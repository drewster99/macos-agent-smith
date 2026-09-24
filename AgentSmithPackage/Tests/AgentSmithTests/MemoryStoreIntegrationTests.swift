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
///   AGENT_SMITH_RUN_MLX_TESTS=1 \
///   xcodebuild test \
///       -scheme AgentSmith \
///       -destination 'platform=macOS' \
///       -only-testing:AgentSmithTests/MemoryStoreIntegrationTests
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
                tags: seed.tags
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
}
