import Foundation

// MARK: - Pattern segments (Sendable)

/// A single segment of a parsed glob pattern. The pattern `**/src/*.swift` decomposes into
/// `[.doubleStar, .literal("src"), .wildcard(*.swift)]`.
///
/// `**` is its own case (not a `.wildcard`) because the structural matcher handles it specially:
/// `**` matches zero-or-more path components and drives the only step that actually walks a
/// subtree. Pure-literal segments are cheap one-`stat` lookups; pure-wildcard segments need a
/// `contentsOfDirectory` of the current dir.
enum PatternSegment: Sendable, Hashable {
    case doubleStar
    case literal(String)
    case wildcard(CompiledGlob)
}

/// A compiled single-segment glob (e.g. `*.swift`, `test?`, `*.{ts,tsx}`). The regex is anchored
/// `^...$` and matches a *name* (no `/`). `NSRegularExpression` is documented thread-safe but
/// isn't marked `Sendable` in the SDK, hence `@unchecked Sendable`.
struct CompiledGlob: @unchecked Sendable, Hashable {
    let raw: String
    let regex: NSRegularExpression

    init(_ glob: String) throws {
        self.raw = glob
        let regexBody = GlobTool.globToRegex(glob)
        self.regex = try NSRegularExpression(pattern: "^\(regexBody)$")
    }

    func matches(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    static func == (lhs: CompiledGlob, rhs: CompiledGlob) -> Bool { lhs.raw == rhs.raw }
    func hash(into hasher: inout Hasher) { hasher.combine(raw) }
}

// MARK: - Spotlight query plan

/// Coarse Spotlight query derived from a glob pattern. The scope is folded with any leading
/// literal segments, the name query is a (possibly OR'd) `kMDItemFSName` predicate covering the
/// trailing leaf segment, and `postFilterPattern` is the full `^globToRegex(pattern)$` regex body
/// — applied to each candidate's base-relative path to enforce structure the index can't express.
struct SpotlightPlan: Sendable {
    let scope: String
    let nameQuery: String
    /// Regex body (without `^...$` anchors) for the full pattern, used to filter mdfind candidates.
    let postFilterPattern: String
}

// MARK: - Fast file pattern matching tool

/// Fast file pattern matching tool.
///
/// Spotlight-first via `mdfind` (the index handles almost all queries in milliseconds), with a
/// bounded *structural* (pattern-directed) filesystem walk as fallback. The walk is resumable
/// across calls via an opaque token, so slow needle-in-haystack searches over un-indexed trees
/// aren't doomed by the timeout.
///
/// Returns a JSON-as-string result (see `GlobResult`).
final class GlobTool: AgentTool {
    let name = "glob"

    var toolDescription: String {
        "Find files matching a glob pattern (supports *, **, ?, and {a,b}). Returns paths newest-first as a JSON object: `search_root` + `matches` (paths relative to `search_root`) + `source` (\"spotlight_index\" or \"filesystem_walk\") + `stop_reason` + `total_matched` + `more_available` + `resume_token`. Use this instead of `find`/`ls`. " + FilesystemSearch.pruneSummary
    }

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                   BrownBehavior.approvalGateNote(outcome: "the JSON result")
        default:
            return toolDescription
        }
    }

    var parameters: [String: AnyCodable] {
        [
            "type": .string("object"),
            "properties": .dictionary([
                "pattern": .dictionary([
                    "type": .string("string"),
                    "description": .string("Glob pattern (e.g. `**/*.swift`, `src/**/*.{ts,tsx}`, `**/AppDelegate.swift`). Ignored when `resume` is set.")
                ]),
                "path": .dictionary([
                    "type": .string("string"),
                    "description": .string("Absolute or ~-prefixed directory to search in. `~` expands as a path prefix (`~/projects/foo`) but resolving exactly to `~`/`$HOME` or a system root like `/` or `/System` is refused as too broad. Ignored when `resume` is set.")
                ]),
                "limit": .dictionary([
                    "type": .string("integer"),
                    "description": .string("Max paths to return, newest-first. Default 100, max 1000.")
                ]),
                "timeout": .dictionary([
                    "type": .string("integer"),
                    "description": .string("Wall-clock budget in seconds for the whole call. Default 30, max 120. Almost never bites when Spotlight handles the query; mainly bounds the walk fallback.")
                ]),
                "resume": .dictionary([
                    "type": .string("string"),
                    "description": .string("Opaque token from a prior truncated walk result (`resume_token`). When set, continues that walk with a fresh `timeout` budget; `pattern` and `path` are ignored.")
                ])
            ]),
            "required": .array([.string("pattern"), .string("path")])
        ]
    }

    // MARK: - Tuning (init-injectable; production uses defaults)

    private let useSpotlight: Bool
    let maxEntriesScanned: Int
    let defaultTimeoutSeconds: Int
    private let walkStore: WalkStore

    /// Hard caps. `static` because they don't vary per instance.
    static let maxTimeoutSeconds = 120
    static let maxResultsHardCap = 1000
    static let spotlightResultCeiling = 50_000

    /// `executionTimeout` (the agent-level wall-clock cap) is fixed at construction and must cover
    /// the maximum caller `timeout` plus slack for Spotlight + post-processing on top.
    var executionTimeout: Duration { .seconds(Self.maxTimeoutSeconds + 20) }

    init(
        useSpotlight: Bool = true,
        maxEntriesScanned: Int = 200_000,
        walkStoreCapacity: Int = 4,
        defaultTimeoutSeconds: Int = 30
    ) {
        self.useSpotlight = useSpotlight
        self.maxEntriesScanned = maxEntriesScanned
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.walkStore = WalkStore(capacity: walkStoreCapacity)
    }

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    // MARK: - Result shape

    /// JSON-serialised tool output. `nil` optionals are omitted by the synthesised encoder —
    /// "no `resume_token` key" reads identically to "`resume_token: null`" to the LLM.
    private struct GlobResult: Codable {
        let tool: String
        let search_root: String
        let pattern: String?
        let source: String
        let stop_reason: String
        let total_matched: Int?
        let returned: Int
        let more_available: Bool
        let resume_token: String?
        let message: String?
        let matches: [String]
    }

    private func encode(_ result: GlobResult, succeeded: Bool) -> ToolExecutionResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json: String
        do {
            let data = try encoder.encode(result)
            json = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            // JSONEncoder cannot fail for our simple Codable struct in practice — if this fires
            // it's a programming error, not a runtime expectation. Surface a clear error result
            // rather than silently masking it.
            json = #"{"tool":"glob","stop_reason":"bad_request","matches":[],"message":"Internal JSON encoding error: \#(error.localizedDescription)"}"#
        }
        return ToolExecutionResult(output: json, succeeded: succeeded)
    }

    private func badRequest(searchRoot: String, pattern: String?, message: String) -> ToolExecutionResult {
        let r = GlobResult(
            tool: "glob", search_root: searchRoot, pattern: pattern,
            source: "filesystem_walk", stop_reason: "bad_request",
            total_matched: nil, returned: 0, more_available: false,
            resume_token: nil, message: message, matches: []
        )
        return encode(r, succeeded: false)
    }

    private func tooBroad(searchRoot: String, pattern: String?, message: String) -> ToolExecutionResult {
        let r = GlobResult(
            tool: "glob", search_root: searchRoot, pattern: pattern,
            source: "filesystem_walk", stop_reason: "too_broad",
            total_matched: nil, returned: 0, more_available: false,
            resume_token: nil, message: message, matches: []
        )
        return encode(r, succeeded: false)
    }

    // MARK: - execute

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        if case .string(let token) = arguments["resume"], !token.isEmpty {
            let limit = clampLimit(arguments["limit"])
            let timeoutSec = clampTimeout(arguments["timeout"])
            return resumeWalk(token: token, limit: limit, timeoutSeconds: timeoutSec)
        }

        guard case .string(let pattern) = arguments["pattern"] else {
            throw ToolCallError.missingRequiredArgument("pattern")
        }
        guard case .string(let rawPath) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }
        let limit = clampLimit(arguments["limit"])
        let timeoutSec = clampTimeout(arguments["timeout"])

        if pattern.contains("..") {
            return badRequest(searchRoot: rawPath, pattern: pattern,
                              message: "Pattern must not contain '..' (path traversal).")
        }

        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return badRequest(searchRoot: rawPath, pattern: pattern,
                              message: "`path` must be absolute (start with / or ~/). Got: \(rawPath)")
        }
        let resolvedBase = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path

        if FilesystemSearch.isOverlyBroadRoot(resolvedBase) {
            return tooBroad(
                searchRoot: resolvedBase, pattern: pattern,
                message: "Refusing to search '\(expanded)' — that root is far too broad (mostly system files). Pass a specific project or subdirectory. For a machine-wide filename lookup use `bash` with `mdfind -name <name>`."
            )
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedBase, isDirectory: &isDir), isDir.boolValue else {
            return badRequest(searchRoot: resolvedBase, pattern: pattern,
                              message: "Directory does not exist: \(expanded)")
        }

        let segments: [PatternSegment]
        do {
            segments = try Self.parseSegments(pattern)
        } catch {
            return badRequest(searchRoot: resolvedBase, pattern: pattern,
                              message: "Invalid glob pattern '\(pattern)': \(error.localizedDescription)")
        }
        if segments.isEmpty {
            return badRequest(searchRoot: resolvedBase, pattern: pattern,
                              message: "Pattern '\(pattern)' is empty.")
        }

        let fullRegex: NSRegularExpression
        do {
            let body = Self.globToRegex(pattern)
            fullRegex = try NSRegularExpression(pattern: "^\(body)$")
        } catch {
            return badRequest(searchRoot: resolvedBase, pattern: pattern,
                              message: "Invalid glob pattern '\(pattern)': \(error.localizedDescription)")
        }

        // --- Spotlight first ---
        if useSpotlight {
            let plan = Self.spotlightPlan(forSegments: segments, resolvedBase: resolvedBase, fullRegexBody: Self.globToRegex(pattern))
            let outcome = await SpotlightSearch.run(scope: plan.scope, nameQuery: plan.nameQuery, timeoutSeconds: min(timeoutSec, 10))
            if case .ok(let raw) = outcome {
                if raw.count > Self.spotlightResultCeiling {
                    return tooBroad(
                        searchRoot: resolvedBase, pattern: pattern,
                        message: "Spotlight matched \(raw.count)+ files under '\(resolvedBase)' — far too broad to enumerate. Narrow `path` to a specific project/subdirectory, or narrow `pattern`."
                    )
                }
                var survivors: [(rel: String, mtime: Date)] = []
                survivors.reserveCapacity(min(raw.count, 1024))
                var staleCount = 0
                for candidate in raw {
                    guard let entry = Self.validatedSpotlightCandidate(
                        path: candidate, resolvedBase: resolvedBase, postFilter: fullRegex
                    ) else {
                        staleCount += 1
                        continue
                    }
                    survivors.append(entry)
                }
                if !survivors.isEmpty {
                    survivors.sort { $0.mtime > $1.mtime }
                    let total = survivors.count
                    let pageEnd = min(limit, total)
                    let page = Array(survivors[0..<pageEnd])
                    let stale = staleCount
                    let staleNote: String? = (stale > 0 && stale * 4 > raw.count)
                        ? "Note: \(stale) of \(raw.count) Spotlight hits were stale (file moved/deleted since indexing). The index may be out of date for this area."
                        : nil
                    let result = GlobResult(
                        tool: "glob",
                        search_root: resolvedBase,
                        pattern: pattern,
                        source: "spotlight_index",
                        stop_reason: total > limit ? "result_limit" : "complete",
                        total_matched: total,
                        returned: page.count,
                        more_available: total > limit,
                        resume_token: nil,
                        message: staleNote,
                        matches: page.map(\.rel)
                    )
                    return encode(result, succeeded: true)
                }
                // Zero survivors after stat-validation — index either had nothing or every hit was
                // stale. Fall through to the walk so "genuinely none" vs "not indexed here" can be
                // disambiguated.
            }
        }

        // --- Filesystem walk fallback (fresh) ---
        return executeWalk(
            pattern: pattern, segments: segments, fullRegex: fullRegex,
            resolvedBase: resolvedBase, limit: limit, timeoutSeconds: timeoutSec
        )
    }

    // MARK: - Arg clamping

    private func clampLimit(_ raw: AnyCodable?) -> Int {
        let requested: Int
        switch raw {
        case .int(let v): requested = v
        case .double(let v): requested = Int(v)
        default: requested = 100
        }
        return max(1, min(requested, Self.maxResultsHardCap))
    }

    private func clampTimeout(_ raw: AnyCodable?) -> Int {
        let requested: Int
        switch raw {
        case .int(let v): requested = v
        case .double(let v): requested = Int(v)
        default: requested = defaultTimeoutSeconds
        }
        return max(1, min(requested, Self.maxTimeoutSeconds))
    }

    // MARK: - Spotlight plan + validation

    /// Builds a Spotlight query plan from parsed pattern segments. `scope` folds leading literals
    /// onto the search base; `nameQuery` is a `kMDItemFSName` predicate (with brace alternation
    /// expanded into `||`) derived from the trailing segment; `postFilterPattern` is the full
    /// glob→regex (without anchors) for in-process filtering after Spotlight returns candidates.
    static func spotlightPlan(forSegments segments: [PatternSegment], resolvedBase: String, fullRegexBody: String) -> SpotlightPlan {
        var scope = resolvedBase
        var idx = 0
        // Fold leading literal segments into the scope — but stop short of the trailing segment.
        // The trailing segment names the *file* and drives `nameQuery`; folding it would make
        // `scope` point at the file rather than its parent directory.
        while idx < segments.count - 1 {
            if case .literal(let lit) = segments[idx] {
                scope += "/" + lit
                idx += 1
            } else {
                break
            }
        }
        let nameQuery: String
        if let leaf = segments.last {
            switch leaf {
            case .literal(let lit):
                nameQuery = #"kMDItemFSName == "\#(strippingQuotes(lit))""#
            case .wildcard(let cg):
                let alts = Self.expandBraces(cg.raw)
                    .map(Self.collapseWildcardRuns)
                    .map(Self.strippingQuotes)
                if alts.count == 1 {
                    nameQuery = #"kMDItemFSName == "\#(alts[0])""#
                } else {
                    nameQuery = alts.map { #"kMDItemFSName == "\#($0)""# }
                        .joined(separator: " || ")
                }
            case .doubleStar:
                nameQuery = #"kMDItemFSName == "*""#
            }
        } else {
            nameQuery = #"kMDItemFSName == "*""#
        }
        return SpotlightPlan(scope: scope, nameQuery: nameQuery, postFilterPattern: fullRegexBody)
    }

    /// Stat-validates one Spotlight candidate. Returns `nil` when the candidate is stale (gone or
    /// no longer a regular file), escapes `resolvedBase` after symlink resolution, lives under a
    /// hidden (dot-prefixed) path component below the base — the structural walk skips those, so
    /// the Spotlight path must too, or the same query gives different answers depending on whether
    /// Spotlight happened to be available — or fails the post-filter regex against its base-relative
    /// path.
    static func validatedSpotlightCandidate(path: String, resolvedBase: String, postFilter: NSRegularExpression) -> (rel: String, mtime: Date)? {
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(resolvedBase + "/") || resolved == resolvedBase else { return nil }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        } catch {
            return nil  // stale: file no longer exists at this path
        }
        guard values.isRegularFile == true else { return nil }
        let rel: String
        if resolved.hasPrefix(resolvedBase + "/") {
            rel = String(resolved.dropFirst(resolvedBase.count + 1))
        } else {
            return nil
        }
        if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return nil }
        let range = NSRange(rel.startIndex..<rel.endIndex, in: rel)
        guard postFilter.firstMatch(in: rel, range: range) != nil else { return nil }
        return (rel, values.contentModificationDate ?? Date.distantPast)
    }

    /// Expands `{a,b}` alternations into a flat list of brace-free glob strings. `*.{ts,tsx}` →
    /// `["*.ts","*.tsx"]`. Non-brace globs return `[self]`. Malformed → falls back to `[glob]`.
    static func expandBraces(_ glob: String) -> [String] {
        guard glob.contains("{") else { return [glob] }
        guard let openIdx = glob.firstIndex(of: "{"),
              let closeIdx = findMatchingBrace(in: glob, from: openIdx) else {
            return [glob]
        }
        let prefix = String(glob[glob.startIndex..<openIdx])
        let inner = glob[glob.index(after: openIdx)..<closeIdx]
        let suffix = String(glob[glob.index(after: closeIdx)..<glob.endIndex])
        let alts = splitBraceAlternatives(inner).map(String.init)
        // Recurse: each alternative may itself contain braces; suffix may too.
        var out: [String] = []
        for alt in alts {
            for expandedAlt in expandBraces(alt) {
                for expandedSuffix in expandBraces(suffix) {
                    out.append(prefix + expandedAlt + expandedSuffix)
                }
            }
        }
        return out
    }

    /// Collapses runs of `*`/`?` into a single `*` for use as an `mdfind` `kMDItemFSName` wildcard.
    /// Spotlight's `==` predicate supports `*` (zero-or-more) but not `?` (one), and runs like `**`
    /// inside a segment are redundant. The result is a *superset* of the original glob's matches;
    /// the post-filter regex (with the precise `?`/character-class semantics) does the final pruning.
    static func collapseWildcardRuns(_ glob: String) -> String {
        var out = ""
        var prevWasWildcard = false
        for c in glob {
            if c == "*" || c == "?" {
                if !prevWasWildcard { out.append("*") }
                prevWasWildcard = true
            } else {
                out.append(c)
                prevWasWildcard = false
            }
        }
        return out
    }

    /// Strips embedded double quotes from a value being inlined into an `mdfind` query string —
    /// they can't be safely represented in the `kMDItemFSName == "..."` predicate we build, and a
    /// stripped name is a *superset* of the real one (the post-filter regex re-narrows). Defense in
    /// depth — glob segments containing `"` are extremely rare.
    static func strippingQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "")
    }

    // MARK: - Structural walk (fresh + resume)

    /// Frozen state of a paused walk, keyed by `resume_token`. The queue holds the work-frontier
    /// — pairs of (resolved-dir-path, segment-index) — so a resumed call picks up at exactly the
    /// next dir without re-traversing what's already been processed.
    final class WalkState: @unchecked Sendable {
        let pattern: String
        let segments: [PatternSegment]
        let resolvedBase: String
        let homePruneSet: Set<String>
        let fullRegex: NSRegularExpression
        // Queue entries: (dirPath, segmentIdx). segmentIdx == segments.count means "match all
        // regular files at-or-below dirPath" (trailing-`**` / `**`-was-last semantics).
        var queue: [(dirPath: String, segmentIdx: Int)] = []
        // `(resolvedDirPath \0 segmentIdx)` strings already pushed for recursion — guards `**`
        // cycles and avoids re-processing the same (dir, idx) state.
        var visited: Set<String> = []
        // Matches collected past the page's `limit` during one queue-pop's listing (a wildcard
        // step can produce many matches at once). Drained into the next page on resume.
        var overflow: [(rel: String, mtime: Date)] = []
        var entriesScanned: Int = 0

        init(pattern: String, segments: [PatternSegment], resolvedBase: String, homePruneSet: Set<String>, fullRegex: NSRegularExpression) {
            self.pattern = pattern
            self.segments = segments
            self.resolvedBase = resolvedBase
            self.homePruneSet = homePruneSet
            self.fullRegex = fullRegex
        }
    }

    /// LRU-capped store of paused walks, keyed by opaque UUID tokens. Sized small (~4) — paging
    /// happens within a single task usually within a few turns. Eviction drops the state; a
    /// subsequent resume of the evicted token gets `bad_request`.
    final class WalkStore: @unchecked Sendable {
        private let lock = NSLock()
        private var order: [UUID] = []  // front = least recently used
        private var states: [UUID: WalkState] = [:]
        private let capacity: Int

        init(capacity: Int) { self.capacity = max(1, capacity) }

        func insert(_ state: WalkState) -> UUID {
            lock.lock(); defer { lock.unlock() }
            let id = UUID()
            states[id] = state
            order.append(id)
            while order.count > capacity {
                let evict = order.removeFirst()
                states.removeValue(forKey: evict)
            }
            return id
        }

        func take(_ id: UUID) -> WalkState? {
            lock.lock(); defer { lock.unlock() }
            guard let state = states.removeValue(forKey: id) else { return nil }
            order.removeAll { $0 == id }
            return state
        }

        func reinsert(_ id: UUID, state: WalkState) {
            lock.lock(); defer { lock.unlock() }
            states[id] = state
            order.append(id)
            while order.count > capacity {
                let evict = order.removeFirst()
                states.removeValue(forKey: evict)
            }
        }
    }

    private func executeWalk(pattern: String, segments: [PatternSegment], fullRegex: NSRegularExpression, resolvedBase: String, limit: Int, timeoutSeconds: Int) -> ToolExecutionResult {
        let homePruneSet = FilesystemSearch.homePruneAbsolutePaths(forBase: resolvedBase)
        let state = WalkState(pattern: pattern, segments: segments, resolvedBase: resolvedBase, homePruneSet: homePruneSet, fullRegex: fullRegex)
        state.queue.append((dirPath: resolvedBase, segmentIdx: 0))
        return driveWalk(state: state, limit: limit, timeoutSeconds: timeoutSeconds, existingToken: nil)
    }

    private func resumeWalk(token: String, limit: Int, timeoutSeconds: Int) -> ToolExecutionResult {
        guard let uuid = UUID(uuidString: token), let state = walkStore.take(uuid) else {
            return badRequest(searchRoot: "<unknown>", pattern: nil,
                              message: "Resume token '\(token)' is unknown or has expired. Start a new search with `pattern` + `path`.")
        }
        return driveWalk(state: state, limit: limit, timeoutSeconds: timeoutSeconds, existingToken: uuid)
    }

    /// Core walk loop. Drains `state.overflow` first, then processes `state.queue` until first of
    /// `limit` matches collected, deadline, scan cap, or queue empty. Returns a JSON result and
    /// (when more work remains) re-stashes the `WalkState` under the same or new token.
    private func driveWalk(state: WalkState, limit: Int, timeoutSeconds: Int, existingToken: UUID?) -> ToolExecutionResult {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var matches: [(rel: String, mtime: Date)] = []

        // Drain overflow first (carried over from a prior call).
        while !state.overflow.isEmpty && matches.count < limit {
            matches.append(state.overflow.removeFirst())
        }

        enum StopReason { case complete, resultLimit, timeLimit, scanLimit }
        var stop: StopReason = .complete

        outer: while !state.queue.isEmpty {
            if matches.count >= limit {
                stop = .resultLimit
                break
            }
            state.entriesScanned += 1
            if state.entriesScanned > maxEntriesScanned {
                stop = .scanLimit
                break
            }
            // Treat agent-level cancellation (the `executionTimeout` wrapper, or agent
            // termination) the same as the caller timeout: stop now, leave a resume token.
            if Date() >= deadline || Task.isCancelled {
                stop = .timeLimit
                break
            }

            let (dirPath, idx) = state.queue.removeFirst()

            // A symlinked subdir can resolve to a path outside `resolvedBase` (`proj/x -> /etc`).
            // Matches outside the base are already filtered by `baseRelativePath`, but without
            // this we'd still *descend* the foreign tree and burn the whole budget there.
            guard dirPath == state.resolvedBase || dirPath.hasPrefix(state.resolvedBase + "/") else {
                continue outer
            }

            let segments = state.segments

            // Single dedup gate for the whole walk: each (resolved-dir, segment-idx) is
            // processed at most once. Without this, two sibling directories that are symlinks
            // to the *same* real dir would both push and both process the same `(real, idx)`
            // → duplicate matches. Catches `**` self-cycles too.
            let dedupKey = dirPath + "\u{0}" + String(idx)
            guard state.visited.insert(dedupKey).inserted else { continue outer }

            if idx >= segments.count {
                // "Match every regular file at-or-below dirPath" — trailing `**` semantics.
                processMatchAllStep(dirPath: dirPath, state: state, matches: &matches, limit: limit, idx: idx)
                continue outer
            }

            switch segments[idx] {
            case .doubleStar:
                processDoubleStarStep(dirPath: dirPath, idx: idx, state: state)
            case .literal(let lit):
                processLiteralStep(dirPath: dirPath, lit: lit, idx: idx, state: state, matches: &matches, limit: limit)
            case .wildcard(let cg):
                processWildcardStep(dirPath: dirPath, cg: cg, idx: idx, state: state, matches: &matches, limit: limit)
            }
        }

        // Sort the page by mtime desc (within the page; not globally — see source/stop_reason).
        matches.sort { $0.mtime > $1.mtime }

        let isExhausted = (stop == .complete && state.overflow.isEmpty)
        let moreAvailable = !isExhausted
        var resumeToken: String?
        if !isExhausted {
            if let existingToken {
                walkStore.reinsert(existingToken, state: state)
                resumeToken = existingToken.uuidString
            } else {
                resumeToken = walkStore.insert(state).uuidString
            }
        }

        let stopReasonString: String = switch stop {
        case .complete: "complete"
        case .resultLimit: "result_limit"
        case .timeLimit: "time_limit"
        case .scanLimit: "scan_limit"
        }

        // The walk having drained (`stop == .complete`) means we know the total exactly — even if
        // some matches are sitting in `overflow` waiting for the next page. Early-stop cases
        // (`result_limit` / `time_limit` / `scan_limit`) leave the total unknown.
        let totalMatched: Int? = (stop == .complete) ? (matches.count + state.overflow.count) : nil

        let result = GlobResult(
            tool: "glob",
            search_root: state.resolvedBase,
            pattern: state.pattern,
            source: "filesystem_walk",
            stop_reason: stopReasonString,
            total_matched: totalMatched,
            returned: matches.count,
            more_available: moreAvailable,
            resume_token: resumeToken,
            message: nil,
            matches: matches.map(\.rel)
        )
        return encode(result, succeeded: true)
    }

    // MARK: - Walk step handlers

    private func processMatchAllStep(dirPath: String, state: WalkState, matches: inout [(rel: String, mtime: Date)], limit: Int, idx: Int) {
        // Dedup happens in the main loop's central gate — no per-handler check needed.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey])
            } catch { continue }
            if values.isRegularFile == true {
                if let rel = baseRelativePath(of: entry, base: state.resolvedBase) {
                    let entryTuple = (rel: rel, mtime: values.contentModificationDate ?? Date.distantPast)
                    if matches.count < limit {
                        matches.append(entryTuple)
                    } else {
                        state.overflow.append(entryTuple)
                    }
                }
            } else if values.isDirectory == true {
                let name = entry.lastPathComponent
                let absPath = entry.path
                if FilesystemSearch.shouldPruneDirectory(absolutePath: absPath, name: name, homePruneSet: state.homePruneSet) {
                    continue
                }
                let resolvedSub = entry.resolvingSymlinksInPath().path
                state.queue.append((dirPath: resolvedSub, segmentIdx: idx))
            }
        }
    }

    private func processDoubleStarStep(dirPath: String, idx: Int, state: WalkState) {
        // Dedup happens in the main loop's central gate.
        // Consume the `**` (zero components) — continue with idx+1 in the same dir.
        state.queue.append((dirPath: dirPath, segmentIdx: idx + 1))
        // Expand `**` by one level — for each non-pruned subdir, stay on idx (still consuming).
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            } catch { continue }
            guard values.isDirectory == true else { continue }
            let name = entry.lastPathComponent
            let absPath = entry.path
            if FilesystemSearch.shouldPruneDirectory(absolutePath: absPath, name: name, homePruneSet: state.homePruneSet) {
                continue
            }
            let resolvedSub = entry.resolvingSymlinksInPath().path
            state.queue.append((dirPath: resolvedSub, segmentIdx: idx))
        }
    }

    private func processLiteralStep(dirPath: String, lit: String, idx: Int, state: WalkState, matches: inout [(rel: String, mtime: Date)], limit: Int) {
        // One `stat`, no listing — the cheapest case.
        let childPath = dirPath + "/" + lit
        let url = URL(fileURLWithPath: childPath)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey])
        } catch { return }
        if idx + 1 == state.segments.count {
            // Last segment is a literal → exact filename match. Must be a regular file.
            guard values.isRegularFile == true else { return }
            // Literal-only paths can't have a `..` and we resolved earlier; symlink-escape check
            // still applies (defense in depth).
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(state.resolvedBase + "/") || resolved == state.resolvedBase else { return }
            if let rel = baseRelativePath(of: url, base: state.resolvedBase) {
                let entry = (rel: rel, mtime: values.contentModificationDate ?? Date.distantPast)
                if matches.count < limit {
                    matches.append(entry)
                } else {
                    state.overflow.append(entry)
                }
            }
        } else {
            // Non-last literal → must be a directory; descend. Literal segments are NEVER pruned
            // (if the user explicitly named the dir, they want it).
            guard values.isDirectory == true else { return }
            let resolvedSub = url.resolvingSymlinksInPath().path
            state.queue.append((dirPath: resolvedSub, segmentIdx: idx + 1))
        }
    }

    private func processWildcardStep(dirPath: String, cg: CompiledGlob, idx: Int, state: WalkState, matches: inout [(rel: String, mtime: Date)], limit: Int) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let isLast = (idx + 1 == state.segments.count)
        for entry in entries {
            let name = entry.lastPathComponent
            guard cg.matches(name) else { continue }
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey])
            } catch { continue }
            if isLast {
                guard values.isRegularFile == true else { continue }
                if let rel = baseRelativePath(of: entry, base: state.resolvedBase) {
                    let tuple = (rel: rel, mtime: values.contentModificationDate ?? Date.distantPast)
                    if matches.count < limit {
                        matches.append(tuple)
                    } else {
                        state.overflow.append(tuple)
                    }
                }
            } else {
                guard values.isDirectory == true else { continue }
                let absPath = entry.path
                if FilesystemSearch.shouldPruneDirectory(absolutePath: absPath, name: name, homePruneSet: state.homePruneSet) {
                    continue
                }
                let resolvedSub = entry.resolvingSymlinksInPath().path
                state.queue.append((dirPath: resolvedSub, segmentIdx: idx + 1))
            }
        }
    }

    private func baseRelativePath(of url: URL, base: String) -> String? {
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base + "/") else { return nil }
        return String(resolved.dropFirst(base.count + 1))
    }

    // MARK: - Pattern parsing

    /// Parses a glob into segments. Splits on `/`, drops empty components (collapses `a//b` and
    /// `/foo` to `a/b` / `foo`). Each component is classified `doubleStar` / `literal` / `wildcard`.
    static func parseSegments(_ pattern: String) throws -> [PatternSegment] {
        let raw = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var out: [PatternSegment] = []
        out.reserveCapacity(raw.count)
        for component in raw {
            if component == "**" {
                out.append(.doubleStar)
            } else if Self.hasGlobMetachars(component) {
                let cg = try CompiledGlob(component)
                out.append(.wildcard(cg))
            } else {
                out.append(.literal(component))
            }
        }
        return out
    }

    private static func hasGlobMetachars(_ s: String) -> Bool {
        s.contains(where: { $0 == "*" || $0 == "?" || $0 == "{" || $0 == "}" })
    }

    // MARK: - Glob to Regex (kept on GlobTool; reused by CompiledGlob + Spotlight post-filter + tests)

    /// Converts a glob pattern to a regex pattern string (without `^...$` anchors).
    ///
    /// Supports:
    /// - `**` — matches any number of path segments (including zero)
    /// - `*` — matches any characters except `/`
    /// - `?` — matches a single character except `/`
    /// - `{a,b}` — alternation (brace expansion)
    /// - All other regex-special characters are escaped
    static func globToRegex(_ glob: String) -> String {
        var result = ""
        var i = glob.startIndex

        while i < glob.endIndex {
            let c = glob[i]

            if c == "*" {
                let next = glob.index(after: i)
                if next < glob.endIndex && glob[next] == "*" {
                    let afterStars = glob.index(after: next)
                    if afterStars < glob.endIndex && glob[afterStars] == "/" {
                        result += "(.*/)?"
                        i = glob.index(after: afterStars)
                    } else {
                        result += ".*"
                        i = afterStars
                    }
                } else {
                    result += "[^/]*"
                    i = next
                }
            } else if c == "?" {
                result += "[^/]"
                i = glob.index(after: i)
            } else if c == "{" {
                if let closeIdx = Self.findMatchingBrace(in: glob, from: i) {
                    let inner = glob[glob.index(after: i)..<closeIdx]
                    let alternatives = Self.splitBraceAlternatives(inner).map { Self.globToRegex(String($0)) }
                    result += "(\(alternatives.joined(separator: "|")))"
                    i = glob.index(after: closeIdx)
                } else {
                    result += "\\{"
                    i = glob.index(after: i)
                }
            } else if c == "}" {
                result += "\\}"
                i = glob.index(after: i)
            } else {
                let special: Set<Character> = [".", "+", "^", "$", "|", "(", ")", "[", "]", "\\"]
                if special.contains(c) {
                    result += "\\\(c)"
                } else {
                    result.append(c)
                }
                i = glob.index(after: i)
            }
        }

        return result
    }

    /// Finds the matching `}` for a `{` at `openIdx`, respecting nested braces.
    static func findMatchingBrace(in str: String, from openIdx: String.Index) -> String.Index? {
        var depth = 0
        var idx = openIdx
        while idx < str.endIndex {
            if str[idx] == "{" {
                depth += 1
            } else if str[idx] == "}" {
                depth -= 1
                if depth == 0 {
                    return idx
                }
            }
            idx = str.index(after: idx)
        }
        return nil
    }

    /// Splits brace content by commas at the top level only.
    static func splitBraceAlternatives(_ content: Substring) -> [Substring] {
        var alternatives: [Substring] = []
        var depth = 0
        var segmentStart = content.startIndex
        for idx in content.indices {
            let c = content[idx]
            if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
            } else if c == "," && depth == 0 {
                alternatives.append(content[segmentStart..<idx])
                segmentStart = content.index(after: idx)
            }
        }
        alternatives.append(content[segmentStart...])
        return alternatives
    }
}
