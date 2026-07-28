import SwiftUI
import AgentSmithKit

/// The live "Now" view at the top of the inspector: the tasks happening right now, each
/// with its stage, its Brown's live micro-state, and its most recent tool calls — each showing
/// who is looking at it and how long it actually ran.
///
/// Sources: the Brown state (`thinking` / `running <tool>` / `waiting on security`) comes from
/// per-instance telemetry (the M2 re-key), matched to a task via the Brown instance id in its
/// `assigneeIDs`. Each tool row is assembled from the CHANNEL, joining a call's request, its
/// Security Agent verdict, and its output on the `requestID` all three carry — the same join the
/// transcript uses. Nothing is faked; a state that isn't on the wire is simply omitted.
///
/// The per-call security state replaced a single `Security · evaluating` line under Brown. That
/// line could not say WHICH call of a batch was under review, and it contradicted the Agents
/// tally beside it: the tally counts only real LLM-backed evaluations, while the line lit up for
/// auto-approved calls too, so "Brown waiting on security" could sit directly above "0 Security".
///
/// Activity rows are age-bounded (`activityWindowSeconds`) on their REQUEST time and swept on a
/// timer, because this section means "now" literally. What a row DISPLAYS is the tool's own run
/// duration, never that age — showing the age made a call that had long since returned read as
/// one that never did. A task keeps its title and stage chip for as long as its status is live;
/// only the activity beneath it expires.
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

        // One ROW per call, built by joining the three messages a call produces on their shared
        // `requestID`: the request, the Security Agent's verdict, and the output. Bucketing on the
        // `tool` metadata key alone (which request AND output both carry) listed every call twice.
        //
        // Only the REQUESTS are age-bounded, and only they end the walk: `messages` is
        // append-ordered, so once a request predates the window every earlier request does too.
        // Verdicts and outputs are collected without a cutoff — a call issued just inside the
        // window returns just outside it, and dropping its output would leave a finished call
        // rendering forever as "under review".
        //
        // Walking newest-first also means the FIRST verdict/output seen for a requestID is the
        // newest, which is the one that counts; a repeated id keeps its latest state.
        let cutoff = Date().addingTimeInterval(-Self.activityWindowSeconds)
        var reviewByRequest: [String: ChannelMessage] = [:]
        var outputByRequest: [String: ChannelMessage] = [:]
        var requests: [(message: ChannelMessage, taskID: UUID, tool: String, requestID: String)] = []
        scan: for message in viewModel.messages.reversed() {
            guard case .string(let requestID)? = message.metadata?["requestID"] else { continue }
            // A security verdict carries NO `messageKind`; it is identified by its typed
            // `securityDisposition`, exactly as the transcript's `isSuppressibleFollowUp` does.
            // Still a typed discriminator — just a different one.
            if message.metadata?["securityDisposition"] != nil {
                if reviewByRequest[requestID] == nil { reviewByRequest[requestID] = message }
                continue
            }
            switch message.kind {
            case .toolOutput:
                if outputByRequest[requestID] == nil { outputByRequest[requestID] = message }
            case .toolRequest:
                guard message.timestamp >= cutoff else { break scan }
                guard let taskID = message.taskID,
                      case .string(let tool)? = message.metadata?["tool"] else { continue }
                requests.append((message, taskID, tool, requestID))
            default:
                continue
            }
        }

        var toolsByTask: [UUID: [ToolActivity]] = [:]
        for request in requests {
            guard toolsByTask[request.taskID, default: []].count < Self.maxToolRowsPerTask else { continue }
            toolsByTask[request.taskID, default: []].append(
                Self.activity(
                    request: request.message,
                    name: request.tool,
                    review: reviewByRequest[request.requestID],
                    output: outputByRequest[request.requestID]
                )
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
                // Already newest-first and already capped by the collecting loop above.
                tools: toolsByTask[task.id] ?? []
            )
        }

        // Project rule: defer @State mutation out of .onChange / .task closures.
        DispatchQueue.main.async {
            if rows != next { rows = next }
        }
    }

    /// Assembles one call's state from its request, its Security Agent verdict, and its output.
    /// Every branch is driven by which of those three messages EXIST and by the verdict's typed
    /// `securityDisposition` — never by their prose.
    private static func activity(
        request: ChannelMessage,
        name: String,
        review: ChannelMessage?,
        output: ChannelMessage?
    ) -> ToolActivity {
        let disposition: String? = {
            if case .string(let value)? = review?.metadata?["securityDisposition"] { return value }
            return nil
        }()
        let security: ToolActivity.SecurityPhase
        switch disposition {
        case "approved": security = .approved
        case "autoApproved": security = .autoApproved
        case "warning": security = .warned
        case "denied": security = .denied
        // No verdict on the wire yet: still in front of the Security Agent. A verdict carrying an
        // unrecognised disposition is treated as reviewed-and-allowed rather than guessed at — it
        // got past the gate, which is the only thing this row claims.
        default: security = review == nil ? .evaluating : .approved
        }

        let run: ToolActivity.RunPhase
        if security == .denied || security == .evaluating {
            run = .notStarted
        } else if let output {
            run = .finished(runMs: {
                if case .int(let ms)? = output.metadata?["executionMs"] { return ms }
                return nil
            }())
        } else {
            // Executing. The verdict is posted immediately before the tool is invoked, so its
            // timestamp is the closest start-of-execution marker the transcript carries.
            run = .running(since: review?.timestamp ?? request.timestamp)
        }

        return ToolActivity(
            id: request.id,
            name: name,
            requestedAt: request.timestamp,
            security: security,
            run: run
        )
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
        let tools: [ToolActivity]
    }

    /// One tool call's live story: who is looking at it, and how long it actually RAN.
    struct ToolActivity: Identifiable, Equatable {
        let id: UUID
        let name: String
        /// When the request was posted. NOT displayed — it is the row's AGE, which is what this
        /// used to show and what made a finished call read as a tool that never returned. Kept
        /// only to age the row out of the "now" window.
        let requestedAt: Date
        let security: SecurityPhase
        let run: RunPhase

        /// What the Security Agent has decided about this call, so far.
        enum SecurityPhase: Equatable {
            /// No verdict on the wire yet — the call is sitting in review.
            case evaluating
            /// Reviewed by the Security Agent's LLM and allowed.
            case approved
            /// Pre-cleared without an LLM round-trip (the auto-approve table, or a WARN retry).
            case autoApproved
            /// Allowed, with a caveat.
            case warned
            /// Refused. The tool never ran, so there is no duration to show.
            case denied
        }

        /// How far the tool itself has got. `.notStarted` covers both "still in review" and
        /// "denied" — in neither case has the tool run, and a denied call never will.
        enum RunPhase: Equatable {
            case notStarted
            /// Approved and executing, counting from the verdict's timestamp.
            case running(since: Date)
            /// Finished, with the duration `runToolWithTimeout` actually measured. Nil when the
            /// producing path published none — rendered as no duration, never a fabricated one.
            case finished(runMs: Int?)
        }
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

            ForEach(row.tools) { tool in
                LiveToolRowView(tool: tool)
            }
        }
        .padding(.vertical, 5)
    }
}

/// One tool call: its name, then whatever is true of it right now — under review, running, or
/// finished with the time it actually took and how Security ruled on it.
private struct LiveToolRowView: View {
    let tool: NowLiveSection.ToolActivity

    var body: some View {
        HStack(spacing: 6) {
            Text(tool.name)
                .font(AppFonts.liveToolName)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            LiveToolStatusView(tool: tool)
        }
        .padding(.leading, 28)
        .padding(.trailing, 12)
    }
}

/// The trailing half of a live tool row: either the Security Agent holding the call, or the run
/// duration plus the verdict it was let through on.
private struct LiveToolStatusView: View {
    let tool: NowLiveSection.ToolActivity

    var body: some View {
        switch tool.security {
        case .evaluating:
            // The one state that names an agent: this call is parked in front of the Security
            // Agent and nothing else is happening to it.
            Text("Security")
                .font(AppFonts.liveAgentLabel)
                .foregroundStyle(AppColors.color(for: .agent(.securityAgent)))
        case .denied:
            // No duration: a denied call never ran, so any number here would be a lie.
            Image(systemName: "xmark.circle.fill")
                .font(AppFonts.liveToolVerdictIcon)
                .foregroundStyle(AppColors.securityDenied)
        case .approved, .autoApproved, .warned:
            HStack(spacing: 5) {
                LiveToolDurationView(run: tool.run)
                Image(systemName: verdictSymbol)
                    .font(AppFonts.liveToolVerdictIcon)
                    .foregroundStyle(verdictColor)
            }
        }
    }

    private var verdictSymbol: String {
        switch tool.security {
        case .autoApproved: return "bolt.circle.fill"
        case .warned: return "exclamationmark.triangle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    private var verdictColor: Color {
        switch tool.security {
        case .warned: return AppColors.securityWarning
        case .autoApproved: return AppColors.securityAutoApproved
        default: return AppColors.securityApproved
        }
    }
}

/// Time the TOOL spent running — never the age of the row, never the review wait. A call still
/// executing counts up from its verdict; a finished one shows what was measured.
private struct LiveToolDurationView: View {
    let run: NowLiveSection.ToolActivity.RunPhase

    var body: some View {
        switch run {
        case .notStarted:
            EmptyView()
        case .running(let since):
            Text(since, style: .timer)
                .font(AppFonts.liveToolAge)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        case .finished(let runMs):
            if let runMs {
                Text(Self.formatted(runMs))
                    .font(AppFonts.liveToolAge)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// Sub-second calls read in milliseconds, longer ones in seconds: "1483 ms" is harder to
    /// compare at a glance than "1.5s" when scanning a column of them.
    static func formatted(_ runMs: Int) -> String {
        runMs < 1000 ? "\(runMs) ms" : String(format: "%.1fs", Double(runMs) / 1000)
    }
}
