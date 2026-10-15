import SwiftUI
import AgentSmithKit

// MARK: - Drafts

/// A memory's text and tags as the user types them — a new memory's, or an edit of an existing one.
///
/// A reference the form writes into, so a keystroke re-renders only the form. Bound to the Memory
/// Browser's own state instead, every keystroke re-ran the browser and re-planned every row.
@Observable
final class MemoryDraft {
    var content: String
    /// Comma-separated, as typed.
    var tags: String

    init(content: String = "", tags: [String] = []) {
        self.content = content
        self.tags = tags.joined(separator: ", ")
    }

    /// The typed tags: split on commas, trimmed, blanks dropped.
    var tagList: [String] {
        tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Nothing to save: an empty or whitespace-only memory.
    var isBlank: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The memory being edited in the Memory Browser, and the edit so far.
struct MemoryEdit {
    let memoryID: UUID
    let draft: MemoryDraft

    init(memory: MemoryEntry) {
        memoryID = memory.id
        draft = MemoryDraft(content: memory.content, tags: memory.tags)
    }

    /// The same edit — not merely an edit of the same memory. A save or cancel that finishes after
    /// the user has moved on must not end the edit they moved on to.
    func isSameEdit(as other: MemoryEdit?) -> Bool {
        other?.draft === draft
    }
}

/// What a memory row can ask of the Memory Browser. Rows are hosted in AppKit table cells, out of
/// reach of the browser's SwiftUI state and environment, so everything they change goes through here.
struct MemoryListRowActions {
    let beginEditing: (MemoryEntry) -> Void
    let cancelEditing: (MemoryEdit) -> Void
    let saveEdit: (MemoryEdit) -> Void
    let requestDeletion: (UUID) -> Void
}

// MARK: - Rows

/// One memory in the Memory Browser's table.
nonisolated struct MemoryListRow: HostedTableRow, Sendable {
    let memory: MemoryEntry
    /// The latest search's score for this memory, when a search is showing.
    let similarity: Double?
    let isAlternate: Bool
    let isEditing: Bool

    var id: UUID { memory.id }

    /// Everything the row draws — never the embedding, which is large and never drawn.
    var renderKey: RenderKey {
        RenderKey(
            content: memory.content, source: memory.source, tags: memory.tags,
            createdAt: memory.createdAt, lastUpdatedAt: memory.lastUpdatedAt, lastUpdatedBy: memory.lastUpdatedBy,
            lastRetrievedAt: memory.lastRetrievedAt, retrievalCount: memory.retrievalCount,
            lastInjectedAt: memory.lastInjectedAt, injectionCount: memory.injectionCount,
            similarity: similarity, isAlternate: isAlternate, isEditing: isEditing
        )
    }

    struct RenderKey: Equatable, Sendable {
        let content: String
        let source: MemoryEntry.Source
        let tags: [String]
        let createdAt: Date
        let lastUpdatedAt: Date?
        let lastUpdatedBy: MemoryEntry.UpdateSource?
        let lastRetrievedAt: Date?
        let retrievalCount: Int
        let lastInjectedAt: Date?
        let injectionCount: Int
        let similarity: Double?
        let isAlternate: Bool
        let isEditing: Bool
    }

    /// The edit form's fixed height, or the content's wrapped lines plus the stat lines and buttons.
    var estimatedHeight: CGFloat {
        if isEditing { return Self.editingHeight }
        let tagsHeight = memory.tags.isEmpty ? 0 : Self.tagsLineHeight
        return Self.chromeHeight + tagsHeight
            + Self.contentLineHeight * CGFloat(EstimatedLines.count(in: memory.content))
    }

    private static var editingHeight: CGFloat { 230 }
    /// Three stat lines, the buttons, and the row's padding.
    private static var chromeHeight: CGFloat { 96 }
    private static var tagsLineHeight: CGFloat { 18 }
    private static var contentLineHeight: CGFloat { 17 }
}

/// One task summary in the Memory Browser's table.
nonisolated struct TaskSummaryListRow: HostedTableRow, Sendable {
    let summary: TaskSummaryEntry
    let similarity: Double?
    let isAlternate: Bool

    var id: UUID { summary.id }

    /// Everything the row draws — never the embedding or its source text.
    var renderKey: RenderKey {
        RenderKey(title: summary.title, summary: summary.summary, status: summary.status,
                  taskCreatedAt: summary.taskCreatedAt, similarity: similarity, isAlternate: isAlternate)
    }

    struct RenderKey: Equatable, Sendable {
        let title: String
        let summary: String
        let status: AgentTask.Status
        let taskCreatedAt: Date
        let similarity: Double?
        let isAlternate: Bool
    }

    /// Title, ID line and padding, plus the summary's wrapped lines.
    var estimatedHeight: CGFloat {
        Self.chromeHeight + Self.summaryLineHeight * CGFloat(EstimatedLines.count(in: summary.summary))
    }

    private static var chromeHeight: CGFloat { 56 }
    private static var summaryLineHeight: CGFloat { 16 }
}

/// A rough count of the lines a block of text wraps to in a default-width window — only a first
/// guess for a row's height before it is measured, so it is cheap and bounded rather than right.
private nonisolated enum EstimatedLines {
    private static var charactersPerLine: Int { 100 }
    private static var maximum: Int { 40 }

    static func count(in text: String) -> Int {
        var lines = 1
        var lineLength = 0
        for byte in text.utf8 {
            if byte == UInt8(ascii: "\n") || lineLength >= charactersPerLine {
                lines += 1
                lineLength = 0
                if lines >= maximum { break }
            } else {
                lineLength += 1
            }
        }
        return lines
    }
}

// MARK: - Tables

/// The Memory Browser's memories in a `HostedRowsTable`. Hundreds of memories, each a markdown
/// text view, laid out as one SwiftUI stack made the browser crawl.
struct MemoryListTable: View {
    let rows: [MemoryListRow]
    /// A change scrolls back to the top — a different filter or a new search's results.
    let scrollScope: AnyHashable
    let edit: MemoryEdit?
    let actions: MemoryListRowActions

    var body: some View {
        HostedRowsTable(
            rows: rows,
            scrollResetRevision: scrollScope,
            rowInsets: EdgeInsets(),
            rowContent: { row in
                MemoryListRowView(row: row, edit: row.isEditing ? edit : nil, actions: actions)
            }
        )
    }
}

/// The Memory Browser's task summaries in a `HostedRowsTable`.
struct TaskSummaryListTable: View {
    let rows: [TaskSummaryListRow]
    /// A change scrolls back to the top — a new search's results.
    let scrollScope: AnyHashable

    var body: some View {
        HostedRowsTable(
            rows: rows,
            scrollResetRevision: scrollScope,
            rowInsets: EdgeInsets(),
            rowContent: { row in
                MemoryTaskSummaryRow(summary: row.summary, similarityScore: row.similarity,
                                     isAlternateRow: row.isAlternate)
            }
        )
    }
}

// MARK: - Row views

private struct MemoryListRowView: View {
    let row: MemoryListRow
    /// Present only on the row being edited.
    let edit: MemoryEdit?
    let actions: MemoryListRowActions

    var body: some View {
        MemoryListRowContent(row: row, edit: edit, actions: actions)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(row.isAlternate ? AppColors.subtleRowBackgroundDim : Color.clear)
    }
}

private struct MemoryListRowContent: View {
    let row: MemoryListRow
    let edit: MemoryEdit?
    let actions: MemoryListRowActions

    var body: some View {
        if let edit {
            MemoryDraftForm(
                title: "Editing Memory", draft: edit.draft, background: MemoryBrowserStyle.editBackground,
                onCancel: { actions.cancelEditing(edit) }, onSave: { actions.saveEdit(edit) }
            )
        } else {
            MemoryDisplay(row: row, actions: actions)
        }
    }
}

private struct MemoryDisplay: View {
    let row: MemoryListRow
    let actions: MemoryListRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MemoryHeadline(memory: row.memory, similarity: row.similarity)
            // Only when there are tags: an empty tag line leaves a gap that looks like a layout bug.
            if !row.memory.tags.isEmpty {
                MemoryTagChips(tags: row.memory.tags)
            }
            MemoryStatLine(parts: row.memory.creationStatParts)
            MemoryStatLine(parts: row.memory.retrievalStatParts)
            // Injections get their own line rather than joining retrievals: the gap between the two
            // counts is the interesting part — a memory found often but injected rarely is filtered
            // out downstream; one injected far more than retrieved rides along on task briefings.
            MemoryStatLine(parts: row.memory.injectionStatParts)
            MemoryRowButtons(memory: row.memory, actions: actions)
        }
        .padding(.vertical, 4)
    }
}

private struct MemoryHeadline: View {
    let memory: MemoryEntry
    let similarity: Double?

    var body: some View {
        HStack(alignment: .top) {
            MarkdownText(content: memory.content, baseFont: .body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let similarity {
                Text(String(format: "%.0f%%", similarity * 100))
                    .font(.caption.bold().monospaced())
                    .foregroundStyle(MemoryBrowserStyle.similarityColor(similarity))
            }
            MemorySourceBadge(source: memory.source)
        }
    }
}

private struct MemoryTagChips: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
        }
    }
}

/// One right-aligned line of a memory's stats, its parts separated by bullets.
private struct MemoryStatLine: View {
    let parts: [String]

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Text(parts.joined(separator: "  •  "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct MemoryRowButtons: View {
    let memory: MemoryEntry
    let actions: MemoryListRowActions

    var body: some View {
        HStack(spacing: 8) {
            Button("Edit") { actions.beginEditing(memory) }
                .controlSize(.small)
            Button("Delete") { actions.requestDeletion(memory.id) }
                .controlSize(.small)
                .foregroundStyle(.red)
        }
        .padding(.top, 2)
    }
}

private struct MemorySourceBadge: View {
    let source: MemoryEntry.Source

    var body: some View {
        Text(source.rawValue.capitalized)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(MemoryBrowserStyle.sourceColor(source).opacity(0.15))
            .foregroundStyle(MemoryBrowserStyle.sourceColor(source))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Draft form

/// Content and tags for a memory, with Cancel and Save — the new-memory composer and the inline
/// edit form alike.
struct MemoryDraftForm: View {
    let title: String
    @Bindable var draft: MemoryDraft
    let background: Color
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft.content)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .border(AppColors.codeBlockBorder)
            LabeledContent("Tags") {
                TextField("comma-separated tags", text: $draft.tags)
                    .textFieldStyle(.roundedBorder)
            }
            MemoryDraftButtons(isBlank: draft.isBlank, onCancel: onCancel, onSave: onSave)
        }
        .padding(.vertical, 4)
        .padding(8)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct MemoryDraftButtons: View {
    let isBlank: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .controlSize(.small)
            Button("Save", action: onSave)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(isBlank)
        }
    }
}

// MARK: - Styling

/// The Memory Browser's colors and date format.
enum MemoryBrowserStyle {
    static let newMemoryBackground = Color.accentColor.opacity(0.08)
    static let editBackground = Color.accentColor.opacity(0.05)

    static func sourceColor(_ source: MemoryEntry.Source) -> Color {
        switch source {
        case .user: return .blue
        case .smith: return .green
        case .brown: return .orange
        }
    }

    static func similarityColor(_ score: Double) -> Color {
        if score >= 0.80 { return .green }
        if score >= 0.70 { return .yellow }
        if score >= 0.60 { return .orange }
        return .red
    }

    /// Compact "Apr 8, 14:32".
    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

private extension MemoryEntry {
    var creationStatParts: [String] {
        var parts = ["Created \(MemoryBrowserStyle.dateTime(createdAt))"]
        if let lastUpdatedAt, let lastUpdatedBy {
            parts.append("Updated \(MemoryBrowserStyle.dateTime(lastUpdatedAt)) by \(lastUpdatedBy.displayLabel)")
        }
        return parts
    }

    var retrievalStatParts: [String] {
        guard let lastRetrievedAt else { return ["Never retrieved by an agent"] }
        return ["Last retrieved \(MemoryBrowserStyle.dateTime(lastRetrievedAt))",
                "\(retrievalCount) retrieval\(retrievalCount == 1 ? "" : "s")"]
    }

    var injectionStatParts: [String] {
        guard let lastInjectedAt else { return ["Never injected into an agent's context"] }
        return ["Last injected \(MemoryBrowserStyle.dateTime(lastInjectedAt))",
                "\(injectionCount) injection\(injectionCount == 1 ? "" : "s")"]
    }
}

private extension MemoryEntry.UpdateSource {
    var displayLabel: String {
        switch self {
        case .user: return "User"
        case .system: return "System"
        }
    }
}
