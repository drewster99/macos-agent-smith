import SwiftUI
import Synchronization

/// Fixed geometry for the transcript split, file-scoped so the numbers live with the one view
/// that uses them instead of traveling through an initializer into `@State`.
nonisolated private enum TranscriptSplitMetrics {
    /// Floor for the task-transcript (top) pane.
    static let minTopHeight: CGFloat = 120
    /// Where the divider rests before the user first drags it.
    static let initialTopHeight: CGFloat = 240
    /// Floor for the session-transcript (bottom) pane. When the window can no longer honor
    /// both floors, the bottom pane keeps its floor and the top pane yields first; below both
    /// floors combined, the bottom pane absorbs the shortfall (both are scroll views, so
    /// compressing is safe — the old split overflowed the column instead).
    static let minBottomHeight: CGFloat = 200
    /// Vertical extent of the divider's hit band (hairline plus padding), reserved out of the
    /// height the two panes share.
    static let dividerExtent: CGFloat = 8
    /// The split's minimum height, reported whatever its panes contain. A CONSTANT on purpose —
    /// see `TranscriptSplitLayout`.
    static let minimumHeight: CGFloat = minTopHeight + dividerExtent
}

/// The two stacked transcripts with a draggable divider — a pure-SwiftUI replacement for
/// `VSplitView`.
///
/// `VSplitView` is backed by AppKit's `NSSplitView`, and nesting one inside the detail column
/// made the column rigid at the WINDOW level: the bridged panes participate in the window's
/// AppKit constraint solving directly, outranking the sidebar's holding priority. With the
/// sidebar AND the inspector open, the center column had to compress — and the layout engine
/// resolved the conflict by pushing the SIDEBAR off-screen instead. A SwiftUI-only split exerts
/// no constraint pressure of its own: its width is always exactly what the column proposes, so
/// the flanking columns can never be squeezed on its behalf.
///
/// The pane heights are resolved INSIDE the layout pass, from the height the split is given, and
/// the split's minimum size is a constant. It used to measure its own height with
/// `onGeometryChange`, store it in `@State`, and size the top pane with a rigid `frame(height:)`
/// derived from that state — which made the detail column's minimum height a function of the
/// column's own last measured height. During the inspector-open layout loop (2026-10-10; root
/// cause and fix in `InspectorSidePane`) that minimum was measured cycling 552 → 512 → 632 pt on
/// successive passes: not the loop's cause, but one more answer that changed every time AppKit
/// asked it. A size answer must never depend on a size measured in an earlier pass.
struct TranscriptVerticalSplit<Top: View, Bottom: View>: View {
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom

    /// The top pane's height as last set by a divider drag. Clamped at LAYOUT time rather than
    /// here, so a value a smaller window forced down springs back when the window regrows.
    @State private var topPaneHeight: CGFloat = TranscriptSplitMetrics.initialTopHeight
    /// What the last layout pass resolved, for a drag to start from. A plain reference, never
    /// observed: the layout writes it, and a write that invalidated the layout that made it is
    /// exactly the loop this view exists to avoid.
    @State private var resolved = TranscriptSplitResolvedHeights()

    var body: some View {
        TranscriptSplitLayout(preferredTopHeight: topPaneHeight, resolved: resolved) {
            top
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TranscriptSplitDivider(
                renderedTopHeight: { resolved.topHeight ?? topPaneHeight },
                onAdjust: { proposed in
                    let maxTop = resolved.maxTopHeight ?? .infinity
                    topPaneHeight = min(max(proposed, TranscriptSplitMetrics.minTopHeight), maxTop)
                }
            )
            bottom
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The heights `TranscriptSplitLayout` resolved in its last pass. Nil until the first pass.
/// `Sendable` because a `Layout` is; the lock is uncontended (layout and gestures both run on the
/// main thread) and only makes that safe to state.
nonisolated private final class TranscriptSplitResolvedHeights: Sendable {
    private let heights = Mutex<(top: CGFloat?, maxTop: CGFloat?)>((nil, nil))

    var topHeight: CGFloat? { heights.withLock { $0.top } }
    var maxTopHeight: CGFloat? { heights.withLock { $0.maxTop } }

    func record(top: CGFloat, maxTop: CGFloat) {
        heights.withLock { $0 = (top, maxTop) }
    }
}

/// Stacks top pane, divider and bottom pane, dividing the height it is GIVEN: the top pane gets the
/// preferred height clamped so both panes keep their floors, and the bottom pane takes the rest.
///
/// Its size answers never depend on its subviews' heights or on anything measured in an earlier
/// pass: it fills the proposal, and its minimum height is `TranscriptSplitMetrics.minimumHeight`.
private struct TranscriptSplitLayout: Layout {
    let preferredTopHeight: CGFloat
    let resolved: TranscriptSplitResolvedHeights

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max()
            ?? 0
        let height = proposal.height.map { max($0, TranscriptSplitMetrics.minimumHeight) }
            ?? preferredTopHeight + TranscriptSplitMetrics.dividerExtent + TranscriptSplitMetrics.minBottomHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let heights = Self.paneHeights(total: bounds.height, preferredTop: preferredTopHeight)
        resolved.record(top: heights.top, maxTop: heights.maxTop)
        var y = bounds.minY
        subviews[0].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: heights.top))
        y += heights.top
        subviews[1].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: TranscriptSplitMetrics.dividerExtent))
        y += TranscriptSplitMetrics.dividerExtent
        subviews[2].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: heights.bottom))
    }

    /// Divides `total`: the top pane keeps at least its floor and yields first, so the bottom pane
    /// keeps its floor while there is room for both; below that the bottom pane absorbs the rest.
    static func paneHeights(total: CGFloat, preferredTop: CGFloat) -> (top: CGFloat, bottom: CGFloat, maxTop: CGFloat) {
        let available = max(0, total - TranscriptSplitMetrics.dividerExtent)
        let maxTop = max(TranscriptSplitMetrics.minTopHeight, available - TranscriptSplitMetrics.minBottomHeight)
        let top = min(max(preferredTop, TranscriptSplitMetrics.minTopHeight), maxTop)
        return (top, max(0, available - top), maxTop)
    }
}

/// The divider: a hairline centered in a hit band the height of `dividerExtent`. Dragging it
/// adjusts the top pane's height through `onAdjust`.
private struct TranscriptSplitDivider: View {
    /// The top pane's height as last laid out — the base a drag's translation adds to.
    let renderedTopHeight: () -> CGFloat
    let onAdjust: (CGFloat) -> Void

    /// The rendered top height captured at drag start. The translation is applied to this, not to
    /// the live value, so each event is measured from where the drag began rather than
    /// compounding onto its own effect.
    @State private var dragBaseHeight: CGFloat?

    var body: some View {
        Divider()
            .padding(.vertical, (TranscriptSplitMetrics.dividerExtent - 1) / 2)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                // GLOBAL coordinate space, same reasoning as TaskOverlayBar's grab handle: the
                // divider moves with the drag, so a local-space translation would be measured
                // from an origin its own effect keeps moving.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragBaseHeight ?? renderedTopHeight()
                        if dragBaseHeight == nil { dragBaseHeight = base }
                        onAdjust(base + value.translation.height)
                    }
                    .onEnded { _ in
                        dragBaseHeight = nil
                    }
            )
    }
}
