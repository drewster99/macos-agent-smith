import SwiftUI
import AgentSmithKit

/// The time-of-day portion of a transcript timestamp: 12-hour with seconds and lowercase am/pm,
/// e.g. "3:19:07pm". Used on its own for today's messages and as the tail of the relative-date form
/// for older ones (see `transcriptTimestampString`). All four formatters pin `en_US_POSIX` + Gregorian
/// so the fixed English format renders identically under every user locale/calendar (a fixed
/// `dateFormat` under a non-POSIX locale localizes month/weekday names and can print a non-Gregorian
/// year — e.g. 2569 in a Buddhist calendar — welded onto the force-English am/pm time).
private let sharedTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.amSymbol = "am"
    f.pmSymbol = "pm"
    f.dateFormat = "h:mm:ssa"
    return f
}()

/// Weekday name for a message 2–6 days old, e.g. "Friday".
private let transcriptWeekdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "EEEE"
    return f
}()

/// Month/day for an older message in the current year, e.g. "Sun Jul 14".
private let transcriptDateThisYearFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "EEE MMM d"
    return f
}()

/// Month/day/year for an older message from a previous year, e.g. "Sun Jul 14 2025".
private let transcriptDateOtherYearFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "EEE MMM d yyyy"
    return f
}()

/// A transcript timestamp that only spends characters on a date when it isn't today's. Today shows the
/// bare time ("3:19:07pm"); yesterday and the last few days get a relative-day prefix ("Yesterday,
/// 3:19:07pm" / "Friday, 5:15:32am"); anything older gets a dated prefix, with the year appended only
/// when it differs from now ("Sun Jul 14, 2:06:55pm"). `now` is a parameter so the mapping is pure and
/// testable — production reads the clock, tests pin it.
func transcriptTimestampString(for date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let time = sharedTimestampFormatter.string(from: date)

    // ONE day-bucket decision, every bucket measured against the injected `now` (not the ambient
    // clock), so pinning `now` fully determines the output — the purity the doc comment promises.
    // `dateComponents(.day)` over start-of-day is calendar arithmetic (correct across DST) and yields
    // the SIGNED day gap: a future `date` is negative, so it falls through to the dated form rather
    // than landing in a wrong bucket.
    let startOfDate = calendar.startOfDay(for: date)
    let startOfNow = calendar.startOfDay(for: now)
    guard let daysApart = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day else {
        return datedTranscriptTimestamp(for: date, now: now, time: time)
    }

    switch daysApart {
    case 0:
        return time
    case 1:
        return "Yesterday, \(time)"
    case 2...6:
        return "\(transcriptWeekdayFormatter.string(from: date)), \(time)"
    default:
        return datedTranscriptTimestamp(for: date, now: now, time: time)
    }
}

/// The Gregorian calendar the year-suffix decision is made in, so it agrees with the pinned-Gregorian
/// date formatters. Deciding "same year" in `Calendar.current` (e.g. Hebrew/Islamic) while rendering a
/// Gregorian date can drop the year on a genuinely older message, or print a redundant one.
private let transcriptGregorianCalendar = Calendar(identifier: .gregorian)

/// The fully-dated form ("Sun Jul 14, 3:19:07pm"), with the year appended only when `date`'s year
/// differs from `now`'s. Shared by the older-than-a-week branch and the defensive nil-gap branch.
private func datedTranscriptTimestamp(for date: Date, now: Date, time: String) -> String {
    let sameYear = transcriptGregorianCalendar.isDate(date, equalTo: now, toGranularity: .year)
    let datePart = sameYear
        ? transcriptDateThisYearFormatter.string(from: date)
        : transcriptDateOtherYearFormatter.string(from: date)
    return "\(datePart), \(time)"
}

/// Display preferences for the channel log — purely cosmetic toggles read from the global
/// `SharedAppState` and threaded down through the SwiftUI environment so each banner / row
/// can decide whether to render its timestamp without a per-init parameter.
struct TimestampPreferences: Equatable, Sendable {
    /// Show timestamps on task lifecycle banners (created, acknowledged, completed, etc.).
    var taskBanners: Bool
    /// Show timestamps on tool-call rows.
    var toolCalls: Bool
    /// Show timestamps on agent↔agent and agent↔user message rows.
    var messaging: Bool
    /// Show timestamps on system-sender rows and system-feedback banners (memory, timer activity).
    var systemMessages: Bool
    /// Show elapsed time (request → output) on completed tool calls.
    var elapsedTimeOnToolCalls: Bool
    /// Render transient lifecycle rows ("All agents stopped", "System online. Smith agent
    /// active."). When false, these are suppressed from the transcript even though the
    /// runtime still emits them — useful for keeping the channel log focused on actual work.
    var showRestartChrome: Bool

    /// Defaults used when the channel log is rendered without an explicit preferences
    /// injection (e.g. SwiftUI previews).
    static let `default` = TimestampPreferences(
        taskBanners: true,
        toolCalls: true,
        messaging: true,
        systemMessages: true,
        elapsedTimeOnToolCalls: false,
        showRestartChrome: false
    )

    /// Manual nonisolated `==` so this can be compared from `ChannelLogView`'s `nonisolated`
    /// `Equatable` conformance — synthesized Equatable picks up the surrounding @MainActor
    /// isolation in this file and would refuse to be called from a nonisolated context.
    nonisolated static func == (lhs: TimestampPreferences, rhs: TimestampPreferences) -> Bool {
        lhs.taskBanners == rhs.taskBanners
        && lhs.toolCalls == rhs.toolCalls
        && lhs.messaging == rhs.messaging
        && lhs.systemMessages == rhs.systemMessages
        && lhs.elapsedTimeOnToolCalls == rhs.elapsedTimeOnToolCalls
        && lhs.showRestartChrome == rhs.showRestartChrome
    }
}

private struct TimestampPreferencesKey: EnvironmentKey {
    static let defaultValue = TimestampPreferences.default
}

extension EnvironmentValues {
    /// Read the channel log's timestamp / elapsed-time toggles. Set by `ChannelLogView`
    /// from `SharedAppState`; default keeps timestamps on for previews.
    var timestampPreferences: TimestampPreferences {
        get { self[TimestampPreferencesKey.self] }
        set { self[TimestampPreferencesKey.self] = newValue }
    }
}

/// Formats an elapsed `TimeInterval` as a compact tool-call duration: sub-second values
/// in milliseconds (e.g. `420ms`), 1–60s with one decimal (`12.4s`), and longer durations
/// as `Xm Ys`. Stays terse so it fits next to the tool name without wrapping the row.
func formatToolCallElapsed(_ seconds: TimeInterval) -> String {
    if seconds < 0 { return "" }
    if seconds < 1 { return "\(Int(seconds * 1000))ms" }
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return "\(mins)m \(secs)s"
}

/// Which user-controlled toggle gates a given timestamp render.
enum TimestampBucket {
    case taskBanner
    case systemMessage
    case messaging
    case toolCall
}

/// Renders a channel-log timestamp, gated by the matching user preference. Centralizes the
/// font + colour treatment so banners and rows can swap it in without duplicating modifiers.
struct ChannelTimestamp: View {
    let timestamp: Date
    let bucket: TimestampBucket
    /// Hierarchical foreground style — `.secondary` for most banners, `.tertiary` for
    /// MemoryBanner where the timestamp sits next to a chevron and benefits from a softer tone.
    var foregroundStyle: HierarchicalShapeStyle = .secondary

    @Environment(\.timestampPreferences) private var prefs
    
    /// Determines if this timestamp should be visible based on its bucket and current preferences.
    /// Computed as a separate property to avoid closure execution in body.
    private var isVisible: Bool {
        switch bucket {
        case .taskBanner: return prefs.taskBanners
        case .systemMessage: return prefs.systemMessages
        case .messaging: return prefs.messaging
        case .toolCall: return prefs.toolCalls
        }
    }
    
    var body: some View {
        if isVisible {
            Text(transcriptTimestampString(for: timestamp))
                .font(AppFonts.channelTimestamp)
                .foregroundStyle(foregroundStyle)
        }
    }
}

/// Discriminator for the channel log's banner family, mapped from the message's typed
/// `ChannelMessageKind` (`init?(_:)`) — never from its wire string, so a renamed wire string can't
/// silently stop a banner from rendering.
///
/// Replaces a 16-branch `else if case .string(let kind) = message.metadata?["messageKind"]`
/// ladder. Adding a new banner kind now means adding a case here, its arm in `init?(_:)`, AND a
/// switch arm in `ChannelMessageBanner.body` — all fail at compile time if forgotten, instead of silently
/// falling through to a generic `MessageRow`.
private enum ChannelBannerKind {
    /// Lifecycle chrome. Gets a row only when "Show agent restart chrome" is on (`TranscriptRows`).
    case restartChrome
    /// Timer activity. A "scheduled" row its task's banner repeats gets no row (`TranscriptRows`).
    case timerActivity
    /// Internal Smith guidance. Never gets a row (`TranscriptRows`).
    case taskUpdateGuidance
    case taskAcknowledged
    case taskContinuing
    case taskComplete
    case changesRequested
    case taskActionScheduled
    case taskCreated
    case taskUpdate
    case taskCompleted
    case taskSummarized
    case memorySaved
    case memorySearched
    /// An MCP server failed to load — rendered as a clickable banner that opens Settings.
    case mcpFailed
    /// The user paused/stopped/deleted/retried a task — a system row with an inline control.
    case userTaskAction

    /// The banner a message of `kind` renders as, or nil for a plain row. Exhaustive over every
    /// message kind on purpose: a new kind must be placed here, not defaulted.
    init?(_ kind: ChannelMessageKind) {
        switch kind {
        case .restartChrome: self = .restartChrome
        case .timerActivity: self = .timerActivity
        case .taskUpdateGuidance: self = .taskUpdateGuidance
        case .taskAcknowledged: self = .taskAcknowledged
        case .taskContinuing: self = .taskContinuing
        case .taskComplete: self = .taskComplete
        case .changesRequested: self = .changesRequested
        case .taskActionScheduled: self = .taskActionScheduled
        case .taskCreated: self = .taskCreated
        case .taskUpdate: self = .taskUpdate
        case .taskCompleted: self = .taskCompleted
        case .taskSummarized: self = .taskSummarized
        case .memorySaved: self = .memorySaved
        case .memorySearched: self = .memorySearched
        case .mcpStatus: self = .mcpFailed
        case .userTaskAction: self = .userTaskAction
        case .toolRequest, .toolOutput, .securityReview, .toolScopeReview, .taskFailed, .taskQueuedAtCapacity,
             .taskLifecycle, .scheduledRunDeferred, .scheduledRunRefused, .taskAmendment, .taskWatchFired,
             .taskWatchRefused, .criteriaUpdated, .validationReport, .validationFailed, .validationEscalation,
             .validationDeadlock, .taskBlocked, .userAcceptanceRequested, .submissionAutoRejected,
             .validationBlocked, .validationBlockedWorkerNotice, .orchestratorMessage, .helpRequested,
             .helpProvided, .inboundUserMessage, .contextManagement, .preparing, .agentLifecycle,
             .agentRecovery, .rateLimit, .statusUpdate, .advisory, .modelSwitched, .childTaskOutcome,
             .agentOnline, .validationWaitNotice, .validationOverride, .taskInterrupted:
            return nil
        }
    }
}

/// A `.userTaskAction` notice: the ordinary message row, plus the inline control the notice's
/// task currently supports (Resume a paused/stopped task, Undelete a deleted one).
private struct UserTaskActionNoticeRow: View {
    let message: ChannelMessage
    let displayPrefs: TimestampPreferences
    @Binding var selectedImageAttachment: Attachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MessageRow(
                message: message,
                securityReviewMessage: nil,
                toolOutputMessage: nil,
                displayPrefs: displayPrefs,
                selectedImageAttachment: $selectedImageAttachment
            )
            .equatable()
            UserTaskActionInlineControl(notice: message.userTaskAction, taskID: message.taskID)
        }
    }
}

private struct UserTaskActionInlineControl: View {
    let notice: UserTaskAction?
    let taskID: UUID?
    @Environment(\.transcriptTaskActionHandler) private var handler

    var body: some View {
        if let notice, let taskID, let action = handler.availableAction(notice, taskID) {
            Button(action: { Task { await handler.perform(action, taskID) } }, label: {
                Label(action.title, systemImage: action.symbolName)
            })
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.leading, 8)
        }
    }
}

/// Color-coded scrolling message stream with attachment display.
///
/// The rows live in an AppKit table (`TranscriptTableView`), not a SwiftUI stack: only the rows on
/// screen exist as views, so scrolling costs the same at 50 messages as at 5,000. Every earlier
/// shape — a non-lazy `VStack` behind a sliding 400/3,000-row window — paid layout for the whole
/// window on every append and scroll, and each round of per-row tuning was undone by the next
/// feature. See `docs/plans/TranscriptScrollPerformance.md`.
struct ChannelLogView: View, Equatable {
    var messages: [ChannelMessage]
    var persistedHistoryCount: Int
    var hasRestoredHistory: Bool
    var onRestoreHistory: () -> Void
    /// Invoked when the user taps the PDF button on a "Task Completed" banner. Carries the
    /// banner's task id plus its own fields so the handler can fall back to them when the
    /// underlying task has been permanently deleted.
    var onExportTaskPDF: (_ taskID: UUID, _ title: String, _ result: String?, _ timestamp: Date) -> Void
    /// Invoked when the user clicks an MCP-server-failed banner to open Settings → MCP Servers.
    var onOpenMCPSettings: () -> Void
    /// Display toggles handed to every row.
    var displayPrefs: TimestampPreferences
    /// The pane's own filter. The pane is DELIVERED some verdicts its settings hide (so a tool call
    /// keeps its status icon); this says which ones it actually shows — their inline text, and
    /// whether one whose call isn't shown gets a row of its own.
    var verdictFilter: TranscriptFilter = .all
    /// A Debug-menu request to benchmark this pane's scrolling; runs once per new request.
    var scrollBenchmarkRequest: TranscriptScrollBenchmarkRequest? = nil
    /// The attachment currently shown in the full-screen image viewer, managed by the parent.
    @Binding var selectedImageAttachment: Attachment?

    /// Rows are hosted by AppKit, outside this view's SwiftUI environment, so every custom value a
    /// row reads is carried across explicitly in `TranscriptRowContext`.
    @Environment(\.transcriptTaskActionHandler) private var taskActionHandler
    @Environment(\.attachmentBytesLoader) private var attachmentBytesLoader

    @State private var isAtBottom = true
    @State private var scrollController = TranscriptScrollController()

    /// Prevents body re-evaluation when only unrelated parent properties change (e.g. inputText).
    /// Closures and the Binding are excluded — they can't be meaningfully compared, and their
    /// captures are session-stable here (the per-session `viewModel` is created once by
    /// `SessionManager` and never swapped under a live view).
    ///
    /// CORRECTNESS INVARIANT: assumes `messages` is append-only at the end and trimmed only at the
    /// front. Count + first.id + last.id detects every change under that rule because existing
    /// elements are never mutated in place.
    nonisolated static func == (lhs: ChannelLogView, rhs: ChannelLogView) -> Bool {
        lhs.messages.count == rhs.messages.count
        && lhs.messages.first?.id == rhs.messages.first?.id
        && lhs.messages.last?.id == rhs.messages.last?.id
        && lhs.persistedHistoryCount == rhs.persistedHistoryCount
        && lhs.hasRestoredHistory == rhs.hasRestoredHistory
        && lhs.displayPrefs == rhs.displayPrefs
        && lhs.verdictFilter == rhs.verdictFilter
        && lhs.scrollBenchmarkRequest == rhs.scrollBenchmarkRequest
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TranscriptTableView(
                messages: messages,
                options: TranscriptRows.Options(
                    verdictFilter: verdictFilter,
                    showsRestartChrome: displayPrefs.showRestartChrome
                ),
                restorableHistoryCount: hasRestoredHistory ? 0 : persistedHistoryCount,
                rowContext: TranscriptRowContext(
                    displayPrefs: displayPrefs,
                    taskActionHandler: taskActionHandler,
                    attachmentBytesLoader: attachmentBytesLoader,
                    onRestoreHistory: onRestoreHistory,
                    onExportTaskPDF: onExportTaskPDF,
                    onOpenMCPSettings: onOpenMCPSettings,
                    selectedImageAttachment: $selectedImageAttachment
                ),
                scrollController: scrollController,
                onAtBottomChange: { isAtBottom = $0 }
            )
            .background(AppColors.channelBackground)

            if !isAtBottom {
                ChannelLogScrollToBottomButton(onTap: { scrollController.scrollToBottom(animated: true) })
            }
        }
        .onChange(of: scrollBenchmarkRequest) { _, request in
            guard request != nil else { return }
            scrollController.runScrollBenchmark(completion: TranscriptScrollBenchmarkReporter.report)
        }
        // GREEDY, and load-bearing: without it the pane is sized by whatever it happens to be
        // showing — a short transcript rendered as a ribbon floating in the middle of the pane, and
        // a long URL demanded its width from the whole window. Same defect, same fix as
        // `ModelMetadataInspectorWindow`'s split.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Everything a transcript row needs from outside the row itself. Rows are hosted in AppKit cells,
/// so the SwiftUI environment of `ChannelLogView` does NOT reach them; this is how it crosses.
struct TranscriptRowContext {
    let displayPrefs: TimestampPreferences
    let taskActionHandler: TranscriptTaskActionHandler
    let attachmentBytesLoader: (@Sendable (UUID, String) async -> Data?)?
    let onRestoreHistory: () -> Void
    let onExportTaskPDF: (UUID, String, String?, Date) -> Void
    let onOpenMCPSettings: () -> Void
    let selectedImageAttachment: Binding<Attachment?>
}

/// What one table row shows: the "restore full history" affordance, or a message row.
enum TranscriptDisplayRow {
    case restoreHistory(count: Int)
    case message(TranscriptRow)

    var key: Key {
        switch self {
        case .restoreHistory: return .restoreHistory
        case .message(let row): return .message(row.id)
        }
    }

    enum Key: Hashable {
        case restoreHistory
        case message(UUID)
    }
}

/// The SwiftUI content of one table row, with the context the AppKit host carries across.
struct TranscriptRowContent: View {
    let row: TranscriptDisplayRow
    let context: TranscriptRowContext

    var body: some View {
        TranscriptRowBody(row: row, context: context)
            .environment(\.timestampPreferences, context.displayPrefs)
            .environment(\.transcriptTaskActionHandler, context.taskActionHandler)
            .environment(\.attachmentBytesLoader, context.attachmentBytesLoader)
    }
}

private struct TranscriptRowBody: View {
    let row: TranscriptDisplayRow
    let context: TranscriptRowContext

    var body: some View {
        switch row {
        case .restoreHistory(let count):
            ChannelLogRestoreHistoryButton(persistedHistoryCount: count,
                                           onRestoreHistory: context.onRestoreHistory)
        case .message(let transcriptRow):
            ChannelMessageBanner(
                row: transcriptRow,
                displayPrefs: context.displayPrefs,
                onExportTaskPDF: context.onExportTaskPDF,
                onOpenMCPSettings: context.onOpenMCPSettings,
                selectedImageAttachment: context.selectedImageAttachment
            )
        }
    }
}

/// Renders a channel message as the appropriate banner or row based on its messageKind metadata.
/// Replaces the `bannerView(for:reviewLookup:outputLookup:scheduledTaskBannerIDs:)` function.
private struct ChannelMessageBanner: View {
    let row: TranscriptRow
    let displayPrefs: TimestampPreferences
    let onExportTaskPDF: (UUID, String, String?, Date) -> Void
    let onOpenMCPSettings: () -> Void
    @Binding var selectedImageAttachment: Attachment?
    
    private var message: ChannelMessage { row.message }

    var body: some View {
        // Mapped from the typed kind; only the kinds that render as banners have a case. Whether a
        // message gets a row at all — guidance, hidden restart chrome, a timer row its task's
        // banner repeats — is decided once, by `TranscriptRows`, before it gets here.
        let kind = message.kind.flatMap(ChannelBannerKind.init)
        switch kind {
        case .taskUpdateGuidance:
            // Never a row (`TranscriptRows`); the case exists because the switch is exhaustive.
            EmptyView()
        case .restartChrome:
            // Rendered as a centered marker, not a chat row, so it reads as a lifecycle event.
            LifecycleChromeBanner(message: message)
        case .timerActivity:
            TranscriptMessageRow(row: row, displayPrefs: displayPrefs,
                                 selectedImageAttachment: $selectedImageAttachment)
        case .taskAcknowledged:
            TaskAcknowledgedBanner(
                title: message.content,
                timestamp: message.timestamp
            )
        case .taskContinuing:
            TaskContinuingBanner(
                title: message.content,
                timestamp: message.timestamp
            )
        case .taskComplete:
            TaskReadyForReviewBanner(
                taskTitle: message.stringMetadata("taskTitle") ?? "",
                content: message.content,
                senderName: message.sender.displayName,
                recipientName: message.recipient?.displayName,
                timestamp: message.timestamp
            )
        case .changesRequested:
            ChangesRequestedBanner(
                taskTitle: message.stringMetadata("taskTitle") ?? "",
                content: message.content,
                senderName: message.sender.displayName,
                recipientName: message.recipient?.displayName,
                timestamp: message.timestamp
            )
        case .taskActionScheduled:
            let actionRaw = message.stringMetadata("actionKind") ?? "run"
            let action = TaskActionKind(lenient: actionRaw) ?? .run
            TaskActionScheduledBanner(
                actionLabel: action.bannerLabel,
                symbolName: action.bannerSymbolName,
                taskTitle: message.stringMetadata("taskTitle") ?? message.content,
                scheduledRunAt: message.doubleMetadata("scheduledRunAt").map { Date(timeIntervalSince1970: $0) } ?? message.timestamp,
                timestamp: message.timestamp
            )
        case .taskCreated:
            TaskCreatedBanner(
                title: message.content,
                description: message.stringMetadata("taskDescription"),
                requiredCapabilities: message.stringMetadata("requiredCapabilities"),
                timestamp: message.timestamp,
                contextMemories: message.stringMetadata("contextMemories"),
                contextPriorTasks: message.stringMetadata("contextPriorTasks"),
                memoryCount: message.intMetadata("contextMemoryCount") ?? 0,
                priorTaskCount: message.intMetadata("contextPriorTaskCount") ?? 0,
                scheduledRunAt: message.doubleMetadata("scheduledRunAt").map { Date(timeIntervalSince1970: $0) }
            )
        case .taskUpdate:
            TaskUpdateBanner(
                content: message.content,
                senderName: message.sender.displayName,
                recipientName: message.recipient?.displayName,
                timestamp: message.timestamp
            )
        case .taskCompleted:
            let completedResult = message.stringMetadata("taskResult")
            let completedTaskID = message.stringMetadata("taskID").flatMap { UUID(uuidString: $0) }
            TaskCompletedBanner(
                title: message.content,
                result: completedResult,
                durationSeconds: message.doubleMetadata("durationSeconds"),
                timestamp: message.timestamp,
                onExportPDF: completedTaskID.map { taskID in
                    { onExportTaskPDF(taskID, message.content, completedResult, message.timestamp) }
                }
            )
        case .taskSummarized:
            TaskSummarizedBanner(
                taskTitle: message.stringMetadata("taskTitle") ?? "task",
                latencyMs: message.intMetadata("latencyMs") ?? 0,
                summary: message.content,
                timestamp: message.timestamp
            )
        case .memorySaved:
            let isConsolidated = message.boolMetadata("consolidated") ?? false
            MemoryBanner(
                kind: isConsolidated ? .consolidated : .saved,
                summary: message.content,
                detail: message.stringMetadata("memoryContent"),
                tags: message.stringMetadata("memoryTags"),
                source: message.stringMetadata("memorySource"),
                timestamp: message.timestamp
            )
        case .memorySearched:
            MemoryBanner(
                kind: .searched,
                // Smith's automatic search-on-the-user's-message echoes the message shown right
                // above it, so suppress the query preview for those; explicit `search_memory`
                // calls still show what was searched.
                summary: message.boolMetadata("autoSearch") == true ? "" : (message.stringMetadata("searchQuery") ?? message.content),
                detail: nil,
                tags: nil,
                source: nil,
                timestamp: message.timestamp,
                memoryCount: message.intMetadata("memoryCount") ?? 0,
                taskCount: message.intMetadata("taskCount") ?? 0,
                memoryResults: message.stringMetadata("memoryResults"),
                taskResults: message.stringMetadata("taskResults")
            )
        case .mcpFailed:
            MCPFailedBanner(
                content: message.content,
                timestamp: message.timestamp,
                onOpenSettings: onOpenMCPSettings
            )
        case .userTaskAction:
            UserTaskActionNoticeRow(
                message: message,
                displayPrefs: displayPrefs,
                selectedImageAttachment: $selectedImageAttachment
            )
        case .none:
            // Plain message — fall through to the generic row.
            TranscriptMessageRow(row: row, displayPrefs: displayPrefs,
                                 selectedImageAttachment: $selectedImageAttachment)
        }
    }
}

/// The generic message row, with the row's folded-in verdict and output.
private struct TranscriptMessageRow: View {
    let row: TranscriptRow
    let displayPrefs: TimestampPreferences
    @Binding var selectedImageAttachment: Attachment?

    var body: some View {
        MessageRow(
            message: row.message,
            securityReviewMessage: row.securityReview,
            toolOutputMessage: row.toolOutput,
            showsSecurityReviewText: row.showsSecurityReviewText,
            displayPrefs: displayPrefs,
            selectedImageAttachment: $selectedImageAttachment
        )
        .equatable()
    }
}

/// Banner shown when an MCP server fails to load. The whole row is a button that opens
/// Settings → MCP Servers, where the full error/stderr is available.
private struct MCPFailedBanner: View {
    let content: String
    let timestamp: Date
    let onOpenSettings: () -> Void

    var body: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text("Open MCP Server settings")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

private struct MessageRow: View, Equatable {
    /// (old_string, new_string) extracted from a `file_edit` tool call's params.
    /// Wrapped in a struct so it's `Equatable` for `@State` storage.
    fileprivate struct FileEditStrings: Equatable {
        let oldString: String
        let newString: String
    }

    let message: ChannelMessage
    /// Pre-looked-up security review for this message's requestID (nil if none).
    let securityReviewMessage: ChannelMessage?
    /// Pre-looked-up tool output for this message's requestID (nil if none).
    let toolOutputMessage: ChannelMessage?
    /// Whether the pane's settings show `securityReviewMessage` — gates only the verdict's inline
    /// TEXT. The status icon and its popover always render: they are part of the tool call.
    var showsSecurityReviewText = true
    /// Display preferences. Passed in as a `let` rather than read via `@Environment` so
    /// that it participates in `==` below — `EquatableView`'s cache shortcut would
    /// otherwise prevent body re-evaluation when only the env-injected prefs change,
    /// stranding the previous timestamp-visibility decision in the cached output.
    let displayPrefs: TimestampPreferences
    @Binding var selectedImageAttachment: Attachment?

    @State private var isExpanded = false
    @State private var isHovering = false
    /// Drives the popover shown when the security-disposition indicator (the ✅/⚠️/🚫) is clicked.
    @State private var showSecurityPopover = false

    /// Pre-decoded fields cached on the row so that `body` doesn't re-parse JSON or
    /// re-split the message content on every re-evaluation. Populated by the
    /// `.onChange(of: message, initial: true)` modifier on `body`; before that fires
    /// the body falls back to a synchronous compute via the `effective*` properties
    /// below, which avoids a one-frame flicker on first appearance (visible in the
    /// summarizer-truncation, tool-path, and inline-diff branches).
    @State private var cachedToolFilePath: String? = nil
    @State private var cachedDiffLines: [DiffLine]? = nil
    @State private var cachedFileEditStrings: FileEditStrings? = nil
    @State private var cachedSplitLines: [String] = []
    /// Set true once `.onChange(initial: true)` has populated the four caches above.
    /// Until then, the `effective*` properties recompute synchronously inside body so
    /// the first render shows the correct decoration / truncation state.
    @State private var cacheValid: Bool = false

    /// Skips body re-evaluation when the row's source data is unchanged. Without this,
    /// every existing row re-evaluates whenever `ChannelLogView` re-runs (i.e. on every
    /// appended message), which fans out the per-row JSON decoding / line-splitting
    /// work above into an O(N²) wall. `displayPrefs` is included so runtime toggles of
    /// timestamp visibility cascade to existing rows — see comment on the field.
    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
        && lhs.securityReviewMessage == rhs.securityReviewMessage
        && lhs.toolOutputMessage == rhs.toolOutputMessage
        && lhs.showsSecurityReviewText == rhs.showsSecurityReviewText
        && lhs.displayPrefs == rhs.displayPrefs
    }









































    var body: some View {
        // Compute all derived values INLINE at body start - no computed property accessors
        // Expensive ops use @State caches (cacheValid), simple ops compute directly
        
        let _senderColor = AppColors.color(for: message.author)
        let _recipientColor: Color = {
            guard let recipient = message.recipient else { return .secondary }
            switch recipient {
            case .agent(let role): return AppColors.color(for: .agent(role))
            case .user: return AppColors.color(for: .user)
            }
        }()
        let _hidesPrivateRecipientAnnotation: Bool = {
            if case .user = message.sender { return true }
            if case .user = message.recipient { return true }
            return false
        }()
        let _shouldShowTimestamp: Bool = {
            if message.kind == .toolRequest { return displayPrefs.toolCalls }
            if case .system = message.sender { return displayPrefs.systemMessages }
            return displayPrefs.messaging
        }()
        let _isToolRequest: Bool = message.kind == .toolRequest
        let _toolCallElapsedSeconds: TimeInterval? = {
            guard let output = toolOutputMessage else { return nil }
            let elapsed = output.timestamp.timeIntervalSince(message.timestamp)
            return elapsed >= 0 ? elapsed : nil
        }()
        let _isFileWrite = message.stringMetadata("tool") == "file_write"
        let _parallelBadge: String? = {
            guard case .int(let count) = message.metadata?["parallelCount"], count > 1,
                  case .int(let index) = message.metadata?["parallelIndex"] else { return nil }
            return "\(index + 1)/\(count)"
        }()
        let _dispositionComment: String? = {
            guard showsSecurityReviewText, let review = securityReviewMessage,
                  case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
            switch d {
            case "autoApproved": return nil
            case "warning", "denied", "abort", "unavailable", "cancelled":
                if case .string(let msg) = review.metadata?["dispositionMessage"], !msg.isEmpty {
                    return msg
                }
                return nil
            default: return nil
            }
        }()
        let _dispositionCommentColor: Color = {
            guard let review = securityReviewMessage,
                  case .string(let d) = review.metadata?["securityDisposition"] else { return .secondary }
            switch d {
            case "autoApproved": return AppColors.securityApproved
            case "warning": return AppColors.securityWarning
            case "denied", "unavailable", "cancelled": return AppColors.securityDenied
            case "abort": return AppColors.securityAbort
            default: return .secondary
            }
        }()
        let _effectiveDiffLines: [DiffLine]? = cachedDiffLines
        let _effectiveToolFilePath: String? = cachedToolFilePath
        let _effectiveFileEditStrings: FileEditStrings? = cachedFileEditStrings
        let _fileEditFailed: Bool = {
            guard let output = toolOutputMessage else { return false }
            let content = output.content.trimmingCharacters(in: .whitespaces)
            return !content.hasPrefix("Successfully")
        }()
        let _isFileRead = message.stringMetadata("tool") == "file_read"
        let _toolCallDisplayText: String = {
            let toolCallTruncationLimit = 200
            let isTruncatable = message.content.count > toolCallTruncationLimit
            if !isTruncatable || isExpanded { return message.content }
            return String(message.content.prefix(toolCallTruncationLimit)) + "…"
        }()
        let _remainderWithoutPath: (String, String) -> String = { displayText, path in
            let toolName = message.stringMetadata("tool") ?? displayText.prefix(while: { $0 != ":" }).description
            var text = displayText
            if text.hasPrefix(toolName) {
                text = String(text.dropFirst(toolName.count))
                if text.hasPrefix(": ") { text = String(text.dropFirst(2)) }
            }
            text = text.replacingOccurrences(of: path, with: "")
            text = text.replacingOccurrences(of: ", ,", with: ",")
            return text.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        }
        let _isToolOutput = message.kind == .toolOutput
        let _isSecurityReview = message.metadata?["securityDisposition"] != nil
        let _securityReviewColor: Color = {
            guard let review = securityReviewMessage,
                  case .string(let disposition) = review.metadata?["securityDisposition"] else { return .secondary }
            switch disposition {
            case "approved", "autoApproved": return AppColors.securityApproved
            case "warning": return AppColors.securityWarning
            case "denied": return AppColors.securityDenied
            case "abort": return AppColors.securityAbort
            default: return .secondary
            }
        }()
        let _defaultMaxLines: Int? = {
            let isSummarizer = message.sender == .agent(.summarizer)
            let isSmithToBrown: Bool = {
                guard case .agent(.smith) = message.sender else { return false }
                guard case .agent(.brown) = message.recipient else { return false }
                return true
            }()
            let isBrown: Bool = message.sender == .agent(.brown)
            if isSummarizer { return 2 }
            if isSmithToBrown || isBrown { return 5 }
            return nil
        }()
        let _effectiveSplitLines = cachedSplitLines
        let _isSummarizerMessage = message.sender == .agent(.summarizer)
        let _attachmentTier: ImageCache.Tier = message.sender == .user ? .small : .medium
        // Reads the accessor, never the raw metadata: producers write `severity` now, and this
        // hand-rolled `isError` unwrap stopped matching any of them — the row still appeared
        // (the filter floor sees severity) but lost its error background, which is the one thing
        // that makes it findable in a long transcript.
        let _isSmithToUser: Bool = {
            guard case .agent(.smith) = message.sender else { return false }
            guard case .user = message.recipient else { return false }
            return true
        }()
        // The severity of the security review attached to THIS row — a different message, whose
        // outcome colours the tool row it judged. Not expressible as this row's own severity (a
        // tool_request is not itself an error), and read through the accessor so current and
        // legacy review rows map identically.
        let _reviewSeverity: MessageSeverity = securityReviewMessage?.severity ?? .info
        let _dispositionIndicator: String? = {
            guard let review = securityReviewMessage,
                  case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
            switch d {
            case "approved": return "\u{2705}"
            case "autoApproved": return "\u{2699}\u{FE0F}"
            case "warning": return "\u{26A0}\u{FE0F}"
            case "denied": return "\u{1F6AB}"
            // Blocked, but not judged — a distinct glyph so an outage never reads as a refusal.
            // "cancelled" previously had a `return nil` arm here that no producer ever reached:
            // the evaluator set the flag, but the channel renderer never wrote the tag, so a
            // cancelled review reached this switch tagged "denied". It is a real blocked state and
            // now gets the blocked glyph rather than disappearing.
            case "unavailable", "cancelled": return "\u{26D4}"
            case "abort": return "\u{1F6D1}"
            default: return nil
            }
        }()
        let _dispositionTooltipText: String? = {
            guard let review = securityReviewMessage,
                  case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
            switch d {
            case "approved": return "Safety: Approved"
            case "autoApproved":
                if case .string(let msg) = review.metadata?["dispositionMessage"], !msg.isEmpty {
                    return "Safety: Auto-approved — \(msg)"
                }
                return "Safety: Auto-approved"
            case "warning": return "Safety: Warning"
            case "denied": return "Safety: Denied"
            case "unavailable": return "Safety: BLOCKED — not reviewed (reviewer unavailable)"
            case "cancelled": return "Safety: blocked — review cancelled"
            case "abort": return "Safety: Abort triggered"
            default: return nil
            }
        }()
        let _securityReviewPopoverText: String? = {
            guard let review = securityReviewMessage else { return nil }
            if case .string(let msg) = review.metadata?["dispositionMessage"], !msg.isEmpty {
                return msg
            }
            let content = review.content
            if let colon = content.range(of: ": ") {
                let tail = String(content[colon.upperBound...])
                return tail.isEmpty ? content : tail
            }
            return content.isEmpty ? nil : content
        }()
        
        VStack(alignment: .leading, spacing: 2) {
            MessageRowSenderHeader(
                message: message,
                senderColor: _senderColor,
                recipientColor: _recipientColor,
                hidesPrivateRecipientAnnotation: _hidesPrivateRecipientAnnotation,
                shouldShowTimestamp: _shouldShowTimestamp,
                isToolRequest: _isToolRequest,
                displayPrefs: displayPrefs,
                toolCallElapsedSeconds: _toolCallElapsedSeconds
            )

            if _isToolRequest {
                if _isFileWrite {
                    FileWriteRequestBodyView(
                        message: message,
                        toolOutputMessage: toolOutputMessage,
                        parallelBadge: _parallelBadge,
                        dispositionComment: _dispositionComment,
                        dispositionCommentColor: _dispositionCommentColor,
                        effectiveDiffLines: _effectiveDiffLines,
                        isExpanded: $isExpanded
                    ) {
                        SecurityDispositionControlView(
                            dispositionIndicator: _dispositionIndicator,
                            dispositionTooltipText: _dispositionTooltipText,
                            dispositionCommentColor: _dispositionCommentColor,
                            securityReviewPopoverText: _securityReviewPopoverText
                        )
                    }
                } else {
                    GenericToolRequestBodyView(
                        message: message,
                        toolOutputMessage: toolOutputMessage,
                        parallelBadge: _parallelBadge,
                        effectiveToolFilePath: _effectiveToolFilePath,
                        dispositionComment: _dispositionComment,
                        dispositionCommentColor: _dispositionCommentColor,
                        effectiveFileEditStrings: _effectiveFileEditStrings,
                        fileEditFailed: _fileEditFailed,
                        isFileRead: _isFileRead,
                        toolCallDisplayText: _toolCallDisplayText,
                        remainderWithoutPath: _remainderWithoutPath,
                        openFileOrFallback: openFileOrFallback,
                        isExpanded: $isExpanded
                    ) {
                        SecurityDispositionControlView(
                            dispositionIndicator: _dispositionIndicator,
                            dispositionTooltipText: _dispositionTooltipText,
                            dispositionCommentColor: _dispositionCommentColor,
                            securityReviewPopoverText: _securityReviewPopoverText
                        )
                    }
                }
            } else if _isToolOutput {
                // Standalone tool output (no parent tool_request found — edge case)
                StandaloneToolOutputView(message: message, isExpanded: $isExpanded)
            } else if _isSecurityReview {
                // Standalone security review (no parent tool_request found — edge case)
                MarkdownText(content: message.content, baseFont: .channelBody, textColor: .custom(_securityReviewColor))
            } else if let maxLines = _defaultMaxLines {
                CollapsibleMessageBodyView(
                    message: message,
                    effectiveSplitLines: _effectiveSplitLines,
                    isExpanded: isExpanded,
                    isSummarizerMessage: _isSummarizerMessage,
                    maxLines: maxLines,
                    isExpandedBinding: $isExpanded
                )
            } else {
                MarkdownText(content: message.content, baseFont: .channelBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !message.attachments.isEmpty {
                ForEach(message.attachments) { attachment in
                    AttachmentView(
                        attachment: attachment,
                        tier: _attachmentTier,
                        onTapImage: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedImageAttachment = attachment
                            }
                        }
                    )
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background({
            // Severity decides every alarm colour here — this row's own, then that of the
            // security review attached to it. The `securityDisposition` string table that used to
            // sit at the bottom is gone: `ChannelMessage.severity` derives the level for legacy
            // review rows from that same tag, so the table could only agree with this — or, as it
            // did, disagree, painting a denial amber where severity says red.
            let worst = max(message.severity, _reviewSeverity)
            if worst >= .error { return AppColors.errorBackground }
            if worst == .warning { return AppColors.warningRowBackground }
            if _isSmithToUser { return AppColors.smithToUserBackground }
            return Color.clear
        }())
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            MessageRowCopyOverlay(isHovering: isHovering, messageContent: message.content)
        }
        .onHover { isHovering = $0 }
        .onChange(of: message, initial: true) { _, new in
            // Refresh derived caches when the underlying message changes (and once at
            // first appearance via initial: true). Re-assigning a @State value to one
            // that compares equal is a SwiftUI no-op, so unchanged messages cost
            // nothing here. Setting `cacheValid` last lets the `effective*` fallbacks
            // serve the first synchronous render before this closure runs.
            //
            // Project rule: defer @State mutations out of .onChange / lifecycle
            // closures via DispatchQueue.main.async so they can't race the active
            // render pass. The cache-miss render is already handled by the
            // `effective*` fallbacks above.
            DispatchQueue.main.async {
                cachedToolFilePath = Self.extractToolFilePath(from: new)
                cachedDiffLines = Self.extractPrecomputedDiffLines(from: new)
                cachedFileEditStrings = Self.extractFileEditStrings(from: new)
                cachedSplitLines = new.content.components(separatedBy: "\n")
                cacheValid = true
            }
        }
    }

    /// Maximum characters to show for the tool call description before truncating.
    private static let toolCallTruncationLimit = 200

    /// Whether the tool call description is long enough to warrant truncation.
    private var toolCallIsTruncatable: Bool {
        message.content.count > Self.toolCallTruncationLimit
    }

    /// The tool call description, truncated if needed and not expanded.
    private var toolCallDisplayText: String {
        if !toolCallIsTruncatable || isExpanded {
            return message.content
        }
        return String(message.content.prefix(Self.toolCallTruncationLimit)) + "…"
    }

    // MARK: - Tool path extraction

    /// Keys that contain file paths, in priority order.
    private static let pathKeys = ["file_path", "path"]

    /// Extracts the primary file path from the tool call's params metadata, if any.
    /// Returns nil for tools that don't have path arguments or if params can't be parsed.
    /// Cached into `cachedToolFilePath` via `.onChange(of: message, initial: true)`
    /// so JSON decoding doesn't run on every body re-evaluation.
    private static func extractToolFilePath(from message: ChannelMessage) -> String? {
        guard let paramsJSON = message.stringMetadata("params"),
              let data = paramsJSON.data(using: .utf8),
              // try? — params metadata is user-supplied JSON that can legitimately be
              // missing or malformed; nil here means "no path to extract" and the row
              // falls through to plain-text rendering.
              let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            return nil
        }
        for key in Self.pathKeys {
            if case .string(let path) = dict[key], path.contains("/") {
                return path
            }
        }
        return nil
    }

    /// The tool call summary text with the primary path removed (for display alongside ToolPathText).
    ///
    /// The path is removed together with the KEY that introduced it. Stripping only the value —
    /// which this used to do — left the key stranded holding nothing: `{"path": "", …}` in the
    /// JSON form the validator posts, `…, path=` in the `key=value` form Brown's tools post.
    /// Both read as "the caller passed an empty path" when in fact the path was lifted out and
    /// is rendered in full by `ToolPathText` immediately to the left.
    ///
    /// Two shapes are handled because the two producers format differently, and a bare-path
    /// fallback covers summaries that mention a path with no key at all. Anything that matches
    /// none of them is left as-is rather than guessed at.
    private func remainderWithoutPath(_ displayText: String, path: String) -> String {
        let toolName = message.stringMetadata("tool") ?? displayText.prefix(while: { $0 != ":" }).description
        var text = displayText
        // Remove "toolName: " prefix
        if text.hasPrefix(toolName) {
            text = String(text.dropFirst(toolName.count))
            if text.hasPrefix(": ") { text = String(text.dropFirst(2)) }
        }

        let escapedPath = NSRegularExpression.escapedPattern(for: path)
        for key in Self.pathKeys {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            let keyedForms = [
                #""\#(escapedKey)"\s*:\s*"\#(escapedPath)"\s*,?"#,    // "path": "/x/y",
                #"\b\#(escapedKey)\s*=\s*"?\#(escapedPath)"?\s*,?"#   // path=/x/y,
            ]
            for form in keyedForms {
                text = text.replacingOccurrences(of: form, with: "", options: [.regularExpression])
            }
        }
        // Unkeyed fallback. A no-op when a keyed form already matched — the path is gone by then.
        text = text.replacingOccurrences(of: path, with: "")

        // Tidy the separators the removal leaves behind.
        text = text.replacingOccurrences(of: #"\{\s*,"#, with: "{", options: [.regularExpression])
        text = text.replacingOccurrences(of: #",\s*\}"#, with: "}", options: [.regularExpression])
        text = text.replacingOccurrences(of: #",\s*,"#, with: ",", options: [.regularExpression])
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        // The path was the only argument — an empty object is noise, not information.
        return text == "{}" ? "" : text
    }

    // MARK: - Tool request consolidated block

    private var isFileWrite: Bool {
        message.stringMetadata("tool") == "file_write"
    }

    // MARK: generic tool display

    /// Whether this tool call was part of a parallel batch.
    private var parallelBadge: String? {
        guard case .int(let count) = message.metadata?["parallelCount"], count > 1,
              case .int(let index) = message.metadata?["parallelIndex"] else { return nil }
        return "\(index + 1)/\(count)"
    }
    /// Whether this tool call is `file_read` — its output is raw file content that
    /// should stay collapsed by default.
    private var isFileRead: Bool {
        message.stringMetadata("tool") == "file_read"
    }

    /// Whether a `file_edit` tool call failed. A successful edit always returns a
    /// "Successfully replaced …" message; anything else (Error:, BLOCKED:, Tool error:,
    /// etc.) is a failure. Pending calls (no output yet) return false so the optimistic
    /// diff is still shown while the call is in flight.
    private var fileEditFailed: Bool {
        guard let output = toolOutputMessage else { return false }
        let content = output.content.trimmingCharacters(in: .whitespaces)
        return !content.hasPrefix("Successfully")
    }

    /// Handles a tap on a tool call's file path. If the path exists, previews files in
    /// Quick Look and reveals directories in Finder. If the path doesn't exist
    /// (e.g., already deleted, or a path the tool couldn't resolve), falls through to
    /// toggling the row's expand state so the tap still does something useful.
    private func openFileOrFallback(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            isExpanded.toggle()
            return
        }
        if isDir.boolValue {
            // Folder: open it in Finder showing its contents.
            NSWorkspace.shared.open(url)
        } else {
            // File: preview it rather than launching whatever app owns the extension.
            QuickLookPreview.present(url)
        }
    }

    /// Extracts (old_string, new_string) from a `file_edit` tool_request's params metadata.
    /// Cached into `cachedFileEditStrings` via `.onChange(of: message, initial: true)`.
    private static func extractFileEditStrings(from message: ChannelMessage) -> FileEditStrings? {
        guard let paramsJSON = message.stringMetadata("params"),
              let data = paramsJSON.data(using: .utf8),
              // try? — params metadata can legitimately be missing or malformed; nil
              // here means "no diff to show" and the row falls through gracefully.
              let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            return nil
        }
        guard case .string(let oldString) = dict["old_string"],
              case .string(let newString) = dict["new_string"] else {
            return nil
        }
        return FileEditStrings(oldString: oldString, newString: newString)
    }

    /// Decodes the precomputed diff that `AgentActor` stashed into
    /// `fileWriteDiff` metadata at tool_request post time. Returns nil if no
    /// diff was stored (large file, read failure) or if the metadata can't be
    /// parsed — in both cases the UI falls through to "no diff shown".
    /// Cached into `cachedDiffLines` via `.onChange(of: message, initial: true)`.
    private static func extractPrecomputedDiffLines(from message: ChannelMessage) -> [DiffLine]? {
        guard let json = message.stringMetadata("fileWriteDiff"),
              let data = json.data(using: .utf8) else {
            return nil
        }
        do {
            return try JSONDecoder().decode([DiffLine].self, from: data)
        } catch {
            return nil
        }
    }

    private var securityReviewColor: Color {
        guard case .string(let disposition) = message.metadata?["securityDisposition"] else {
            return .secondary
        }
        switch disposition {
        case "approved": return AppColors.securityApproved
        case "autoApproved": return AppColors.securityApproved
        case "warning": return AppColors.securityWarning
        case "denied": return AppColors.securityDenied
        case "abort": return AppColors.securityAbort
        default: return .secondary
        }
    }

    // MARK: - Extracted View structs (refactored from func ... -> some View)
    // These nested structs replace the helper functions to improve SwiftUI performance
    // by enabling better view caching and reducing body recalculation.
    
    /// Renders the security disposition indicator with popover.
    struct SecurityDispositionControlView: View {
        let dispositionIndicator: String?
        let dispositionTooltipText: String?
        let dispositionCommentColor: Color
        let securityReviewPopoverText: String?

        @State private var showSecurityPopover = false

        var body: some View {
            if let indicator = dispositionIndicator {
                Button(action: { showSecurityPopover.toggle() }, label: {
                    Text(indicator)
                })
                .buttonStyle(.plain)
                .help(dispositionTooltipText ?? "Security review")
                .popover(isPresented: $showSecurityPopover, arrowEdge: .bottom) {
                    SecurityVerdictPopoverContent(
                        title: dispositionTooltipText ?? "Security review",
                        titleColor: dispositionCommentColor,
                        text: securityReviewPopoverText)
                }
            }
        }
    }

    /// The reviewer's verdict text, in the indicator's popover.
    struct SecurityVerdictPopoverContent: View {
        let title: String
        let titleColor: Color
        let text: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(titleColor)
                Text(text ?? "No details provided.")
                    .font(AppFonts.channelBody)
                    .foregroundStyle(text == nil ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: 420)
        }
    }
    
    /// Renders a file_write tool request row.
    struct FileWriteRequestBodyView: View {
        let message: ChannelMessage
        let toolOutputMessage: ChannelMessage?
        let parallelBadge: String?
        let dispositionComment: String?
        let dispositionCommentColor: Color
        let effectiveDiffLines: [DiffLine]?
        private let collapsedErrorPreview: String?
        private let toolOutputHasMore: Bool
        
        init(message: ChannelMessage, toolOutputMessage: ChannelMessage?, parallelBadge: String?, dispositionComment: String?, dispositionCommentColor: Color, effectiveDiffLines: [DiffLine]?, isExpanded: Binding<Bool>, securityDispositionControl: @escaping () -> SecurityDispositionControlView) {
            self.message = message
            self.toolOutputMessage = toolOutputMessage
            self.parallelBadge = parallelBadge
            self.dispositionComment = dispositionComment
            self.dispositionCommentColor = dispositionCommentColor
            self.effectiveDiffLines = effectiveDiffLines
            self._isExpanded = isExpanded
            self.securityDispositionControl = securityDispositionControl
            // Compute collapsedErrorPreview and toolOutputHasMore once at init time
            if let output = toolOutputMessage, !output.content.isEmpty {
                let firstLine = output.content.components(separatedBy: .newlines).first ?? output.content
                let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
                self.collapsedErrorPreview = trimmed.lowercased().hasPrefix("error") ? firstLine : nil
                if let errorLine = self.collapsedErrorPreview {
                    self.toolOutputHasMore = output.content.count > errorLine.count
                } else {
                    self.toolOutputHasMore = true
                }
            } else {
                self.collapsedErrorPreview = nil
                self.toolOutputHasMore = false
            }
        }
        
        @Binding var isExpanded: Bool
        let securityDispositionControl: () -> SecurityDispositionControlView
        
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: { isExpanded.toggle() }, label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        FileWritePathView(path: message.stringMetadata("fileWritePath") ?? "")
                        if let badge = parallelBadge {
                            Text("⚡\(badge)")
                                .font(.caption2.bold())
                                .foregroundStyle(AppColors.cyanBadgeForeground)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(AppColors.cyanBadgeBackground)
                                .clipShape(Capsule())
                        }
                        if isExpanded {
                            Text("(show less)")
                                .font(.caption)
                                .foregroundStyle(AppColors.disclosureToggle)
                        } else if toolOutputHasMore {
                            Text("(show more)")
                                .font(.caption)
                                .foregroundStyle(AppColors.disclosureToggle)
                        }
                        securityDispositionControl()
                    }
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                
                if let comment = dispositionComment {
                    MarkdownText(content: comment, baseFont: .channelBodyItalic, textColor: .custom(dispositionCommentColor))
                        .padding(.leading, 12)
                }
                
                if let diffLines = effectiveDiffLines {
                    DiffView(lines: diffLines)
                }
                
                if let output = toolOutputMessage {
                    if isExpanded {
                        Text(output.content)
                            .font(AppFonts.channelBody.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else if let errorLine = collapsedErrorPreview {
                        Text(errorLine)
                            .font(AppFonts.channelBody.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 12)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
    
    /// Renders a generic tool request row.
    struct GenericToolRequestBodyView: View {
        let message: ChannelMessage
        let toolOutputMessage: ChannelMessage?
        let parallelBadge: String?
        let effectiveToolFilePath: String?
        let dispositionComment: String?
        let dispositionCommentColor: Color
        let effectiveFileEditStrings: FileEditStrings?
        let fileEditFailed: Bool
        let isFileRead: Bool
        let toolCallDisplayText: String
        let remainderWithoutPath: (String, String) -> String
        let openFileOrFallback: (String) -> Void
        private let collapsedErrorPreview: String?
        private let toolOutputHasMore: Bool
        
        init(message: ChannelMessage, toolOutputMessage: ChannelMessage?, parallelBadge: String?, effectiveToolFilePath: String?, dispositionComment: String?, dispositionCommentColor: Color, effectiveFileEditStrings: FileEditStrings?, fileEditFailed: Bool, isFileRead: Bool, toolCallDisplayText: String, remainderWithoutPath: @escaping (String, String) -> String, openFileOrFallback: @escaping (String) -> Void, isExpanded: Binding<Bool>, securityDispositionControl: @escaping () -> SecurityDispositionControlView) {
            self.message = message
            self.toolOutputMessage = toolOutputMessage
            self.parallelBadge = parallelBadge
            self.effectiveToolFilePath = effectiveToolFilePath
            self.dispositionComment = dispositionComment
            self.dispositionCommentColor = dispositionCommentColor
            self.effectiveFileEditStrings = effectiveFileEditStrings
            self.fileEditFailed = fileEditFailed
            self.isFileRead = isFileRead
            self.toolCallDisplayText = toolCallDisplayText
            self.remainderWithoutPath = remainderWithoutPath
            self.openFileOrFallback = openFileOrFallback
            self._isExpanded = isExpanded
            self.securityDispositionControl = securityDispositionControl
            // Compute collapsedErrorPreview and toolOutputHasMore once at init time
            if let output = toolOutputMessage, !output.content.isEmpty {
                let firstLine = output.content.components(separatedBy: .newlines).first ?? output.content
                let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
                self.collapsedErrorPreview = trimmed.lowercased().hasPrefix("error") ? firstLine : nil
                if let errorLine = self.collapsedErrorPreview {
                    self.toolOutputHasMore = output.content.count > errorLine.count
                } else {
                    self.toolOutputHasMore = true
                }
            } else {
                self.collapsedErrorPreview = nil
                self.toolOutputHasMore = false
            }
        }
        
        @Binding var isExpanded: Bool
        let securityDispositionControl: () -> SecurityDispositionControlView
        
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: { isExpanded.toggle() }, label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        let displayText = isExpanded ? message.content : toolCallDisplayText
                        let toolName = message.stringMetadata("tool") ?? displayText.prefix(while: { $0 != ":" }).description
                        ToolNameChip(name: toolName)
                        if let path = effectiveToolFilePath {
                            Button(action: { openFileOrFallback(path) }, label: {
                                ToolPathText(path: path)
                            })
                            .buttonStyle(.plain)
                            let extra = remainderWithoutPath(displayText, path)
                            if !extra.isEmpty {
                                Text(extra)
                                    .font(AppFonts.channelBody)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(isExpanded ? nil : 1)
                            }
                        } else {
                            let remainder = displayText.hasPrefix(toolName) ? String(displayText.dropFirst(toolName.count)) : ": \(displayText)"
                            let cleanRemainder = remainder.hasPrefix(": ") ? String(remainder.dropFirst(2)) : remainder
                            Text(cleanRemainder)
                                .font(AppFonts.channelBody)
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? nil : 1)
                        }
                        if let badge = parallelBadge {
                            Text("⚡\(badge)")
                                .font(.caption2.bold())
                                .foregroundStyle(AppColors.cyanBadgeForeground)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(AppColors.cyanBadgeBackground)
                                .clipShape(Capsule())
                        }
                        if isExpanded {
                            Text("(show less)")
                                .font(.caption)
                                .foregroundStyle(AppColors.disclosureToggle)
                        } else if toolOutputHasMore {
                            Text("(show more)")
                                .font(.caption)
                                .foregroundStyle(AppColors.disclosureToggle)
                        }
                        securityDispositionControl()
                    }
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                
                if let comment = dispositionComment {
                    MarkdownText(content: comment, baseFont: .channelBodyItalic, textColor: .custom(dispositionCommentColor))
                        .padding(.leading, 12)
                }
                
                if message.stringMetadata("tool") == "file_edit",
                   !fileEditFailed,
                   let strings = effectiveFileEditStrings {
                    DiffView(oldContent: strings.oldString, newContent: strings.newString)
                }
                
                if let output = toolOutputMessage {
                    if isExpanded {
                        let fullText: String = {
                            if case .string(let expanded) = output.metadata?["expandedContent"] {
                                return expanded
                            }
                            return output.content
                        }()
                        Text(fullText)
                            .font(AppFonts.channelBody.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else if !isFileRead, let errorLine = collapsedErrorPreview {
                        Text(errorLine)
                            .font(AppFonts.channelBody.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 12)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
    
    /// Renders a standalone tool output as a DisclosureGroup.
    struct StandaloneToolOutputView: View {
        let message: ChannelMessage
        
        @Binding var isExpanded: Bool
        
        var body: some View {
            DisclosureGroup(isExpanded: $isExpanded, content: {
                Text(message.content)
                    .font(AppFonts.channelBody.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }, label: {
                StandaloneToolOutputLabelView(message: message)
            })
        }
    }

    /// Identifies orphaned tool failures as tool feedback, not agent-authored prose.
    struct StandaloneToolOutputLabelView: View {
        let message: ChannelMessage

        var body: some View {
            if message.severity >= .error {
                Label(failureTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(AppFonts.channelBody)
                    .foregroundStyle(AppColors.verdictError)
            } else {
                Text(message.toolName.map { "Output: \($0)" } ?? "Output")
                    .font(AppFonts.channelBody)
                    .foregroundStyle(.secondary)
            }
        }

        private var failureTitle: String {
            guard let toolName = message.toolName else {
                return "\(message.sender.displayName) tool failed"
            }
            return "\(message.sender.displayName) tool failed: \(toolName)"
        }
    }
    
    /// Renders a collapsible message body with truncation.
    struct CollapsibleMessageBodyView: View {
        let message: ChannelMessage
        let effectiveSplitLines: [String]
        let isExpanded: Bool
        let isSummarizerMessage: Bool
        let maxLines: Int
        
        @Binding var isExpandedBinding: Bool
        
        var body: some View {
            let lines = effectiveSplitLines
            let needsTruncation = lines.count > maxLines
            
            if isExpandedBinding || !needsTruncation {
                VStack(alignment: .leading, spacing: 1) {
                    if isSummarizerMessage {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            MarkdownText(content: line, baseFont: .channelBody)
                                .padding(.leading, index > 0 ? 12 : 0)
                        }
                    } else {
                        MarkdownText(content: message.content, baseFont: .channelBody)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if needsTruncation {
                    Button(action: { isExpandedBinding = false }, label: {
                        Text("(show less)")
                            .font(.caption)
                            .foregroundStyle(AppColors.disclosureToggle)
                            .padding(.leading, isSummarizerMessage ? 12 : 0)
                    })
                    .buttonStyle(.plain)
                }
            } else {
                let visibleLines = Array(lines.prefix(maxLines))
                Button(action: { isExpandedBinding = true }, label: {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(visibleLines.dropLast().enumerated()), id: \.offset) { index, line in
                            MarkdownText(content: line, baseFont: .channelBody)
                                .padding(.leading, isSummarizerMessage && index > 0 ? 12 : 0)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(visibleLines.last ?? "")
                                .font(AppFonts.channelBody)
                                .lineLimit(1)
                            Text(" (show more)")
                                .font(.caption)
                                .foregroundStyle(AppColors.disclosureToggle)
                        }
                        .padding(.leading, isSummarizerMessage && maxLines > 1 ? 12 : 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // A selectable text view here would take the click meant for the button.
                    .environment(\.markdownRendering, .staticText)
                })
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - ChannelMessage helper

private extension ChannelMessage {
    func stringMetadata(_ key: String) -> String? {
        if case .string(let value) = metadata?[key] { return value }
        return nil
    }

    func intMetadata(_ key: String) -> Int? {
        if case .int(let value) = metadata?[key] { return value }
        return nil
    }

    func doubleMetadata(_ key: String) -> Double? {
        switch metadata?[key] {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    func boolMetadata(_ key: String) -> Bool? {
        if case .bool(let value) = metadata?[key] { return value }
        return nil
    }
}


/// A centered lifecycle marker for `restart_chrome` messages ("System online. Smith agent active.",
/// "All agents stopped") — a small capsule with a status dot, flanked by hairline rules, so it reads
/// as a boot/shutdown event rather than a chat message.
private struct LifecycleChromeBanner: View {
    let message: ChannelMessage

    var body: some View {
        let _isStop = message.stringMetadata("restartChromeKind") == "agents_stopped"
        return HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: _isStop ? "moon.zzz.fill" : "bolt.horizontal.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(_isStop ? Color.secondary : AppColors.smithAgent)
                Text(message.content)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.secondary.opacity(0.10))
            )
            .overlay(
                Capsule().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
}
