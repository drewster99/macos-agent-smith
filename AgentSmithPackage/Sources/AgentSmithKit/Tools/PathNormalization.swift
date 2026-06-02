import Foundation

/// Single source of truth for turning an LLM-supplied path string into a filesystem path.
///
/// LLM agents pass paths in three forms that need normalizing before we touch the disk
/// (or key the per-agent read tracker on them):
/// - `file://` URLs — strip the scheme and percent-decode (`%20` → space).
/// - Shell-escaped paths (an agent that reflexively quotes for bash) — strip backslash
///   escapes for the common shell-special characters (` `, `(`, `)`, `&`, `'`, `"`, `;`,
///   `*`, `?`, `[`, `]`).
/// - Tilde-prefixed paths — expand to the user's home dir.
///
/// Empty / relative inputs pass through unchanged; callers that require an absolute path
/// enforce that separately. The transformation is idempotent.
enum PathNormalization {
    /// Normalize a raw path string. Order matters: percent-decode first (for the `file://`
    /// case), then unescape (for the shell case), then expand tilde. The three
    /// transformations don't overlap in practice (no LLM passes a percent-encoded
    /// shell-escaped path).
    static func normalize(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw

        // Strip leading `file://` scheme. Both `file://` and `file:///` are accepted — the
        // former leaves a leading `/` (correct for absolute paths), the latter strips one
        // slash too. Use a URL parse when it's a valid file URL; fall back to string
        // trimming when it isn't.
        if s.lowercased().hasPrefix("file://") {
            if let url = URL(string: s), url.isFileURL {
                s = url.path(percentEncoded: false)
            } else {
                s.removeFirst("file://".count)
                if let decoded = s.removingPercentEncoding {
                    s = decoded
                }
            }
        }

        s = unescapeShellPath(s)
        return (s as NSString).expandingTildeInPath
    }

    /// Boundary-aware containment test for blocklist matching.
    ///
    /// Returns `true` only when `path` equals `prefix` or is a child of it — never when
    /// `path` merely shares a textual prefix (e.g. `/Libraryland` is NOT under `/Library`,
    /// and `~/.sshbackup` is NOT under `~/.ssh`). A bare `hasPrefix` over-blocks those.
    ///
    /// Both operands are assumed to be already resolved/normalized absolute paths (callers
    /// resolve symlinks before invoking). The comparison is case-insensitive to match the
    /// pre-existing blocklist behavior (APFS is case-insensitive, so `/SYSTEM` must match
    /// `/System`).
    static func isSubpath(_ path: String, ofOrEqualTo prefix: String) -> Bool {
        let p = path.lowercased()
        let base = prefix.lowercased()
        return p == base || p.hasPrefix(base + "/")
    }

    /// Strips backslash escapes for shell-special characters commonly inserted by an LLM
    /// that's been over-trained to quote paths for bash. Replaces `\X` with `X` for X in
    /// `[ ()&'";*?[]]`. A literal backslash followed by any other character is preserved
    /// (e.g. `\n` stays `\n` — newlines aren't valid in macOS filenames anyway).
    private static func unescapeShellPath(_ raw: String) -> String {
        let escapable: Set<Character> = [" ", "(", ")", "&", "'", "\"", ";", "*", "?", "[", "]"]
        var out = ""
        out.reserveCapacity(raw.count)
        var iterator = raw.makeIterator()
        while let c = iterator.next() {
            if c == "\\", let next = iterator.next() {
                if escapable.contains(next) {
                    out.append(next)
                } else {
                    out.append(c)
                    out.append(next)
                }
            } else {
                out.append(c)
            }
        }
        return out
    }
}
