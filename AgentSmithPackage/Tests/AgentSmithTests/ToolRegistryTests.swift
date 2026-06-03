import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// Unit tests for `ToolRegistry` — the per-agent tool registry + availability gate that backs
/// per-task security scoping. Covers the availability formula, verdict application (including
/// the fail-closed / hallucinated-allow rules), forced/context flag interaction, flag
/// preservation across rebuilds, and the content fingerprint used for change detection.
@Suite("ToolRegistry")
struct ToolRegistryTests {

    private struct StubTool: AgentTool {
        let name: String
        var toolDescription: String = "stub"
        var paramKeys: [String] = []

        var parameters: [String: AnyCodable] {
            var props: [String: AnyCodable] = [:]
            for key in paramKeys { props[key] = .dictionary(["type": .string("string")]) }
            return [
                "type": .string("object"),
                "properties": .dictionary(props),
                "required": .array([])
            ]
        }

        func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
            .success("ok")
        }
    }

    private func names(_ tools: [any AgentTool]) -> [String] { tools.map(\.name) }

    @Test("rebuild seeds default approval and availableTools reflects it")
    func rebuildSeedsApproval() {
        var registry = ToolRegistry()
        let candidates: [any AgentTool] = [StubTool(name: "a"), StubTool(name: "b")]

        registry.rebuild(candidates: candidates, defaultApproved: true)
        #expect(names(registry.availableTools()) == ["a", "b"])

        var disabled = ToolRegistry()
        disabled.rebuild(candidates: candidates, defaultApproved: false)
        #expect(disabled.availableTools().isEmpty)
    }

    @Test("applyApproval enables listed tools, blocks the rest, ignores hallucinated names")
    func applyApproval() {
        var registry = ToolRegistry()
        registry.rebuild(candidates: [StubTool(name: "a"), StubTool(name: "b"), StubTool(name: "c")],
                         defaultApproved: false)

        // Includes a name that isn't a real candidate — must be ignored, not enabled.
        registry.applyApproval(approvedNames: ["a", "c", "ghost"])

        #expect(names(registry.availableTools()) == ["a", "c"])
        #expect(Set(registry.approvedNames) == ["a", "c"])
        #expect(registry.entry(named: "ghost") == nil)
    }

    @Test("isForcedAvailableBySystem short-circuits approval and context suppression")
    func forcedOverride() {
        var registry = ToolRegistry()
        registry.rebuild(candidates: [StubTool(name: "ack")], defaultApproved: false)
        #expect(registry.availableTools().isEmpty)

        registry.setForcedAvailable("ack", true)
        #expect(names(registry.availableTools()) == ["ack"])

        // Even with context suppression, forced wins.
        registry.setContextUnavailable("ack", true)
        #expect(names(registry.availableTools()) == ["ack"])

        registry.setForcedAvailable("ack", false)
        #expect(registry.availableTools().isEmpty)
    }

    @Test("context suppression hides an approved tool")
    func contextSuppression() {
        var registry = ToolRegistry()
        registry.rebuild(candidates: [StubTool(name: "reply")], defaultApproved: true)
        #expect(names(registry.availableTools()) == ["reply"])

        registry.setContextUnavailable("reply", true)
        #expect(registry.availableTools().isEmpty)

        registry.setContextUnavailable("reply", false)
        #expect(names(registry.availableTools()) == ["reply"])
    }

    @Test("rebuild preserves flags for surviving tools and drops removed ones")
    func rebuildPreservesFlags() {
        var registry = ToolRegistry()
        registry.rebuild(candidates: [StubTool(name: "a"), StubTool(name: "b")], defaultApproved: false)
        registry.applyApproval(approvedNames: ["a"])
        registry.setForcedAvailable("b", true)

        // 'a' survives (approved preserved), 'b' survives (forced preserved), 'c' is new.
        registry.rebuild(candidates: [StubTool(name: "a"), StubTool(name: "b"), StubTool(name: "c")],
                         defaultApproved: false)

        #expect(registry.entry(named: "a")?.isApproved == true)
        #expect(registry.entry(named: "b")?.isForcedAvailableBySystem == true)
        #expect(registry.entry(named: "c")?.isApproved == false)
        #expect(Set(names(registry.availableTools())) == ["a", "b"])

        // Dropping 'a' removes it entirely.
        registry.rebuild(candidates: [StubTool(name: "b"), StubTool(name: "c")], defaultApproved: false)
        #expect(registry.entry(named: "a") == nil)
    }

    @Test("candidate fingerprint is stable across reorder but changes on redefinition")
    func fingerprint() {
        var base = ToolRegistry()
        base.rebuild(candidates: [StubTool(name: "a", toolDescription: "does A"),
                                  StubTool(name: "b", toolDescription: "does B")],
                     defaultApproved: true)
        let baseline = base.candidateFingerprint

        // Reordering the same tools must not change the fingerprint (sorted by name internally).
        var reordered = ToolRegistry()
        reordered.rebuild(candidates: [StubTool(name: "b", toolDescription: "does B"),
                                       StubTool(name: "a", toolDescription: "does A")],
                          defaultApproved: true)
        #expect(reordered.candidateFingerprint == baseline)

        // A silent redefinition of "a" (same name, new description) changes the fingerprint —
        // this is the rug-pull defense.
        var redefined = ToolRegistry()
        redefined.rebuild(candidates: [StubTool(name: "a", toolDescription: "does something ELSE"),
                                       StubTool(name: "b", toolDescription: "does B")],
                          defaultApproved: true)
        #expect(redefined.candidateFingerprint != baseline)

        // A new parameter key also changes the fingerprint.
        var newParam = ToolRegistry()
        newParam.rebuild(candidates: [StubTool(name: "a", toolDescription: "does A", paramKeys: ["x"]),
                                      StubTool(name: "b", toolDescription: "does B")],
                         defaultApproved: true)
        #expect(newParam.candidateFingerprint != baseline)
    }

    @Test("built-in safety classification: read-only vs destructive vs open-world")
    func safetyClassification() {
        // Sanity-check the central classification that feeds Jones.
        #expect(ToolSafetyClassification.isDestructive(toolName: "bash") == true)
        #expect(ToolSafetyClassification.isOpenWorld(toolName: "bash") == true)
        #expect(ToolSafetyClassification.isDestructive(toolName: "file_write") == true)
        #expect(ToolSafetyClassification.isOpenWorld(toolName: "file_write") == false)
        #expect(ToolSafetyClassification.isDestructive(toolName: "save_memory") == true)
        #expect(ToolSafetyClassification.isDestructive(toolName: "file_read") == false)
        #expect(ToolSafetyClassification.isOpenWorld(toolName: "file_read") == false)
        // Fail-closed: an unknown (e.g. MCP-style) name defaults to risky.
        #expect(ToolSafetyClassification.isDestructive(toolName: "some_unknown_mcp_tool") == true)
        #expect(ToolSafetyClassification.isOpenWorld(toolName: "some_unknown_mcp_tool") == true)
    }
}
