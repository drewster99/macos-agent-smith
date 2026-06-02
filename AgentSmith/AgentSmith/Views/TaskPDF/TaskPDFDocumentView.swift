import SwiftUI
import AgentSmithKit

/// SwiftUI layout rendered to PDF by `TaskPDFExporter`. The document is exposed as an
/// ordered list of `pdfBlocks()` so the exporter can paginate *between* blocks — a page
/// break never cuts through the middle of a paragraph (only a single block taller than a
/// full page is sliced, which is rare).
///
/// Sections are gated by `TaskPDFFieldOptions`; the title and (for terminal tasks) the
/// completion date/time are always shown so the document is self-identifying. Markdown
/// bodies reuse `MarkdownText` so the PDF matches what the user sees in-app.
struct TaskPDFDocumentView: View {
    let task: AgentTask
    let options: TaskPDFFieldOptions
    let tokens: AppViewModel.TaskTokenTotals?
    let cost: Double?
    let generatedAt: Date

    private static let timestampStyle = Date.FormatStyle(date: .abbreviated, time: .standard)
    private static let bodyFont = AppFonts.pdfBody

    /// Single-view rendering (used for previews / non-paginated contexts). The exporter
    /// uses `pdfBlocks()` directly instead of this.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(pdfBlocks().enumerated()), id: \.offset) { _, block in
                block
            }
        }
        .foregroundStyle(.black)
    }

    /// The document split into independently-paginatable blocks, top to bottom.
    func pdfBlocks() -> [AnyView] {
        var blocks: [AnyView] = [AnyView(header())]

        if metadataRowsPresent {
            blocks.append(AnyView(metadataGrid()))
            blocks.append(AnyView(Divider()))
        }

        if options.description, !task.description.isEmpty {
            blocks.append(contentsOf: sectionBlocks(title: "Description", body: task.description))
        }
        if options.summary, let summary = task.summary, !summary.isEmpty {
            blocks.append(contentsOf: sectionBlocks(title: "Summary", body: summary))
        }
        if options.result, let result = task.result, !result.isEmpty {
            blocks.append(contentsOf: sectionBlocks(title: resultTitle, body: result))
        }

        blocks.append(AnyView(Divider()))
        blocks.append(AnyView(footer()))
        return blocks
    }

    // MARK: - Header

    @ViewBuilder
    private func header() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(AppFonts.pdfTitle)
            Text(headerSubtitle)
                .font(AppFonts.pdfBody)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Completed Jun 1, 2026 at 3:04:05 PM" for terminal tasks (the always-shown
    /// completion stamp), otherwise a human-readable status label.
    private var headerSubtitle: String {
        switch task.status {
        case .completed:
            if let completedAt = task.completedAt {
                return "Completed \(completedAt.formatted(Self.timestampStyle))"
            }
            return "Completed"
        case .failed:
            if let completedAt = task.completedAt {
                return "Failed \(completedAt.formatted(Self.timestampStyle))"
            }
            return "Failed"
        case .awaitingReview: return "Awaiting Review"
        case .running:        return "Running"
        case .paused:         return "Paused"
        case .interrupted:    return "Interrupted"
        case .pending:        return "Pending"
        case .scheduled:      return "Scheduled"
        }
    }

    private var resultTitle: String {
        task.status == .failed ? "Error" : "Result"
    }

    // MARK: - Metadata

    /// Whether the metadata grid will actually render at least one row. Gates the grid +
    /// its divider so a selected-but-empty field set doesn't leave a stray rule under the
    /// header.
    private var metadataRowsPresent: Bool {
        (options.startTime && task.startedAt != nil)
        || (options.elapsedTime && task.completedAt != nil && task.elapsedDisplayString != nil)
        || (options.tokens && (tokens?.total ?? 0) > 0)
        || (options.cost && (cost ?? 0) > 0)
    }

    @ViewBuilder
    private func metadataGrid() -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if options.startTime, let startedAt = task.startedAt {
                metadataRow("Started", startedAt.formatted(Self.timestampStyle))
            }
            // Elapsed is only meaningful in a static document once the task has finished;
            // a running task's "elapsed" would be frozen at export time and misleading.
            if options.elapsedTime, task.completedAt != nil, let elapsed = task.elapsedDisplayString {
                metadataRow("Elapsed", elapsed)
            }
            if options.tokens, let tokens, tokens.total > 0 {
                metadataRow("Tokens", tokens.formattedLine())
            }
            if options.cost, let cost, cost > 0 {
                metadataRow("Cost", String(format: "$%.2f", cost))
            }
        }
        .font(AppFonts.pdfBody)
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

    /// Builds the blocks for one section: the title is grouped with the first paragraph so
    /// a section heading is never orphaned at the bottom of a page; remaining paragraphs
    /// become their own blocks so long bodies break between paragraphs.
    private func sectionBlocks(title: String, body: String) -> [AnyView] {
        let chunks = Self.splitMarkdownChunks(body)
        guard let first = chunks.first else {
            return [AnyView(
                Text(title)
                    .font(AppFonts.pdfSectionHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
            )]
        }
        var result: [AnyView] = [AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppFonts.pdfSectionHeader)
                MarkdownText(content: first, baseFont: Self.bodyFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )]
        for chunk in chunks.dropFirst() {
            result.append(AnyView(
                MarkdownText(content: chunk, baseFont: Self.bodyFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            ))
        }
        return result
    }

    /// Splits markdown into paragraph-level chunks for pagination: blank lines separate
    /// paragraphs, while fenced code blocks (``` … ```) are kept whole even when they
    /// contain blank lines. Consecutive non-blank lines (lists, tables) stay together.
    static func splitMarkdownChunks(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [String] = []
        var current: [String] = []
        var inFence = false

        func flush() {
            if !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    current.append(line)
                    inFence = false
                    flush()
                } else {
                    flush()
                    inFence = true
                    current.append(line)
                }
                continue
            }
            if inFence {
                current.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            current.append(line)
        }
        flush()
        return chunks
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer() -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Agent Smith · generated \(generatedAt.formatted(Self.timestampStyle))")
            Spacer()
            Text("ID: \(task.id.uuidString)")
        }
        .font(AppFonts.pdfFooter)
        .foregroundStyle(.tertiary)
    }
}
