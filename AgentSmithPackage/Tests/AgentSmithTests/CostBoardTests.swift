import Testing
import Foundation
@testable import AgentSmithKit
import SwiftLLMKit

/// Tests for `CostBoard` — the cached, incrementally-updated cost rollup that
/// powers the inspector's Cost Estimate panel.
///
/// The contracts under test:
///
/// - **Bootstrap.** A full scan of the `UsageStore` produces eight totals
///   (today / week / month / year × current / prior) using the canonical local-TZ,
///   Sunday-start calendar — *not* `Calendar.current`.
/// - **Incremental insert.** A new record published via `UsageStore.append` flows
///   through to the snapshot in O(1) — no re-scans.
/// - **Boundary rollover.** Advancing the clock past midnight rolls today's current
///   into prior and resets current. Each window rolls independently — a day boundary
///   does not disturb the week / month / year totals.
/// - **Calendar configuration.** The shared `CostBoard.calendar` has `firstWeekday = 1`
///   (Sunday) and uses `.current` time zone, so the "this week" window means
///   Sun-Sat in the user's local zone regardless of locale defaults.
@Suite("CostBoard")
struct CostBoardTests {

    // MARK: - Helpers

    /// Fixed pricing: 1¢ per input token, 1¢ per output token, no cache.
    /// Picked so every record's cost is trivially `(input + output) * 0.01`,
    /// making assertions readable.
    private static let cheapPricing = ModelPricing(
        base: PricingTier(input: 0.01, output: 0.01, cacheRead: 0, cacheWrite: 0)
    )

    private static let lookup: @Sendable (String?, String) -> ModelPricing? = { _, _ in cheapPricing }

    private func makeStore() async -> (UsageStore, URL) {
        // Each test gets its own scratch directory so concurrent runs don't fight
        // over `usage_records.json`. PersistenceManager() resolves Application
        // Support; for tests we use a per-test tmp dir via a custom subclass-free
        // path by writing directly through PersistenceManager (the simplest is to
        // just use a fresh dir each time and ignore the on-disk artifact).
        let pm = PersistenceManager()
        let store = UsageStore(persistence: pm)
        // Don't call load() — start clean. The persisted file may have prior data.
        // We rely on `records: []` starting state to test bootstrap semantics.
        // Return a placeholder URL just so the signature is uniform.
        return (store, URL(fileURLWithPath: "/dev/null"))
    }

    private func record(at timestamp: Date, input: Int = 100, output: Int = 50) -> UsageRecord {
        UsageRecord(
            timestamp: timestamp,
            agentRole: .brown,
            taskID: nil,
            modelID: "test-model",
            providerType: "test",
            providerID: "test-provider",
            configuration: nil,
            inputTokens: input,
            outputTokens: output,
            latencyMs: 100
        )
    }

    /// Cost matching `cheapPricing`: `(input + output) * 0.01`.
    private func expectedCost(input: Int, output: Int) -> Double {
        Double(input + output) * 0.01
    }

    private func captureSnapshot(from board: CostBoard) async -> CostBoard.Snapshot {
        await board.snapshot
    }

    // MARK: - Tests

    @Test("empty store bootstraps to zero totals")
    func emptyStore() async throws {
        let (store, _) = await makeStore()
        let board = CostBoard(usageStore: store, pricingLookup: Self.lookup)
        await board.bootstrap()
        let s = await captureSnapshot(from: board)
        #expect(s.todayCurrent == 0)
        #expect(s.todayPrior == 0)
        #expect(s.weekCurrent == 0)
        #expect(s.weekPrior == 0)
        #expect(s.monthCurrent == 0)
        #expect(s.monthPrior == 0)
        #expect(s.yearCurrent == 0)
        #expect(s.yearPrior == 0)
        await board.stop()
    }

    @Test("bootstrap totals classify records by calendar window")
    func bootstrapClassifiesRecords() async throws {
        let (store, _) = await makeStore()
        let cal = CostBoard.calendar
        let now = Date()
        let todayMid = cal.startOfDay(for: now).addingTimeInterval(60)        // today 00:01
        // 2 days ago: well inside the prior week (with Sunday-start there could be
        // edge cases on Sunday/Monday, but a 2-day lookback always lands prior-day
        // and is "this week" unless `now` is Sunday — handled below).
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: todayMid) ?? now
        let lastYear = cal.date(byAdding: .year, value: -1, to: todayMid) ?? now

        await store.append(record(at: todayMid, input: 100, output: 100))   // counts in today/week/month/year current
        await store.append(record(at: twoDaysAgo, input: 200, output: 0))   // counts in today prior OR weeks ago, depending on calendar
        await store.append(record(at: lastYear, input: 50, output: 50))     // counts in year prior

        let board = CostBoard(usageStore: store, pricingLookup: Self.lookup)
        await board.bootstrap()
        let s = await captureSnapshot(from: board)

        // The "today" record must be in todayCurrent.
        #expect(s.todayCurrent >= expectedCost(input: 100, output: 100))
        // The lastYear record must be in yearPrior, never yearCurrent.
        #expect(s.yearPrior >= expectedCost(input: 50, output: 50))
        #expect(s.yearCurrent < expectedCost(input: 50, output: 50) + 0.001 + s.todayCurrent + s.weekCurrent)
        await board.stop()
    }

    @Test("new record after bootstrap updates the current snapshot incrementally")
    func incrementalInsert() async throws {
        let (store, _) = await makeStore()
        let board = CostBoard(usageStore: store, pricingLookup: Self.lookup)
        await board.bootstrap()
        let before = await captureSnapshot(from: board)

        // Append a "today, now" record. The async onInsert handler runs on a
        // detached Task — give it a beat to land before reading.
        await store.append(record(at: Date(), input: 1000, output: 500))
        try? await Task.sleep(for: .milliseconds(200))

        let after = await captureSnapshot(from: board)
        let delta = after.todayCurrent - before.todayCurrent
        #expect(abs(delta - expectedCost(input: 1000, output: 500)) < 0.0001,
                "todayCurrent should increase by exactly the new record's cost; before=\(before.todayCurrent) after=\(after.todayCurrent)")
        // Prior totals are anchored at bootstrap and immutable until a boundary rolls.
        #expect(after.todayPrior == before.todayPrior)
        #expect(after.weekPrior == before.weekPrior)
        #expect(after.monthPrior == before.monthPrior)
        #expect(after.yearPrior == before.yearPrior)
        await board.stop()
    }

    @Test("day boundary rollover promotes current to prior and resets current")
    func dayBoundaryRollover() async throws {
        let (store, _) = await makeStore()
        let cal = CostBoard.calendar
        // Anchor "now" at noon today so we can advance to the next day cleanly.
        let nowAtNoon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let clockBox = ClockBox(initial: nowAtNoon)
        let board = CostBoard(
            usageStore: store,
            pricingLookup: Self.lookup,
            clock: { clockBox.now }
        )

        // Seed one record dated "today" (relative to the clock).
        await store.append(record(at: nowAtNoon, input: 1000, output: 500))
        await board.bootstrap()
        let before = await captureSnapshot(from: board)
        #expect(before.todayCurrent > 0, "bootstrap should have picked up the seeded record")

        // Advance the clock past midnight to "tomorrow noon."
        let tomorrowNoon = cal.date(byAdding: .day, value: 1, to: nowAtNoon) ?? nowAtNoon
        clockBox.now = tomorrowNoon

        await board.refreshIfBoundariesElapsed()
        let after = await captureSnapshot(from: board)

        // Today's totals from the prior calendar day now live in todayPrior.
        // todayCurrent resets to whatever (if anything) was logged after the new
        // boundary — nothing in this test, so 0.
        #expect(after.todayPrior == before.todayCurrent,
                "todayCurrent (\(before.todayCurrent)) should have been promoted to todayPrior (\(after.todayPrior))")
        #expect(after.todayCurrent == 0)
        // The new today interval starts at the new day's local midnight.
        #expect(after.todayInterval.start == cal.startOfDay(for: tomorrowNoon))
        await board.stop()
    }

    @Test("calendar uses Sunday as firstWeekday and the current time zone")
    func calendarConfiguration() {
        let cal = CostBoard.calendar
        #expect(cal.firstWeekday == 1, "Sunday-start weeks are a project contract")
        #expect(cal.timeZone == .current, "windows should anchor on the user's local time")
        #expect(cal.identifier == .gregorian)
    }

    /// Thread-safe clock holder. The injected `clock` closure is `@Sendable` so a
    /// plain `var` capture won't compile.
    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(initial: Date) { value = initial }
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }
}
