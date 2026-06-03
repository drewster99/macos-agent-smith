import SwiftUI
import AgentSmithKit

/// Shared timestamp formatter used by all banner and message row structs in this file.
let sharedTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SS"
    return f
}()

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
            Text(sharedTimestampFormatter.string(from: timestamp))
                .font(AppFonts.channelTimestamp)
                .foregroundStyle(foregroundStyle)
        }
    }
}

/// Discriminator for the channel log's banner family. Each raw value matches the
/// `messageKind` string set by the runtime when posting `ChannelMessage`.
///
/// Replaces a 16-branch `else if case .string(let kind) = message.metadata?["messageKind"]`
/// ladder. Adding a new banner kind now means adding a case here AND a switch arm in
/// `bannerView(for:in:)` — both fail at compile time if forgotten, instead of silently
/// falling through to a generic `MessageRow`.
private enum ChannelBannerKind: String {
    /// Internal coordination row — not rendered.
    case agentOnline = "agent_online"
    /// Lifecycle chrome — gated by the user's "Show agent restart chrome" preference.
    case restartChrome = "restart_chrome"
    /// Timer activity — duplicate of a task's Scheduled chip when paired; otherwise rendered.
    case timerActivity = "timer_activity"
    /// Internal Smith guidance — not rendered.
    case taskUpdateGuidance = "task_update_guidance"
    case taskAcknowledged = "task_acknowledged"
    case taskContinuing = "task_continuing"
    case taskComplete = "task_complete"
    case changesRequested = "changes_requested"
    case taskActionScheduled = "task_action_scheduled"
    case taskCreated = "task_created"
    case taskUpdate = "task_update"
    case taskCompleted = "task_completed"
    case taskSummarized = "task_summarized"
    case memorySaved = "memory_saved"
    case memorySearched = "memory_searched"
    /// An MCP server failed to load — rendered as a clickable banner that opens Settings.
    case mcpFailed = "mcp_status"
}

/// Color-coded scrolling message stream with attachment display.
struct ChannelLogView: View, Equatable {
    var messages: [ChannelMessage]
    /// Derived lookups maintained by `AppViewModel` (rebuilt on every channel-log mutation)
    /// so this view doesn't re-scan `messages` inside `body`. They are a pure function of
    /// `messages`, so `==` below intentionally does not compare them — count + last.id of
    /// `messages` already implies they're current.
    var toolRequestIDs: Set<String>
    var securityReviewByRequestID: [String: ChannelMessage]
    var toolOutputByRequestID: [String: ChannelMessage]
    var taskIDsWithSchedulingBanner: Set<String>
    var persistedHistoryCount: Int
    var hasRestoredHistory: Bool
    var onRestoreHistory: () -> Void
    /// Invoked when the user taps the PDF button on a "Task Completed" banner. Carries the
    /// banner's task id plus its own fields so the handler can fall back to them when the
    /// underlying task has been permanently deleted.
    var onExportTaskPDF: (_ taskID: UUID, _ title: String, _ result: String?, _ timestamp: Date) -> Void
    /// Invoked when the user clicks an MCP-server-failed banner to open Settings → MCP Servers.
    var onOpenMCPSettings: () -> Void
    /// Display toggles forwarded into the environment so each banner / row reads them
    /// without having to thread parameters through every initializer.
    var displayPrefs: TimestampPreferences

    @State private var isAtBottom = true
    @State private var autoScrollEnabled = true
    /// The attachment currently shown in the full-screen image viewer, managed by the parent.
    @Binding var selectedImageAttachment: Attachment?

    /// Prevents body re-evaluation when only unrelated parent properties change (e.g. inputText).
    /// Closures and Bindings are excluded — they can't be meaningfully compared, and
    /// the Binding manages its own invalidation internally. `displayPrefs` is included so
    /// toggling a setting at runtime invalidates the cached body.
    ///
    /// Closures (`onRestoreHistory`, `onExportTaskPDF`) are intentionally excluded — they
    /// can't be meaningfully compared, and their captures are session-stable here (the
    /// per-session `viewModel` is created once by `SessionManager` and never swapped under
    /// a live view). A future change that makes a closure capture a value that varies
    /// without also changing one of the compared fields would route to a stale capture; if
    /// that ever happens, fold the relevant identity into this comparator.
    ///
    /// CORRECTNESS INVARIANT: assumes `messages` is append-only. Count + last.id is
    /// sufficient to detect "something changed" only because we never mutate existing
    /// elements in place. If this ever changes (e.g. updating an already-appended
    /// tool_request's metadata when its output arrives, instead of treating output as a
    /// separate appended row), this comparator must be expanded to detect those edits —
    /// otherwise the channel log will silently fail to redraw on streaming updates.
    nonisolated static func == (lhs: ChannelLogView, rhs: ChannelLogView) -> Bool {
        lhs.messages.count == rhs.messages.count
        && lhs.messages.last?.id == rhs.messages.last?.id
        && lhs.persistedHistoryCount == rhs.persistedHistoryCount
        && lhs.hasRestoredHistory == rhs.hasRestoredHistory
        && lhs.displayPrefs == rhs.displayPrefs
    }

    private struct ScrollMetrics: Equatable {
        var isNearBottom: Bool
        var contentHeight: CGFloat
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if persistedHistoryCount > 0 && !hasRestoredHistory {
                            ChannelLogRestoreHistoryButton(
                                persistedHistoryCount: persistedHistoryCount,
                                onRestoreHistory: onRestoreHistory
                            )
                        }

                        ForEach(messages) { message in
                            if !shouldSuppress(message, toolRequestIDs: toolRequestIDs) {
                                bannerView(
                                    for: message,
                                    reviewLookup: securityReviewByRequestID,
                                    outputLookup: toolOutputByRequestID,
                                    scheduledTaskBannerIDs: taskIDsWithSchedulingBanner
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(8)
                }
                .background(AppColors.channelBackground)
                .environment(\.timestampPreferences, displayPrefs)
                .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                    let distanceFromBottom = geometry.contentSize.height
                        - geometry.contentOffset.y
                        - geometry.containerSize.height
                    let threshold = geometry.containerSize.height * 0.2
                    return ScrollMetrics(
                        isNearBottom: distanceFromBottom <= threshold,
                        contentHeight: geometry.contentSize.height
                    )
                } action: { old, new in
                    // Project rule: defer @State mutation out of scroll-geometry actions
                    // via DispatchQueue.main.async. The action callback fires rapidly during
                    // ScrollView animation/inertia; mutating @State synchronously triggers
                    // SwiftUI's "OnScrollGeometryChange tried to update multiple times per
                    // frame" warning when the resulting body re-evaluation re-attaches the
                    // modifier mid-frame.
                    DispatchQueue.main.async {
                        isAtBottom = new.isNearBottom
                        // Content grew but user didn't scroll -> keep auto-scroll on
                        // Content same but user scrolled away -> disable auto-scroll
                        if old.isNearBottom && !new.isNearBottom
                            && new.contentHeight == old.contentHeight {
                            autoScrollEnabled = false
                        }
                        if new.isNearBottom {
                            autoScrollEnabled = true
                        }
                    }
                }
                .onChange(of: messages.count) {
                    guard autoScrollEnabled, let lastID = messages.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }

                if !isAtBottom {
                    ChannelLogScrollToBottomButton(onTap: {
                        guard let lastID = messages.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    })
                }
            }
        }
    }

    /// Suppresses security reviews and tool outputs that are grouped into a parent tool_request row.
    private func shouldSuppress(_ message: ChannelMessage, toolRequestIDs: Set<String>) -> Bool {
        guard let reqID = message.stringMetadata("requestID") else { return false }
        let isFollowUp = message.metadata?["securityDisposition"] != nil
            || message.stringMetadata("messageKind") == "tool_output"
        guard isFollowUp else { return false }
        // Only suppress if the parent tool_request exists in the messages array
        return toolRequestIDs.contains(reqID)
    }

    /// Renders the right banner / row for a single channel message. Replaces the
    /// 16-branch metadata-keyed ladder that used to live in `body`. Each `nil`-returning
    /// case represents an internal coordination message that's intentionally suppressed.
    @ViewBuilder
    private func bannerView(
        for message: ChannelMessage,
        reviewLookup: [String: ChannelMessage],
        outputLookup: [String: ChannelMessage],
        scheduledTaskBannerIDs: Set<String>
    ) -> some View {
        let kind = message.stringMetadata("messageKind").flatMap(ChannelBannerKind.init(rawValue:))
        switch kind {
        case .agentOnline, .taskUpdateGuidance:
            // Internal coordination messages — never rendered.
            EmptyView()
        case .restartChrome:
            // Lifecycle chrome ("All agents stopped", "Smith agent active") — gated by
            // the user's "Show agent restart chrome" preference.
            if displayPrefs.showRestartChrome {
                MessageRow(
                    message: message,
                    securityReviewMessage: message.stringMetadata("requestID").flatMap { reviewLookup[$0] },
                    toolOutputMessage: message.stringMetadata("requestID").flatMap { outputLookup[$0] },
                    displayPrefs: displayPrefs,
                    selectedImageAttachment: $selectedImageAttachment
                )
                .equatable()
            }
        case .timerActivity:
            // Suppress the "scheduled HH:MM — run_task: …" row when paired with a Task
            // banner whose chip carries the same info; otherwise render via MessageRow.
            if message.stringMetadata("timerEventKind") == "scheduled",
               let timerTaskID = message.stringMetadata("timerTaskID"),
               scheduledTaskBannerIDs.contains(timerTaskID) {
                EmptyView()
            } else {
                MessageRow(
                    message: message,
                    securityReviewMessage: message.stringMetadata("requestID").flatMap { reviewLookup[$0] },
                    toolOutputMessage: message.stringMetadata("requestID").flatMap { outputLookup[$0] },
                    displayPrefs: displayPrefs,
                    selectedImageAttachment: $selectedImageAttachment
                )
                .equatable()
            }
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
            let action = TaskActionKind(rawValue: actionRaw) ?? .run
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
        case .none:
            // Plain message — fall through to the generic row.
            MessageRow(
                message: message,
                securityReviewMessage: message.stringMetadata("requestID").flatMap { reviewLookup[$0] },
                toolOutputMessage: message.stringMetadata("requestID").flatMap { outputLookup[$0] },
                displayPrefs: displayPrefs,
                selectedImageAttachment: $selectedImageAttachment
            )
            .equatable()
        }
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
    /// Display preferences. Passed in as a `let` rather than read via `@Environment` so
    /// that it participates in `==` below — `EquatableView`'s cache shortcut would
    /// otherwise prevent body re-evaluation when only the env-injected prefs change,
    /// stranding the previous timestamp-visibility decision in the cached output.
    let displayPrefs: TimestampPreferences
    @Binding var selectedImageAttachment: Attachment?

    @State private var isExpanded = false
    @State private var isHovering = false

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

    private var effectiveToolFilePath: String? {
        cacheValid ? cachedToolFilePath : Self.extractToolFilePath(from: message)
    }
    private var effectiveDiffLines: [DiffLine]? {
        cacheValid ? cachedDiffLines : Self.extractPrecomputedDiffLines(from: message)
    }
    private var effectiveFileEditStrings: FileEditStrings? {
        cacheValid ? cachedFileEditStrings : Self.extractFileEditStrings(from: message)
    }
    private var effectiveSplitLines: [String] {
        cacheValid ? cachedSplitLines : message.content.components(separatedBy: "\n")
    }

    /// Skips body re-evaluation when the row's source data is unchanged. Without this,
    /// every existing row re-evaluates whenever `ChannelLogView` re-runs (i.e. on every
    /// appended message), which fans out the per-row JSON decoding / line-splitting
    /// work above into an O(N²) wall. `displayPrefs` is included so runtime toggles of
    /// timestamp visibility cascade to existing rows — see comment on the field.
    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
        && lhs.securityReviewMessage == rhs.securityReviewMessage
        && lhs.toolOutputMessage == rhs.toolOutputMessage
        && lhs.displayPrefs == rhs.displayPrefs
    }

    /// Image tier for this message's attachments — user messages get small, others get medium.
    private var attachmentTier: ImageCache.Tier {
        message.sender == .user ? .small : .medium
    }

    private var senderColor: Color {
        AppColors.color(for: message.sender)
    }

    private var recipientColor: Color {
        guard let recipient = message.recipient else { return .secondary }
        switch recipient {
        case .agent(let role): return AppColors.color(for: .agent(role))
        case .user: return AppColors.color(for: .user)
        }
    }

    private var messageKind: String? {
        message.stringMetadata("messageKind")
    }

    private var isToolRequest: Bool {
        messageKind == "tool_request"
    }

    /// Elapsed seconds between the tool request and its output, if both timestamps are
    /// available. Used by the "show elapsed time on tool calls" display toggle. Returns nil
    /// for in-flight calls (no output yet) or when the output predates the request (clock
    /// skew, replay).
    private var toolCallElapsedSeconds: TimeInterval? {
        guard let output = toolOutputMessage else { return nil }
        let elapsed = output.timestamp.timeIntervalSince(message.timestamp)
        return elapsed >= 0 ? elapsed : nil
    }

    private var isToolOutput: Bool {
        messageKind == "tool_output"
    }

    private var isSecurityReview: Bool {
        message.metadata?["securityDisposition"] != nil
    }

    private var isErrorMessage: Bool {
        if case .bool(let value) = message.metadata?["isError"] { return value }
        return false
    }

    /// The security disposition string for this tool request's review, if any.
    private var securityDisposition: String? {
        guard let review = securityReviewMessage,
              case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
        return d
    }

    /// True when Smith sends a private message directly to the user — these deserve visual emphasis.
    private var isSmithToUser: Bool {
        guard case .agent(.smith) = message.sender else { return false }
        guard case .user = message.recipient else { return false }
        return true
    }

    /// True when Smith sends a private message to Brown.
    private var isSmithToBrown: Bool {
        guard case .agent(.smith) = message.sender else { return false }
        guard case .agent(.brown) = message.recipient else { return false }
        return true
    }

    /// True for any message sent by Brown (public or private).
    private var isBrownMessage: Bool {
        guard case .agent(.brown) = message.sender else { return false }
        return true
    }

    /// True for any message sent by the Summarizer agent.
    private var isSummarizerMessage: Bool {
        guard case .agent(.summarizer) = message.sender else { return false }
        return true
    }

    /// Default max visible lines for this message type. Nil means show all.
    private var defaultMaxLines: Int? {
        if isSummarizerMessage { return 2 }
        if isSmithToBrown || isBrownMessage { return 5 }
        return nil
    }

    // MARK: - Tool request grouping

    private var dispositionIndicator: String? {
        guard let review = securityReviewMessage,
              case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
        switch d {
        case "approved": return "\u{2705}"   // checkmark
        case "autoApproved": return "\u{2705}"  // checkmark (comment below explains auto-approval)
        case "warning": return "\u{26A0}\u{FE0F}" // warning
        case "denied": return "\u{1F6AB}"    // prohibited
        case "abort": return "\u{1F6D1}"     // stop sign
        case "cancelled": return nil
        default: return nil
        }
    }

    /// Human-readable tooltip text describing what the safety monitor determined.
    private var dispositionTooltipText: String? {
        guard let review = securityReviewMessage,
              case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
        switch d {
        case "approved": return "Safety: Approved"
        case "autoApproved": return "Safety: Auto-approved (identical retry)"
        case "warning": return "Safety: Warning"
        case "denied": return "Safety: Denied"
        case "abort": return "Safety: Abort triggered"
        default: return nil
        }
    }

    private var dispositionComment: String? {
        guard let review = securityReviewMessage,
              case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
        switch d {
        case "autoApproved":
            return "Auto-approved (identical WARN retry)"
        case "warning", "denied", "abort":
            // Use the full disposition message from metadata (includes retry instruction for WARN)
            if case .string(let msg) = review.metadata?["dispositionMessage"], !msg.isEmpty {
                return msg
            }
            return nil
        default:
            return nil
        }
    }

    private var dispositionCommentColor: Color {
        guard let review = securityReviewMessage,
              case .string(let d) = review.metadata?["securityDisposition"] else { return .secondary }
        switch d {
        case "autoApproved": return AppColors.securityApproved
        case "warning": return AppColors.securityWarning
        case "denied": return AppColors.securityDenied
        case "abort": return AppColors.securityAbort
        default: return .secondary
        }
    }

    /// Maximum characters for tool output before the view layer truncates.
    private static let outputTruncationLimit = 500

    /// When collapsed, tool output preview is suppressed unless the first line starts
    /// with "error" (case-insensitive). Returns that line for display, or nil.
    private func collapsedErrorPreview(_ content: String) -> String? {
        let firstLine = content.components(separatedBy: .newlines).first ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("error") ? firstLine : nil
    }

    /// True when this row involves the human (sender == user OR recipient == user). The
    /// header drops the lock + arrow + recipient annotation in that case — when Smith
    /// addresses Drew, "Smith → Drew" reads as redundant clutter; same for Drew's input.
    private var hidesPrivateRecipientAnnotation: Bool {
        if case .user = message.sender { return true }
        if case .user = message.recipient { return true }
        return false
    }

    /// Whether this row should render its timestamp, given the current display prefs.
    /// Tool calls, system messages, and agent↔agent / agent↔user messaging each have
    /// their own toggle so the user can mute the categories they don't want.
    private var shouldShowTimestamp: Bool {
        if isToolRequest { return displayPrefs.toolCalls }
        if case .system = message.sender { return displayPrefs.systemMessages }
        return displayPrefs.messaging
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MessageRowSenderHeader(
                message: message,
                senderColor: senderColor,
                recipientColor: recipientColor,
                hidesPrivateRecipientAnnotation: hidesPrivateRecipientAnnotation,
                shouldShowTimestamp: shouldShowTimestamp,
                isToolRequest: isToolRequest,
                displayPrefs: displayPrefs,
                toolCallElapsedSeconds: toolCallElapsedSeconds
            )

            if isToolRequest {
                toolRequestBody()
            } else if isToolOutput {
                // Standalone tool output (no parent tool_request found — edge case)
                standaloneToolOutput()
            } else if isSecurityReview {
                // Standalone security review (no parent tool_request found — edge case)
                MarkdownText(content: message.content, baseFont: AppFonts.channelBody)
                    .foregroundStyle(securityReviewColor)
            } else if let maxLines = defaultMaxLines {
                collapsibleMessageBody(maxLines: maxLines)
            } else {
                MarkdownText(content: message.content, baseFont: AppFonts.channelBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !message.attachments.isEmpty {
                ForEach(message.attachments) { attachment in
                    AttachmentView(
                        attachment: attachment,
                        tier: attachmentTier,
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
            if isErrorMessage { return AppColors.errorBackground }
            if isSmithToUser { return AppColors.smithToUserBackground }
            switch securityDisposition {
            case "warning", "denied": return AppColors.warningRowBackground
            case "abort": return AppColors.errorBackground
            default: break
            }
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
    /// Returns nil if no path was extracted.
    private func remainderWithoutPath(_ displayText: String, path: String) -> String {
        let toolName = message.stringMetadata("tool") ?? displayText.prefix(while: { $0 != ":" }).description
        var text = displayText
        // Remove "toolName: " prefix
        if text.hasPrefix(toolName) {
            text = String(text.dropFirst(toolName.count))
            if text.hasPrefix(": ") { text = String(text.dropFirst(2)) }
        }
        // Remove the path from the remaining text
        text = text.replacingOccurrences(of: path, with: "")
        // Clean up separators left behind (e.g. ", , " or leading ", ")
        text = text.replacingOccurrences(of: ", ,", with: ",")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        return text
    }

    // MARK: - Tool request consolidated block

    private var isFileWrite: Bool {
        message.stringMetadata("tool") == "file_write"
    }

    @ViewBuilder

    private func toolRequestBody() -> some View {
        if isFileWrite {
            fileWriteRequestBody()
        } else {
            genericToolRequestBody()
        }
    }

    // MARK: file_write display

    @ViewBuilder

    private func fileWriteRequestBody() -> some View {
        // Line 1: "file_write /dir/path/filename ⚡1/3 (show more) ✅"
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
                if let indicator = dispositionIndicator {
                    if let tooltip = dispositionTooltipText {
                        Text(indicator).hoverTooltip(tooltip)
                    } else {
                        Text(indicator)
                    }
                }
            }
            .contentShape(Rectangle())
        })
        .buttonStyle(.plain)

        // Disposition comment (for WARN/UNSAFE/ABORT)
        if let comment = dispositionComment {
            MarkdownText(content: comment, baseFont: AppFonts.channelBody.italic())
                .foregroundStyle(dispositionCommentColor)
                .padding(.leading, 12)
        }

        // Inline diff: rendered from precomputed [DiffLine] that AgentActor
        // stashed into `fileWriteDiff` metadata at post time. Storing only
        // the diff lines (not the raw old+new file contents) keeps
        // channel_log.json bounded regardless of file size.
        if let diffLines = effectiveDiffLines {
            DiffView(lines: diffLines)
        }

        // Tool output: suppressed when collapsed unless first line begins with "error".
        // Full content is revealed on expand.
        if let output = toolOutputMessage {
            if isExpanded {
                Text(output.content)
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else if let errorLine = collapsedErrorPreview(output.content) {
                Text(errorLine)
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: generic tool display

    /// Whether this tool call was part of a parallel batch.
    private var parallelBadge: String? {
        guard case .int(let count) = message.metadata?["parallelCount"], count > 1,
              case .int(let index) = message.metadata?["parallelIndex"] else { return nil }
        return "\(index + 1)/\(count)"
    }

    /// Whether the collapsed view is hiding any output content that expanding would reveal.
    /// Drives the "(show more)" affordance on the tool call line.
    private var toolOutputHasMore: Bool {
        guard let output = toolOutputMessage, !output.content.isEmpty else { return false }
        // When collapsed we show either nothing or a single error line. If that error
        // line is the entire output, there is nothing more to reveal.
        if let errorLine = collapsedErrorPreview(output.content) {
            return output.content.count > errorLine.count
        }
        return true
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

    /// Handles a tap on a tool call's file path. If the path exists, opens files via
    /// the default app and reveals directories in Finder. If the path doesn't exist
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
            // File: present Quick Look preview rather than opening the default app.
            // See MarkdownText.swift for rationale on the qlmanage shell-out vs.
            // QLPreviewPanel — same trade-off, same one-line answer.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            task.arguments = ["-p", expanded]
            try? task.run()
        }
    }

    @ViewBuilder

    private func genericToolRequestBody() -> some View {
        // Line 1: "[bash] pwd (more) ✅" — tool name as chip, rest in secondary.
        // Outer Button toggles expand; inner Button on path opens the file. The inner
        // Button consumes its own hits so tapping the path doesn't collapse the row.
        Button(action: { isExpanded.toggle() }, label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                let displayText = isExpanded ? message.content : toolCallDisplayText
                let toolName = message.stringMetadata("tool") ?? displayText.prefix(while: { $0 != ":" }).description
                ToolNameChip(name: toolName)
                if let path = effectiveToolFilePath {
                    Button(action: { openFileOrFallback(path: path) }, label: {
                        ToolPathText(path: path)
                    })
                    .buttonStyle(.plain)
                    let extra = remainderWithoutPath(displayText, path: path)
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
                if let indicator = dispositionIndicator {
                    if let tooltip = dispositionTooltipText {
                        Text(indicator).hoverTooltip(tooltip)
                    } else {
                        Text(indicator)
                    }
                }
            }
            .contentShape(Rectangle())
        })
        .buttonStyle(.plain)

        // Disposition comment (for WARN/UNSAFE/ABORT) — always shown in full
        if let comment = dispositionComment {
            MarkdownText(content: comment, baseFont: AppFonts.channelBody.italic())
                .foregroundStyle(dispositionCommentColor)
                .padding(.leading, 12)
        }

        // file_edit inline diff — parse old_string / new_string from params.
        // Suppress the diff if the edit failed (e.g., `old_string` not found) so the
        // UI doesn't imply a change was applied when it wasn't. The error line from the
        // tool output is still shown below.
        if message.stringMetadata("tool") == "file_edit",
           !fileEditFailed,
           let strings = effectiveFileEditStrings {
            DiffView(oldContent: strings.oldString, newContent: strings.newString)
        }

        // Tool output: suppressed when collapsed unless first line begins with "error".
        // Full content is revealed on expand.
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
            } else if !isFileRead, let errorLine = collapsedErrorPreview(output.content) {
                Text(errorLine)
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .textSelection(.enabled)
            }
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

    @ViewBuilder

    private func standaloneToolOutput() -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(message.content)
                .font(AppFonts.channelBody.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } label: {
            if case .string(let toolName) = message.metadata?["tool"] {
                Text("Output: \(toolName)")
                    .font(AppFonts.channelBody)
                    .foregroundStyle(.secondary)
            } else {
                Text("Output")
                    .font(AppFonts.channelBody)
                    .foregroundStyle(.secondary)
            }
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

    // MARK: - Collapsible message body

    /// Renders a message body with a default line limit and inline "(show more)".
    /// Summarizer messages indent from the 2nd line onwards.
    /// Reads `effectiveSplitLines` (cached via `.onChange(of: message, initial: true)`,
    /// with synchronous fallback) rather than re-splitting `message.content` on every
    /// body re-evaluation.
    @ViewBuilder
    private func collapsibleMessageBody(maxLines: Int) -> some View {
        let lines = effectiveSplitLines
        let needsTruncation = lines.count > maxLines

        if isExpanded || !needsTruncation {
            VStack(alignment: .leading, spacing: 1) {
                // For summarizer: indent all lines after the first
                if isSummarizerMessage {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        MarkdownText(content: line, baseFont: AppFonts.channelBody)
                            .padding(.leading, index > 0 ? 12 : 0)
                    }
                } else {
                    MarkdownText(content: message.content, baseFont: AppFonts.channelBody)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if needsTruncation {
                Button(action: { isExpanded = false }, label: {
                    Text("(show less)")
                        .font(.caption)
                        .foregroundStyle(AppColors.disclosureToggle)
                        .padding(.leading, isSummarizerMessage ? 12 : 0)
                })
                .buttonStyle(.plain)
            }
        } else {
            let visibleLines = Array(lines.prefix(maxLines))
            Button(action: { isExpanded = true }, label: {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(visibleLines.dropLast().enumerated()), id: \.offset) { index, line in
                        MarkdownText(content: line, baseFont: AppFonts.channelBody)
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
            })
            .buttonStyle(.plain)
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

