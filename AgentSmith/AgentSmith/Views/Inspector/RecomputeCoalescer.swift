import SwiftUI

/// Collapses many change signals into ONE cache rebuild per frame.
///
/// The inspector's views keep a `@State` cache rebuilt by a fan of `.onChange` handlers, and several
/// fire together as a matter of course: one completed tool call changes the message list, the
/// processing set, the executing-tools map and the security-evaluation registry at the same
/// instant. Each handler then rebuilt the cache and scheduled its own assignment.
///
/// What this buys is the REBUILDS, and ONLY the rebuilds — measured, not assumed. A standalone
/// harness (six signals, six watchers, 60s) put it at 30,989 rebuilds down to 14,729, and 15.8s of
/// CPU down to 7.5s. Over the same run, body evaluations were 34,474 in BOTH arms and `@State`
/// writes were 185,934 vs 88,374 — so twice the writes produced bit-identical render counts.
/// SwiftUI marks dependents dirty and renders once per pass regardless; this changes none of that.
/// Do not reach for it to reduce RENDERING.
///
/// It DOES silence SwiftUI's "onChange/task action tried to update multiple times per frame"
/// logging, because the flush is delayed a full frame (`frameInterval`): every signal arriving in
/// that window — across all the main-queue turns a frame contains — folds into one rebuild, so the
/// `@State` write it performs happens at most once per frame. (The earlier version drained on the
/// next main-queue TURN, and a frame holds several turns, so a card watching ~11 inputs still
/// rebuilt several times per frame and still tripped the warning.)
///
/// It therefore pays only where the REBUILD is expensive and the watchers fire TOGETHER. Where the
/// shared work is a lookup, or the watchers write unrelated state, it buys nothing.
///
/// And it is only safe where a ONE-TURN DELAY is safe. `ChannelLogView` has the ideal fan-out on
/// paper — two of its three cache watchers fire on every appended message — but its cache feeds a
/// `ForEach` that `proxy.scrollTo` targets in a sibling watcher on the same key, so deferring the
/// rebuild would scroll to a row that does not exist yet and break auto-scroll on every message.
/// It dedupes with a synchronous signature guard instead. Check what reads the cache in the SAME
/// pass before reaching for this.
///
/// LAST writer wins, deliberately. Most of these rebuilds read live view-model state, but not all:
/// `InspectorView`'s cards take `roleMessages` as a `let` on the view struct, so a closure captures
/// the generation it was created in. Keeping the FIRST closure and dropping the rest would pin that
/// stale capture and write it after newer messages had already arrived — with nothing to re-fire
/// until some unrelated input changed. Keeping the last means the freshest capture is the one that
/// runs.
///
/// A reference type held by `@State` on purpose. Mutating its contents is not a `@State` mutation,
/// so it neither invalidates the view nor trips this project's rule against mutating state inside
/// an `.onChange` closure; the stored reference itself never changes. The pending block always
/// runs and clears the slot before invoking the work, so no failure can wedge it.
@MainActor
final class RecomputeCoalescer {
    private var pending: (@MainActor () -> Void)?

    init() {}

    /// One frame at 60 Hz. The flush is delayed by this so EVERY signal arriving within the window —
    /// across as many main-queue turns as a frame contains — collapses into ONE rebuild. See
    /// `schedule`.
    private static let frameInterval: TimeInterval = 1.0 / 60.0

    /// Runs the most recently supplied `work` at most once per frame, absorbing every signal that
    /// arrives in the window. A plain `DispatchQueue.main.async` drains on the NEXT main-queue turn,
    /// and a frame contains several turns — so a card watching ~11 inputs still rebuilt several times
    /// per frame when a burst touched several of them, which is precisely SwiftUI's "onChange action
    /// tried to update multiple times per frame". Delaying by one frame makes the rebuild — and thus
    /// the `@State` write it performs — happen at most once per frame, which silences the warning.
    /// Safe here because a one-frame lag on inspector display is imperceptible; do NOT use where a
    /// sibling reads the rebuilt value in the SAME pass (`ChannelLogView`'s auto-scroll — see below).
    func schedule(_ work: @escaping @MainActor () -> Void) {
        let alreadyScheduled = pending != nil
        pending = work
        guard !alreadyScheduled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.frameInterval) { [self] in
            let work = pending
            pending = nil
            work?()
        }
    }
}
