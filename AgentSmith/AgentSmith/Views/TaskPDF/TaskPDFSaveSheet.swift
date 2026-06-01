import SwiftUI

/// Lets the user pick which task elements to include before saving a task as a PDF.
/// Presented from the task-detail window's "Save as PDF…" action. The title and
/// completion date/time are always included, so they are not offered as toggles.
struct TaskPDFSaveSheet: View {
    @Binding var options: TaskPDFFieldOptions
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save as PDF")
                .font(.title2.bold())

            Text("Choose which elements to include. The task title and completion time are always included.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Start time", isOn: $options.startTime)
                Toggle("Elapsed time", isOn: $options.elapsedTime)
                Toggle("Tokens", isOn: $options.tokens)
                Toggle("Cost estimate", isOn: $options.cost)
                Toggle("Task description", isOn: $options.description)
                Toggle("Summary", isOn: $options.summary)
                Toggle("Result", isOn: $options.result)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save…", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
