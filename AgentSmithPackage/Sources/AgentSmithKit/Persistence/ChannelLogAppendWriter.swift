import Foundation
import os

/// Serial append writer for the JSONL channel log.
///
/// Unlike `SerialPersistenceWriter`, which coalesces snapshots last-writer-wins, this
/// *accumulates* — every enqueued message must reach disk, so a burst is batched (not
/// dropped) and appended in FIFO order. A completed `flush()` guarantees every message
/// enqueued before the flush call has been handed to the append closure.
///
/// The flush contract uses a sequence watermark rather than awaiting the in-flight task:
/// under a steady stream of post-flush enqueues the drain keeps re-arming, so awaiting the
/// task could never return.
public actor ChannelLogAppendWriter {
    private let logger: Logger
    private let append: @Sendable ([ChannelMessage]) async throws -> Void

    private var buffer: [ChannelMessage] = []
    private var inflight: Task<Void, Never>?

    private var enqueueSeq: UInt64 = 0
    private var writtenSeq: UInt64 = 0
    private var flushWaiters: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    /// True when the last drain GAVE UP on a persistently-failing append (disk full / permissions):
    /// the retained batch is in memory only, so a caller that treats a completed `flush()` as durable
    /// would be over-claiming. Cleared on the next successful append; surfaced via `flush()`'s return.
    public private(set) var lastFlushFailed = false

    public init(
        logger: Logger = Logger(subsystem: "com.agentsmith", category: "ChannelLogAppendWriter"),
        append: @escaping @Sendable ([ChannelMessage]) async throws -> Void
    ) {
        self.logger = logger
        self.append = append
    }

    /// Queue messages to be appended. Order is preserved across calls.
    public func enqueue(_ messages: [ChannelMessage]) {
        guard !messages.isEmpty else { return }
        buffer.append(contentsOf: messages)
        enqueueSeq &+= 1
        if inflight == nil {
            inflight = Task { [weak self] in await self?.drain() }
        }
    }

    /// Returns once every message enqueued before this call has been written. The result is `true`
    /// when the log is durable (everything reached disk) and `false` when a drain gave up on a
    /// persistently-failing append and the tail is retained in memory only — so a termination path can
    /// surface that instead of exiting as though the disk reflected memory.
    @discardableResult
    public func flush() async -> Bool {
        let target = enqueueSeq
        if writtenSeq >= target { return !lastFlushFailed }
        await withCheckedContinuation { continuation in
            flushWaiters.append((target, continuation))
        }
        return !lastFlushFailed
    }

    private static let maxAppendAttempts = 5

    private func drain() async {
        defer { inflight = nil }
        while !buffer.isEmpty {
            let batch = buffer
            buffer = []
            let seq = enqueueSeq
            var attempt = 0
            while true {
                do {
                    try await append(batch)
                    writtenSeq = seq
                    lastFlushFailed = false
                    resumeFlushWaiters()
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
                        logger.error("Channel log append failed after \(attempt, privacy: .public) attempts; \(batch.count, privacy: .public) message(s) retained for retry: \(error.localizedDescription, privacy: .public)")
                        buffer.insert(contentsOf: batch, at: 0)
                        // Advance the watermark to the CURRENT enqueue seq (not this failed batch's
                        // `seq`): messages that streamed in during the ~1.5s of retries bumped
                        // `enqueueSeq` past `seq`, and their `flush()` waiters (target > seq) would
                        // otherwise hang until a future enqueue since we return without re-draining.
                        writtenSeq = enqueueSeq
                        lastFlushFailed = true
                        resumeFlushWaiters()
                        return
                    }
                    logger.error("Channel log append attempt \(attempt, privacy: .public) failed, retrying: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: .milliseconds(100 * attempt))
                }
            }
        }
    }

    private func resumeFlushWaiters() {
        guard !flushWaiters.isEmpty else { return }
        let ready = flushWaiters.filter { writtenSeq >= $0.target }
        flushWaiters.removeAll { writtenSeq >= $0.target }
        for waiter in ready { waiter.continuation.resume() }
    }
}
