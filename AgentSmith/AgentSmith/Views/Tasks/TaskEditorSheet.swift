import SwiftUI
import AgentSmithKit

/// One presentation of `TaskEditorSheet`, and the reason the editor is always driven by
/// `.sheet(item:)` rather than `.sheet(isPresented:)`.
///
/// The editor is a form: its `@State` has to be seeded from the task being edited, which is
/// normally the anti-pattern `CLAUDE.md` warns about — with `isPresented`, SwiftUI may reuse the
/// view identity across presentations and the seeding initializer never runs again, so the second
/// open shows the first open's abandoned edits. Carrying a distinct `id` per presentation makes
/// each open a genuinely new view, which is what makes seeding from `mode` correct.
struct TaskEditorPresentation: Identifiable {
    let id: UUID
    let mode: TaskEditorSheet.Mode

    /// A brand-new id every time, so reopening "New Task" never inherits a prior draft.
    static func creating() -> TaskEditorPresentation {
        TaskEditorPresentation(id: UUID(), mode: .create)
    }

    /// Keyed by task id — reopening the same task rebuilds the form from current store state.
    static func editing(_ task: AgentTask) -> TaskEditorPresentation {
        TaskEditorPresentation(id: task.id, mode: .edit(task))
    }
}

struct TaskEditorSheet: View {
    enum Mode {
        case create
        case edit(AgentTask)
    }

    let mode: Mode
    @Bindable var viewModel: AppViewModel
    let onDone: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var isTemplate: Bool
    @State private var instanceTitleTemplate: String
    @State private var inputs: [InputRow]
    @State private var criteria: [CriterionRow]
    @State private var steps: [StepRow]
    @State private var capabilities: [CapabilityRow]
    /// Seeded like every other field here; see `TaskEditorPresentation` for why seeding is correct.
    @State private var requiresUserAcceptance: Bool
    /// Tombstoned steps carried through untouched. They are not shown here — this sheet authors
    /// the active seed plan — but they MUST be written back on save, because `setTaskSteps`
    /// replaces the step array wholesale and an active-only array erases the append-only record
    /// that acceptance validators are promised.
    @State private var preservedTombstones: [TaskStep]
    /// The form as it opened for `Mode.edit`'s task. Save writes a part only when it differs from
    /// this, because the contract and steps are refused once the task is running and an untouched
    /// part must not block a change that is allowed (a capability edit). Criteria and steps compare
    /// the RAW rows: the builders normalize (an empty prompt takes the name, tombstones go last), so
    /// comparing built output both invents changes and hides real ones — typing a prompt equal to
    /// the name switches a criterion from the default validator to a custom one.
    struct OpenedForm {
        let title: String
        let description: String
        let isTemplate: Bool
        let inputs: [TemplateInputDefinition]
        let instanceTitleTemplate: String
        let criterionRows: [CriterionRow]
        let stepRows: [StepRow]
    }
    @State private var localError: String?

    struct InputRow: Identifiable {
        let id: UUID
        var name: String
        var description: String
        var required: Bool

        init(id: UUID = UUID(), name: String = "", description: String = "", required: Bool = true) {
            self.id = id
            self.name = name
            self.description = description
            self.required = required
        }
    }

    struct CriterionRow: Identifiable, Equatable {
        let id: UUID
        var name: String
        var validationPrompt: String
        var inputEnumeratorPrompt: String
        var waivable: Bool

        init(
            id: UUID = UUID(),
            name: String = "",
            validationPrompt: String = "",
            inputEnumeratorPrompt: String = "",
            waivable: Bool = false
        ) {
            self.id = id
            self.name = name
            self.validationPrompt = validationPrompt
            self.inputEnumeratorPrompt = inputEnumeratorPrompt
            self.waivable = waivable
        }
    }

    /// A required capability being edited: an item the task already has (`existing`, whose
    /// provenance stays on show) or one this sheet adds. Only the text is editable; `save()` turns
    /// the rows into edits against the list the sheet opened with.
    struct CapabilityRow: Identifiable {
        let id: UUID
        var text: String
        let existing: RequiredCapability?

        init() {
            self.id = UUID()
            self.text = ""
            self.existing = nil
        }

        init(capability: RequiredCapability) {
            self.id = capability.id
            self.text = capability.text
            self.existing = capability
        }

        var draft: RequiredCapabilityDraft {
            RequiredCapabilityDraft(existingID: existing?.id, text: text)
        }

        var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// One editable ACTIVE step. Text is the only thing this sheet edits, but the row carries
    /// the rest of the step so `save()` can write it back untouched — rebuilding steps from
    /// text alone silently reset every status to `.pending`, dropped skip notes, and rewrote
    /// Brown's and Smith's authorship to `.user`.
    struct StepRow: Identifiable, Equatable {
        let id: UUID
        var text: String
        let status: TaskStep.Status
        let note: String?
        let origin: TaskAuthorship

        init(id: UUID = UUID(), text: String = "", status: TaskStep.Status = .pending, note: String? = nil, origin: TaskAuthorship = .user) {
            self.id = id
            self.text = text
            self.status = status
            self.note = note
            self.origin = origin
        }

        init(step: TaskStep) {
            self.init(id: step.id, text: step.text, status: step.status, note: step.note, origin: step.origin)
        }

        func built() -> TaskStep? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TaskStep(id: id, text: trimmed, status: status, note: note, origin: origin)
        }
    }

    init(mode: Mode, viewModel: AppViewModel, onDone: @escaping () -> Void) {
        self.mode = mode
        self.viewModel = viewModel
        self.onDone = onDone
        switch mode {
        case .create:
            _title = State(initialValue: "")
            _description = State(initialValue: "")
            _isTemplate = State(initialValue: false)
            _instanceTitleTemplate = State(initialValue: "")
            _inputs = State(initialValue: [])
            _criteria = State(initialValue: [])
            _steps = State(initialValue: [])
            _capabilities = State(initialValue: [])
            _requiresUserAcceptance = State(initialValue: false)
            _preservedTombstones = State(initialValue: [])
        case .edit(let task):
            _title = State(initialValue: task.title)
            _description = State(initialValue: task.description)
            _isTemplate = State(initialValue: task.isTemplate)
            _instanceTitleTemplate = State(initialValue: task.templateInstanceTitleTemplate ?? "")
            _inputs = State(initialValue: Self.inputRows(of: task))
            _criteria = State(initialValue: Self.criterionRows(of: task))
            _steps = State(initialValue: Self.stepRows(of: task))
            _capabilities = State(initialValue: task.requiredCapabilities.map(CapabilityRow.init(capability:)))
            _requiresUserAcceptance = State(initialValue: task.requiresUserAcceptance)
            _preservedTombstones = State(initialValue: task.steps.filter { !$0.isActive })
        }
    }

    private static func inputRows(of task: AgentTask) -> [InputRow] {
        task.templateInputDefinitions.map {
            InputRow(name: $0.name, description: $0.description, required: $0.required)
        }
    }

    private static func criterionRows(of task: AgentTask) -> [CriterionRow] {
        task.acceptanceCriteria.map {
            CriterionRow(
                id: $0.id,
                name: $0.name,
                validationPrompt: $0.validationPrompt,
                inputEnumeratorPrompt: $0.inputEnumeratorPrompt ?? "",
                waivable: $0.waivable
            )
        }
    }

    private static func stepRows(of task: AgentTask) -> [StepRow] {
        task.steps.filter(\.isActive).map(StepRow.init(step:))
    }

    /// `OpenedForm` for `task`, from the same rows and builders the form itself uses.
    private static func openedForm(of task: AgentTask) -> OpenedForm {
        OpenedForm(
            title: task.title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: task.description.trimmingCharacters(in: .whitespacesAndNewlines),
            isTemplate: task.isTemplate,
            inputs: builtInputs(from: inputRows(of: task)),
            instanceTitleTemplate: (task.templateInstanceTitleTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            criterionRows: criterionRows(of: task),
            stepRows: stepRows(of: task)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    definitionSection()
                    TaskEditorCapabilitiesSection(capabilities: $capabilities, lockReason: capabilitiesLockReason)
                    templateSection()
                    criteriaSection()
                    stepsSection()
                    InlineProblemText(message: localError)
                }
                .padding(.trailing, 8)
            }
            footer()
        }
        .padding(20)
        .frame(width: 680, height: 720)
        .onAppear(perform: clearStaleTaskActionError)
    }

    /// A prior failed action may have left an error on the view model whose alert is attached to a
    /// window BEHIND this sheet (the sidebar, or Task Detail); clear it so it can't surface, looking
    /// like a failure, after a successful save closes the sheet. This sheet reports its own problems
    /// inline.
    private func clearStaleTaskActionError() {
        guard viewModel.taskActionError != nil else { return }
        DispatchQueue.main.async { viewModel.taskActionError = nil }
    }

    private func header() -> some View {
        HStack {
            Text(isCreate ? "New Task" : "Edit Task")
                .font(.title3.bold())
            Spacer()
            Button("Cancel", action: onDone)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func definitionSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Definition").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Description", text: $description, axis: .vertical)
                .lineLimit(6...12)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func templateSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Template", isOn: $isTemplate)
                .toggleStyle(.checkbox)
            if isTemplate {
                TextField("Instance title template, e.g. Localize {{app_name}}", text: $instanceTitleTemplate)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Inputs").font(.headline)
                    Spacer()
                    Button(action: {
                        inputs.append(InputRow())
                    }, label: {
                        Label("Add Input", systemImage: "plus.circle")
                    })
                    .buttonStyle(.plain)
                }
                ForEach($inputs) { $row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("name", text: $row.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                        TextField("Description", text: $row.description)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Required", isOn: $row.required)
                            .toggleStyle(.checkbox)
                        RemoveRowButton(title: "Remove input") {
                            inputs.removeAll { $0.id == row.id }
                        }
                    }
                }

                if !inputs.isEmpty {
                    Text("Write {{input_name}} in the title, description, steps, or acceptance criteria — each is replaced with the run's value when an instance is created.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let problem = templateProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppColors.verdictError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func criteriaSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Acceptance").font(.headline)
                Spacer()
                Button(action: {
                    criteria.append(CriterionRow())
                }, label: {
                    Label("Add Criterion", systemImage: "plus.circle")
                })
                .buttonStyle(.plain)
                .disabled(!canEditValidationContract)
            }
            UserAcceptanceGateToggle(
                requiresUserAcceptance: $requiresUserAcceptance,
                lockedReason: userAcceptanceGateLockedReason
            )
            if !canEditValidationContract {
                Text("Acceptance criteria are locked for this task status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach($criteria) { $row in
                criterionCard(row: $row, number: criterionNumber(for: row.id))
                    .disabled(!canEditValidationContract)
            }
        }
    }

    private func criterionCard(row: Binding<CriterionRow>, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                requirementChip(number)
                TextField("Name", text: row.name)
                    .textFieldStyle(.roundedBorder)
                Toggle("Waivable", isOn: row.waivable)
                    .toggleStyle(.checkbox)
                RemoveRowButton(title: "Remove criterion") {
                    criteria.removeAll { $0.id == row.wrappedValue.id }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Validation prompt")
                TextField("Validation prompt", text: row.validationPrompt, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Input enumerator prompt")
                TextField("Input enumerator prompt", text: row.inputEnumeratorPrompt, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
        .background(AppColors.secondaryBackground)
        .clipShape(.rect(cornerRadius: 10))
    }

    private func requirementChip(_ number: Int) -> some View {
        Text("R\(number)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppColors.subtleRowBackgroundLift)
            .clipShape(Capsule())
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func criterionNumber(for id: UUID) -> Int {
        guard let index = criteria.firstIndex(where: { $0.id == id }) else { return 0 }
        return index + 1
    }

    private func stepsSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Seed Steps").font(.headline)
                Spacer()
                Button(action: {
                    steps.append(StepRow())
                }, label: {
                    Label("Add Step", systemImage: "plus.circle")
                })
                .buttonStyle(.plain)
                .disabled(!canEditValidationContract)
            }
            if !canEditValidationContract {
                Text("Seed steps are locked for this task status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach($steps) { $row in
                HStack {
                    TextField("Step", text: $row.text)
                        .textFieldStyle(.roundedBorder)
                    RemoveRowButton(title: "Remove step") {
                        steps.removeAll { $0.id == row.id }
                    }
                }
                .disabled(!canEditValidationContract)
            }
        }
    }

    private func footer() -> some View {
        HStack {
            Spacer()
            Button(isCreate ? "Create" : "Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var userAcceptanceGateLockedReason: String? {
        switch mode {
        case .create:
            return nil
        case .edit(let task):
            return UserAcceptanceGateToggle.lockedReason(for: task)
        }
    }

    /// Why the capabilities can't change now (`AgentTask.requiredCapabilitiesLockReason`, the rule
    /// the store enforces); nil when they can. On a running task a change re-scopes its worker.
    private var capabilitiesLockReason: RequiredCapabilitiesLockReason? {
        switch mode {
        case .create:
            return nil
        case .edit(let task):
            return task.requiredCapabilitiesLockReason
        }
    }

    private var canEditValidationContract: Bool {
        switch mode {
        case .create:
            return true
        case .edit(let task):
            return task.status.isValidationContractEditable
        }
    }

    /// Live validation of the template inputs + instance title template, run WHILE the form is open
    /// using the exact same checks the save path runs — so an invalid input name (wrong characters,
    /// duplicate, missing description) or a title template referencing an unknown input is caught
    /// inline as you type, instead of only silently blocking Create.
    private var templateProblem: String? {
        guard isTemplate else { return nil }
        let definitions = builtInputs
        if let problem = TemplateInputValidation.validateDefinitions(definitions) { return problem }
        let definedNames = Set(definitions.map(\.name))
        let titleTemplate = instanceTitleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !titleTemplate.isEmpty,
           let problem = TemplateStringRenderer.validate(titleTemplate, allowedNames: definedNames) {
            return problem
        }
        // The same placeholder check the store applies on save, run live so a mistyped
        // `{{input}}` reads as a typo next to the input list rather than as a rejected Save.
        // Built from the SAME lists `save()` writes, so the field this names is the field the
        // refusal names — numbering over the raw rows made this say "step 3" where the store said
        // "step 2", and quoting a raw row made it name a criterion the store called something else.
        return TemplateInputValidation.firstProblem(
            authoringTemplateWithTitle: title,
            description: description,
            activeStepTexts: builtActiveSteps.map(\.text),
            criteria: builtCriteria,
            requiredCapabilityTexts: builtCapabilityTexts,
            definedNames: definedNames
        )
    }

    /// The template input definitions this form would save. Shared with `save()` so the live
    /// warning and the refusal that actually blocks Save can never disagree about what is written.
    private var builtInputs: [TemplateInputDefinition] { Self.builtInputs(from: inputs) }

    private static func builtInputs(from rows: [InputRow]) -> [TemplateInputDefinition] {
        rows.compactMap { row -> TemplateInputDefinition? in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = row.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || !description.isEmpty else { return nil }
            return TemplateInputDefinition(name: name, description: description, required: row.required)
        }
    }

    /// The acceptance criteria this form would save. A row with neither a name nor a prompt is
    /// dropped, and an empty name falls back to the prompt — which is also the name the store
    /// quotes back in a placeholder refusal, so the live warning has to be built from exactly this
    /// list or it names a different criterion than the save does.
    private var builtCriteria: [AcceptanceCriterion] {
        criteria.compactMap { row -> AcceptanceCriterion? in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = row.validationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || !prompt.isEmpty else { return nil }
            let enumerator = row.inputEnumeratorPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return AcceptanceCriterion(
                id: row.id,
                name: name.isEmpty ? prompt : name,
                validationPrompt: prompt.isEmpty ? name : prompt,
                inputEnumeratorPrompt: enumerator.isEmpty ? nil : enumerator,
                waivable: row.waivable,
                origin: .user
            )
        }
    }

    /// The ACTIVE steps this form would save, in plan order. Empty rows are dropped HERE, exactly
    /// as they are on save, so the position a placeholder problem names is the position `setSteps`
    /// names.
    private var builtActiveSteps: [TaskStep] {
        steps.compactMap { $0.built() }
    }

    /// The required-capability texts this form would save, in order, empty rows dropped — shared
    /// with the live placeholder warning so both number the same items.
    private var builtCapabilityTexts: [String] {
        capabilities.map(\.trimmedText).filter { !$0.isEmpty }
    }

    private func save() {
        let inputDefinitions = builtInputs
        let capabilityTextsToSave = builtCapabilityTexts
        let criteriaToSave = builtCriteria
        // Tombstones go back on the end, matching the ordering convention `applyStepAction`'s
        // reorder/move use: active steps in plan order, then the removal record.
        let builtSteps = builtActiveSteps + preservedTombstones
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            localError = "Title must not be empty."
            return
        }
        guard !trimmedDescription.isEmpty else {
            localError = "Description must not be empty."
            return
        }
        Task {
            var saved: Bool
            switch mode {
            case .create:
                saved = await viewModel.createManualTask(
                    title: trimmedTitle,
                    description: trimmedDescription,
                    isTemplate: isTemplate,
                    templateInputDefinitions: inputDefinitions,
                    templateInstanceTitleTemplate: instanceTitleTemplate,
                    acceptanceCriteria: criteriaToSave,
                    steps: builtSteps,
                    requiresUserAcceptance: requiresUserAcceptance,
                    requiredCapabilityTexts: capabilityTextsToSave
                )
            case .edit(let task):
                // Written only when one of its fields changed: the definition is refused once the
                // task is running, and that refusal must not block a change it doesn't cover (a
                // capability added to a task that started while this sheet was open).
                let opened = Self.openedForm(of: task)
                let definitionChanged = trimmedTitle != opened.title
                    || trimmedDescription != opened.description
                    || isTemplate != opened.isTemplate
                    || inputDefinitions != opened.inputs
                    || instanceTitleTemplate.trimmingCharacters(in: .whitespacesAndNewlines) != opened.instanceTitleTemplate
                saved = true
                if definitionChanged {
                    saved = await viewModel.updateTaskDefinition(
                        id: task.id,
                        title: trimmedTitle,
                        description: trimmedDescription,
                        isTemplate: isTemplate,
                        templateInputDefinitions: inputDefinitions,
                        templateInstanceTitleTemplate: instanceTitleTemplate
                    )
                }
                if saved && canEditValidationContract {
                    // Only a gate the user actually changed is written: comparing against the value the
                    // sheet opened with means a gate Smith changed while the sheet was open is not
                    // silently reverted by a Save that never touched the checkbox.
                    let gateChange: Bool? = requiresUserAcceptance == task.requiresUserAcceptance ? nil : requiresUserAcceptance
                    // Like the definition above, each part is written only when it changed: the
                    // contract and steps are refused once the task is running, and an unchanged part
                    // must not block a change that is allowed (a capability edit).
                    if gateChange != nil || criteria != opened.criterionRows {
                        saved = await viewModel.editTaskAcceptanceContract(
                            id: task.id, criteria: criteriaToSave, requiresUserAcceptance: gateChange)
                    }
                    if saved && steps != opened.stepRows {
                        saved = await viewModel.setTaskSteps(id: task.id, steps: builtSteps)
                    }
                }
                let capabilityEdits = RequiredCapabilityEdit.edits(from: task.requiredCapabilities, to: capabilities.map(\.draft))
                if saved && capabilitiesLockReason == nil && !capabilityEdits.isEmpty {
                    saved = await viewModel.editTaskRequiredCapabilities(id: task.id, capabilityEdits)
                }
            }
            if saved {
                onDone()
            } else {
                // On failure the view model set `taskActionError`, but its alert is attached to the
                // sidebar BEHIND this modal sheet, so it never appears — Create/Save just looked dead.
                // Surface the actual reason in-sheet (where the title/description errors show), and
                // clear the view-model error so the hidden alert can't double-fire later.
                localError = viewModel.taskActionError
                    ?? "The task could not be saved. Check the fields and try again."
                viewModel.taskActionError = nil
            }
        }
    }
}

/// The editor's required-capabilities list. A row added while creating is part of the task as
/// written; one added to an existing task is recorded as a later addition by the user.
private struct TaskEditorCapabilitiesSection: View {
    @Binding var capabilities: [TaskEditorSheet.CapabilityRow]
    let lockReason: RequiredCapabilitiesLockReason?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaskEditorCapabilitiesHeader(isEditable: lockReason == nil,
                                         onAdd: { capabilities.append(TaskEditorSheet.CapabilityRow()) })
            Text(lockReason?.editorCaption ?? "What the worker must be able to do — abilities, not tool names. The security agent pays special attention to this list when it chooses the worker's tools.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($capabilities) { $row in
                CapabilityEditorRow(row: $row, onRemove: { capabilities.removeAll { $0.id == row.id } })
            }
            .disabled(lockReason != nil)
        }
    }
}

private struct TaskEditorCapabilitiesHeader: View {
    let isEditable: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack {
            Text("Required Capabilities").font(.headline)
            Spacer()
            Button(action: onAdd, label: {
                Label("Add Capability", systemImage: "plus.circle")
            })
            .buttonStyle(.plain)
            .disabled(!isEditable)
        }
    }
}

/// One editable required capability. A later addition says who added it and why, so editing the
/// wording never hides that the item was learned while the task ran.
private struct CapabilityEditorRow: View {
    @Binding var row: TaskEditorSheet.CapabilityRow
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField("e.g. Compile the Xcode project", text: $row.text)
                    .textFieldStyle(.roundedBorder)
                RemoveRowButton(title: "Remove capability", action: onRemove)
            }
            if let existing = row.existing, existing.origin == .addedLater {
                RequiredCapabilityProvenanceLabel(addedBy: existing.addedBy, addedAt: existing.addedAt, reason: existing.reason)
            }
        }
    }
}

extension RequiredCapabilitiesLockReason {
    /// Why the editor shows the list read-only.
    var editorCaption: String {
        switch self {
        case .completed:
            return "This task is completed, so its required capabilities are history. Create a successor task for follow-up work."
        case .validating:
            return "Locked while validators judge the result. Editable again once validation ends."
        case .notInActiveList:
            return "This task is archived or deleted. Restore it to edit its required capabilities."
        }
    }
}
