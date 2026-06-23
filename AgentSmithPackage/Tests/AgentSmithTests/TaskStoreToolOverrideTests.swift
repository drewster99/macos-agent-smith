import Testing
import Foundation
@testable import AgentSmithKit

/// Covers per-task user tool overrides — the single setter and the bulk setter that backs the
/// per-MCP-server Auto/On/Off shortcut. Verifies enable/disable/clear semantics and that an
/// emptied override map collapses back to nil.
@Suite("TaskStore tool overrides")
struct TaskStoreToolOverrideTests {

    @Test("single override: on/off set the value; auto (nil) clears it")
    func singleOverride() async {
        let store = TaskStore()
        let task = await store.addTask(title: "T", description: "D")

        await store.setUserToolOverride(id: task.id, tool: "bash", enabled: true)
        await store.setUserToolOverride(id: task.id, tool: "grep", enabled: false)
        var t = await store.task(id: task.id)
        #expect(t?.userToolOverrides?["bash"] == true)
        #expect(t?.userToolOverrides?["grep"] == false)

        await store.setUserToolOverride(id: task.id, tool: "bash", enabled: nil)
        t = await store.task(id: task.id)
        #expect(t?.userToolOverrides?["bash"] == nil)
        #expect(t?.userToolOverrides?["grep"] == false)
    }

    @Test("bulk override applies one value across many tools at once")
    func bulkApplies() async {
        let store = TaskStore()
        let task = await store.addTask(title: "T", description: "D")
        let tools = ["mcp__srv__a", "mcp__srv__b", "mcp__srv__c"]

        await store.setUserToolOverrides(id: task.id, tools: tools, enabled: true)
        var t = await store.task(id: task.id)
        #expect(tools.allSatisfy { t?.userToolOverrides?[$0] == true })

        await store.setUserToolOverrides(id: task.id, tools: tools, enabled: false)
        t = await store.task(id: task.id)
        #expect(tools.allSatisfy { t?.userToolOverrides?[$0] == false })
    }

    @Test("bulk auto (nil) clears overrides; emptying the map collapses it to nil")
    func bulkClearCollapsesToNil() async {
        let store = TaskStore()
        let task = await store.addTask(title: "T", description: "D")
        let tools = ["mcp__srv__a", "mcp__srv__b"]

        await store.setUserToolOverrides(id: task.id, tools: tools, enabled: true)
        await store.setUserToolOverrides(id: task.id, tools: tools, enabled: nil)
        let t = await store.task(id: task.id)
        #expect(t?.userToolOverrides == nil)
    }

    @Test("bulk with an empty tool list is a no-op")
    func bulkEmptyNoop() async {
        let store = TaskStore()
        let task = await store.addTask(title: "T", description: "D")
        await store.setUserToolOverride(id: task.id, tool: "bash", enabled: true)
        await store.setUserToolOverrides(id: task.id, tools: [], enabled: false)
        let t = await store.task(id: task.id)
        #expect(t?.userToolOverrides?["bash"] == true)
    }
}
