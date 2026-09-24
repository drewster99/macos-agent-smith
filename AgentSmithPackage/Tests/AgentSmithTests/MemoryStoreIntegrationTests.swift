import Testing
import Foundation
@testable import AgentSmithKit

/// End-to-end tests for `MemoryStore` running against a real `SemanticSearchEngine`.
///
/// The prepared engine and the saved memories are shared across every test in the
/// suite via a single `Task` so we download / load the MLX model at most once.
///
/// Requires Xcode's build pipeline to compile MLX's Metal shaders. Plain `swift test`
/// cannot compile MLX's `.metal` shaders, so this suite is gated behind an explicit
/// environment variable and skipped (with a recorded note) when not set:
///
///   cd AgentSmithPackage && TEST_RUNNER_AGENT_SMITH_RUN_MLX_TESTS=1 xcodebuild test \
///       -scheme AgentSmithPackage \
///       -destination 'platform=macOS' \
///       -only-testing:AgentSmithTests/MemoryStoreIntegrationTests
///
/// `xcodebuild` forwards only `TEST_RUNNER_`-prefixed variables to the test process (with the
/// prefix stripped); a bare `AGENT_SMITH_RUN_MLX_TESTS=1` never reaches it.
///
/// Without the flag, every test in this suite returns immediately. This means the
/// project's primary test command — `swift test --skip MemoryStoreIntegrationTests`
/// (per CLAUDE.md) — is now belt-and-suspenders: even without `--skip`, the tests
/// won't actually exercise the MLX runtime.
@Suite("MemoryStore Integration", .serialized)
struct MemoryStoreIntegrationTests {
    /// True when the gating env var is set to a non-empty, non-zero value. Snapshot at
    /// suite construction so each `@Test` can short-circuit cheaply.
    private static let isEnabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["AGENT_SMITH_RUN_MLX_TESTS"] else {
            return false
        }
        let v = raw.trimmingCharacters(in: .whitespaces)
        return !v.isEmpty && v != "0" && v.lowercased() != "false"
    }()

    private static let shared: Task<Fixture, Error> = Task {
        let engine = SemanticSearchEngine()
        for try await _ in engine.prepare() { /* drain progress */ }
        let store = MemoryStore(engine: engine)
        var ids: [String: UUID] = [:]
        for seed in Self.seeds {
            let entry = try await store.save(
                content: seed.content,
                source: .smith,
                tags: seed.tags,
                origin: .other("integration test fixture")
            )
            ids[seed.id] = entry.id
        }
        return Fixture(engine: engine, store: store, ids: ids)
    }

    /// Returns the shared fixture if the suite is enabled; otherwise returns nil so
    /// the calling `@Test` can skip itself with a recorded note. Putting this in one
    /// place keeps every test's gating identical.
    private static func fixtureIfEnabled() async throws -> Fixture? {
        guard isEnabled else {
            Issue.record("MemoryStoreIntegrationTests skipped — set AGENT_SMITH_RUN_MLX_TESTS=1 and run via xcodebuild to exercise this suite.")
            return nil
        }
        return try await shared.value
    }

    private struct Fixture: Sendable {
        let engine: SemanticSearchEngine
        let store: MemoryStore
        /// Maps stable seed IDs (like `"swift-async"`) to the UUID the store assigned.
        let ids: [String: UUID]
    }

    private struct Seed: Sendable {
        let id: String
        let content: String
        let tags: [String]
    }

    /// Small corpus of agent-flavored memories. Distinct topics + distinct vocabulary
    /// so the searcher has to actually do semantic work, not just trip over a shared
    /// keyword.
    private static let seeds: [Seed] = [
        Seed(id: "swift-async",
             content: "Swift actors serialize access to their mutable state so concurrent code cannot introduce low-level data races.",
             tags: ["language:swift", "topic:concurrency"]),
        Seed(id: "python-venv",
             content: "A Python virtual environment isolates a single project's installed packages from every other project on the same machine.",
             tags: ["language:python", "topic:tooling"]),
        Seed(id: "git-rebase",
             content: "Interactive rebase in Git lets a developer squash, reorder, edit, or drop commits to clean up history before merging a feature branch.",
             tags: ["tool:git", "topic:workflow"]),
        Seed(id: "sql-index",
             content: "A well-placed database index turns a full table scan into a logarithmic lookup on the indexed columns.",
             tags: ["topic:databases", "topic:performance"]),
        Seed(id: "cook-risotto",
             content: "Good risotto is stirred constantly and takes warm stock one ladle at a time until the arborio grains turn creamy and al dente.",
             tags: ["topic:cooking"]),
        Seed(id: "astro-aurora",
             content: "The aurora borealis appears when charged particles from the solar wind collide with oxygen and nitrogen high in Earth's upper atmosphere.",
             tags: ["topic:astronomy"]),
        Seed(id: "fit-vo2",
             content: "VO2 max improves fastest with four- to six-minute intervals performed at near-maximal effort, separated by easy recovery jogs.",
             tags: ["topic:fitness"]),
        Seed(id: "garden-mulch",
             content: "A two-inch layer of mulch spread over garden beds conserves soil moisture and suppresses weed germination.",
             tags: ["topic:gardening"])
    ]

    private struct QueryCase: Sendable {
        let query: String
        let expectedSeedID: String
    }

    /// Paraphrased queries with no meaningful keyword overlap with the target memory,
    /// so a successful top-1 hit proves the semantic half of RRF is pulling its weight.
    private static let queryCases: [QueryCase] = [
        QueryCase(query: "how do I prevent race conditions across multiple threads in Swift",                expectedSeedID: "swift-async"),
        QueryCase(query: "isolating a project's package versions from other projects on the same computer", expectedSeedID: "python-venv"),
        QueryCase(query: "cleaning up messy commit history before opening a pull request",                  expectedSeedID: "git-rebase"),
        QueryCase(query: "speeding up slow queries that read a whole table",                                expectedSeedID: "sql-index"),
        QueryCase(query: "a creamy Italian rice dish that needs constant stirring",                         expectedSeedID: "cook-risotto"),
        QueryCase(query: "what causes the northern lights",                                                 expectedSeedID: "astro-aurora"),
        QueryCase(query: "interval workout for raising maximum aerobic capacity",                           expectedSeedID: "fit-vo2"),
        QueryCase(query: "keeping weeds from taking over my vegetable beds",                                expectedSeedID: "garden-mulch")
    ]

    // MARK: - Tests

    @Test("save persists the memory and assigns an embedding of the model's dimension")
    func savePersistsWithEmbedding() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let memories = await fixture.store.allMemories()
        #expect(memories.count == Self.seeds.count)

        let expectedDim = fixture.engine.model.dimension
        for memory in memories {
            #expect(memory.embedding.count == expectedDim)
        }
    }

    @Test("searchMemories returns the expected memory as top-1 for each paraphrased query")
    func searchTop1ForEachQuery() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let idBySeed = fixture.ids

        var misses: [(query: String, expected: String, got: String?, rrf: Double)] = []
        for test in Self.queryCases {
            let expectedUUID = try #require(idBySeed[test.expectedSeedID])
            let results = try await fixture.store.searchMemories(query: test.query, limit: 5, origin: .other("integration test"))
            try #require(!results.isEmpty, "query \"\(test.query)\" returned no results")
            let topID = results[0].memory.id
            if topID != expectedUUID {
                let gotSeed = idBySeed.first(where: { $0.value == topID })?.key
                misses.append((test.query, test.expectedSeedID, gotSeed, results[0].rrfScore))
            }
        }
        if !misses.isEmpty {
            let description = misses
                .map { "  \"\($0.query)\" → got \($0.got ?? "?") (rrf \($0.rrf)), expected \($0.expected)" }
                .joined(separator: "\n")
            Issue.record("Top-1 mismatches:\n\(description)")
        }
    }

    @Test("unrelated query scores lower than a matched query against the same expected memory")
    func unrelatedScoresLowerThanMatchedQuery() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let matchedQuery = "what causes the northern lights"
        let unrelatedQuery = "the flight path of a migrating humpback whale"
        let expectedUUID = try #require(fixture.ids["astro-aurora"])

        let matchedResults = try await fixture.store.searchMemories(query: matchedQuery, limit: fixture.ids.count, origin: .other("integration test"))
        let unrelatedResults = try await fixture.store.searchMemories(query: unrelatedQuery, limit: fixture.ids.count, origin: .other("integration test"))

        let matchedSimilarity = matchedResults.first(where: { $0.memory.id == expectedUUID })?.similarity ?? 0
        let unrelatedSimilarity = unrelatedResults.first(where: { $0.memory.id == expectedUUID })?.similarity ?? 0

        #expect(
            matchedSimilarity > unrelatedSimilarity,
            "matched=\(matchedSimilarity) should exceed unrelated=\(unrelatedSimilarity) for the aurora memory"
        )
    }

    @Test("exact phrase recall — querying with the memory's own content retrieves it as top-1")
    func exactContentRetrievesItself() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        for seed in Self.seeds {
            let expectedUUID = try #require(fixture.ids[seed.id])
            let results = try await fixture.store.searchMemories(query: seed.content, limit: 1, origin: .other("integration test"))
            try #require(!results.isEmpty, "exact-content query for \(seed.id) returned no results")
            #expect(results[0].memory.id == expectedUUID, "exact-content query for \(seed.id) did not return the same memory")
        }
    }

    // MARK: - Memory activity feed (inspector)

    /// Collects the activity a store publishes.
    private final class ActivityCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [MemoryActivity] = []
        func record(_ activity: MemoryActivity) { lock.withLock { collected.append(activity) } }
        var activities: [MemoryActivity] { lock.withLock { collected } }
        var queries: [MemoryQueryActivity] {
            activities.compactMap { if case .query(let query) = $0.kind { return query } else { return nil } }
        }
        var mutations: [MemoryMutationActivity] {
            activities.compactMap { if case .mutation(let mutation) = $0.kind { return mutation } else { return nil } }
        }
    }

    /// A fresh store sharing the fixture's prepared engine, with its activity collected.
    private static func freshStore(_ fixture: Fixture) async -> (MemoryStore, ActivityCollector) {
        let store = MemoryStore(engine: fixture.engine)
        let collector = ActivityCollector()
        await store.setOnActivityRecorded { collector.record($0) }
        return (store, collector)
    }

    @Test("memories-only and tasks-only searches record the other corpus as not searched")
    func singleCorpusSearchesRecordTheOtherAsNotSearched() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let (store, collector) = await Self.freshStore(fixture)
        try await store.save(content: "The deploy key lives in the ops vault.", source: .smith, origin: .other("test"))
        _ = try await store.searchMemories(query: "deploy key", limit: 5, threshold: 0, origin: .other("test"))
        _ = try await store.searchTaskSummaries(query: "deploy key", limit: 5, threshold: 0, origin: .other("test"))

        let queries = collector.queries
        #expect(queries.count == 2)
        #expect(queries[0].taskSummaries == .notSearched)
        #expect(queries[0].taskScanMs == nil)
        #expect(queries[0].memories.hits?.isEmpty == false)
        #expect(queries[1].memories == .notSearched)
        #expect(queries[1].memoryScanMs == nil)
        #expect(queries[1].taskSummaries == .searched(hits: []), "an empty corpus that was searched is searched-and-empty")
    }

    @Test("searchAll with a zero task limit records tasks as not searched, not as zero results")
    func searchAllZeroLimitIsNotSearched() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let (store, collector) = await Self.freshStore(fixture)
        _ = try await store.searchAll(query: "anything", memoryLimit: 3, taskLimit: 0, origin: .other("test"))
        let query = try #require(collector.queries.first)
        #expect(query.memories == .searched(hits: []))
        #expect(query.taskSummaries == .notSearched)
    }

    @Test("hit snapshots keep query-time content after the memory is edited and deleted")
    func snapshotsSurviveLaterEdits() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let (store, collector) = await Self.freshStore(fixture)
        let entry = try await store.save(content: "Staging runs on port 8443.", source: .brown, tags: ["identifier"],
                                         origin: .other("test"))
        _ = try await store.searchMemories(query: "staging port", limit: 5, threshold: 0, origin: .other("test"))
        try await store.update(id: entry.id, content: "Staging runs on port 9443.", updatedBy: .user, origin: .memoryBrowser)
        await store.delete(id: entry.id, origin: .memoryBrowser)

        let hit = try #require(collector.queries.first?.memories.hits?.first)
        #expect(hit.rank == 1)
        #expect(hit.memoryID == entry.id)
        #expect(hit.content == "Staging runs on port 8443.")
        #expect(hit.tags == ["identifier"])
        #expect(hit.reciprocalRankFusionScore > 0)
    }

    @Test("create, edit, delete, and task-summary writes each emit exactly one mutation, after commit")
    func mutationsEmitOnceAfterCommit() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let (store, collector) = await Self.freshStore(fixture)
        let entry = try await store.save(content: "A", source: .user, tags: ["x"], origin: .memoryBrowser)
        #expect(await store.allMemories().contains { $0.id == entry.id })
        try await store.update(id: entry.id, content: "B", updatedBy: .user, origin: .memoryBrowser)
        // Unchanged content and tags is not a logical mutation.
        try await store.update(id: entry.id, content: "B", updatedBy: .user, origin: .memoryBrowser)
        await store.delete(id: entry.id, origin: .memoryBrowser)
        let task = AgentTask(title: "Summarized", description: "d")
        try await store.saveTaskSummary(task: task, summary: "first", status: .completed)
        try await store.saveTaskSummary(task: task, summary: "second", status: .completed)
        await store.removeTaskSummary(id: task.id)

        let mutations = collector.mutations
        #expect(mutations.map(\.operation) == [.create, .edit, .delete, .taskSummaryWrite, .taskSummaryWrite, .taskSummaryDelete])
        #expect(mutations[1].before == MemoryContentSnapshot(text: "A", tags: ["x"]))
        #expect(mutations[1].after == MemoryContentSnapshot(text: "B", tags: ["x"]))
        #expect(mutations[2].before?.text == "B")
        #expect(mutations[3].retainedExistingID == false)
        #expect(mutations[4].retainedExistingID)
        #expect(mutations[4].before?.text == "first")
        let sequences = collector.activities.map(\.sequence)
        #expect(sequences == Array(1...sequences.count), "sequences are assigned in commit order")
    }

    @Test("retrieval/injection bookkeeping and failed mutations publish nothing")
    func maintenanceAndFailuresArePublishedAsNothing() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let (store, collector) = await Self.freshStore(fixture)
        let entry = try await store.save(content: "Build with make release.", source: .smith, origin: .other("test"))
        let before = collector.activities.count
        await store.recordInjections(memoryIDs: [entry.id])
        await store.persistRetrievalStatsIfNeeded()
        let missing = try await store.update(id: UUID(), content: "x", updatedBy: .user, origin: .memoryBrowser)
        let deletedMissing = await store.delete(id: UUID(), origin: .memoryBrowser)

        #expect(missing == nil)
        #expect(deletedMissing == false)
        #expect(collector.activities.count == before)
    }

    @Test("a consolidation merge records existing, proposed, and final content with its decision")
    func mergeRecordsItsInputsAndDecision() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let (store, collector) = await Self.freshStore(fixture)
        let existing = try await store.save(content: "Phone: 555-0100", source: .smith, tags: ["identifier"], origin: .other("test"))
        let correlationID = UUID()
        try await store.update(
            id: existing.id, content: "Phone: 555-0199", tags: ["identifier", "contact"], updatedBy: .system,
            origin: .memoryConsolidation(requestedBy: .brown),
            consolidation: MemoryConsolidationContext(correlationID: correlationID, candidateMemoryID: existing.id,
                                                      candidateSimilarity: 0.91, outcome: .merged),
            proposed: MemoryContentSnapshot(text: "New phone is 555-0199", tags: ["contact"])
        )
        let merge = try #require(collector.mutations.last)
        #expect(merge.operation == .merge)
        #expect(merge.retainedExistingID)
        #expect(merge.before?.text == "Phone: 555-0100")
        #expect(merge.proposed?.text == "New phone is 555-0199")
        #expect(merge.after == MemoryContentSnapshot(text: "Phone: 555-0199", tags: ["identifier", "contact"]))
        #expect(merge.consolidation?.correlationID == correlationID)
        #expect(merge.consolidation?.outcome == .merged)
    }

    // MARK: - save_memory consolidation outcomes

    private static let existingFact = "The staging database password rotates every 30 days."
    private static let restatedFact = "The staging database password is rotated every 30 days."

    /// Seeds one memory, runs `save_memory` with `proposed` against a stubbed reconciler, and
    /// returns the store's mutations plus the correlation id the reconciler was handed.
    private static func runSaveMemory(
        _ fixture: Fixture,
        proposed: String,
        reconciler: MemoryReconciliation
    ) async throws -> (mutations: [MemoryMutationActivity], queries: [MemoryQueryActivity], reconcilerCorrelation: UUID?, memoryCount: Int) {
        let (store, collector) = await freshStore(fixture)
        try await store.save(content: existingFact, source: .smith, tags: ["procedure"], origin: .other("seed"))
        let handedCorrelation = CorrelationBox()
        let context = TestToolContext.make(
            agentRole: .smith,
            memoryStore: store,
            reconcileMemory: { request in
                handedCorrelation.set(request.correlationID)
                return reconciler
            }
        )
        _ = try await SaveMemoryTool().execute(
            arguments: ["content": .string(proposed), "tags": .array([.string("gotcha")])], context: context)
        let seedCount = 1
        return (Array(collector.mutations.dropFirst(seedCount)), collector.queries, handedCorrelation.value,
                await store.allMemories().count)
    }

    private final class CorrelationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UUID?
        func set(_ id: UUID) { lock.withLock { stored = id } }
        var value: UUID? { lock.withLock { stored } }
    }

    @Test("a SAME merge retains the id, unions tags, and shares one correlation id end to end")
    func consolidationMergeIsLinkedAndComplete() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let run = try await Self.runSaveMemory(fixture, proposed: Self.restatedFact,
                                               reconciler: .merged("Staging DB password rotates every 30 days."))
        #expect(run.memoryCount == 1)
        let merge = try #require(run.mutations.first)
        #expect(run.mutations.count == 1)
        #expect(merge.operation == .merge)
        #expect(merge.retainedExistingID)
        #expect(merge.before?.text == Self.existingFact)
        #expect(merge.proposed?.text == Self.restatedFact)
        #expect(merge.after?.text == "Staging DB password rotates every 30 days.")
        #expect(Set(merge.after?.tags ?? []) == ["procedure", "gotcha"])
        let correlation = try #require(run.reconcilerCorrelation)
        #expect(merge.consolidation?.correlationID == correlation)
        #expect(run.queries.first?.correlationID == correlation)
        #expect(run.queries.first?.origin == .memoryConsolidationCandidateSearch)
    }

    @Test(
        "every non-merge reconciler outcome saves exactly one new memory and says why",
        arguments: [
            (MemoryReconciliation.different, MemoryConsolidationSeparateReason.reconcilerJudgedDifferent),
            (.malformed(response: "hmm"), .reconcilerResponseMalformed(response: "hmm")),
            (.emptyMerge, .reconcilerMergeWasEmpty),
            (.unavailable(errorDescription: "503"), .reconcilerUnavailable(errorDescription: "503")),
            (.cancelled, .reconcilerCancelled),
        ]
    )
    func nonMergeOutcomesKeepSeparate(reconciler: MemoryReconciliation, expected: MemoryConsolidationSeparateReason) async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let run = try await Self.runSaveMemory(fixture, proposed: Self.restatedFact, reconciler: reconciler)
        #expect(run.memoryCount == 2)
        #expect(run.mutations.count == 1)
        let create = try #require(run.mutations.first)
        #expect(create.operation == .create)
        #expect(create.origin == .agentSaveMemory(.smith))
        #expect(create.consolidation?.outcome == .keptSeparate(expected))
        #expect(create.consolidation?.candidateSimilarity != nil)
    }

    @Test("with no qualifying candidate the reconciler is never asked")
    func noCandidateSkipsReconciler() async throws {
        guard let fixture = try await Self.fixtureIfEnabled() else { return }
        let run = try await Self.runSaveMemory(fixture, proposed: "Always run swiftlint before committing.",
                                               reconciler: .merged("must not be used"))
        #expect(run.reconcilerCorrelation == nil)
        #expect(run.memoryCount == 2)
        #expect(run.mutations.first?.consolidation?.outcome == .keptSeparate(.noQualifyingCandidate))
    }
}
