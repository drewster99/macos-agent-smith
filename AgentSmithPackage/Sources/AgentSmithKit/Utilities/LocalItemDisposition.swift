import Foundation
import os

/// What clicking a local path an agent named should do — decided without AppKit so the package
/// tests can pin it. The app performs the action (`LocalItemOpener`).
///
/// Nothing here ever means "launch": a path in agent-authored text is untrusted, and handing a
/// package (an `.app` above all) to `NSWorkspace.open` runs it on one click.
public enum LocalItemDisposition: Equatable, Sendable {
    /// A file: peek at it in Quick Look, never open it in the app that owns its type
    /// (`.terminal`, `.webloc`, `.fileloc` act when opened).
    case preview(URL)
    /// A package (app, bundle, document package), or a directory whose package-ness could not
    /// be read: select it in Finder, which shows it without running it.
    case reveal(URL)
    /// A plain folder: open it in Finder to show its contents.
    case browse(URL)
    /// Nothing is there (including a dangling symlink).
    case missing

    private static let logger = Logger(subsystem: "com.agentsmith", category: "LocalItemDisposition")

    /// Decides what to do with `url`. The URL carried by each case is the symlink-RESOLVED target —
    /// act on it, not on `url`, so the action hits exactly what was classified. Resolution comes
    /// first because a symlink to an app is not itself a package.
    public static func disposition(for url: URL) -> LocalItemDisposition {
        let target = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        // `fileExists` follows links, so a dangling one lands here; `resourceValues` would not
        // throw for it and it would be "previewed".
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false),
                                             isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else { return .preview(target) }
        do {
            let values = try target.resourceValues(forKeys: [.isPackageKey])
            guard let isPackage = values.isPackage else {
                logger.error("isPackage unavailable for \(target.path(percentEncoded: false), privacy: .public); revealing instead of opening")
                return .reveal(target)
            }
            return isPackage ? .reveal(target) : .browse(target)
        } catch {
            // Unknown package-ness must not fall through to `.browse` — that is the launch path.
            logger.error("isPackage lookup failed for \(target.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public); revealing instead of opening")
            return .reveal(target)
        }
    }
}
