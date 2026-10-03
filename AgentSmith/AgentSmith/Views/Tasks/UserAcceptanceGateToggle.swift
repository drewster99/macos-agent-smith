import SwiftUI
import AgentSmithKit

/// The per-task user sign-off gate (`AgentTask.requiresUserAcceptance`) as a labelled checkbox.
/// Shared by the task editor (a draft saved with the form) and Task Detail (a live store write) so
/// both describe the gate, and the reasons it can be locked, identically.
struct UserAcceptanceGateToggle: View {
    @Binding var requiresUserAcceptance: Bool
    /// Shown in place of the explanation, and disables the control, when the gate can't change now.
    let lockedReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Require my sign-off before completing", isOn: $requiresUserAcceptance)
                .toggleStyle(.checkbox)
                .disabled(lockedReason != nil)
            Text(lockedReason ?? "When every criterion passes, the task waits for you to accept it instead of completing automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why the gate can't be changed on `task` right now, or nil when it can — the same rules the
    /// store enforces (`TaskStore.editAcceptanceContract`), so a locked control never disagrees with
    /// a refusal.
    static func lockedReason(for task: AgentTask) -> String? {
        // An archived or recently-deleted task lives outside the store's writable sets, so every edit
        // would be refused with "Task not found".
        guard task.disposition == .active else {
            return "Restore this task to change its sign-off gate."
        }
        if task.isParkedForUserAcceptance {
            return "This task is waiting on your sign-off now — accept it or send it back from its row in the task list."
        }
        guard task.status.isValidationContractEditable else {
            return "Can't be changed while the task is \(task.status.displayName.lowercased()) — the same rule as its acceptance criteria."
        }
        return nil
    }
}
