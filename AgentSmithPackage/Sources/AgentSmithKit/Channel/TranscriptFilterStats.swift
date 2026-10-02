import Foundation

/// Message counts behind the transcript filter's live feedback: how much a pane shows, how much each
/// participant and activity contributes, and how much the scope removes.
///
/// Pure and value-typed so it is computed off the main actor from a snapshot of the transcript.
/// Counts are taken with the SAME `TranscriptFilter` the pane renders through — there is no second
/// implementation of "would this message show" to drift from the real one.
public struct TranscriptFilterStats: Sendable, Equatable {
    /// Messages in the pane's universe (the whole session, or the whole task).
    public private(set) var total = 0
    /// Of those, the ones the scope keeps (differs from `total` only in the session pane with
    /// per-task work hidden).
    public private(set) var inScope = 0
    /// Of those, the ones the full filter shows.
    public private(set) var shown = 0
    /// Of `shown`, the ones visible ONLY because the problem policy re-admitted them — a warning or
    /// error whose participant or activity is hidden. Without this a hidden row that still showed
    /// its warnings looked like a filter that did nothing.
    public private(set) var shownOnlyAsProblems = 0
    /// In-scope messages by author and target. A tool exchange counts under both its kind and its
    /// tool, so a tool row and the "Tool calls" row each report their own messages.
    public private(set) var counts: [ChannelMessage.Sender: [TranscriptFilterTarget: Int]] = [:]
    /// The `shownOnlyAsProblems` messages by author and target, shaped like `counts`.
    public private(set) var problemCounts: [ChannelMessage.Sender: [TranscriptFilterTarget: Int]] = [:]
    /// In-scope messages each participant wrote or was addressed by.
    public private(set) var involving: [ChannelMessage.Sender: Int] = [:]
    /// Every tool name seen in scope — including MCP tools, which no static list can enumerate.
    public private(set) var observedToolNames: Set<String> = []

    public init() {}

    /// Messages the scope removes.
    public var scopeExcluded: Int { total - inScope }

    /// In-scope messages matching any of `targets` from any of `participants`.
    public func count(of targets: [TranscriptFilterTarget], for participants: [ChannelMessage.Sender]) -> Int {
        Self.sum(counts, targets: targets, participants: participants)
    }

    /// Of those, the ones shown only because the problem policy re-admitted them.
    public func problemCount(of targets: [TranscriptFilterTarget], for participants: [ChannelMessage.Sender]) -> Int {
        Self.sum(problemCounts, targets: targets, participants: participants)
    }

    private static func sum(_ table: [ChannelMessage.Sender: [TranscriptFilterTarget: Int]],
                            targets: [TranscriptFilterTarget], participants: [ChannelMessage.Sender]) -> Int {
        participants.reduce(0) { sum, participant in
            guard let byTarget = table[participant] else { return sum }
            return targets.reduce(sum) { $0 + (byTarget[$1] ?? 0) }
        }
    }

    /// - Parameters:
    ///   - universe: the pane's whole population (`.any` for the session, `.task(id)` for a task).
    ///   - scope: what the pane's scope keeps — equal to `universe` except in the session pane
    ///     with per-task work hidden.
    public static func compute(
        messages: [ChannelMessage],
        config: TranscriptViewConfig,
        universe: TranscriptFilter.TaskScope,
        scope: TranscriptFilter.TaskScope
    ) -> TranscriptFilterStats {
        let inUniverse = TranscriptFilter(taskScope: universe, alwaysShowAtOrAbove: nil)
        let inScope = TranscriptFilter(taskScope: scope, alwaysShowAtOrAbove: nil)
        let rendered = config.makeFilter(taskScope: scope)
        // The same filter with the floor removed: a message the pane shows but this one doesn't is
        // shown only because it's a problem.
        var unfloored = rendered
        unfloored.alwaysShowAtOrAbove = nil
        var stats = TranscriptFilterStats()
        for message in messages where inUniverse.matches(message) {
            stats.total += 1
            guard inScope.matches(message) else { continue }
            let isShown = rendered.matches(message)
            stats.record(message, shown: isShown, onlyAsProblem: isShown && !unfloored.matches(message))
        }
        return stats
    }

    private mutating func record(_ message: ChannelMessage, shown isShown: Bool, onlyAsProblem: Bool) {
        inScope += 1
        if isShown { shown += 1 }
        if onlyAsProblem { shownOnlyAsProblems += 1 }
        let author = message.author
        var targets: [TranscriptFilterTarget] = [message.kind.map(TranscriptFilterTarget.kind) ?? .chat]
        if let tool = message.toolName {
            targets.append(.tool(tool))
            observedToolNames.insert(tool)
        }
        for target in targets {
            counts[author, default: [:]][target, default: 0] += 1
            if onlyAsProblem { problemCounts[author, default: [:]][target, default: 0] += 1 }
        }
        involving[author, default: 0] += 1
        if let addressee = message.addressee, addressee != author {
            involving[addressee, default: 0] += 1
        }
    }
}
