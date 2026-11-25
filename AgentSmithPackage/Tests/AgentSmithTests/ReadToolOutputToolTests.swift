import Foundation
import Testing
@testable import AgentSmithKit

/// A fresh root for saved tool output, removed afterwards — never the one the running app uses.
private func withSpillRoot<Result>(_ body: (URL) async throws -> Result) async throws -> Result {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("spilled-tool-output-tests-\(UUID().uuidString)", isDirectory: true)
    defer {
        do {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        } catch {
            Issue.record("could not remove \(root.path): \(error)")
        }
    }
    return try await body(root)
}

/// `SpilledToolOutputStore` keeps each owner's saved tool output in its own folder, so a handle
/// reaches only what that owner saved (`docs/plans/SpilledToolOutputByHandle.md`).
@Suite("SpilledToolOutputStore")
struct SpilledToolOutputStoreTests {

    @Test("A task's output is saved in a folder named by the task id, under the root")
    func taskFolder() async throws {
        try await withSpillRoot { root in
            let taskID = UUID()
            let store = SpilledToolOutputStore.forTask(taskID, under: root)
            #expect(store.directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
            #expect(store.directory.lastPathComponent == taskID.uuidString)

            let handle = try store.save("full text")
            #expect(store.fileURL(forHandle: handle).path.hasPrefix(store.directory.path + "/"))
            #expect(try store.output(forHandle: handle) == "full text")
        }
    }

    @Test("An agent with no task gets its own folder, distinct from any task's")
    func agentFolder() async throws {
        try await withSpillRoot { root in
            let id = UUID()
            let agentStore = SpilledToolOutputStore.forAgent(id, under: root)
            #expect(agentStore.directory != SpilledToolOutputStore.forTask(id, under: root).directory)
            #expect(agentStore.directory.lastPathComponent.contains(id.uuidString))
        }
    }

    @Test("The production root is the app's tool-output folder under the OS temp dir")
    func productionRoot() {
        #expect(SpilledToolOutputStore.rootDirectory.lastPathComponent == "AgentSmith-tool-output")
        #expect(SpilledToolOutputStore.rootDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let taskID = UUID()
        #expect(SpilledToolOutputStore.forTask(taskID).directory.path
                == SpilledToolOutputStore.rootDirectory.appendingPathComponent(taskID.uuidString).path)
    }

    @Test("One task cannot load a handle another task saved")
    func crossTaskIsolation() async throws {
        try await withSpillRoot { root in
            let first = SpilledToolOutputStore.forTask(UUID(), under: root)
            let second = SpilledToolOutputStore.forTask(UUID(), under: root)
            let handle = try first.save("first task's output")
            #expect(try second.output(forHandle: handle) == nil)
            #expect(try first.output(forHandle: handle) == "first task's output")
        }
    }

    @Test("An unknown handle, and any handle before the first save, loads as nil")
    func unknownHandle() async throws {
        try await withSpillRoot { root in
            let store = SpilledToolOutputStore.forTask(UUID(), under: root)
            #expect(try store.output(forHandle: UUID()) == nil)
            _ = try store.save("x")
            #expect(try store.output(forHandle: UUID()) == nil)
        }
    }

    @Test("removeAll removes only this owner's output, and is not an error when nothing was saved")
    func removeAll() async throws {
        try await withSpillRoot { root in
            let first = SpilledToolOutputStore.forTask(UUID(), under: root)
            let second = SpilledToolOutputStore.forTask(UUID(), under: root)
            try first.removeAll()

            let firstHandle = try first.save("a")
            let secondHandle = try second.save("b")
            try first.removeAll()
            #expect(try first.output(forHandle: firstHandle) == nil)
            #expect(!FileManager.default.fileExists(atPath: first.directory.path))
            #expect(try second.output(forHandle: secondHandle) == "b")
        }
    }

    @Test("Ending a task's scratch also removes the output that task saved")
    func workspaceCleanupRemovesSavedOutput() throws {
        let workspace = TaskWorkspace(taskID: UUID(), workspaceRoot: nil)
        #expect(workspace.spilledToolOutputs == SpilledToolOutputStore.forTask(workspace.taskID))
        let handle = try workspace.spilledToolOutputs.save("saved by the task")
        workspace.cleanupTemporary()
        #expect(try workspace.spilledToolOutputs.output(forHandle: handle) == nil)
        #expect(!FileManager.default.fileExists(atPath: workspace.spilledToolOutputs.directory.path))
    }

    @Test("A tool context with no store of its own gets the agent's; a task's store is used as given")
    func contextDefault() async throws {
        let agentID = UUID()
        #expect(TestToolContext.make(agentID: agentID).spilledToolOutputs == SpilledToolOutputStore.forAgent(agentID))
        let taskStore = SpilledToolOutputStore.forTask(UUID())
        #expect(TestToolContext.make(agentID: agentID, spilledToolOutputs: taskStore).spilledToolOutputs == taskStore)
    }
}

/// `read_tool_output` pages and searches saved tool output by handle.
@Suite("ReadToolOutputTool")
struct ReadToolOutputToolTests {
    private static let handle = UUID()

    /// `count` lines: "line 1", "line 2", ….
    private static func numbered(_ count: Int) -> String {
        (1...count).map { "line \($0)" }.joined(separator: "\n")
    }

    /// The body lines of a result, without its header and footer.
    private static func body(_ result: ToolExecutionResult) -> [String] {
        Array(result.output.components(separatedBy: "\n").dropFirst().dropLast())
    }

    private static func footer(_ result: ToolExecutionResult) throws -> String {
        try #require(result.output.components(separatedBy: "\n").last)
    }

    /// The `startingLineNum` a result says to continue from, nil when it reports the end.
    private static func resumeLine(_ result: ToolExecutionResult) throws -> Int? {
        let footer = try footer(result)
        guard let match = footer.firstMatch(of: #/startingLineNum: (\d+)\]/#) else {
            #expect(footer == "[End of saved output]")
            return nil
        }
        return Int(match.1)
    }

    private static func page(_ text: String, from start: Int = 1, max: Int = ReadToolOutputTool.defaultMaxLines, pattern: String? = nil) throws -> ToolExecutionResult {
        try ReadToolOutputTool.page(
            of: text, handle: handle, startingLine: start, maxLines: max,
            pattern: try pattern.map { try NSRegularExpression(pattern: $0) }
        )
    }

    // MARK: Paging

    @Test("A page is cat -n lines, a header naming the span, and where to resume")
    func firstPage() throws {
        let result = try Self.page(Self.numbered(10), max: 3)
        #expect(result.succeeded)
        #expect(result.output.hasPrefix("[Saved tool output \(Self.handle.uuidString): lines 1–3 of 10]\n"))
        #expect(Self.body(result) == ["     1  line 1", "     2  line 2", "     3  line 3"])
        #expect(try Self.resumeLine(result) == 4)
        #expect(try Self.footer(result).contains(ReadToolOutputTool.toolName))
    }

    @Test("Following the resume line page by page returns every line exactly once, then the end")
    func pagesCoverEverything() throws {
        let text = Self.numbered(23)
        var collected: [String] = []
        var next: Int? = 1
        var pages = 0
        while let start = next {
            let result = try Self.page(text, from: start, max: 5)
            collected += Self.body(result)
            next = try Self.resumeLine(result)
            pages += 1
            try #require(pages <= 10, "paging did not terminate")
        }
        #expect(pages == 5)
        #expect(collected == (1...23).map { String(format: "%6d  ", $0) + "line \($0)" })
    }

    @Test("A page that reaches the last line exactly reports the end, not a further page")
    func exactEnd() throws {
        let result = try Self.page(Self.numbered(6), from: 4, max: 3)
        #expect(Self.body(result).count == 3)
        #expect(result.output.contains("lines 4–6 of 6"))
        #expect(try Self.resumeLine(result) == nil)
    }

    @Test("Starting past the end fails and says how many lines there are; the last line is valid")
    func startPastEnd() throws {
        let past = try Self.page(Self.numbered(4), from: 5)
        #expect(!past.succeeded)
        #expect(past.output.contains("4 lines"))
        #expect(Self.body(try Self.page(Self.numbered(4), from: 4)) == ["     4  line 4"])
    }

    @Test("A trailing line break adds no empty last line; blank lines inside are kept; CRLF is one break")
    func lineSplitting() {
        #expect(ReadToolOutputTool.numberedLines(of: "a\nb\n") == ["a", "b"])
        #expect(ReadToolOutputTool.numberedLines(of: "a\n\nb") == ["a", "", "b"])
        #expect(ReadToolOutputTool.numberedLines(of: "a\r\nb\r\n") == ["a", "b"])
        #expect(ReadToolOutputTool.numberedLines(of: "") == [""])
    }

    @Test("maxLines far beyond the content, even Int.max, returns the rest without trapping")
    func hugeMaxLines() throws {
        let result = try Self.page(Self.numbered(3), from: 2, max: Int.max)
        #expect(Self.body(result).count == 2)
        #expect(try Self.resumeLine(result) == nil)
    }

    // MARK: Long lines and the response ceiling

    @Test("A line longer than the limit is split into consecutive numbered lines that rejoin to it")
    func longLineSplit() throws {
        let limit = ReadToolOutputTool.maxLineCharacters
        let long = String(repeating: "ab", count: limit) + "tail"
        let lines = ReadToolOutputTool.numberedLines(of: "before\n\(long)\nafter")
        #expect(lines.count == 5)
        #expect(lines.first == "before" && lines.last == "after")
        #expect(lines[1].count == limit && lines[2].count == limit && lines[3] == "tail")
        #expect(lines[1...3].joined() == long)
        // Exactly at the limit is one line, with no empty piece after it.
        #expect(ReadToolOutputTool.numberedLines(of: String(repeating: "x", count: limit)).count == 1)
        #expect(ReadToolOutputTool.numberedLines(of: String(repeating: "x", count: limit + 1)).map(\.count) == [limit, 1])
    }

    @Test("Multibyte text is split between characters, never inside one")
    func longLineMultibyte() {
        let family = "👨‍👩‍👧‍👦"
        let long = String(repeating: family, count: ReadToolOutputTool.maxLineCharacters + 7)
        let lines = ReadToolOutputTool.numberedLines(of: long)
        #expect(lines.map(\.count) == [ReadToolOutputTool.maxLineCharacters, 7])
        #expect(lines.joined() == long)
    }

    @Test("One enormous line can be read to its last character, each response under the result cap")
    func singleLineOutputIsFullyReachable() throws {
        let text = String((0..<(ToolResultCap.maxCharacters * 3)).map { Character(String($0 % 10)) })
        var rebuilt = ""
        var next: Int? = 1
        var pages = 0
        while let start = next {
            let result = try Self.page(text, from: start, max: Int.max)
            #expect(result.output.count <= ToolResultCap.maxCharacters, "a page must never spill again")
            rebuilt += Self.body(result).map { String($0.dropFirst(8)) }.joined()
            next = try Self.resumeLine(result)
            pages += 1
            try #require(pages <= 100, "paging did not terminate")
        }
        #expect(pages > 1)
        #expect(rebuilt == text)
    }

    @Test("The response ceiling stops a page early and resumes at the first line it left out")
    func responseCeiling() throws {
        let line = String(repeating: "z", count: ReadToolOutputTool.maxLineCharacters)
        let perPage = ReadToolOutputTool.maxResponseCharacters / ReadToolOutputTool.maxLineCharacters
        let result = try Self.page(Array(repeating: line, count: perPage + 5).joined(separator: "\n"), max: 1_000)
        #expect(Self.body(result).count == perPage)
        #expect(try Self.resumeLine(result) == perPage + 1)
    }

    // MARK: Pattern

    @Test("With a pattern only matching lines are returned, under their original line numbers")
    func patternFilters() throws {
        let result = try Self.page(Self.numbered(30), pattern: "line \\d*5$")
        #expect(Self.body(result) == ["     5  line 5", "    15  line 15", "    25  line 25"])
        #expect(result.output.hasPrefix("[Saved tool output \(Self.handle.uuidString): 3 matching line(s) in lines 1–30 of 30]"))
        #expect(try Self.resumeLine(result) == nil)
    }

    @Test("maxLines counts MATCHES, and resuming with the same pattern pages the filtered output")
    func patternPagesByMatches() throws {
        // 100 lines, every 4th matches: 25 matches, paged 10 at a time.
        let text = (1...100).map { $0 % 4 == 0 ? "hit \($0)" : "miss \($0)" }.joined(separator: "\n")
        var matches: [String] = []
        var next: Int? = 1
        var pageSizes: [Int] = []
        while let start = next {
            let result = try Self.page(text, from: start, max: 10, pattern: "^hit")
            let body = Self.body(result)
            pageSizes.append(body.count)
            matches += body
            next = try Self.resumeLine(result)
            try #require(pageSizes.count <= 10, "paging did not terminate")
        }
        #expect(pageSizes == [10, 10, 5])
        #expect(matches == stride(from: 4, through: 100, by: 4).map { String(format: "%6d  ", $0) + "hit \($0)" })
    }

    @Test("A full page of matches resumes AT the next match, so no line is scanned twice or skipped")
    func patternResumePoint() throws {
        let text = "hit a\nmiss\nhit b\nmiss\nhit c"
        let first = try Self.page(text, max: 2, pattern: "hit")
        #expect(Self.body(first) == ["     1  hit a", "     3  hit b"])
        #expect(try Self.resumeLine(first) == 5)
        #expect(first.output.contains("in lines 1–4 of 5"))
        #expect(try Self.footer(first).contains("the same handle and pattern"))
        #expect(Self.body(try Self.page(text, from: 5, max: 2, pattern: "hit")) == ["     5  hit c"])
    }

    @Test("A full page whose matches are the last in the output reports the end")
    func patternExactlyFillsPage() throws {
        let result = try Self.page("hit\nhit\nmiss\nmiss", max: 2, pattern: "hit")
        #expect(Self.body(result).count == 2)
        #expect(try Self.resumeLine(result) == nil)
    }

    @Test("No match is a successful, empty answer that covers the whole output")
    func patternNoMatch() throws {
        let result = try Self.page(Self.numbered(5), pattern: "absent")
        #expect(result.succeeded)
        #expect(Self.body(result).isEmpty)
        #expect(result.output.contains("0 matching line(s) in lines 1–5 of 5"))
        #expect(try Self.resumeLine(result) == nil)
    }

    // MARK: execute

    private static func execute(_ arguments: [String: AnyCodable], store: SpilledToolOutputStore) async throws -> ToolExecutionResult {
        try await ReadToolOutputTool().execute(arguments: arguments, context: TestToolContext.make(spilledToolOutputs: store))
    }

    @Test("The handle in a capped result reads the full output back, page by page")
    func roundTripThroughTheCap() async throws {
        try await withSpillRoot { root in
            let store = SpilledToolOutputStore.forTask(UUID(), under: root)
            let original = (1...6_000).map { "entry number \($0)" }.joined(separator: "\n")
            try #require(original.count > ToolResultCap.maxCharacters)
            let capped = ToolResultCap.cap(original, spillingInto: store)
            let handleText = String(try #require(capped.firstMatch(of: #/saved under handle ([0-9A-Fa-f-]{36})\./#)).1)

            var lines: [String] = []
            var next: Int? = 1
            while let start = next {
                let result = try await Self.execute(["handle": .string(handleText), "startingLineNum": .int(start), "maxLines": .int(2_500)], store: store)
                try #require(result.succeeded, Comment(rawValue: result.output))
                #expect(ToolResultCap.cap(result.output, spillingInto: store) == result.output, "a page must never spill again")
                lines += Self.body(result).map { String($0.dropFirst(8)) }
                next = try Self.resumeLine(result)
                try #require(lines.count <= 6_000, "paging did not terminate")
            }
            #expect(lines.joined(separator: "\n") == original)
        }
    }

    @Test("Defaults: from line 1, the default page size")
    func defaults() async throws {
        try await withSpillRoot { root in
            let store = SpilledToolOutputStore.forTask(UUID(), under: root)
            let handle = try store.save(Self.numbered(ReadToolOutputTool.defaultMaxLines + 50))
            let result = try await Self.execute(["handle": .string(handle.uuidString)], store: store)
            #expect(Self.body(result).count == ReadToolOutputTool.defaultMaxLines)
            #expect(try Self.resumeLine(result) == ReadToolOutputTool.defaultMaxLines + 1)
        }
    }

    @Test("Empty placeholders for the optional arguments read as absent")
    func emptyOptionalsAreAbsent() async throws {
        try await withSpillRoot { root in
            let store = SpilledToolOutputStore.forTask(UUID(), under: root)
            let handle = try store.save(Self.numbered(3))
            let result = try await Self.execute(
                ["handle": .string(handle.uuidString), "pattern": .string("  "), "startingLineNum": .null, "maxLines": .null],
                store: store
            )
            #expect(Self.body(result).count == 3, "a blank pattern is no pattern")
            #expect(!result.output.contains("matching"))
        }
    }

    @Test("Zero or negative startingLineNum and maxLines are clamped to 1")
    func clampedNumbers() async throws {
        try await withSpillRoot { root in
            let store = SpilledToolOutputStore.forTask(UUID(), under: root)
            let handle = try store.save(Self.numbered(3))
            let result = try await Self.execute(["handle": .string(handle.uuidString), "startingLineNum": .int(-4), "maxLines": .int(0)], store: store)
            #expect(Self.body(result) == ["     1  line 1"])
        }
    }

    @Test("A handle from another task, or one never saved, is refused without revealing anything")
    func foreignHandle() async throws {
        try await withSpillRoot { root in
            let mine = SpilledToolOutputStore.forTask(UUID(), under: root)
            let other = SpilledToolOutputStore.forTask(UUID(), under: root)
            let otherHandle = try other.save("another task's secret output")
            for handle in [otherHandle, UUID()] {
                let result = try await Self.execute(["handle": .string(handle.uuidString)], store: mine)
                #expect(!result.succeeded)
                #expect(result.output.contains("No saved output"))
                #expect(!result.output.contains("secret"))
            }
        }
    }

    @Test("A handle that is not a UUID — a path above all — is refused and reads nothing")
    func malformedHandle() async throws {
        try await withSpillRoot { root in
            let mine = SpilledToolOutputStore.forTask(UUID(), under: root)
            let other = SpilledToolOutputStore.forTask(UUID(), under: root)
            let otherHandle = try other.save("another task's secret output")
            let traversals = [
                "../\(other.directory.lastPathComponent)/tool-output-\(otherHandle.uuidString)",
                other.fileURL(forHandle: otherHandle).path,
                "/etc/passwd",
                "not-a-handle"
            ]
            for text in traversals {
                let result = try await Self.execute(["handle": .string(text)], store: mine)
                #expect(!result.succeeded, Comment(rawValue: text))
                #expect(result.output.contains("is not a saved-output handle"))
                #expect(!result.output.contains("secret"))
            }
        }
    }

    @Test("A missing, blank or all-zero handle is a missing required argument")
    func missingHandle() async throws {
        try await withSpillRoot { root in
            let store = SpilledToolOutputStore.forTask(UUID(), under: root)
            let absent: [[String: AnyCodable]] = [
                [:], ["handle": .string("")], ["handle": .null],
                ["handle": .string("00000000-0000-0000-0000-000000000000")]
            ]
            for arguments in absent {
                await #expect(throws: ToolCallError.self) {
                    _ = try await Self.execute(arguments, store: store)
                }
            }
        }
    }

    @Test("An invalid regular expression is refused before anything is read")
    func invalidPattern() async throws {
        try await withSpillRoot { root in
            let store = SpilledToolOutputStore.forTask(UUID(), under: root)
            let handle = try store.save(Self.numbered(3))
            let result = try await Self.execute(["handle": .string(handle.uuidString), "pattern": .string("(unclosed")], store: store)
            #expect(!result.succeeded)
            #expect(result.output.contains("Invalid regular expression"))
        }
    }

    // MARK: Wiring

    @Test("Offered to the worker, the orchestrator and validators — through `any AgentTool`")
    func availability() {
        let tool: any AgentTool = ReadToolOutputTool()
        func available(to role: AgentRole) -> Bool {
            tool.isAvailable(in: ToolAvailabilityContext(agentRole: role))
        }
        #expect(tool.name == "read_tool_output")
        #expect(available(to: .brown) && available(to: .smith) && available(to: .validator))
        #expect(!available(to: .securityAgent))
        #expect(BrownBehavior.tools().contains { $0.name == tool.name })
        #expect(SmithBehavior.tools().contains { $0.name == tool.name })
    }

    @Test("Pre-cleared for every role that holds it, so no reviewer judges it as a path read")
    func autoApproved() {
        for role in [AgentRole.brown, .smith, .validator] {
            #expect(SecurityEvaluator.isAutoApproved(toolName: ReadToolOutputTool.toolName, role: role), "\(role)")
        }
        #expect(!SecurityEvaluator.isAutoApproved(toolName: "file_read", role: .brown), "path reads are still judged")
        #expect(!SecurityEvaluator.isAutoApproved(toolName: "grep", role: .brown), "path reads are still judged")
    }

    @Test("A worker has it whatever scoping approved; a global Never or a per-task Off removes it")
    func approvedByDefaultForWorkers() {
        let name = ReadToolOutputTool.toolName
        let candidates: Set<String> = [name, "file_read"]
        func offered(policies: [String: ToolPolicy] = [:], overrides: [String: Bool] = [:]) -> Set<String> {
            ToolPolicy.effectiveApprovedTools(
                base: Set(["file_read"]).union(ToolPolicy.workerToolsApprovedByDefault),
                candidates: candidates, globalPolicies: policies, taskOverrides: overrides
            )
        }
        #expect(offered().contains(name))
        #expect(!offered(policies: [name: .never]).contains(name))
        #expect(!offered(overrides: [name: false]).contains(name))
    }

    @Test("Classified as a read-only built-in with a tool group")
    func classification() {
        let name = ReadToolOutputTool.toolName
        #expect(ToolSafetyClassification.knownBuiltInNames.contains(name))
        #expect(!ToolSafetyClassification.hasSideEffects(toolName: name))
        #expect(!ToolSafetyClassification.isDestructive(toolName: name))
        #expect(!ToolSafetyClassification.isOpenWorld(toolName: name))
        #expect(BuiltInToolGroup.group(forToolName: name) == .savedToolOutput)
    }

    @Test("A validator with evidence tools is given it; one with none is given nothing")
    func validatorTools() {
        let withEvidence = OrchestrationRuntime.validatorTools(named: EvaluatorDefaults.validatorEvidenceToolNames).map(\.name)
        #expect(withEvidence == EvaluatorDefaults.validatorEvidenceToolNames + [ReadToolOutputTool.toolName])
        #expect(OrchestrationRuntime.validatorTools(named: []).isEmpty)
        #expect(!EvaluatorDefaults.validatorEvidenceToolNames.contains(ReadToolOutputTool.toolName),
                "it is added by the runtime, not chosen by a criterion's author")
    }
}
