import Foundation

/// Produces notifications. A source owns its own pending state (a timer owns its schedules; an
/// event source owns its subscriptions) and persists it. It is the source's job to mint each
/// notification's DETERMINISTIC idempotency key from already-durable state, so a re-post after a
/// crash collides in the ledger rather than double-delivering.
///
/// Two production styles, both supported by the broker:
/// - **Pollable** (timers): `drainReady(now:)` returns notifications whose fire time has passed.
///   The broker calls it on a tick and at cold boot. Recurrence lives in the source (a timer
///   concept), never in the core.
/// - **Event-driven** (inbound message, webhook): the source posts on demand via its `SourceHandle`
///   when an external event arrives; `drainReady` returns empty.
///
/// What a NEW source writes: a `NotificationSource` conformer + (maybe) a `TriggerSource` case.
/// Nothing in the broker, ledger, or routing changes.
public protocol NotificationSource: Sendable, AnyObject {
    /// Notifications whose trigger has fired and that have not yet been produced this pass. Called
    /// at cold boot and on each broker tick. Producing one should atomically advance/remove the
    /// source's own pending record (commit-on-produce) so replay never re-produces a fired one.
    func drainReady(now: Date) async -> [AgentNotification]
}
