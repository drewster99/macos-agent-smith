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
    /// is why there are ~184 `-> some View` functions and zero `some View` properties: the guard
    /// worked, and everyone followed its instructions into the other half of the same rule. See
    /// `someViewFunctionRatchet` below, which holds that number still.
    @Test("No `: some View` properties besides body in app target")
    func noSomeViewProperties() throws {
        var hits: [String] = []
        let rootPath = Self.appTargetRoot.path
        for url in Self.swiftFiles() {
            let relative = url.path.replacingOccurrences(of: rootPath + "/", with: "")
            let source = Self.strippingComments(try String(contentsOf: url, encoding: .utf8))
            for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where Self.declaresSomeViewProperty(line: String(line)) {
                hits.append("  \(relative):\(offset + 1) — \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        if !hits.isEmpty {
            Issue.record("""
                Found `: some View` properties (extract a `View` struct — do NOT convert to a \
                @ViewBuilder func, which violates the same rule):
                \(hits.joined(separator: "\n"))
                """)
        }
    }

    /// Whether one line declares a non-`body` stored/computed property of type `some View`.
    ///
    /// Deliberately NOT the modifier-alternation regex this replaced. That one matched only bare
    /// `var` and `private `/`fileprivate  var`, required exactly one space after the colon, and
    /// required `@ViewBuilder` to sit on its OWN line — so `public var x: some View`,
    /// `private(set) var x: some View`, `@MainActor var x: some View`, `var x:  some View` and a
    /// single-line `@ViewBuilder var x: some View` all sailed past a guard that looked strict.
    /// Tokenizing sidesteps the whole family: find `var`, take the next identifier, check the type.
    static func declaresSomeViewProperty(line: String) -> Bool {
        // Normalize so spacing and attribute placement cannot matter.
        let collapsed = line.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        guard let typeRange = collapsed.range(of: ": some View") else { return false }
        // Everything before the colon must end in `var <identifier>`; `let` cannot be `some View`
        // in a stored property, and a function's `->` return never reaches here.
        let head = collapsed[collapsed.startIndex..<typeRange.lowerBound]
        let words = head.split(separator: " ").map(String.init)
        guard words.count >= 2, let name = words.last else { return false }
        guard words[words.count - 2] == "var" else { return false }
        return name != "body"
    }

    /// Every spelling the previous modifier-alternation regex let through.
    ///
    /// It matched only bare `var` and `private `/`fileprivate  var`, demanded exactly one space
    /// after the colon, and required `@ViewBuilder` to sit on its own line. So the guard read as
    /// strict while six ordinary spellings walked past it. None of these are exotic — `public var`
    /// and a single-line `@ViewBuilder` are what someone writes without thinking.
    @Test("The property guard catches every modifier spelling, not just `private var`")
    func propertyGuardIsNotEvadable() {
        let shouldCatch = [
            "var chip: some View",
            "private var chip: some View",
            "fileprivate var chip: some View",
            "public var chip: some View",                 // missed before
            "internal var chip: some View",               // missed before
            "static var chip: some View",                 // missed before
            "private(set) var chip: some View",           // missed before
            "@MainActor var chip: some View",             // missed before
            "@ViewBuilder var chip: some View",           // missed before (same-line attribute)
            "private @ViewBuilder var chip: some View",   // missed before (modifier order)
            "var chip:  some View",                       // missed before (two spaces)
            "    @ViewBuilder public var chip : some View"
        ]
        for line in shouldCatch {
            #expect(CodeStyleGuardTests.declaresSomeViewProperty(line: line), "missed: \(line)")
        }

        let shouldAllow = [
            "var body: some View",
            "    var body: some View {",
            "@ViewBuilder var body: some View",
            "private func chip() -> some View {",          // the function form, counted elsewhere
            "func body(content: Content) -> some View {",
            "let text: String",
            "var isExpanded: Bool = false"
        ]
        for line in shouldAllow {
            #expect(!CodeStyleGuardTests.declaresSomeViewProperty(line: line), "false positive: \(line)")
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
            Issue.record("Found .onTapGesture (use Button(action:label:) + .buttonStyle(.plain) instead):\n\(formatted)")
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
        "Views/TaskListView.swift": 4,
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
    private static let someViewFunctionTotal = 130

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

    // MARK: - Multiple trailing closures

    /// The package's own source roots, scanned alongside the app target.
    ///
    /// Deliberately `Sources/` and `Tests/` rather than the package directory:
    /// `.build/checkouts` holds ~164 multiple-trailing-closure hits in vendored code (swift-nio
    /// alone accounts for most of them). Today `.skipsHiddenFiles` keeps them out, but making
    /// that option load-bearing for a ZERO-TOLERANCE guard is one config edit away from 164
    /// lines of noise. Rooting below `.build` makes the vendored code unreachable by
    /// construction instead.
    static var packageSourceRoots: [URL] {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()  // .../AgentSmithTests/
        url.deleteLastPathComponent()  // .../Tests/
        return [
            url.appendingPathComponent("Sources", isDirectory: true),
            url.appendingPathComponent("Tests", isDirectory: true)
        ]
    }

    /// Yields every `.swift` file under `root`.
    static func swiftFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// Blanks `//` and `/* */` comments AND every string literal — single-line, multiline `"""`,
    /// and raw `#"…"#` at any pound depth — replacing each consumed character with a space and
    /// preserving newlines, so a line number computed on the result matches the original source.
    ///
    /// ONE pass, not `strippingComments` composed with a string stripper: either composition
    /// order corrupts real code in this repo. Comments-first blanks a `//` that is INSIDE a
    /// string, leaving a dangling `"` that swallows the rest of the line. Strings-first
    /// mis-tokenizes `ChannelLogView.remainderWithoutPath`, a raw string containing an internal
    /// `"` followed on the same line by a comment that also contains `"`.
    ///
    /// Raw-string awareness is required rather than defensive: that same function holds
    /// `#"\{\s*,"#` and `#",\s*\}"#`, which a naive scanner terminates at the wrong quote.
    static func strippingCommentsAndStringLiterals(_ source: String) -> String {
        var out = Array(source)
        let count = out.count
        var index = 0

        func matches(_ at: Int, _ needle: [Character]) -> Bool {
            guard at + needle.count <= count else { return false }
            for (offset, character) in needle.enumerated() where out[at + offset] != character {
                return false
            }
            return true
        }
        func blank(_ from: Int, _ to: Int) {
            for position in from..<min(to, count) where out[position] != "\n" { out[position] = " " }
        }

        while index < count {
            let character = out[index]
            if character == "/", matches(index, ["/", "/"]) {
                var end = index
                while end < count, out[end] != "\n" { end += 1 }
                blank(index, end)
                index = end
                continue
            }
            if character == "/", matches(index, ["/", "*"]) {
                var depth = 1
                var end = index + 2
                while end < count, depth > 0 {
                    if matches(end, ["/", "*"]) { depth += 1; end += 2 }
                    else if matches(end, ["*", "/"]) { depth -= 1; end += 2 }
                    else { end += 1 }
                }
                blank(index, end)
                index = end
                continue
            }
            if character == "#" || character == "\"" {
                var quote = index
                while quote < count, out[quote] == "#" { quote += 1 }
                let pounds = quote - index
                guard quote < count, out[quote] == "\"" else {
                    index += max(pounds, 1)
                    continue
                }
                let tail = String(repeating: "#", count: pounds)
                let isMultiline = quote + 2 < count && out[quote + 1] == "\"" && out[quote + 2] == "\""
                let closing = Array((isMultiline ? "\"\"\"" : "\"") + tail)
                let escape = Array("\\" + tail)
                var end = quote + (isMultiline ? 3 : 1)
                while end < count {
                    if matches(end, escape) { end += escape.count + 1; continue }
                    // An unterminated single-line literal resyncs at the newline. Running to
                    // endIndex instead would blank the remainder of the file and silently hide
                    // every real violation below it.
                    if !isMultiline, out[end] == "\n" { break }
                    if matches(end, closing) { end += closing.count; break }
                    end += 1
                }
                blank(index, min(end, count))
                index = min(end, count)
                continue
            }
            index += 1
        }
        return String(out)
    }

    /// A `}` closing one trailing closure followed by `identifier: {` opening the next — Swift's
    /// SE-0279 multiple-trailing-closure syntax.
    ///
    /// Newline-tolerant. `}\nlabel: {` is legal Swift and no instance exists today, so a
    /// same-line pattern would read as complete while leaving a spelling that evades it forever.
    ///
    /// The false-positive surface is empty for a structural reason, not a lucky one: every Swift
    /// labelled statement requires a KEYWORD between the label and the brace (`while`, `for`,
    /// `repeat`, `if`, `switch`, `do`), and every declaration requires a TYPE between the colon
    /// and the brace. So `} outer: while x {`, `} var x: Int { 3 }`, `} struct Foo: Bar {` and
    /// `} where T: Foo {` cannot match, and `} else: {` / `} catch: {` are not legal Swift at all.
    /// The correct spelling `}, label: {` cannot match either — a comma is neither whitespace nor
    /// an identifier character.
    private static let multipleTrailingClosurePattern =
        #"\}\s*[A-Za-z_][A-Za-z0-9_]*\s*:\s*\{"#

    /// Multiple trailing closures are forbidden by the project Swift style rule.
    /// Write `Button(action: { … }, label: { … })`, never `Button { … } label: { … }`.
    ///
    /// ZERO TOLERANCE, not a ratchet — deliberately unlike `someViewFunctionRatchet` above. Every
    /// entry in that table is a design decision (which `View` struct, what does it own), so it is
    /// paid down over time. These are compiler-verified syntax swaps with no design content: the
    /// whole debt was payable in one pass and was paid, so a budget would preserve it rather than
    /// manage it. `excluded` is the escape hatch if a case ever genuinely earns one; it ships
    /// empty, and an exemption has to be named here rather than silently absorbed by a ceiling.
    ///
    /// Nothing about a rewritten call changes: `label:`, `content:`, `actions:`, `message:`,
    /// `detail:` are already `@ViewBuilder` parameters, and the result-builder transform attaches
    /// to the parameter DECLARATION (SE-0289), not the call site.
    @Test("No multiple trailing closures (app target + package)")
    func noMultipleTrailingClosures() throws {
        let excluded: [String] = []
        let pattern = try NSRegularExpression(pattern: Self.multipleTrailingClosurePattern)
        var hits: [String] = []

        for root in [Self.appTargetRoot] + Self.packageSourceRoots {
            let prefix = root.deletingLastPathComponent().path + "/"
            for url in Self.swiftFiles(under: root) {
                let relative = url.path.replacingOccurrences(of: prefix, with: "")
                if excluded.contains(where: { relative.hasSuffix($0) }) { continue }

                let source = Self.strippingCommentsAndStringLiterals(
                    try String(contentsOf: url, encoding: .utf8)
                )
                let range = NSRange(source.startIndex..<source.endIndex, in: source)
                for match in pattern.matches(in: source, options: [], range: range) {
                    guard let found = Range(match.range, in: source) else { continue }
                    let line = source[..<found.lowerBound].filter { $0 == "\n" }.count + 1
                    let text = source[found].replacingOccurrences(
                        of: #"\s+"#, with: " ", options: .regularExpression
                    )
                    hits.append("  \(relative):\(line) — \(text)")
                }
            }
        }

        if !hits.isEmpty {
            Issue.record("""
                Found multiple trailing closures. Move every closure but the last into parameter \
                position — e.g. `Button(action: { … }, label: { … })`. Put the closing `)` BEFORE \
                any trailing modifier: a `)` that lands after `.buttonStyle`/`.disabled` compiles \
                and silently applies the modifier to the label instead of the control.
                \(hits.sorted().joined(separator: "\n"))
                """)
        }
    }

    /// The stripper is the only thing standing between prose and a hard RED on a zero-tolerance
    /// guard, so it is pinned rather than trusted.
    ///
    /// Not hypothetical: this file's own `noOnTapGesture` message used to contain the literal
    /// text `Button { } label: { }`, and `someViewFunctionCount` above carries a documented
    /// history of a counter inflated by a `// MARK:` recording that a violation had been REMOVED.
    @Test("The multiple-trailing-closure guard reads code, not prose or string literals")
    func multipleTrailingClosureGuardReadsCodeOnly() throws {
        let pattern = try NSRegularExpression(pattern: Self.multipleTrailingClosurePattern)
        func fires(_ source: String) -> Bool {
            let stripped = Self.strippingCommentsAndStringLiterals(source)
            #expect(
                stripped.filter { $0 == "\n" }.count == source.filter { $0 == "\n" }.count,
                "the stripper changed the newline count — reported line numbers would be wrong"
            )
            let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            return pattern.firstMatch(in: stripped, options: [], range: range) != nil
        }

        // Prose and literals are not code.
        #expect(!fires("// Button { } label: { }"))
        #expect(!fires("/* } label: { */"))
        #expect(!fires("/* /* } label: { */ */"))
        #expect(!fires("let s = \"} label: {\""))
        #expect(!fires("let s = \"a\\\\\"\nlet t = 1"))          // escaped backslash ends it
        #expect(!fires("let s = \"a\\\"b } label: { \""))         // escaped quote does not
        #expect(!fires("let s = #\"} label: {\"#"))               // raw
        #expect(!fires("let s = #\"a\"b } label: { \"#"))         // raw, internal quote
        #expect(!fires("let s = ##\"a\"# } label: { \"##"))       // pound depth 2
        #expect(!fires("let s = \"\"\"\n} label: {\n\"\"\""))     // multiline
        #expect(!fires("let s = \"\"\"\n  } label: {\n  \"\"\"")) // indented close delimiter
        #expect(!fires("let u = \"http://x } label: { y\""))      // `//` inside a string
        #expect(!fires("// he said \"hi\" } label: { "))          // quote inside a comment
        #expect(!fires("let s = \"\\(xs.map { $0 }.count)\""))    // braces in interpolation

        // Legal Swift that merely resembles the pattern.
        #expect(!fires("}\nouter: do {"))
        #expect(!fires("}\nloop: while x {"))
        #expect(!fires("} var x: Int { 3 }"))
        #expect(!fires("} var x: Set<Int> = { [] }()"))
        #expect(!fires("} struct Foo: Bar {"))
        #expect(!fires("foo(a: { 1 }, b: { 2 })"))

        // Violations, including the nested case a hand-rewrite is most likely to corrupt.
        #expect(fires("Button {\n} label: {\n}"))
        #expect(fires("Button {\n}\nlabel: {\n}"))                // newline-tolerant
        #expect(fires("let s = #\"\\{\\s*,\"#\nButton {\n} label: {\n}"))
        // The required spelling must never be flagged, or the fix would fail the guard.
        #expect(!fires("Button(action: {\n    act()\n}, label: {\n    Text(\"go\")\n})"))
    }

}
