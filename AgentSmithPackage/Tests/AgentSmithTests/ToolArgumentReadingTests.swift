import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// `ToolArguments` — reading optional tool arguments, where an empty placeholder means ABSENT.
@Suite("ToolArguments")
struct ToolArgumentReadingTests {

    @Test("A blank string reads as absent, however it is spelled")
    func blankStringsReadAsAbsent() {
        for blank in ["", " ", "\t", "\n", "   \n  "] {
            #expect(ToolArguments.optionalString(["k": .string(blank)], "k") == nil)
        }
    }

    @Test("A meaningful string comes back trimmed")
    func meaningfulStringIsTrimmed() {
        #expect(ToolArguments.optionalString(["k": .string("  hi  ")], "k") == "hi")
        #expect(ToolArguments.optionalString(["k": .string("hi")], "k") == "hi")
    }

    @Test("Absent, null, and wrong-typed all read as absent")
    func nonStringsReadAsAbsent() {
        #expect(ToolArguments.optionalString([:], "k") == nil)
        #expect(ToolArguments.optionalString(["k": .null], "k") == nil)
        #expect(ToolArguments.optionalString(["k": .int(3)], "k") == nil)
        #expect(ToolArguments.optionalString(["k": .array([])], "k") == nil)
    }

    @Test("An empty array reads as absent; a populated one does not")
    func emptyArrayReadsAsAbsent() {
        #expect(ToolArguments.optionalArray(["k": .array([])], "k") == nil)
        #expect(ToolArguments.optionalArray([:], "k") == nil)
        #expect(ToolArguments.optionalArray(["k": .null], "k") == nil)
        #expect(ToolArguments.optionalArray(["k": .string("x")], "k") == nil)
        #expect(ToolArguments.optionalArray(["k": .array([.string("x")])], "k")?.count == 1)
    }

    /// `false` is a value a caller can mean. Reading it as absent would be the mirror image of
    /// the bug this type exists to fix.
    @Test("false is a real bool, never absent")
    func falseIsNotAbsent() {
        #expect(ToolArguments.optionalBool(["k": .bool(false)], "k") == false)
        #expect(ToolArguments.optionalBool(["k": .bool(true)], "k") == true)
        #expect(ToolArguments.optionalBool([:], "k") == nil)
        #expect(ToolArguments.optionalBool(["k": .string("true")], "k") == nil)
    }

    // MARK: Optional UUIDs

    @Test("A real UUID reads as a value")
    func realUUIDReadsAsValue() {
        let id = UUID()
        #expect(ToolArguments.optionalUUID(["k": .string(id.uuidString)], "k") == .value(id))
    }

    /// The sentinel a model invents when it must send the key but means nothing by it. Unlike
    /// "" and [] this one PARSES, so it reached `list_tasks` as a real filter and matched the
    /// children of a task that cannot exist.
    @Test("The all-zero UUID reads as absent, not as an id")
    func placeholderUUIDReadsAsAbsent() {
        let zero = "00000000-0000-0000-0000-000000000000"
        #expect(ToolArguments.optionalUUID(["k": .string(zero)], "k") == .absent)
        #expect(ToolArguments.optionalUUID(["k": .string(zero.lowercased())], "k") == .absent)
    }

    @Test("Absent and blank read as absent")
    func absentUUIDReadsAsAbsent() {
        #expect(ToolArguments.optionalUUID([:], "k") == .absent)
        #expect(ToolArguments.optionalUUID(["k": .string("")], "k") == .absent)
        #expect(ToolArguments.optionalUUID(["k": .string("   ")], "k") == .absent)
        #expect(ToolArguments.optionalUUID(["k": .null], "k") == .absent)
    }

    /// Garbage must still be REFUSED — absent and malformed demand opposite responses, which is
    /// why this returns three cases rather than `UUID?`.
    @Test("Garbage is malformed, never absent")
    func garbageUUIDIsMalformed() {
        #expect(ToolArguments.optionalUUID(["k": .string("not-a-uuid")], "k") == .malformed("not-a-uuid"))
    }

    @Test("An integral double is an int; a fractional one is refused, not truncated")
    func integralDoublesAreInts() {
        #expect(ToolArguments.optionalInt(["k": .int(5)], "k") == 5)
        #expect(ToolArguments.optionalInt(["k": .double(5.0)], "k") == 5)
        #expect(ToolArguments.optionalInt(["k": .double(-5.0)], "k") == -5)
        #expect(ToolArguments.optionalInt(["k": .double(2.7)], "k") == nil)
        #expect(ToolArguments.optionalInt(["k": .string("5")], "k") == nil)
        #expect(ToolArguments.optionalInt([:], "k") == nil)
    }
}

/// The regressions themselves, stated as the calls that actually failed.
///
/// A model on the Codex endpoint emits every optional property on every call. With no `strict`
/// flag and only `title`/`description` required, `gpt-5.6-sol` still sent `scheduled_run_at: ""`,
/// `template_inputs: []`, `attachment_ids: []` and `template_instance_title_template: ""` — and
/// `create_task` rejected the call seven times running, because a caller cannot comply with
/// "omit this key" when it cannot stop sending the key.
@Suite("Empty-sentinel arguments are accepted, not rejected")
struct EmptySentinelArgumentTests {

    /// Exactly the argument set from the 2026-09-20 transcript.
    private var sentinelArguments: [String: AnyCodable] {
        [
            "title": .string("Investigate the idle gate"),
            "description": .string("Look at the MCP's idle handling."),
            "scheduled_run_at": .string(""),
            "template_inputs": .array([]),
            "template_instance_title_template": .string(""),
            "attachment_ids": .array([]),
            "is_template": .bool(false)
        ]
    }

    @Test("create_task accepts a call carrying every optional key as an empty placeholder")
    func createTaskAcceptsEmptySentinels() async throws {
        let store = TaskStore()
        let context = TestToolContext.make(taskStore: store)
        let result = try await CreateTaskTool().execute(arguments: sentinelArguments, context: context)

        #expect(result.succeeded, "create_task rejected empty placeholders: \(result.output)" as Comment)
        let tasks = await store.allTasks()
        #expect(tasks.count == 1)
        // The sentinels must read as ABSENT, not be stored as empty values.
        #expect(tasks.first?.scheduledRunAt == nil)
        #expect(tasks.first?.templateInputDefinitions.isEmpty == true)
        #expect(tasks.first?.templateInstanceTitleTemplate == nil)
    }

    /// Each sentinel on its own, so a future regression names the field it broke rather than
    /// failing the whole bundle.
    @Test("Each empty sentinel is individually harmless",
          arguments: [
            ("scheduled_run_at", AnyCodable.string("")),
            ("template_inputs", AnyCodable.array([])),
            ("template_instance_title_template", AnyCodable.string("")),
            ("attachment_ids", AnyCodable.array([]))
          ])
    func eachSentinelIsHarmless(field: String, value: AnyCodable) async throws {
        let store = TaskStore()
        var arguments: [String: AnyCodable] = [
            "title": .string("Task for \(field)"),
            "description": .string("d")
        ]
        arguments[field] = value
        let result = try await CreateTaskTool().execute(
            arguments: arguments, context: TestToolContext.make(taskStore: store)
        )
        #expect(result.succeeded, "\(field) as an empty placeholder was rejected: \(result.output)" as Comment)
    }

    /// A real value must still be honored — the reader must not have turned the field off.
    @Test("A real scheduled_run_at still schedules")
    func realScheduledRunAtStillWorks() async throws {
        let store = TaskStore()
        let when = Date().addingTimeInterval(3600)
        let iso = ISO8601DateFormatter().string(from: when)
        let result = try await CreateTaskTool().execute(
            arguments: ["title": .string("Later"), "description": .string("d"),
                        "scheduled_run_at": .string(iso)],
            context: TestToolContext.make(taskStore: store)
        )
        #expect(result.succeeded, "\(result.output)" as Comment)
        #expect(await store.allTasks().first?.scheduledRunAt != nil)
    }

    /// A genuinely malformed value must still be refused — leniency is for EMPTY, not for wrong.
    @Test("A malformed scheduled_run_at is still refused")
    func malformedScheduledRunAtStillFails() async throws {
        let result = try await CreateTaskTool().execute(
            arguments: ["title": .string("Bad"), "description": .string("d"),
                        "scheduled_run_at": .string("next tuesday")],
            context: TestToolContext.make(taskStore: TaskStore())
        )
        #expect(result.succeeded == false)
        #expect(result.output.contains("ISO-8601"))
    }

    /// The zero-UUID sentinel end to end: it must not become a filter that hides every task.
    @Test("list_tasks with a placeholder parent_task_id does not filter everything away")
    func listTasksIgnoresPlaceholderParentID() async throws {
        let store = TaskStore()
        _ = await store.addTask(title: "Visible task", description: "d")
        let result = try await ListTasksTool().execute(
            arguments: [
                "parent_task_id": .string("00000000-0000-0000-0000-000000000000"),
                "disposition_filter": .string(""),
                "query": .string("")
            ],
            context: TestToolContext.make(taskStore: store)
        )
        #expect(result.succeeded, "\(result.output)" as Comment)
        #expect(result.output.contains("Visible task"), "\(result.output)" as Comment)
    }

    /// A REAL parent id must still filter — the reader must not have disabled the argument.
    @Test("A real parent_task_id still filters")
    func realParentTaskIDStillFilters() async throws {
        let store = TaskStore()
        _ = await store.addTask(title: "Unrelated task", description: "d")
        let result = try await ListTasksTool().execute(
            arguments: ["parent_task_id": .string(UUID().uuidString)],
            context: TestToolContext.make(taskStore: store)
        )
        #expect(result.succeeded, "\(result.output)" as Comment)
        #expect(result.output.contains("Unrelated task") == false, "\(result.output)" as Comment)
    }

    /// The same guard on the other tool that carries it. `edit_task` had the identical dead end.
    @Test("edit_task accepts template_inputs: [] on a non-template")
    func editTaskAcceptsEmptyTemplateInputs() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "T", description: "d")
        let result = try await EditTaskTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "template_inputs": .array([])],
            context: TestToolContext.make(taskStore: store)
        )
        #expect(result.output.contains("template_inputs are valid only") == false, "\(result.output)" as Comment)
    }

    @Test("edit_task clears template inputs only with explicit destructive intent")
    func editTaskClearsTemplateInputsExplicitly() async throws {
        let store = TaskStore()
        let task = await store.addTask(
            title: "Template",
            description: "d",
            isTemplate: true,
            templateInputDefinitions: [
                TemplateInputDefinition(name: "value", description: "A value", required: true)
            ]
        )
        let context = TestToolContext.make(taskStore: store)

        let placeholder = try await EditTaskTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "template_inputs": .array([])],
            context: context
        )
        #expect(placeholder.succeeded)
        #expect(await store.task(id: task.id)?.templateInputDefinitions.count == 1)

        let cleared = try await EditTaskTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "clear_template_inputs": .bool(true)],
            context: context
        )
        #expect(cleared.succeeded)
        #expect(await store.task(id: task.id)?.templateInputDefinitions.isEmpty == true)
    }
}

/// Guards the rule rather than trusting it: no NEW hand-unwraps of an optional tool argument.
///
/// The type is a convenience; this is what keeps the antipattern from coming back. Modeled on
/// `ChannelMessageKindLiteralGuardTests`, and ratcheted rather than absolute — a REQUIRED
/// argument legitimately pattern-matches on presence (and must keep rejecting empty), so the
/// budget is the count of remaining hand-unwraps, which may fall but never rise.
@Suite("Tool argument reading guard")
struct ToolArgumentReadingGuardTests {

    private static var toolsRoot: URL {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repo.deleteLastPathComponent() }
        return repo.appendingPathComponent("AgentSmithPackage/Sources/AgentSmithKit/Tools", isDirectory: true)
    }

    /// `ToolArgumentReading.swift` defines the readers; everything else goes through them.
    private static let exemptFileNames: Set<String> = ["ToolArgumentReading.swift"]

    /// Hand-unwraps that remain because their argument is REQUIRED — the tool refuses the call
    /// when it is missing, and an empty value there is a real error rather than an omission.
    /// Frozen so the number can fall but not rise.
    ///
    /// Every one of these is a `guard case` (a required argument, correctly refusing empty).
    /// There are ZERO `if case` sites left: every optional argument in every tool now reads
    /// through `ToolArguments`, which the companion test below pins separately and absolutely —
    /// that one is the real guard, and this budget is the coarse backstop behind it.
    /// Raised from 62 to 64 on 2026-09-25 for `watch_task`'s required `action` and `task_id`.
    private static let handUnwrapBudget = 64

    /// Every `if case .string/.array(let x) = arguments["k"]` still in the tool sources.
    private static func handUnwrapSites(requiringPrefix prefix: String? = nil) throws -> [String] {
        let pattern = #"case \.(?:string|array)\(let \w+\)\s*=\s*arguments\["#
        let regex = try NSRegularExpression(pattern: pattern)
        var sites: [String] = []
        guard let enumerator = FileManager.default.enumerator(
            at: toolsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Could not enumerate \(toolsRoot.path) — this guard covers nothing.")
            return []
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard !exemptFileNames.contains(url.lastPathComponent) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if let prefix, !trimmedLine.hasPrefix(prefix) { continue }
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    sites.append("\(url.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return sites
    }

    /// The precise rule, and an absolute one rather than a ratchet.
    ///
    /// `guard case … else { return .failure(…) }` is how a REQUIRED argument is read, and it
    /// stays. `if case .string(let x) = arguments["k"]` is how an OPTIONAL one used to be read,
    /// and it must not come back: that form treats an empty placeholder as a deliberate value,
    /// which a caller emitting every key cannot retract. There are currently none.
    @Test("No optional tool argument is hand-unwrapped")
    func noOptionalHandUnwraps() throws {
        let sites = try Self.handUnwrapSites(requiringPrefix: "if case")
        #expect(sites.isEmpty, Comment(rawValue: """
            \(sites.count) optional tool argument(s) read by pattern-matching on PRESENCE.

            Use `ToolArguments.optionalString/optionalArray/optionalBool/optionalInt` — an empty
            placeholder must read as ABSENT. A model that emits every key with an empty value
            cannot comply with a rejection; that is how `create_task` dead-ended seven times on
            2026-09-20.

            Sites:
            \(sites.joined(separator: "\n"))
            """))
    }

    @Test("No new hand-unwrapped tool arguments")
    func handUnwrapsDoNotGrow() throws {
        let sites = try Self.handUnwrapSites()
        #expect(sites.isEmpty == false, "The scan found nothing at all — the pattern or the path is wrong.")
        if sites.count > Self.handUnwrapBudget {
            Issue.record(Comment(rawValue: """
                \(sites.count) hand-unwrapped tool arguments, budget \(Self.handUnwrapBudget).

                An OPTIONAL argument must be read through `ToolArguments` — a model that emits
                every key with an empty placeholder cannot comply with a rejection, which is how
                `create_task` dead-ended seven times on 2026-09-20.

                A REQUIRED argument may keep pattern-matching on presence. If that is what you
                added, raise the budget in the same commit and say which argument it is.

                Sites:
                \(sites.joined(separator: "\n"))
                """))
        }
        if sites.count < Self.handUnwrapBudget {
            Issue.record(Comment(rawValue: """
                Only \(sites.count) hand-unwraps remain, budget says \(Self.handUnwrapBudget).
                Debt was paid down — lower the budget in the same commit so it keeps ratcheting.
                """))
        }
    }
}
