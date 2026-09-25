import Foundation
import os

/// Coalescing serial writer for snapshot-style persistence.
///
/// Each `enqueue(_:)` overwrites any prior un-drained snapshot, so a burst of
/// rapid enqueues collapses to at most a few writes. Snapshots are written in
/// strict FIFO order — never an older snapshot after a newer one — and a
/// completed `flush()` guarantees every snapshot enqueued before the flush call
/// has hit the closure, and REPORTS whether it reached disk.
///
/// Two watermarks, deliberately distinct: `drainedSeq` ("the writer is done with it", advanced
/// on success AND failure so a failing disk can't park `flush()` forever) and `durableSeq`
/// ("a write covering it succeeded"). Each snapshot is complete state, so a later successful
/// write makes every earlier seq durable too. Conflating the two let callers treat a failed
/// write as saved.
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
    /// target watermark; `drainedSeq` tracks the highest seq the writer has finished with, and
    /// `durableSeq` the highest seq a SUCCESSFUL write covers.
    private var enqueueSeq: UInt64 = 0
    private var drainedSeq: UInt64 = 0
    private var durableSeq: UInt64 = 0
    /// Callers parked in `flush()` waiting for `drainedSeq` to reach their target.
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
        enqueueSeq += 1
        pending = (enqueueSeq, snapshot)
        if inflight == nil {
            inflight = Task { [weak self] in
                await self?.drain()
            }
        }
    }

    /// Returns once every snapshot enqueued before this call has been drained, reporting whether
    /// they are DURABLE — i.e. whether a successful write covers the latest of them. `false` means
    /// the disk refused (the failure is already logged); the caller decides what that costs it.
    ///
    /// Uses a sequence watermark rather than awaiting the in-flight task: under a
    /// steady stream of post-flush enqueues the in-flight task keeps re-arming, so
    /// awaiting it could never return. Instead we capture the latest enqueued seq
    /// as our target and wait only until `drainedSeq` reaches it.
    @discardableResult
    public func flush() async -> Bool {
        let target = enqueueSeq
        // Synchronous fast-path BEFORE parking: if the target is already drained
        // there is nothing to wait for. Critical — parking unconditionally would
        // leak a waiter that nothing ever resumes (the drain only resumes waiters
        // when it advances `drainedSeq`, which won't happen with no pending work).
        if drainedSeq < target {
            await withCheckedContinuation { continuation in
                flushWaiters.append((target, continuation))
            }
        }
        return durableSeq >= target
    }

    private func drain() async {
        defer { inflight = nil }
        while let item = pending {
            pending = nil
            do {
                try await write(item.snapshot)
                durableSeq = item.seq
            } catch {
                logger.error("Persistence write failed [\(self.label, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            }
            // Advance on BOTH success and failure: a failed write must not block
            // `flush()` forever. `durableSeq` (above) is what records success.
            drainedSeq = item.seq
            resumeFlushWaiters()
        }
    }

    /// Resumes any parked `flush()` callers whose target watermark has been reached.
    private func resumeFlushWaiters() {
        guard !flushWaiters.isEmpty else { return }
        let ready = flushWaiters.filter { drainedSeq >= $0.target }
        flushWaiters.removeAll { drainedSeq >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
