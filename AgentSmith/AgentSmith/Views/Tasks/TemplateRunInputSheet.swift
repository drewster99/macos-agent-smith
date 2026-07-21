import SwiftUI
import AgentSmithKit

struct TemplateRunInputSheet: View {
    let task: AgentTask
    let onRun: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var values: [String: String]

    init(task: AgentTask, onRun: @escaping ([String: String]) -> Void, onCancel: @escaping () -> Void) {
        self.task = task
        self.onRun = onRun
        self.onCancel = onCancel
        let initialValues = Dictionary(
            uniqueKeysWithValues: task.templateInputDefinitions.map { ($0.name, "") }
        )
        _values = State(initialValue: initialValues)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run Template")
                    .font(.title3.bold())
                Text(task.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(task.templateInputDefinitions, id: \.name) { definition in
                    inputRow(definition)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run") {
                    onRun(resolvedValues)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hasMissingRequiredValues)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private func inputRow(_ definition: TemplateInputDefinition) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(definition.name)
                    .font(.headline)
                if definition.required {
                    Text("Required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !definition.description.isEmpty {
                Text(definition.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Value", text: binding(for: definition.name))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var resolvedValues: [String: String] {
        values.reduce(into: [:]) { result, pair in
            let trimmed = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result[pair.key] = trimmed
            }
        }
    }

    private var hasMissingRequiredValues: Bool {
        task.templateInputDefinitions.contains { definition in
            definition.required && (values[definition.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }
}

extension AgentTask {
    var shouldPromptForTemplateRunInputs: Bool {
        isTemplate && !templateInputDefinitions.isEmpty
    }
}
