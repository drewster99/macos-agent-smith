import AppKit
import AgentSmithKit
import os

/// Opens a local path named in agent-authored content without ever launching it: markdown opens in
/// its default app, other files preview in Quick Look, packages (apps included) are selected in
/// Finder, plain folders open in Finder. The
/// decision is `LocalItemDisposition` (AgentSmithKit, unit-tested); this only performs it.
enum LocalItemOpener {
    private static let logger = Logger(subsystem: "com.agentsmith", category: "LocalItemOpener")

    /// Performs the action for `url` and returns what was decided, so a caller can react to
    /// `.missing` (the path vanished since it was linked).
    @discardableResult
    static func open(_ url: URL) -> LocalItemDisposition {
        let disposition = LocalItemDisposition.disposition(for: url)
        switch disposition {
        case .preview(let target):
            QuickLookPreview.present(target)
        case .openInDefaultApp(let target):
            if !NSWorkspace.shared.open(target) {
                logger.error("No app could open \(target.path(percentEncoded: false), privacy: .public)")
            }
        case .reveal(let target):
            NSWorkspace.shared.activateFileViewerSelecting([target])
        case .browse(let target):
            if !NSWorkspace.shared.open(target) {
                logger.error("Finder could not open folder \(target.path(percentEncoded: false), privacy: .public)")
            }
        case .missing:
            break
        }
        return disposition
    }
}
