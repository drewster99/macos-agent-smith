import SwiftUI

/// One context entry rendered with an optional inter-row divider above it. The parent
/// VStack uses `spacing: 10`; this view collapses to a single child per ForEach iteration
/// and toggles the divider's height/opacity rather than its presence so SwiftUI never
/// has to reconcile a structural shape change.
struct ContextEntryDividedRow: View {
    let entry: String
    /// True for every iteration after the first; drives the visible separator above the
    /// entry. When false the divider collapses to zero height (no `if` in the body).
    let showsDivider: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: showsDivider ? 10 : 0) {
            Divider()
                .opacity(showsDivider ? 0.4 : 0)
                .frame(height: showsDivider ? 1 : 0)
            ContextEntryView(entry: entry)
        }
    }
}

/// Plain-text variant for the New Task banner's "Memories" section, which renders the
/// entry as a `Text` rather than the header+body block produced by `contextEntryView`.
struct ContextMemoryDividedRow: View {
    let entry: String
    let showsDivider: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: showsDivider ? 10 : 0) {
            Divider()
                .opacity(showsDivider ? 0.4 : 0)
                .frame(height: showsDivider ? 1 : 0)
            Text(entry)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
