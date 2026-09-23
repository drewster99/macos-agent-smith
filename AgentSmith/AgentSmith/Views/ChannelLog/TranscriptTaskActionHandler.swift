import SwiftUI
import AgentSmithKit

/// A one-click task control offered inline on a user-task-action notice in the transcript.
enum TranscriptInlineTaskAction {
    case resume
    case undelete

    var title: String {
        switch self {
        case .resume: return "Resume"
        case .undelete: return "Undelete"
        }
    }

    var symbolName: String {
        switch self {
        case .resume: return "play.fill"
        case .undelete: return "arrow.uturn.backward"
        }
    }
}

/// Resolves and performs a notice's inline control against LIVE task state.
///
/// Injected through the environment rather than threaded through `ChannelLogView`, whose `==`
/// deliberately ignores everything but the message list: only notice rows read this, and because
/// `availableAction` reads the observable view model inside the row's body, Observation re-renders
/// just those rows when the task moves — the button disappears once the task leaves the state the
/// notice describes. The default offers nothing, so a pane that doesn't inject it shows no button.
struct TranscriptTaskActionHandler {
    let availableAction: @MainActor (_ notice: UserTaskAction, _ taskID: UUID) -> TranscriptInlineTaskAction?
    let perform: @MainActor (_ action: TranscriptInlineTaskAction, _ taskID: UUID) async -> Void

    static let unavailable = TranscriptTaskActionHandler(
        availableAction: { _, _ in nil },
        perform: { _, _ in }
    )
}

private struct TranscriptTaskActionHandlerKey: EnvironmentKey {
    static let defaultValue = TranscriptTaskActionHandler.unavailable
}

extension EnvironmentValues {
    var transcriptTaskActionHandler: TranscriptTaskActionHandler {
        get { self[TranscriptTaskActionHandlerKey.self] }
        set { self[TranscriptTaskActionHandlerKey.self] = newValue }
    }
}
