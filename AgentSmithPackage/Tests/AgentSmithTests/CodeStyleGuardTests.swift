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
    /// The fix is to convert to `@ViewBuilder` functions.
    @Test("No `: some View` properties besides body in app target")
    func noSomeViewProperties() throws {
        // Match `[@ViewBuilder] [private] var <name>: some View` where name != body
        let hits = try Self.scan(
            regex: #"^\s*(@ViewBuilder\s*\n\s*)?(private |fileprivate )?var (?!body\b)[a-zA-Z_][a-zA-Z0-9_]*: some View\b"#
        )
        if !hits.isEmpty {
            let formatted = hits.map { "  \($0.path):\($0.line) — \($0.text)" }.joined(separator: "\n")
            Issue.record("Found `: some View` properties (use @ViewBuilder funcs instead):\n\(formatted)")
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
}
