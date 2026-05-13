import AVFoundation
import SwiftUI
import SwiftLLMKit
import AgentSmithKit

// MARK: - Summarizer Card

/// Inspector card for the TaskSummarizer, matching AgentCard visual style.
///
/// The summarizer is transient (fires once per task completion), so it doesn't have
/// persistent context, tools, or LLM turns. Instead, we show activity history and stats.
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

    @State private var expanded = true
    @State private var showingConfig = false

    private static let roleColor = AppColors.summarizerAgent

    /// Aggregated stats over the summarizer's message slice. Walks the input once and
    /// returns the filtered messages alongside summary/error counts so the body doesn't
    /// re-scan three separate times per render.
    static func summarizerStats(
        _ messages: [ChannelMessage]
    ) -> (messages: [ChannelMessage], summaryCount: Int, errorCount: Int) {
        var filtered: [ChannelMessage] = []
        var summaryCount = 0
        var errorCount = 0
        for message in messages {
            guard case .agent(.summarizer) = message.sender else { continue }
            filtered.append(message)
            if case .string("task_summarized") = message.metadata?["messageKind"] {
                summaryCount += 1
            }
            if case .bool(true) = message.metadata?["isError"] {
                errorCount += 1
            }
        }
        return (filtered, summaryCount, errorCount)
    }

    var body: some View {
        // Single pass to bucket the summarizer's messages and count summary/error events.
        // Without caching, summarizerMessages was filtering the full message array per
        // body access, and summaryCount/errorCount each re-filtered it again.
        let stats = Self.summarizerStats(messages)
        let summarizerMessages = stats.messages
        let hasActivity = !summarizerMessages.isEmpty
        let summaryCount = stats.summaryCount
        let errorCount = stats.errorCount

        return VStack(alignment: .leading, spacing: 0) {
            SummarizerCardHeader(
                hasActivity: hasActivity,
                isProcessing: isProcessing,
                executingTools: executingTools,
                roleColor: Self.roleColor,
                expanded: $expanded,
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

            if expanded {
                SummarizerCardExpandedSections(
                    summarizerMessages: summarizerMessages,
                    summaryCount: summaryCount,
                    errorCount: errorCount
                )
            }

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
}

/// A single row in the summarizer activity log.
struct SummarizerActivityRow: View {
    let message: ChannelMessage

    @State private var isExpanded = false

    private var isError: Bool {
        if case .bool(true) = message.metadata?["isError"] { return true }
        return false
    }

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

