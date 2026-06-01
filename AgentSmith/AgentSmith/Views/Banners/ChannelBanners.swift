import SwiftUI
import AgentSmithKit

/// Visually distinct banner announcing a newly created task in the channel log.
struct TaskCreatedBanner: View {
    let title: String
    let description: String?
    let timestamp: Date
    let contextMemories: String?
    let contextPriorTasks: String?
    let memoryCount: Int
    let priorTaskCount: Int
    /// When non-nil, the task was created with a future `scheduled_run_at`. The banner
    /// renders a clock-icon chip on the right showing when the wake will fire — replaces
    /// the standalone `System ⏰ scheduled …` row that used to follow this banner.
    let scheduledRunAt: Date?

    @State private var isContextExpanded = false

    private let accentColor = AppColors.taskCreatedAccent
    private var hasContext: Bool { memoryCount > 0 || priorTaskCount > 0 }
    private var hasScheduled: Bool { scheduledRunAt != nil }
    /// Color used for the scheduled chip — matches the task list's `.scheduled` styling.
    private var scheduledAccent: Color { TaskStatusBadge.color(for: .scheduled) }

    var body: some View {
        VStack(spacing: 0) {
            // Top rule
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(AppFonts.bannerIcon)
                    .foregroundStyle(accentColor)

                Text("New Task")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                Spacer()

                ChannelTimestamp(timestamp: timestamp, bucket: .taskBanner)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Text(title)
                .font(AppFonts.channelBody.bold())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, (description != nil || hasContext || hasScheduled) ? 2 : 6)

            if let description {
                MarkdownText(content: description, baseFont: AppFonts.channelBody.italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, (hasContext || hasScheduled) ? 2 : 6)
            }

            // Scheduled-fire chip. Lives in its own band when there's no Context row;
            // when there IS a Context row below, this sits as a complementary row above it.
            if let runAt = scheduledRunAt {
                TaskCreatedBannerScheduledChip(runAt: runAt)
            }

            // Semantic context retrieved at task creation
            if hasContext {
                TaskCreatedBannerContextSection(
                    memoryCount: memoryCount,
                    priorTaskCount: priorTaskCount,
                    contextMemories: contextMemories,
                    contextPriorTasks: contextPriorTasks,
                    isExpanded: $isContextExpanded
                )
            }

            // Bottom rule
            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }

}

/// Splits a context metadata string into entries on the ASCII Record Separator (U+001E)
/// that `CreateTaskTool` and `SearchMemoryTool` write between items. Falls back to
/// splitting on newlines for backward compatibility with older persisted messages that
/// pre-date the separator change. Empty entries are dropped.
func parseContextEntries(_ raw: String) -> [String] {
    let parts: [String]
    if raw.contains("\u{1E}") {
        parts = raw.components(separatedBy: "\u{1E}")
    } else {
        parts = raw.components(separatedBy: "\n")
    }
    return parts
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Renders a single context entry as a bold header line followed by an optional body.
/// The header is the first line of the entry; everything after the first newline is body.
/// Used by both `TaskCreatedBanner` (prior tasks) and `MemoryBanner` (search results).
@ViewBuilder
func contextEntryView(_ entry: String) -> some View {
    let split = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    let header = split.first.map(String.init) ?? entry
    let body = split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    VStack(alignment: .leading, spacing: 3) {
        Text(header)
            .font(AppFonts.inspectorBody.weight(.semibold))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
        if !body.isEmpty {
            Text(body)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

/// Compact banner announcing a `schedule_task_action` — replaces the standalone
/// `System ⏰ scheduled …` row with an action-typed banner (pause / stop / summarize /
/// clone & run / run). The icon + label express the action; the right-side chip carries
/// the fire time. Reuses the scheduled-task accent color so it visually relates to the
/// New Task banner's chip and the task list's `.scheduled` styling.
struct TaskActionScheduledBanner: View {
    let actionLabel: String
    let symbolName: String
    let taskTitle: String
    let scheduledRunAt: Date
    let timestamp: Date

    private var accentColor: Color { TaskStatusBadge.color(for: .scheduled) }

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(AppFonts.bannerIcon)
                    .foregroundStyle(accentColor)

                Text("Scheduled \(actionLabel)")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                Spacer()

                ChannelTimestamp(timestamp: timestamp, bucket: .taskBanner)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Text(taskTitle)
                .font(AppFonts.channelBody.bold())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(AppFonts.bannerIconSmall)
                    .foregroundStyle(accentColor)
                Text("Fires \(formatScheduledTime(scheduledRunAt))")
                    .font(AppFonts.channelBody)
                    .foregroundStyle(accentColor)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            accentColor.frame(height: 1).opacity(0.3)
        }
        .background(accentColor.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(.vertical, 1)
    }
}

/// Gold/amber banner marking a task's completion in the channel log.
struct TaskCompletedBanner: View {
    let title: String
    let result: String?
    let durationSeconds: Double?
    let timestamp: Date
    /// Invoked when the user taps the banner's PDF button. `nil` hides the button.
    var onExportPDF: (() -> Void)?

    private let accentColor = AppColors.taskCompletedAccent

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppFonts.bannerIcon)
                    .foregroundStyle(accentColor)

                Text("Task Completed")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                if let duration = durationSeconds {
                    Text("(\(Self.formattedDuration(duration)))")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let onExportPDF {
                    Button(action: onExportPDF, label: {
                        Image(systemName: "doc.richtext")
                            .font(AppFonts.channelTimestamp)
                            .foregroundStyle(accentColor)
                    })
                    .buttonStyle(.plain)
                    .help("Save this task as a PDF")
                }

                ChannelTimestamp(timestamp: timestamp, bucket: .taskBanner)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Text(title)
                .font(AppFonts.channelBody.bold())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, result == nil ? 6 : 4)

            if let result, !result.isEmpty {
                MarkdownText(content: result, baseFont: AppFonts.channelBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        if minutes < 60 {
            return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
    }

}

/// Banner for task_acknowledged messages in the channel log, styled like task created/completed.
struct TaskAcknowledgedBanner: View {
    let title: String
    let timestamp: Date

    private let accentColor = AppColors.taskAcknowledgedAccent

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(AppFonts.bannerIcon)
                    .foregroundStyle(accentColor)

                Text("Task Acknowledged")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                Spacer()

                ChannelTimestamp(timestamp: timestamp, bucket: .taskBanner)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Text(title)
                .font(AppFonts.channelBody.bold())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }
}

/// Banner for re-acknowledgement after a rejection (task status returns to running).
/// Visually distinct from `TaskAcknowledgedBanner` so it's obvious this isn't a fresh task.
struct TaskContinuingBanner: View {
    let title: String
    let timestamp: Date

    private let accentColor = AppColors.taskAcknowledgedAccent

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(AppFonts.bannerIcon)
                    .foregroundStyle(accentColor)

                Text("Continuing Task")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                Spacer()

                ChannelTimestamp(timestamp: timestamp, bucket: .taskBanner)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Text(title)
                .font(AppFonts.channelBody.bold())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }
}

/// Banner for Brown's `task_complete` submission — the task is awaiting Smith's review.
struct TaskReadyForReviewBanner: View {
    let taskTitle: String
    let content: String
    let senderName: String
    let recipientName: String?
    let timestamp: Date

    @State private var isExpanded = false

    private let accentColor = AppColors.taskReadyForReviewAccent

    /// Splits the banner's `content` into (header, body). The header is everything
    /// before the first line that starts with "Result:"; the body is that line and
    /// everything after it. If no "Result:" marker is present, the full content is
    /// treated as the header and the body is nil.
    private var splitContent: (header: String, body: String?) {
        let lines = content.components(separatedBy: "\n")
        guard let resultIndex = lines.firstIndex(where: { $0.hasPrefix("Result:") }) else {
            return (content, nil)
        }
        let headerLines = lines[..<resultIndex]
        let bodyLines = lines[resultIndex...]
        let header = headerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (header, body.isEmpty ? nil : body)
    }

    var body: some View {
        let parts = splitContent
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.up.fill")
                    .font(AppFonts.bannerIconMedium)
                    .foregroundStyle(accentColor)

                Text("Ready for Review")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                if let recipientName {
                    Text("\(senderName) \u{2192} \(recipientName)")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ChannelTimestamp(timestamp: timestamp, bucket: .taskBanner)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if !taskTitle.isEmpty {
                Text(taskTitle)
                    .font(AppFonts.channelBody.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
            }

            if !parts.header.isEmpty {
                MarkdownText(content: parts.header, baseFont: AppFonts.channelBody)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, parts.body == nil ? 6 : 2)
            }

            if let body = parts.body {
                Button(action: { isExpanded.toggle() }) {
                    Text(isExpanded ? "(hide result)" : "(show result)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, isExpanded ? 2 : 6)

                if isExpanded {
                    MarkdownText(content: body, baseFont: AppFonts.channelBody)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
            }

            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }
}

/// Banner for Smith's rejection — feedback sent to Brown with requested changes.
struct ChangesRequestedBanner: View {
    let taskTitle: String
    let content: String
    let senderName: String
    let recipientName: String?
    let timestamp: Date

    private let accentColor = AppColors.changesRequestedAccent

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(AppFonts.bannerIconMedium)
                    .foregroundStyle(accentColor)

                Text("Changes Requested")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                if let recipientName {
                    Text("\(senderName) \u{2192} \(recipientName)")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ChannelTimestamp(timestamp: timestamp, bucket: .taskBanner)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if !taskTitle.isEmpty {
                Text(taskTitle)
                    .font(AppFonts.channelBody.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
            }

            MarkdownText(content: content, baseFont: AppFonts.channelBody)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }
}

/// Compact 1-liner for task summarization events.
struct TaskSummarizedBanner: View {
    let taskTitle: String
    let latencyMs: Int
    let summary: String
    let timestamp: Date

    /// Truncate long task titles so the banner stays one line.
    private static let maxTitleLength = 60

    @State private var isExpanded = false

    private var displayTitle: String {
        if taskTitle.count <= Self.maxTitleLength { return taskTitle }
        return String(taskTitle.prefix(Self.maxTitleLength)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isExpanded.toggle() }, label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(AppFonts.bannerIconSmall)
                        .foregroundStyle(.secondary)

                    Text("Summarized task '\(displayTitle)' in \(latencyMs)ms")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if isExpanded {
                        Text("(show less)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else {
                        Text("(show more)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    Spacer()

                    ChannelTimestamp(timestamp: timestamp, bucket: .taskBanner, foregroundStyle: .tertiary)
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)

            if isExpanded {
                MarkdownText(content: summary, baseFont: AppFonts.channelBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

/// Small banner for task_update messages in the channel log.
struct TaskUpdateBanner: View {
    let content: String
    let senderName: String
    let recipientName: String?
    let timestamp: Date

    private let accentColor = AppColors.taskUpdateAccent

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(AppFonts.bannerIconMedium)
                    .foregroundStyle(accentColor)

                Text("Task Update")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                if let recipientName {
                    Text("\(senderName) \u{2192} \(recipientName)")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ChannelTimestamp(timestamp: timestamp, bucket: .taskBanner)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            MarkdownText(content: content, baseFont: AppFonts.channelBody)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }
}

/// Green mini-banner for memory save/search events in the channel log.
struct MemoryBanner: View {
    enum Kind { case saved, consolidated, searched }

    let kind: Kind
    let summary: String
    let detail: String?
    let tags: String?
    let source: String?
    let timestamp: Date
    var memoryCount: Int = 0
    var taskCount: Int = 0
    /// For `.searched` only — formatted memory result entries joined by `\u{1E}`.
    var memoryResults: String? = nil
    /// For `.searched` only — formatted task summary result entries joined by `\u{1E}`.
    var taskResults: String? = nil

    @State private var isExpanded = false

    private let accentColor: Color = .green

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            accentColor.frame(height: 1).opacity(0.3)

            Button(action: {
                guard hasExpandableContent else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }, label: {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(AppFonts.metaIconSmall)
                        .foregroundStyle(accentColor)

                    Text(headerText)
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(accentColor)

                    Text(summaryPreview)
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if hasExpandableContent {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(AppFonts.microIcon)
                            .foregroundStyle(.tertiary)
                    }

                    ChannelTimestamp(timestamp: timestamp, bucket: .systemMessage, foregroundStyle: .tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            })
            .buttonStyle(.plain)

            if isExpanded {
                expandedBody()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }

            accentColor.frame(height: 1).opacity(0.3)
        }
        .background(accentColor.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(.vertical, 1)
    }

    private var headerText: String {
        switch kind {
        case .saved: return "Memory Saved"
        case .consolidated: return "Memory Consolidated"
        case .searched:
            if memoryCount == 0 && taskCount == 0 {
                return "Memory Search — no results"
            }
            var parts: [String] = []
            if memoryCount > 0 { parts.append("\(memoryCount) memor\(memoryCount == 1 ? "y" : "ies")") }
            if taskCount > 0 { parts.append("\(taskCount) task\(taskCount == 1 ? "" : "s")") }
            return "Memory Search — \(parts.joined(separator: ", "))"
        }
    }

    private var iconName: String {
        switch kind {
        case .saved: return "brain.head.profile"
        case .consolidated: return "arrow.triangle.merge"
        case .searched: return "magnifyingglass"
        }
    }

    /// Single-line preview shown next to the header. Returns the full summary so SwiftUI's
    /// `.lineLimit(1)` can truncate to fit the available width — no arbitrary char cap.
    private var summaryPreview: String {
        summary
    }

    private var hasExpandableContent: Bool {
        switch kind {
        case .saved, .consolidated:
            return detail != nil && !(detail ?? "").isEmpty
        case .searched:
            let hasMemories = !(memoryResults?.isEmpty ?? true)
            let hasTasks = !(taskResults?.isEmpty ?? true)
            return hasMemories || hasTasks
        }
    }

    @ViewBuilder

    private func expandedBody() -> some View {
        switch kind {
        case .saved, .consolidated:
            if let detail, !detail.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail)
                        .font(AppFonts.channelBody)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    if let tags, !tags.isEmpty {
                        Text("Tags: \(tags)")
                            .font(AppFonts.channelTimestamp)
                            .foregroundStyle(.secondary)
                    }
                    if let source, !source.isEmpty {
                        Text("Source: \(source)")
                            .font(AppFonts.channelTimestamp)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .searched:
            VStack(alignment: .leading, spacing: 10) {
                if let memoryResults, !memoryResults.isEmpty {
                    Text("Memories")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    let entries = parseContextEntries(memoryResults)
                    ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                        ContextEntryDividedRow(entry: entry, showsDivider: idx > 0)
                    }
                }
                if let taskResults, !taskResults.isEmpty {
                    Text("Prior Tasks")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    let entries = parseContextEntries(taskResults)
                    ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                        ContextEntryDividedRow(entry: entry, showsDivider: idx > 0)
                    }
                }
            }
        }
    }

}
