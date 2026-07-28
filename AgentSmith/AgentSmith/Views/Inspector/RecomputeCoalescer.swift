import SwiftUI

/// Collapses many change signals into ONE cache rebuild per main-queue turn.
///
/// The inspector's views keep a `@State` cache rebuilt by a dozen `.onChange` handlers, and several
/// fire together as a matter of course: one completed tool call changes the message list, the
/// processing set, the executing-tools map and the security-evaluation registry at the same
/// instant. Each handler then rebuilt the cache and scheduled its own assignment.
///
/// What this reliably buys is the REBUILDS, not the assignments: twelve passes over the message
/// arrays collapse to one, and the eleven discarded results were pure waste. The assignments were
/// already largely absorbed by the `if cached != next` guard, since same-pass rebuilds compute
/// identical values — so treat any reduction in SwiftUI's "tried to update multiple times per
/// frame" logging as a welcome side effect rather than the guarantee. A signal arriving in a
/// LATER turn of the same frame still gets its own rebuild; the coalescing unit is a queue drain,
/// not a frame, and no main-queue mechanism can promise otherwise.
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

    /// Runs the most recently supplied `work` on the next main-queue turn, absorbing any signals
    /// that arrive before it drains.
    func schedule(_ work: @escaping @MainActor () -> Void) {
        let alreadyScheduled = pending != nil
        pending = work
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [self] in
            let work = pending
            pending = nil
            work?()
        }
    }
}
