import SwiftUI
import AgentSmithKit

/// SwiftUI layout rendered to PDF by `TaskPDFExporter`. Sections are gated by
/// `TaskPDFFieldOptions`; the title and (for terminal tasks) the completion date/time are
/// always shown so the document is self-identifying.
///
/// Markdown bodies reuse `MarkdownText` so the PDF matches what the user sees in-app.
struct TaskPDFDocumentView: View {
    let task: AgentTask
    let options: TaskPDFFieldOptions
    let tokens: AppViewModel.TaskTokenTotals?
    let cost: Double?
    let generatedAt: Date

    private static let timestampStyle = Date.FormatStyle(date: .abbreviated, time: .standard)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if options.hasAnyMetadata {
                metadataGrid
                Divider()
            }

            if options.description, !task.description.isEmpty {
                section(title: "Description", body: task.description)
            }

            if options.summary, let summary = task.summary, !summary.isEmpty {
                section(title: "Summary", body: summary)
            }

            if options.result, let result = task.result, !result.isEmpty {
                section(title: resultTitle, body: result)
            }

            Divider()
            footer
        }
        .foregroundStyle(.black)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.system(size: 22, weight: .bold))
            Text(headerSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Completed Jun 1, 2026 at 3:04:05 PM", "Failed …", or just the status for
    /// non-terminal tasks (the detail-view Save action can target any status).
    private var headerSubtitle: String {
        let statusWord = task.status == .failed ? "Failed" : "Completed"
        if task.status.isTerminal, let completedAt = task.completedAt {
            return "\(statusWord) \(completedAt.formatted(Self.timestampStyle))"
        }
        return task.status.rawValue.capitalized
    }

    private var resultTitle: String {
        task.status == .failed ? "Error" : "Result"
    }

    // MARK: - Metadata

    private var metadataGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if options.startTime, let startedAt = task.startedAt {
                metadataRow("Started", startedAt.formatted(Self.timestampStyle))
            }
            if options.elapsedTime, let elapsed = Self.elapsedTime(for: task) {
                metadataRow("Elapsed", elapsed)
            }
            if options.tokens, let tokens, Self.tokenTotal(tokens) > 0 {
                metadataRow("Tokens", Self.formatTokenLine(tokens))
            }
            if options.cost, let cost, cost > 0 {
                metadataRow("Cost", String(format: "$%.2f", cost))
            }
        }
        .font(.system(size: 12))
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .monospacedDigit()
        }
    }

    // MARK: - Sections

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            MarkdownText(content: body, baseFont: .system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Agent Smith · generated \(generatedAt.formatted(Self.timestampStyle))")
            Spacer()
            Text("ID: \(task.id.uuidString)")
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }

    // MARK: - Formatting helpers

    private static func tokenTotal(_ tokens: AppViewModel.TaskTokenTotals) -> Int {
        tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite
    }

    /// Mirrors `TaskDetailWindow.formatTokenLine` — "12,345 in   6,789 out   1,234 cached".
    private static func formatTokenLine(_ tokens: AppViewModel.TaskTokenTotals) -> String {
        let cached = tokens.cacheRead + tokens.cacheWrite
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let nIn = formatter.string(from: NSNumber(value: tokens.input)) ?? "\(tokens.input)"
        let nOut = formatter.string(from: NSNumber(value: tokens.output)) ?? "\(tokens.output)"
        let nCached = formatter.string(from: NSNumber(value: cached)) ?? "\(cached)"
        if cached > 0 {
            return "\(nIn) in   \(nOut) out   \(nCached) cached"
        }
        return "\(nIn) in   \(nOut) out"
    }

    /// Mirrors `TaskDetailWindow.elapsedTime` — human-readable `startedAt → completedAt`.
    private static func elapsedTime(for task: AgentTask) -> String? {
        guard let start = task.startedAt else { return nil }
        let end = task.completedAt ?? Date()
        let interval = end.timeIntervalSince(start)
        guard interval >= 0 else { return nil }

        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}
