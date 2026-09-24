import AVFoundation
import SwiftUI
import SwiftLLMKit
import AgentSmithKit

// MARK: - Summarizer Card

/// Inspector card for the TaskSummarizer, matching AgentCard visual style.
///
/// The summarizer is transient (fires once per task completion, memory consolidation, or prompted
/// web fetch), so it has no persistent context or tools. The card is status only; its title opens
/// the shared inspector window, which lists its provider calls (a completed call with its exact
/// request, a failed attempt with its error).
struct SummarizerCard: View {
    @Bindable var viewModel: AppViewModel
    let messages: [ChannelMessage]
    let isProcessing: Bool
    let executingTools: [String]
    let currentSystemPrompt: String
    let pollInterval: TimeInterval
    let maxToolCalls: Int
    let speechController: SpeechController
    let onUpdateSystemPrompt: (String) -> Void
    let onUpdatePollInterval: (TimeInterval) -> Void
    let onUpdateMaxToolCalls: (Int) -> Void

    @State private var showingConfig = false
    @Environment(\.openWindow) private var openWindow

    private static let roleColor = AppColors.summarizerAgent

    var body: some View {
        // `messages` is already the Summarizer's own slice (bucketed by the parent).
        let hasActivity = !messages.isEmpty || viewModel.hasAgentActivity(.summarizer)

        return VStack(alignment: .leading, spacing: 0) {
            SummarizerCardHeader(
                hasActivity: hasActivity,
                isProcessing: isProcessing,
                executingTools: executingTools,
                roleColor: Self.roleColor,
                onOpenWindow: openInspector,
                onShowConfig: { showingConfig = true }
            )

            HStack(spacing: 6) {
                Text("Session")
                Spacer()
                Text(String(format: "$%.2f", viewModel.sessionCost(for: .summarizer)))
                    .monospacedDigit()
            }
            .font(AppFonts.inspectorLabel)
            .foregroundStyle(.tertiary)
            .padding(.leading, 28)
            .padding(.trailing, 12)
            .padding(.bottom, 6)

            Divider()
        }
        .sheet(isPresented: $showingConfig) {
            AgentConfigSheet(
                viewModel: viewModel,
                role: .summarizer,
                roleColor: Self.roleColor,
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
    }

    private func openInspector() {
        openWindow(value: AgentInspectorTarget(sessionID: viewModel.session.id, role: .summarizer))
    }
}

/// A single row in the summarizer activity log.
struct SummarizerActivityRow: View {
    let message: ChannelMessage

    @State private var isExpanded = false

    /// Via the accessor — the raw `isError` key this used to read is no longer written, so a
    /// FAILED summary was about to render with a green checkmark.
    private var isError: Bool { message.severity >= .error }

    private var taskID: String? {
        if case .string(let id) = message.metadata?["taskID"] { return id }
        return nil
    }

    private var latencyMs: Int? {
        if case .int(let ms) = message.metadata?["latencyMs"] { return ms }
        return nil
    }

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }, label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(AppFonts.metaIcon)
                        .foregroundStyle(isError ? .red : .green)

                    Text(isExpanded ? message.content : String(message.content.prefix(80)) + (message.content.count > 80 ? "…" : ""))
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)

                    if let latencyMs {
                        Text(formatLatency(latencyMs))
                            .font(AppFonts.inspectorBody)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    if !isExpanded {
                        Text(message.timestamp, style: .time)
                            .font(AppFonts.inspectorBody)
                            .foregroundStyle(.tertiary)
                    }
                }

                if isExpanded, let taskID {
                    Text("Task: \(taskID)")
                        .font(AppFonts.microMonoCode)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(isError ? Color.red.opacity(0.05) : Color.green.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
    }
}

