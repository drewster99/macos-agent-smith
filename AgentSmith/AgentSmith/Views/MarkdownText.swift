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

    // MARK: - Inline code

    /// GFM treats even single tildes as strikethrough delimiters, so two home-relative
    /// paths in one line ("check ~/cursor/a and ~/cursor/b") struck through everything
    /// between them (observed on user-typed text 2026-07-09). Escape `~` only when it
    /// starts a `~/` path and is outside a backtick code span — deliberate
    /// `~~strikethrough~~` and code spans are untouched.
    static func escapingPathTildes(_ text: String) -> String {
        guard text.contains("~/") else { return text }
        var result = ""
        result.reserveCapacity(text.count + 4)
        var insideCode = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "`" {
                insideCode.toggle()
                result.append(character)
            } else if character == "~", !insideCode {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "/" {
                    result.append("\\~")
                } else {
                    result.append(character)
                }
            } else {
                result.append(character)
            }
            index = text.index(after: index)
        }
        return result
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
                Text(lines.joined(separator: "\n"))
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
        
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    let isHeader = rowIdx == 0
                    let cellFont = isHeader ? baseFont.weight(.semibold) : baseFont
                    let renderedCells: [Text] = (0..<columnCount).map { colIdx in
                        let cell = colIdx < row.count ? row[colIdx] : ""
                        return InlineText.styled(cell, font: cellFont)
                    }
                    MarkdownTableRow(renderedCells: renderedCells, isHeader: isHeader)
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
        
        init(line: String, baseFont: Font) {
            self.line = line
            self.baseFont = baseFont
            self.trimmed = line.trimmingCharacters(in: .whitespaces)
            self.parsed = LineParser.parse(line, baseFont: baseFont)
        }
        
        var body: some View {
            if trimmed.hasPrefix("### ") {
                InlineText.styled(String(trimmed.dropFirst(4)), font: AppFonts.markdownH3)
            } else if trimmed.hasPrefix("## ") {
                InlineText.styled(String(trimmed.dropFirst(3)), font: AppFonts.markdownH2)
            } else if trimmed.hasPrefix("# ") {
                InlineText.styled(String(trimmed.dropFirst(2)), font: AppFonts.markdownH1)
            } else if trimmed.isEmpty {
                Color.clear.frame(height: 6)
            } else {
                if parsed.isList {
                    // Indent based on leading whitespace: 12pt base + 12pt per 2-space level
                    let depthPadding = CGFloat(max(0, parsed.indent / 2)) * 12
                    let marker = parsed.isNumbered ? parsed.numberPrefix : "•"
                    HStack(alignment: .top, spacing: 4) {
                        Text(marker)
                            .font(baseFont)
                        InlineText.styled(parsed.content, font: baseFont)
                    }
                    .padding(.leading, depthPadding)
                } else if parsed.indent > 0 {
                    // Indented non-list text — preserve the indent
                    let depthPadding = CGFloat(max(0, parsed.indent / 2)) * 12
                    InlineText.styled(parsed.content, font: baseFont)
                        .padding(.leading, depthPadding)
                } else {
                    InlineText.styled(line, font: baseFont)
                }
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
        static func styled(_ raw: String, font: Font) -> Text {
            let segments = InlineCodeParser.parse(raw)
            var combined = AttributedString()
            
            for segment in segments {
                // A backtick-wrapped segment whose entire content is a single path or URL
                // is more useful as a clickable link than as colored inline code. One
                // `standaloneLink(for:)` call covers both the decision and the wrapping,
                // so paths get exactly one `FileManager.fileExists` hit per render.
                if segment.isCode, let linked = PathLinkifier.standaloneLink(for: segment.text) {
                    combined += MarkdownParser.parse(linked, fallback: segment.text)
                } else if segment.isCode {
                    var part = AttributedString(segment.text)
                    part.foregroundColor = AppColors.inlineCode
                    combined += part
                } else {
                    combined += MarkdownParser.parse(PathLinkifier.linkify(segment.text), fallback: segment.text)
                }
            }
            return Text(combined).font(font)
        }
    }
    
    /// Helper namespace for inline code parsing
    private enum InlineCodeParser {
        struct InlineSegment {
            let text: String
            let isCode: Bool
        }
        
        static func parse(_ text: String) -> [InlineSegment] {
            var segments: [InlineSegment] = []
            var remaining = text[...]
            
            while let backtickStart = remaining.firstIndex(of: "`") {
                if backtickStart > remaining.startIndex {
                    segments.append(InlineSegment(text: String(remaining[remaining.startIndex..<backtickStart]), isCode: false))
                }
                let afterBacktick = remaining.index(after: backtickStart)
                if afterBacktick < remaining.endIndex,
                   let backtickEnd = remaining[afterBacktick...].firstIndex(of: "`") {
                    segments.append(InlineSegment(text: String(remaining[afterBacktick..<backtickEnd]), isCode: true))
                    remaining = remaining[remaining.index(after: backtickEnd)...]
                } else {
                    // No closing backtick — treat rest as plain text.
                    segments.append(InlineSegment(text: String(remaining[backtickStart...]), isCode: false))
                    remaining = remaining[remaining.endIndex...]
                }
            }
            if !remaining.isEmpty {
                segments.append(InlineSegment(text: String(remaining), isCode: false))
            }
            return segments
        }
    }
    
    /// Helper namespace for markdown parsing
    private enum MarkdownParser {
        static func parse(_ markdown: String, fallback: String) -> AttributedString {
            if let parsed = try? AttributedString(
                markdown: MarkdownText.escapingPathTildes(markdown),
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            ) {
                return parsed
            }
            return AttributedString(fallback)
        }
    }
}
