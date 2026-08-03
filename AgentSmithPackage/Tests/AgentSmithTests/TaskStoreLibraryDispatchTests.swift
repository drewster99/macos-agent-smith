import Testing
import Foundation
@testable import AgentSmithKit

/// The cross-store paths that only exist when a `TaskStore` has a `TemplateLibraryStore` wired:
/// promote (session → library), edit-in-library (dual-dispatch), demote (library → session), and
/// instantiate-from-library (mints an instance back into the session). The rest of the suite runs
/// with no library, exercising the in-place branch; these exercise the library branch.
@Suite struct TaskStoreLibraryDispatchTests {

    private func makeStore() -> (TaskStore, TemplateLibraryStore) {
        let library = TemplateLibraryStore()
        let store = TaskStore(sessionID: UUID(), templateLibrary: library)
        return (store, library)
    }

    @Test func promoteMovesTaskOutToLibrary() async {
        let (store, library) = makeStore()
        let task = AgentTask(title: "Nightly", description: "run it")
        await store.restore([task])

        let result = await store.setTemplate(id: task.id, isTemplate: true)
        #expect(result == nil)
        // Left the per-session store; now a template in the library.
        #expect(await store.task(id: task.id) == nil)
        #expect(await library.template(id: task.id)?.isTemplate == true)
        // The union lookup still finds it.
        #expect(await store.taskOrLibraryTemplate(id: task.id)?.id == task.id)
        #expect(await store.allLibraryTemplates().contains { $0.id == task.id })
    }

    @Test func editsDispatchToTheLibraryCopy() async {
        let (store, library) = makeStore()
        let task = AgentTask(title: "Nightly", description: "run it")
        await store.restore([task])
        _ = await store.setTemplate(id: task.id, isTemplate: true)

        // setSteps on the (now library-resident) template writes back to the library, not the session.
        let stepsResult = await store.setSteps(id: task.id, steps: [TaskStep(text: "step one", origin: .smith)])
        #expect(stepsResult == nil)
        #expect(await library.template(id: task.id)?.steps.count == 1)
        #expect(await store.task(id: task.id) == nil)   // still not in the session

        // applyStepAction (manage_steps) likewise dispatches to the library.
        let addResult = await store.applyStepAction(
            taskID: task.id, action: .add(text: "step two", origin: .smith))
        #expect(addResult == nil)
        #expect(await library.template(id: task.id)?.steps.filter(\.isActive).count == 2)
    }

    @Test func demoteBringsTemplateBackIntoThisSession() async {
        let (store, library) = makeStore()
        let sessionID = UUID()
        let scopedStore = TaskStore(sessionID: sessionID, templateLibrary: library)
        let task = AgentTask(title: "Nightly", description: "run it")
        await scopedStore.restore([task])
        _ = await scopedStore.setTemplate(id: task.id, isTemplate: true)
        #expect(await scopedStore.task(id: task.id) == nil)

        let result = await scopedStore.setTemplate(id: task.id, isTemplate: false)
        #expect(result == nil)
        let demoted = await scopedStore.task(id: task.id)
        #expect(demoted?.isTemplate == false)
        #expect(demoted?.sessionID == sessionID)        // adopted this session
        #expect(await library.template(id: task.id) == nil)  // gone from the library
    }

    @Test func taskAnyDispositionAndUnionLookupsFindLibraryTemplates() async {
        // Regression: tools that resolve a task_id (get_task_details, run_task, the editing tools)
        // must find a template surfaced by list_tasks. Both the "find anywhere" and the union lookup do.
        let (store, _) = makeStore()
        let task = AgentTask(title: "Nightly", description: "run it")
        await store.restore([task])
        _ = await store.setTemplate(id: task.id, isTemplate: true)

        #expect(await store.taskAnyDisposition(id: task.id)?.id == task.id)
        #expect(await store.taskOrLibraryTemplate(id: task.id)?.id == task.id)
        // A plain per-session lookup deliberately does NOT (it's the active-only accessor).
        #expect(await store.task(id: task.id) == nil)
    }

    @Test func addUpdateLandsOnLibraryTemplate() async {
        // Regression: the "Started instance … from this template" note run_task records lands on the
        // template, which is library-resident — addUpdate must dual-dispatch or the note is silently lost.
        let (store, library) = makeStore()
        let task = AgentTask(title: "Nightly", description: "run it")
        await store.restore([task])
        _ = await store.setTemplate(id: task.id, isTemplate: true)

        await store.addUpdate(id: task.id, message: "Started instance ABC from this template.")
        let updates = await library.template(id: task.id)?.updates ?? []
        #expect(updates.contains { $0.message.contains("Started instance ABC") })
    }

    @Test func instantiateFromLibraryMintsInstanceIntoSession() async {
        let (store, library) = makeStore()
        let task = AgentTask(title: "Nightly", description: "run it")
        await store.restore([task])
        _ = await store.setTemplate(id: task.id, isTemplate: true)

        switch await store.instantiateTemplate(templateID: task.id, inputValues: [:]) {
        case .success(let instance):
            #expect(instance.isTemplate == false)
            #expect(instance.parentTaskID == task.id)
            #expect(await store.task(id: instance.id) != nil)   // instance lives in the session
            #expect(await library.template(id: task.id) != nil) // template stays in the library
        case .failure(let message):
            Issue.record("instantiate failed: \(message)")
        }
    }
}
