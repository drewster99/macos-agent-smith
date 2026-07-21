import SwiftUI
import AgentSmithKit

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

    struct CriterionRow: Identifiable {
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

    struct StepRow: Identifiable {
        let id: UUID
        var text: String

        init(id: UUID = UUID(), text: String = "") {
            self.id = id
            self.text = text
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
        case .edit(let task):
            _title = State(initialValue: task.title)
            _description = State(initialValue: task.description)
            _isTemplate = State(initialValue: task.isTemplate)
            _instanceTitleTemplate = State(initialValue: task.templateInstanceTitleTemplate ?? "")
            _inputs = State(initialValue: task.templateInputDefinitions.map {
                InputRow(name: $0.name, description: $0.description, required: $0.required)
            })
            _criteria = State(initialValue: task.acceptanceCriteria.map {
                CriterionRow(
                    id: $0.id,
                    name: $0.name,
                    validationPrompt: $0.validationPrompt,
                    inputEnumeratorPrompt: $0.inputEnumeratorPrompt ?? "",
                    waivable: $0.waivable
                )
            })
            _steps = State(initialValue: task.steps.filter(\.isActive).map { StepRow(id: $0.id, text: $0.text) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    definitionSection()
                    templateSection()
                    criteriaSection()
                    stepsSection()
                    if let localError {
                        Text(localError)
                            .font(.caption)
                            .foregroundStyle(AppColors.verdictError)
                    }
                }
                .padding(.trailing, 8)
            }
            footer()
        }
        .padding(20)
        .frame(width: 680, height: 720)
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
                    Button {
                        inputs.append(InputRow())
                    } label: {
                        Label("Add Input", systemImage: "plus.circle")
                    }
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
                        Button {
                            inputs.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func criteriaSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Acceptance").font(.headline)
                Spacer()
                Button {
                    criteria.append(CriterionRow())
                } label: {
                    Label("Add Criterion", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(!canEditValidationContract)
            }
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
                Button {
                    criteria.removeAll { $0.id == row.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
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
                Button {
                    steps.append(StepRow())
                } label: {
                    Label("Add Step", systemImage: "plus.circle")
                }
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
                    Button {
                        steps.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
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

    private var canEditValidationContract: Bool {
        switch mode {
        case .create:
            return true
        case .edit(let task):
            return task.status.isValidationContractEditable
        }
    }

    private func save() {
        let builtInputs = inputs.compactMap { row -> TemplateInputDefinition? in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = row.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || !description.isEmpty else { return nil }
            return TemplateInputDefinition(name: name, description: description, required: row.required)
        }
        let builtCriteria = criteria.compactMap { row -> AcceptanceCriterion? in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = row.validationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || !prompt.isEmpty else { return nil }
            return AcceptanceCriterion(
                id: row.id,
                name: name.isEmpty ? prompt : name,
                validationPrompt: prompt.isEmpty ? name : prompt,
                inputEnumeratorPrompt: row.inputEnumeratorPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : row.inputEnumeratorPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                waivable: row.waivable,
                origin: .user
            )
        }
        let builtSteps = steps.compactMap { row -> TaskStep? in
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TaskStep(id: row.id, text: text, origin: .user)
        }
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
                    templateInputDefinitions: builtInputs,
                    templateInstanceTitleTemplate: instanceTitleTemplate,
                    acceptanceCriteria: builtCriteria,
                    steps: builtSteps
                )
            case .edit(let task):
                saved = await viewModel.updateTaskDefinition(
                    id: task.id,
                    title: trimmedTitle,
                    description: trimmedDescription,
                    isTemplate: isTemplate,
                    templateInputDefinitions: builtInputs,
                    templateInstanceTitleTemplate: instanceTitleTemplate
                )
                if saved && canEditValidationContract {
                    let criteriaSaved = await viewModel.setTaskAcceptanceCriteria(id: task.id, criteria: builtCriteria)
                    let stepsSaved = await viewModel.setTaskSteps(id: task.id, steps: builtSteps)
                    saved = criteriaSaved && stepsSaved
                }
            }
            if saved {
                onDone()
            }
        }
    }
}
