import Testing
import Foundation

/// Source-level guard against the data-loss class that wiped a month of
/// `usage_records.json` on 2026-05-13. The shape of that bug:
///
/// 1. A test constructed `PersistenceManager()` directly, which resolves to
///    `~/Library/Application Support/AgentSmith/` — the real app's data path.
/// 2. That manager was wired into a `UsageStore` without calling `load()`,
///    so its in-memory `records` array was empty.
/// 3. A subsequent `usageStore.append(...)` scheduled a coalesced 5-second
///    flush that wrote `[only-test-records]` to disk, overwriting the user's
///    real file.
///
/// This guard scans every `.swift` file under the test target and fails if it
/// finds `PersistenceManager()` or `PersistenceManager(sessionID:` — both
/// inits route through the real Application Support path. Tests must use
/// `PersistenceManager(testingRoot:)` and direct it at a per-test temp
/// directory.
///
/// If you have a legitimate reason to use the real-data inits from a test
/// (e.g. you're explicitly verifying production paths), add the file to
/// `Self.allowedFiles` with a comment explaining why — and only if your test
/// CANNOT trigger any `save*` write against the manager.
@Suite("PersistenceManager test-usage guard")
struct PersistenceManagerTestUsageGuardTests {

    /// Files explicitly allowed to use the real-data inits. Empty today —
    /// no test in the tree should need them. Adding an entry here is a
    /// reviewer-attention moment.
    private static let allowedFiles: Set<String> = []

    @Test("No test file constructs PersistenceManager() or PersistenceManager(sessionID:)")
    func noRealDataInits() throws {
        let testRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let enumerator = FileManager.default.enumerator(
            at: testRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Could not enumerate test directory at \(testRoot.path)")
            return
        }

        // Match the two real-data inits but NOT `PersistenceManager(testingRoot:`.
        // The lookbehind-style negative is awkward in NSRegularExpression, so we
        // match the full forbidden forms explicitly:
        //   PersistenceManager()
        //   PersistenceManager(sessionID:
        // Anything else — including `(testingRoot:` — is allowed.
        let forbidden = try NSRegularExpression(
            pattern: #"PersistenceManager\(\s*\)|PersistenceManager\(\s*sessionID\s*:"#,
            options: []
        )

        var violations: [(file: String, line: Int, text: String)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            // Don't scan this guard file itself — its doc comments mention the
            // forbidden forms in prose, which the regex would otherwise flag.
            if url.lastPathComponent == "PersistenceManagerTestUsageGuardTests.swift" { continue }
            if Self.allowedFiles.contains(url.lastPathComponent) { continue }

            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else { continue }

            content.enumerateLines { line, _ in
                // Skip comment lines so doc/inline commentary about the API
                // doesn't trip the guard.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    return
                }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if forbidden.firstMatch(in: line, options: [], range: range) != nil {
                    violations.append((file: url.lastPathComponent, line: 0, text: line))
                }
            }
        }

        if !violations.isEmpty {
            let summary = violations.map { v in
                "  \(v.file):  \(v.text.trimmingCharacters(in: .whitespaces))"
            }.joined(separator: "\n")
            Issue.record(
                """
                Found test code using a real-data `PersistenceManager` init. This routes \
                to `~/Library/Application Support/AgentSmith/` and can overwrite the \
                user's real `usage_records.json` (and other shared files). Use \
                `PersistenceManager(testingRoot:)` instead.

                \(summary)
                """
            )
        }
    }
}
