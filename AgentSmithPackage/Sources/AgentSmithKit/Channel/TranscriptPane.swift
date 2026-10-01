import Foundation

/// A named, one-click transcript view.
public struct TranscriptViewPreset: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    /// One short line saying what the preset shows.
    public let summary: String
    public let config: TranscriptViewConfig

    public static let conversation = TranscriptViewPreset(
        id: "conversation", title: "Conversation",
        summary: "You and Smith — no worker, task, tool, or security traffic",
        config: .conversation)

    public static let everything = TranscriptViewPreset(
        id: "everything", title: "Everything",
        summary: "Every message, unfiltered",
        config: .everything)

    public static let condensed = TranscriptViewPreset(
        id: "condensed", title: "Condensed",
        summary: "Every step, without tool output or security reviews",
        config: .condensed)
}

/// Which transcript pane a filter configures. The panes answer different questions, so each has
/// its own default, its own presets, and its own subset of controls.
public enum TranscriptPane: Sendable, Equatable {
    /// The bottom pane: the whole session.
    case session
    /// The top pane: one task's transcript.
    case task

    public var title: String {
        switch self {
        case .session: return "Session transcript"
        case .task: return "Task transcript"
        }
    }

    public var defaultConfig: TranscriptViewConfig {
        switch self {
        case .session: return .conversation
        case .task: return .everything
        }
    }

    public var presets: [TranscriptViewPreset] {
        switch self {
        case .session: return [.conversation, .everything]
        case .task: return [.everything, .condensed]
        }
    }

    /// Whether the "hide per-task work" scope control applies. The task pane is always scoped to
    /// its task, so offering it there would be a control that does nothing.
    public var offersTaskScopeControl: Bool { self == .session }

    /// The preset `config` is identical to, judged only on what THIS pane honors — the task pane
    /// ignores `hideTaskScoped`, so a stray value there must not turn a preset into "Custom".
    public func preset(matching config: TranscriptViewConfig) -> TranscriptViewPreset? {
        let honored = normalized(config)
        return presets.first { normalized($0.config) == honored }
    }

    /// Whether `config` differs from this pane's default in anything the pane honors.
    public func isCustomized(_ config: TranscriptViewConfig) -> Bool {
        normalized(config) != normalized(defaultConfig)
    }

    private func normalized(_ config: TranscriptViewConfig) -> TranscriptViewConfig {
        guard !offersTaskScopeControl else { return config }
        var copy = config
        copy.hideTaskScoped = false
        return copy
    }
}
