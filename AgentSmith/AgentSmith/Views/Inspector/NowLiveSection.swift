import SwiftUI
import AgentSmithKit

/// The live "Now" view at the top of the inspector: the tasks happening right now, each
/// with its stage, its Brown's live micro-state, whether the Security Agent is reviewing
/// one of its calls, and its most recent tool activity.
///
/// Sources: recent tool calls are bucketed from the channel by `taskID` (request side only —
/// see `recompute`); the Brown state (`thinking` / `running <tool>` / `waiting on security`)
/// and the nested `Security · evaluating` row come from the per-instance telemetry (the M2
/// re-key), matched to a task via the Brown instance id in its `assigneeIDs`. Auto-approved
/// read-only evidence takes the no-LLM fast path, so it correctly shows no security wait.
/// Nothing is faked — a state that isn't currently signalled is simply omitted.
///
/// "Live" spans two different things and the distinction is load-bearing: a task that is
/// WORKING, and a task that is PARKED and needs attention (`isLive` vs `isParked`). A parked
/// task may have no worker at all — its Brown can be long gone — so it shows its stage chip
/// and nothing else. Its last tool calls are history, and because each row is stamped with a
/// `.relative` AGE, leaving them visible made a correctly-parked task look like a hung one:
/// the final call before the worker went away sits there counting upward.
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
                        .font(AppFonts.liveSectionHeader)
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

        // Only the REQUEST side of a call is one activity. Both `tool_request` and `tool_output`
        // carry a `tool` metadata key, so bucketing on that key alone listed every call twice —
        // once when issued, once when it returned. Four visible rows were really two calls, and
        // the ~5-second request→result gap between each pair read as four separate events.
        var toolsByTask: [UUID: [ToolActivity]] = [:]
        for message in viewModel.messages {
            guard let taskID = message.taskID,
                  message.messageKind == "tool_request",
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

        let next = live.map { task -> LiveTaskRow in
            let brownState = Self.brownState(for: task, processing: processing, tools: toolsByInstance)
            // A parked task with no live worker has no activity to show — only history. Rendering
            // it anyway is what made a correctly-parked task read as a hang: the rows are stamped
            // with `.relative` AGE, so the last call before the worker went away sits there
            // counting upward ("23 min") and looks like a tool that never returned. The stage
            // chip ("Awaiting Review") is the whole truth for these; stale rows only obscure it.
            let showsActivity = brownState != nil || !Self.isParked(task.status)
            return LiveTaskRow(
                id: task.id,
                title: task.title,
                status: task.status,
                brownState: brownState,
                securityEvaluating: Self.securityEvaluating(for: task, processing: processing),
                tools: showsActivity
                    ? Array((toolsByTask[task.id] ?? []).suffix(Self.maxToolRowsPerTask).reversed())
                    : []
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
            let brownRef = AgentInstanceRef(role: .brown, instanceID: id)
            if let counts = tools[brownRef], !counts.isEmpty {
                let names = counts.keys.sorted()
                if names.count == 1, let only = names.first { return "running \(only)" }
                return "running \(names.count) tools"
            }
            // Brown is blocked while the Security Agent reviews the call it just issued.
            if processing.contains(AgentInstanceRef(role: .securityAgent, instanceID: id)) {
                return "waiting on security"
            }
            if processing.contains(brownRef) { return "thinking" }
        }
        return nil
    }

    /// Whether the Security Agent is actively evaluating a call for this task's Brown.
    private static func securityEvaluating(for task: AgentTask, processing: Set<AgentInstanceRef>) -> Bool {
        task.assigneeIDs.contains { processing.contains(AgentInstanceRef(role: .securityAgent, instanceID: $0)) }
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

    /// Statuses where the task is waiting on someone else rather than progressing on its own.
    /// These belong in the Live section (they need attention) but must not imply activity: a
    /// parked task may have no worker at all, and the tool rows beneath it would be history.
    /// Kept separate from `isLive` so the "needs attention" and "is working" questions stay
    /// distinct — conflating them is what let a dead worker's last calls masquerade as live ones.
    static func isParked(_ status: AgentTask.Status) -> Bool {
        switch status {
        case .awaitingReview, .awaitingHelp, .interrupted:
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
        /// True while the Security Agent is actively evaluating a call for this task's Brown
        /// (the 4–6 s LLM review). Drives the nested "Security · evaluating" row and Brown's
        /// "waiting on security" state. Auto-approved read-only evidence never sets this —
        /// it takes the no-LLM fast path, so there's genuinely no wait to show.
        let securityEvaluating: Bool
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
                    .font(AppFonts.liveTaskTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(row.status.displayName)
                    .font(AppFonts.liveTaskStageChip)
                    .foregroundStyle(stageColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(stageColor.opacity(0.16), in: Capsule())
            }
            .padding(.horizontal, 12)

            if let brownState = row.brownState {
                HStack(spacing: 6) {
                    Text("Brown")
                        .font(AppFonts.liveAgentLabel)
                        .foregroundStyle(AppColors.color(for: .agent(.brown)))
                    Text(brownState)
                        .font(AppFonts.liveAgentState)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 12)
            }

            if row.securityEvaluating {
                HStack(spacing: 6) {
                    Text("Security")
                        .font(AppFonts.liveAgentLabel)
                        .foregroundStyle(AppColors.color(for: .agent(.securityAgent)))
                    Text("evaluating")
                        .font(AppFonts.liveAgentState)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
            }

            ForEach(row.tools) { tool in
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(AppFonts.liveToolName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(tool.timestamp, style: .relative)
                        .font(AppFonts.liveToolAge)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 28)
                .padding(.trailing, 12)
            }
        }
        .padding(.vertical, 5)
    }
}
