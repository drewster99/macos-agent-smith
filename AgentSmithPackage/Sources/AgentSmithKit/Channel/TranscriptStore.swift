import Foundation

/// One update pushed from a `TranscriptStore` to a subscribed pane.
///
/// The delta is deliberately just "here are messages; replace or append". Eviction is NOT a wire
/// concern — a subscriber trims its own front to its own cap when it appends, because messages are
/// immutable and append-only, so the only way a filtered view shrinks is its own cap. `replaces == true`
/// is a wholesale swap (initial snapshot, filter change, restore, clear); `replaces == false` appends.
///
/// `persistedHistoryCount` / `hasRestoredHistory` ride along so a pane's "Load earlier" / "Restore full
/// history" affordances stay current without a second round-trip. They describe the underlying LOG (all
/// messages on disk), not the filtered view — the same semantics the single pane had.
public struct TranscriptUpdate: Sendable {
    public let messages: [ChannelMessage]
    public let replaces: Bool
    public let persistedHistoryCount: Int
    public let hasRestoredHistory: Bool

    public init(messages: [ChannelMessage], replaces: Bool, persistedHistoryCount: Int, hasRestoredHistory: Bool) {
        self.messages = messages
        self.replaces = replaces
        self.persistedHistoryCount = persistedHistoryCount
        self.hasRestoredHistory = hasRestoredHistory
    }
}

/// The per-session owner of the transcript, OFF the main actor.
///
/// It holds the resident tail, coalesces the channel stream, persists to the JSONL log, and fans each
/// batch out to every subscribed pane — running all of the filtering and distribution inside the actor
/// so the main thread only ever performs the final array assignment (in `FilteredTranscriptProvider`).
///
/// A pane subscribes with a `TranscriptFilter` and consumes an `AsyncStream<TranscriptUpdate>`. On a
/// new batch the store tests ONLY the batch against each subscriber's filter (O(batch × subscribers)),
/// never the whole resident array — that full pass happens only on subscribe / filter-change / restore.
///
/// Persistence + full-log loading are injected as closures (set via `setPersistence`) so the store stays
/// decoupled from `PersistenceManager` and trivially testable; a store with no persistence set keeps
/// everything in memory (the test/standalone shape).
public actor TranscriptStore {

    // MARK: Resident state

    private var resident: [ChannelMessage] = []
    /// Total messages ever written to the log (grows past the resident cap). Drives "Load earlier".
    private(set) var persistedHistoryCount = 0
    /// True once the full on-disk history has been pulled in — after which the resident tail stops being
    /// trimmed (the user opted into holding everything until relaunch).
    private(set) var hasRestoredHistory = false
    /// Cap on the resident tail before `restoreFullHistory`. A non-lazy transcript materializes a layer
    /// per row, so only a bounded tail is ever held; the full history lives on disk.
    private let residentCap: Int

    public init(residentCap: Int = 5_000) {
        self.residentCap = residentCap
    }

    // MARK: Coalescer

    private var pendingIngest: [ChannelMessage] = []
    private var flushScheduled = false
    /// One frame at 60 Hz. A within-frame burst folds into a single fan-out so each pane mutates at most
    /// once per frame — the same discipline the old `AppViewModel` coalescer enforced, now off-main.
    private static let flushInterval: Duration = .milliseconds(16)

    /// Buffers a streamed message for coalesced folding. Speech (which must fire immediately) is handled
    /// by the caller BEFORE it forwards here — the store owns only the visible/persisted transcript.
    public func ingest(_ message: ChannelMessage) {
        pendingIngest.append(message)
        scheduleFlush()
    }

    /// Buffers a batch (e.g. a synchronous local system line). Same coalesced path as `ingest`.
    public func ingest(_ messages: [ChannelMessage]) {
        guard !messages.isEmpty else { return }
        pendingIngest.append(contentsOf: messages)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            await self?.flush()
        }
    }

    /// Folds every buffered message into the resident tail in one pass and fans it out. Public so a
    /// shutdown path can force a final flush and guarantee no buffered message is lost.
    public func flush() async {
        flushScheduled = false
        guard !pendingIngest.isEmpty else { return }
        let batch = pendingIngest
        pendingIngest.removeAll(keepingCapacity: true)

        resident.append(contentsOf: batch)
        persistedHistoryCount += batch.count
        if !hasRestoredHistory, resident.count > residentCap {
            resident.removeFirst(resident.count - residentCap)
        }

        fanOut(appended: batch)
    }

    /// Wipes the resident tail and every subscriber's view (the `/clear` screen reset). Persistence is
    /// the caller's concern — the store owns display only.
    public func clear() {
        resident.removeAll()
        persistedHistoryCount = 0
        hasRestoredHistory = false
        resetAllSubscribers()
    }

    private func fanOut(appended batch: [ChannelMessage]) {
        for subscriber in subscribers.values {
            let matched = batch.filter(subscriber.filter.matches)
            guard !matched.isEmpty else { continue }
            subscriber.continuation.yield(makeAppend(matched))
        }
    }

    // MARK: Subscribers

    private struct Subscriber {
        var filter: TranscriptFilter
        let continuation: AsyncStream<TranscriptUpdate>.Continuation
    }
    private var subscribers: [UUID: Subscriber] = [:]

    /// Subscribes a pane. Returns the subscriber id (for `updateFilter`/`unsubscribe`) and the stream to
    /// consume. The FIRST element is always a `replaces: true` snapshot of the current resident tail
    /// under `filter`, so a pane paints correctly the instant it appears. The registry entry is removed
    /// automatically when the consumer stops iterating (the pane's view disappears).
    public func subscribe(filter: TranscriptFilter) -> (id: UUID, stream: AsyncStream<TranscriptUpdate>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TranscriptUpdate>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = Subscriber(filter: filter, continuation: continuation)
        continuation.yield(makeReset(under: filter))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return (id, stream)
    }

    /// Re-filters the resident tail for one subscriber and pushes a fresh `replaces: true` snapshot. This
    /// is the ONLY full-resident pass on the append path's critical section — it runs on a user's filter
    /// change, not per message.
    public func updateFilter(_ id: UUID, to filter: TranscriptFilter) {
        guard var subscriber = subscribers[id] else { return }
        subscriber.filter = filter
        subscribers[id] = subscriber
        subscriber.continuation.yield(makeReset(under: filter))
    }

    public func unsubscribe(_ id: UUID) {
        removeSubscriber(id)
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id]?.continuation.finish()
        subscribers.removeValue(forKey: id)
    }

    private func makeAppend(_ messages: [ChannelMessage]) -> TranscriptUpdate {
        TranscriptUpdate(messages: messages, replaces: false,
                         persistedHistoryCount: persistedHistoryCount, hasRestoredHistory: hasRestoredHistory)
    }
    private func makeReset(under filter: TranscriptFilter) -> TranscriptUpdate {
        TranscriptUpdate(messages: resident.filter(filter.matches), replaces: true,
                         persistedHistoryCount: persistedHistoryCount, hasRestoredHistory: hasRestoredHistory)
    }

    private func resetAllSubscribers() {
        for subscriber in subscribers.values {
            subscriber.continuation.yield(makeReset(under: subscriber.filter))
        }
    }

    // MARK: Log readers (injected)
    //
    // The store owns DISPLAY (the resident tail + fan-out). Persistence — the JSONL append and its
    // shutdown flush — stays with the session's view model; the store only READS the log, to seed the
    // initial tail at launch and to satisfy a user-initiated "Restore full history".

    private var loadFullLog: (@Sendable () async throws -> [ChannelMessage])?
    private var loadLogTail: (@Sendable (Int) async throws -> (messages: [ChannelMessage], totalCount: Int))?

    public func setLogReaders(
        loadFull: @escaping @Sendable () async throws -> [ChannelMessage],
        loadTail: @escaping @Sendable (Int) async throws -> (messages: [ChannelMessage], totalCount: Int)
    ) {
        loadFullLog = loadFull
        loadLogTail = loadTail
    }

    /// Loads the most-recent `residentCap` messages from the log into the resident tail and resets every
    /// subscriber to the freshly-loaded view. Called once at session start after persistence is wired.
    public func loadInitialTail() async throws {
        guard let loadLogTail else { return }
        let (tail, total) = try await loadLogTail(residentCap)
        resident = tail
        persistedHistoryCount = total
        hasRestoredHistory = tail.count >= total
        resetAllSubscribers()
    }

    /// Pulls the ENTIRE on-disk history into the resident tail (user-initiated "Restore full history"),
    /// suspending trimming from here on, then resets every subscriber. Idempotent.
    public func restoreFullHistory() async throws {
        guard !hasRestoredHistory, let loadFullLog else { return }
        let full = try await loadFullLog()
        // Any resident message not yet on disk (a not-yet-persisted append) is kept after the
        // authoritative history, deduped by id.
        let fullIDs = Set(full.map(\.id))
        let liveTail = resident.filter { !fullIDs.contains($0.id) }
        resident = full + liveTail
        persistedHistoryCount = resident.count
        hasRestoredHistory = true
        resetAllSubscribers()
    }
}
