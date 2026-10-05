import Foundation
import os
import Synchronization

/// Serial append writer for an append-only JSONL file (the channel log, the usage log).
///
/// Unlike `SerialPersistenceWriter`, which coalesces snapshots last-writer-wins, this
/// *accumulates* — every enqueued element must reach disk, so a burst is batched (not
/// dropped) and appended in FIFO order. A completed `flush()` guarantees every element
/// enqueued before the flush call has been handed to the append closure.
///
/// `enqueue` is SYNCHRONOUS, which is why this is a lock-guarded class rather than an actor.
/// The order of lines on disk must be the order of the calls — the usage log replays a backfill
/// row only onto the records BEFORE it — and two `await writer.enqueue(…)` hops from one actor
/// are not guaranteed to reach another actor in the order they were made. A synchronous call
/// has no hop to reorder.
///
/// The flush contract uses a sequence watermark rather than awaiting the in-flight task:
/// under a steady stream of post-flush enqueues the drain keeps re-arming, so awaiting the
/// task could never return.
public final class JSONLAppendWriter<Element: Sendable>: Sendable {
    private let logger: Logger
    /// Names the file in log lines, so a failing append says WHICH log is losing durability.
    private let label: String
    private let append: @Sendable ([Element]) async throws -> Void

    private struct State {
        var buffer: [Element] = []
        var isDraining = false
        var enqueueSeq: UInt64 = 0
        var writtenSeq: UInt64 = 0
        var flushWaiters: [(target: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
        /// True when the last drain GAVE UP on a persistently-failing append (disk full /
        /// permissions): the retained batch is in memory only, so a caller that treats a
        /// completed `flush()` as durable would be over-claiming. Cleared on the next successful
        /// append; surfaced via `flush()`'s return.
        var lastFlushFailed = false
    }

    private let state = Mutex(State())

    public init(
        label: String,
        append: @escaping @Sendable ([Element]) async throws -> Void
    ) {
        self.logger = Logger(subsystem: "com.agentsmith", category: "JSONLAppendWriter")
        self.label = label
        self.append = append
    }

    /// Queue elements to be appended. Lines reach the file in exactly the order of these calls.
    public func enqueue(_ elements: [Element]) {
        guard !elements.isEmpty else { return }
        let startsDrain = state.withLock { state in
            state.buffer.append(contentsOf: elements)
            state.enqueueSeq &+= 1
            guard !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        if startsDrain {
            Task { await self.drain() }
        }
    }

    /// Returns once every element enqueued before this call has been written. The result is `true`
    /// when the log is durable (everything reached disk) and `false` when a drain gave up on a
    /// persistently-failing append and the tail is retained in memory only — so a termination path can
    /// surface that instead of exiting as though the disk reflected memory.
    @discardableResult
    public func flush() async -> Bool {
        await withCheckedContinuation { continuation in
            let durable: Bool? = state.withLock { state in
                let target = state.enqueueSeq
                if state.writtenSeq >= target { return !state.lastFlushFailed }
                state.flushWaiters.append((target, continuation))
                return nil
            }
            if let durable { continuation.resume(returning: durable) }
        }
    }

    private static var maxAppendAttempts: Int { 5 }

    private func drain() async {
        while true {
            let next: (batch: [Element], seq: UInt64)? = state.withLock { state in
                guard !state.buffer.isEmpty else {
                    state.isDraining = false
                    return nil
                }
                let batch = state.buffer
                state.buffer = []
                return (batch, state.enqueueSeq)
            }
            guard let (batch, seq) = next else { return }
            var attempt = 0
            while true {
                do {
                    try await append(batch)
                    resumeFlushWaiters { state in
                        state.writtenSeq = seq
                        state.lastFlushFailed = false
                    }
                    break  // success → move on to any batch that accrued during the write
                } catch {
                    attempt += 1
                    if attempt >= Self.maxAppendAttempts {
                        // A likely-permanent failure (disk full / permissions). Keep the batch
                        // buffered so a later enqueue retries it, but advance the watermark so
                        // flush() can't hang forever, then STOP draining (returning, not
                        // re-looping, so we don't busy-spin on a persistently failing disk). This
                        // is the one path that reports "flushed" without durability — logged
                        // loudly, and only after exhausting retries.
                        logger.error("\(self.label, privacy: .public) append failed after \(attempt, privacy: .public) attempts; \(batch.count, privacy: .public) element(s) retained for retry: \(error.localizedDescription, privacy: .public)")
                        resumeFlushWaiters { state in
                            state.buffer.insert(contentsOf: batch, at: 0)
                            // Advance the watermark to the CURRENT enqueue seq (not this failed
                            // batch's `seq`): elements that streamed in during the ~1.5s of
                            // retries bumped `enqueueSeq` past `seq`, and their `flush()` waiters
                            // (target > seq) would otherwise hang until a future enqueue since we
                            // return without re-draining.
                            state.writtenSeq = state.enqueueSeq
                            state.lastFlushFailed = true
                            state.isDraining = false
                        }
                        return
                    }
                    logger.error("\(self.label, privacy: .public) append attempt \(attempt, privacy: .public) failed, retrying: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: .milliseconds(100 * attempt))
                }
            }
        }
    }

    /// Applies `update` and resumes every waiter it satisfied — outside the lock, since a resumed
    /// continuation may run arbitrary code.
    private func resumeFlushWaiters(after update: (inout State) -> Void) {
        let (ready, durable) = state.withLock { state in
            update(&state)
            let written = state.writtenSeq
            let ready = state.flushWaiters.filter { written >= $0.target }
            state.flushWaiters.removeAll { written >= $0.target }
            return (ready.map(\.continuation), !state.lastFlushFailed)
        }
        for continuation in ready { continuation.resume(returning: durable) }
    }
}
