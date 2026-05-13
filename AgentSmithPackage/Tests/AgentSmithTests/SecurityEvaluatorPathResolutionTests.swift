import Testing
import Foundation
@testable import AgentSmithKit

@Suite("SecurityEvaluator path resolution appendix")
struct SecurityEvaluatorPathResolutionTests {

    /// Returns a fresh test directory under a fully canonicalized temp root.
    /// Uses POSIX realpath so the baseline path has no aliases at all —
    /// otherwise `/var/folders/...` would still canonicalize to
    /// `/private/var/folders/...` and defeat the "no symlinks involved"
    /// tests, since the production code uses realpath for canonicalization.
    private func makeCanonicalTempDir() throws -> URL {
        let raw = NSTemporaryDirectory()
        let canonical = SecurityEvaluator.canonicalizeViaRealpath(raw) ?? raw
        let dir = URL(fileURLWithPath: canonical)
            .appendingPathComponent("agent-smith-path-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("symlinked task path and canonical tool path produce appendix listing both")
    func symlinkedTaskAndCanonicalTool() throws {
        let tmp = try makeCanonicalTempDir()
        defer { cleanup(tmp) }

        let realDir = tmp.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realFile = realDir.appendingPathComponent("file.txt")
        try Data().write(to: realFile)

        let aliasLink = tmp.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: aliasLink, withDestinationURL: realDir)

        let taskDesc = "Please work in \(aliasLink.path)/"
        let toolParams = "{\"path\":\"\(realFile.path)\"}"

        let appendix = SecurityEvaluator.pathResolutionAppendix(
            taskDescription: taskDesc, toolName: "file_read", toolParams: toolParams
        )

        let text = try #require(appendix)
        #expect(text.contains("Path resolutions"))
        #expect(text.contains(aliasLink.path))
        #expect(text.contains(realDir.path))
        #expect(text.contains(realFile.path))
    }

    @Test("identical real paths with no symlinks return nil — no noise in prompt")
    func noSymlinksReturnsNil() throws {
        let tmp = try makeCanonicalTempDir()
        defer { cleanup(tmp) }

        let realFile = tmp.appendingPathComponent("file.txt")
        try Data().write(to: realFile)

        let taskDesc = "Work on \(tmp.path)"
        let toolParams = "{\"path\":\"\(realFile.path)\"}"

        let appendix = SecurityEvaluator.pathResolutionAppendix(
            taskDescription: taskDesc, toolName: "file_read", toolParams: toolParams
        )

        #expect(appendix == nil)
    }

    @Test("file_write content field is not scanned for path tokens")
    func contentFieldNotScanned() throws {
        let tmp = try makeCanonicalTempDir()
        defer { cleanup(tmp) }

        let realDir = tmp.appendingPathComponent("real-content-skip")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let aliasLink = tmp.appendingPathComponent("alias-content-skip")
        try FileManager.default.createSymbolicLink(at: aliasLink, withDestinationURL: realDir)

        let newPath = tmp.appendingPathComponent("brand-new.txt").path
        let dict: [String: Any] = [
            "path": newPath,
            "content": "Edit your config under \(aliasLink.path) before running"
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let toolParams = try #require(String(data: data, encoding: .utf8))

        let appendix = SecurityEvaluator.pathResolutionAppendix(
            taskDescription: nil, toolName: "file_write", toolParams: toolParams
        )

        #expect(appendix == nil)
    }

    @Test("file_edit old_string and new_string fields are not scanned for path tokens")
    func fileEditStringFieldsNotScanned() throws {
        let tmp = try makeCanonicalTempDir()
        defer { cleanup(tmp) }

        let realDir = tmp.appendingPathComponent("real-edit-skip")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let aliasLink = tmp.appendingPathComponent("alias-edit-skip")
        try FileManager.default.createSymbolicLink(at: aliasLink, withDestinationURL: realDir)

        let target = tmp.appendingPathComponent("target.txt")
        try Data().write(to: target)

        let dict: [String: Any] = [
            "file_path": target.path,
            "old_string": "see \(aliasLink.path)",
            "new_string": "see \(aliasLink.path)/here",
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let toolParams = try #require(String(data: data, encoding: .utf8))

        let appendix = SecurityEvaluator.pathResolutionAppendix(
            taskDescription: nil, toolName: "file_edit", toolParams: toolParams
        )

        #expect(appendix == nil)
    }

    @Test("non-existent path produces no resolution entry")
    func nonExistentNoEntry() {
        let phantom = "/definitely/does/not/exist/path-\(UUID().uuidString)"
        let taskDesc = "Look at \(phantom) and \(phantom)/sub"
        let toolParams = "{\"path\":\"\(phantom)/file.txt\"}"

        let appendix = SecurityEvaluator.pathResolutionAppendix(
            taskDescription: taskDesc, toolName: "file_read", toolParams: toolParams
        )

        #expect(appendix == nil)
    }

    @Test("file:// URL with percent-encoded space resolves through /tmp symlink")
    func fileURLPercentEncoded() throws {
        let unique = "spc \(UUID().uuidString).txt"
        let writePath = "/tmp/\(unique)"
        defer { try? FileManager.default.removeItem(atPath: writePath) }
        try Data().write(to: URL(fileURLWithPath: writePath))

        let percentEncoded = unique.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? unique
        let url = "file:///tmp/\(percentEncoded)"
        let taskDesc = "Inspect \(url) for context"

        let appendix = SecurityEvaluator.pathResolutionAppendix(
            taskDescription: taskDesc, toolName: "file_read", toolParams: "{}"
        )

        let text = try #require(appendix)
        #expect(text.contains("/private/tmp/\(unique)"))
    }

    @Test("more than max candidates does not crash or hang")
    func candidateCap() {
        var pieces: [String] = []
        for i in 0..<(SecurityEvaluator.maxPathResolutionCandidates * 2) {
            pieces.append("/tmp/cap-test-\(i)-\(UUID().uuidString)")
        }
        let taskDesc = pieces.joined(separator: " ")

        let appendix = SecurityEvaluator.pathResolutionAppendix(
            taskDescription: taskDesc, toolName: "file_read", toolParams: "{}"
        )
        #expect(appendix == nil)
    }

    @Test("text scanner extracts ~/ and / paths and strips trailing punctuation")
    func textScannerBasic() {
        let text = "Please work in ~/cursor/yt-best-practices/, then check /etc/hosts."
        let paths = SecurityEvaluator.collectPathStringsFromText(text)
        #expect(paths.contains("~/cursor/yt-best-practices/"))
        #expect(paths.contains("/etc/hosts"))
    }

    @Test("text scanner extracts file:// URL")
    func textScannerFileURL() {
        let text = "Open file:///tmp/x.txt for context"
        let paths = SecurityEvaluator.collectPathStringsFromText(text)
        #expect(paths.contains(where: { $0.hasPrefix("file:///tmp/x.txt") }))
    }

    @Test("expandToAbsolutePath handles tilde, file://, absolute, and rejects relative")
    func expandRules() {
        #expect(SecurityEvaluator.expandToAbsolutePath("~/foo") == NSString(string: "~/foo").expandingTildeInPath)
        #expect(SecurityEvaluator.expandToAbsolutePath("/abs/path") == "/abs/path")
        #expect(SecurityEvaluator.expandToAbsolutePath("file:///tmp/x") == "/tmp/x")
        #expect(SecurityEvaluator.expandToAbsolutePath("relative/path") == nil)
        #expect(SecurityEvaluator.expandToAbsolutePath("./relative") == nil)
    }

    @Test("JSON walker collects path-like values, skipping content keys")
    func jsonWalkerSkipsContent() throws {
        let dict: [String: Any] = [
            "path": "/tmp/foo.txt",
            "content": "/etc/hosts data",
            "nested": ["working_directory": "/usr/local/bin"]
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let obj = try JSONSerialization.jsonObject(with: data)
        var out: [String] = []
        SecurityEvaluator.collectPathStringsFromJSON(obj, skipKeys: ["content"], out: &out)
        #expect(out.contains("/tmp/foo.txt"))
        #expect(out.contains("/usr/local/bin"))
        #expect(!out.contains(where: { $0.contains("/etc/hosts") }))
    }

    @Test("JSON walker only treats strings beginning with /, ~/, or file:// as paths")
    func jsonWalkerStrictPrefix() throws {
        let dict: [String: Any] = [
            "command": "ls -la",
            "comment": "this references /etc/hosts inline",
            "abs": "/etc/hosts",
            "tilde": "~/code",
            "url": "file:///tmp/x",
            "relative": "./local"
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let obj = try JSONSerialization.jsonObject(with: data)
        var out: [String] = []
        SecurityEvaluator.collectPathStringsFromJSON(obj, skipKeys: [], out: &out)
        #expect(out.contains("/etc/hosts"))
        #expect(out.contains("~/code"))
        #expect(out.contains("file:///tmp/x"))
        #expect(!out.contains("ls -la"))
        #expect(!out.contains("./local"))
        #expect(!out.contains(where: { $0.contains("inline") }))
    }
}
