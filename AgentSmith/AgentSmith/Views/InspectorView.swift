import AVFoundation
import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Inspector panel showing per-agent status: activity, context, tools, and direct messaging.
///
/// **Where the data comes from.** Every card and the Live section read finished values from
/// `AppViewModel.inspectorLive` (`InspectorLiveState`), which derives them in the model. The views
/// here watch nothing: the `.onChange`-driven caches they used to keep were the source of every
/// SwiftUI "tried to update multiple times per frame" warning, and SwiftUI skipped the rebuild each
/// one warned about. See `InspectorLiveState`.
struct InspectorView: View {
    let viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            CostEstimateSection(snapshot: viewModel.shared.costBoardSnapshot)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NowLiveSection(live: viewModel.inspectorLive)

                    Text("Agents")
                        .font(AppFonts.sectionHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    ConcurrencyStrip(shared: viewModel.shared)

                    Divider()

                    RoleAgentCard(viewModel: viewModel, card: viewModel.inspectorLive.card(for: .smith))
                    RoleAgentCard(viewModel: viewModel, card: viewModel.inspectorLive.card(for: .brown))
                    RoleAgentCard(viewModel: viewModel, card: viewModel.inspectorLive.card(for: .securityAgent))
                    ValidatorAgentCard(viewModel: viewModel)
                    SummarizerAgentCard(viewModel: viewModel, live: viewModel.inspectorLive)
                    MemoryActivityCard(shared: viewModel.shared)
                }
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
        .task {
            viewModel.inspectorLive.activate()
            // Refresh boundaries on every view appear so an app that was idle past
            // local midnight rolls today → prior immediately when the inspector becomes
            // visible, rather than waiting up to a minute for the watcher timer.
            if let board = viewModel.shared.costBoard {
                await board.refreshIfBoundariesElapsed()
            }
        }
    }
}

// MARK: - Per-Role Card Wrappers

/// Shows one role's card from the model-side data (`RoleCardState`), once the first rebuild has
/// produced it.
private struct RoleAgentCard: View {
    let viewModel: AppViewModel
    let card: RoleCardState

    var body: some View {
        if let data = card.data {
            RoleAgentCardContent(viewModel: viewModel, data: data)
        }
    }
}

/// Builds the `AgentCard` for one role's data, with the handlers that write its settings back.
/// Separate from `RoleAgentCard` to keep the AgentCard call out of a `@ViewBuilder` conditional:
/// with its handler closures inline, the call blew the type-checker's overload-resolution budget.
private struct RoleAgentCardContent: View {
    let viewModel: AppViewModel
    let data: AgentRoleData

    var body: some View {
        AgentCard(
            viewModel: viewModel,
            data: data,
            speechController: viewModel.shared.speechController,
            onUpdateSystemPrompt: makeUpdateSystemPromptHandler(role: data.role),
            onUpdatePollInterval: makeUpdatePollIntervalHandler(role: data.role),
            onUpdateMaxToolCalls: makeUpdateMaxToolCallsHandler(role: data.role)
        )
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
}

/// Shows the summarizer's card from the model-side data, once the first rebuild has produced it.
private struct SummarizerAgentCard: View {
    let viewModel: AppViewModel
    let live: InspectorLiveState

    var body: some View {
        if let data = live.summarizerCard {
            SummarizerAgentCardContent(viewModel: viewModel, data: data)
        }
    }
}

private struct SummarizerAgentCardContent: View {
    let viewModel: AppViewModel
    let data: SummarizerCardData

    var body: some View {
        SummarizerCard(
            viewModel: viewModel,
            messages: data.messages,
            isProcessing: data.isProcessing,
            executingTools: data.executingTools,
            providerWaits: data.providerWaits,
            currentSystemPrompt: data.currentSystemPrompt,
            pollInterval: data.pollInterval,
            maxToolCalls: data.maxToolCalls,
            speechController: viewModel.shared.speechController,
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
}

private struct AgentCard: View {
    @Bindable var viewModel: AppViewModel
    /// The whole pre-computed slice for this role.
    ///
    /// One value rather than the fifteen fields it holds, restated. The comment on the call site
    /// records what listing them cost: seventeen parameters and four trailing closures blew the
    /// type-checker's overload-resolution budget when the call sat inside a `@ViewBuilder`.
    let data: AgentRoleData
    let speechController: SpeechController
    let onUpdateSystemPrompt: (String) -> Void
    let onUpdatePollInterval: (TimeInterval) -> Void
    let onUpdateMaxToolCalls: (Int) -> Void

    @Environment(\.openWindow) private var openWindow
    /// Cards start COLLAPSED — the agent's details (tools, evaluations, context, turns) are opened on
    /// demand rather than filling the panel by default (Security Agent in particular used to open with
    /// its full evaluation log expanded).
    @State private var expanded = false
    @State private var showingConfig = false


    // Read through to the slice, so the body and its helpers read exactly as before.
    private var role: AgentRole { data.role }
    private var isProcessing: Bool { data.isProcessing }
    private var executingTools: [String] { data.executingTools }
    private var hasActivity: Bool { data.hasActivity }
    private var availableTools: [String] { data.availableTools }
    private var contextMessages: [LLMMessage] { data.contextMessages }
    private var llmTurns: [LLMTurnRecord] { data.callLog?.retainedTurns ?? [] }
    private var modelConfig: ModelConfiguration? { data.modelConfig }
    private var evaluationRecords: [EvaluationRecord] { data.evaluationRecords }
    private var currentSystemPrompt: String { data.currentSystemPrompt }
    private var pollInterval: TimeInterval { data.pollInterval }
    private var maxToolCalls: Int { data.maxToolCalls }

    /// Smith and Brown open in a separate window from the title; Security Agent's title expands
    /// its recent evaluations inline and a separate button opens its window.
    private var opensInWindow: Bool { role == .smith || role == .brown }
    private var hasSeparatePopOutButton: Bool { role == .securityAgent }

    private var roleColor: Color { AppColors.color(for: .agent(role)) }
    private var isSpeechEnabled: Bool { speechController.agentEnabled[role] ?? false }

    /// The sidebar lists only the newest few evaluations; the inspector window lists every
    /// retained one.
    private static let inlineEvaluationLimit = 10

    /// Display name override for the inspector panel.
    private var inspectorDisplayName: String {
        switch role {
        case .smith: return "Agent Smith"
        case .brown: return "Agent Brown"
        case .securityAgent: return "Security Agent"
        case .summarizer: return "Summarizer"
        // Not reachable today — validators are per-criterion evaluations, not long-lived
        // agents, so no inspector panel is ever opened on this role.
        case .validator: return role.displayName
        }
    }

    /// Whether the agent has been terminated — has activity history but no live tools.
    private var isTerminated: Bool {
        availableTools.isEmpty && !contextMessages.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentCardHeaderRow(
                role: role, roleColor: roleColor, displayName: inspectorDisplayName,
                hasActivity: hasActivity, opensInWindow: opensInWindow,
                hasSeparatePopOutButton: hasSeparatePopOutButton,
                isSpeechEnabled: isSpeechEnabled, expanded: $expanded,
                onOpenWindow: openOwnWindow, onToggleSpeech: toggleSpeech,
                onOpenConfig: { showingConfig = true }
            )
            // Its own line under the name (indented past the dot) so a long
            // "Working — <tool> MM:SS" never squeezes the name into a column of letters.
            AgentCardStatusBadge(
                isProcessing: isProcessing, hasActivity: hasActivity,
                isSecurityAgent: role == .securityAgent,
                isTerminated: role != .securityAgent && isTerminated,
                executingTools: executingTools, processingStartDate: data.processingSince,
                toolExecutingStartDate: data.toolsRunningSince,
                providerWaits: data.providerWaits
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 28).padding(.trailing, 12).padding(.bottom, 6)

            // 28 = 12 (container) + 8 (dot) + 8 (spacing), so this aligns with the agent's name.
            if let config = modelConfig {
                AgentCardModelInfoLine(modelConfig: config, llmTurns: llmTurns,
                                       role: role, shared: viewModel.shared,
                                       evictedCallCount: data.callLog?.evictedCount ?? 0)
                    .padding(.leading, 28).padding(.trailing, 12).padding(.bottom, 2)
            }
            AgentCardSessionCostLine(cost: data.sessionCost)

            if expanded && !opensInWindow {
                SecurityEvaluationsSection(
                    records: evaluationRecords, lifetimeCount: data.evaluationLifetimeCount,
                    limit: Self.inlineEvaluationLimit, detail: .compact)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            Divider()
        }
        .sheet(isPresented: $showingConfig) {
            AgentConfigSheet(
                viewModel: viewModel, role: role, roleColor: roleColor,
                initialSystemPrompt: currentSystemPrompt, initialPollInterval: pollInterval,
                initialMaxToolCalls: maxToolCalls, speechController: speechController,
                onSave: onSaveConfig
            )
        }
    }

    private func openOwnWindow() {
        openWindow(value: AgentInspectorTarget(sessionID: viewModel.session.id, role: role))
    }

    private func toggleSpeech() {
        speechController.setEnabled(!isSpeechEnabled, for: role)
    }

    private func onSaveConfig(_ prompt: String, _ interval: TimeInterval, _ maxCalls: Int) {
        onUpdateSystemPrompt(prompt)
        onUpdatePollInterval(interval)
        onUpdateMaxToolCalls(maxCalls)
    }
}

/// An agent card's title line: the activity dot and name (which either expands the card or opens
/// its own window), plus the mute and settings controls.
private struct AgentCardHeaderRow: View {
    let role: AgentRole
    let roleColor: Color
    let displayName: String
    let hasActivity: Bool
    let opensInWindow: Bool
    /// A dedicated pop-out button beside a title that expands inline (Security Agent).
    let hasSeparatePopOutButton: Bool
    let isSpeechEnabled: Bool
    @Binding var expanded: Bool
    let onOpenWindow: () -> Void
    let onToggleSpeech: () -> Void
    let onOpenConfig: () -> Void

    /// The name either expands the card in place or opens the agent its own window — never both,
    /// which is why the chevron and the open-in-window glyph are alternatives in the label.
    private func activateTitle() {
        if opensInWindow {
            onOpenWindow()
        } else {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: activateTitle, label: {
                AgentCardTitleLabel(roleColor: roleColor, displayName: displayName,
                                    hasActivity: hasActivity, opensInWindow: opensInWindow,
                                    expanded: expanded)
            })
            .buttonStyle(.plain)
            .help(opensInWindow ? "Open \(displayName) inspector" : (expanded ? "Collapse" : "Expand") + " \(displayName)")
            .accessibilityLabel(opensInWindow ? "Open \(displayName) inspector" : (expanded ? "Collapse" : "Expand") + " \(displayName)")

            if hasSeparatePopOutButton {
                AgentCardPopOutButton(displayName: displayName, onOpen: onOpenWindow)
            }

            AgentCardMuteButton(role: role, isSpeechEnabled: isSpeechEnabled,
                                onToggle: onToggleSpeech)
            Button(action: onOpenConfig, label: {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            })
            .buttonStyle(.plain)
            .help("\(displayName) settings")
            .accessibilityLabel("\(displayName) settings")
            .padding(.leading, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

/// The dot, the name, and the affordance that says what clicking does.
private struct AgentCardTitleLabel: View {
    let roleColor: Color
    let displayName: String
    let hasActivity: Bool
    let opensInWindow: Bool
    let expanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(hasActivity ? roleColor : AppColors.inactiveDot)
                .frame(width: 8, height: 8)
            Text(displayName)
                .font(.headline)
                .foregroundStyle(hasActivity ? roleColor : .secondary)
                .lineLimit(1)
            Spacer()
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
    }
}

/// What this agent has spent in the current session.
private struct AgentCardSessionCostLine: View {
    let cost: Double

    var body: some View {
        HStack(spacing: 6) {
            Text("Session")
            Spacer()
            Text(String(format: "$%.2f", cost))
                .monospacedDigit()
        }
        .font(AppFonts.inspectorLabel)
        .foregroundStyle(.tertiary)
        .padding(.leading, 28)
        .padding(.trailing, 12)
        .padding(.bottom, 6)
    }
}

/// Opens an agent's inspector window, for cards whose title expands inline instead.
private struct AgentCardPopOutButton: View {
    let displayName: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen, label: {
            Image(systemName: "arrow.up.forward.square")
                .font(.caption)
                .foregroundStyle(.secondary)
        })
        .buttonStyle(.plain)
        .help("Open \(displayName) inspector")
        .accessibilityLabel("Open \(displayName) inspector")
    }
}

/// Mutes or unmutes one agent's speech.
private struct AgentCardMuteButton: View {
    let role: AgentRole
    let isSpeechEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle, label: {
            Image(systemName: isSpeechEnabled ? "speaker.wave.1" : "speaker.slash")
                .font(.caption)
                .foregroundStyle(isSpeechEnabled ? .green : AppColors.inactiveDot)
        })
        .buttonStyle(.plain)
        .help(isSpeechEnabled ? "Mute \(role.displayName)" : "Unmute \(role.displayName)")
    }
}

// MARK: - Shared Views

/// Shows elapsed time (MM:SS) after 5 seconds of processing. Updates every second.
struct ThinkingElapsedTime: View {
    let since: Date
    let font: Font

    var body: some View {
        TimelineView(SharedTimelineSchedules.everySecond) { timeline in
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
        if let name = message.toolName { return name }
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

// MARK: - Concurrency Strip

/// A compact, color-coded meter of how many operations of each kind are running app-wide RIGHT NOW —
/// Brown workers, Security/Validator evaluations, Summarizer runs, and memory searches. Reads
/// `SharedAppState.liveActivitySnapshot` (the single app-wide tracker's main-thread mirror), so the
/// counts are TOTALS across every tab, not per-session. Each chip lights when its count > 0 and dims
/// to a neutral dot at zero; the chips reflow to the inspector's width.
private struct ConcurrencyStrip: View {
    /// Read the snapshot INSIDE this view (not passed down from `InspectorView.body`) so only this
    /// strip re-renders on each activity tick — the agent cards' body evaluation stays gated by their
    /// own caches, per this file's observation-narrowing rules.
    let shared: SharedAppState

    private struct Meter: Identifiable {
        let id: String
        let count: Int
        let label: String
        let color: Color
    }

    private func meters(_ snapshot: LiveActivityTracker.Snapshot) -> [Meter] {
        [
            Meter(id: "brown", count: snapshot.brownWorkers, label: "Brown",
                  color: AppColors.color(for: .agent(.brown))),
            Meter(id: "security", count: snapshot.securityEvaluations, label: "Security",
                  color: AppColors.color(for: .agent(.securityAgent))),
            Meter(id: "validator", count: snapshot.validatorEvaluations, label: "Validator",
                  color: AppColors.color(for: .agent(.validator))),
            Meter(id: "summarizer", count: snapshot.summarizerRuns, label: "Summarizer",
                  color: AppColors.color(for: .agent(.summarizer))),
            // Memory search shares the purple used by the Memory query card below.
            Meter(id: "search", count: snapshot.memorySearches, label: "Search", color: .purple)
        ]
    }

    /// Two chips per row, laid out as a Grid (not a free-flowing row) so the same column position
    /// lines up across rows — e.g. Security and Summarizer share a left edge, Search sits under Brown.
    private static let columnCount = 2

    var body: some View {
        let snapshot = shared.liveActivitySnapshot
        let ms = meters(snapshot)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(stride(from: 0, to: ms.count, by: Self.columnCount)), id: \.self) { start in
                GridRow {
                    ForEach(ms[start ..< min(start + Self.columnCount, ms.count)]) { meter in
                        ConcurrencyChip(count: meter.count, label: meter.label, color: meter.color)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.15), value: snapshot)
    }
}

/// One count in the concurrency strip: a colored dot + count + label, going neutral/secondary at zero.
private struct ConcurrencyChip: View {
    let count: Int
    let label: String
    let color: Color

    private var active: Bool { count > 0 }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? color : AppColors.inactiveDot)
                .frame(width: 7, height: 7)
            Text("\(count)")
                .font(AppFonts.inspectorLabel)
                .fontWeight(active ? .semibold : .regular)
                .monospacedDigit()
                .foregroundStyle(active ? .primary : .secondary)
            Text(label)
                .font(AppFonts.inspectorLabel)
                .foregroundStyle(active ? .secondary : .tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(label) running")
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

