import SwiftUI
import AgentSmithKit

/// Compact 4×2 cost summary placed above the Agents column in the inspector.
///
/// Reads `sharedAppState.costBoardSnapshot` — never queries the `UsageStore` itself.
/// The `CostBoard` actor maintains the snapshot incrementally (O(1) per new
/// `UsageRecord`) and rolls calendar boundaries on its own watcher timer.
///
/// Windows are anchored on a **local-time, Sunday-start** Gregorian calendar
/// (see `CostBoard.calendar`):
///
/// | Row        | Current                         | Prior                          |
/// | ---------- | ------------------------------- | ------------------------------ |
/// | Today      | local midnight → now            | yesterday 00:00 → 24:00        |
/// | This week  | last Sunday 00:00 → now         | the prior Sun-Sat full week    |
/// | This month | 1st-of-month 00:00 → now        | the prior full calendar month  |
/// | This year  | Jan 1 00:00 → now               | the prior full calendar year   |
///
/// Dollar amounts are rendered with `.monospacedDigit()` and `String(format: "$%.4f", …)`
/// so the columns never reflow as digit widths change.
struct CostEstimateSection: View {
    let snapshot: CostBoard.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cost Estimate")
                .font(AppFonts.sectionHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    Text("Current")
                        .gridColumnAlignment(.trailing)
                    Text("Prior")
                        .gridColumnAlignment(.trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Today's current value renders in orange to draw the eye — it's
                // the line the user checks most often. Other rows stay neutral.
                row("Today", current: snapshot.todayCurrent, prior: snapshot.todayPrior, currentColor: .orange)
                row("This week", current: snapshot.weekCurrent, prior: snapshot.weekPrior, currentColor: .primary)
                row("This month", current: snapshot.monthCurrent, prior: snapshot.monthPrior, currentColor: .primary)
                row("This year", current: snapshot.yearCurrent, prior: snapshot.yearPrior, currentColor: .primary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()
        }
    }

    @ViewBuilder
    private func row(_ label: String, current: Double, prior: Double, currentColor: Color) -> some View {
        GridRow {
            Text(label)
                .font(.callout)
            Text(format(current))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(currentColor)
            Text(format(prior))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// Fixed two-decimal display. Two decimals keeps the columns readable at a
    /// glance — short-window numbers below a cent show as $0.00, which is the
    /// honest signal that nothing meaningful was spent yet.
    private func format(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
