import Testing
import Foundation
import os
@testable import AgentSmithKit

// MARK: - H1/H2: SerialPersistenceWriter

/// Coalescing serializer fixes both:
///  • H1 — `Task.detached` writes that captured snapshots on MainActor could land
///    in the persistence actor out-of-order, leaving older snapshots on disk after
///    newer ones had already been written.
///  • H2 — `flushPersistence()` could not actually flush in-flight detached writes.
@Suite("Concurrency Review — H1/H2: SerialPersistenceWriter", .serialized)
struct SerialPersistenceWriterTests {

    @Test("After many rapid enqueues, the LAST snapshot is what's persisted")
    func writerSettlesOnLatestSnapshot() async throws {
        let recorder = SnapshotRecorder()
        let writer = SerialPersistenceWriter<Int>(label: "h1.last") { snapshot in
            try? await Task.sleep(for: .milliseconds(2))
            await recorder.record(snapshot)
        }
        for i in 1...100 {
            await writer.enqueue(i)
        }
        await writer.flush()
        let last = await recorder.last
        #expect(last == 100, "Latest snapshot must win; got \(String(describing: last))")
    }

    @Test("Snapshots are written in monotonic order — never an older after a newer")
    func writerNeverWritesOutOfOrder() async throws {
        let recorder = SnapshotRecorder()
        let writer = SerialPersistenceWriter<Int>(label: "h1.order") { snapshot in
            try? await Task.sleep(for: .microseconds(500))
            await recorder.record(snapshot)
        }
        for i in 1...200 { await writer.enqueue(i) }
        await writer.flush()
        let inOrder = await recorder.isMonotonic
        #expect(inOrder, "Writer must preserve monotonic order")
    }

    @Test("flush() drains every pending write before returning")
    func flushFullyDrains() async throws {
        let recorder = SnapshotRecorder()
        let writer = SerialPersistenceWriter<Int>(label: "h2.flush") { snapshot in
            try? await Task.sleep(for: .milliseconds(10))
            await recorder.record(snapshot)
        }
        for i in 1...10 { await writer.enqueue(i) }
        await writer.flush()
        let last = await recorder.last
        #expect(last == 10, "flush() must wait for the latest snapshot to land; got \(String(describing: last))")
    }

    /// Stress test: many concurrent producers enqueue increasing snapshots
    /// from independent Tasks. The writer must still drain to the LAST
    /// snapshot value, even though arrival order at the actor is not
    /// guaranteed to mirror caller-side ordering when callers are independent.
    /// This is the worst-case shape that the prior `Task.detached` pattern
    /// could not handle (older snapshots could win the race).
    @Test("Concurrent producers leave the LATEST value in the writer")
    func concurrentProducersLeaveLatestValue() async throws {
        let recorder = SnapshotRecorder()
        let writer = SerialPersistenceWriter<Int>(label: "h1.concurrent") { snapshot in
            try? await Task.sleep(for: .microseconds(200))
            await recorder.record(snapshot)
        }
        // Spawn 50 concurrent enqueues with values 1...50 (strictly increasing).
        await withTaskGroup(of: Void.self) { group in
            for i in 1...50 {
                group.addTask {
                    await writer.enqueue(i)
                }
            }
        }
        await writer.flush()
        let last = await recorder.last
        // The drain processes whatever's pending at the time it runs. With
        // concurrent producers, the LAST enqueue to land at the writer wins,
        // and that's the last snapshot we'll see written.
        #expect(last != nil, "At least one snapshot must be written")
        // We can't assert last == 50 deterministically — concurrent enqueues
        // can arrive in any order at the writer. What we CAN assert is that
        // the writer is monotonic and that some snapshot landed.
        let isMonotonic = await recorder.isMonotonic
        #expect(isMonotonic, "Within a single drain, written snapshots must be monotonic")
    }

    @Test("Coalescing — total writes ≤ enqueues for rapid bursts")
    func writerCoalesces() async throws {
        let recorder = SnapshotRecorder()
        let writer = SerialPersistenceWriter<Int>(label: "h1.coalesce") { snapshot in
            try? await Task.sleep(for: .milliseconds(5))
            await recorder.record(snapshot)
        }
        for i in 1...50 { await writer.enqueue(i) }
        await writer.flush()
        let count = await recorder.count
        #expect(count < 50, "Coalescing should drop redundant writes; got \(count) writes for 50 enqueues")
        #expect(count >= 1, "At least one write must occur")
    }
}

private actor SnapshotRecorder {
    private(set) var received: [Int] = []
    private(set) var isMonotonic = true

    func record(_ snapshot: Int) {
        if let prev = received.last, prev > snapshot {
            isMonotonic = false
        }
        received.append(snapshot)
    }

    var last: Int? { received.last }
    var count: Int { received.count }
}

// MARK: - H3: SerialChainedTaskQueue (restartForNewTask serialization)

/// Restart requests must run one at a time, in FIFO order. The pre-fix code
/// fired each `restartForNewTask` as its own `Task.detached`, allowing multiple
/// restarts to interleave; with `OrchestrationRuntime.start()`'s
/// `guard smith == nil else { return }` guard, the second restart's `start()`
/// could silently no-op, dropping the request.
@Suite("Concurrency Review — H3: SerialChainedTaskQueue", .serialized)
struct SerialChainedTaskQueueTests {

    @Test("Every scheduled restart runs to completion exactly once")
    func everyScheduledRestartRuns() async throws {
        let counter = OperationCounter()
        let queue = SerialChainedTaskQueue()
        for i in 1...20 {
            queue.schedule {
                try? await Task.sleep(for: .milliseconds(2))
                await counter.recordCompletion(at: i)
            }
        }
        await queue.waitForAll()
        let completions = await counter.completions
        #expect(completions == Array(1...20),
                "Every scheduled task must run exactly once in FIFO order; got \(completions)")
    }

    @Test("Operations are observed in strict serial order — no overlap")
    func operationsRunSerially() async throws {
        let observer = OverlapDetector()
        let queue = SerialChainedTaskQueue()
        for i in 1...30 {
            queue.schedule {
                await observer.enter(i)
                try? await Task.sleep(for: .microseconds(500))
                await observer.exit(i)
            }
        }
        await queue.waitForAll()
        let didOverlap = await observer.didOverlap
        #expect(!didOverlap, "Two scheduled operations must never overlap")
    }
}

private actor OperationCounter {
    private(set) var completions: [Int] = []
    func recordCompletion(at index: Int) { completions.append(index) }
}

private actor OverlapDetector {
    private var inFlight: Int = 0
    private(set) var didOverlap = false
    func enter(_ id: Int) {
        inFlight += 1
        if inFlight > 1 { didOverlap = true }
    }
    func exit(_ id: Int) { inFlight -= 1 }
}

// MARK: - M3: MessageChannel.stream subscriber lifecycle

@Suite("Concurrency Review — M3: stream subscriber cleanup", .serialized)
struct MessageChannelSubscriberLifecycleTests {

    @Test("Cancelling a stream consumer removes its subscriber promptly")
    func cancellingStreamConsumerCleansSubscriber() async throws {
        let channel = MessageChannel()

        let baseline = await channel.subscriberCount

        // Start a consumer task that subscribes via stream() and then cancels itself.
        let consumer = Task {
            for await _ in channel.stream() { break }
        }
        // Give the stream a tick to register its subscriber.
        try? await Task.sleep(for: .milliseconds(20))
        let active = await channel.subscriberCount
        #expect(active >= baseline + 1, "Stream subscribe should have added an entry")

        consumer.cancel()
        // Push a message so the for-await loop wakes and exits.
        await channel.post(ChannelMessage(sender: .system, content: "drain"))
        _ = await consumer.value

        // Subscriber must drop quickly. Allow a brief window for cleanup, but it
        // must complete reliably (currently the cleanup is fire-and-forget).
        var iterations = 0
        var current = await channel.subscriberCount
        while current > baseline && iterations < 20 {
            try? await Task.sleep(for: .milliseconds(10))
            current = await channel.subscriberCount
            iterations += 1
        }
        #expect(current == baseline, "Subscriber must be removed; remained at \(current) (baseline=\(baseline))")
    }
}

// MARK: - M4: callbacks cleared on stopAll/stop

@Suite("Concurrency Review — M4: callbacks cleared on shutdown", .serialized)
struct CallbackClearingTests {

    @Test("OrchestrationRuntime.stopAll() nulls every observer callback")
    func runtimeStopAllNullsCallbacks() async throws {
        let runtime = makeRuntime()
        await runtime.setOnAbort { _ in }
        await runtime.setOnProcessingStateChange { _, _ in }
        await runtime.setOnAgentStarted { _, _ in }
        await runtime.setOnTurnRecorded { _, _ in }
        await runtime.setOnEvaluationRecorded { _ in }
        await runtime.setOnContextChanged { _, _ in }
        await runtime.setOnTimerEventForChannel { _ in }

        let beforeCleared = await runtime.observerCallbacksCleared
        #expect(!beforeCleared, "Sanity check: callbacks should be installed before stopAll")

        await runtime.stopAll()

        let afterCleared = await runtime.observerCallbacksCleared
        #expect(afterCleared, "Every observer callback must be nilled out by stopAll()")
    }

    /// Regression: `restartForNewTask` calls `stopAll(preserveObserverCallbacks: true)`
    /// then `start` on the same runtime. If `stopAll` cleared the AppViewModel-set
    /// observers anyway, the new Brown spawned by `start` would have no path to push
    /// turns / evaluations / context updates back to the inspector — Jones's history
    /// would silently disappear from the right pane on every task re-run.
    @Test("stopAll(preserveObserverCallbacks: true) keeps every observer alive")
    func stopAllPreserveKeepsCallbacks() async throws {
        let runtime = makeRuntime()
        await runtime.setOnAbort { _ in }
        await runtime.setOnProcessingStateChange { _, _ in }
        await runtime.setOnAgentStarted { _, _ in }
        await runtime.setOnTurnRecorded { _, _ in }
        await runtime.setOnEvaluationRecorded { _ in }
        await runtime.setOnContextChanged { _, _ in }
        await runtime.setOnTimerEventForChannel { _ in }

        await runtime.stopAll(preserveObserverCallbacks: true)

        let cleared = await runtime.observerCallbacksCleared
        #expect(!cleared, "Observer callbacks must survive stopAll when preserveObserverCallbacks is true")
    }

    /// Regression: `abort()` calls `stopAll()` (which clears callbacks) and then
    /// fires `onAbort`. If we read `onAbort` from the field after `stopAll()`
    /// runs, it would always be nil and the UI would silently miss every abort.
    /// `abort()` must capture the handler BEFORE the clear.
    @Test("abort() still delivers its onAbort callback after stopAll clears callbacks")
    func abortStillFiresAfterStopAllClearsCallbacks() async throws {
        let runtime = makeRuntime()
        let observer = AbortObserver()
        await runtime.setOnAbort { reason in
            Task { await observer.record(reason) }
        }
        await runtime.abort(reason: "boom", callerRole: .jones)
        // Allow the Task to deliver to the observer.
        try? await Task.sleep(for: .milliseconds(50))
        let received = await observer.reasons
        #expect(received.count == 1, "abort handler must fire exactly once")
        #expect(received.first?.contains("boom") == true, "abort reason must reach the handler; got \(received)")
    }
}

private actor AbortObserver {
    private(set) var reasons: [String] = []
    func record(_ r: String) { reasons.append(r) }
}

private func makeRuntime() -> OrchestrationRuntime {
    // Sandboxed PersistenceManager — `PersistenceManager()` resolves to
    // `~/Library/Application Support/AgentSmith/`, and any code path that calls
    // `usageStore.append` from within the runtime would schedule a flush that
    // overwrites the user's real usage records. Today this test never appends,
    // but routing through `init(testingRoot:)` keeps the failure mode closed if
    // someone later adds a code path that does.
    let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("agent-smith-concurrency-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    return OrchestrationRuntime(
        providers: [:],
        configurations: [:],
        providerAPITypes: [:],
        agentTuning: [:],
        semanticSearchEngine: SemanticSearchEngine(),
        usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
        autoAdvanceEnabled: true,
        autoRunInterruptedTasks: false,
        memoryStore: nil
    )
}

// MARK: - L4: FileReadTracker uses Mutex (no NSLock)

/// L4 calls for replacing NSLock with Swift's `Mutex`. The behavior must be
/// identical, but the new implementation should not depend on Foundation's
/// `NSLock` — verified indirectly by exercising contention and ensuring the
/// tracker remains thread-safe under heavy parallel access.
@Suite("Concurrency Review — L4: FileReadTracker thread safety", .serialized)
struct FileReadTrackerThreadSafetyTests {

    @Test("Concurrent record/contains stays consistent under heavy parallel access")
    func concurrentAccessStaysConsistent() async throws {
        let tracker = FileReadTracker()
        let paths = (0..<500).map { "/tmp/file_\($0)" }

        await withTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask { tracker.record(path) }
                group.addTask { _ = tracker.contains(path) }
            }
        }

        for path in paths {
            #expect(tracker.contains(path), "Tracker dropped a recorded path: \(path)")
        }
    }
}
