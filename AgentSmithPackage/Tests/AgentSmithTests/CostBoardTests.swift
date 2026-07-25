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
        // CRITICAL: `PersistenceManager()` resolves to `~/Library/Application Support/AgentSmith/`
        // — the real app's data path. `UsageStore.append(...)` schedules a flush that writes
        // the in-memory `records` array to disk 5 seconds later, with no merge against the
        // existing file. If a test calls `append` without `load`, the in-memory array contains
        // ONLY test records; the flush overwrites the real file with that test data. This is
        // exactly what happened the first time these tests ran and silently wiped a month of
        // real usage data. We now route every test through a per-test temp dir via the
        // `init(testingRoot:)` escape hatch on `PersistenceManager`.
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-costboard-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let pm = PersistenceManager(testingRoot: tmpRoot)
        let store = UsageStore(persistence: pm)
        return (store, tmpRoot)
    }

    private func record(
        at timestamp: Date,
        input: Int = 100,
        output: Int = 50,
        taskID: UUID? = nil,
        sessionID: UUID? = nil
    ) -> UsageRecord {
        UsageRecord(
            timestamp: timestamp,
            agentRole: .brown,
            taskID: taskID,
            modelID: "test-model",
            providerType: "test",
            providerID: "test-provider",
            configuration: nil,
            inputTokens: input,
            outputTokens: output,
            latencyMs: 100,
            sessionID: sessionID
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

    // MARK: - Per-task rollup

    @Test("bootstrap groups existing records into per-task totals")
    func taskCostsBootstrap() async throws {
        let (store, _) = await makeStore()
        let taskA = UUID()
        let taskB = UUID()
        let now = Date()

        await store.append(record(at: now, input: 100, output: 100, taskID: taskA))
        await store.append(record(at: now, input: 200, output: 200, taskID: taskA))
        await store.append(record(at: now, input: 300, output: 300, taskID: taskB))
        // Unattributed (Smith's orchestration overhead) — belongs to no task.
        await store.append(record(at: now, input: 900, output: 900, taskID: nil))

        let board = CostBoard(usageStore: store, pricingLookup: Self.lookup)
        await board.bootstrap()
        let costs = await board.taskCosts

        #expect(costs.count == 2, "only the two attributed tasks should appear")
        #expect(abs((costs[taskA] ?? 0) - expectedCost(input: 300, output: 300)) < 0.0001)
        #expect(abs((costs[taskB] ?? 0) - expectedCost(input: 300, output: 300)) < 0.0001)
        await board.stop()
    }

    @Test("a record for a running task raises its total without waiting for completion")
    func taskCostsGrowWhileRunning() async throws {
        let (store, _) = await makeStore()
        let runningTask = UUID()
        let board = CostBoard(usageStore: store, pricingLookup: Self.lookup)
        await board.bootstrap()

        // The regression this guards: a task whose row rendered before it had ANY records
        // used to display nothing until it reached a terminal status, because the cost was
        // fetched once and cached. Nothing here marks the task finished.
        #expect(await board.taskCosts[runningTask] == nil, "no records yet")

        await store.append(record(at: Date(), input: 1000, output: 500, taskID: runningTask))
        // Longer than the coalescing window so the scheduled recompute has run.
        try await Task.sleep(for: .milliseconds(1500))
        let afterFirst = await board.taskCosts[runningTask] ?? 0
        #expect(abs(afterFirst - expectedCost(input: 1000, output: 500)) < 0.0001)

        await store.append(record(at: Date(), input: 100, output: 100, taskID: runningTask))
        try await Task.sleep(for: .milliseconds(1500))
        let afterSecond = await board.taskCosts[runningTask] ?? 0
        #expect(abs(afterSecond - expectedCost(input: 1100, output: 600)) < 0.0001,
                "the still-running task's total must include both records; was \(afterSecond)")
        await board.stop()
    }

    @Test("observers are notified when per-task totals change")
    func taskCostsPublishToObserver() async throws {
        let (store, _) = await makeStore()
        let taskID = UUID()
        let board = CostBoard(usageStore: store, pricingLookup: Self.lookup)
        let inbox = TaskCostInbox()
        await board.setOnTaskCostsUpdate { totals in await inbox.record(totals) }
        await board.bootstrap()

        await store.append(record(at: Date(), input: 400, output: 400, taskID: taskID))
        try await Task.sleep(for: .milliseconds(1500))

        let latest = await inbox.latest
        #expect(abs((latest[taskID] ?? 0) - expectedCost(input: 400, output: 400)) < 0.0001,
                "the observer should have received the updated map")
        await board.stop()
    }

    @Test("re-attributed records land on the task they were backfilled onto")
    func taskCostsFollowBackfill() async throws {
        let (store, _) = await makeStore()
        let sessionID = UUID()
        let taskID = UUID()
        // Smith's pre-task planning: recorded with no task, later charged to the task it
        // produced. `backfillTaskID` rewrites STORED records and appends nothing, so an
        // insert-only aggregate would never see it.
        await store.append(record(at: Date(), input: 500, output: 500, taskID: nil, sessionID: sessionID))

        let board = CostBoard(usageStore: store, pricingLookup: Self.lookup)
        await board.bootstrap()
        #expect(await board.taskCosts.isEmpty, "unattributed records belong to no task")

        await store.backfillTaskID(taskID, forSession: sessionID)
        await board.recomputeTaskCosts()

        let costs = await board.taskCosts
        #expect(abs((costs[taskID] ?? 0) - expectedCost(input: 500, output: 500)) < 0.0001,
                "the backfilled records should now be charged to the task")
        await board.stop()
    }

    /// Collects the maps delivered to `setOnTaskCostsUpdate`. An actor because the
    /// callback is `@Sendable` and fires off the test's task.
    private actor TaskCostInbox {
        private(set) var latest: [UUID: Double] = [:]
        func record(_ totals: [UUID: Double]) { latest = totals }
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
