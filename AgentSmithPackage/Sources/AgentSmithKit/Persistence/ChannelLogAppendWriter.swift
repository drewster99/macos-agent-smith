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

    /// Returns once every message enqueued before this call has been written.
    public func flush() async {
        let target = enqueueSeq
        if writtenSeq >= target { return }
        await withCheckedContinuation { continuation in
            flushWaiters.append((target, continuation))
        }
    }

    private func drain() async {
        defer { inflight = nil }
        while !buffer.isEmpty {
            let batch = buffer
            buffer = []
            let seq = enqueueSeq
            do {
                try await append(batch)
            } catch {
                // A failed append must not park flush() forever. Re-queue the batch at the
                // front so nothing is silently lost, then advance the watermark so waiters
                // for already-satisfied targets aren't stranded — the re-queued batch will be
                // retried on the next drain iteration (kicked by a later enqueue or flush).
                logger.error("Channel log append failed: \(error.localizedDescription, privacy: .public)")
                buffer.insert(contentsOf: batch, at: 0)
                writtenSeq = seq
                resumeFlushWaiters()
                return
            }
            writtenSeq = seq
            resumeFlushWaiters()
        }
    }

    private func resumeFlushWaiters() {
        guard !flushWaiters.isEmpty else { return }
        let ready = flushWaiters.filter { writtenSeq >= $0.target }
        flushWaiters.removeAll { writtenSeq >= $0.target }
        for waiter in ready { waiter.continuation.resume() }
    }
}
