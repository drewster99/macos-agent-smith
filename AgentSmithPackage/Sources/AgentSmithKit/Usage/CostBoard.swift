import Foundation
import SwiftLLMKit

/// Cached, incrementally-updated rollup of estimated cost over four calendar
/// windows (today, this week, this month, this year) and the matching prior
/// periods.
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

    /// One-time initial scan. Builds the eight totals from the full `UsageStore`,
    /// subscribes to inserts, and publishes the first snapshot. Idempotent: a
    /// second call rebuilds from scratch.
    public func bootstrap() async {
        await rebuildFromScratch()
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
                }
            }
        }
    }

    /// Stops the boundary watcher. Call before discarding the actor (the app's
    /// SharedAppState lives for the whole process, so this is mostly relevant
    /// in tests).
    public func stop() {
        watcherTask?.cancel()
        watcherTask = nil
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
        var s = snapshot
        if !s.todayInterval.contains(now) {
            // Day rollover: today's current becomes prior, current resets to whatever
            // (if anything) was logged since the new boundary.
            s.todayPrior = await sumCost(in: priors.day)
            s.todayCurrent = await sumCost(in: intervals.day)
            s.todayInterval = intervals.day
        }
        if !s.weekInterval.contains(now) {
            s.weekPrior = await sumCost(in: priors.week)
            s.weekCurrent = await sumCost(in: intervals.week)
            s.weekInterval = intervals.week
        }
        if !s.monthInterval.contains(now) {
            s.monthPrior = await sumCost(in: priors.month)
            s.monthCurrent = await sumCost(in: intervals.month)
            s.monthInterval = intervals.month
        }
        if !s.yearInterval.contains(now) {
            s.yearPrior = await sumCost(in: priors.year)
            s.yearCurrent = await sumCost(in: intervals.year)
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
        let cost = costOf(record)
        guard cost > 0 else { return }
        var s = snapshot
        if s.todayInterval.contains(record.timestamp) { s.todayCurrent += cost }
        if s.weekInterval.contains(record.timestamp) { s.weekCurrent += cost }
        if s.monthInterval.contains(record.timestamp) { s.monthCurrent += cost }
        if s.yearInterval.contains(record.timestamp) { s.yearCurrent += cost }
        s.asOf = clock()
        snapshot = s
        await publish()
    }

    private func publish() async {
        await onUpdate?(snapshot)
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
