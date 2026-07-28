import Foundation
import Testing
@testable import AgentSmithKit

/// `{{input}}` substitution into a template instance's authored text, and the authoring-time
/// check that catches a placeholder naming no input.
///
/// The two halves are deliberately asymmetric and must stay that way: RENDERING is lenient (an
/// unrecognized `{{…}}` passes through verbatim, so a template whose prose quotes brace syntax
/// still runs), while AUTHORING is strict (the same text is refused when written, so a typo
/// reaches its author rather than a worker).
@Suite("Template input substitution")
struct TemplateSubstitutionTests {

    private func makeTemplate(
        store: TaskStore,
        title: String = "Build",
        description: String,
        inputs: [TemplateInputDefinition]
    ) async -> AgentTask {
        await store.addTask(
            title: title,
            description: description,
            isTemplate: true,
            templateInputDefinitions: inputs
        )
    }

    private func instance(_ store: TaskStore, _ templateID: UUID, _ values: [String: String]) async -> AgentTask? {
        switch await store.instantiateTemplate(templateID: templateID, inputValues: values) {
        case .success(let created):
            return created
        case .failure(let message):
            Issue.record("instantiation should have succeeded: \(message)")
            return nil
        }
    }

    @Test("Substitution reaches the description, the steps, and every criterion field")
    func substitutionReachesEveryAuthoredField() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build {{app_name}} from {{project_dir}}.",
            inputs: [
                TemplateInputDefinition(name: "app_name", description: "App name.", required: true),
                TemplateInputDefinition(name: "project_dir", description: "Checkout path.", required: true)
            ]
        )
        #expect(await store.setSteps(id: template.id, steps: [
            TaskStep(text: "cd {{project_dir}}", origin: .smith),
            TaskStep(text: "xcodebuild -scheme {{app_name}}", origin: .smith)
        ]) == nil)
        #expect(await store.setAcceptanceCriteria(id: template.id, criteria: [
            AcceptanceCriterion(
                name: "{{app_name}} builds",
                validationPrompt: "Confirm {{app_name}} built cleanly in {{project_dir}}.",
                inputEnumeratorPrompt: "List every scheme in {{project_dir}}.",
                origin: .smith
            )
        ]) == nil)

        guard let instance = await instance(store, template.id, [
            "app_name": "Widgets",
            "project_dir": "/src/widgets"
        ]) else { return }

        #expect(instance.description == "Build Widgets from /src/widgets.")
        #expect(instance.steps.map(\.text) == ["cd /src/widgets", "xcodebuild -scheme Widgets"])
        #expect(instance.acceptanceCriteria[0].name == "Widgets builds")
        #expect(instance.acceptanceCriteria[0].validationPrompt == "Confirm Widgets built cleanly in /src/widgets.")
        #expect(instance.acceptanceCriteria[0].inputEnumeratorPrompt == "List every scheme in /src/widgets.")
        // The template itself is untouched — it has to render again for the next run.
        #expect(await store.task(id: template.id)?.description == "Build {{app_name}} from {{project_dir}}.")
    }

    @Test("The template's own title renders when no instance title template is set")
    func plainTitleRendersWithoutATitleTemplate() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            title: "Localize {{app_name}} ({{locale}})",
            description: "Localize it.",
            inputs: [
                TemplateInputDefinition(name: "app_name", description: "App name.", required: true),
                TemplateInputDefinition(name: "locale", description: "Locale.", required: false)
            ]
        )

        guard let both = await instance(store, template.id, ["app_name": "Notes", "locale": "fr"]) else { return }
        #expect(both.title == "Localize Notes (fr)")

        // An omitted OPTIONAL input must not leave a doubled space behind — the single-line layout
        // is what a title gets, exactly as an explicit title template would.
        guard let partial = await instance(store, template.id, ["app_name": "Notes"]) else { return }
        #expect(partial.title == "Localize Notes ()")
    }

    @Test("Multi-line body text keeps its layout; only titles collapse whitespace")
    func bodyTextPreservesLayout() async {
        let store = TaskStore()
        let description = """
            # Build {{app_name}}

            - step one
            - step two

                indented code block
            """
        let template = await makeTemplate(
            store: store,
            description: description,
            inputs: [TemplateInputDefinition(name: "app_name", description: "App name.", required: true)]
        )

        guard let instance = await instance(store, template.id, ["app_name": "Widgets"]) else { return }
        #expect(instance.description == """
            # Build Widgets

            - step one
            - step two

                indented code block
            """)
    }

    @Test("An unrecognized placeholder renders verbatim rather than failing the run")
    func unrecognizedPlaceholdersPassThrough() async {
        let store = TaskStore()
        // Created with text and definitions in one shot, which is the shape legacy data has and the
        // shape `addTask` cannot refuse. Covers all four ways a `{{…}}` fails to be a placeholder:
        // an undefined name, an unclosed brace, surrounding whitespace, and a non-conforming name.
        let template = await makeTemplate(
            store: store,
            title: "Fix the partial",
            description: "The tag {{user_name}} is wrong; use {{app_name}}. Unclosed: {{oops. Spaced: {{ app_name }}. Bad name: {{App_Name}}.",
            inputs: [TemplateInputDefinition(name: "app_name", description: "App name.", required: true)]
        )

        guard let instance = await instance(store, template.id, ["app_name": "Widgets"]) else { return }
        #expect(instance.description == "The tag {{user_name}} is wrong; use Widgets. Unclosed: {{oops. Spaced: {{ app_name }}. Bad name: {{App_Name}}.")
    }

    @Test("A defined-but-omitted optional input renders empty, and a criterion stays default-validated")
    func omittedOptionalRendersEmptyAndDefaultValidatorSurvives() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Ship {{app_name}}.{{notes}}",
            inputs: [
                TemplateInputDefinition(name: "app_name", description: "App name.", required: true),
                TemplateInputDefinition(name: "notes", description: "Extra notes.", required: false)
            ]
        )
        // An empty validation prompt means "judge with the shipped default validator". Substitution
        // must not accidentally populate it — `usesDefaultValidator` keys on emptiness.
        #expect(await store.setAcceptanceCriteria(id: template.id, criteria: [
            AcceptanceCriterion(name: "{{app_name}} ships", validationPrompt: "", origin: .user)
        ]) == nil)

        guard let instance = await instance(store, template.id, ["app_name": "Widgets"]) else { return }
        #expect(instance.description == "Ship Widgets.")
        #expect(instance.acceptanceCriteria[0].name == "Widgets ships")
        #expect(instance.acceptanceCriteria[0].usesDefaultValidator)
    }

    @Test("Authoring refuses an unknown placeholder in the description")
    func authoringRefusesUnknownPlaceholderInDescription() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build {{app_name}}.",
            inputs: [TemplateInputDefinition(name: "app_name", description: "App name.", required: true)]
        )

        let problem = await store.updateDefinition(
            id: template.id,
            title: "Build",
            description: "Build {{app_nmae}}.",
            isTemplate: true,
            templateInputDefinitions: [TemplateInputDefinition(name: "app_name", description: "App name.", required: true)],
            templateInstanceTitleTemplate: nil
        )
        #expect(problem?.contains("app_nmae") == true)
        #expect(problem?.contains("description") == true)
        #expect(await store.task(id: template.id)?.description == "Build {{app_name}}.")

        // The same edit is accepted once the placeholder names a real input.
        #expect(await store.updateDescription(id: template.id, description: "Build {{app_name}} now.") == nil)
    }

    @Test("Authoring refuses an unknown placeholder in a step and in a criterion")
    func authoringRefusesUnknownPlaceholderInStepsAndCriteria() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build it.",
            inputs: [TemplateInputDefinition(name: "app_name", description: "App name.", required: true)]
        )

        let stepProblem = await store.applyStepAction(
            taskID: template.id,
            action: .add(text: "build {{app_nmae}}", origin: .smith)
        )
        #expect(stepProblem?.contains("app_nmae") == true)
        #expect(await store.task(id: template.id)?.steps.isEmpty == true)

        let setStepsProblem = await store.setSteps(id: template.id, steps: [
            TaskStep(text: "build {{app_name}}", origin: .smith),
            TaskStep(text: "sign {{app_nmae}}", origin: .smith)
        ])
        #expect(setStepsProblem?.contains("step 2") == true)
        #expect(await store.task(id: template.id)?.steps.isEmpty == true)

        let criterionProblem = await store.applyCriterionActions(taskID: template.id, actions: [
            .add(name: "builds", validationPrompt: "Confirm {{app_nmae}} built.", inputEnumeratorPrompt: nil, waivable: false, origin: .smith)
        ])
        #expect(criterionProblem?.contains("app_nmae") == true)
        #expect(await store.task(id: template.id)?.acceptanceCriteria.isEmpty == true)

        let replaceProblem = await store.setAcceptanceCriteria(id: template.id, criteria: [
            AcceptanceCriterion(name: "{{nope}} builds", validationPrompt: "Confirm it built.", origin: .user)
        ])
        #expect(replaceProblem?.contains("nope") == true)
        #expect(await store.task(id: template.id)?.acceptanceCriteria.isEmpty == true)
    }

    @Test("Removing an input is refused while a placeholder still names it")
    func removingAnInputCannotOrphanAPlaceholder() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build {{app_name}} from {{project_dir}}.",
            inputs: [
                TemplateInputDefinition(name: "app_name", description: "App name.", required: true),
                TemplateInputDefinition(name: "project_dir", description: "Checkout path.", required: true)
            ]
        )

        let problem = await store.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "app_name", description: "App name.", required: true)
        ])
        #expect(problem?.contains("project_dir") == true)
        #expect(await store.task(id: template.id)?.templateInputDefinitions.count == 2)

        // Rewriting the text first is what unblocks it.
        #expect(await store.updateDescription(id: template.id, description: "Build {{app_name}}.") == nil)
        #expect(await store.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "app_name", description: "App name.", required: true)
        ]) == nil)
    }

    @Test("An input and its placeholders can be renamed in one edit")
    func renamingAnInputAndItsPlaceholdersTogetherIsAccepted() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build {{app_name}}.",
            inputs: [TemplateInputDefinition(name: "app_name", description: "App name.", required: true)]
        )

        // Validating the new text against the OLD definitions (or vice versa) would reject this;
        // the check runs against the prospective state, where both halves agree.
        let problem = await store.updateDefinition(
            id: template.id,
            title: "Build",
            description: "Build {{product}}.",
            isTemplate: true,
            templateInputDefinitions: [TemplateInputDefinition(name: "product", description: "Product name.", required: true)],
            templateInstanceTitleTemplate: nil
        )
        #expect(problem == nil)

        guard let instance = await instance(store, template.id, ["product": "Widgets"]) else { return }
        #expect(instance.description == "Build Widgets.")
    }

    @Test("A task with no template inputs has no placeholders to police")
    func bracesAreOrdinaryTextWithoutInputDefinitions() async {
        let store = TaskStore()
        let task = await store.addTask(title: "Fix the template", description: "The {{user_name}} tag renders blank.")

        // Ordinary task: nothing rejects the braces, nothing rewrites them.
        #expect(await store.updateDescription(id: task.id, description: "Both {{user_name}} and {{org}} render blank.") == nil)
        // Promoting it to a template must stay possible — a definition set is what mints
        // placeholders, and this template has none.
        #expect(await store.setTemplate(id: task.id, isTemplate: true) == nil)
        #expect(await store.task(id: task.id)?.isTemplate == true)

        guard let instance = await instance(store, task.id, [:]) else { return }
        #expect(instance.description == "Both {{user_name}} and {{org}} render blank.")
    }

    @Test("Tombstoned steps are neither rendered nor policed")
    func tombstonedStepsAreIgnored() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build it.",
            inputs: [TemplateInputDefinition(name: "app_name", description: "App name.", required: true)]
        )
        #expect(await store.setSteps(id: template.id, steps: [
            TaskStep(text: "build {{app_name}}", origin: .smith),
            TaskStep(text: "obsolete {{app_name}}", status: .removed, note: "dropped", origin: .smith)
        ]) == nil)

        guard let instance = await instance(store, template.id, ["app_name": "Widgets"]) else { return }
        #expect(instance.steps.map(\.text) == ["build Widgets"])
    }
}
