import Foundation
import Testing
@testable import AgentSmithKit

/// Template tasks: toggling, cloning a fresh instance, and the fields carried vs blanked.
@Suite("Task templates")
struct TaskTemplateTests {

    @Test("cloneTemplateInstance copies the contract, blanks run-state, links the parent")
    func cloneCarriesContractBlanksRunState() async {
        let store = TaskStore()
        var template = await store.addTask(title: "Nightly report", description: "Generate the report.", isTemplate: true)
        await store.setSteps(id: template.id, steps: [
            TaskStep(text: "gather data", origin: .smith),
            TaskStep(text: "write report", origin: .smith)
        ])
        await store.setAcceptanceCriteria(id: template.id, criteria: [
            AcceptanceCriterion(name: "report exists", origin: .user)
        ])
        // Dirty the template with run-state that must NOT carry over.
        await store.setResult(id: template.id, result: "old result", commentary: "old commentary", attachments: [])
        await store.addUpdate(id: template.id, message: "old update")
        _ = await store.beginValidationRound(id: template.id)
        template = await store.task(id: template.id)!

        let instance = await store.cloneTemplateInstance(templateID: template.id)
        guard let instance else { Issue.record("clone returned nil"); return }

        // Contract carried.
        #expect(instance.title == "Nightly report")
        #expect(instance.description == "Generate the report.")
        #expect(instance.steps.map(\.text) == ["gather data", "write report"])
        #expect(instance.steps.allSatisfy { $0.status == .pending })
        #expect(instance.acceptanceCriteria.map(\.text) == ["report exists"])
        // Run-state blanked.
        #expect(instance.result == nil)
        #expect(instance.commentary == nil)
        #expect(instance.updates.isEmpty)
        #expect(instance.validation == nil)
        #expect(instance.summary == nil)
        // Instance identity + lineage.
        #expect(instance.id != template.id)
        #expect(instance.isTemplate == false)
        #expect(instance.parentTaskID == template.id)
        #expect(instance.status == .pending)
        // Fresh criterion IDs so the instance's ledger can't collide with the template's.
        #expect(instance.acceptanceCriteria.first?.id != template.acceptanceCriteria.first?.id)

        // The template itself is untouched and still a template.
        let templateAfter = await store.task(id: template.id)
        #expect(templateAfter?.isTemplate == true)
        #expect(templateAfter?.result == "old result")
    }

    @Test("Toggling a terminal task into a template normalizes it to a clean pending launcher")
    func toggleTerminalTaskNormalizes() async {
        let store = TaskStore()
        let task = await store.addTask(title: "One-off", description: "d")
        await store.setResult(id: task.id, result: "done", commentary: nil, attachments: [])
        await store.updateStatus(id: task.id, status: .completed)

        await store.setTemplate(id: task.id, isTemplate: true)
        let t = await store.task(id: task.id)
        #expect(t?.isTemplate == true)
        #expect(t?.status == .pending, "a template must be a startable launcher, not a stale completed task")
        #expect(t?.result == nil)
        #expect(t?.updates.contains { $0.message.contains("Replacing previous result") } == true, "prior result preserved in history")
    }

    @Test("Toggling template off leaves an ordinary task")
    func toggleOff() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d", isTemplate: true)
        await store.setTemplate(id: task.id, isTemplate: false)
        #expect(await store.task(id: task.id)?.isTemplate == false)
    }
}
