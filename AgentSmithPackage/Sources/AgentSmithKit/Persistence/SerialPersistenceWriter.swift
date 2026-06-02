import Foundation
import os

/// Coalescing serial writer for snapshot-style persistence.
///
/// Each `enqueue(_:)` overwrites any prior un-drained snapshot, so a burst of
/// rapid enqueues collapses to at most a few writes. Snapshots are written in
/// strict FIFO order — never an older snapshot after a newer one — and a
/// completed `flush()` guarantees every snapshot enqueued before the flush call
/// has hit the closure.
///
/// Replaces the prior `Task.detached { await persistence.saveX(snapshot) }`
/// pattern, which captured snapshots on MainActor in deterministic order but
/// then raced into the persistence actor with no ordering guarantee. Under that
/// pattern an older snapshot could win the race and overwrite a newer one on
/// disk, and `flushPersistence()` couldn't actually drain in-flight writes.
public actor SerialPersistenceWriter<Snapshot: Sendable> {
    private let label: String
    private let logger: Logger
    private let write: @Sendable (Snapshot) async throws -> Void

    private var pending: (seq: UInt64, snapshot: Snapshot)?
    private var inflight: Task<Void, Never>?

    /// Monotonic id stamped on each enqueue. `flush()` captures the latest as its
    /// target watermark; `writtenSeq` tracks the highest seq actually drained.
    private var enqueueSeq: UInt64 = 0
    private var writtenSeq: UInt64 = 0
    /// Callers parked in `flush()` waiting for `writtenSeq` to reach their target.
    private var flushWaiters: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    public init(
        label: String,
        logger: Logger = Logger(subsystem: "com.agentsmith", category: "SerialPersistenceWriter"),
        write: @escaping @Sendable (Snapshot) async throws -> Void
    ) {
        self.label = label
        self.logger = logger
        self.write = write
    }

    /// Schedule a write for `snapshot`. Replaces any prior un-drained snapshot.
    public func enqueue(_ snapshot: Snapshot) {
        enqueueSeq &+= 1
        pending = (enqueueSeq, snapshot)
        if inflight == nil {
            inflight = Task { [weak self] in
                await self?.drain()
            }
        }
    }

    /// Returns once every snapshot enqueued before this call has been written.
    ///
    /// Uses a sequence watermark rather than awaiting the in-flight task: under a
    /// steady stream of post-flush enqueues the in-flight task keeps re-arming, so
    /// awaiting it could never return. Instead we capture the latest enqueued seq
    /// as our target and wait only until `writtenSeq` reaches it.
    public func flush() async {
        let target = enqueueSeq
        // Synchronous fast-path BEFORE parking: if the target is already written
        // there is nothing to wait for. Critical — parking unconditionally would
        // leak a waiter that nothing ever resumes (the drain only resumes waiters
        // when it advances `writtenSeq`, which won't happen with no pending work).
        if writtenSeq >= target { return }
        await withCheckedContinuation { continuation in
            flushWaiters.append((target, continuation))
        }
    }

    private func drain() async {
        defer { inflight = nil }
        while let item = pending {
            pending = nil
            do {
                try await write(item.snapshot)
            } catch {
                logger.error("Persistence write failed [\(self.label, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            }
            // Advance on BOTH success and failure: a failed write must not block
            // `flush()` forever. The seq is "drained," not "durably persisted."
            writtenSeq = item.seq
            resumeFlushWaiters()
        }
    }

    /// Resumes any parked `flush()` callers whose target watermark has been reached.
    private func resumeFlushWaiters() {
        guard !flushWaiters.isEmpty else { return }
        let ready = flushWaiters.filter { writtenSeq >= $0.target }
        flushWaiters.removeAll { writtenSeq >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
