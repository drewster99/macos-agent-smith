import SwiftUI

/// Fixed geometry for the transcript split, file-scoped so the numbers live with the one view
/// that uses them instead of traveling through an initializer into `@State`.
private enum TranscriptSplitMetrics {
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
}

/// The two stacked transcripts with a draggable divider — a pure-SwiftUI replacement for
/// `VSplitView`.
///
/// `VSplitView` is backed by AppKit's `NSSplitView`, and nesting one inside the detail column
/// made the column rigid at the WINDOW level: the bridged panes participate in the window's
/// AppKit constraint solving directly, outranking the sidebar's holding priority. With the
/// sidebar AND the inspector open, the center column had to compress — and the layout engine
/// resolved the conflict by pushing the SIDEBAR off-screen instead. With only one flanking
/// column there was enough slack to hide the problem, which is why the push appeared only with
/// both open. A SwiftUI-only split exerts no constraint pressure of its own: its width is
/// always exactly what the column proposes, so the flanking columns can never be squeezed on
/// its behalf. This is the same physics the detail column had before the two-pane refactor,
/// when it never pushed the sidebar.
struct TranscriptVerticalSplit<Top: View, Bottom: View>: View {
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom

    /// The top pane's height as last set by a divider drag. Clamped at RENDER time rather than
    /// here, so a value a smaller window forced down springs back when the window regrows.
    @State private var topPaneHeight: CGFloat = TranscriptSplitMetrics.initialTopHeight
    /// The split's measured height; zero until the first layout pass lands.
    @State private var totalHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            top
                .frame(maxWidth: .infinity)
                .frame(height: resolvedTopHeight)
            TranscriptSplitDivider(
                resolvedTopHeight: resolvedTopHeight,
                onAdjust: { topPaneHeight = clampedTopHeight($0) }
            )
            bottom
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { newHeight in
            totalHeight = newHeight
        })
    }

    /// The height the top pane renders at this pass: the user's chosen height clamped so both
    /// panes keep their floors within the measured total. Before the first measurement there is
    /// nothing to clamp against, and clamping against zero would collapse the pane to its floor
    /// for one frame.
    private var resolvedTopHeight: CGFloat {
        totalHeight > 0 ? clampedTopHeight(topPaneHeight) : topPaneHeight
    }

    private func clampedTopHeight(_ proposed: CGFloat) -> CGFloat {
        let availableForPanes = totalHeight - TranscriptSplitMetrics.dividerExtent
        let maxTop = max(TranscriptSplitMetrics.minTopHeight,
                         availableForPanes - TranscriptSplitMetrics.minBottomHeight)
        return min(max(proposed, TranscriptSplitMetrics.minTopHeight), maxTop)
    }
}

/// The divider: a hairline centered in a hit band the height of `dividerExtent`. Dragging it
/// adjusts the top pane's height through `onAdjust`.
private struct TranscriptSplitDivider: View {
    /// The top pane's height as currently rendered — the base a drag's translation adds to.
    let resolvedTopHeight: CGFloat
    let onAdjust: (CGFloat) -> Void

    /// `resolvedTopHeight` captured at drag start. The translation is applied to this, not to
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
                        if dragBaseHeight == nil { dragBaseHeight = resolvedTopHeight }
                        onAdjust((dragBaseHeight ?? resolvedTopHeight) + value.translation.height)
                    }
                    .onEnded { _ in
                        dragBaseHeight = nil
                    }
            )
    }
}
