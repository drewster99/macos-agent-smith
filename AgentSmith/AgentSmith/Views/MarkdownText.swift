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
    let baseFont: Font

    /// Prevents body re-evaluation (and markdown re-parsing) when content is unchanged.
    nonisolated static func == (lhs: MarkdownText, rhs: MarkdownText) -> Bool {
        lhs.content == rhs.content
    }

    @State private var cachedBlocks: [ContentBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(cachedBlocks) { block in
                RenderBlockView(block: block, baseFont: baseFont)
            }
        }
        .task {
            await updateBlocks()
        }
        .onChange(of: content) { _, _ in
            Task { await updateBlocks() }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL else { return .systemAction }
            let path = url.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                // Path disappeared between linkification and tap — silently drop.
                return .handled
            }
            if isDir.boolValue {
                // Folder: open it in Finder showing its contents.
                NSWorkspace.shared.open(url)
            } else {
                // File: present Quick Look preview rather than opening the default app.
                // Shells out to `/usr/bin/qlmanage -p <path>` because spinning up
                // `QLPreviewPanel` programmatically requires a long-lived data source
                // and panel-controller wiring; qlmanage gives the user the same Quick
                // Look window with one Process invocation. The qlmanage process stays
                // alive until the QL window is dismissed; we don't wait on it.
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                task.arguments = ["-p", path]
                try? task.run()
            }
            return .handled
        })
    }

    @Sendable private func updateBlocks() async {
        let blocks = parseContentBlocks()
        await MainActor.run {
            cachedBlocks = blocks
        }
    }

    // MARK: - Block model

    private enum ContentBlock: Identifiable {
        case line(id: Int, text: String)
        /// Rows × columns; the first row is the header.
        case table(id: Int, rows: [[String]])
        /// Fenced code block with optional language label.
        case codeBlock(id: Int, language: String?, lines: [String])

        var id: Int {
            switch self {
            case .line(let id, _):      return id
            case .table(let id, _):     return id
            case .codeBlock(let id, _, _): return id
            }
        }
    }

    private func parseContentBlocks() -> [ContentBlock] {
        let lines = content.components(separatedBy: "\n")
        var result: [ContentBlock] = []
        var i = 0
        var nextID = 0

        while i < lines.count {
            // Fenced code block: ``` with optional language specifier.
            let trimmedLine = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
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
                result.append(.line(id: nextID, text: lines[i]))
                nextID += 1
                i += 1
            }
        }
        return result
    }

    // MARK: - Table parsing

    /// A data row has at least one `|`.
    private func isTableDataRow(_ line: String) -> Bool {
        line.contains("|")
    }

    /// A separator row contains only `-`, `:`, `|`, space, and tab.
    private func isTableSeparatorRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        return line.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " || $0 == "\t" }
    }

    private func parseTableRow(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|")
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty  == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Extracted View structs (refactored from func ... -> some View helpers)
    
    /// Nested View struct for rendering content blocks (refactored from renderBlock(_:)
    private struct RenderBlockView: View {
        let block: MarkdownText.ContentBlock
        let baseFont: Font
        
        var body: some View {
            switch block {
            case .line(_, let text):
                RenderLineView(line: text, baseFont: baseFont)
            case .table(_, let rows):
                if let columnCount = rows.map(\.count).max(), columnCount > 0 {
                    TableView(rows: rows, columnCount: columnCount, baseFont: baseFont)
                }
            case .codeBlock(_, let language, let lines):
                CodeBlockView(language: language, lines: lines, baseFont: baseFont)
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
        let rows: [[String]]
        let columnCount: Int
        let baseFont: Font
        private let renderedRows: [(isHeader: Bool, cells: [Text])]
        
        init(rows: [[String]], columnCount: Int, baseFont: Font) {
            self.rows = rows
            self.columnCount = columnCount
            self.baseFont = baseFont
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
    
    /// Nested View struct for rendering a single line (refactored from renderLine(_:)
    private struct RenderLineView: View {
        let line: String
        let baseFont: Font
        private let parsed: LineParseResult
        private let trimmed: String
        private let h1Text: Text?
        private let h2Text: Text?
        private let h3Text: Text?
        private let listMarkerText: Text?
        private let listContentText: Text?
        private let indentedText: Text?
        private let plainText: Text?
        
        init(line: String, baseFont: Font) {
            self.line = line
            self.baseFont = baseFont
            self.trimmed = line.trimmingCharacters(in: .whitespaces)
            self.parsed = LineParser.parse(line, baseFont: baseFont)
            // Pre-compute all styled text variants at init time
            self.h1Text = trimmed.hasPrefix("# ") ? InlineText.styled(String(trimmed.dropFirst(2)), font: AppFonts.markdownH1) : nil
            self.h2Text = trimmed.hasPrefix("## ") ? InlineText.styled(String(trimmed.dropFirst(3)), font: AppFonts.markdownH2) : nil
            self.h3Text = trimmed.hasPrefix("### ") ? InlineText.styled(String(trimmed.dropFirst(4)), font: AppFonts.markdownH3) : nil
            if parsed.isList {
                self.listMarkerText = Text(parsed.isNumbered ? parsed.numberPrefix : "•").font(baseFont)
                self.listContentText = InlineText.styled(parsed.content, font: baseFont)
                self.indentedText = nil
                self.plainText = nil
            } else if parsed.indent > 0 {
                self.listMarkerText = nil
                self.listContentText = nil
                self.indentedText = InlineText.styled(parsed.content, font: baseFont)
                self.plainText = nil
            } else {
                self.listMarkerText = nil
                self.listContentText = nil
                self.indentedText = nil
                self.plainText = InlineText.styled(line, font: baseFont)
            }
        }
        
        var body: some View {
            if let h3Text = h3Text {
                h3Text
            } else if let h2Text = h2Text {
                h2Text
            } else if let h1Text = h1Text {
                h1Text
            } else if trimmed.isEmpty {
                Color.clear.frame(height: 6)
            } else if let listMarkerText = listMarkerText, let listContentText = listContentText {
                // Indent based on leading whitespace: 12pt base + 12pt per 2-space level
                let depthPadding = CGFloat(max(0, parsed.indent / 2)) * 12
                HStack(alignment: .top, spacing: 4) {
                    listMarkerText
                    listContentText
                }
                .padding(.leading, depthPadding)
            } else if let indentedText = indentedText {
                // Indented non-list text — preserve the indent
                let depthPadding = CGFloat(max(0, parsed.indent / 2)) * 12
                indentedText
                    .padding(.leading, depthPadding)
            } else if let plainText = plainText {
                plainText
            }
        }
    }
    
    /// Helper struct for line parsing results
    private struct LineParseResult {
        let indent: Int
        let isList: Bool
        let isNumbered: Bool
        let numberPrefix: String
        let content: String
    }
    
    /// Helper namespace for line parsing logic
    private enum LineParser {
        static func parse(_ line: String, baseFont: Font) -> LineParseResult {
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line.count - stripped.count
            
            // Bullet markers: "* ", "- "
            if stripped.hasPrefix("* ") || stripped.hasPrefix("- ") {
                return LineParseResult(indent: indent, isList: true, isNumbered: false, numberPrefix: "", content: String(stripped.dropFirst(2)))
            }
            // Unicode bullet: "•" or "•" (some LLMs omit the trailing space)
            if stripped.hasPrefix("•") {
                let afterBullet = stripped.dropFirst(1).drop(while: { $0 == " " })
                return LineParseResult(indent: indent, isList: true, isNumbered: false, numberPrefix: "", content: String(afterBullet))
            }
            
            // Numbered list: "1. ", "2) ", etc. — preserve the prefix for display
            if let match = stripped.prefixMatch(of: /\d+[.)]\s+/) {
                let prefix = String(stripped[match.range]).trimmingCharacters(in: .whitespaces)
                return LineParseResult(indent: indent, isList: true, isNumbered: true, numberPrefix: prefix, content: String(stripped[match.range.upperBound...]))
            }
            
            return LineParseResult(indent: indent, isList: false, isNumbered: false, numberPrefix: "", content: String(stripped))
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
