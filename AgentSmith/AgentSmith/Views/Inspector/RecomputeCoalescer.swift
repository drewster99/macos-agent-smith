import SwiftUI

/// Collapses many change signals into ONE cache rebuild per frame.
///
/// The inspector's views keep a `@State` cache rebuilt by a dozen `.onChange` handlers, and several
/// of them fire in the SAME frame as a matter of course: one completed tool call changes the
/// message list, the processing set, the executing-tools map and the security-evaluation registry
/// at the same instant. Each handler then scheduled its own `DispatchQueue.main.async` assignment,
/// and SwiftUI logged `onChange(of:) action tried to update multiple times per frame` — once per
/// redundant assignment, several times a second under load.
///
/// Rebuilding once, after the frame's signals have all landed, is also strictly cheaper: every
/// intermediate rebuild was discarded by the very next one. The work skipped is the expensive part
/// — filtering message arrays, rebuilding row structs — not the assignment.
///
/// A reference type held by `@State` on purpose. Mutating its contents is not a `@State` mutation,
/// so it neither invalidates the view nor trips this project's rule against mutating state inside
/// an `.onChange` closure; the stored reference itself never changes.
@MainActor
final class RecomputeCoalescer {
    private var isScheduled = false

    init() {}

    /// Runs `work` on the next main-queue turn, unless a run is already pending — in which case
    /// this signal is absorbed by the run already coming, which will see its effect anyway because
    /// `work` reads current state rather than anything captured here.
    func schedule(_ work: @escaping @MainActor () -> Void) {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [self] in
            isScheduled = false
            work()
        }
    }
}
