import Foundation

/// The paths git ignores under one search root, read once per search (`glob`'s `respect_gitignore`,
/// #29), so filtering is a set lookup rather than a git call per file. Paths are relative to the
/// search root, exactly as `glob` reports matches.
///
/// It honors everything git does — nested `.gitignore` files, `.git/info/exclude`, the global
/// excludes file — because git computes it. A tracked file is never "ignored", whatever the rules
/// say; git doesn't apply ignore rules to tracked files either. A nested repository that isn't a
/// submodule is opaque to the outer one, so its own ignore rules aren't applied.
struct GitIgnoreSnapshot: Sendable, Equatable {
    /// Ignored files, relative to the search root (lowercased when `caseInsensitive`).
    let ignoredFiles: Set<String>
    /// Ignored directories (everything inside is ignored), relative to the search root
    /// (lowercased when `caseInsensitive`).
    let ignoredDirectories: Set<String>
    /// The search root itself is inside an ignored directory, so everything under it is ignored.
    let rootIgnored: Bool
    /// The root's volume doesn't distinguish case, so `Generated/x` is the same file as git's
    /// `generated/x` — and a glob literal segment spells a path the way the PATTERN does.
    let caseInsensitive: Bool

    /// Whether `relativePath` (a file or directory under the search root, `""` for the root) is
    /// ignored: itself, or inside an ignored directory.
    func isIgnored(_ relativePath: String) -> Bool {
        let key = caseInsensitive ? relativePath.lowercased() : relativePath
        if rootIgnored || ignoredFiles.contains(key) { return true }
        var ancestor = Substring(key)
        while !ancestor.isEmpty {
            if ignoredDirectories.contains(String(ancestor)) { return true }
            guard let slash = ancestor.lastIndex(of: "/") else { break }
            ancestor = ancestor[..<slash]
        }
        return false
    }

    /// Builds a snapshot from `git ls-files -z --others --ignored --exclude-standard --directory`
    /// run at the repository's top level over the whole work tree: NUL-separated paths relative to
    /// the top level, a directory marked by a trailing `/`. `rootPrefix` is the search
    /// root relative to the top level (`git rev-parse --show-prefix`: empty, or ending in `/`).
    ///
    /// An entry under the root is kept, relative to it; an ignored directory that CONTAINS the root
    /// means the whole root is ignored; anything else is outside the root and dropped.
    static func parse(lsFilesOutput output: String, rootPrefix: String, caseInsensitive: Bool) -> GitIgnoreSnapshot {
        var files: Set<String> = []
        var directories: Set<String> = []
        var rootIgnored = false
        for entry in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let isDirectory = entry.hasSuffix("/")
            let path = isDirectory ? String(entry.dropLast()) : String(entry)
            let relative: String
            if rootPrefix.isEmpty {
                relative = path
            } else if path.hasPrefix(rootPrefix) {
                relative = String(path.dropFirst(rootPrefix.count))
            } else {
                if isDirectory, rootPrefix.hasPrefix(path + "/") { rootIgnored = true }
                continue
            }
            let key = caseInsensitive ? relative.lowercased() : relative
            if isDirectory {
                directories.insert(key)
            } else {
                files.insert(key)
            }
        }
        return GitIgnoreSnapshot(ignoredFiles: files, ignoredDirectories: directories, rootIgnored: rootIgnored, caseInsensitive: caseInsensitive)
    }

    /// Why a snapshot couldn't be taken. Each reads as the end of "respect_gitignore was not applied: …".
    enum Unavailable: Error, Equatable {
        case gitNotInstalled
        /// git doesn't place the root in a work tree; `gitSays` is git's own reason (not a repository,
        /// a repository it refuses as unsafe), quoted rather than interpreted — empty when git just
        /// answered "no" (inside `.git`, a bare repository).
        case notInAWorkTree(root: String, gitSays: String)
        case gitFailed(String)
        /// Whether the root's volume tells case apart couldn't be read, so lookups couldn't be
        /// matched to it.
        case volumeUnreadable(String)

        var explanation: String {
            switch self {
            case .gitNotInstalled: return "git isn't available (the Xcode Command Line Tools aren't installed)"
            case .notInAWorkTree(let root, let gitSays):
                return gitSays.isEmpty ? "\(root) isn't inside a git work tree" : "\(root) isn't inside a git work tree (git: \(gitSays))"
            case .gitFailed(let reason): return "git failed: \(reason)"
            case .volumeUnreadable(let reason): return "couldn't tell whether the volume is case-sensitive: \(reason)"
            }
        }
    }

    /// Takes a snapshot for `root`, spending at most `budget` seconds across all its git calls.
    /// git is checked for first through `xcode-select`, because running `/usr/bin/git` without the
    /// Command Line Tools pops an install dialog instead of failing. `core.fsmonitor` is forced off:
    /// an untrusted repository's config could otherwise name a program for git to run.
    ///
    /// `ls-files` lists the WHOLE work tree from its top level and the root's share is picked out
    /// here, rather than listing from the root or with the root as a pathspec: for a root two or
    /// more levels inside an ignored directory that holds no tracked file, both of those abort
    /// ("directory entry not superset of prefix"). `--directory` collapses each ignored directory
    /// to one entry, so the listing stays small — though git still visits every untracked directory
    /// in the work tree, which on a very large one can spend the budget and report a timeout.
    static func take(forRoot root: String, budget: TimeInterval) async -> Result<GitIgnoreSnapshot, Unavailable> {
        let deadline = Date().addingTimeInterval(budget)
        let timedOut = Unavailable.gitFailed("timed out after \(Int(budget))s")
        do {
            let tools = try await ProcessRunner.run(executable: "/usr/bin/xcode-select", arguments: ["-p"], workingDirectory: nil, timeout: deadline.timeIntervalSinceNow)
            guard !tools.timedOut else { return .failure(timedOut) }
            guard tools.exitCode == 0 else { return .failure(.gitNotInstalled) }
            let config = ["-c", "core.fsmonitor=false"]
            // Each later call gets what is left of the one budget; none starts once it is spent.
            guard deadline.timeIntervalSinceNow > 0 else { return .failure(timedOut) }

            // Standard error stays merged here: when the answer is "no", it is git's reason.
            let inside = try await ProcessRunner.run(
                executable: "/usr/bin/git", arguments: ["-C", root] + config + ["rev-parse", "--is-inside-work-tree"],
                workingDirectory: nil, timeout: deadline.timeIntervalSinceNow
            )
            guard !inside.timedOut else { return .failure(timedOut) }
            let insideAnswer = inside.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard inside.exitCode == 0, insideAnswer == "true" else {
                return .failure(.notInAWorkTree(root: root, gitSays: inside.exitCode == 0 ? "" : insideAnswer))
            }

            // Standard error is discarded from here on: a warning interleaved into output this
            // parses would corrupt it.
            guard deadline.timeIntervalSinceNow > 0 else { return .failure(timedOut) }
            let location = try await ProcessRunner.run(
                executable: "/usr/bin/git", arguments: ["-C", root] + config + ["rev-parse", "--show-toplevel", "--show-prefix"],
                workingDirectory: nil, timeout: deadline.timeIntervalSinceNow, standardError: .discarded
            )
            guard !location.timedOut else { return .failure(timedOut) }
            // Exactly "<top level>\n<prefix>\n". Anything else — a path containing a newline — would
            // put part of the top level into the prefix, so it is refused rather than guessed at.
            let lines = location.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard location.exitCode == 0, location.outputIsUTF8, lines.count == 3, !lines[0].isEmpty, lines[2].isEmpty else {
                return .failure(.gitFailed("rev-parse couldn't locate the work tree (exit status \(location.exitCode))"))
            }
            let topLevel = lines[0]
            let rootPrefix = lines[1]

            guard deadline.timeIntervalSinceNow > 0 else { return .failure(timedOut) }
            let listing = try await ProcessRunner.run(
                executable: "/usr/bin/git",
                arguments: ["-C", topLevel] + config
                    + ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"],
                workingDirectory: nil, timeout: deadline.timeIntervalSinceNow, standardError: .discarded
            )
            guard !listing.timedOut else { return .failure(timedOut) }
            guard listing.exitCode == 0 else { return .failure(.gitFailed("ls-files exited with status \(listing.exitCode)")) }
            guard listing.outputIsUTF8 else { return .failure(.gitFailed("ls-files listed a path that isn't valid UTF-8")) }

            let caseSensitive: Bool
            do {
                let volume = try URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                guard let known = volume.volumeSupportsCaseSensitiveNames else {
                    return .failure(.volumeUnreadable("the volume doesn't say"))
                }
                caseSensitive = known
            } catch {
                return .failure(.volumeUnreadable(error.localizedDescription))
            }
            return .success(parse(lsFilesOutput: listing.output, rootPrefix: rootPrefix, caseInsensitive: !caseSensitive))
        } catch {
            return .failure(.gitFailed(error.localizedDescription))
        }
    }
}
