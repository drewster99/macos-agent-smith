import Testing
import Foundation
@testable import AgentSmithKit

@Suite("DirectoryListingTool")
struct DirectoryListingToolTests {

    @Test("lists files + dirs with type/size/mtime and dirs-first ordering")
    func basicListing() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("package", to: "Package.swift")
        _ = try dir.write("readme content here, a bit longer than the other one", to: "README.md")
        // A subdir (creates the dir via `write`'s mkdir).
        _ = try dir.write("a", to: "Sources/App.swift")

        let r = try await DirectoryListingTool().execute(
            arguments: ["path": .string(dir.path)],
            context: TestToolContext.make()
        )
        #expect(r.succeeded)
        let out = r.output
        #expect(out.contains("Contents of"))
        // 3 entries at the listing level (Package.swift, README.md, Sources/).
        #expect(out.contains("3 entries"))
        // Dir name suffixed with `/`.
        #expect(out.contains("Sources/"))
        #expect(out.contains("Package.swift"))
        #expect(out.contains("README.md"))
    }

    @Test("filter narrows results to matching basenames")
    func filterApplied() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "Package.swift")
        _ = try dir.write("b", to: "Util.swift")
        _ = try dir.write("c", to: "README.md")

        let r = try await DirectoryListingTool().execute(
            arguments: ["path": .string(dir.path), "filter": .string("*.swift")],
            context: TestToolContext.make()
        )
        #expect(r.succeeded)
        #expect(r.output.contains("Package.swift"))
        #expect(r.output.contains("Util.swift"))
        #expect(!r.output.contains("README.md"))
        #expect(r.output.contains("matching '*.swift'"))
    }

    @Test("show_hidden_files=false drops dotfiles; true keeps them")
    func showHiddenToggle() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("v", to: "Visible.swift")
        _ = try dir.write("h", to: ".env")

        let hidden = try await DirectoryListingTool().execute(
            arguments: ["path": .string(dir.path)],
            context: TestToolContext.make()
        )
        #expect(hidden.succeeded)
        #expect(!hidden.output.contains(".env"))

        let shown = try await DirectoryListingTool().execute(
            arguments: ["path": .string(dir.path), "show_hidden_files": .bool(true)],
            context: TestToolContext.make()
        )
        #expect(shown.succeeded)
        #expect(shown.output.contains(".env"))
    }

    @Test("limit + offset page past the cap and the trailer names the next offset")
    func limitOffsetPaging() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        for i in 0..<10 {
            _ = try dir.write("\(i)", to: "file_\(String(format: "%02d", i)).txt")
        }

        let page1 = try await DirectoryListingTool().execute(
            arguments: ["path": .string(dir.path), "limit": .int(3), "sort": .string("name")],
            context: TestToolContext.make()
        )
        #expect(page1.succeeded)
        let out1 = page1.output
        #expect(out1.contains("showing 1–3"))
        #expect(out1.contains("offset=3"))
        // Page 1 contains the first three (by name).
        #expect(out1.contains("file_00.txt"))
        #expect(out1.contains("file_02.txt"))
        #expect(!out1.contains("file_03.txt"))

        let page2 = try await DirectoryListingTool().execute(
            arguments: ["path": .string(dir.path), "limit": .int(3), "offset": .int(3), "sort": .string("name")],
            context: TestToolContext.make()
        )
        #expect(page2.succeeded)
        let out2 = page2.output
        #expect(out2.contains("showing 4–6"))
        #expect(out2.contains("file_03.txt"))
        #expect(out2.contains("file_05.txt"))
        #expect(!out2.contains("file_00.txt"))
    }

    @Test("empty directory returns a clear single-line message")
    func emptyDirectory() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }

        let r = try await DirectoryListingTool().execute(
            arguments: ["path": .string(dir.path)],
            context: TestToolContext.make()
        )
        #expect(r.succeeded)
        #expect(r.output.contains("is empty"))
    }

    @Test("offset past the end is reported clearly (not silently empty)")
    func offsetPastEnd() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "only.txt")

        let r = try await DirectoryListingTool().execute(
            arguments: ["path": .string(dir.path), "offset": .int(50)],
            context: TestToolContext.make()
        )
        #expect(r.succeeded)
        #expect(r.output.contains("past the end"))
    }
}
