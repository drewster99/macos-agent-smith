import Foundation
import SwiftLLMKit

/// Cached, incrementally-updated rollup of estimated cost over four calendar
/// windows (today, this week, this month, this year) and the matching prior
/// periods, plus per-task cost and token totals (`taskUsage`).
///
/// Why this exists: the inspector's Cost Estimate panel needs eight cost totals
/// at all times. Computing them on every SwiftUI redraw would run eight
/// `UsageStore.records(from:to:)` + `UsageAggregator.summarize(...)` passes per
/// frame. Instead, we compute them once at boot, then update incrementally as
/// new `UsageRecord`s arrive — a single record contributes O(1) work to up to
/// four "current" totals. Prior totals are immutable until their calendar
/// boundary rolls.
///
/// Calendar boundaries are computed against a local-time, Sunday-start
/// `Calendar` (`Self.calendar`) — independent of `Calendar.current`, which may
/// pick up locale-defined `firstWeekday = 2`. Boundary rollover (today rolls
/// at midnight local, week rolls Sunday 00:00 local, month at 1st of month,
/// year at Jan 1) is detected lazily on `refreshIfBoundariesElapsed(now:)` —
/// callers (the view or a low-frequency timer) drive the check.
public actor CostBoard {

    // MARK: - Snapshot

    /// All eight totals plus the four calendar intervals that defined them.
    /// Republished as a single value via the `onUpdate` callback so SwiftUI
    /// observers don't need to read individual fields off the actor.
    public struct Snapshot: Sendable, Equatable {
        public var todayCurrent: Double
        public var todayPrior: Double
        public var weekCurrent: Double
        public var weekPrior: Double
        public var monthCurrent: Double
        public var monthPrior: Double
        public var yearCurrent: Double
        public var yearPrior: Double
        /// The current-window intervals these totals describe. `todayInterval.start`
        /// is the most recent local-midnight, etc.
        public var todayInterval: DateInterval
        public var weekInterval: DateInterval
        public var monthInterval: DateInterval
        public var yearInterval: DateInterval
        public var asOf: Date

        public static let empty: Snapshot = {
            let zero = DateInterval(start: .distantPast, end: .distantPast)
            return Snapshot(
                todayCurrent: 0, todayPrior: 0,
                weekCurrent: 0, weekPrior: 0,
                monthCurrent: 0, monthPrior: 0,
                yearCurrent: 0, yearPrior: 0,
                todayInterval: zero, weekInterval: zero,
                monthInterval: zero, yearInterval: zero,
                asOf: .distantPast
            )
        }()
    }

    // MARK: - Calendar

    /// Explicit local-time, Sunday-start Gregorian calendar. Use this everywhere
    /// boundaries are computed — `Calendar.current` may have `firstWeekday = 2`
    /// (ISO) depending on locale, which would break the "Sun-Sat week" contract.
    nonisolated public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = 1  // Sunday
        return c
    }()

    // MARK: - State

    private let usageStore: UsageStore
    private let pricingLookup: @Sendable (String?, String) -> ModelPricing?
    /// Returns "now." Test-injectable so boundary-rollover assertions can advance
    /// the clock without sleeping.
    private let clock: @Sendable () -> Date
    private(set) public var snapshot: Snapshot = .empty
    private var onUpdate: (@Sendable (Snapshot) async -> Void)?
    /// Periodic boundary-check loop. Started from `bootstrap()`, cancelled on `stop()`.
    /// Without this, an idle app (no new records) would not notice when midnight rolls
    /// over and would keep displaying yesterday's totals labeled "Today" until the
    /// next record arrives.
    private var watcherTask: Task<Void, Never>?

    /// Cost and token totals per task, keyed by `UsageRecord.taskID`. Records with no task
    /// attribution — Smith's orchestration overhead — belong to no task and are excluded.
    /// This is the single source every per-task usage figure reads: the cost chips, the
    /// family roll-up, and the detail window's token line. Each of those used to scan the
    /// whole `UsageStore` once on view appear and cache the result, which froze an in-flight
    /// task's numbers at whatever had accrued the moment its view first rendered (usually
    /// nothing) until the task reached a terminal status.
    ///
    /// Cost and tokens travel together in one entry deliberately: they are derived from the
    /// same records in the same pass, so they cannot drift apart or disagree about how much
    /// of a running task's work has landed.
    ///
    /// Recomputed wholesale rather than incremented per insert, unlike the calendar windows
    /// above. Two things stop an insert-only feed from staying exact here: `backfillTaskID`
    /// re-attributes ALREADY-STORED records from "no task" onto a task, which no stream of
    /// new records can describe; and `UsageStore.append` adds to its array immediately while
    /// delivering to `onInsert` from a queue, so a rebuild racing a queued delivery would
    /// count the same record twice. A full grouped pass is O(records), but it runs at most
    /// once per `taskUsageRecomputeInterval` and is self-correcting by construction.
    private(set) public var taskUsage: [UUID: TaskUsage] = [:]
    private var onTaskUsageUpdate: (@Sendable ([UUID: TaskUsage]) async -> Void)?
    /// The pending coalesced recompute, or `nil` when none is scheduled.
    private var taskUsageRecomputeTask: Task<Void, Never>?
    /// Upper bound on how often the per-task map is rebuilt and republished. A figure
    /// arriving a beat late is invisible; re-rendering every task row on every LLM turn
    /// across every live worker is not.
    private static let taskUsageRecomputeInterval: Duration = .milliseconds(750)

    /// One task's accumulated spend and token counts.
    public struct TaskUsage: Sendable, Equatable {
        public var cost: Double = 0
        public var inputTokens: Int = 0
        public var outputTokens: Int = 0
        public var cacheReadTokens: Int = 0
        public var cacheWriteTokens: Int = 0

        public init() {}

        /// Folds one record in. `cost` is passed rather than computed here because pricing
        /// lives on the board, not on the totals.
        mutating func add(_ record: UsageRecord, cost: Double) {
            self.cost += cost
            inputTokens += record.inputTokens
            outputTokens += record.outputTokens
            cacheReadTokens += record.cacheReadTokens
            cacheWriteTokens += record.cacheWriteTokens
        }
    }

    // MARK: - Init

    public init(
        usageStore: UsageStore,
        pricingLookup: @escaping @Sendable (String?, String) -> ModelPricing?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.usageStore = usageStore
        self.pricingLookup = pricingLookup
        self.clock = clock
    }

    /// Registers a callback fired on every snapshot change (bootstrap, incremental
    /// insert, boundary rollover). The current snapshot is delivered immediately.
    public func setOnUpdate(_ handler: @escaping @Sendable (Snapshot) async -> Void) async {
        onUpdate = handler
        await handler(snapshot)
    }

    /// Registers a callback fired on every change to the per-task usage map (bootstrap and
    /// each coalesced recompute). The current map is delivered immediately.
    public func setOnTaskUsageUpdate(_ handler: @escaping @Sendable ([UUID: TaskUsage]) async -> Void) async {
        onTaskUsageUpdate = handler
        await handler(taskUsage)
    }

    /// One-time initial scan. Builds the eight totals from the full `UsageStore`,
    /// subscribes to inserts, and publishes the first snapshot. Idempotent: a
    /// second call rebuilds from scratch.
    public func bootstrap() async {
        await rebuildFromScratch()
        // Populate the per-task map before the first observer paints, so a task that
        // already had spend when the app launched shows it immediately rather than at
        // the first coalesced recompute.
        await recomputeTaskUsage()
        await usageStore.setOnInsert { [weak self] record in
            guard let self else { return }
            await self.recordInserted(record)
        }
        // Start the periodic boundary watcher only on first bootstrap.
        if watcherTask == nil {
            watcherTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    if Task.isCancelled { return }
                    guard let self else { return }
                    await self.refreshIfBoundariesElapsed()
                    // Convergence backstop for record changes that append nothing —
                    // `UsageStore.backfillTaskID` moves existing records onto a task
                    // without producing an insert, so nothing else would notice.
                    await self.recomputeTaskUsage()
                }
            }
        }
    }

    /// Stops the boundary watcher and any pending per-task recompute. Call before
    /// discarding the actor (the app's SharedAppState lives for the whole process,
    /// so this is mostly relevant in tests).
    public func stop() {
        watcherTask?.cancel()
        watcherTask = nil
        taskUsageRecomputeTask?.cancel()
        taskUsageRecomputeTask = nil
    }

    /// Re-anchors any windows whose `currentInterval` no longer contains `now`. Cheap
    /// when no boundary has rolled (just four interval-membership checks). Callers
    /// should invoke this on view appear and from any low-frequency timer that
    /// watches for midnight.
    public func refreshIfBoundariesElapsed() async {
        let now = clock()
        // Fast path: no boundary crossed. Avoids a `dateInterval(of:for:)` call when
        // no work is needed (typical case — fires every 60s on an idle app and the
        // four containment checks all pass).
        if snapshot.todayInterval.contains(now),
           snapshot.weekInterval.contains(now),
           snapshot.monthInterval.contains(now),
           snapshot.yearInterval.contains(now) {
            return
        }

        let intervals = currentIntervals(now: now)
        let priors = priorIntervals(currentIntervals: intervals)

        // Decide which windows rolled from the snapshot we observe up front, but do
        // NOT capture the snapshot's *values* yet: the `sumCost` awaits below suspend
        // the actor, during which `recordInserted` may apply incremental updates. If
        // we captured `var s = snapshot` before the awaits and wrote it back after,
        // we'd clobber those concurrent increments. So we compute every sum into a
        // local first, then re-read the snapshot and apply in one non-suspended write.
        let dayRolled = !snapshot.todayInterval.contains(now)
        let weekRolled = !snapshot.weekInterval.contains(now)
        let monthRolled = !snapshot.monthInterval.contains(now)
        let yearRolled = !snapshot.yearInterval.contains(now)

        // Day rollover: today's current becomes prior, current resets to whatever
        // (if anything) was logged since the new boundary. Same shape for the other
        // windows. All awaits happen here, before the snapshot is re-read.
        var newTodayPrior = 0.0, newTodayCurrent = 0.0
        if dayRolled {
            newTodayPrior = await sumCost(in: priors.day)
            newTodayCurrent = await sumCost(in: intervals.day)
        }
        var newWeekPrior = 0.0, newWeekCurrent = 0.0
        if weekRolled {
            newWeekPrior = await sumCost(in: priors.week)
            newWeekCurrent = await sumCost(in: intervals.week)
        }
        var newMonthPrior = 0.0, newMonthCurrent = 0.0
        if monthRolled {
            newMonthPrior = await sumCost(in: priors.month)
            newMonthCurrent = await sumCost(in: intervals.month)
        }
        var newYearPrior = 0.0, newYearCurrent = 0.0
        if yearRolled {
            newYearPrior = await sumCost(in: priors.year)
            newYearCurrent = await sumCost(in: intervals.year)
        }

        // Critical section: no `await` between this read and the write-back below.
        var s = snapshot
        if dayRolled {
            s.todayPrior = newTodayPrior
            s.todayCurrent = newTodayCurrent
            s.todayInterval = intervals.day
        }
        if weekRolled {
            s.weekPrior = newWeekPrior
            s.weekCurrent = newWeekCurrent
            s.weekInterval = intervals.week
        }
        if monthRolled {
            s.monthPrior = newMonthPrior
            s.monthCurrent = newMonthCurrent
            s.monthInterval = intervals.month
        }
        if yearRolled {
            s.yearPrior = newYearPrior
            s.yearCurrent = newYearCurrent
            s.yearInterval = intervals.year
        }
        s.asOf = now
        snapshot = s
        await publish()
    }

    // MARK: - Internal: scan / incremental

    private func rebuildFromScratch() async {
        let now = clock()
        let intervals = currentIntervals(now: now)
        let priors = priorIntervals(currentIntervals: intervals)

        snapshot = Snapshot(
            todayCurrent: await sumCost(in: intervals.day),
            todayPrior: await sumCost(in: priors.day),
            weekCurrent: await sumCost(in: intervals.week),
            weekPrior: await sumCost(in: priors.week),
            monthCurrent: await sumCost(in: intervals.month),
            monthPrior: await sumCost(in: priors.month),
            yearCurrent: await sumCost(in: intervals.year),
            yearPrior: await sumCost(in: priors.year),
            todayInterval: intervals.day,
            weekInterval: intervals.week,
            monthInterval: intervals.month,
            yearInterval: intervals.year,
            asOf: now
        )
        await publish()
    }

    private func recordInserted(_ record: UsageRecord) async {
        // Roll any elapsed boundaries first so a record that arrives shortly after
        // midnight is attributed to the new "today", not the prior one we still had cached.
        await refreshIfBoundariesElapsed()
        // Critical-section invariant: the read of `snapshot`, the mutations, and
        // the write-back must form one non-suspended region — there must be no
        // `await` between `var s = snapshot` and `snapshot = s`, or a concurrent
        // `recordInserted`/`refreshIfBoundariesElapsed` running at that suspension
        // point would clobber this increment. This relies on `costOf` being
        // synchronous (it is) so the cost is computed without yielding the actor.
        let cost = costOf(record)
        // Bump `asOf` and republish on EVERY insert, not only cost-bearing ones — observers
        // (e.g. the spending dashboard's live refresh) key off `asOf` to know a record landed,
        // and a task run entirely on a free/unpriced model (cost 0) must still trigger them.
        // Totals only move for priced records.
        var s = snapshot
        if cost > 0 {
            if s.todayInterval.contains(record.timestamp) { s.todayCurrent += cost }
            if s.weekInterval.contains(record.timestamp) { s.weekCurrent += cost }
            if s.monthInterval.contains(record.timestamp) { s.monthCurrent += cost }
            if s.yearInterval.contains(record.timestamp) { s.yearCurrent += cost }
        }
        s.asOf = clock()
        snapshot = s
        await publish()
        scheduleTaskUsageRecompute()
    }

    private func publish() async {
        await onUpdate?(snapshot)
    }

    // MARK: - Internal: per-task rollup

    /// Requests a per-task recompute, coalescing a burst of inserts into one pass.
    /// A pass already scheduled absorbs this request — that IS the coalescing.
    private func scheduleTaskUsageRecompute() {
        guard taskUsageRecomputeTask == nil else { return }
        taskUsageRecomputeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.taskUsageRecomputeInterval)
            guard let self else { return }
            await self.runScheduledTaskUsageRecompute()
        }
    }

    /// Clears the pending handle, then recomputes unless this pass was cancelled.
    /// Clearing FIRST, unconditionally, is the point: a handle left pointing at a task
    /// that returned early would make every later `scheduleTaskUsageRecompute` a silent
    /// no-op, and the figures would freeze — the exact failure this rollup exists to
    /// fix. Returning without recomputing is fine; never returning without clearing.
    private func runScheduledTaskUsageRecompute() async {
        taskUsageRecomputeTask = nil
        guard !Task.isCancelled else { return }
        await recomputeTaskUsage()
    }

    /// Rebuilds `taskUsage` from the full record set and republishes if it moved.
    /// Not `private` so tests can drive a pass without waiting out the coalescing window.
    ///
    /// The pending handle is already released by the time we get here (see
    /// `runScheduledTaskUsageRecompute`), so a record landing while this pass is in flight
    /// — after the fetch below has taken its snapshot — schedules the next pass instead of
    /// being absorbed into this one and lost.
    func recomputeTaskUsage() async {
        let records = await usageStore.allRecords()
        var totals: [UUID: TaskUsage] = [:]
        for record in records {
            guard let taskID = record.taskID else { continue }
            totals[taskID, default: TaskUsage()].add(record, cost: costOf(record))
        }
        // Republish only on an actual change, since every publish invalidates every view
        // observing the map.
        guard totals != taskUsage else { return }
        taskUsage = totals
        await onTaskUsageUpdate?(totals)
    }

    // MARK: - Cost math

    /// Same per-record cost formula `UsageAggregator.summarize` uses, distilled
    /// to a single Double. Cache-aware: cached input is subtracted from the
    /// billable input bucket before applying the uncached rate.
    private func costOf(_ record: UsageRecord) -> Double {
        guard let pricing = pricingLookup(record.providerID, record.modelID) else { return 0 }
        let rates = pricing.effectiveRates(totalInputTokens: record.inputTokens)
        let uncachedInput = max(0, record.inputTokens - record.cacheReadTokens - record.cacheWriteTokens)
        let i = Double(uncachedInput) * (rates.input ?? 0)
        let o = Double(record.outputTokens) * (rates.output ?? 0)
        let cr = Double(record.cacheReadTokens) * (rates.cacheRead ?? 0)
        let cw = Double(record.cacheWriteTokens) * (rates.cacheWrite ?? 0)
        return i + o + cr + cw
    }

    /// Aggregates cost across all records inside `interval`. Used at bootstrap
    /// and on boundary rollover only — never on per-render reads.
    private func sumCost(in interval: DateInterval) async -> Double {
        let records = await usageStore.records(from: interval.start, to: interval.end)
        var total: Double = 0
        for r in records {
            total += costOf(r)
        }
        return total
    }

    // MARK: - Calendar boundary helpers

    private struct CurrentIntervals {
        let day: DateInterval
        let week: DateInterval
        let month: DateInterval
        let year: DateInterval
    }

    private struct PriorIntervals {
        let day: DateInterval
        let week: DateInterval
        let month: DateInterval
        let year: DateInterval
    }

    private func currentIntervals(now: Date) -> CurrentIntervals {
        let cal = Self.calendar
        // dateInterval(of:for:) returns [start, end) anchored on the local calendar.
        // The unwrap should never fail for these basic units, but guarding here keeps
        // us off force-unwraps and yields a zero-length fallback if it ever does.
        func interval(_ unit: Calendar.Component) -> DateInterval {
            cal.dateInterval(of: unit, for: now) ?? DateInterval(start: now, duration: 0)
        }
        return CurrentIntervals(
            day: interval(.day),
            week: interval(.weekOfYear),
            month: interval(.month),
            year: interval(.year)
        )
    }

    private func priorIntervals(currentIntervals current: CurrentIntervals) -> PriorIntervals {
        let cal = Self.calendar
        // Prior window = the full prior calendar unit. Anchor by walking one unit
        // before the current start, then re-resolving the interval at that anchor.
        func priorOf(_ unit: Calendar.Component, current: DateInterval) -> DateInterval {
            let anchor = cal.date(byAdding: unit, value: -1, to: current.start) ?? current.start
            return cal.dateInterval(of: unit, for: anchor) ?? DateInterval(start: anchor, duration: 0)
        }
        return PriorIntervals(
            day: priorOf(.day, current: current.day),
            week: priorOf(.weekOfYear, current: current.week),
            month: priorOf(.month, current: current.month),
            year: priorOf(.year, current: current.year)
        )
    }
}
