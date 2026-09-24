import Testing
import Foundation
import SemanticSearch
@testable import AgentSmithKit

/// `MemoryStore` activity for the paths that need no embedding model — seeded with `restore`, so
/// these run in the normal `swift test` pass (the embedding paths live in the MLX-gated
/// `MemoryStoreIntegrationTests`).
@Suite("MemoryStore activity without embeddings")
struct MemoryStoreActivityTests {
    private static let engine = SemanticSearchEngine()

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [MemoryActivity] = []
        func record(_ activity: MemoryActivity) { lock.withLock { collected.append(activity) } }
        var mutations: [MemoryMutationActivity] {
            lock.withLock { collected }.compactMap { if case .mutation(let m) = $0.kind { return m } else { return nil } }
        }
        var count: Int { lock.withLock { collected.count } }
    }

    private func seededStore(memory: MemoryEntry, summary: TaskSummaryEntry? = nil) async -> (MemoryStore, Collector) {
        let store = MemoryStore(engine: Self.engine)
        await store.restore(memories: [memory], taskSummaries: summary.map { [$0] } ?? [])
        let collector = Collector()
        await store.setOnActivityRecorded { collector.record($0) }
        return (store, collector)
    }

    private func memory(_ content: String) -> MemoryEntry {
        MemoryEntry(content: content, embedding: [1, 0], source: .smith, tags: ["t"], sourceTaskID: UUID())
    }

    @Test("delete publishes one DELETE carrying what was removed; deleting again publishes nothing")
    func deletePublishesOnce() async {
        let entry = memory("the fact")
        let (store, collector) = await seededStore(memory: entry)
        #expect(await store.delete(id: entry.id, origin: .memoryBrowser))
        #expect(await store.delete(id: entry.id, origin: .memoryBrowser) == false)
        let mutations = collector.mutations
        #expect(mutations.count == 1)
        #expect(mutations.first?.operation == .delete)
        #expect(mutations.first?.before == MemoryContentSnapshot(text: "the fact", tags: ["t"]))
        #expect(mutations.first?.taskID == entry.sourceTaskID)
        #expect(mutations.first?.origin == .memoryBrowser)
    }

    @Test("a conditional update against changed content writes and publishes nothing")
    func conditionalUpdateRefusesChangedContent() async throws {
        let entry = memory("current text")
        let (store, collector) = await seededStore(memory: entry)
        let result = try await store.update(id: entry.id, content: "merged", updatedBy: .system,
                                            origin: .memoryConsolidation(requestedBy: .brown),
                                            onlyIfUnchangedFrom: MemoryContentSnapshot(text: "the text the reconciler saw", tags: ["t"]))
        #expect(result == nil)
        #expect(await store.allMemories().first?.content == "current text", "the edit must survive")
        #expect(collector.count == 0)
    }

    @Test("a conditional update refuses when only the tags changed underneath it")
    func conditionalUpdateRefusesChangedTags() async throws {
        let entry = memory("current text")
        let (store, collector) = await seededStore(memory: entry)
        let result = try await store.update(id: entry.id, content: "merged", updatedBy: .system,
                                            origin: .memoryConsolidation(requestedBy: .brown),
                                            onlyIfUnchangedFrom: MemoryContentSnapshot(text: "current text", tags: ["old tag"]))
        #expect(result == nil, "a tag edit made while the reconciler ran must not be overwritten")
        #expect(collector.count == 0)
    }

    @Test("an update that changes nothing publishes no EDIT")
    func noOpUpdatePublishesNothing() async throws {
        let entry = memory("same")
        let (store, collector) = await seededStore(memory: entry)
        let result = try await store.update(id: entry.id, content: "same", tags: ["t"], updatedBy: .user, origin: .memoryBrowser)
        #expect(result != nil)
        #expect(collector.count == 0)
    }

    @Test("injection bookkeeping publishes nothing")
    func bookkeepingPublishesNothing() async {
        let entry = memory("fact")
        let (store, collector) = await seededStore(memory: entry)
        await store.recordInjections(memoryIDs: [entry.id])
        await store.persistRetrievalStatsIfNeeded()
        #expect(collector.count == 0)
    }

    @Test("removing a task summary publishes one TASK SUMMARY delete with its text")
    func removeTaskSummaryPublishes() async {
        let taskID = UUID()
        let summary = TaskSummaryEntry(id: taskID, title: "Build", summary: "It was built.", embeddingSourceText: "x",
                                       embedding: [1, 0], status: .completed, taskCreatedAt: Date())
        let (store, collector) = await seededStore(memory: memory("m"), summary: summary)
        await store.removeTaskSummary(id: taskID)
        await store.removeTaskSummary(id: taskID)
        let mutations = collector.mutations
        #expect(mutations.count == 1)
        #expect(mutations.first?.operation == .taskSummaryDelete)
        #expect(mutations.first?.subject == .taskSummary(taskID: taskID, title: "Build"))
        #expect(mutations.first?.before?.text == "It was built.")
        #expect(mutations.first?.origin == .permanentTaskDeletion)
    }
}
