import SwiftUI
import AgentSmithKit

/// Renders a string with markdown formatting.
///
/// Supports:
/// - Block headings: `# H1`, `## H2`, `### H3`
/// - Bullet lists: lines starting with `* ` or `- `
/// - Pipe-delimited tables with a separator row
/// - Inline bold: `**text**`, italic: `*text*` or `_text_`, bold-italic: `***text***`
/// - Inline code: `` `code` ``
/// - Fenced code blocks: ```` ``` ```` with optional language label
/// - Links: `[text](url)` and bare `https://` URLs
struct MarkdownText: View, Equatable {
    let content: String
    let baseFont: MarkdownFont
    let textColor: MarkdownTextColor

    /// Prevents body re-evaluation (and markdown re-parsing) when nothing rendered has changed.
    /// Every stored input participates: two views with different fonts or colors render
    /// differently and must not compare equal.
    nonisolated static func == (lhs: MarkdownText, rhs: MarkdownText) -> Bool {
        lhs.content == rhs.content && lhs.baseFont == rhs.baseFont && lhs.textColor == rhs.textColor
    }

    /// Parsed in `init`, not in a `.task`: a transcript row sizes itself from its first layout,
    /// and a `.task` left that layout empty — every row drew blank, then jumped to its real height
    /// a frame later. The parse is cheap (0.001ms median over 4,000 real channel messages).
    private let blocks: [ContentBlock]

    init(content: String, baseFont: MarkdownFont, textColor: MarkdownTextColor = .primary) {
        self.content = content
        self.baseFont = baseFont
        self.textColor = textColor
        self.blocks = Self.parseContentBlocks(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownLine.lineSpacing) {
            ForEach(blocks) { block in
                RenderBlockView(block: block, baseFont: baseFont, textColor: textColor)
            }
        }
        .modifier(MarkdownForegroundModifier(textColor: textColor))
        // Code blocks and tables; prose selects through its own text view.
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            MarkdownLinkOpener.open(url)
            return .handled
        })
    }

    // MARK: - Block model

    private enum ContentBlock: Identifiable {
        /// Consecutive prose lines — one selectable unit.
        case prose(id: Int, lines: [MarkdownLine])
        /// Rows × columns; the first row is the header.
        case table(id: Int, rows: [[String]])
        /// Fenced code block with optional language label.
        case codeBlock(id: Int, language: String?, lines: [String])

        var id: Int {
            switch self {
            case .prose(let id, _):        return id
            case .table(let id, _):        return id
            case .codeBlock(let id, _, _): return id
            }
        }
    }

    private static func parseContentBlocks(_ content: String) -> [ContentBlock] {
        let lines = content.components(separatedBy: "\n")
        var result: [ContentBlock] = []
        var prose: [MarkdownLine] = []
        var i = 0
        var nextID = 0

        func flushProse() {
            guard !prose.isEmpty else { return }
            result.append(.prose(id: nextID, lines: prose))
            nextID += 1
            prose = []
        }

        while i < lines.count {
            // Fenced code block: ``` with optional language specifier.
            let trimmedLine = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                flushProse()
                let langRaw = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let language = langRaw.isEmpty ? nil : langRaw
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                result.append(.codeBlock(id: nextID, language: language, lines: codeLines))
                nextID += 1
                continue
            }

            // Table detected when current line looks like a data row and the next is a separator.
            if i + 1 < lines.count,
               isTableDataRow(lines[i]),
               isTableSeparatorRow(lines[i + 1]) {
                flushProse()
                var tableLines: [String] = []
                while i < lines.count,
                      isTableDataRow(lines[i]) || isTableSeparatorRow(lines[i]) {
                    tableLines.append(lines[i])
                    i += 1
                }
                let rows = tableLines
                    .filter { !isTableSeparatorRow($0) }
                    .map { parseTableRow($0) }
                if !rows.isEmpty {
                    result.append(.table(id: nextID, rows: rows))
                    nextID += 1
                }
            } else {
                prose.append(MarkdownLine(lines[i]))
                i += 1
            }
        }
        flushProse()
        return result
    }

    // MARK: - Table parsing

    /// A data row has at least one `|`.
    private static func isTableDataRow(_ line: String) -> Bool {
        line.contains("|")
    }

    /// A separator row contains only `-`, `:`, `|`, space, and tab.
    private static func isTableSeparatorRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        return line.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " || $0 == "\t" }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|")
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty  == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Extracted View structs (refactored from func ... -> some View helpers)
    
    /// One block: prose, a table, or a code block.
    private struct RenderBlockView: View {
        let block: MarkdownText.ContentBlock
        let baseFont: MarkdownFont
        let textColor: MarkdownTextColor

        var body: some View {
            switch block {
            case .prose(_, let lines):
                ProseBlockView(lines: lines, baseFont: baseFont, textColor: textColor)
            case .table(_, let rows):
                if let columnCount = rows.map(\.count).max(), columnCount > 0 {
                    TableView(rows: rows, columnCount: columnCount, baseFont: baseFont.font)
                }
            case .codeBlock(_, let language, let lines):
                CodeBlockView(language: language, lines: lines, baseFont: baseFont.font)
            }
        }
    }

    /// Prose drawn by whichever renderer the environment asks for.
    private struct ProseBlockView: View {
        let lines: [MarkdownLine]
        let baseFont: MarkdownFont
        let textColor: MarkdownTextColor
        @Environment(\.markdownRendering) private var rendering

        var body: some View {
            switch rendering {
            case .selectable:
                SelectableProseView(lines: lines, baseFont: baseFont, textColor: textColor)
            case .staticText:
                VStack(alignment: .leading, spacing: MarkdownLine.lineSpacing) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        RenderLineView(line: line, baseFont: baseFont.font)
                    }
                }
            }
        }
    }
    
    /// Nested View struct for rendering code blocks (refactored from codeBlockView(language:lines:))
    private struct CodeBlockView: View {
        let language: String?
        let lines: [String]
        let baseFont: Font
        private let joinedCode: String
        
        init(language: String?, lines: [String], baseFont: Font) {
            self.language = language
            self.lines = lines
            self.baseFont = baseFont
            self.joinedCode = lines.joined(separator: "\n")
        }
        
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                Text(joinedCode)
                    .font(baseFont)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.codeBlockBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(AppColors.codeBlockBorder, lineWidth: 0.5)
            )
            .padding(.vertical, 4)
        }
    }
    
    /// Nested View struct for rendering tables (refactored from tableView(rows:columnCount:))
    private struct TableView: View {
        /// Only the rendered cells are stored — `rows`/`columnCount`/`baseFont` are inputs to
        /// that rendering, and keeping them as properties retained the raw `[[String]]` for the
        /// view's lifetime while `body` never read them.
        private let renderedRows: [(isHeader: Bool, cells: [Text])]

        init(rows: [[String]], columnCount: Int, baseFont: Font) {
            // Pre-compute all rendered cells at init time
            self.renderedRows = rows.enumerated().map { rowIdx, row in
                let isHeader = rowIdx == 0
                let cellFont = isHeader ? baseFont.weight(.semibold) : baseFont
                let renderedCells: [Text] = (0..<columnCount).map { colIdx in
                    let cell = colIdx < row.count ? row[colIdx] : ""
                    return InlineText.styled(cell, font: cellFont)
                }
                return (isHeader: isHeader, cells: renderedCells)
            }
        }
        
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(renderedRows.enumerated()), id: \.offset) { idx, row in
                    MarkdownTableRow(renderedCells: row.cells, isHeader: row.isHeader)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AppColors.tableBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.vertical, 4)
        }
    }
    
    /// One prose line as SwiftUI `Text` — the static renderer (PDF export). Styled in `init`, once.
    private struct RenderLineView: View {
        private let content: Content

        private enum Content {
            case heading(Text)
            case blank
            case list(marker: Text, content: Text, indent: CGFloat)
            case indented(Text, indent: CGFloat)
            case plain(Text)
        }

        init(line: MarkdownLine, baseFont: Font) {
            switch line {
            case .heading(let level, let text):
                content = .heading(InlineText.styled(text, font: MarkdownLine.headingFont(level: level).font))
            case .blank:
                content = .blank
            case .listItem(let marker, let text, let indent):
                content = .list(marker: Text(marker).font(baseFont),
                                content: InlineText.styled(text, font: baseFont), indent: indent)
            case .indented(let text, let indent):
                content = .indented(InlineText.styled(text, font: baseFont), indent: indent)
            case .plain(let text):
                content = .plain(InlineText.styled(text, font: baseFont))
            }
        }

        var body: some View {
            switch content {
            case .heading(let text):
                text
            case .blank:
                Color.clear.frame(height: MarkdownLine.blankLineHeight)
            case .list(let marker, let text, let indent):
                HStack(alignment: .top, spacing: MarkdownLine.listMarkerSpacing) {
                    marker
                    text
                }
                .padding(.leading, indent)
            case .indented(let text, let indent):
                text.padding(.leading, indent)
            case .plain(let text):
                text
            }
        }
    }

    /// Helper namespace for styled inline text (refactored from styledInlineText(_:font:))
    private enum InlineText {
        /// The parsing/styling pipeline lives in `InlineMarkdownStyler` (AgentSmithKit)
        /// so the package test suite can pin its behavior — emphasis and links form
        /// across inline code spans, linkification never reaches inside them.
        static func styled(_ raw: String, font: Font) -> Text {
            Text(InlineMarkdownStyler.styledLine(raw, inlineCodeColor: AppColors.inlineCode))
                .font(font)
        }
    }
}
