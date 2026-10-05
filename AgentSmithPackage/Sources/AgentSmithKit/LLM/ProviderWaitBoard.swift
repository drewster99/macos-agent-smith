import Foundation
import Synchronization

/// Every LLM caller in a session that is sleeping before a retry, in one place.
///
/// Two jobs, both of which a bare `Task.sleep` could not do:
///
/// - **Visibility.** A caller sleeping on a provider is in a real state of its own, and before
///   this it showed as whatever it happened to be doing around the sleep — an agent read "Idle"
///   (its turn had ended), the worker whose tool call a Security Agent review was holding read
///   "Thinking". On 2026-10-04 a Codex weekly usage limit put every agent to sleep for 4.8 days
///   and the UI showed exactly that. The board publishes each `ProviderWait` for the whole sleep.
/// - **Waking.** When a role's model changes, everything sleeping on that role's OLD model is
///   woken (`wakeForModelChange(of:)`) so it retries on the new one at once, instead of finishing
///   a wait that no longer applies.
///
/// One board per `OrchestrationRuntime`; every retry sleep in the session goes through it
/// (`sleep(for:_:)`). A lock-guarded class rather than an actor so a wake from the runtime never
/// queues behind the sleepers it is waking.
public final class ProviderWaitBoard: Sendable {

    /// How a sleep ended.
    public enum SleepOutcome: Sendable, Equatable {
        /// The full delay passed; retry as planned.
        case elapsed
        /// The waiter's role was given a different model; retry now, on the new model.
        case wokenForModelChange
        /// The waiting task was cancelled (agent stopped, session ended).
        case cancelled
    }

    private struct Sleeper {
        var wait: ProviderWait
        var continuation: CheckedContinuation<SleepOutcome, Never>
        var timer: Task<Void, Never>?
    }

    private struct State {
        var sleepers: [UUID: Sleeper] = [:]
        var onChange: (@Sendable ([ProviderWait]) -> Void)?
    }

    private let state = Mutex(State())

    public init() {}

    /// Registers the observer of the published waits and immediately delivers the current set.
    /// One observer: the owning runtime, which forwards to the UI.
    public func setOnChange(_ handler: (@Sendable ([ProviderWait]) -> Void)?) {
        state.withLock { $0.onChange = handler }
        publish()
    }

    /// Every wait in progress, soonest resumption first.
    public var waits: [ProviderWait] {
        state.withLock { Self.sortedWaits($0.sleepers) }
    }

    /// Sleeps `seconds` while publishing `wait`. Returns early when the waiter's role gets a new
    /// model or the calling task is cancelled.
    public func sleep(for seconds: TimeInterval, _ wait: ProviderWait) async -> SleepOutcome {
        let id = wait.id
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SleepOutcome, Never>) in
                state.withLock { $0.sleepers[id] = Sleeper(wait: wait, continuation: continuation, timer: nil) }
                // Registered BEFORE the cancellation check: a cancel that landed before
                // registration found nothing to finish, and is caught here instead.
                if Task.isCancelled {
                    finish(id, with: .cancelled)
                    return
                }
                let timer = Task { [self] in
                    do {
                        try await Task.sleep(for: .seconds(max(seconds, 0)))
                    } catch {
                        return  // cancelled because the sleep already ended another way
                    }
                    finish(id, with: .elapsed)
                }
                let stillSleeping = state.withLock { state -> Bool in
                    guard state.sleepers[id] != nil else { return false }
                    state.sleepers[id]?.timer = timer
                    return true
                }
                if !stillSleeping { timer.cancel() }
                publish()
            }
        } onCancel: {
            finish(id, with: .cancelled)
        }
        return outcome
    }

    /// Wakes everything sleeping on `role`'s model. Returns how many sleeps it ended.
    @discardableResult
    public func wakeForModelChange(of role: AgentRole) -> Int {
        let ids = state.withLock { state in
            state.sleepers.values.filter { $0.wait.holder.role == role }.map(\.wait.id)
        }
        var woken = 0
        for id in ids where finish(id, with: .wokenForModelChange) { woken += 1 }
        return woken
    }

    /// Ends one sleep exactly once — whichever of timer, wake or cancel gets here first.
    @discardableResult
    private func finish(_ id: UUID, with outcome: SleepOutcome) -> Bool {
        guard let sleeper = state.withLock({ $0.sleepers.removeValue(forKey: id) }) else { return false }
        sleeper.timer?.cancel()
        sleeper.continuation.resume(returning: outcome)
        publish()
        return true
    }

    private func publish() {
        let (snapshot, handler) = state.withLock { state in
            (Self.sortedWaits(state.sleepers), state.onChange)
        }
        handler?(snapshot)
    }

    private static func sortedWaits(_ sleepers: [UUID: Sleeper]) -> [ProviderWait] {
        sleepers.values.map(\.wait).sorted {
            ($0.resumesAt, $0.id.uuidString) < ($1.resumesAt, $1.id.uuidString)
        }
    }
}

extension ProviderWaitBoard {
    /// The sleep for a caller that may have no board (only tests construct holders without one;
    /// the runtime wires a board into every holder it builds — pinned by a test). Without a board
    /// the sleep is a plain one: never visible, never woken.
    static func sleep(
        on board: ProviderWaitBoard?,
        for seconds: TimeInterval,
        _ wait: ProviderWait
    ) async -> SleepOutcome {
        if let board { return await board.sleep(for: seconds, wait) }
        do {
            try await Task.sleep(for: .seconds(max(seconds, 0)))
            return .elapsed
        } catch {
            return .cancelled
        }
    }
}
