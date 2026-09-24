import Testing
import Foundation
@testable import AgentSmithKit

/// The Memory activity feed and its labels: corpus state comes from the typed outcome, never from a
/// count or a timing, and the feed orders by the store's sequence and discloses what it evicted.
@Suite("Memory activity feed and labels")
struct MemoryActivityTests {

    private func memoryHit(rank: Int, content: String) -> MemoryHitSnapshot {
        MemoryHitSnapshot(rank: rank, result: MemorySearchResult(
            memory: MemoryEntry(content: content, embedding: [1], source: .smith, tags: ["t"]),
            similarity: 0.9, textScore: 0.2, rrfScore: 0.03))
    }

    private func query(
        memories: CorpusSearchOutcome<MemoryHitSnapshot>,
        tasks: CorpusSearchOutcome<TaskSummaryHitSnapshot>,
        memoryScanMs: Int? = 0,
        taskScanMs: Int? = 0
    ) -> MemoryQueryActivity {
        MemoryQueryActivity(query: "q", origin: .memoryBrowser, correlationID: nil, latencyMs: 5, embedMs: 3,
                            memoryScanMs: memoryScanMs, taskScanMs: taskScanMs, memories: memories, taskSummaries: tasks)
    }

    @Test("compact label distinguishes not searched from searched-and-empty")
    func compactLabels() {
        let hit = memoryHit(rank: 1, content: "fact")
        #expect(MemoryActivityPresentation.compactCorpusLabel(query(memories: .searched(hits: [hit]), tasks: .notSearched)) == "1m · tasks off")
        #expect(MemoryActivityPresentation.compactCorpusLabel(query(memories: .notSearched, tasks: .searched(hits: []))) == "memory off · 0t")
        #expect(MemoryActivityPresentation.compactCorpusLabel(query(memories: .searched(hits: []), tasks: .searched(hits: []))) == "0m · 0t")
    }

    @Test("accessibility text spells out both corpora")
    func accessibilityText() {
        let text = MemoryActivityPresentation.corpusAccessibilityText(query(memories: .searched(hits: []), tasks: .notSearched))
        #expect(text == "no memories matched; prior task summaries not searched")
        let hit = memoryHit(rank: 1, content: "fact")
        #expect(MemoryActivityPresentation.corpusAccessibilityText(query(memories: .searched(hits: [hit]), tasks: .searched(hits: [])))
                == "1 memory returned; no prior task summaries matched")
    }

    @Test("a zero-millisecond scan of a searched corpus still reads as searched")
    func zeroMillisecondsIsNotSkipped() {
        let fast = query(memories: .searched(hits: []), tasks: .notSearched, memoryScanMs: 0, taskScanMs: nil)
        #expect(MemoryActivityPresentation.memoriesHeading(fast.memories) == "No memories matched")
        #expect(MemoryActivityPresentation.taskSummariesHeading(fast.taskSummaries) == "Prior task summaries not searched")
        #expect(MemoryActivityPresentation.phaseBreakdown(fast) == "embed 3ms · memory scan 0ms · task scan skipped")
    }

    @Test("hit snapshots keep rank, identity, content, and scores")
    func hitSnapshotsAreComplete() {
        let entry = MemoryEntry(content: "the fact", embedding: [1], source: .brown, tags: ["a", "b"], sourceTaskID: UUID())
        let snapshot = MemoryHitSnapshot(rank: 2, result: MemorySearchResult(memory: entry, similarity: 0.8, textScore: 0.1, rrfScore: 0.02))
        #expect(snapshot.rank == 2)
        #expect(snapshot.memoryID == entry.id)
        #expect(snapshot.content == "the fact")
        #expect(snapshot.tags == ["a", "b"])
        #expect(snapshot.source == .brown)
        #expect(snapshot.sourceTaskID == entry.sourceTaskID)
        #expect(snapshot.cosineSimilarity == 0.8)
        #expect(snapshot.lexicalScore == 0.1)
        #expect(snapshot.reciprocalRankFusionScore == 0.02)
    }

    @Test("retrieval origins get human labels")
    func originLabels() {
        #expect(MemoryActivityPresentation.originLabel(.retrieval(.smithUserMessage)) == "Smith auto-context")
        #expect(MemoryActivityPresentation.originLabel(.retrieval(.securityToolReview)) == "Security tool review")
        #expect(MemoryActivityPresentation.originLabel(.retrieval(.newTask)) == "New-task context")
        #expect(MemoryActivityPresentation.originLabel(.memoryConsolidationCandidateSearch) == "Memory consolidation candidate search")
    }

    @Test("the feed orders by sequence regardless of arrival order and discloses eviction")
    func feedOrdersAndBounds() {
        var feed = MemoryActivityFeed(capacity: 3)
        let q = query(memories: .notSearched, tasks: .notSearched)
        for sequence in [2, 1, 4, 3, 5] {
            feed.insert(MemoryActivity(sequence: sequence, timestamp: Date(), kind: .query(q)))
        }
        #expect(feed.activities.map(\.sequence) == [3, 4, 5])
        #expect(feed.lifetimeCount == 5)
        #expect(feed.evictedCount == 2)
        #expect(MemoryActivityPresentation.feedHeading(feed) == "Latest 3 of 5 activities")
    }

    private func mutation(_ operation: MemoryMutationActivity.Operation,
                          consolidation: MemoryConsolidationContext? = nil) -> MemoryMutationActivity {
        MemoryMutationActivity(operation: operation, subject: .memory(id: UUID()), origin: .memoryBrowser, taskID: nil,
                               before: nil, proposed: nil, after: MemoryContentSnapshot(text: "t", tags: []),
                               retainedExistingID: false, consolidation: consolidation)
    }

    @Test("mutation badges")
    func mutationBadges() {
        let expected: [(MemoryMutationActivity.Operation, String)] = [
            (.create, "CREATE"), (.edit, "EDIT"), (.merge, "MERGE"), (.delete, "DELETE"),
            (.taskSummaryWrite, "TASK SUMMARY"), (.taskSummaryDelete, "TASK SUMMARY"),
        ]
        for (operation, badge) in expected {
            #expect(MemoryActivityPresentation.mutationBadge(mutation(operation)) == badge)
        }
    }

    @Test("a failed or garbled reconciler is never described as a DIFFERENT decision")
    func consolidationDecisionWording() {
        func decision(_ reason: MemoryConsolidationSeparateReason) -> String {
            MemoryActivityPresentation.consolidationDecision(MemoryConsolidationContext(
                correlationID: UUID(), candidateMemoryID: UUID(), candidateSimilarity: 0.8, outcome: .keptSeparate(reason)))
        }
        #expect(decision(.reconcilerJudgedDifferent).contains("DIFFERENT"))
        let nonDecisions: [MemoryConsolidationSeparateReason] = [
            .reconcilerUnavailable(errorDescription: "503"), .reconcilerResponseMalformed(response: "?"),
            .reconcilerMergeWasEmpty, .reconcilerCancelled,
        ]
        for reason in nonDecisions {
            #expect(decision(reason).contains("answered DIFFERENT") == false)
            #expect(decision(reason).contains("no decision"))
        }
    }

    @Test("mutation origins get human labels")
    func mutationOriginLabels() {
        #expect(MemoryActivityPresentation.originLabel(.agentSaveMemory(.brown)) == "\(AgentRole.brown.displayName) save_memory")
        #expect(MemoryActivityPresentation.originLabel(.taskSummarization) == "Task summarization")
        #expect(MemoryActivityPresentation.originLabel(.memoryBrowser) == "Memory Browser")
        #expect(MemoryActivityPresentation.queryOriginLabel(.memoryBrowser) == "Memory Browser search")
    }
}
