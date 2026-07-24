import SwiftUI
import AgentSmithKit
import SwiftLLMKit

/// Centralized color definitions with semantic names.
enum AppColors {
    static let smithAgent = Color.green
    static let brownAgent = Color.orange
    static let securityAgent = Color.red
    static let summarizerAgent = Color.blue
    static let validatorAgent = Color.teal
    private static let userMessage = Color.blue
    static let systemMessage = Color.gray
    static let background = Color(.windowBackgroundColor)
    static let secondaryBackground = Color(.controlBackgroundColor)

    // Structured result deliverables (task detail)
    static let deliverableCardBackground = Color(.controlBackgroundColor)
    static let deliverableCardBorder = Color(.separatorColor)
    static let deliverableTagBackground = Color.accentColor.opacity(0.14)
    static let deliverableTagForeground = Color.accentColor

    static let channelBackground = Color(.textBackgroundColor)
    static let errorBackground = Color.red.opacity(0.12)
    /// Subtle highlight for Smith→User private messages to draw attention to agent output.
    static let smithToUserBackground = Color.green.opacity(0.08)
    /// Accent for new-task banners in the channel log.
    static let taskCreatedAccent = Color.blue
    /// Accent for task-completed banners in the channel log.
    static let taskCompletedAccent = Color(red: 0.85, green: 0.65, blue: 0.13)
    /// Accent for task-acknowledged banners in the channel log.
    static let taskAcknowledgedAccent = Color.cyan
    /// Accent for task-update banners in the channel log.
    static let taskUpdateAccent = Color.orange
    /// Accent for Brown's task_complete submission (awaiting Smith's review).
    static let taskReadyForReviewAccent = Color.purple
    /// Accent for Smith's rejection / changes-requested messages.
    static let changesRequestedAccent = Color(red: 0.90, green: 0.35, blue: 0.35)

    // MARK: - Channel-log row tints

    /// Background tint for tool-request rows whose security review returned WARN/DENY.
    static let warningRowBackground = Color.orange.opacity(0.10)
    /// Full-screen image lightbox backdrop.
    static let lightboxBackdrop = Color.black.opacity(0.85)
    /// Drop-target overlay tint when files are dragged over MainView.
    static let dropTargetTint = Color.blue.opacity(0.08)

    // MARK: - Affordances / inline action text

    /// "(show more)" / "(show less)" / "Restore full history" inline buttons.
    static let disclosureToggle = Color.blue

    // MARK: - Acceptance validation

    static let verdictAccepted = Color.green
    static let verdictRejected = Color(red: 0.90, green: 0.35, blue: 0.35)
    static let verdictWaived = Color.orange
    static let verdictError = Color.red
    static let verdictPending = Color.secondary

    // MARK: - Task success measure (graded outcome)

    /// All criteria accepted — an unqualified win.
    static let outcomeSuccess = Color.green
    /// Completed, but with waivers — met, with carve-outs. Amber-gold reads as "good, noted."
    static let outcomePass = Color(red: 0.82, green: 0.66, blue: 0.20)
    /// Failed / stalled — matches the rejected-verdict red.
    static let outcomeIncomplete = Color(red: 0.90, green: 0.35, blue: 0.35)
    /// Escalated — the machine couldn't judge; needs the user.
    static let outcomeReview = Color.orange

    // MARK: - Worker step statuses

    static let stepCompleted = Color.green
    static let stepInProgress = Color.blue
    static let stepSkipped = Color.orange
    static let stepRemoved = Color.gray

    // MARK: - Security-review dispositions

    static let securityApproved = Color.green
    static let securityWarning = Color.orange
    static let securityDenied = Color.orange
    static let securityAbort = Color.red

    // MARK: - Tool-row inline accents

    /// Filename portion of an inline tool path (`ToolPathText`).
    static let toolPathFilename = Color.cyan
    /// Resolved destination of a symlink shown next to the source path.
    static let symlinkDestination = Color.purple.opacity(0.8)

    // MARK: - Inspector / LLM turn rendering

    /// "Outgoing" arrow + label color in the per-turn inspector.
    static let inspectorOutgoing = Color.blue
    /// "Response" arrow + label color in the per-turn inspector.
    static let inspectorResponse = Color.green
    /// Reasoning / thinking text color in the per-turn inspector.
    static let inspectorReasoning = Color.purple
    /// Tool-call arg label color in the per-turn inspector.
    static let inspectorToolCallArg = Color.orange

    // MARK: - Diff view

    static let diffAddedBackground = Color.green.opacity(0.12)
    static let diffRemovedBackground = Color.red.opacity(0.12)
    static let diffAddedForeground = Color.green
    static let diffRemovedForeground = Color.red

    // MARK: - Launch splash

    /// Backdrop fill behind the launch splash logo. A near-black tone that
    /// matches the dark vignette of the logo art so the image edges blend in.
    static let splashBackground = Color(red: 0.06, green: 0.08, blue: 0.10)
    /// Soft cyan-tinted glow surrounding the launch logo.
    static let splashLogoGlow = Color(red: 0.30, green: 0.85, blue: 0.80).opacity(0.35)
    /// Drop shadow under the launch logo.
    static let splashLogoShadow = Color.black.opacity(0.55)
    /// Subtle inner stroke around the rounded launch logo.
    static let splashLogoStroke = Color.white.opacity(0.08)

    // MARK: - Markdown view

    static let codeBlockBackground = Color.secondary.opacity(0.10)
    static let codeBlockBorder = Color.secondary.opacity(0.20)
    static let tableHeaderBackground = Color.secondary.opacity(0.12)
    static let tableBorder = Color.secondary.opacity(0.25)
    static let inlineCode = Color.cyan

    // MARK: - Inspector / shared row chrome

    static let subtleRowBackground = Color.secondary.opacity(0.06)
    static let subtleRowBackgroundDim = Color.secondary.opacity(0.05)
    static let subtleRowBackgroundLift = Color.secondary.opacity(0.08)
    static let toolCallInspectorTint = Color.orange.opacity(0.05)
    static let inactiveDot = Color.secondary.opacity(0.40)
    static let dimSecondary30 = Color.secondary.opacity(0.30)
    static let dimSecondary35 = Color.secondary.opacity(0.35)

    // MARK: - Banners / chips

    static let flagChipBackground = Color.blue.opacity(0.15)
    static let flagChipForeground = Color.blue
    static let summarySectionBackground = Color.purple.opacity(0.06)

    // MARK: - Task detail
    /// Tinted background for the AI Commentary inset inside the Result section.
    static let aiCommentaryBackground = Color.purple.opacity(0.07)
    /// Stroke around the AI Commentary inset.
    static let aiCommentaryBorder = Color.purple.opacity(0.30)
    /// Tint for a future scheduled run time in the metadata header.
    static let scheduledFutureAccent = Color.green
    /// Tint for a past-due scheduled run time in the metadata header.
    static let scheduledPastDueAccent = Color.orange
    /// Header tint for the Error section on a failed task.
    static let errorSectionAccent = Color.red
    /// Tint for the spelled-out `(more)` / `(less)` disclosure links used in
    /// `TaskDetailWindow` sections and rows. Distinct from `disclosureToggle` so the
    /// link reads as interactive without colliding with chevron-style toggles.
    static let moreLessLink = Color.accentColor
    static let cyanBadgeForeground = Color.cyan
    static let cyanBadgeBackground = Color.cyan.opacity(0.15)
    static let toolChipForeground = Color.blue
    static let toolChipBackground = Color.blue.opacity(0.12)
    static let toolChipBorder = Color.blue.opacity(0.40)

    /// Returns the color for a given channel message sender.
    static func color(for sender: ChannelMessage.Sender) -> Color {
        switch sender {
        case .agent(.smith): return smithAgent
        case .agent(.brown): return brownAgent
        case .agent(.securityAgent): return securityAgent
        case .agent(.summarizer): return summarizerAgent
        case .user: return userMessage
        case .system: return systemMessage
        case .validator: return validatorAgent
        }
    }

    /// Returns the soft background tint used for an LLMMessage row in the inspector,
    /// keyed by the role.
    static func contextRowBackground(for role: LLMMessage.Role) -> Color {
        switch role {
        case .system: return Color.secondary.opacity(0.05)
        case .user: return Color.blue.opacity(0.05)
        case .assistant: return Color.green.opacity(0.05)
        case .tool: return Color.orange.opacity(0.05)
        case .developer: return Color.secondary.opacity(0.05)
        }
    }
}

/// Centralized font definitions.
enum AppFonts {
    /// Task-overlay bar: the status chip in a column header.
    static let taskOverlayChip = Font.system(size: 9, weight: .bold)
    /// Task-overlay bar: step/criterion status icons and header buttons.
    static let taskOverlayIcon = Font.system(size: 10)
    /// Task-overlay bar: the column dismiss (✕) button.
    static let taskOverlayDismiss = Font.system(size: 10, weight: .semibold)

    static let channelSender = Font.system(.caption, design: .monospaced, weight: .bold)
    static let channelBody = Font.system(.body, design: .monospaced)
    static let channelTimestamp = Font.system(.caption2, design: .monospaced)
    static let taskTitle = Font.headline
    /// Title font for compact (child) task rows. Deliberately unbolded — a template's runs
    /// almost always share the parent's title, so the title is context rather than headline.
    static let taskTitleCompact = Font.system(.subheadline, weight: .regular)
    static let taskDescription = Font.subheadline
    static let sectionHeader = Font.title3.bold()
    static let inputField = Font.system(.body, design: .monospaced)
    static let markdownH1 = Font.system(.title2, design: .default, weight: .bold)
    static let markdownH2 = Font.system(.title3, design: .default, weight: .bold)
    static let markdownH3 = Font.system(.headline, design: .default, weight: .bold)
    static let inspectorLabel = Font.system(.caption, design: .monospaced)
    static let inspectorBody = Font.system(.caption2, design: .monospaced)
    /// 13pt — banner header icons (New Task, Task Completed, etc.).
    static let bannerIcon = Font.system(size: 13)
    /// 12pt — banner secondary icons (Ready for Review tray icon).
    static let bannerIconMedium = Font.system(size: 12)
    /// 11pt — clock chips, secondary banner icons.
    static let bannerIconSmall = Font.system(size: 11)
    /// 10pt — inspector inline meta icons.
    static let metaIconSmall = Font.system(size: 10)
    /// 9pt — inline lock / wrench / terminal meta icons.
    static let metaIcon = Font.system(size: 9)
    /// 8pt — micro chevrons.
    static let microIcon = Font.system(size: 8)
    /// 9pt monospaced badge text used for disposition / response-type chips.
    static let microMonoBadge = Font.system(size: 9, weight: .medium, design: .monospaced)
    /// 9pt monospaced for tool-call inspector code text.
    static let microMonoCode = Font.system(size: 9, design: .monospaced)
    /// 10pt monospaced — argument fragment under tool calls.
    static let smallMonoCode = Font.system(size: 10, design: .monospaced)
    /// 8pt monospaced — turn-row index column.
    static let microMonoIndex = Font.system(size: 8, weight: .medium, design: .monospaced)
    /// 11pt monospaced — turn header model id.
    static let modelIDLabel = Font.system(size: 11, weight: .medium, design: .monospaced)
    /// 40pt — welcome screen wave icon.
    static let welcomeIcon = Font.system(size: 40)
    /// 22pt — onboarding "what should I call you?" name field (large, friendly input).
    static let onboardingNameField = Font.system(size: 22)
    /// 42pt rounded bold — spending dashboard headline cost number.
    static let dashboardHeadline = Font.system(size: 42, weight: .bold, design: .rounded)
    /// Title font for the AI Commentary inset (smaller than `sectionHeader`).
    static let aiCommentaryTitle = Font.subheadline.weight(.semibold)
    /// Body font for the AI Commentary inset.
    static let aiCommentaryBody = Font.callout

    // MARK: PDF export (TaskPDFDocumentView)
    // Fixed point sizes (not Dynamic Type styles) because these render into a fixed-size
    // PDF page via ImageRenderer, where the document layout must be deterministic.
    /// 22pt bold — PDF document title.
    static let pdfTitle = Font.system(size: 22, weight: .bold)
    /// 12pt — PDF body, subtitle, and metadata text.
    static let pdfBody = Font.system(size: 12)
    /// 15pt semibold — PDF section headings (Description / Summary / Result).
    static let pdfSectionHeader = Font.system(size: 15, weight: .semibold)
    /// 9pt — PDF footer line.
    static let pdfFooter = Font.system(size: 9)
}

/// Pricing display formatting.
enum PricingFormatter {
    /// Compact pricing summary string for display (e.g., "$3.00 in / $15.0 out per M").
    static func summary(_ pricing: ModelPricing) -> String {
        var parts: [String] = []
        if let input = pricing.base.input {
            parts.append("\(costPerMillion(input * 1_000_000)) in")
        }
        if let output = pricing.base.output {
            parts.append("\(costPerMillion(output * 1_000_000)) out")
        }
        guard !parts.isEmpty else { return "" }
        var result = parts.joined(separator: " / ") + " per M"
        if !pricing.tokenThresholdTiers.isEmpty {
            result += " (tiered)"
        }
        return result
    }

    /// Formats a cost-per-million-tokens value as a compact dollar string.
    static func costPerMillion(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else if cost < 1 {
            return String(format: "$%.2f", cost)
        } else {
            return String(format: "$%.1f", cost)
        }
    }
}

/// Task status badge styling.
enum TaskStatusBadge {
    static func color(for status: AgentTask.Status) -> Color {
        switch status {
        case .pending: return .gray
        case .starting: return .cyan
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .paused: return .indigo
        case .awaitingReview: return .orange
        case .interrupted: return .yellow
        case .scheduled: return .purple
        case .validating: return .teal
        }
    }

    static func icon(for status: AgentTask.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .starting: return "hourglass"
        case .running: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .awaitingReview: return "eye.circle.fill"
        case .interrupted: return "exclamationmark.circle.fill"
        case .scheduled: return "clock.badge"
        case .validating: return "checklist"
        }
    }
}

/// Color + SF Symbol for a task's graded success measure (`TaskOutcome`). Parallels
/// `TaskStatusBadge` but keyed on the derived outcome rather than the lifecycle status.
enum TaskOutcomeBadge {
    static func color(for outcome: TaskOutcome) -> Color {
        switch outcome {
        case .success: return AppColors.outcomeSuccess
        case .pass: return AppColors.outcomePass
        case .incomplete: return AppColors.outcomeIncomplete
        case .needsReview: return AppColors.outcomeReview
        }
    }

    static func icon(for outcome: TaskOutcome) -> String {
        switch outcome {
        case .success: return "checkmark.seal.fill"
        case .pass: return "checkmark.circle.fill"
        case .incomplete: return "xmark.circle.fill"
        case .needsReview: return "exclamationmark.triangle.fill"
        }
    }
}
