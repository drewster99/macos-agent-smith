import Foundation
import Observation
import SwiftLLMKit
import AgentSmithKit

/// The inspector's derived display state — every agent card's data and the Live section's rows —
/// computed HERE, in the model, and read by the views as plain stored values.
///
/// Why it is not computed in the views: the cards and the Live section used to keep their own
/// `@State` caches, rebuilt by a fan of `.onChange` watchers over a dozen view-model inputs. Every
/// SwiftUI "onChange(of:) action tried to update multiple times per frame" warning in the app came
/// from those watchers (identified site by site, 2026-09-25), SwiftUI SKIPS the action it warns
/// about, and a single input change was enough to trigger it. The skipped rebuild left a card up
/// to its 2 s heartbeat stale and the Live rows up to their 10 s sweep. See
/// `docs/audits/2026-09-25-onchange-per-frame/`.
///
/// So the views watch nothing. `rebuild()` reads its inputs inside `withObservationTracking`; the
/// first change to any of them schedules ONE rebuild on the next main-queue turn, which reads the
/// new values and re-arms the tracking. Each output is assigned only when it actually changed, so
/// a card re-renders only when its own data did.
///
/// Activated by the inspector when it first appears (`activate()`); a session that never shows an
/// inspector never pays for it.
@Observable
@MainActor
final class InspectorLiveState {
    /// Per-role card data, one observable holder per role, so a Brown change never re-renders the
    /// Smith card.
    let roleCards: [AgentRole: RoleCardState] = [
        .smith: RoleCardState(),
        .brown: RoleCardState(),
        .securityAgent: RoleCardState()
    ]
    private(set) var summarizerCard: SummarizerCardData?
    private(set) var liveRows: [LiveTaskRow] = []

    @ObservationIgnored private weak var viewModel: AppViewModel?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var rebuildScheduled = false
    @ObservationIgnored private var agingTask: Task<Void, Never>?
    /// Bucketing the transcript by role is the one expensive step, so it runs only when the
    /// transcript itself changed (`AppViewModel.messagesRevision`), not on every rebuild.
    @ObservationIgnored private var bucketedRevision: Int?
    @ObservationIgnored private var bucketed: [AgentRole: [ChannelMessage]] = [:]
    /// When each role's current busy spell began — the card's elapsed timers. Kept here, beside
    /// the flags they time, so no view has to watch the flags to seed them. Tracked (not
    /// `@ObservationIgnored`) and covers every role, not just the three with a card: the
    /// standalone `AgentInspectorWindow` (opened for Summarizer and Validator too) reads these
    /// directly instead of keeping its own `@State` + `.onChange` pair, which was the last
    /// leftover copy of the bug this file exists to close (see the type doc above).
    ///
    /// These are OUTPUTS, assigned outside the tracking like every other output (see `rebuild`).
    /// They used to be written inside `computeOutputs` — on every pass, since a dictionary
    /// subscript assignment fires `willSet` even when the value is unchanged — while also being
    /// read there as inputs. Any rebuild that ran with the previous rebuild's tracking still armed
    /// (the aging sweep does exactly that) then tripped that tracking with its own write, which
    /// scheduled the next rebuild, which tripped the next: a self-sustaining loop pinning the main
    /// thread at 100% (measured 2026-10-01). The rebuild now carries the previous values in the
    /// untracked `lastProcessingSince` / `lastToolsRunningSince` instead of reading these.
    private(set) var processingSince: [AgentRole: Date] = [:]
    private(set) var toolsRunningSince: [AgentRole: Date] = [:]
    /// Each role's callers sleeping on their provider, soonest resumption first. Covers every role
    /// for the same reason `processingSince` does: the standalone inspector window reads it.
    private(set) var providerWaitsByRole: [AgentRole: [ProviderWait]] = [:]
    @ObservationIgnored private var lastProcessingSince: [AgentRole: Date] = [:]
    @ObservationIgnored private var lastToolsRunningSince: [AgentRole: Date] = [:]

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    func card(for role: AgentRole) -> RoleCardState {
        guard let state = roleCards[role] else {
            preconditionFailure("No inspector card exists for \(role); cards are built for Smith, Brown and the Security Agent only")
        }
        return state
    }

    /// Starts deriving. Idempotent.
    func activate() {
        guard !isActive else { return }
        isActive = true
        // Deferred, not synchronous: this fires from `InspectorView`'s `.task`, in the same runloop
        // turn the pane appears, and a synchronous `rebuild()` lands every card and live row in one
        // burst during that layout. `scheduleRebuild` is the same one-tick deferral every later
        // rebuild goes through. (This was added 2026-10-01 as the fix for the inspector-open hang;
        // it wasn't — the hang was the native `.inspector` column's layout loop, see
        // `InspectorSidePane`. The deferral is kept because it is still the cheaper order.)
        scheduleRebuild()
        // The Live rows age out on a clock, and nothing observable changes when a row simply
        // gets older, so they need a timed rebuild as well.
        agingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.agingSweepIntervalSeconds))
                guard !Task.isCancelled, let self else { return }
                self.scheduleRebuild()
            }
        }
    }

    isolated deinit {
        agingTask?.cancel()
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildScheduled = false
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        // Inputs are read inside the tracking; the outputs are compared and assigned OUTSIDE it,
        // so the rebuild is never registered on its own writes (which would buy a redundant
        // second rebuild after every real one).
        let next = withObservationTracking({
            computeOutputs()
        }, onChange: { [weak self] in
            // Called as an input is ABOUT to change: rebuilding now would read the old value.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleRebuild() } }
        })
        guard let next else { return }
        for (role, data) in next.roleCards {
            let state = card(for: role)
            if state.data != data { state.data = data }
        }
        if summarizerCard != next.summarizerCard { summarizerCard = next.summarizerCard }
        if liveRows != next.liveRows { liveRows = next.liveRows }
        lastProcessingSince = next.processingSince
        lastToolsRunningSince = next.toolsRunningSince
        if processingSince != next.processingSince { processingSince = next.processingSince }
        if toolsRunningSince != next.toolsRunningSince { toolsRunningSince = next.toolsRunningSince }
        if providerWaitsByRole != next.providerWaitsByRole { providerWaitsByRole = next.providerWaitsByRole }
    }

    private struct Outputs {
        let roleCards: [AgentRole: AgentRoleData]
        let summarizerCard: SummarizerCardData
        let liveRows: [LiveTaskRow]
        let processingSince: [AgentRole: Date]
        let toolsRunningSince: [AgentRole: Date]
        let providerWaitsByRole: [AgentRole: [ProviderWait]]
    }

    /// Everything the views show, from the current inputs. Nil once the view model is gone.
    private func computeOutputs() -> Outputs? {
        guard let viewModel else { return nil }
        let now = Date()
        if bucketedRevision != viewModel.messagesRevision {
            bucketed = Self.bucketMessagesByRole(viewModel.messages)
            bucketedRevision = viewModel.messagesRevision
        }
        // Every role, not just the three with a card: Summarizer and Validator are still valid
        // `AgentInspectorWindow` targets. A spell keeps its start date until it ends.
        var processing: [AgentRole: Date] = [:]
        var toolsRunning: [AgentRole: Date] = [:]
        for role in AgentRole.allCases {
            if Self.isProcessing(role, viewModel: viewModel) {
                processing[role] = lastProcessingSince[role] ?? now
            }
            if !Self.executingToolNames(viewModel.toolExecutingByRole[role]).isEmpty {
                toolsRunning[role] = lastToolsRunningSince[role] ?? now
            }
        }
        // Already soonest-first from the board; grouping keeps that order within each role.
        let waitsByRole = Dictionary(grouping: viewModel.providerWaits, by: \.holder.role)
        var cards: [AgentRole: AgentRoleData] = [:]
        for role in roleCards.keys {
            cards[role] = roleCardData(for: role, viewModel: viewModel,
                                       processingSince: processing[role], toolsRunningSince: toolsRunning[role],
                                       providerWaits: waitsByRole[role] ?? [])
        }
        return Outputs(
            roleCards: cards,
            summarizerCard: summarizerCardData(viewModel: viewModel, providerWaits: waitsByRole[.summarizer] ?? []),
            liveRows: Self.liveRows(viewModel: viewModel, now: now),
            processingSince: processing,
            toolsRunningSince: toolsRunning,
            providerWaitsByRole: waitsByRole
        )
    }

    /// The Security Agent's busy state comes from its own evaluator registry; every other role's
    /// from the processing set.
    private static func isProcessing(_ role: AgentRole, viewModel: AppViewModel) -> Bool {
        role == .securityAgent ? viewModel.isSecurityAgentBusy : viewModel.processingRoles.contains(role)
    }

    // MARK: - Role cards

    private func roleCardData(for role: AgentRole, viewModel: AppViewModel,
                              processingSince: Date?, toolsRunningSince: Date?,
                              providerWaits: [ProviderWait]) -> AgentRoleData {
        let store = viewModel.inspectorStore
        let roleMessages = bucketed[role] ?? []
        let isProcessing = Self.isProcessing(role, viewModel: viewModel)
        let executingTools = Self.executingToolNames(viewModel.toolExecutingByRole[role])
        return AgentRoleData(
            role: role,
            roleMessages: roleMessages,
            contextMessages: store.contextMessages(for: role),
            callLog: store.callLogsByRole[role],
            pollInterval: viewModel.agentPollIntervals[role] ?? 5,
            maxToolCalls: viewModel.agentMaxToolCalls[role] ?? 100,
            currentSystemPrompt: store.systemPrompt(for: role),
            hasActivity: !roleMessages.isEmpty || viewModel.hasAgentActivity(role),
            availableTools: viewModel.agentToolNames[role] ?? [],
            evaluationRecords: role == .securityAgent ? store.evaluationRecords : [],
            evaluationLifetimeCount: role == .securityAgent ? store.evaluationLifetimeCount : 0,
            sessionCost: viewModel.sessionCost(for: role),
            isProcessing: isProcessing,
            processingSince: processingSince,
            executingTools: executingTools,
            toolsRunningSince: toolsRunningSince,
            providerWaits: providerWaits,
            modelConfig: viewModel.resolvedAgentConfigs[role]
        )
    }

    private func summarizerCardData(viewModel: AppViewModel, providerWaits: [ProviderWait]) -> SummarizerCardData {
        SummarizerCardData(
            currentSystemPrompt: viewModel.inspectorStore.systemPrompt(for: .summarizer),
            pollInterval: viewModel.agentPollIntervals[.summarizer] ?? 5,
            maxToolCalls: viewModel.agentMaxToolCalls[.summarizer] ?? 100,
            isProcessing: viewModel.processingRoles.contains(.summarizer),
            executingTools: Self.executingToolNames(viewModel.toolExecutingByRole[.summarizer]),
            providerWaits: providerWaits,
            messages: bucketed[.summarizer] ?? [],
            unseenErrors: Array((bucketed[.summarizer] ?? [])
                .filter { $0.severity >= .error && $0.timestamp > viewModel.summarizerErrorsSeenThrough }
                .reversed())
        )
    }

    /// Buckets channel messages by the agent role they belong to, in one pass.
    /// One deliberate deviation from "sender == role": role-attributed SYSTEM diagnostics are
    /// INCLUDED (metadata `agentRole`, e.g. "Security Agent error (3/5): failed to parse security
    /// response") — these are exactly the errors/warnings a user opens the agent card to find, and
    /// they previously never surfaced in the inspector at all.
    static func bucketMessagesByRole(_ messages: [ChannelMessage]) -> [AgentRole: [ChannelMessage]] {
        var buckets: [AgentRole: [ChannelMessage]] = [:]
        for message in messages {
            if case .agent(let role) = message.sender {
                buckets[role, default: []].append(message)
            } else if case .system = message.sender, let role = message.attributedRole {
                buckets[role, default: []].append(message)
            }
        }
        return buckets
    }

    /// Flattens the `[toolName: count]` multiset into an ordered, repeated-name list so
    /// the card's status badge can show "Working — run_applescript" for a single call,
    /// "Working — 2 tools" for a parallel batch.
    static func executingToolNames(_ counts: [String: Int]?) -> [String] {
        guard let counts else { return [] }
        var out: [String] = []
        for name in counts.keys.sorted() {
            for _ in 0..<(counts[name] ?? 0) { out.append(name) }
        }
        return out
    }

    // MARK: - Live rows

    private static func liveRows(viewModel: AppViewModel, now: Date) -> [LiveTaskRow] {
        let live = viewModel.activeTaskList.filter { isLive($0.status) }
        // The one registry `SecurityEvaluator` writes. Read ONCE per rebuild so the tally, the
        // per-worker blocked state, and every tool row describe the same instant.
        let security = viewModel.shared.liveActivitySnapshot

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
        let cutoff = now.addingTimeInterval(-activityWindowSeconds)
        // Keyed by (agent, call id), NOT call id alone. A tool call id is whatever the provider
        // sent — some OpenAI-compatible servers emit per-response index ids like `call_0` — so with
        // two workers running, a bare id let one agent's row pick up another's verdict and output.
        // The registry was hardened against exactly this; its consumer has to match.
        var reviewByRequest: [CallKey: ChannelMessage] = [:]
        var outputByRequest: [CallKey: ChannelMessage] = [:]
        var requests: [(message: ChannelMessage, taskID: UUID, tool: String, key: CallKey)] = []
        scan: for message in viewModel.messages.reversed() {
            guard case .string(let requestID)? = message.metadata?["requestID"],
                  let agentInstanceID = agentInstanceID(of: message) else { continue }
            let key = CallKey(agentInstanceID: agentInstanceID, callID: requestID)
            // A security verdict carries NO `messageKind`; it is identified by its typed
            // `securityDisposition`, exactly as the transcript's `isSuppressibleFollowUp` does.
            // Still a typed discriminator — just a different one.
            if message.metadata?["securityDisposition"] != nil {
                if reviewByRequest[key] == nil { reviewByRequest[key] = message }
                continue
            }
            switch message.kind {
            case .toolOutput:
                if outputByRequest[key] == nil { outputByRequest[key] = message }
            case .toolRequest:
                guard message.timestamp >= cutoff else { break scan }
                guard let taskID = message.taskID,
                      let tool = message.toolName else { continue }
                requests.append((message, taskID, tool, key))
            default:
                continue
            }
        }

        var toolsByTask: [UUID: [LiveToolActivity]] = [:]
        for request in requests {
            guard toolsByTask[request.taskID, default: []].count < maxToolRowsPerTask else { continue }
            toolsByTask[request.taskID, default: []].append(
                activity(
                    request: request.message,
                    name: request.tool,
                    review: reviewByRequest[request.key],
                    output: outputByRequest[request.key],
                    key: request.key,
                    security: security
                )
            )
        }

        // Per-instance live state (the M2 re-key payoff): each task reads ITS OWN Brown's
        // thinking/tool state, matched by the Brown instance id in the task's assignees, so
        // two concurrent Browns no longer clobber one shared role-level indicator.
        let processing = viewModel.processingInstances
        let toolsByInstance = viewModel.toolExecutingByInstance

        return live.map { task in
            LiveTaskRow(
                id: task.id,
                title: task.title,
                status: task.status,
                brownState: brownState(for: task, processing: processing, tools: toolsByInstance,
                                       security: security, providerWaits: viewModel.providerWaits),
                // Already newest-first and already capped by the collecting loop above.
                tools: toolsByTask[task.id] ?? []
            )
        }
    }

    /// Assembles one call's state from its request, its Security Agent verdict, and its output.
    /// Every branch is driven by which of those three messages EXIST and by the verdict's typed
    /// `securityDisposition` — never by their prose.
    private static func activity(
        request: ChannelMessage,
        name: String,
        review: ChannelMessage?,
        output: ChannelMessage?,
        key: CallKey,
        security: LiveActivityTracker.Snapshot
    ) -> LiveToolActivity {
        let disposition: String? = {
            if case .string(let value)? = review?.metadata?["securityDisposition"] { return value }
            return nil
        }()
        let phase: LiveToolActivity.SecurityPhase
        switch disposition {
        case "approved": phase = .approved
        case "autoApproved": phase = .autoApproved
        case "warning": phase = .warned
        case "denied", "abort": phase = .denied
        // Blocked, and NOT by a verdict. These must render as blocked — falling into the default
        // below would paint a green check on a call that never ran, because that branch reads
        // "a row exists" as "it got past the gate". It does not: `reviewDisabled` has been
        // rendering that way since it shipped, and `unavailable`/`cancelled` would have joined it.
        case "unavailable", "cancelled": phase = .denied
        case "reviewDisabled": phase = .autoApproved
        // No verdict on the wire yet. "Under review" is ASKED, not inferred: the registry
        // `SecurityEvaluator` writes says whether this exact call is in front of the LLM right
        // now. Inferring it from a missing verdict was also true before evaluation started and
        // during any delivery gap, so a call could show "Security" while nothing was looking at
        // it. An UNRECOGNISED disposition is deliberately NOT treated as allowed: a value this
        // build has not heard of is most likely a newer build's block, and painting it green is
        // the one wrong answer that hides a call which never ran. Blocked-looking is the safe
        // reading, and `SecurityDisposition.channelTag` is the closed set it comes from.
        default:
            if review != nil {
                phase = .denied
            } else {
                phase = security.isEvaluating(callID: key.callID, agentInstanceID: key.agentInstanceID)
                    ? .evaluating
                    : .notYetReviewed
            }
        }

        let run: LiveToolActivity.RunPhase
        if phase == .denied || phase == .evaluating || phase == .notYetReviewed {
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

        return LiveToolActivity(
            id: request.id,
            name: name,
            requestedAt: request.timestamp,
            security: phase,
            run: run
        )
    }

    /// The live micro-state of the Brown assigned to `task`, read from the per-instance
    /// telemetry (thinking / running a tool). Nil when that Brown isn't currently active.
    private static func brownState(
        for task: AgentTask,
        processing: Set<AgentInstanceRef>,
        tools: [AgentInstanceRef: [String: Int]],
        security: LiveActivityTracker.Snapshot,
        providerWaits: [ProviderWait]
    ) -> String? {
        for id in task.assigneeIDs {
            // A wait on a provider outranks everything below: while it lasts the worker is neither
            // thinking nor being reviewed, it is waiting out a limit — possibly for days.
            if let own = providerWaits.first(where: { $0.holder.agentID == id }) {
                return "waiting for \(own.modelID ?? "its model") — \(own.reason.displayDescription), until \(own.resumeClockDescription)"
            }
            if let review = providerWaits.first(where: { $0.holder.purpose.heldAgentID == id }) {
                return "waiting on security — its model \(review.reason.displayDescription), until \(review.resumeClockDescription)"
            }
            let brownRef = AgentInstanceRef(role: .brown, instanceID: id)
            if let counts = tools[brownRef], !counts.isEmpty {
                let names = counts.keys.sorted()
                if names.count == 1, let only = names.first { return "running \(only)" }
                return "running \(names.count) tools"
            }
            // Brown is blocked while the Security Agent reviews a call it issued. Derived from the
            // one registry `SecurityEvaluator` writes, so this can never contradict the Agents
            // tally or the tool row beneath it — all three read the same entries.
            if security.isAwaitingSecurity(agentInstanceID: id) {
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

    /// How often the Live rows are rebuilt so aged-out activity actually disappears. Well under
    /// `activityWindowSeconds`, so a row is never visibly overdue by more than this.
    private static let agingSweepIntervalSeconds: TimeInterval = 10

    /// Statuses that represent work happening — or needing attention — right now.
    static func isLive(_ status: AgentTask.Status) -> Bool {
        switch status {
        case .starting, .running, .validating, .awaitingReview, .awaitingHelp, .interrupted:
            return true
        default:
            return false
        }
    }

    /// The agent a tool-lifecycle message belongs to. Every producer stamps it: `AgentActor` on
    /// requests, verdicts and outputs; `TaskValidationCoordinator` on the validator's requests.
    /// A message without one cannot be placed and is skipped rather than guessed at.
    static func agentInstanceID(of message: ChannelMessage) -> UUID? {
        guard case .string(let raw)? = message.metadata?["agentID"] else { return nil }
        return UUID(uuidString: raw)
    }

    /// Identifies one tool call. The agent is part of the key because a call id is provider data
    /// and is not unique across agents — the same reason `LiveActivityTracker` keys its registry
    /// this way, and the two must agree or a row reads another agent's verdict.
    private struct CallKey: Hashable {
        let agentInstanceID: UUID
        let callID: String
    }
}

/// One role card's data, in its own observable holder so each card observes only its own role.
@Observable
@MainActor
final class RoleCardState {
    /// Nil until the first rebuild.
    fileprivate(set) var data: AgentRoleData?
}

/// Pre-computed data for a single agent role. Equatable so an unchanged rebuild assigns nothing and
/// the card's body is not re-evaluated.
struct AgentRoleData: Equatable {
    let role: AgentRole
    let roleMessages: [ChannelMessage]
    let contextMessages: [LLMMessage]
    let callLog: InspectorCallLog?
    let pollInterval: TimeInterval
    let maxToolCalls: Int
    let currentSystemPrompt: String
    let hasActivity: Bool
    let availableTools: [String]
    let evaluationRecords: [EvaluationRecord]
    let evaluationLifetimeCount: Int
    let sessionCost: Double
    let isProcessing: Bool
    /// When the current busy spell began; nil while idle.
    let processingSince: Date?
    let executingTools: [String]
    /// When tools started running (continuously); nil while none is running.
    let toolsRunningSince: Date?
    /// This role's callers sleeping on their provider, soonest resumption first.
    let providerWaits: [ProviderWait]
    let modelConfig: ModelConfiguration?
}

/// Pre-computed data for the summarizer card.
struct SummarizerCardData: Equatable {
    let currentSystemPrompt: String
    let pollInterval: TimeInterval
    let maxToolCalls: Int
    let isProcessing: Bool
    let executingTools: [String]
    /// The summarizer's calls sleeping on their provider, soonest resumption first.
    let providerWaits: [ProviderWait]
    let messages: [ChannelMessage]
    /// Errors the Summarizer posted since the user last opened its inspector, newest first. The
    /// card flags them: a failed summary or memory merge otherwise scrolled away in the transcript.
    let unseenErrors: [ChannelMessage]
}

/// One live task: its title + stage, its Brown's micro-state, and its recent tool calls.
struct LiveTaskRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let status: AgentTask.Status
    /// This task's Brown's live micro-state, read from the per-instance telemetry (the
    /// M2 re-key) and matched by the Brown instance id in the task's assignees — so two
    /// concurrent Browns no longer overwrite one shared indicator. Nil when idle.
    let brownState: String?
    let tools: [LiveToolActivity]
}

/// One tool call's live story: who is looking at it, and how long it actually RAN.
struct LiveToolActivity: Identifiable, Equatable {
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
        /// The Security Agent's LLM is looking at this call right now.
        case evaluating
        /// No verdict yet, and nothing is evaluating it — the moment between a call being
        /// issued and review starting, or an auto-approval whose verdict hasn't landed. Shown
        /// as nothing rather than as a security wait that isn't happening.
        case notYetReviewed
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
