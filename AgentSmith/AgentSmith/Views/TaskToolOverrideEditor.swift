import SwiftUI
import AgentSmithKit

/// Per-task tool override editor shown in a task's detail window. Lets the user force individual
/// tools on/off for this task, overriding the security agent's automatic scoping verdict. "Auto"
/// clears the override (defer to scoping + global policy). Overrides persist and survive any
/// re-evaluation. Forced lifecycle tools are always available and not listed.
struct TaskToolOverrideEditor: View {
    let task: AgentTask
    @Bindable var viewModel: AppViewModel
    @State private var expanded = false

    private static let forcedLifecycle: Set<String> = [
        "task_acknowledged", "task_update", "task_complete", "request_help", "reply_to_user"
    ]

    /// Built-in worker tools, plus any tools that were scoped or already overridden for this task
    /// (which is how MCP tools enter the list). Lifecycle tools excluded.
    private var tools: [String] {
        var set = Set(BrownBehavior.toolNames)
        set.formUnion(task.approvedTools ?? [])
        if let overrides = task.userToolOverrides { set.formUnion(overrides.keys) }
        set.subtract(Self.forcedLifecycle)
        return set.sorted()
    }

    private var approved: Set<String> { Set(task.approvedTools ?? []) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tools, id: \.self) { row($0) }
                Text("“Auto” follows the security agent. “On”/“Off” are your overrides — they persist and won't be undone by re-evaluation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.top, 4)
        } label: {
            // Count only tools that actually appear as rows. Forced lifecycle tools are approved
            // by scoping but deliberately not listed (see `tools`), so counting the raw
            // `approvedTools` made the header disagree with the visible list (e.g. "5 approved"
            // while only 2 rows show a checkmark).
            let n = approved.subtracting(Self.forcedLifecycle).count
            let o = task.userToolOverrides?.count ?? 0
            Text(o > 0 ? "\(n) approved · \(o) override\(o == 1 ? "" : "s")" : "\(n) approved")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ tool: String) -> some View {
        let override = task.userToolOverrides?[tool]
        let effective = override ?? approved.contains(tool)
        return HStack(spacing: 8) {
            Image(systemName: effective ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(effective ? Color.green : Color.secondary)
            Text(tool)
                .font(.body.monospaced())
                .fontWeight(override != nil ? .bold : .regular)
            Spacer(minLength: 12)
            Picker("", selection: stateBinding(tool)) {
                Text("Auto").tag(OverrideState.auto)
                Text("On").tag(OverrideState.on)
                Text("Off").tag(OverrideState.off)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
    }

    private enum OverrideState { case auto, on, off }

    private func stateBinding(_ tool: String) -> Binding<OverrideState> {
        Binding(
            get: {
                guard let o = task.userToolOverrides?[tool] else { return .auto }
                return o ? .on : .off
            },
            set: { newState in
                let enabled: Bool?
                switch newState {
                case .auto: enabled = nil
                case .on: enabled = true
                case .off: enabled = false
                }
                viewModel.setTaskToolOverride(taskID: task.id, tool: tool, enabled: enabled)
            }
        )
    }
}
