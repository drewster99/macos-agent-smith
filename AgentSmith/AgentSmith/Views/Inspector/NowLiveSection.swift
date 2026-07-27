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
/// Activity rows are age-bounded (`activityWindowSeconds`) and swept on a timer, because this
/// section means "now" literally. Each row renders a `.relative` age, so anything left in it
/// past its welcome counts upward and reads as a tool that never returned — which is exactly
/// how a correctly-parked task came to look like a hang. A task keeps its title and stage chip
/// for as long as its status is live; only the activity beneath it expires.
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
        // Activity rows age out on a clock, so they have to be re-evaluated on one. Every other
        // trigger here is change-driven, and in a quiet session (a task parked, or a worker
        // thinking for minutes) none of them fire — an aged-out row would sit on screen until
        // some unrelated change happened to force a recompute.
        .task {
            recompute()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.staleSweepIntervalSeconds))
                guard !Task.isCancelled else { return }
                recompute()
            }
        }
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
        //
        // Rows are also age-bounded. This section answers "what is happening now", and each row
        // renders a `.relative` AGE — so without a cutoff the last few calls of a task that has
        // gone quiet sit here indefinitely, counting upward, indistinguishable from a tool that
        // never returned. Work genuinely still in flight is reported by `brownState` (which is
        // read from live telemetry, not timestamps), so a long-running call keeps its "running
        // <tool>" line even after its request row ages out.
        // Walk newest-first and stop at the cutoff. `messages` is append-ordered, so everything
        // past the first too-old message is older still. That matters because this now runs on a
        // timer: the resident transcript is normally capped, but "restore full history" opts into
        // holding the entire session log, and rescanning all of it every tick to find the last
        // two minutes would be pure waste.
        let cutoff = Date().addingTimeInterval(-Self.activityWindowSeconds)
        var toolsByTask: [UUID: [ToolActivity]] = [:]
        for message in viewModel.messages.reversed() {
            guard message.timestamp >= cutoff else { break }
            guard let taskID = message.taskID,
                  message.kind == .toolRequest,
                  case .string(let tool)? = message.metadata?["tool"] else { continue }
            guard toolsByTask[taskID, default: []].count < Self.maxToolRowsPerTask else { continue }
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
                securityEvaluating: Self.securityEvaluating(for: task, processing: processing),
                // Already newest-first and already capped by the collecting loop above.
                tools: toolsByTask[task.id] ?? []
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

    /// How far back a tool call still counts as "now". Comfortably longer than a typical call
    /// (most return in seconds) and short enough that nothing on screen reads as stale. A call
    /// that outlives this is still represented — by `brownState`'s live "running <tool>" line,
    /// which comes from telemetry rather than a timestamp and therefore can't go stale.
    private static let activityWindowSeconds: TimeInterval = 120

    /// How often the rows are re-evaluated so aged-out activity actually disappears. Well under
    /// `activityWindowSeconds`, so a row is never visibly overdue by more than this.
    private static let staleSweepIntervalSeconds: TimeInterval = 10

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
