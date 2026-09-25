import Testing
import Foundation
@testable import AgentSmithKit

@Suite("Frame-batched main-actor queue", .serialized)
@MainActor
struct FrameBatchedMainActorQueueTests {

    /// Records what the batched work observed, on the main actor.
    @MainActor final class Recorder {
        var order: [Int] = []
        /// Bumped by a main-queue block scheduled from inside the first work item: work that runs in
        /// the SAME main-queue turn as that item still sees the old value.
        var turnMarker = 0
        var markersSeen: [Int] = []
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Work enqueued from other threads runs in enqueue order, all in one main-queue turn")
    func oneTurnInOrder() async {
        let queue = FrameBatchedMainActorQueue(interval: .milliseconds(60))
        let recorder = Recorder()
        await Task.detached {
            for index in 0..<5 {
                // Spaced out, so per-item main-queue hops would interleave with the marker block.
                try? await Task.sleep(for: .milliseconds(3))
                queue.enqueue {
                    if index == 0 {
                        DispatchQueue.main.async { MainActor.assumeIsolated { recorder.turnMarker = 1 } }
                    }
                    recorder.order.append(index)
                    recorder.markersSeen.append(recorder.turnMarker)
                }
            }
        }.value
        await waitUntil { recorder.order.count == 5 }
        #expect(recorder.order == [0, 1, 2, 3, 4])
        #expect(recorder.markersSeen == [0, 0, 0, 0, 0], "no main-queue turn ran between items of one batch")
    }

    @Test("Work enqueued while a batch runs goes to the next batch")
    func enqueuedDuringBatchRunsLater() async {
        let queue = FrameBatchedMainActorQueue(interval: .milliseconds(20))
        let recorder = Recorder()
        queue.enqueue {
            DispatchQueue.main.async { MainActor.assumeIsolated { recorder.turnMarker = 1 } }
            recorder.order.append(0)
            queue.enqueue {
                recorder.order.append(1)
                recorder.markersSeen.append(recorder.turnMarker)
            }
        }
        await waitUntil { recorder.order.count == 2 }
        #expect(recorder.order == [0, 1])
        #expect(recorder.markersSeen == [1], "ran in a later turn, after the batch that enqueued it")
    }

    @Test("Nothing runs before the interval has passed")
    func waitsForInterval() async {
        let queue = FrameBatchedMainActorQueue(interval: .milliseconds(200))
        let recorder = Recorder()
        queue.enqueue { recorder.order.append(0) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.order.isEmpty)
        await waitUntil { recorder.order.count == 1 }
        #expect(recorder.order == [0])
    }
}
