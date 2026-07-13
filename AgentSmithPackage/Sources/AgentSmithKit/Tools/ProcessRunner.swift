import Foundation
import os

/// Shared process execution logic for BashTool.
///
/// Spawns via `posix_spawn` (not Foundation's `Process`) specifically so the child can be placed
/// in its own process group *atomically at spawn, before exec* — `POSIX_SPAWN_SETPGROUP` +
/// `posix_spawnattr_setpgroup(&attr, 0)`. Foundation's `Process` gives no pre-exec hook in the
/// child, so the only place left to set the group is the parent after `run()`, by which time the
/// child has already exec'd and `setpgid` fails with `EACCES` every time (reproduced 5/5). With
/// the group set at spawn, the timeout/cancel can `kill(-pid, …)` the whole tree — including
/// backgrounded children (`cmd &`) and grandchildren — instead of leaking them.
///
/// Design guarantees:
/// - Reads output incrementally (a `DispatchSource` read source draining the fd) so the ~64 KB
///   pipe buffer can't fill and block the child on write. Every read is gated by a zero-timeout
///   `poll` so it can never block the draining thread, regardless of the fd's O_NONBLOCK state.
/// - Ties "done" to the *shell process exiting* — a blocking `waitpid` on a dedicated thread, NOT
///   the pipe closing — so a backgrounded child that inherited the pipe can't block us, and a fast
///   child that exits before any async observer is armed can't be missed either.
/// - The final drain in `finish()` is non-blocking and happens *before* the fd is closed and
///   `done` is signalled — preserving the drain-before-signal ordering that keeps output from
///   being dropped (see git history: bb50e2c's locked drain invariant).
/// - Honors Task cancellation: SIGTERM the group, then SIGKILL after 2 s.
enum ProcessRunner {
    struct Result: Sendable {
        let output: String
        let exitCode: Int32
        let timedOut: Bool
    }

    private static let logger = Logger(subsystem: "AgentSmith", category: "ProcessRunner")

    static func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        timeout: TimeInterval
    ) async throws -> Result {
        enum State {
            case pending
            case running(pid_t)
            case cancelled
            case completed
        }
        struct PipeReadState {
            var buffer = Data()
            var closed = false
            var exitStatus: Int32 = 0
        }
        let stateBox = OSAllocatedUnfairLock<State>(initialState: .pending)

        // Child is a group leader (group id == pid), so the negative-pid form targets the whole
        // group; fall back to the bare pid if the group send fails.
        @Sendable func signalGroup(_ pid: pid_t, _ sig: Int32) {
            if kill(-pid, sig) != 0 { kill(pid, sig) }
        }
        @Sendable func terminate(_ pid: pid_t) {
            signalGroup(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                // Signal 0 probes liveness, gating the SIGKILL against a recycled pid.
                guard kill(-pid, 0) == 0 || kill(pid, 0) == 0 else { return }
                signalGroup(pid, SIGKILL)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    // Raw pipe (fds only; no non-Sendable FileHandle) for stdout+stderr.
                    var fds: [Int32] = [-1, -1]
                    guard pipe(&fds) == 0 else {
                        continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                        return
                    }
                    let readFD = fds[0]
                    let writeFD = fds[1]
                    // Non-blocking read end so incremental reads and the final drain never block on
                    // a backgrounded child still holding the write end open.
                    let readFlags = fcntl(readFD, F_GETFL)
                    _ = fcntl(readFD, F_SETFL, readFlags | O_NONBLOCK)

                    let readState = OSAllocatedUnfairLock(initialState: PipeReadState())
                    let done = DispatchSemaphore(value: 0)
                    let didTimeout = OSAllocatedUnfairLock(initialState: false)

                    // Drain everything currently available WITHOUT ever blocking. Returns true at
                    // EOF. Each read is gated by a zero-timeout `poll`: it reports the fd readable
                    // when there's data OR the write end has closed (EOF/HUP), so the following
                    // `read` can't block — crucially, this does NOT depend on the fd's O_NONBLOCK
                    // flag, which proved unreliable to set here via variadic `fcntl` and left `read`
                    // blocking forever whenever a slow/surviving child kept a write end open.
                    @Sendable func drainAvailable(into buffer: inout Data) -> Bool {
                        var chunk = [UInt8](repeating: 0, count: 65_536)
                        while true {
                            var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                            let ready = poll(&pfd, 1, 0)
                            if ready < 0 {
                                if errno == EINTR { continue }
                                return false
                            }
                            if ready == 0 { return false }   // nothing ready right now (not EOF)
                            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                                read(readFD, raw.baseAddress, raw.count)
                            }
                            if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
                            else if n == 0 { return true }   // EOF
                            else if errno == EINTR { continue }
                            else { return false }            // EAGAIN / error
                        }
                    }

                    let readSource = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: DispatchQueue.global())

                    // Terminal step: drain → mark closed → cancel source → close → record status →
                    // signal. The waitpid thread and the timeout fallback can BOTH call this (e.g. a
                    // timeout kills the child, waitpid finishes, then the +5 s fallback fires), so
                    // everything past the first call MUST be skipped — most importantly close(readFD),
                    // which on a second call would close an fd number already recycled by another
                    // concurrent run/file op. The `firstCall` flag gates the whole tail, not just the
                    // drain. Drain is BEFORE close+signal → no output lost.
                    @Sendable func finish(status: Int32?) {
                        let firstCall = readState.withLock { state -> Bool in
                            guard !state.closed else { return false }
                            _ = drainAvailable(into: &state.buffer)
                            state.closed = true
                            if let status { state.exitStatus = status }
                            return true
                        }
                        guard firstCall else { return }
                        readSource.cancel()
                        close(readFD)
                        done.signal()
                    }

                    readSource.setEventHandler {
                        let eof = readState.withLock { state -> Bool in
                            guard !state.closed else { return false }
                            return drainAvailable(into: &state.buffer)
                        }
                        if eof { readSource.cancel() }   // write end closed; the waitpid thread drives completion
                    }
                    readSource.resume()

                    // --- file actions: stdin ← /dev/null, stdout+stderr → pipe write end ---
                    // Opaque-pointer types on Darwin (imported as optionals); `_init` allocates them.
                    var fileActions: posix_spawn_file_actions_t?
                    posix_spawn_file_actions_init(&fileActions)
                    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
                    posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
                    posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDERR_FILENO)
                    // The child only needs the dup'd stdout/stderr; close both original pipe fds in
                    // it so it can't hold the read end open or leak the raw write fd.
                    posix_spawn_file_actions_addclose(&fileActions, writeFD)
                    posix_spawn_file_actions_addclose(&fileActions, readFD)
                    if let workingDirectory {
                        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
                    }

                    // --- attributes: new process group atomically at spawn (the whole point) ---
                    var attr: posix_spawnattr_t?
                    posix_spawnattr_init(&attr)
                    // Give the child a clean signal environment so it actually responds to our
                    // SIGTERM on timeout/cancel. TWO inheritance hazards, both surviving exec:
                    //   1. Blocked signal MASK. We spawn from a libdispatch worker thread, and
                    //      libdispatch blocks most signals on its workers. A blocked SIGTERM is
                    //      inherited, stays *pending* (undelivered) in the child, and only the
                    //      unblockable SIGKILL (our 2 s fallback) ever lands — too slow to beat a
                    //      fast child. SETSIGMASK with an empty set unblocks everything.
                    //   2. Ignored DISPOSITION (SIG_IGN). Also inherited across exec (unlike
                    //      handlers, which reset). SETSIGDEF resets all dispositions to default.
                    // Proven empirically: with the mask blocked, SETSIGDEF alone does NOT help;
                    // SETSIGMASK is the one that makes the group SIGTERM work. Set both for safety.
                    var defaultSignals = sigset_t()
                    sigfillset(&defaultSignals)
                    posix_spawnattr_setsigdefault(&attr, &defaultSignals)
                    var unblockedMask = sigset_t()
                    sigemptyset(&unblockedMask)
                    posix_spawnattr_setsigmask(&attr, &unblockedMask)
                    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
                    posix_spawnattr_setpgroup(&attr, 0)

                    // --- argv / envp (posix_spawn copies these; free after the call) ---
                    var env = ProcessInfo.processInfo.environment
                    env["GIT_TERMINAL_PROMPT"] = "0"  // git: don't prompt for credentials
                    env["SSH_ASKPASS"] = ""            // ssh: don't invoke a GUI askpass
                    let argvStrings = [executable] + arguments
                    let envStrings = env.map { "\($0.key)=\($0.value)" }
                    var argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
                    argv.append(nil)
                    var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
                    envp.append(nil)

                    // Synchronous cleanup — deliberately NOT @Sendable (it touches the non-Sendable
                    // argv/envp/attr, and is only ever called inline on this queue).
                    func freeSpawnResources() {
                        for p in argv where p != nil { free(p) }
                        for p in envp where p != nil { free(p) }
                        posix_spawn_file_actions_destroy(&fileActions)
                        posix_spawnattr_destroy(&attr)
                    }

                    if case .cancelled = stateBox.withLock({ $0 }) {
                        freeSpawnResources()
                        close(writeFD)        // not yet closed (spawn hasn't run)
                        finish(status: nil)   // tears down source + closes readFD
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    var pidVar: pid_t = 0
                    let spawnRC = posix_spawn(&pidVar, executable, &fileActions, &attr, argv, envp)
                    freeSpawnResources()
                    // Parent drops its copy of the write end so the pipe can EOF once the child (and
                    // any children) are done.
                    close(writeFD)

                    guard spawnRC == 0 else {
                        finish(status: nil)
                        continuation.resume(throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(spawnRC),
                            userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed: \(String(cString: strerror(spawnRC)))"]
                        ))
                        return
                    }

                    // Freeze the pid so the concurrently-executing handlers capture an immutable value.
                    let pid = pidVar

                    let shouldKillNow = stateBox.withLock { state -> Bool in
                        switch state {
                        case .cancelled:
                            return true
                        case .pending, .running, .completed:
                            state = .running(pid)
                            return false
                        }
                    }
                    if shouldKillNow { terminate(pid) }

                    // Completion is tied to the shell exiting. Use a blocking `waitpid` on a
                    // dedicated thread rather than a `DispatchSource` process source: that source
                    // is edge-triggered and MISSES the exit of a child that dies before it's armed
                    // — a fast `echo` exits in microseconds, which hangs us forever (observed).
                    // `waitpid` blocks until the child terminates regardless of timing, and reaps
                    // it so it can't zombie. The child always terminates eventually — naturally, or
                    // because the timeout/cancel killed its group.
                    DispatchQueue.global().async {
                        var status: Int32 = 0
                        while true {
                            let r = waitpid(pid, &status, 0)
                            if r == pid { finish(status: status); break }
                            if r == -1 {
                                if errno == EINTR { continue }   // interrupted — retry
                                finish(status: nil); break       // ECHILD / other: already reaped
                            }
                            finish(status: nil); break           // r == 0 can't happen with options 0
                        }
                    }

                    // Timeout: kill the group; the killed child then exits and the waitpid thread
                    // finishes us. The delayed fallback guarantees we can't hang even if waitpid
                    // never returns (e.g. an unkillable D-state child) — and it drains first, so no
                    // output is lost.
                    let timeoutItem = DispatchWorkItem {
                        didTimeout.withLock { $0 = true }
                        terminate(pid)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(status: nil) }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                    done.wait()
                    timeoutItem.cancel()

                    let finalState = stateBox.withLock { state -> State in
                        let previous = state
                        state = .completed
                        return previous
                    }

                    let (data, rawStatus) = readState.withLock { ($0.buffer, $0.exitStatus) }
                    let output = String(data: data, encoding: .utf8)
                        ?? "Error: output could not be decoded as UTF-8 (\(data.count) bytes)"
                    let timedOut = didTimeout.withLock { $0 }

                    if case .cancelled = finalState {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    continuation.resume(returning: Result(
                        output: output,
                        exitCode: Self.exitCode(fromWaitStatus: rawStatus),
                        timedOut: timedOut
                    ))
                }
            }
        } onCancel: {
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
            if let pid = pidToKill { terminate(pid) }
        }
    }

    /// Maps a `waitpid` status to a shell-style exit code: the exit status for a normal exit,
    /// `128 + signal` for a signal-terminated process (bash's convention), else -1.
    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let lowSeven = status & 0x7f
        if lowSeven == 0 { return (status >> 8) & 0xff }   // WIFEXITED → WEXITSTATUS
        if lowSeven != 0x7f { return 128 + lowSeven }       // WIFSIGNALED → 128 + WTERMSIG
        return -1
    }
}
