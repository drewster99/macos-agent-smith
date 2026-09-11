import Foundation
import os

nonisolated private let quickLookLogger = Logger(subsystem: "com.agentsmith", category: "QuickLook")

/// Presents a file in a system Quick Look window.
///
/// Shells out to `/usr/bin/qlmanage -p` rather than driving `QLPreviewPanel`, which needs a
/// long-lived data source and panel-controller wiring to show what one `Process` invocation shows.
/// It is deliberately not "open in the default app" either: a peek is the point, and launching
/// Preview/Xcode/whatever owns the extension is a heavier, different action.
///
/// Fire-and-forget by design — the child outlives this call and exits when the user dismisses the
/// Quick Look window, so there is nothing to wait on.
enum QuickLookPreview {

    /// Opens a Quick Look window for `url` and returns immediately.
    ///
    /// Existence is the caller's business; every call site already checks it.
    ///
    /// A launch failure means `qlmanage` is missing or unspawnable — machine-constant and
    /// user-uncorrectable, so it is logged rather than surfaced: an alert would fire on every
    /// preview click forever and tell the user nothing they could act on. It cannot report that
    /// Quick Look failed to RENDER a file; `qlmanage` decides that after launch, and nothing here
    /// observes the child.
    ///
    /// `nonisolated` because the target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
    /// which would otherwise pin a pure syscall with no actor state to the main actor and make it
    /// uncallable from anywhere else.
    nonisolated static func present(_ url: URL) {
        let path = url.path(percentEncoded: false)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        task.arguments = ["-p", path]
        do {
            try task.run()
        } catch {
            quickLookLogger.error(
                "Quick Look launch failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
