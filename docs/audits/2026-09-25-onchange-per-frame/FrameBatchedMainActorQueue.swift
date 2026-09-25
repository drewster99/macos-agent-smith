import Foundation
import Synchronization

/// Applies UI-state updates in batches: everything enqueued within one interval runs, in enqueue
/// order, in ONE main-queue turn.
///
/// Why: SwiftUI logs "onChange(of:) action tried to update multiple times per frame" whenever a
/// watched value changes in more than one main-queue turn inside a single frame. Changing it several
/// times inside ONE turn does not trigger it, and neither does another key of the same dictionary
/// changing (both measured with a standalone harness, 2026-09-25). The inspector watches values fed
/// by many independent runtime callbacks, each of which used to hop to the main actor on its own,
/// so a single tool call changed several watched values across several turns of one frame.
///
/// The interval is deliberately LONGER than a frame. A flush is scheduled by the first enqueue after
/// the previous flush, so two flushes are always at least one interval apart — and therefore never
/// in the same frame — on any display at 40 Hz or faster. The cost is up to one interval of display
/// latency. A timer, not a display link: a display link stops while the display sleeps, which would
/// hold the view model's mirrors of runtime state stale until it woke.
///
/// Enqueue from any thread. The work always runs on the main actor.
public final class FrameBatchedMainActorQueue: Sendable {
    public typealias Work = @MainActor @Sendable () -> Void

    /// Longer than one frame at 40 Hz and above; see the type comment.
    public static let defaultInterval: Duration = .milliseconds(25)

    private let interval: Duration
    private let pending = Mutex<[Work]>([])

    public init(interval: Duration = FrameBatchedMainActorQueue.defaultInterval) {
        self.interval = interval
    }

    /// Queues `work` for the next batch, scheduling that batch if none is pending.
    public func enqueue(_ work: @escaping Work) {
        let startsBatch = pending.withLock { queue in
            queue.append(work)
            return queue.count == 1
        }
        guard startsBatch else { return }
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            MainActor.assumeIsolated { runBatch() }
        }
    }

    /// Runs everything queued so far, in order. Work enqueued while the batch runs goes to the next
    /// batch, so a batch never grows while it executes.
    @MainActor
    private func runBatch() {
        let batch = pending.withLock { queue in
            let taken = queue
            queue.removeAll()
            return taken
        }
        for work in batch { work() }
    }
}

