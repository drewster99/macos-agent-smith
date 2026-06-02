import Foundation
import os

/// Shared process execution logic for BashTool.
///
/// Handles incremental output reading, process group management, and timeouts correctly —
/// including commands that spawn backgrounded child processes (e.g., `cmd &`).
enum ProcessRunner {
    struct Result: Sendable {
        let output: String
        let exitCode: Int32
        let timedOut: Bool
    }

    /// Runs a command and returns its output.
    ///
    /// - Uses `readabilityHandler` for incremental output collection (avoids pipe buffer deadlock).
    /// - Creates a process group so the timeout can kill all children, including backgrounded ones.
    /// - Ties "done reading" to the shell process exiting, not to the pipe closing — so backgrounded
    ///   children that inherit the pipe don't block us indefinitely.
    /// - Honors Task cancellation: if the calling Task is cancelled, the process group is
    ///   SIGTERMed (then SIGKILLed after 2s). Without this, `stopAll` couldn't unwind a Brown
    ///   that was mid-bash, leading to zombie agents surviving across restarts.
    static func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        timeout: TimeInterval
    ) async throws -> Result {
        // Shared state between the async block and the cancellation handler.
        // - pending: continuation hasn't launched the process yet
        // - running(pid): process launched and reachable via its process group
        // - cancelled: Task was cancelled; the block should decline to launch or kill-on-set
        // - completed: process finished on its own; cancel is a no-op
        enum State {
            case pending
            case running(pid_t)
            case cancelled
            case completed
        }
        let stateBox = OSAllocatedUnfairLock<State>(initialState: .pending)
        // Whether `setpgid` succeeded. When it does, kill the whole process group (`-pid`)
        // so backgrounded descendants die too; when it doesn't (it appears to fail
        // consistently in this sandbox — the child has already exec'd by the time the parent
        // calls it), fall back to killing just the direct child (`pid`). Either way the
        // child itself is reaped on timeout/cancel.
        let ownsProcessGroup = OSAllocatedUnfairLock(initialState: false)

        @Sendable func terminate(_ pid: pid_t) {
            let target = ownsProcessGroup.withLock { $0 } ? -pid : pid
            kill(target, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                // The SIGTERM may have already reaped the process; by the time
                // this fires the pid could have been recycled onto an unrelated
                // process. Signal 0 delivers nothing and returns 0 only while the
                // original target/group is still alive, so it gates the escalation
                // against killing an innocent bystander.
                guard kill(target, 0) == 0 else { return }
                kill(target, SIGKILL)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    let pipe = Pipe()

                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.standardOutput = pipe
                    process.standardError = pipe

                    if let workingDirectory {
                        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
                    }

                    // Serial queue to serialize all pipe reads (FileHandle is not thread-safe).
                    let readQueue = DispatchQueue(label: "process-runner-read")
                    var buffer = Data()
                    var pipeIsClosed = false

                    let done = DispatchSemaphore(value: 0)
                    let didTimeout = OSAllocatedUnfairLock(initialState: false)

                    // Read output incrementally as it arrives. This prevents the pipe buffer
                    // (~64KB) from filling up and blocking the process on write.
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        readQueue.sync {
                            guard !pipeIsClosed else { return }
                            let chunk = handle.availableData
                            if !chunk.isEmpty {
                                buffer.append(chunk)
                            }
                        }
                    }

                    // When the shell exits, drain remaining output and close the pipe.
                    // Closing our read end causes backgrounded children to get SIGPIPE on
                    // their next write — they won't hold us open.
                    process.terminationHandler = { _ in
                        pipe.fileHandleForReading.readabilityHandler = nil
                        readQueue.sync {
                            guard !pipeIsClosed else { return }
                            let remaining = pipe.fileHandleForReading.availableData
                            if !remaining.isEmpty {
                                buffer.append(remaining)
                            }
                            pipeIsClosed = true
                            // close() can throw if the fd is already closed (e.g., process never started).
                            // This is expected and safe to ignore — we're done with the pipe.
                            do { try pipe.fileHandleForReading.close() } catch { /* fd already closed */ }
                        }
                        done.signal()
                    }

                    // Prevent interactive prompts from hanging the process indefinitely.
                    // Without this, SSH/git may wait for a passphrase on stdin that will never arrive.
                    process.standardInput = FileHandle.nullDevice
                    var env = ProcessInfo.processInfo.environment
                    env["GIT_TERMINAL_PROMPT"] = "0"  // git: don't prompt for credentials
                    env["SSH_ASKPASS"] = ""            // SSH: don't invoke GUI askpass program
                    process.environment = env

                    // If the Task was cancelled before we even got here, bail out without
                    // launching the process. No kill needed — nothing to kill.
                    let alreadyCancelled = stateBox.withLock { state -> Bool in
                        if case .cancelled = state { return true }
                        return false
                    }
                    if alreadyCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }

                    // Put the process in its own group so the timeout/cancel can kill all
                    // children. If this fails, `terminate(_:)` falls back to a single-pid kill.
                    let pgidOK = setpgid(process.processIdentifier, process.processIdentifier) == 0
                    let pgidErrno = errno
                    ownsProcessGroup.withLock { $0 = pgidOK }
                    if !pgidOK {
                        let logger = Logger(subsystem: "AgentSmith", category: "ProcessRunner")
                        logger.debug("setpgid failed for pid \(process.processIdentifier): \(String(cString: strerror(pgidErrno))) — timeout/cancel will signal only the direct child")
                    }

                    // Publish the pid so the cancellation handler can reach it, but also
                    // handle the race where cancellation fired between the pre-launch check
                    // above and now: if the state is already `.cancelled`, kill the process
                    // group ourselves (the cancel handler couldn't — it saw pid=nil).
                    let pid = process.processIdentifier
                    let shouldKillNow = stateBox.withLock { state -> Bool in
                        switch state {
                        case .cancelled:
                            return true
                        case .pending, .running, .completed:
                            state = .running(pid)
                            return false
                        }
                    }
                    if shouldKillNow {
                        terminate(pid)
                    }

                    // Schedule timeout — kills the process group (or the direct child if
                    // setpgid failed).
                    let timeoutItem = DispatchWorkItem {
                        didTimeout.withLock { $0 = true }
                        terminate(pid)
                    }
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + timeout,
                        execute: timeoutItem
                    )

                    // Wait for shell to exit (normal completion, timeout, or cancellation).
                    done.wait()
                    timeoutItem.cancel()

                    // Mark the state as completed so a late-arriving cancel handler does nothing.
                    let finalState = stateBox.withLock { state -> State in
                        let previous = state
                        state = .completed
                        return previous
                    }

                    let data = readQueue.sync { buffer }
                    let output = String(data: data, encoding: .utf8)
                        ?? "Error: output could not be decoded as UTF-8 (\(data.count) bytes)"
                    let status = process.terminationStatus
                    let timedOut = didTimeout.withLock { $0 }

                    // If cancellation won the race with natural termination, surface
                    // CancellationError so the caller unwinds instead of seeing a Result
                    // that looks like a normal exit.
                    if case .cancelled = finalState {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    continuation.resume(returning: Result(
                        output: output,
                        exitCode: status,
                        timedOut: timedOut
                    ))
                }
            }
        } onCancel: {
            // Snapshot-and-transition the shared state. If a process is running, send
            // SIGTERM (then SIGKILL after a grace period) — to the whole group if we have
            // one, otherwise to the direct child. If we're still pending, record
            // cancellation so the dispatch block bails out before launching.
            let pidToKill: pid_t? = stateBox.withLock { state in
                switch state {
                case .pending:
                    state = .cancelled
                    return nil
                case .running(let pid):
                    state = .cancelled
                    return pid
                case .cancelled, .completed:
                    return nil
                }
            }
            if let pid = pidToKill {
                terminate(pid)
            }
        }
    }
}
