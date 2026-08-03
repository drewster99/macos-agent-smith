import Testing
import Foundation
@testable import AgentSmithKit

/// Exercises the off-main transcript core: subscribe → snapshot, ingest → coalesced fan-out, per-pane
/// filtering, the resident cap, `clear` (which must KEEP the on-disk count so Restore stays offered),
/// and the injected log readers. `flush()` is driven explicitly so the tests don't race the 16 ms timer.
@Suite struct TranscriptStoreTests {

    private func msg(_ content: String, sender: ChannelMessage.Sender = .user, task: UUID? = nil) -> ChannelMessage {
        ChannelMessage(sender: sender, content: content, taskID: task)
    }

    @Test func subscribeYieldsEmptyInitialSnapshot() async {
        let store = TranscriptStore()
        let (_, stream) = await store.subscribe(filter: .all)
        var it = stream.makeAsyncIterator()
        let first = await it.next()
        #expect(first?.replaces == true)
        #expect(first?.messages.isEmpty == true)
        #expect(first?.persistedHistoryCount == 0)
    }

    @Test func ingestFlushFansOutAppendDelta() async {
        let store = TranscriptStore()
        let (_, stream) = await store.subscribe(filter: .all)
        var it = stream.makeAsyncIterator()
        _ = await it.next()   // initial empty snapshot

        await store.ingest(msg("hello"))
        await store.flush()
        let update = await it.next()
        #expect(update?.replaces == false)
        #expect(update?.messages.count == 1)
        #expect(update?.messages.first?.content == "hello")
        #expect(update?.persistedHistoryCount == 1)
    }

    @Test func filterExcludesNonMatchingSenders() async {
        let store = TranscriptStore()
        let (_, stream) = await store.subscribe(filter: TranscriptFilter(allowedSenders: [.user]))
        var it = stream.makeAsyncIterator()
        _ = await it.next()

        await store.ingest(msg("from smith", sender: .agent(.smith)))
        await store.ingest(msg("from user", sender: .user))
        await store.flush()
        let update = await it.next()
        // Only the user message belongs in this pane's delta; the smith one is filtered off-main.
        #expect(update?.messages.count == 1)
        #expect(update?.messages.first?.sender == .user)
    }

    @Test func filterByTaskScope() async {
        let taskA = UUID()
        let store = TranscriptStore()
        let (_, stream) = await store.subscribe(filter: TranscriptFilter(taskScope: .task(taskA)))
        var it = stream.makeAsyncIterator()
        _ = await it.next()

        await store.ingest(msg("for A", task: taskA))
        await store.ingest(msg("for B", task: UUID()))
        await store.ingest(msg("orchestration", task: nil))
        await store.flush()
        let update = await it.next()
        #expect(update?.messages.count == 1)
        #expect(update?.messages.first?.content == "for A")
    }

    @Test func residentCapTrimsFrontButKeepsCount() async {
        let store = TranscriptStore(residentCap: 3)
        for i in 1...5 { await store.ingest(msg("m\(i)")) }
        await store.flush()
        // A fresh subscriber sees the capped, most-recent tail…
        let (_, stream) = await store.subscribe(filter: .all)
        var it = stream.makeAsyncIterator()
        let snapshot = await it.next()
        #expect(snapshot?.messages.map(\.content) == ["m3", "m4", "m5"])
        // …but the persisted count reflects everything ever ingested (drives "Load earlier").
        let count = await store.persistedHistoryCount
        #expect(count == 5)
    }

    @Test func clearKeepsPersistedCountAndReoffersRestore() async {
        let store = TranscriptStore()
        await store.ingest(msg("a"))
        await store.ingest(msg("b"))
        await store.flush()
        await store.clear()
        // The on-disk log is untouched, so the count must survive and Restore must be re-offered.
        let count = await store.persistedHistoryCount
        let restored = await store.hasRestoredHistory
        #expect(count == 2)
        #expect(restored == false)
        let (_, stream) = await store.subscribe(filter: .all)
        var it = stream.makeAsyncIterator()
        let snapshot = await it.next()
        #expect(snapshot?.messages.isEmpty == true)
        #expect(snapshot?.persistedHistoryCount == 2)
    }

    @Test func loadInitialTailResetsSubscribers() async throws {
        let store = TranscriptStore()
        let seeded = [msg("x"), msg("y")]
        await store.setLogReaders(
            loadFull: { seeded },
            loadTail: { _ in (seeded, seeded.count) }
        )
        let (_, stream) = await store.subscribe(filter: .all)
        var it = stream.makeAsyncIterator()
        _ = await it.next()   // initial empty (subscribed before load)
        try await store.loadInitialTail()
        let update = await it.next()
        #expect(update?.replaces == true)
        #expect(update?.messages.count == 2)
        #expect(update?.hasRestoredHistory == true)   // the whole log fit in the tail
    }

    @Test func updateFilterResetsToNewView() async {
        let store = TranscriptStore()
        await store.ingest(msg("smith", sender: .agent(.smith)))
        await store.ingest(msg("user", sender: .user))
        await store.flush()
        let (id, stream) = await store.subscribe(filter: .all)
        var it = stream.makeAsyncIterator()
        let all = await it.next()
        #expect(all?.messages.count == 2)   // .all sees both

        await store.updateFilter(id, to: TranscriptFilter(allowedSenders: [.user]))
        let filtered = await it.next()
        #expect(filtered?.replaces == true)
        #expect(filtered?.messages.count == 1)
        #expect(filtered?.messages.first?.sender == .user)
    }
}
