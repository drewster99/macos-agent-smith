import Foundation
import Testing
@testable import AgentSmithKit

/// "Never" means never (user decision 2026-10-05). A per-task On used to beat a global Never, so a
/// tool the user had banned everywhere could be switched back on for one task.
@Suite("Tool policy resolution")
struct ToolPolicyResolutionTests {

    private let candidates: Set<String> = ["bash", "file_write", "web_fetch"]

    private func resolve(
        base: Set<String>,
        global: [String: ToolPolicy] = [:],
        task: [String: Bool] = [:]
    ) -> Set<String> {
        ToolPolicy.effectiveApprovedTools(base: base, candidates: candidates, globalPolicies: global, taskOverrides: task)
    }

    @Test("a global Never beats a per-task On")
    func neverBeatsTaskOn() {
        #expect(!resolve(base: ["bash"], global: ["file_write": .never], task: ["file_write": true]).contains("file_write"))
    }

    @Test("a global Never strips a tool the scoping verdict approved")
    func neverBeatsVerdict() {
        #expect(resolve(base: ["bash", "file_write"], global: ["file_write": .never]) == ["bash"])
    }

    @Test("a built-in Never beats a per-task On")
    func builtInNeverBeatsTaskOn() {
        let name = ReportInboundUserMessageTool.toolName
        let result = ToolPolicy.effectiveApprovedTools(
            base: [name], candidates: [name], globalPolicies: [:], taskOverrides: [name: true]
        )
        #expect(result.isEmpty)
    }

    @Test("a user global entry replaces the built-in default")
    func globalReplacesBuiltIn() {
        let name = ReportInboundUserMessageTool.toolName
        #expect(ToolPolicy.effective(for: name, globalPolicies: [:]) == .never)
        #expect(ToolPolicy.effective(for: name, globalPolicies: [name: .always]) == .always)
        let result = ToolPolicy.effectiveApprovedTools(
            base: [], candidates: [name], globalPolicies: [name: .always], taskOverrides: [:]
        )
        #expect(result == [name])
    }

    @Test("a per-task Off beats a global Always")
    func taskOffBeatsAlways() {
        #expect(!resolve(base: [], global: ["web_fetch": .always], task: ["web_fetch": false]).contains("web_fetch"))
        #expect(resolve(base: [], global: ["web_fetch": .always]).contains("web_fetch"))
    }

    @Test("a per-task On adds a tool the verdict left out; Off removes one it approved")
    func taskOverridesBeatVerdict() {
        #expect(resolve(base: ["bash"], task: ["file_write": true, "bash": false]) == ["file_write"])
    }

    /// `save_memory` used to be FORCED available, which beat a Never set in Settings.
    @Test("a tool approved by default is still removed by Never or a per-task Off")
    func approvedByDefaultObeysRestrictions() {
        let name = "save_memory"
        #expect(ToolPolicy.workerToolsApprovedByDefault.contains(name))
        let base = Set<String>().union(ToolPolicy.workerToolsApprovedByDefault)
        let candidates: Set<String> = [name]
        #expect(ToolPolicy.effectiveApprovedTools(base: base, candidates: candidates, globalPolicies: [:], taskOverrides: [:]) == [name])
        #expect(ToolPolicy.effectiveApprovedTools(base: base, candidates: candidates, globalPolicies: [name: .never], taskOverrides: [:]).isEmpty)
        #expect(ToolPolicy.effectiveApprovedTools(base: base, candidates: candidates, globalPolicies: [:], taskOverrides: [name: false]).isEmpty)
    }

    @Test("neither a policy nor an override adds a tool the worker does not have")
    func nonCandidatesNeverAdded() {
        let result = resolve(base: [], global: ["create_task": .always], task: ["list_tasks": true])
        #expect(result.isEmpty)
    }
}

/// Choosing "Default" for a tool whose built-in default is Never used to remove the entry, which put
/// the built-in Never straight back: the picker snapped to Never and "defer to scoping" could not be
/// expressed.
@Suite("Recording a tool policy choice")
struct ToolPolicyRecordingTests {
    private let builtInNever = ReportInboundUserMessageTool.toolName

    @Test("Default on a built-in-Never tool is stored, so it resolves to Default")
    func defaultOnBuiltInNeverIsStored() {
        var policies: [String: ToolPolicy] = ["other": .always]
        ToolPolicy.recordUserChoice(.default, for: builtInNever, in: &policies)
        #expect(policies == [builtInNever: .default, "other": .always])
        #expect(ToolPolicy.effective(for: builtInNever, globalPolicies: policies) == .default)
        ToolPolicy.recordUserChoice(.never, for: builtInNever, in: &policies)
        #expect(policies == ["other": .always])
    }

    @Test("An ordinary tool's Default removes the entry; Always is stored")
    func ordinaryTool() {
        var policies: [String: ToolPolicy] = ["bash": .never]
        ToolPolicy.recordUserChoice(.default, for: "bash", in: &policies)
        #expect(policies.isEmpty)
        ToolPolicy.recordUserChoice(.always, for: "bash", in: &policies)
        #expect(policies == ["bash": .always])
    }
}

/// Scoping judges tools one by one and could approve `create_child_task` without
/// `wait_for_child_tasks`, leaving a coordinator unable to wait for what it created.
@Suite("Companion tools")
struct ToolPolicyCompanionTests {
    private let create = "create_child_task"
    private let wait = "wait_for_child_tasks"
    private var candidates: Set<String> { [create, wait, "bash"] }

    private func resolve(base: Set<String>, global: [String: ToolPolicy] = [:], task: [String: Bool] = [:], candidates: Set<String>? = nil) -> Set<String> {
        ToolPolicy.effectiveApprovedTools(base: base, candidates: candidates ?? self.candidates, globalPolicies: global, taskOverrides: task)
    }

    @Test("a principal from the verdict or a per-task On brings its companion")
    func principalBringsCompanion() {
        #expect(resolve(base: [create]).contains(wait))
        #expect(resolve(base: [], task: [create: true]).contains(wait))
        #expect(resolve(base: [], global: [create: .always]).contains(wait))
    }

    @Test("a companion's own Off or Never still withholds it; a withheld principal brings nothing")
    func companionStillWithheld() {
        #expect(!resolve(base: [create], task: [wait: false]).contains(wait))
        #expect(!resolve(base: [create], global: [wait: .never]).contains(wait))
        #expect(resolve(base: [create], global: [create: .never]).isDisjoint(with: [create, wait]))
        #expect(!resolve(base: [create], candidates: [create]).contains(wait), "a companion the worker doesn't have")
    }

    @Test("scoping is shown only tools the policy can offer")
    func scopingCandidatesDropWithheld() {
        let tools: [any AgentTool] = [BashTool(), FileReadTool()]
        let offered = ToolPolicy.scopingCandidates(tools, globalPolicies: ["bash": .never]).map(\.name)
        #expect(offered == ["file_read"])
    }
}
