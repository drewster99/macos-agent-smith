import Testing
import Foundation
@testable import AgentSmithKit

/// The immutable origin `sessionID` on `AgentTask` (hand-written Codable): it round-trips, is
/// forward-compatible with legacy files that lack the key, and is stamped on every store-created task.
@Suite struct TaskSessionIDTests {

    @Test func sessionIDRoundTripsThroughJSON() throws {
        let sid = UUID()
        let task = AgentTask(title: "t", description: "d", sessionID: sid)
        let back = try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(task))
        #expect(back.sessionID == sid)
    }

    @Test func legacyTaskWithoutSessionIDDecodesToNil() throws {
        let task = AgentTask(title: "t", description: "d")   // sessionID nil by default
        let data = try JSONEncoder().encode(task)
        #expect(!String(decoding: data, as: UTF8.self).contains("sessionID"))   // encodeIfPresent omits nil
        let back = try JSONDecoder().decode(AgentTask.self, from: data)
        #expect(back.sessionID == nil)
    }

    @Test func addTaskStampsOriginSession() async {
        let sid = UUID()
        let store = TaskStore(sessionID: sid)
        let task = await store.addTask(title: "new", description: "d")
        #expect(task.sessionID == sid)
    }

    @Test func instantiateTemplateStampsInstantiatingSession() async {
        let sid = UUID()
        let store = TaskStore(sessionID: sid)
        let template = await store.addTask(title: "tmpl", description: "d", isTemplate: true)
        let result = await store.instantiateTemplate(templateID: template.id, inputValues: [:])
        guard case .success(let instance) = result else {
            #expect(Bool(false), "instantiation should succeed")
            return
        }
        #expect(instance.sessionID == sid)
        #expect(instance.parentTaskID == template.id)
    }

    @Test func setSessionIDIsSetOnce() async {
        let store = TaskStore()   // nil origin (e.g. the live store before adoption)
        let first = UUID()
        await store.setSessionID(first)
        await store.setSessionID(UUID())   // ignored — set-once
        let task = await store.addTask(title: "x", description: "d")
        #expect(task.sessionID == first)
    }
}
