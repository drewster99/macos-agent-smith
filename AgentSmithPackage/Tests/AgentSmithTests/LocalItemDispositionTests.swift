import Foundation
import Testing
@testable import AgentSmithKit

/// Clicking a path an agent named must never launch it. The defect this pins: every directory went
/// to `NSWorkspace.open`, and an `.app` is a directory — so a model-authored link to one ran it.
@Suite("Local item disposition — clicking an agent-named path never launches it")
struct LocalItemDispositionTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A temp folder that couldn't be cleaned up is reported, not ignored.
    private func remove(_ dir: URL) {
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            Issue.record("could not remove temp folder \(dir.path): \(error)")
        }
    }

    private func makeDirectory(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func makeLink(_ name: String, to destination: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }

    @Test("An app bundle is revealed, not opened")
    func appIsRevealed() throws {
        let dir = try tempDir()
        defer { remove(dir) }
        let app = try makeDirectory("Tool.app", in: dir)
        guard case .reveal(let target) = LocalItemDisposition.disposition(for: app) else {
            Issue.record("expected .reveal")
            return
        }
        #expect(target.lastPathComponent == "Tool.app")
    }

    @Test("A symlink to an app reveals the app it points at")
    func symlinkToAppIsRevealed() throws {
        let dir = try tempDir()
        defer { remove(dir) }
        let app = try makeDirectory("Tool.app", in: dir)
        for link in [try makeLink("Absolute", to: app.path, in: dir),
                     try makeLink("Relative", to: "Tool.app", in: dir)] {
            guard case .reveal(let target) = LocalItemDisposition.disposition(for: link) else {
                Issue.record("expected .reveal for \(link.lastPathComponent)")
                continue
            }
            #expect(target.lastPathComponent == "Tool.app")
        }
    }

    @Test("A non-app package is revealed")
    func bundleIsRevealed() throws {
        let dir = try tempDir()
        defer { remove(dir) }
        let bundle = try makeDirectory("Thing.bundle", in: dir)
        guard case .reveal = LocalItemDisposition.disposition(for: bundle) else {
            Issue.record("expected .reveal")
            return
        }
    }

    @Test("A plain folder, directly or through a symlink, is browsed")
    func plainFolderIsBrowsed() throws {
        let dir = try tempDir()
        defer { remove(dir) }
        let plain = try makeDirectory("Plain", in: dir)
        for url in [plain, try makeLink("PlainLink", to: "Plain", in: dir)] {
            guard case .browse(let target) = LocalItemDisposition.disposition(for: url) else {
                Issue.record("expected .browse for \(url.lastPathComponent)")
                continue
            }
            #expect(target.lastPathComponent == "Plain")
        }
    }

    @Test("A file — even one named like an app — is previewed, through a symlink too")
    func fileIsPreviewed() throws {
        let dir = try tempDir()
        defer { remove(dir) }
        let note = try makeFile("note.txt", in: dir)
        let fakeApp = try makeFile("Evil.app", in: dir)
        let link = try makeLink("NoteLink", to: "note.txt", in: dir)
        for (url, expectedName) in [(note, "note.txt"), (fakeApp, "Evil.app"), (link, "note.txt")] {
            guard case .preview(let target) = LocalItemDisposition.disposition(for: url) else {
                Issue.record("expected .preview for \(url.lastPathComponent)")
                continue
            }
            #expect(target.lastPathComponent == expectedName)
        }
    }

    @Test("A missing path and a dangling symlink are missing")
    func missingAndDangling() throws {
        let dir = try tempDir()
        defer { remove(dir) }
        let dangling = try makeLink("Dangle", to: dir.appendingPathComponent("Gone.app").path, in: dir)
        #expect(LocalItemDisposition.disposition(for: dir.appendingPathComponent("absent")) == .missing)
        #expect(LocalItemDisposition.disposition(for: dangling) == .missing)
    }
}
