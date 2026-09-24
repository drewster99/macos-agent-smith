import Foundation

/// Wording for the inspector's Memory activity rows.
///
/// Lives in the package rather than the app target only so it can be tested — the app target has
/// no test bundle. Every label derives corpus state from the typed `CorpusSearchOutcome`, never
/// from a hit count or an elapsed time: `0 results` must never mean `not searched`.
public enum MemoryActivityPresentation {

    /// Compact chip, e.g. `1m · tasks off`, `memory off · 0t`, `0m · 0t`.
    public static func compactCorpusLabel(_ query: MemoryQueryActivity) -> String {
        let memoryPart = query.memories.hits.map { "\($0.count)m" } ?? "memory off"
        let taskPart = query.taskSummaries.hits.map { "\($0.count)t" } ?? "tasks off"
        return "\(memoryPart) · \(taskPart)"
    }

    /// The compact chip spelled out for help text and VoiceOver.
    public static func corpusAccessibilityText(_ query: MemoryQueryActivity) -> String {
        let memoryPart: String
        switch query.memories.hits?.count {
        case nil: memoryPart = "memories not searched"
        case 0: memoryPart = "no memories matched"
        case 1: memoryPart = "1 memory returned"
        case let count?: memoryPart = "\(count) memories returned"
        }
        let taskPart: String
        switch query.taskSummaries.hits?.count {
        case nil: taskPart = "prior task summaries not searched"
        case 0: taskPart = "no prior task summaries matched"
        case 1: taskPart = "1 prior task summary returned"
        case let count?: taskPart = "\(count) prior task summaries returned"
        }
        return "\(memoryPart); \(taskPart)"
    }

    /// Heading over a query's returned memories.
    public static func memoriesHeading(_ outcome: CorpusSearchOutcome<MemoryHitSnapshot>) -> String {
        switch outcome {
        case .notSearched: return "Memories not searched"
        case .searched(let hits) where hits.isEmpty: return "No memories matched"
        case .searched(let hits): return "Returned memories (\(hits.count))"
        }
    }

    /// Heading over a query's returned prior-task summaries.
    public static func taskSummariesHeading(_ outcome: CorpusSearchOutcome<TaskSummaryHitSnapshot>) -> String {
        switch outcome {
        case .notSearched: return "Prior task summaries not searched"
        case .searched(let hits) where hits.isEmpty: return "No prior task summaries matched"
        case .searched(let hits): return "Returned prior task summaries (\(hits.count))"
        }
    }

    /// Where the time went, naming a skipped scan as skipped rather than printing zero.
    public static func phaseBreakdown(_ query: MemoryQueryActivity) -> String {
        let memoryScan = query.memoryScanMs.map { "\($0)ms" } ?? "skipped"
        let taskScan = query.taskScanMs.map { "\($0)ms" } ?? "skipped"
        return "embed \(query.embedMs)ms · memory scan \(memoryScan) · task scan \(taskScan)"
    }

    /// Human-readable name of what caused an activity.
    public static func originLabel(_ origin: MemoryActivityOrigin) -> String {
        switch origin {
        case .retrieval(.smithUserMessage): return "Smith auto-context"
        case .retrieval(.newTask): return "New-task context"
        case .retrieval(.validatorReview): return "Validator review"
        case .retrieval(.securityScoping): return "Security tool scoping"
        case .retrieval(.securityToolReview): return "Security tool review"
        case .agentSearchMemory(let role): return "Agent search_memory (\(role.displayName))"
        case .memoryBrowser: return "Memory Browser search"
        case .memoryConsolidationCandidateSearch: return "Memory consolidation candidate search"
        case .other(let name): return name
        }
    }

    /// Retention heading for the feed, e.g. `Latest 200 of 327 activities`.
    public static func feedHeading(_ feed: MemoryActivityFeed) -> String {
        let noun = feed.lifetimeCount == 1 ? "activity" : "activities"
        if feed.evictedCount > 0 {
            return "Latest \(feed.activities.count) of \(feed.lifetimeCount) \(noun)"
        }
        return "\(feed.lifetimeCount) \(noun)"
    }
}
