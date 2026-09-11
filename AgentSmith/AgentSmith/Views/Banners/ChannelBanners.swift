import SwiftUI
import AgentSmithKit

// MARK: - Shared banner chrome

/// The frame every task-lifecycle banner draws: accent hairlines above and below, a tinted
/// ground, rounded corners, and a header line of icon + headline + optional routing + timestamp.
///
/// Eight banners repeated this same twenty lines verbatim around a one- to six-line body — both
/// hairlines, all three header paddings, the corner radius and the outer vertical padding. What
/// actually differed between them is the parameter list below.
///
/// It deliberately applies NO padding to `content`. The banners do not agree on their body's
/// bottom inset (a title above a markdown block uses 2, a lone body uses 6), so imposing one here
/// would silently reflow half of them.
struct TaskBannerFrame<Content: View>: View {
    let systemImage: String
    var iconFont: Font = AppFonts.bannerIcon
    let headline: String
    let accentColor: Color
    /// "sender → recipient", shown when the banner names who acted on whom.
    var routing: String?
    var groundOpacity: Double = 0.08
    let timestamp: Date
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)
            TaskBannerHeader(
                systemImage: systemImage,
                iconFont: iconFont,
                headline: headline,
                accentColor: accentColor,
                routing: routing,
                timestamp: timestamp
            )
            content
            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(groundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }
}

struct TaskBannerHeader: View {
    let systemImage: String
    let iconFont: Font
    let headline: String
    let accentColor: Color
    let routing: String?
    let timestamp: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(iconFont)
                .foregroundStyle(accentColor)
            Text(headline)
                .font(AppFonts.channelSender)
                .foregroundStyle(accentColor)
            if let routing {
                Text(routing)
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ChannelTimestamp(timestamp: timestamp, bucket: .taskBanner)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// The bolded task title a banner leads its body with.
struct TaskBannerTitleLine: View {
    let title: String
    /// 2 when a body follows, 6 when the title IS the body.
    var bottomPadding: CGFloat = 6

    var body: some View {
        Text(title)
            .font(AppFonts.channelBody.bold())
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, bottomPadding)
    }
}

/// A banner's markdown body.
struct TaskBannerBodyText: View {
    let content: String

    var body: some View {
        MarkdownText(content: content, baseFont: AppFonts.channelBody)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
    }
}

/// The quieter frame — fainter hairlines, a lighter ground and a tighter radius than
/// `TaskBannerFrame`. Used by the banners that report background activity rather than a task
/// lifecycle event, so they recede in a busy transcript.
struct QuietBannerFrame<Content: View>: View {
    let accentColor: Color
    var openingHairlineOpacity: Double = 0.3
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            accentColor.frame(height: 1).opacity(openingHairlineOpacity)
            content
            accentColor.frame(height: 1).opacity(0.3)
        }
        .background(accentColor.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(.vertical, 1)
    }
}

/// The expansion affordance, shown only when there is something to expand.
private struct MemoryBannerChevron: View {
    let isExpandable: Bool
    let isExpanded: Bool

    var body: some View {
        if isExpandable {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(AppFonts.microIcon)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct MemoryBannerHeaderRow: View {
    let iconName: String
    let headerText: String
    let summaryPreview: String
    let accentColor: Color
    let timestamp: Date
    let isExpandable: Bool
    let isExpanded: Bool

    var body: some View {
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
            MemoryBannerChevron(isExpandable: isExpandable, isExpanded: isExpanded)
            ChannelTimestamp(timestamp: timestamp, bucket: .systemMessage, foregroundStyle: .tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// The "Fires <time>" line under a scheduled-action banner's title.
struct ScheduledFiresLine: View {
    let accentColor: Color
    let scheduledRunAt: Date

    var body: some View {
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
    }
}

/// A memory banner's clickable header. Owns nothing — the expansion flag stays with the banner,
/// which is what decides whether the expanded body renders.
private struct MemoryBannerHeaderButton: View {
    let iconName: String
    let headerText: String
    let summaryPreview: String
    let accentColor: Color
    let timestamp: Date
    let isExpandable: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        Button(action: {
            guard isExpandable else { return }
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }, label: {
            MemoryBannerHeaderRow(
                iconName: iconName, headerText: headerText, summaryPreview: summaryPreview,
                accentColor: accentColor, timestamp: timestamp,
                isExpandable: isExpandable, isExpanded: isExpanded
            )
        })
        .buttonStyle(.plain)
    }
}

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

    var body: some View {
        // Compute derived values once at body start
        let _hasContext = memoryCount > 0 || priorTaskCount > 0
        let _hasScheduled = scheduledRunAt != nil
        
        return VStack(spacing: 0) {
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
                .padding(.bottom, (description != nil || _hasContext || _hasScheduled) ? 2 : 6)

            if let description {
                MarkdownText(content: description, baseFont: AppFonts.channelBody.italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, (_hasContext || _hasScheduled) ? 2 : 6)
            }

            // Scheduled-fire chip. Lives in its own band when there's no Context row;
            // when there IS a Context row below, this sits as a complementary row above it.
            if let runAt = scheduledRunAt {
                TaskCreatedBannerScheduledChip(runAt: runAt)
            }

            // Semantic context retrieved at task creation
            if _hasContext {
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
struct ContextEntryView: View {
    let entry: String
    private let headerText: String
    private let bodyText: String
    
    init(entry: String) {
        self.entry = entry
        let split = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        self.headerText = split.first.map(String.init) ?? entry
        self.bodyText = split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headerText)
                .font(AppFonts.inspectorBody.weight(.semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            if !bodyText.isEmpty {
                Text(bodyText)
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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

    var body: some View {
        // Quieter chrome than the lifecycle banners — a fainter closing hairline, a lighter
        // ground and a tighter radius — so this reuses the header and title line rather than
        // `TaskBannerFrame`, which would need four more parameters to express the difference.
        let accentColor = TaskStatusBadge.color(for: .scheduled)
        return QuietBannerFrame(accentColor: accentColor, openingHairlineOpacity: 0.4) {
            TaskBannerHeader(
                systemImage: symbolName, iconFont: AppFonts.bannerIcon,
                headline: "Scheduled \(actionLabel)", accentColor: accentColor,
                routing: nil, timestamp: timestamp
            )
            TaskBannerTitleLine(title: taskTitle, bottomPadding: 2)
            ScheduledFiresLine(accentColor: accentColor, scheduledRunAt: scheduledRunAt)
        }
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
        TaskBannerFrame(
            systemImage: "play.circle.fill",
            headline: "Task Acknowledged",
            accentColor: accentColor,
            timestamp: timestamp
        ) {
            TaskBannerTitleLine(title: title)
        }
    }
}

/// Banner for re-acknowledgement after a rejection (task status returns to running).
/// Visually distinct from `TaskAcknowledgedBanner` so it's obvious this isn't a fresh task.
struct TaskContinuingBanner: View {
    let title: String
    let timestamp: Date

    private let accentColor = AppColors.taskAcknowledgedAccent

    var body: some View {
        TaskBannerFrame(
            systemImage: "arrow.counterclockwise.circle.fill",
            headline: "Continuing Task",
            accentColor: accentColor,
            timestamp: timestamp
        ) {
            TaskBannerTitleLine(title: title)
        }
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
    private let headerText: String
    private let bodyText: String?
    private let accentColor = AppColors.taskReadyForReviewAccent

    init(taskTitle: String, content: String, senderName: String, recipientName: String?, timestamp: Date) {
        self.taskTitle = taskTitle
        self.content = content
        self.senderName = senderName
        self.recipientName = recipientName
        self.timestamp = timestamp
        // Parse content once at init time
        let lines = content.components(separatedBy: "\n")
        let resultIndex = lines.firstIndex(where: { $0.hasPrefix("Result:") })
        if let resultIndex = resultIndex {
            let headerLines = lines[..<resultIndex]
            let bodyLines = lines[resultIndex...]
            self.headerText = headerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyStr = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            self.bodyText = bodyStr.isEmpty ? nil : bodyStr
        } else {
            self.headerText = content
            self.bodyText = nil
        }
    }

    var body: some View {
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

            if !headerText.isEmpty {
                MarkdownText(content: headerText, baseFont: AppFonts.channelBody)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, bodyText == nil ? 6 : 2)
            }

            if let body = bodyText {
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
        TaskBannerFrame(
            systemImage: "arrow.uturn.backward.circle.fill",
            iconFont: AppFonts.bannerIconMedium,
            headline: "Changes Requested",
            accentColor: accentColor,
            routing: recipientName.map { "\(senderName) \u{2192} \($0)" },
            groundOpacity: 0.06,
            timestamp: timestamp
        ) {
            if !taskTitle.isEmpty {
                TaskBannerTitleLine(title: taskTitle, bottomPadding: 2)
            }
            TaskBannerBodyText(content: content)
        }
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

    var body: some View {
        // Inline displayTitle logic
        let displayTitle: String = {
            if taskTitle.count <= Self.maxTitleLength { return taskTitle }
            return String(taskTitle.prefix(Self.maxTitleLength)) + "…"
        }()
        
        return VStack(alignment: .leading, spacing: 0) {
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
        TaskBannerFrame(
            systemImage: "arrow.triangle.2.circlepath",
            iconFont: AppFonts.bannerIconMedium,
            headline: "Task Update",
            accentColor: accentColor,
            routing: recipientName.map { "\(senderName) \u{2192} \($0)" },
            groundOpacity: 0.06,
            timestamp: timestamp
        ) {
            TaskBannerBodyText(content: content)
        }
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

    private var headerText: String {
        switch kind {
        case .saved: return "Memory Saved"
        case .consolidated: return "Memory Consolidated"
        case .searched:
            if memoryCount == 0 && taskCount == 0 { return "Memory Search — no results" }
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

    private var hasExpandableContent: Bool {
        switch kind {
        case .saved, .consolidated:
            return detail != nil && !(detail ?? "").isEmpty
        case .searched:
            return !(memoryResults?.isEmpty ?? true) || !(taskResults?.isEmpty ?? true)
        }
    }

    var body: some View {
        QuietBannerFrame(accentColor: accentColor) {
            MemoryBannerHeaderButton(
                iconName: iconName, headerText: headerText, summaryPreview: summary,
                accentColor: accentColor, timestamp: timestamp,
                isExpandable: hasExpandableContent, isExpanded: $isExpanded
            )
            if isExpanded {
                ExpandedBody(kind: kind, detail: detail, tags: tags,
                             source: source, memoryResults: memoryResults, taskResults: taskResults)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
    }

    private struct ExpandedBody: View {
        let kind: MemoryBanner.Kind
        let detail: String?
        let tags: String?
        let source: String?
        let memoryResults: String?
        let taskResults: String?
        private let memoryEntries: [String]
        private let taskEntries: [String]
        
        init(kind: MemoryBanner.Kind, detail: String?, tags: String?, source: String?, memoryResults: String?, taskResults: String?) {
            self.kind = kind
            self.detail = detail
            self.tags = tags
            self.source = source
            self.memoryResults = memoryResults
            self.taskResults = taskResults
            self.memoryEntries = memoryResults.map { parseContextEntries($0) } ?? []
            self.taskEntries = taskResults.map { parseContextEntries($0) } ?? []
        }
        
        var body: some View {
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
                    if !memoryEntries.isEmpty {
                        Text("Memories")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(Array(memoryEntries.enumerated()), id: \.offset) { idx, entry in
                            ContextEntryDividedRow(entry: entry, showsDivider: idx > 0)
                        }
                    }
                    if !taskEntries.isEmpty {
                        Text("Prior Tasks")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(Array(taskEntries.enumerated()), id: \.offset) { idx, entry in
                            ContextEntryDividedRow(entry: entry, showsDivider: idx > 0)
                        }
                    }
                }
            }
        }
    }
}
