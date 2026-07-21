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
        _ = await store.setTemplateInputDefinitions(id: task.id, definitions: [
            TemplateInputDefinition(name: "target_app", description: "App name", required: true)
        ])
        await store.setTemplate(id: task.id, isTemplate: false)
        #expect(await store.task(id: task.id)?.isTemplate == false)
        #expect(await store.task(id: task.id)?.templateInputDefinitions.isEmpty == true)
        #expect(await store.task(id: task.id)?.templateInputValues.isEmpty == true)
    }

    @Test("Template inputs validate, resolve, and snapshot onto instances")
    func templateInputsValidateResolveAndSnapshot() async {
        let store = TaskStore()
        let template = await store.addTask(title: "Localization", description: "Test app.", isTemplate: true)
        let setError = await store.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "target_app", description: "App name or bundle ID.", required: true),
            TemplateInputDefinition(name: "locale", description: "Locale to test.", required: false)
        ])
        #expect(setError == nil)

        switch await store.instantiateTemplate(templateID: template.id, inputValues: ["target_ap": "Typo"]) {
        case .success:
            Issue.record("unknown template input should reject instantiation")
        case .failure(let message):
            #expect(message.contains("Unknown template input"))
        }

        switch await store.instantiateTemplate(templateID: template.id, inputValues: [:]) {
        case .success:
            Issue.record("missing required input should reject instantiation")
        case .failure(let message):
            #expect(message.contains("Missing required template input"))
            #expect(message.contains("target_app"))
        }

        let instance: AgentTask
        switch await store.instantiateTemplate(templateID: template.id, inputValues: [
            "target_app": "  Localizer  ",
            "locale": "   "
        ]) {
        case .success(let created):
            instance = created
        case .failure(let message):
            Issue.record("valid template inputs should instantiate: \(message)")
            return
        }

        #expect(instance.parentTaskID == template.id)
        #expect(instance.templateInputDefinitions.map(\.name) == ["target_app", "locale"])
        #expect(instance.templateInputValues == ["target_app": "Localizer"])
        #expect(instance.renderedTemplateInputValues()?.contains("target_app: Localizer") == true)
        #expect(!instance.renderedDescriptionWithTemplateInputs().contains("locale:"))
    }

    @Test("Template instance title template renders from snapshotted inputs")
    func templateInstanceTitleTemplateRendersFromInputs() async {
        let store = TaskStore()
        let template = await store.addTask(title: "Localize App", description: "Localize it.", isTemplate: true)
        _ = await store.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "target_app", description: "App name.", required: true)
        ])
        let titleError = await store.setTemplateInstanceTitleTemplate(
            id: template.id,
            titleTemplate: "Localize {{target_app}}"
        )
        #expect(titleError == nil)

        switch await store.instantiateTemplate(templateID: template.id, inputValues: ["target_app": "Notes"]) {
        case .success(let instance):
            #expect(instance.title == "Localize Notes")
            #expect(instance.templateInputValues == ["target_app": "Notes"])
        case .failure(let message):
            Issue.record("valid title template should instantiate: \(message)")
        }
    }

    @Test("Changing template inputs cannot strand an invalid instance title template")
    func changingTemplateInputsPreservesTitleTemplateValidity() async {
        let store = TaskStore()
        let template = await store.addTask(title: "Localize App", description: "Localize it.", isTemplate: true)
        _ = await store.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "target_app", description: "App name.", required: true)
        ])
        let titleError = await store.setTemplateInstanceTitleTemplate(
            id: template.id,
            titleTemplate: "Localize {{target_app}}"
        )
        #expect(titleError == nil)

        let inputError = await store.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "app_name", description: "App name.", required: true)
        ])

        #expect(inputError?.contains("instance title template") == true)
        let unchangedTemplate = await store.task(id: template.id)
        #expect(unchangedTemplate?.templateInputDefinitions.map(\.name) == ["target_app"])
        #expect(unchangedTemplate?.templateInstanceTitleTemplate == "Localize {{target_app}}")
    }

    @Test("Template clones inherit user tool overrides but not scoped approvals")
    func templateCloneInheritsToolOverridesNotApprovedTools() async {
        let store = TaskStore()
        let template = await store.addTask(title: "Check messages", description: "Check source.", isTemplate: true)
        await store.setApprovedTools(id: template.id, approvedTools: ["file_read"])
        await store.setUserToolOverride(id: template.id, tool: ReportInboundUserMessageTool.toolName, enabled: true)

        switch await store.instantiateTemplate(templateID: template.id, inputValues: [:]) {
        case .success(let instance):
            #expect(instance.userToolOverrides == [ReportInboundUserMessageTool.toolName: true])
            #expect(instance.approvedTools == nil)
        case .failure(let message):
            Issue.record("template should instantiate: \(message)")
        }
    }

    @Test("Only templates can define template inputs")
    func onlyTemplatesCanDefineInputs() async {
        let store = TaskStore()
        let task = await store.addTask(title: "Ordinary", description: "d")
        let error = await store.setTemplateInputDefinitions(id: task.id, definitions: [
            TemplateInputDefinition(name: "target_app", description: "App name", required: true)
        ])
        #expect(error?.contains("not a template") == true)
    }
}
