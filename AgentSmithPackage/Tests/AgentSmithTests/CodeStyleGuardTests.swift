import Testing
import Foundation

/// Source-level regression tests that scan the AgentSmith app target for forbidden
/// SwiftUI patterns.
///
/// These exist because Swift's compiler will happily accept code that violates the
/// project's SwiftUI rules in `CLAUDE.md`. Running these tests in CI catches
/// regressions even when SwiftLint isn't installed.
///
/// The tests resolve the app target source dir relative to this file, walk every `.swift`
/// file under `AgentSmith/AgentSmith/`, and apply targeted regex checks.
@Suite("Code style guards (app target)")
struct CodeStyleGuardTests {

    // MARK: - Project paths

    /// Resolves the absolute path to `AgentSmith/AgentSmith/` (the SwiftUI app target).
    /// Walks up from the package's source root until we find the sibling app directory.
    static var appTargetRoot: URL {
        // This file is at:
        //   <repo>/AgentSmithPackage/Tests/AgentSmithTests/CodeStyleGuardTests.swift
        // The app target is at:
        //   <repo>/AgentSmith/AgentSmith/
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()  // .../AgentSmithTests/
        url.deleteLastPathComponent()  // .../Tests/
        url.deleteLastPathComponent()  // .../AgentSmithPackage/
        url.deleteLastPathComponent()  // .../<repo>/
        url.appendPathComponent("AgentSmith", isDirectory: true)
        url.appendPathComponent("AgentSmith", isDirectory: true)
        return url
    }

    /// Yields every `.swift` file under the app target, lazily.
    static func swiftFiles() -> [URL] {
        let root = appTargetRoot
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files
    }

    /// Returns hits of the regex across all app-target Swift files as
    /// `(relativePath, lineNumber, lineText)` tuples.
    private static func scan(
        regex pattern: String,
        excluding excluded: [String] = []
    ) throws -> [(path: String, line: Int, text: String)] {
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let rootPath = appTargetRoot.path
        var hits: [(String, Int, String)] = []

        for url in swiftFiles() {
            let relPath = url.path.replacingOccurrences(of: rootPath + "/", with: "")
            if excluded.contains(where: { relPath.hasSuffix($0) }) { continue }

            let content = try String(contentsOf: url, encoding: .utf8)
            let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
            for match in regex.matches(in: content, options: [], range: nsRange) {
                guard let range = Range(match.range, in: content) else { continue }
                let lineStart = content[..<range.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count
                let lineText = content[range].split(separator: "\n").first.map(String.init) ?? ""
                hits.append((relPath, lineStart, lineText.trimmingCharacters(in: .whitespaces)))
            }
        }
        return hits
    }

    // MARK: - Tests

    /// `: some View` properties besides `body` are forbidden by `CLAUDE.md`.
    ///
    /// The fix is to extract a `View` struct — NOT to convert to a `@ViewBuilder` function, which
    /// this message used to recommend and which the project rule forbids just as firmly. That advice
    /// is why there are now ~188 `-> some View` functions and zero `some View` properties: the guard
    /// worked, and everyone followed its instructions into the other half of the same rule. See
    /// `someViewFunctionRatchet` below, which holds that number still.
    @Test("No `: some View` properties besides body in app target")
    func noSomeViewProperties() throws {
        // Match `[@ViewBuilder] [private] var <name>: some View` where name != body
        let hits = try Self.scan(
            regex: #"^\s*(@ViewBuilder\s*\n\s*)?(private |fileprivate )?var (?!body\b)[a-zA-Z_][a-zA-Z0-9_]*: some View\b"#
        )
        if !hits.isEmpty {
            let formatted = hits.map { "  \($0.path):\($0.line) — \($0.text)" }.joined(separator: "\n")
            Issue.record("Found `: some View` properties (extract a `View` struct — do NOT convert to a @ViewBuilder func, which violates the same rule):\n\(formatted)")
        }
    }

    /// `LazyVStack`, `LazyHStack`, `LazyVGrid`, `LazyHGrid` are forbidden by the project
    /// SwiftUI rule. Use `VStack` / `HStack` etc. inside a `ScrollView`.
    @Test("No Lazy* containers in app target")
    func noLazyContainers() throws {
        // `ModelsSettingsTab.swift` is a documented, USER-APPROVED exception (2026-07-31): the model
        // catalog runs to ~1,700 short, uniform rows, so eager realization froze the tab. The rows are
        // well under a screen dimension, so the sizing pitfall this rule guards against does not apply.
        // The approval is recorded at the usage site; this whitelist keeps the guard honoring it.
        // Matched on the full relative path (the scan uses `hasSuffix`) so a differently-named file such
        // as `CustomModelsSettingsTab.swift` can't slip through the exclusion.
        let hits = try Self.scan(
            regex: #"\bLazy(VStack|HStack|VGrid|HGrid)\b"#,
            excluding: ["Views/ModelsSettingsTab.swift"]
        )
        if !hits.isEmpty {
            let formatted = hits.map { "  \($0.path):\($0.line) — \($0.text)" }.joined(separator: "\n")
            Issue.record("Found Lazy* containers (project rule says avoid; prefer ScrollView { VStack {} }):\n\(formatted)")
        }
    }

    /// `.onTapGesture` is forbidden by `CLAUDE.md` whenever a `Button` will work.
    /// Buttons get keyboard focus, hover, and accessibility for free.
    @Test("No .onTapGesture in app target (use Button)")
    func noOnTapGesture() throws {
        // Sanity: confirm the scanner is actually finding view files. If this fails the
        // path resolution in `appTargetRoot` is wrong and other guards may be silently
        // empty too.
        let files = Self.swiftFiles()
        #expect(files.count > 5, "Code style guard found only \(files.count) Swift files at \(Self.appTargetRoot.path) — path resolution is likely wrong")
        let hits = try Self.scan(regex: #"\.onTapGesture\b"#)
        if !hits.isEmpty {
            let formatted = hits.map { "  \($0.path):\($0.line) — \($0.text)" }.joined(separator: "\n")
            Issue.record("Found .onTapGesture (use Button { } label: { }.buttonStyle(.plain) instead):\n\(formatted)")
        }
    }

    /// `.foregroundColor(...)` is the deprecated form. Modern SwiftUI uses
    /// `.foregroundStyle(...)`.
    @Test("No deprecated .foregroundColor in app target")
    func noForegroundColor() throws {
        let hits = try Self.scan(regex: #"\.foregroundColor\("#)
        if !hits.isEmpty {
            let formatted = hits.map { "  \($0.path):\($0.line) — \($0.text)" }.joined(separator: "\n")
            Issue.record("Found deprecated .foregroundColor (use .foregroundStyle):\n\(formatted)")
        }
    }

    /// Direct `@ObservedObject var foo = Model()` is the project anti-pattern.
    /// Use `@StateObject` for local creation or `@EnvironmentObject` for env-injected types.
    @Test("No @ObservedObject in app target")
    func noObservedObject() throws {
        let hits = try Self.scan(regex: #"@ObservedObject\b"#)
        if !hits.isEmpty {
            let formatted = hits.map { "  \($0.path):\($0.line) — \($0.text)" }.joined(separator: "\n")
            Issue.record("Found @ObservedObject (use @StateObject / @EnvironmentObject / @Bindable):\n\(formatted)")
        }
    }

    /// `LazyVGrid` and similar containers are caught by the broader Lazy* check above.
    /// This test catches the AppFonts and AppColors centralization regression: any new
    /// inline `.font(.system(size: ...))` or hardcoded `Color.<name>.opacity(...)` literal
    /// in the Views/ directory should go through `AppFonts` / `AppColors` instead.
    /// We tolerate exemptions where there's no semantic name (e.g. a one-off welcome icon
    /// size 40) — those have already been promoted to `AppFonts`.
    @Test("Inline .font(.system(size:)) literals are gone in Views/")
    func noInlineSystemSizeFonts() throws {
        let hits = try Self.scan(regex: #"\.font\(\.system\(size: ?\d+\b"#)
        // Filter to Views/ only (Styling/ is exempt — that's where AppFonts is defined)
        let viewHits = hits.filter { $0.path.hasPrefix("Views/") }
        if !viewHits.isEmpty {
            let formatted = viewHits.map { "  \($0.path):\($0.line) — \($0.text)" }.joined(separator: "\n")
            Issue.record("Found inline .font(.system(size:)) (promote to AppFonts entry):\n\(formatted)")
        }
    }

    // MARK: - `-> some View` ratchet

    /// Files that may contain `-> some View` returns, and how many.
    ///
    /// **This table is a BACKLOG, not an allowance.** The project rule says the correct number is
    /// zero everywhere: a helper returning `some View` is a `View` struct that was never written,
    /// and it costs identity stability and body-size discipline.
    ///
    /// It exists because the number was GROWING. `noSomeViewProperties` above guards the property
    /// form of the same rule, and until this commit its failure message told you to fix a violation
    /// by writing the function form — so the count went from 89 when that guard landed to 208 at its
    /// peak, entirely inside the shape it was supposed to prevent. One commit in that period is
    /// literally titled "Extract all `-> some View` helpers to View structs" and left 197 behind,
    /// because nobody was counting.
    ///
    /// Ceilings fail UPWARD only, so paying one off never breaks the build; the global total below
    /// fails in BOTH directions, so the debt cannot be paid down on paper without the number moving.
    private static let someViewFunctionBudget: [String: Int] = [
        "Views/TaskDetailWindow.swift": 30,
        "Views/TaskListView.swift": 28,
        "Views/SpendingDashboardView.swift": 13,
        "Views/ModelMetadataInspectorWindow.swift": 12,
        "Views/RoleModelConfigOverrideEditor.swift": 12,
        "Views/TaskOverlay/TaskOverlayBar.swift": 11,
        "Views/Tasks/TaskEditorSheet.swift": 9,
        "Views/CompactionDiffWindow.swift": 8,
        "Views/MemoryEditorView.swift": 8,
        "Views/LLMTurnViews.swift": 6,
        "Views/OnboardingView.swift": 6,
        "Views/AgentModelSettingsSection.swift": 5,
        "Views/MetadataCoverageView.swift": 4,
        "Views/ProviderManagementView.swift": 4,
        "Views/TaskPDF/TaskPDFDocumentView.swift": 4,
        "Views/DeliverablesView.swift": 3,
        "Views/MCPServerEditorSheet.swift": 3,
        "Views/SettingsView.swift": 3,
        "Views/InspectorView.swift": 2,
        "Views/ModelStatsPopover.swift": 2,
        "Views/TaskToolOverrideEditor.swift": 2,
        "Views/ToolsSettingsView.swift": 2,
        "Views/ConfigValidationView.swift": 1,
        "Views/Inspector/AgentCardModelInfoLine.swift": 1,
        "Views/Inspector/CostEstimateSection.swift": 1,
        "Views/Inspector/ValidatorAgentCard.swift": 1,
        "Views/MCPServerManagementView.swift": 1,
        "Views/TaskDetail/TaskRelevantPriorTaskRow.swift": 1,
        "Views/Tasks/TemplateRunInputSheet.swift": 1
    ]

    /// The sum of the ceilings. Pinned separately and checked in BOTH directions so a cleanup has
    /// to edit this number, and so unused headroom cannot quietly accumulate in the table.
    private static let someViewFunctionTotal = 184

    /// Counts `func … -> some View` declarations in one file, excluding the two forms that have no
    /// `View`-struct spelling:
    ///
    ///   - `ViewModifier.body(content:)` — a protocol requirement.
    ///   - anything inside `extension View { … }` — the modifier-factory idiom.
    ///
    /// Matched by SHAPE rather than by filename, so a new `ViewModifier` in a new file is fine while
    /// an ordinary helper hiding in an exempt file still counts.
    static func someViewFunctionCount(in source: String) -> Int {
        // Strip comments FIRST. Two of the three counters that produced a baseline for this table
        // were fooled by prose — including, with some irony, `// MARK: - Extracted View structs
        // (refactored from func ... -> some View)`, a comment recording that the violation had been
        // REMOVED. A count that rises when someone documents the rule is worse than no count.
        let source = Self.strippingComments(source)
        let viewExtensionRanges = Self.braceRanges(in: source, after: #"\bextension\s+View\s*\{"#)
        var count = 0
        var index = source.startIndex
        let marker = "some View"
        while let hit = source.range(of: marker, range: index..<source.endIndex) {
            index = hit.upperBound
            // Walk back to the declaration this return type belongs to.
            let head = source[source.startIndex..<hit.lowerBound]
            guard let arrow = head.range(of: "->", options: .backwards),
                  head[arrow.upperBound...].allSatisfy({ $0 == " " || $0 == "\n" || $0 == "\t" }) else { continue }
            guard let funcKeyword = head[head.startIndex..<arrow.lowerBound].range(of: "func ", options: .backwards) else { continue }
            // A `var` between the `func` and the arrow means this return type belongs to something
            // else (a local closure, a nested property) — not the function declaration.
            if head[funcKeyword.upperBound..<arrow.lowerBound].contains("var ") { continue }
            let declaration = String(head[funcKeyword.lowerBound..<arrow.lowerBound])
            if declaration.contains("body(content:") || declaration.contains("body(content ") { continue }
            if viewExtensionRanges.contains(where: { $0.contains(funcKeyword.lowerBound) }) { continue }
            count += 1
        }
        return count
    }

    /// Blanks out `//` line comments and `/* */` blocks, preserving length and newlines so any
    /// offsets computed afterwards still line up with the original source.
    ///
    /// Deliberately does not try to be a full lexer: a `//` inside a string literal is blanked too.
    /// For this counter that is harmless — it can only ever cause an UNDER-count of a declaration
    /// hidden inside a string, which is not a thing that exists.
    static func strippingComments(_ source: String) -> String {
        var out = Array(source)
        var index = 0
        var inLine = false
        var inBlock = false
        while index < out.count {
            let c = out[index]
            let next = index + 1 < out.count ? out[index + 1] : "\0"
            if inLine {
                if c == "\n" { inLine = false } else { out[index] = " " }
            } else if inBlock {
                if c == "*", next == "/" { out[index] = " "; out[index + 1] = " "; index += 2; inBlock = false; continue }
                if c != "\n" { out[index] = " " }
            } else if c == "/", next == "/" {
                inLine = true
                out[index] = " "; out[index + 1] = " "
                index += 2
                continue
            } else if c == "/", next == "*" {
                inBlock = true
                out[index] = " "; out[index + 1] = " "
                index += 2
                continue
            }
            index += 1
        }
        return String(out)
    }

    /// Brace-balanced ranges of every construct matching `pattern`, used to exempt `extension View`.
    private static func braceRanges(in source: String, after pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(source.startIndex..<source.endIndex, in: source)
        var ranges: [Range<String.Index>] = []
        for match in regex.matches(in: source, options: [], range: full) {
            guard let matched = Range(match.range, in: source) else { continue }
            var depth = 1
            var cursor = matched.upperBound
            while cursor < source.endIndex, depth > 0 {
                if source[cursor] == "{" { depth += 1 }
                else if source[cursor] == "}" { depth -= 1 }
                cursor = source.index(after: cursor)
            }
            ranges.append(matched.lowerBound..<cursor)
        }
        return ranges
    }

    @Test("`-> some View` functions do not grow beyond their frozen per-file budget")
    func someViewFunctionRatchet() throws {
        let rootPath = Self.appTargetRoot.path
        var actual: [String: Int] = [:]
        for url in Self.swiftFiles() {
            let relative = url.path.replacingOccurrences(of: rootPath + "/", with: "")
            let count = Self.someViewFunctionCount(in: try String(contentsOf: url, encoding: .utf8))
            if count > 0 { actual[relative] = count }
        }

        var problems: [String] = []
        for (path, count) in actual.sorted(by: { $0.key < $1.key }) {
            let budget = Self.someViewFunctionBudget[path] ?? 0
            if count > budget {
                problems.append("  \(path): \(count) > budget \(budget) — extract a `View` struct instead of a `-> some View` helper")
            }
        }
        let total = actual.values.reduce(0, +)
        if total != Self.someViewFunctionTotal {
            // Print the CURRENT table on any mismatch. The fix is then mechanical — paste it — and
            // there is nothing for a reader (or a review agent) to interpret.
            let table = actual.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .map { "        \"\($0.key)\": \($0.value)," }
                .joined(separator: "\n")
            let direction = total < Self.someViewFunctionTotal
                ? "Debt was paid down — lower the ceiling AND the total in the same commit."
                : "New violations — extract `View` structs rather than raising the budget."
            problems.append("  TOTAL is \(total), budget says \(Self.someViewFunctionTotal). \(direction)\n  Current table:\n\(table)")
        }

        if !problems.isEmpty {
            Issue.record("`-> some View` budget violated:\n\(problems.joined(separator: "\n"))")
        }
    }

    @Test("The ratchet exempts ViewModifier.body and `extension View` factories by shape")
    func ratchetExemptionsAreStructural() {
        // A ViewModifier conformance has no `View`-struct spelling.
        #expect(CodeStyleGuardTests.someViewFunctionCount(in: """
            struct Tip: ViewModifier {
                func body(content: Content) -> some View { content }
            }
            """) == 0)
        // Neither does a modifier factory.
        #expect(CodeStyleGuardTests.someViewFunctionCount(in: """
            extension View {
                func tip(_ text: String) -> some View { modifier(Tip()) }
            }
            """) == 0)
        // An ordinary helper counts, including one hiding in a file that also has an exempt form.
        #expect(CodeStyleGuardTests.someViewFunctionCount(in: """
            extension View {
                func tip(_ text: String) -> some View { self }
            }
            struct Row: View {
                var body: some View { header() }
                private func header() -> some View { Text("hi") }
            }
            """) == 1)
        // A multi-line signature is still one hit.
        #expect(CodeStyleGuardTests.someViewFunctionCount(in: """
            struct Row: View {
                var body: some View { Text("x") }
                private func chip(
                    title: String,
                    count: Int
                ) -> some View { Text(title) }
            }
            """) == 1)
        // Prose is not code. Two of the three counters that produced a baseline for the table above
        // were fooled by exactly these lines — one of which records that the violation was removed.
        #expect(CodeStyleGuardTests.someViewFunctionCount(in: """
            // MARK: - Extracted View structs (refactored from func ... -> some View)
            /// A `View` struct (not a `-> some View` helper) per the project's SwiftUI rules.
            /* func legacy() -> some View { EmptyView() } */
            struct Row: View {
                var body: some View { Text("x") }
            }
            """) == 0)
    }
}
