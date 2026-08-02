import Foundation
import Observation
import AgentSmithKit

/// A single pane's view onto a `TranscriptStore`, on the main actor.
///
/// It subscribes to the store with a `TranscriptFilter`, consumes the store's `AsyncStream` of updates,
/// and exposes a plain `messages` array (plus the tool-request id set and the log's restore metadata)
/// for a `ChannelLogView` to render. All the filtering happens OFF this actor inside the store; the only
/// main-thread work here is a SINGLE array assignment per update in `apply`.
///
/// One store can vend many providers (the two-pane view, plus any pop-out) — each with its own filter,
/// each mutating its own `@Observable` array independently. A view creates a provider, calls `attach`
/// on appear, and lets it deinit on disappear (which unsubscribes).
@Observable
@MainActor
final class FilteredTranscriptProvider {

    /// The messages this pane shows, newest last. Mutated at most once per store update.
    private(set) var messages: [ChannelMessage] = []
    /// `requestID`s of every resident `tool_request` in `messages`, maintained incrementally so
    /// `ChannelLogView` can fold tool-output / security-review follow-ups into their parent row without
    /// rebuilding this set over the whole array each render. (Mirrors the old `renderedToolRequestIDs`.)
    private(set) var toolRequestIDs: Set<String> = []
    /// Total messages on disk (drives "Restore full history"). From the store; describes the LOG.
    private(set) var persistedHistoryCount = 0
    /// Whether the full on-disk history has been pulled in (trimming then stops). From the store.
    private(set) var hasRestoredHistory = false

    /// The filter this pane shows. Assigning a new value re-filters via the store (a single full pass
    /// off the main actor) and replaces `messages` wholesale — it does NOT re-filter here.
    var filter: TranscriptFilter {
        didSet {
            guard filter != oldValue, let subscriberID, let store else { return }
            let f = filter
            Task { await store.updateFilter(subscriberID, to: f) }
        }
    }

    /// Cap on the pane's own resident tail (before full-history restore). The store also caps its
    /// resident array; a filtered pane trims its (smaller) view to this independently.
    private let cap: Int
    private weak var store: TranscriptStore?
    private var subscriberID: UUID?
    private var consumeTask: Task<Void, Never>?

    init(filter: TranscriptFilter = .all, cap: Int = 5_000) {
        self.filter = filter
        self.cap = cap
    }

    // No `deinit` cleanup: the consume task captures `self` weakly (no retain cycle), so it self-
    // terminates once this provider is gone. Call `detach()` for prompt, deterministic teardown — the
    // session-lifetime primary provider never needs it; a pop-out / second pane detaches on disappear.

    /// Subscribes to `store` and starts consuming updates. Re-attachable (detaches any prior
    /// subscription first). The first update is always a full snapshot, so `messages` paints correctly
    /// as soon as the stream delivers.
    func attach(to store: TranscriptStore) {
        detach()
        self.store = store
        let initialFilter = filter
        // `store` is captured strongly by the task (the session owns it too, so this just keeps it
        // alive for the subscription's lifetime). `self` is captured WEAKLY and re-bound per iteration
        // so the provider is never retained across a suspension — otherwise a strong `self` held for the
        // whole stream would keep the pane alive forever and its unsubscribe-on-deinit would never fire.
        consumeTask = Task { [weak self] in
            let (id, stream) = await store.subscribe(filter: initialFilter)
            self?.subscriberID = id
            for await update in stream {
                guard let self else { break }
                self.apply(update)
            }
            await store.unsubscribe(id)
        }
    }

    /// Unsubscribes and stops consuming. Safe to call repeatedly.
    func detach() {
        consumeTask?.cancel()
        consumeTask = nil
        if let subscriberID, let store {
            Task { await store.unsubscribe(subscriberID) }
        }
        subscriberID = nil
    }

    /// Applies one store update with a SINGLE write to each observed property. On `replaces` the
    /// message set and id set are swapped wholesale; otherwise the batch is appended and the pane's own
    /// front is trimmed to `cap` (immutable, append-only messages mean the only shrink is the cap).
    private func apply(_ update: TranscriptUpdate) {
        if persistedHistoryCount != update.persistedHistoryCount { persistedHistoryCount = update.persistedHistoryCount }
        if hasRestoredHistory != update.hasRestoredHistory { hasRestoredHistory = update.hasRestoredHistory }

        if update.replaces {
            let newIDs = Set(update.messages.compactMap(Self.toolRequestID(of:)))
            if newIDs != toolRequestIDs { toolRequestIDs = newIDs }
            messages = update.messages
            return
        }

        var updated = messages
        updated.append(contentsOf: update.messages)

        var newIDs = toolRequestIDs
        for message in update.messages {
            if let rid = Self.toolRequestID(of: message) { newIDs.insert(rid) }
        }
        if !hasRestoredHistory, updated.count > cap {
            let removeCount = updated.count - cap
            for trimmed in updated.prefix(removeCount) {
                if let rid = Self.toolRequestID(of: trimmed) { newIDs.remove(rid) }
            }
            updated.removeFirst(removeCount)
        }
        if newIDs != toolRequestIDs { toolRequestIDs = newIDs }
        messages = updated
    }

    /// The `requestID` of `message` if it is a `tool_request`, else nil.
    private static func toolRequestID(of message: ChannelMessage) -> String? {
        guard message.kind == .toolRequest,
              case .string(let requestID)? = message.metadata?["requestID"] else { return nil }
        return requestID
    }
}
