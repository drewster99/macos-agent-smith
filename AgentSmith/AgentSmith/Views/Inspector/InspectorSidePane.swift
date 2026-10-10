import SwiftUI

/// Fixed geometry for the inspector pane — the same range the native inspector column used.
private enum InspectorPaneMetrics {
    static let minWidth: CGFloat = 280
    static let initialWidth: CGFloat = 320
    static let maxWidth: CGFloat = 460
    /// Horizontal extent of the divider's hit band (hairline plus padding).
    static let dividerExtent: CGFloat = 8
}

/// The window's inspector as an app-owned trailing pane beside the main content, instead of
/// SwiftUI's `.inspector` column.
///
/// Why not `.inspector`: on macOS 26/27, a `NavigationSplitView` with the native inspector column
/// can fall into an endless window-layout loop when the inspector opens — AppKit's split view and
/// SwiftUI's column hosting views never agree on the column widths, so the window re-lays itself
/// out (every transcript row with it) about every 313 ms until AppKit throws "more Update
/// Constraints in Window passes than there are views in the window". Measured here 2026-10-10 in a
/// 1243 pt window: the split's width alternated 923 ↔ 969.5 pt with no app state changing at all,
/// and it kept looping with the toolbar removed, with explicit column widths, and with constant
/// minimum/ideal size answers. It is a known platform bug (a three-`Text` repro is on Apple's
/// forums); a pane the app lays out itself is not affected, because AppKit sees one SwiftUI view
/// whose width it never has to negotiate.
struct InspectorSidePane<Content: View, Inspector: View>: View {
    let isPresented: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let inspector: Inspector

    /// The pane's width as last set by a divider drag.
    @State private var width: CGFloat = InspectorPaneMetrics.initialWidth

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented {
                InspectorPaneDivider(width: width, onAdjust: { proposed in
                    width = min(max(proposed, InspectorPaneMetrics.minWidth), InspectorPaneMetrics.maxWidth)
                })
                inspector
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(AppColors.secondaryBackground)
            }
        }
    }
}

/// The divider between the content and the inspector: a hairline centered in a hit band. Dragging
/// it LEFT widens the inspector.
private struct InspectorPaneDivider: View {
    /// The inspector's current width — the base a drag's translation is applied to.
    let width: CGFloat
    let onAdjust: (CGFloat) -> Void

    /// The width captured at drag start, so each event is measured from where the drag began
    /// rather than compounding onto its own effect.
    @State private var dragBaseWidth: CGFloat?

    var body: some View {
        Divider()
            .padding(.horizontal, (InspectorPaneMetrics.dividerExtent - 1) / 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                // GLOBAL coordinate space: the divider moves with the drag, so a local-space
                // translation would be measured from an origin its own effect keeps moving.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragBaseWidth ?? width
                        if dragBaseWidth == nil { dragBaseWidth = base }
                        onAdjust(base - value.translation.width)
                    }
                    .onEnded { _ in
                        dragBaseWidth = nil
                    }
            )
            .accessibilityLabel("Inspector divider")
    }
}
