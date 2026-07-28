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

    @Test("Removing an input leaves its placeholders as literal text, refused on the next edit")
    func removingAnInputStrandsPlaceholdersAsLiteralText() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build {{app_name}} from {{project_dir}}.",
            inputs: [
                TemplateInputDefinition(name: "app_name", description: "App name.", required: true),
                TemplateInputDefinition(name: "project_dir", description: "Checkout path.", required: true)
            ]
        )

        // Allowed — a definitions-only write validates no text. Refusing here is what made an
        // input rename impossible; see `renamingAnInputIsPossibleFromEveryPath`.
        #expect(await store.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "app_name", description: "App name.", required: true)
        ]) == nil)

        // The stranded placeholder degrades to literal text — visible, never a failed run.
        guard let instance = await instance(store, template.id, ["app_name": "Widgets"]) else { return }
        #expect(instance.description == "Build Widgets from {{project_dir}}.")

        // And the next edit of that text says so, which is where the author gets told.
        let problem = await store.updateDescription(id: template.id, description: "Rebuild {{app_name}} from {{project_dir}}.")
        #expect(problem?.contains("project_dir") == true)
    }

    @Test("Renaming an input and its references is possible from every path")
    func renamingAnInputIsPossibleFromEveryPath() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build {{app_name}}.",
            inputs: [TemplateInputDefinition(name: "app_name", description: "App.", required: true)]
        )
        #expect(await store.setSteps(id: template.id, steps: [
            TaskStep(text: "xcodebuild -scheme {{app_name}}", origin: .user)
        ]) == nil)

        // Exactly the task editor's save order: the definition (with the new input AND the new
        // description) first, then the criteria, then the steps. Checking `updateDefinition`
        // against fields it does not write refused this at step one, over step text the very next
        // call was about to replace — so a correctly-renamed template could not be saved at all.
        #expect(await store.updateDefinition(
            id: template.id,
            title: "Build",
            description: "Build {{product}}.",
            isTemplate: true,
            templateInputDefinitions: [TemplateInputDefinition(name: "product", description: "Product.", required: true)],
            templateInstanceTitleTemplate: nil
        ) == nil)
        #expect(await store.setSteps(id: template.id, steps: [
            TaskStep(text: "xcodebuild -scheme {{product}}", origin: .user)
        ]) == nil)

        guard let instance = await instance(store, template.id, ["product": "Widgets"]) else { return }
        #expect(instance.description == "Build Widgets.")
        #expect(instance.steps.map(\.text) == ["xcodebuild -scheme Widgets"])
    }

    @Test("A title with no placeholders survives instantiation byte-for-byte")
    func titleWithoutPlaceholdersIsNotNormalized() async {
        let store = TaskStore()
        // Whitespace collapsing repairs the gap an omitted optional input leaves behind, so it must
        // not run when nothing was substituted. Unconditional collapsing silently rewrote the title
        // of every instance — including templates that use no placeholders anywhere.
        let template = await makeTemplate(
            store: store,
            title: "Nightly  report — v2",
            description: "Audit {{repo_path}}.",
            inputs: [TemplateInputDefinition(name: "repo_path", description: "Repo.", required: true)]
        )

        guard let instance = await instance(store, template.id, ["repo_path": "/src"]) else { return }
        #expect(instance.title == "Nightly  report — v2")
        #expect(instance.description == "Audit /src.")
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

    @Test("An amendment to a template is checked; one to an instance or ordinary task is not")
    func amendmentsAreCheckedOnTemplatesOnly() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build {{app_name}}.",
            inputs: [TemplateInputDefinition(name: "app_name", description: "App.", required: true)]
        )

        // `amendDescription` is the THIRD writer of a template's description, and the text it
        // appends is substituted at instantiation like the rest — so a typo here would weld into
        // every future clone.
        let problem = await store.amendDescription(id: template.id, amendment: "Also sign {{app_nmae}}.")
        #expect(problem?.contains("app_nmae") == true)
        #expect(problem?.contains("description amendment") == true)
        #expect(await store.task(id: template.id)?.description == "Build {{app_name}}.")

        // A placeholder naming a real input is accepted, and substitutes in the next instance.
        #expect(await store.amendDescription(id: template.id, amendment: "Also sign {{app_name}}.") == nil)
        guard let instance = await instance(store, template.id, ["app_name": "Widgets"]) else { return }
        #expect(instance.description == "Build Widgets.\n\n[Amendment]: Also sign Widgets.")

        // The INSTANCE carries a snapshot of the definitions but is not a template, and its text is
        // never rendered again — so an amendment naming anything at all is fine. Gating on the
        // definitions rather than on `isTemplate` would break every per-run instruction.
        #expect(await store.amendDescription(id: instance.id, amendment: "Ignore {{whatever}}.") == nil)
        #expect(await store.task(id: instance.id)?.description.hasSuffix("[Amendment]: Ignore {{whatever}}.") == true)
    }

    @Test("An instance amendment substitutes the run's supplied input values; unsupplied names stay literal")
    func instanceAmendmentSubstitutesSuppliedValues() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build {{app_name}}.",
            inputs: [
                TemplateInputDefinition(name: "app_name", description: "App.", required: true),
                TemplateInputDefinition(name: "locale", description: "Locale.", required: false)
            ]
        )
        guard let instance = await instance(store, template.id, ["app_name": "Widgets"]) else { return }
        // The supplied value renders; the omitted optional stays literal — an instance carries
        // values but not definitions, and for an after-the-fact amendment the visible placeholder
        // is the honest outcome, not a silent empty gap.
        #expect(await store.amendDescription(id: instance.id, amendment: "Also sign {{app_name}} for {{locale}}.") == nil)
        #expect(await store.task(id: instance.id)?.description.hasSuffix("[Amendment]: Also sign Widgets for {{locale}}.") == true)
        // The dedup compares the SUBSTITUTED text — re-sending the same amendment stacks nothing.
        #expect(await store.amendDescription(id: instance.id, amendment: "Also sign {{app_name}} for {{locale}}.") == nil)
        let description = await store.task(id: instance.id)?.description ?? ""
        #expect(description.components(separatedBy: "[Amendment]:").count == 2)
    }

    @Test("The template-inputs block renders ABOVE the description")
    func templateInputsBlockLeadsTheRenderedDescription() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build the app.",
            inputs: [TemplateInputDefinition(name: "app_name", description: "App.", required: true)]
        )
        guard let instance = await instance(store, template.id, ["app_name": "Widgets"]) else { return }
        let rendered = instance.renderedDescriptionWithTemplateInputs()
        #expect(rendered.hasPrefix("## Template inputs\n- app_name: Widgets"))
        #expect(rendered.hasSuffix("Build the app."))
    }

    @Test("A rejected amendment stays rejected when it is re-sent")
    func rejectedAmendmentIsNotLaunderedByTheDedup() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            description: "Build {{app_name}}.",
            inputs: [TemplateInputDefinition(name: "app_name", description: "App.", required: true)]
        )
        // Checking BELOW the dedup would let a re-send fall into the no-op branch and report
        // success for text the system rejected the first time.
        #expect(await store.amendDescription(id: template.id, amendment: "Sign {{app_nmae}}.") != nil)
        #expect(await store.amendDescription(id: template.id, amendment: "Sign {{app_nmae}}.") != nil)
        #expect(await store.task(id: template.id)?.description == "Build {{app_name}}.")
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

    @Test("A title template that renders empty falls back to the RENDERED template title")
    func emptyTitleTemplateFallsBackToTheRenderedTemplateTitle() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            title: "Localize {{app_name}}",
            description: "Localize it.",
            inputs: [
                TemplateInputDefinition(name: "app_name", description: "App name.", required: true),
                TemplateInputDefinition(name: "locale", description: "Locale.", required: false)
            ]
        )
        // A title template made entirely of an OPTIONAL input renders to nothing when that input is
        // omitted, which is the only way to reach the fallback.
        #expect(await store.setTemplateInstanceTitleTemplate(id: template.id, titleTemplate: "{{locale}}") == nil)

        guard let instance = await instance(store, template.id, ["app_name": "Notes"]) else { return }
        // The fallback renders like every other title path. Handing back the RAW title showed a
        // placeholder for an input this run actually supplied.
        #expect(instance.title == "Localize Notes")
    }

    @Test("The fallback title is not normalized when the template title has no placeholders")
    func fallbackTitleWithoutPlaceholdersIsNotNormalized() async {
        let store = TaskStore()
        let template = await makeTemplate(
            store: store,
            title: "Nightly  report — v2",
            description: "Audit {{repo_path}}.",
            inputs: [
                TemplateInputDefinition(name: "repo_path", description: "Repo.", required: true),
                TemplateInputDefinition(name: "locale", description: "Locale.", required: false)
            ]
        )
        #expect(await store.setTemplateInstanceTitleTemplate(id: template.id, titleTemplate: "{{locale}}") == nil)

        guard let instance = await instance(store, template.id, ["repo_path": "/src"]) else { return }
        // Rendering the fallback is only safe because collapsing repairs a gap substitution made:
        // a title nothing substituted into must come back exactly as authored, here too.
        #expect(instance.title == "Nightly  report — v2")
    }

    @Test("The creation-path check covers every field instantiation substitutes")
    func creationCheckCoversEverySubstitutedField() {
        // The substituting half is pinned by `substitutionReachesEveryAuthoredField`; this is the
        // checking half. A field that substitutes but is not checked ships a typo to a worker; a
        // field checked but not substituted refuses text that would have run fine.
        let defined: Set<String> = ["app_name"]
        let clean = AcceptanceCriterion(
            name: "Ships {{app_name}}",
            validationPrompt: "The bundle is named {{app_name}}",
            inputEnumeratorPrompt: "List targets in {{app_name}}",
            origin: .smith
        )
        func problem(
            title: String = "Build {{app_name}}",
            description: String = "Build {{app_name}} for release",
            steps: [String] = ["cd {{app_name}}"],
            criteria: [AcceptanceCriterion] = [clean]
        ) -> String? {
            TemplateInputValidation.firstProblem(
                authoringTemplateWithTitle: title,
                description: description,
                activeStepTexts: steps,
                criteria: criteria,
                definedNames: defined
            )
        }
        #expect(problem() == nil)
        #expect(problem(title: "Build {{app_nmae}}")?.hasPrefix("Template title:") == true)
        #expect(problem(description: "Build {{app_nmae}}")?.hasPrefix("Template description:") == true)
        #expect(problem(steps: ["cd {{app_name}}", "test {{app_nmae}}"])?.hasPrefix("Template step 2:") == true)

        var badName = clean
        badName.name = "Ships {{app_nmae}}"
        #expect(problem(criteria: [badName])?.hasPrefix("Template criterion \"Ships {{app_nmae}}\" name:") == true)

        var badPrompt = clean
        badPrompt.validationPrompt = "The bundle is named {{app_nmae}}"
        #expect(problem(criteria: [badPrompt])?.hasPrefix("Template criterion \"Ships {{app_name}}\" validation prompt:") == true)

        var badEnumerator = clean
        badEnumerator.inputEnumeratorPrompt = "List targets in {{app_nmae}}"
        #expect(problem(criteria: [badEnumerator])?.hasPrefix("Template criterion \"Ships {{app_name}}\" input enumerator prompt:") == true)
    }

    @Test("An unclosed placeholder deep in long prose is located, not buried")
    func unclosedPlaceholderQuotesAWindowNotAPrefix() {
        // `validate` scans FORWARD past every well-formed placeholder, so the offending `{{` sits
        // wherever the author typed it — routinely near the end of a long description. Quoting a
        // leading prefix would show text that is not the problem while omitting the text that is,
        // and the unclosed case has no placeholder name to fall back on.
        let filler = String(repeating: "lorem ipsum dolor sit amet. ", count: 200)
        let template = "\(filler)and then MARKER_BEFORE {{unterminated placeholder"
        guard let problem = TemplateStringRenderer.validate(template, allowedNames: ["app_name"]) else {
            Issue.record("an unclosed placeholder should be a problem")
            return
        }
        #expect(problem.count < 300, "the whole document must not land in the message: \(problem.count) chars")
        #expect(problem.contains("MARKER_BEFORE"), "the window must show the text around the offending brace")
        #expect(problem.contains("character \(template.distance(from: template.startIndex, to: template.range(of: "{{")!.lowerBound))"))
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
