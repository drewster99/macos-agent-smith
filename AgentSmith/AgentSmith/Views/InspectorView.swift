import AVFoundation
import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Inspector panel showing per-agent status: activity, context, tools, and direct messaging.
///
/// **Performance design.** The inspector watches ~9 high-frequency view-model dependencies.
/// To avoid the trap where every body evaluation re-computes ~27 derived values:
///
/// 1. The parent owns three per-role `@State` message buckets, populated once per
///    `viewModel.messages` tick. Each child card receives only its own slice as a direct
///    `@State` value.
/// 2. Each `RoleAgentCard` owns its own cached `AgentRoleData?` and its own narrow
///    `.onChange` watchers (one per source dictionary, narrowed to that role's key).
///    The card body reads only the cached `@State` — never `viewModel.inspectorStore.*`
///    or `viewModel.*` directly. SwiftUI's view-diff short-circuits AgentCard's body when
///    the cached struct hasn't changed.
/// 3. Cross-role keys (e.g. `turnsByRole`) still cause every card's outer body to
///    re-evaluate (the Observation framework propagates whole-property changes), but the
///    only work is "read 1 stable @State, hand to child View, SwiftUI diffs and skips."
///    The heavy AgentCard body re-eval is avoided when the per-role narrowing
///    (`turnsByRole[role]`) didn't change.
struct InspectorView: View {
    let viewModel: AppViewModel

    // Per-role message slices. Populated once when `viewModel.messages` ticks; each card
    // watches only its own slice, so a Brown-only message doesn't dirty Smith or Jones.
    // The summarizer slice is also bucketed here so SummarizerAgentCard doesn't need to
    // run its own `viewModel.messages` watcher — having two watchers on the same source
    // array led to SwiftUI's "tried to update multiple times per frame" warnings.
    @State private var smithMessages: [ChannelMessage] = []
    @State private var brownMessages: [ChannelMessage] = []
    @State private var jonesMessages: [ChannelMessage] = []
    @State private var summarizerMessages: [ChannelMessage] = []

    /// Buckets channel messages by their sending agent role in one pass.
    static func bucketMessagesByRole(_ messages: [ChannelMessage]) -> [AgentRole: [ChannelMessage]] {
        var buckets: [AgentRole: [ChannelMessage]] = [:]
        for message in messages {
            if case .agent(let role) = message.sender {
                buckets[role, default: []].append(message)
            }
        }
        return buckets
    }

    var body: some View {
        VStack(spacing: 0) {
            CostEstimateSection(snapshot: viewModel.shared.costBoardSnapshot)

            Text("Agents")
                .font(AppFonts.sectionHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    RoleAgentCard(viewModel: viewModel, role: .smith, roleMessages: smithMessages)
                    RoleAgentCard(viewModel: viewModel, role: .brown, roleMessages: brownMessages)
                    RoleAgentCard(viewModel: viewModel, role: .jones, roleMessages: jonesMessages)
                    SummarizerAgentCard(viewModel: viewModel, summarizerMessages: summarizerMessages)
                }
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
        .task {
            rebucket()
            // Refresh boundaries on every view appear so an app that was idle past
            // local midnight rolls today → prior immediately when the inspector becomes
            // visible, rather than waiting up to a minute for the watcher timer.
            if let board = viewModel.shared.costBoard {
                await board.refreshIfBoundariesElapsed()
            }
        }
        .onChange(of: viewModel.messages) { _, _ in rebucket() }
    }

    /// Re-buckets `viewModel.messages` and assigns each per-role @State only if its slice
    /// actually changed. Mutations are deferred via `DispatchQueue.main.async` per the
    /// project rule (no synchronous @State mutation inside .onChange / .task closures).
    private func rebucket() {
        let buckets = Self.bucketMessagesByRole(viewModel.messages)
        let nextSmith = buckets[.smith] ?? []
        let nextBrown = buckets[.brown] ?? []
        let nextJones = buckets[.jones] ?? []
        let nextSummarizer = buckets[.summarizer] ?? []
        DispatchQueue.main.async {
            if smithMessages != nextSmith { smithMessages = nextSmith }
            if brownMessages != nextBrown { brownMessages = nextBrown }
            if jonesMessages != nextJones { jonesMessages = nextJones }
            if summarizerMessages != nextSummarizer { summarizerMessages = nextSummarizer }
        }
    }
}

// MARK: - Cached Data Structures

/// Pre-computed data for a single agent role. Equatable so SwiftUI can short-circuit
/// AgentCard's body re-evaluation when the cached struct is unchanged.
private struct AgentRoleData: Equatable {
    let role: AgentRole
    let roleMessages: [ChannelMessage]
    let recentMessages: [ChannelMessage]
    let recentToolUses: [ChannelMessage]
    let contextMessages: [LLMMessage]
    let llmTurns: [LLMTurnRecord]
    let pollInterval: TimeInterval
    let maxToolCalls: Int
    let currentSystemPrompt: String
    let hasActivity: Bool
    let availableTools: [String]
    let evaluationRecords: [EvaluationRecord]
    let isProcessing: Bool
    let executingTools: [String]
    let modelConfig: ModelConfiguration?
}

/// Pre-computed data for the summarizer role.
private struct SummarizerData: Equatable {
    let currentSystemPrompt: String
    let pollInterval: TimeInterval
    let maxToolCalls: Int
    let isProcessing: Bool
    let executingTools: [String]
    let messages: [ChannelMessage]
}

// MARK: - Per-Role Card Wrappers
//
// Each wrapper owns its own cached `AgentRoleData?` (or `SummarizerData?`) populated only
// via `.onChange` callbacks that narrow to a single key per source dictionary. The body
// reads ONLY the cache — never `viewModel.*` or `viewModel.inspectorStore.*` directly —
// so AgentCard's body re-evaluation is gated by the cache changing, which only happens
// when this role's specific slice of any source actually changed.

/// Wraps `AgentCard` with per-role @State caching and narrowed dependency watchers.
private struct RoleAgentCard: View {
    @Bindable var viewModel: AppViewModel
    let role: AgentRole
    let roleMessages: [ChannelMessage]

    @State private var cached: AgentRoleData?

    var body: some View {
        // The Group wrapper gives the view-modifier chain (.onChange) a stable parent View
        // to attach to even when the conditional `if let cached` is unsatisfied.
        Group {
            if let cached {
                cardView(for: cached)
            }
        }
        // Each .onChange watcher narrows to a per-role key where possible. Cross-role
        // dictionaries (`turnsByRole`, `liveContexts`) still cause every card's outer body
        // to re-evaluate when any role changes (Observation propagates whole-property
        // changes), but the `[role]` subscript narrows the *callback* — recompute() fires
        // only when this role's entry differs.
        //
        // Initial population is via `.task`, not `.onChange(initial: true)`. Two synchronous
        // initial-fires per modifier (one for each watcher) on first body eval was
        // contributing to SwiftUI's "tried to update multiple times per frame" warnings on
        // the Array<ChannelMessage>-typed watchers.
        .task { recompute() }
        .onChange(of: roleMessages)                                                  { _, _ in recompute() }
        .onChange(of: viewModel.inspectorStore.turnsByRole[role])                    { _, _ in recompute() }
        .onChange(of: viewModel.inspectorStore.liveContexts[role])                   { _, _ in recompute() }
        .onChange(of: role == .jones ? viewModel.inspectorStore.evaluationRecords.count : 0)
                                                                                     { _, _ in recompute() }
        .onChange(of: viewModel.processingRoles.contains(role))                      { _, _ in recompute() }
        .onChange(of: viewModel.toolExecutingByRole[role])                           { _, _ in recompute() }
        .onChange(of: viewModel.agentPollIntervals[role])                            { _, _ in recompute() }
        .onChange(of: viewModel.agentMaxToolCalls[role])                             { _, _ in recompute() }
        .onChange(of: viewModel.agentToolNames[role])                                { _, _ in recompute() }
        .onChange(of: viewModel.resolvedAgentConfigs[role])                          { _, _ in recompute() }
    }

    /// Helper extracted to keep the AgentCard call out of the body's `@ViewBuilder`
    /// type-checking context. With 17 parameters and four trailing closures, inlining the
    /// call inside `body` blew the type-checker's exponential overload-resolution budget.
    @ViewBuilder
    private func cardView(for cached: AgentRoleData) -> some View {
        let speechController = viewModel.shared.speechController
        AgentCard(
            viewModel: viewModel,
            role: cached.role,
            isProcessing: cached.isProcessing,
            executingTools: cached.executingTools,
            hasActivity: cached.hasActivity,
            availableTools: cached.availableTools,
            recentMessages: cached.recentMessages,
            recentToolUses: cached.recentToolUses,
            contextMessages: cached.contextMessages,
            llmTurns: cached.llmTurns,
            modelConfig: cached.modelConfig,
            evaluationRecords: cached.evaluationRecords,
            currentSystemPrompt: cached.currentSystemPrompt,
            pollInterval: cached.pollInterval,
            maxToolCalls: cached.maxToolCalls,
            speechController: speechController,
            onSendDirectMessage: makeSendMessageHandler(role: cached.role),
            onUpdateSystemPrompt: makeUpdateSystemPromptHandler(role: cached.role),
            onUpdatePollInterval: makeUpdatePollIntervalHandler(role: cached.role),
            onUpdateMaxToolCalls: makeUpdateMaxToolCallsHandler(role: cached.role)
        )
    }

    private func makeSendMessageHandler(role: AgentRole) -> (String) -> Void {
        { [viewModel] text in
            Task { await viewModel.sendDirectMessage(to: role, text: text) }
        }
    }

    private func makeUpdateSystemPromptHandler(role: AgentRole) -> (String) -> Void {
        { [viewModel] prompt in
            Task { await viewModel.updateSystemPrompt(for: role, prompt: prompt) }
        }
    }

    private func makeUpdatePollIntervalHandler(role: AgentRole) -> (TimeInterval) -> Void {
        { [viewModel] interval in
            Task { await viewModel.updatePollInterval(for: role, interval: interval) }
        }
    }

    private func makeUpdateMaxToolCallsHandler(role: AgentRole) -> (Int) -> Void {
        { [viewModel] count in
            Task { await viewModel.updateMaxToolCalls(for: role, count: count) }
        }
    }

    private func recompute() {
        let store = viewModel.inspectorStore
        let next = AgentRoleData(
            role: role,
            roleMessages: roleMessages,
            recentMessages: Array(roleMessages.suffix(5).reversed()),
            recentToolUses: Array(roleMessages.filter { $0.metadata?["tool"] != nil }.suffix(3).reversed()),
            contextMessages: store.contextMessages(for: role),
            llmTurns: store.turnsByRole[role] ?? [],
            pollInterval: viewModel.agentPollIntervals[role] ?? 5,
            maxToolCalls: viewModel.agentMaxToolCalls[role] ?? 100,
            currentSystemPrompt: store.systemPrompt(for: role),
            hasActivity: !roleMessages.isEmpty,
            availableTools: viewModel.agentToolNames[role] ?? [],
            evaluationRecords: role == .jones ? store.evaluationRecords : [],
            isProcessing: viewModel.processingRoles.contains(role),
            executingTools: Self.executingToolNames(viewModel.toolExecutingByRole[role]),
            modelConfig: viewModel.resolvedAgentConfigs[role]
        )
        // Skip the assignment if the struct didn't change — keeps body output stable
        // and lets SwiftUI's diff short-circuit AgentCard's body. Project rule: defer
        // the @State mutation out of .onChange via DispatchQueue.main.async.
        DispatchQueue.main.async {
            if cached != next { cached = next }
        }
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
}

/// Wraps `SummarizerCard` with @State caching and narrowed dependency watchers.
///
/// `summarizerMessages` is the parent's pre-bucketed slice (sender == `.agent(.summarizer)`),
/// so this card watches only its own slice — not the full `viewModel.messages` array — and
/// avoids fighting with the parent's watcher for the same source.
private struct SummarizerAgentCard: View {
    @Bindable var viewModel: AppViewModel
    let summarizerMessages: [ChannelMessage]

    @State private var cached: SummarizerData?

    var body: some View {
        Group {
            if let cached {
                cardView(for: cached)
            }
        }
        .task { recompute() }
        .onChange(of: summarizerMessages)                              { _, _ in recompute() }
        .onChange(of: viewModel.processingRoles.contains(.summarizer)) { _, _ in recompute() }
        .onChange(of: viewModel.toolExecutingByRole[.summarizer])      { _, _ in recompute() }
        .onChange(of: viewModel.agentPollIntervals[.summarizer])       { _, _ in recompute() }
        .onChange(of: viewModel.agentMaxToolCalls[.summarizer])        { _, _ in recompute() }
    }

    @ViewBuilder
    private func cardView(for cached: SummarizerData) -> some View {
        let speechController = viewModel.shared.speechController
        SummarizerCard(
            viewModel: viewModel,
            messages: cached.messages,
            isProcessing: cached.isProcessing,
            executingTools: cached.executingTools,
            currentSystemPrompt: cached.currentSystemPrompt,
            pollInterval: cached.pollInterval,
            maxToolCalls: cached.maxToolCalls,
            speechController: speechController,
            onUpdateSystemPrompt: { [viewModel] prompt in
                Task { await viewModel.updateSystemPrompt(for: .summarizer, prompt: prompt) }
            },
            onUpdatePollInterval: { [viewModel] interval in
                Task { await viewModel.updatePollInterval(for: .summarizer, interval: interval) }
            },
            onUpdateMaxToolCalls: { [viewModel] count in
                Task { await viewModel.updateMaxToolCalls(for: .summarizer, count: count) }
            }
        )
    }

    private func recompute() {
        let store = viewModel.inspectorStore
        let next = SummarizerData(
            currentSystemPrompt: store.systemPrompt(for: .summarizer),
            pollInterval: viewModel.agentPollIntervals[.summarizer] ?? 5,
            maxToolCalls: viewModel.agentMaxToolCalls[.summarizer] ?? 100,
            isProcessing: viewModel.processingRoles.contains(.summarizer),
            executingTools: RoleAgentCard.executingToolNames(viewModel.toolExecutingByRole[.summarizer]),
            messages: summarizerMessages
        )
        // Project rule: defer @State mutation out of .onChange via DispatchQueue.main.async.
        DispatchQueue.main.async {
            if cached != next { cached = next }
        }
    }
}

private struct AgentCard: View {
    @Bindable var viewModel: AppViewModel
    let role: AgentRole
    let isProcessing: Bool
    let executingTools: [String]
    let hasActivity: Bool
    let availableTools: [String]
    let recentMessages: [ChannelMessage]
    let recentToolUses: [ChannelMessage]
    let contextMessages: [LLMMessage]
    let llmTurns: [LLMTurnRecord]
    let modelConfig: ModelConfiguration?
    let evaluationRecords: [EvaluationRecord]
    let currentSystemPrompt: String
    let pollInterval: TimeInterval
    let maxToolCalls: Int
    let speechController: SpeechController
    let onSendDirectMessage: (String) -> Void
    let onUpdateSystemPrompt: (String) -> Void
    let onUpdatePollInterval: (TimeInterval) -> Void
    let onUpdateMaxToolCalls: (Int) -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var expanded = true
    @State private var processingStartDate: Date?
    @State private var toolExecutingStartDate: Date?
    @State private var showingConfig = false
    @State private var expandedTurnIDs: Set<UUID> = []

    /// Smith and Brown open in a separate window; Jones expands inline.
    private var opensInWindow: Bool { role == .smith || role == .brown }

    private var roleColor: Color { AppColors.color(for: .agent(role)) }
    private var isSpeechEnabled: Bool { speechController.agentEnabled[role] ?? false }

    /// Display name override for the inspector panel.
    private var inspectorDisplayName: String {
        switch role {
        case .smith: return "Agent Smith"
        case .brown: return "Agent Brown"
        case .jones: return "Security Agent"
        case .summarizer: return "Summarizer"
        }
    }

    /// Actual input token count from the most recent LLM turn, if available.
    private var lastInputTokens: Int? {
        llmTurns.last?.usage?.inputTokens
    }

    /// Context usage percentage based on actual token counts from the provider.
    private var contextPercent: Int? {
        guard let config = modelConfig, config.maxContextTokens > 0,
              let inputTokens = lastInputTokens else { return nil }
        return min(100, (inputTokens * 100) / config.maxContextTokens)
    }

    /// Whether the agent has been terminated — has activity history but no live tools.
    private var isTerminated: Bool {
        availableTools.isEmpty && !contextMessages.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Button(action: {
                    if opensInWindow {
                        openWindow(value: AgentInspectorTarget(sessionID: viewModel.session.id, role: role))
                    } else {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    }
                }, label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(hasActivity ? roleColor : AppColors.inactiveDot)
                            .frame(width: 8, height: 8)

                        Text(inspectorDisplayName)
                            .font(.headline)
                            .foregroundStyle(hasActivity ? roleColor : .secondary)

                        Spacer()

                        AgentCardStatusBadge(
                            isProcessing: isProcessing,
                            hasActivity: hasActivity,
                            isJones: role == .jones,
                            isTerminated: role != .jones && isTerminated,
                            executingTools: executingTools,
                            processingStartDate: processingStartDate,
                            toolExecutingStartDate: toolExecutingStartDate
                        )

                        if opensInWindow {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)

                Button(action: {
                    speechController.setEnabled(!isSpeechEnabled, for: role)
                }, label: {
                    Image(systemName: isSpeechEnabled ? "speaker.wave.1" : "speaker.slash")
                        .font(.caption)
                        .foregroundStyle(isSpeechEnabled ? .green : AppColors.inactiveDot)
                })
                .buttonStyle(.plain)
                .help(isSpeechEnabled ? "Mute \(role.displayName)" : "Unmute \(role.displayName)")

                Button(action: { showingConfig = true }, label: {
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                })
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Model info subtitle — aligned with agent name text (past the dot)
            if let config = modelConfig {
                AgentCardModelInfoLine(modelConfig: config, llmTurns: llmTurns, role: role)
                    .padding(.leading, 28) // 12 (container) + 8 (dot) + 8 (spacing)
                    .padding(.trailing, 12)
                    .padding(.bottom, 2)
            }

            // Estimated cost spent by this agent in the current session. Recomputed
            // when `inspectorStore.turnsByRole[role]` changes — SwiftUI's per-card
            // narrowing already gates body re-eval to this role's slice changing.
            HStack(spacing: 6) {
                Text("Session")
                Spacer()
                Text(String(format: "$%.2f", viewModel.sessionCost(for: role)))
                    .monospacedDigit()
            }
            .font(AppFonts.inspectorLabel)
            .foregroundStyle(.tertiary)
            .padding(.leading, 28)
            .padding(.trailing, 12)
            .padding(.bottom, 6)

            if expanded && !opensInWindow {
                AgentCardExpandedSections(
                    role: role,
                    availableTools: availableTools,
                    evaluationRecords: evaluationRecords,
                    recentToolUses: recentToolUses,
                    recentMessages: recentMessages,
                    contextMessages: contextMessages,
                    llmTurns: llmTurns,
                    expandedTurnIDs: $expandedTurnIDs,
                    onSendDirectMessage: onSendDirectMessage
                )
            }

            Divider()
        }
        .sheet(isPresented: $showingConfig) {
            AgentConfigSheet(
                viewModel: viewModel,
                role: role,
                roleColor: roleColor,
                initialSystemPrompt: currentSystemPrompt,
                initialPollInterval: pollInterval,
                initialMaxToolCalls: maxToolCalls,
                speechController: speechController,
                onSave: { prompt, interval, maxCalls in
                    onUpdateSystemPrompt(prompt)
                    onUpdatePollInterval(interval)
                    onUpdateMaxToolCalls(maxCalls)
                }
            )
        }
        .onAppear {
            // Project rule: defer @State mutations out of lifecycle closures.
            if isProcessing {
                DispatchQueue.main.async { processingStartDate = Date() }
            }
            if !executingTools.isEmpty {
                DispatchQueue.main.async { toolExecutingStartDate = Date() }
            }
        }
        .onChange(of: isProcessing) { _, newValue in
            DispatchQueue.main.async {
                processingStartDate = newValue ? Date() : nil
            }
        }
        .onChange(of: executingTools.isEmpty) { _, isEmpty in
            DispatchQueue.main.async {
                toolExecutingStartDate = isEmpty ? nil : Date()
            }
        }
    }
}

// MARK: - Shared Views

/// Shows elapsed time (MM:SS) after 5 seconds of processing. Updates every second.
struct ThinkingElapsedTime: View {
    let since: Date
    let font: Font

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { timeline in
            let elapsed = Int(timeline.date.timeIntervalSince(since))
            if elapsed >= 5 {
                Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                    .font(font)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Subviews

struct AvailableToolsGrid: View {
    let toolNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(toolNames, id: \.self) { name in
                HStack(spacing: 5) {
                    Image(systemName: "wrench")
                        .font(AppFonts.metaIcon)
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppFonts.inspectorLabel.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct InspectorToolRow: View {
    let message: ChannelMessage

    private var toolName: String {
        if case .string(let name) = message.metadata?["tool"] { return name }
        return "unknown"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(AppFonts.metaIcon)
                .foregroundStyle(.secondary)
            Text(toolName)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.primary)
            Spacer()
            Text(message.timestamp, style: .time)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(AppColors.subtleRowBackgroundLift)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct InspectorMessageRow: View {
    let message: ChannelMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.content)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.primary)
            Text(message.timestamp, style: .time)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(AppColors.subtleRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// A single entry from an agent's LLM context window. Tap to expand the full content.
struct ContextMessageRow: View {
    let message: LLMMessage
    /// Optional message index displayed before the role label (e.g. "#1").
    var index: Int?
    /// When true, the message starts fully expanded (used in FullContextSheet).
    var initiallyExpanded: Bool = false

    @State private var expanded = false

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }, label: {
            HStack(alignment: .top, spacing: 5) {
                if let index {
                    Text("#\(index)")
                        .font(AppFonts.microMonoIndex)
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, alignment: .trailing)
                }

                Text(roleLabel)
                    .font(AppFonts.inspectorBody.weight(.bold))
                    .foregroundStyle(roleColor)
                    .frame(width: 14, alignment: .center)

                Text(expanded ? fullContent : contentSummary)
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(roleTooltip)
        })
        .buttonStyle(.plain)
        .onAppear {
            // Project rule: defer @State mutations out of lifecycle closures.
            if initiallyExpanded {
                DispatchQueue.main.async { expanded = true }
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .system: return "S"
        case .user: return "U"
        case .assistant: return "A"
        case .tool: return "T"
        case .developer: return "D"
        }
    }

    private var roleTooltip: String {
        switch message.role {
        case .system: return "S = System prompt — the agent's base instructions"
        case .user: return "U = User input — messages from the orchestrator, channel, or injected context"
        case .assistant: return "A = Assistant — the LLM's response (text and/or tool calls)"
        case .tool: return "T = Tool result — output returned by a tool call execution"
        case .developer: return "D = Developer prompt (OpenAI o-series/GPT-5; falls back to system on other providers)"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .system: return .secondary
        case .user: return .blue
        case .assistant: return .green
        case .tool: return .orange
        case .developer: return .secondary
        }
    }

    private var rowBackground: Color {
        AppColors.contextRowBackground(for: message.role)
    }

    private var contentSummary: String {
        switch message.content {
        case .text(let s): return truncate(s)
        case .toolCalls(let calls): return calls.map { "[\($0.name)]" }.joined(separator: ", ")
        case .mixed(let text, let calls):
            return truncate(text) + " " + calls.map { "[\($0.name)]" }.joined(separator: ", ")
        case .toolResult(let callID, let content):
            return "→ \(String(callID.prefix(8))): \(truncate(content))"
        }
    }

    private var fullContent: String {
        switch message.content {
        case .text(let s): return s
        case .toolCalls(let calls):
            return calls.map { call in
                "\(call.name)(\(call.arguments))"
            }.joined(separator: "\n\n")
        case .mixed(let text, let calls):
            var parts = [text]
            parts.append(contentsOf: calls.map { "\($0.name)(\($0.arguments))" })
            return parts.joined(separator: "\n\n")
        case .toolResult(let callID, let content):
            return "→ \(callID):\n\(content)"
        }
    }

    private func truncate(_ s: String) -> String {
        let limit = 120
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }
}

/// A row showing a single security evaluation result from SecurityEvaluator.
struct EvaluationRecordRow: View {
    let record: EvaluationRecord
    @State private var expanded = false

    private var dispositionLabel: String {
        if record.disposition.isCancelled {
            return "CANCELLED"
        } else if record.disposition.approved && record.disposition.isAutoApproval {
            return "AUTO"
        } else if record.disposition.approved {
            return "SAFE"
        } else if record.disposition.isWarning {
            return "WARN"
        } else {
            return "UNSAFE"
        }
    }

    private var dispositionColor: Color {
        if record.disposition.isCancelled { return .secondary }
        if record.disposition.approved { return .green }
        if record.disposition.isWarning { return .orange }
        return .red
    }

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }, label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dispositionLabel)
                        .font(AppFonts.microMonoBadge)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(dispositionColor.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text(record.toolName)
                        .font(AppFonts.inspectorBody.bold())
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(record.latencyMs)ms")
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    Text(record.timestamp, style: .time)
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.tertiary)
                }

                if expanded {
                    if !record.toolParams.isEmpty {
                        Text(record.toolParams)
                            .font(AppFonts.smallMonoCode)
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                    }
                    Text("Response: \(record.response)")
                        .font(AppFonts.inspectorBody.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(dispositionColor.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
    }
}

struct DirectMessageInputRow: View {
    let placeholder: String
    let onSend: (String) -> Void

    @State private var draftText = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $draftText)
                .textFieldStyle(.roundedBorder)
                .font(AppFonts.inspectorBody)
                .onSubmit { sendIfNotEmpty() }

            Button("Send") {
                sendIfNotEmpty()
            }
            .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .controlSize(.small)
        }
    }

    private func sendIfNotEmpty() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
        draftText = ""
    }
}

// MARK: - Config Sheet

struct AgentConfigSheet: View {
    @Bindable var viewModel: AppViewModel
    let role: AgentRole
    let roleColor: Color
    let speechController: SpeechController
    let onSave: (String, TimeInterval, Int) -> Void

    // Drafts seeded from init parameters via `_draftX = State(initialValue:)`. The
    // global SwiftUI rule says "AVOID initializing @State based on init parameters"
    // because the parent rebuilding with new values silently keeps stale @State. That
    // hazard doesn't apply here: this view is sheet content presented via
    // `.sheet(isPresented:)` and is reconstructed on every presentation, so SwiftUI
    // creates fresh @State each time. The alternative (default values + `.task`
    // seeding) introduces a one-frame flash of empty fields and a theoretical race
    // where pressing Done before `.task` runs would save defaults — both regressions.
    @State private var draftPrompt: String
    @State private var draftPollInterval: TimeInterval
    @State private var draftMaxToolCalls: Int
    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @Environment(\.dismiss) private var dismiss

    init(
        viewModel: AppViewModel,
        role: AgentRole,
        roleColor: Color,
        initialSystemPrompt: String,
        initialPollInterval: TimeInterval,
        initialMaxToolCalls: Int,
        speechController: SpeechController,
        onSave: @escaping (String, TimeInterval, Int) -> Void
    ) {
        self.viewModel = viewModel
        self.role = role
        self.roleColor = roleColor
        self.speechController = speechController
        self.onSave = onSave
        _draftPrompt = State(initialValue: initialSystemPrompt)
        _draftPollInterval = State(initialValue: initialPollInterval)
        _draftMaxToolCalls = State(initialValue: initialMaxToolCalls)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(role.displayName) Configuration")
                    .font(.title3.bold())
                    .foregroundStyle(roleColor)
                Spacer()
                Button("Done") {
                    onSave(draftPrompt, draftPollInterval, draftMaxToolCalls)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Model — agent-centric provider/model/tuning controls. Reads & writes
                    // the dedicated configuration for this role via viewModel helpers.
                    AgentModelSettingsSection(viewModel: viewModel, role: role)

                    Divider()

                    AgentConfigSpeechSection(
                        role: role,
                        speechController: speechController,
                        availableVoices: availableVoices
                    )

                    Divider()

                    AgentConfigSoundsSection(role: role, speechController: speechController)

                    Divider()

                    AgentConfigResponsivenessSection(
                        draftMaxToolCalls: $draftMaxToolCalls,
                        draftPollInterval: $draftPollInterval
                    )

                    Divider()

                    AgentConfigSystemPromptSection(draftPrompt: $draftPrompt)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 540, idealHeight: 720)
        .onAppear {
            // Project rule: defer @State mutation out of lifecycle closures.
            let voices = AVSpeechSynthesisVoice.speechVoices()
                .sorted { $0.name < $1.name }
            DispatchQueue.main.async { availableVoices = voices }
        }
    }
}

// MARK: - Reusable Sound/Voice Components

/// A sound-effect picker with a label and preview button.
struct SoundPickerRow: View {
    let label: String
    @Binding var soundName: String
    let onPreview: (String) -> Void

    var body: some View {
        LabeledContent(label) {
            HStack {
                Picker("", selection: $soundName) {
                    Text("None").tag("")
                    ForEach(SpeechController.systemSoundNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Button(action: { onPreview(soundName) }) {
                    Image(systemName: "play.circle")
                }
                .disabled(soundName.isEmpty)
                .buttonStyle(.borderless)
            }
        }
    }
}

/// A voice picker with a test-speech button.
struct VoicePickerRow: View {
    @Binding var voiceIdentifier: String
    let availableVoices: [AVSpeechSynthesisVoice]
    let onTest: () -> Void

    private var displaySelection: Binding<String> {
        Binding(
            get: {
                if voiceIdentifier.isEmpty { return "" }
                return availableVoices.contains { $0.identifier == voiceIdentifier } ? voiceIdentifier : ""
            },
            set: { voiceIdentifier = $0 }
        )
    }

    var body: some View {
        LabeledContent("Voice") {
            HStack {
                Picker("", selection: displaySelection) {
                    Text("System Default").tag("")
                    ForEach(availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Button(action: onTest) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Test voice")
            }
        }
    }
}

// MARK: - Shared Helpers

/// Formats a latency in milliseconds to a human-readable string (e.g. "342ms", "1.8s", "12s").
func formatLatency(_ ms: Int) -> String {
    if ms < 1000 {
        return "\(ms)ms"
    } else if ms < 10_000 {
        return String(format: "%.1fs", Double(ms) / 1000.0)
    } else {
        return String(format: "%.0fs", Double(ms) / 1000.0)
    }
}

