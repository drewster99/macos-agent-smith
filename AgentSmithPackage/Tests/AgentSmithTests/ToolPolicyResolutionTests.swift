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
