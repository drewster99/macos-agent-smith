import Foundation

/// Drives timer-based notifications end to end — the "separate thing that schedules," kept apart
/// from the `NotificationBroker` (which only delivers and persists-until-delivery, never schedules).
///
/// `WakeScheduler` OWNS the scheduled wakes, PERSISTS them itself, arms a real timer for the next
/// due wake, and — when a wake fires — PRODUCES a notification into the broker. Nothing polls: an
/// armed `Task` sleeps until the earliest wake, fires the due batch, re-arms. Smith no longer owns
/// or checks wakes; he only drains the notifications the broker hands him.
///
/// Created before the broker and agents exist (so the `ToolContext` can capture it), then wired via
/// the `set*` methods and handed its persisted wakes through `restore` at boot.
actor WakeScheduler {
    private var wakes: [ScheduledWake] = []
    private var hasRestored = false
    private var timerTask: Task<Void, Never>?

    private var broker: NotificationBroker?
    private var persist: (@Sendable ([ScheduledWake]) async -> Void)?
    private var promoteScheduledToPending: (@Sendable (UUID) async -> Void)?
    private var onScheduled: (@Sendable (ScheduledWake) -> Void)?
    private var onFired: (@Sendable (ScheduledWake, [ScheduledWake]) -> Void)?
    private var onCancelled: (@Sendable (ScheduledWake, WakeCancellationCause) -> Void)?

    // MARK: - Wiring (called once after construction, before restore)

    func setBroker(_ broker: NotificationBroker) { self.broker = broker }

    func setPersistence(_ persist: @escaping @Sendable ([ScheduledWake]) async -> Void) {
        self.persist = persist
    }

    /// The scheduler promotes a `.scheduled` task to `.pending` the instant its RUN wake fires, so
    /// the auto-run path (which rejects `.scheduled`) accepts it.
    func setPromotion(_ promote: @escaping @Sendable (UUID) async -> Void) {
        self.promoteScheduledToPending = promote
    }

    func setTimerCallbacks(
        onScheduled: (@Sendable (ScheduledWake) -> Void)? = nil,
        onFired: (@Sendable (ScheduledWake, [ScheduledWake]) -> Void)? = nil,
        onCancelled: (@Sendable (ScheduledWake, WakeCancellationCause) -> Void)? = nil
    ) {
        self.onScheduled = onScheduled
        self.onFired = onFired
        self.onCancelled = onCancelled
    }

    // MARK: - Boot

    /// Installs the wake list recovered from disk (already filtered by the runtime's restart-replay
    /// policy) and arms. Does NOT persist — the set already came from disk, and persisting here
    /// before any real change risks truncating the file if called with an empty recovery set. Past-
    /// due wakes fire ~immediately (the armed timer's delay clamps to 0), the correct recovery for a
    /// wake that elapsed while the app was quit.
    func restore(_ wakes: [ScheduledWake]) {
        self.wakes = wakes.sorted { $0.wakeAt < $1.wakeAt }
        hasRestored = true
        armTimer()
    }

    /// Cancels the armed timer. Called on runtime teardown so a pending `Task.sleep` doesn't fire
    /// against a stopped runtime.
    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Tool-facing API (schedule / list / cancel)

    func scheduleWake(
        wakeAt: Date,
        instructions: String,
        taskID: UUID? = nil,
        replacesID: UUID? = nil,
        recurrence: Recurrence? = nil,
        survivesTaskTermination: Bool = false,
        action: TaskActionKind? = nil
    ) async -> ScheduleWakeOutcome {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .error("instructions must not be empty — describe what should happen when the wake fires.")
        }

        if let replacesID, let replaced = wakes.first(where: { $0.id == replacesID }) {
            wakes.removeAll { $0.id == replacesID }
            onCancelled?(replaced, .replaced)
        }

        let wake = ScheduledWake(
            wakeAt: wakeAt,
            instructions: trimmed,
            taskID: taskID,
            recurrence: recurrence,
            survivesTaskTermination: survivesTaskTermination,
            action: action
        )
        wakes.append(wake)
        wakes.sort { $0.wakeAt < $1.wakeAt }
        onScheduled?(wake)
        await persistWakes()
        armTimer()
        return .scheduled(wake)
    }

    func listScheduledWakes() -> [ScheduledWake] { wakes }

    @discardableResult
    func cancelWake(id: UUID) async -> Bool {
        guard let removed = wakes.first(where: { $0.id == id }) else { return false }
        wakes.removeAll { $0.id == id }
        onCancelled?(removed, .userRequest)
        await persistWakes()
        armTimer()
        return true
    }

    /// Cancels wakes linked to a terminated task whose `survivesTaskTermination` is false. Wakes
    /// flagged to survive (currently `run`/`summarize`) are retained so a queued future run isn't
    /// wiped by the first run's completion.
    @discardableResult
    func cancelWakesForTask(_ taskID: UUID) async -> [UUID] {
        let doomed = wakes.filter { $0.taskID == taskID && !$0.survivesTaskTermination }
        guard !doomed.isEmpty else { return [] }
        wakes.removeAll { $0.taskID == taskID && !$0.survivesTaskTermination }
        for wake in doomed { onCancelled?(wake, .taskTerminated) }
        await persistWakes()
        armTimer()
        return doomed.map(\.id)
    }

    // MARK: - Firing

    /// Arms a single timer for the earliest scheduled wake. Re-armed on every mutation, so an
    /// earlier wake added later supersedes a pending sleep. A past-due earliest clamps the delay to
    /// 0 and fires on the next runloop hop — the catch-up path.
    private func armTimer() {
        timerTask?.cancel()
        guard let earliest = wakes.map(\.wakeAt).min() else { timerTask = nil; return }
        let delay = max(0, earliest.timeIntervalSinceNow)
        timerTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.fireDue()
        }
    }

    /// Fires every wake whose time has arrived: promote scheduled tasks, produce a notification per
    /// wake into the broker, roll recurring wakes forward (catch-up-collapsed so a long-offline gap
    /// yields ONE future occurrence, not a per-period storm), persist, re-arm. Internal so tests can
    /// drive it deterministically without waiting on the armed timer.
    func fireDue() async {
        let now = Date()
        let due = wakes.filter { $0.wakeAt <= now }
        guard !due.isEmpty else { armTimer(); return }
        wakes.removeAll { $0.wakeAt <= now }

        // Promote a `.scheduled` task to `.pending` when its RUN wake fires, so the auto-run path
        // (which rejects `.scheduled`) accepts it. Gate on `run`: a summarize/pause/interrupt wake
        // firing while the task is still scheduled must not promote it.
        var promoted: Set<UUID> = []
        for wake in due where wake.action == .run {
            guard let taskID = wake.taskID, promoted.insert(taskID).inserted else { continue }
            await promoteScheduledToPending?(taskID)
        }

        // Produce a structured notification per fired wake. The broker decides its fate by the
        // wake's `action` (run → mechanical; reminder/summary → queued for Smith to drain).
        for wake in due {
            await broker?.submit(WakeNotificationFactory.notification(for: wake))
        }

        if let primary = due.first { onFired?(primary, due) }

        for wake in due {
            guard let recurrence = wake.recurrence,
                  let next = recurrence.nextOccurrence(after: wake.wakeAt, notBefore: now) else { continue }
            let nextWake = ScheduledWake(
                wakeAt: next,
                instructions: wake.instructions,
                taskID: wake.taskID,
                recurrence: recurrence,
                originalID: wake.originalID,
                previousFireAt: wake.wakeAt,
                survivesTaskTermination: wake.survivesTaskTermination,
                action: wake.action
            )
            wakes.append(nextWake)
            onScheduled?(nextWake)
        }
        wakes.sort { $0.wakeAt < $1.wakeAt }
        await persistWakes()
        armTimer()
    }

    private func persistWakes() async {
        guard hasRestored else { return }
        await persist?(wakes)
    }
}
