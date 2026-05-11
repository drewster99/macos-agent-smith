import Foundation

/// Shared building blocks for the recursive filesystem-search tools (`glob`, `directory_tree`).
///
/// Deliberately **not** used by `directory_listing` — a single-level listing shows every entry
/// in the one directory it lists; pruning there would hide what the caller explicitly asked to see.
enum FilesystemSearch {

    // MARK: - Pruning

    /// Directory *names* we never recurse into during a walk: VCS internals, build outputs,
    /// dependency caches. Pruning these keeps a `**` walk from drowning in generated files
    /// that are essentially never the thing being searched for.
    static let prunedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".build", "build", "DerivedData", "Pods", ".swiftpm"
    ]

    /// Bundle/package directory *extensions* we treat as opaque during a walk — descending into
    /// an `.xcodeproj`, a Photos `.photoslibrary`, etc. yields metadata noise, not source.
    static let prunedPackageExtensions: Set<String> = [
        "xcodeproj", "xcworkspace", "playground",
        "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "theater"
    ]

    /// True when a directory with this basename should not be descended into during a walk.
    static func isPrunedDirectoryName(_ name: String) -> Bool {
        if prunedDirectoryNames.contains(name) { return true }
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && prunedPackageExtensions.contains(ext)
    }

    /// Subpaths *relative to `$HOME`* that are pruned only when the search base IS the user's
    /// home directory — an explicit search inside one of these (`path=~/Library/Caches`) passes
    /// through. Each is huge, network-backed (iCloud Drive materializes placeholders on access),
    /// or an opaque media library. `~/Library` itself stays walkable (lots of real content under
    /// `Application Support`); only these specific descendants are skipped.
    static let homeOnlyPruneRelativePaths: [String] = [
        "Library/Caches",
        "Library/Containers",
        "Library/Mobile Documents",
        "Library/Group Containers",
        "Library/Application Support/MobileSync",
        "Library/Developer/Xcode/DerivedData",
        "Library/Developer/CoreSimulator",
        "Music/iTunes",
        "Music/Music",
        "Movies/TV",
        ".Trash"
    ]

    /// Resolved home directory path (symlinks collapsed). Computed each call — cheap and avoids
    /// caching a value that could in principle change.
    static var resolvedHomePath: String {
        (NSHomeDirectory() as NSString).resolvingSymlinksInPath
    }

    /// Absolute paths to prune when walking from `resolvedBase` — non-empty only when
    /// `resolvedBase` IS the user's home directory.
    static func homePruneAbsolutePaths(forBase resolvedBase: String) -> Set<String> {
        guard resolvedBase == resolvedHomePath else { return [] }
        return Set(homeOnlyPruneRelativePaths.map { resolvedBase + "/" + $0 })
    }

    /// True when a directory at `absolutePath` (basename `name`) should be pruned given the
    /// home-only prune set for the current walk.
    static func shouldPruneDirectory(absolutePath: String, name: String, homePruneSet: Set<String>) -> Bool {
        if isPrunedDirectoryName(name) { return true }
        return homePruneSet.contains(absolutePath)
    }

    /// One-line summary of pruning behavior, kept in sync with the constants above by
    /// construction. Suitable for inclusion in a tool description.
    static var pruneSummary: String {
        "Walks skip VCS/build/dependency directories (.git, node_modules, build, .build, DerivedData, Pods, .swiftpm) and don't descend .xcodeproj/.xcworkspace/.playground or media-library packages (.photoslibrary, .musiclibrary, .tvlibrary). Walking $HOME directly also skips Library/Caches, Library/Containers, Library/Mobile Documents, Library/Group Containers, Library/Application Support/MobileSync, Library/Developer/Xcode/DerivedData, Library/Developer/CoreSimulator, Music/iTunes, Music/Music, Movies/TV, and .Trash; pass one of those explicitly as `path` to search inside it."
    }

    // MARK: - Pathological-root rejection

    /// Absolute paths too broad to be a sane recursive-search root: huge, mostly system files,
    /// and the LLM essentially never actually wants them. Exact-match only — *children*
    /// (`/Library/Fonts`, `/Users/me/proj`) are fine. `$HOME` itself is handled in
    /// `isOverlyBroadRoot` since it isn't a compile-time constant.
    private static let staticRootBlocklist: Set<String> = [
        "/", "/System", "/usr", "/bin", "/sbin", "/private", "/dev", "/cores",
        "/opt", "/Library", "/Volumes", "/Users"
    ]

    /// True when `resolvedPath` (an already symlink-resolved absolute path) is one of the
    /// blocklisted overly-broad roots — including the user's home directory itself. A `~`-prefixed
    /// path that expands to a *sub*-directory (`~/projects/foo`) is fine; only `~`/`~/`/the literal
    /// home dir is rejected.
    static func isOverlyBroadRoot(_ resolvedPath: String) -> Bool {
        staticRootBlocklist.contains(resolvedPath) || resolvedPath == resolvedHomePath
    }
}

extension Duration {
    /// Total seconds as a `Double`. `components.attoseconds` carries any sub-second fraction;
    /// both are folded in so `.milliseconds(500).seconds` correctly yields `0.5`.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
