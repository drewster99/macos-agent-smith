import SwiftUI
import AgentSmithKit

/// The live "Now" view at the top of the inspector: the tasks that are happening right now,
/// each with its current stage and its most recent tool activity.
///
/// Tool activity is bucketed straight from the channel by `taskID`, so it is accurate
/// per task without depending on the still-role-keyed per-agent telemetry. This is the
/// first visible slice of the "Now panel" (see ROADMAP: *Inspector "Now" panel + M2
/// telemetry re-key*). Per-instance security/validator nesting and live agent micro-state
/// arrive with the telemetry re-key; nothing shown here is faked in the meantime — states
/// that aren't yet available are simply omitted, not guessed.
struct NowLiveSection: View {
    let viewModel: AppViewModel

    @State private var rows: [LiveTaskRow] = []

    var body: some View {
        // Rendered only when something is actually live, so an idle session shows no
        // empty section. The `.onChange`/`.task` chain stays attached via the Group.
        Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Live")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(rows) { row in
                        LiveTaskRowView(row: row)
                    }

                    Divider()
                        .padding(.top, 6)
                }
            }
        }
        .task { recompute() }
        .onChange(of: taskSignature) { _, _ in recompute() }
        .onChange(of: viewModel.messages) { _, _ in recompute() }
        .onChange(of: viewModel.processingInstances) { _, _ in recompute() }
        .onChange(of: viewModel.toolExecutingByInstance) { _, _ in recompute() }
    }

    /// A cheap Equatable digest of the active tasks' identity + stage, so a status change
    /// (e.g. running → validating) triggers a recompute even when no new message arrived.
    private var taskSignature: [String] {
        viewModel.activeTaskList.map { "\($0.id.uuidString):\($0.status.rawValue)" }
    }

    private func recompute() {
        let live = viewModel.activeTaskList.filter { Self.isLive($0.status) }

        var toolsByTask: [UUID: [ToolActivity]] = [:]
        for message in viewModel.messages {
            guard let taskID = message.taskID,
                  case .string(let tool)? = message.metadata?["tool"] else { continue }
            toolsByTask[taskID, default: []].append(
                ToolActivity(id: message.id, name: tool, timestamp: message.timestamp)
            )
        }

        // Per-instance live state (the M2 re-key payoff): each task reads ITS OWN Brown's
        // thinking/tool state, matched by the Brown instance id in the task's assignees, so
        // two concurrent Browns no longer clobber one shared role-level indicator.
        let processing = viewModel.processingInstances
        let toolsByInstance = viewModel.toolExecutingByInstance

        let next = live.map { task in
            LiveTaskRow(
                id: task.id,
                title: task.title,
                status: task.status,
                brownState: Self.brownState(for: task, processing: processing, tools: toolsByInstance),
                tools: Array((toolsByTask[task.id] ?? []).suffix(Self.maxToolRowsPerTask).reversed())
            )
        }

        // Project rule: defer @State mutation out of .onChange / .task closures.
        DispatchQueue.main.async {
            if rows != next { rows = next }
        }
    }

    /// The live micro-state of the Brown assigned to `task`, read from the per-instance
    /// telemetry (thinking / running a tool). Nil when that Brown isn't currently active.
    private static func brownState(
        for task: AgentTask,
        processing: Set<AgentInstanceRef>,
        tools: [AgentInstanceRef: [String: Int]]
    ) -> String? {
        for id in task.assigneeIDs {
            let ref = AgentInstanceRef(role: .brown, instanceID: id)
            if let counts = tools[ref], !counts.isEmpty {
                let names = counts.keys.sorted()
                if names.count == 1, let only = names.first { return "running \(only)" }
                return "running \(names.count) tools"
            }
            if processing.contains(ref) { return "thinking" }
        }
        return nil
    }

    /// Most-recent tool calls shown per task before older ones fall off.
    private static let maxToolRowsPerTask = 4

    /// Statuses that represent work happening — or needing attention — right now.
    static func isLive(_ status: AgentTask.Status) -> Bool {
        switch status {
        case .starting, .running, .validating, .awaitingReview, .awaitingHelp, .interrupted:
            return true
        default:
            return false
        }
    }

    struct LiveTaskRow: Identifiable, Equatable {
        let id: UUID
        let title: String
        let status: AgentTask.Status
        /// This task's Brown's live micro-state, read from the per-instance telemetry (the
        /// M2 re-key) and matched by the Brown instance id in the task's assignees — so two
        /// concurrent Browns no longer overwrite one shared indicator. Nil when idle.
        let brownState: String?
        let tools: [ToolActivity]
    }

    struct ToolActivity: Identifiable, Equatable {
        let id: UUID
        let name: String
        let timestamp: Date
    }
}

/// One live task: its title + stage chip, with its recent tool activity indented beneath.
private struct LiveTaskRowView: View {
    let row: NowLiveSection.LiveTaskRow

    private var stageColor: Color { TaskStatusBadge.color(for: row.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(row.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(row.status.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stageColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(stageColor.opacity(0.16), in: Capsule())
            }
            .padding(.horizontal, 12)

            if let brownState = row.brownState {
                HStack(spacing: 6) {
                    Text("Brown")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.color(for: .agent(.brown)))
                    Text(brownState)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 12)
            }

            ForEach(row.tools) { tool in
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(tool.timestamp, style: .time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 28)
                .padding(.trailing, 12)
            }
        }
        .padding(.vertical, 5)
    }
}
