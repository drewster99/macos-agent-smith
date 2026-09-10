import Testing
import Foundation
@testable import AgentSmithKit

/// Regression coverage for the 2026-09-09 "the timer fired and nothing happened" incident.
///
/// A `schedule_task_action(action: run)` wake fired exactly on time against a task that had been
/// marked `.failed` when its worker died. The mechanical dispatch gated on bare
/// `Status.isRunnable` (pending/paused/interrupted) and `continue`d past everything else — so the
/// run was discarded with no start, no channel row, no log line, and a delivery ledger that
/// recorded the notification as DELIVERED. Meanwhile `run_task`, which the wake's own instruction
/// text names, accepts `.failed` by resetting it. Two copies of one policy, disagreeing.
///
/// The three things pinned here are the three that failed:
///   1. `prepareForRun` is that policy, and it accepts what `run_task` accepts.
///   2. A refusal is REPORTED, not swallowed — `.refused` never settles as delivered.
///   3. `extra_instructions` survives the trip from schedule to started task.
@Suite("Scheduled-run acceptance")
struct ScheduledRunAcceptanceTests {

    // MARK: - prepareForRun: the single acceptance policy

    @Test("A failed task is reset for a retry, exactly as run_task does — the incident case")
    func failedTaskIsResetForRetry() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Find 10 products", description: "...")
        await store.updateStatus(id: task.id, status: .running)
        await store.updateStatus(id: task.id, status: .failed)

        #expect(await store.prepareForRun(id: task.id) == .ready)
        let after = try #require(await store.task(id: task.id))
        #expect(after.status == .pending, "a failed task must come back as pending, not stay failed")
    }

    @Test("A completed task is reopened in place, keeping its id")
    func completedTaskIsReopened() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Ship it", description: "...")
        await store.updateStatus(id: task.id, status: .completed)

        #expect(await store.prepareForRun(id: task.id) == .ready)
        let after = try #require(await store.task(id: task.id))
        #expect(after.status == .pending)
        #expect(after.id == task.id, "reopening must not mint a new task")
    }

    @Test("An unknown id is refused, not crashed or silently ignored")
    func unknownIDIsRefused() async {
        let store = TaskStore()
        guard case .refused = await store.prepareForRun(id: UUID()) else {
            Issue.record("an id not in the store must be refused")
            return
        }
    }

    @Test("A template passes through untouched — starting one clones an instance downstream")
    func templateIsNotResetOrReopened() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Nightly report", description: "...", isTemplate: true)
        // A template's own status must survive the call: instantiation, not in-place running,
        // is what starting a template means.
        #expect(await store.prepareForRun(id: task.id) == .ready)
        let after = try #require(await store.task(id: task.id))
        #expect(after.isTemplate)
        #expect(after.status == task.status)
    }

    /// The drift guard. `Status.canBeStarted` is a PURE predicate (`schedule_task_action` asks it
    /// to warn without mutating); `prepareForRun` is the mutating authority. Two expressions of one
    /// rule is exactly the shape that caused the incident, so they are pinned to the same answer
    /// for every status — including any status added later.
    @Test("canBeStarted agrees with prepareForRun for every status")
    func purePredicateMatchesTheMutatingAuthority() async throws {
        for status in AgentTask.Status.allCases {
            let store = TaskStore()
            let task = await store.addTask(title: "T-\(status.rawValue)", description: "...")
            // `.awaitingReview` carries a hard invariant — a parked submission always HAS a
            // submitted result — and `updateStatus` refuses the transition without one.
            if status == .awaitingReview {
                await store.setResult(id: task.id, result: "submitted work", commentary: nil)
            }
            await store.updateStatus(id: task.id, status: status)

            let prepared = await store.prepareForRun(id: task.id) == .ready
            #expect(
                prepared == status.canBeStarted,
                "status '\(status.rawValue)': canBeStarted=\(status.canBeStarted) but prepareForRun ready=\(prepared)"
            )
        }
    }

    @Test("Every runnable status is accepted without being altered")
    func runnableStatusesPassThroughUnchanged() async throws {
        for status in AgentTask.Status.allCases where status.isRunnable {
            let store = TaskStore()
            let task = await store.addTask(title: "T", description: "...")
            await store.updateStatus(id: task.id, status: status)
            #expect(await store.prepareForRun(id: task.id) == .ready)
            let after = try #require(await store.task(id: task.id))
            #expect(after.status == status, "'\(status.rawValue)' must be left alone, not normalized")
        }
    }

    // MARK: - extra_instructions survives the trip

    @Test("A run wake carries extra_instructions as structured payload, not buried in prose")
    func runNotificationCarriesExtraInstructions() throws {
        let taskID = UUID()
        let wake = ScheduledWake(
            wakeAt: Date(),
            instructions: "Call `run_task` on \(taskID.uuidString) to start the task \"X\". Use Safari only.",
            taskID: taskID,
            action: .run,
            extraInstructions: "Use Safari only."
        )
        let notification = WakeNotificationFactory.notification(for: wake)
        #expect(notification.payload.type == "task_action")
        #expect(notification.payload.data["extra_instructions"] == .string("Use Safari only."))
    }

    @Test("A run wake with no refinements omits the field rather than sending an empty one")
    func runNotificationOmitsAbsentExtraInstructions() {
        let wake = ScheduledWake(wakeAt: Date(), instructions: "Call `run_task` …", taskID: UUID(), action: .run)
        let notification = WakeNotificationFactory.notification(for: wake)
        #expect(notification.payload.data["extra_instructions"] == nil)
    }

    @Test("extraInstructions round-trips, and a wake persisted before the field decodes to nil")
    func extraInstructionsCoding() throws {
        let wake = ScheduledWake(
            wakeAt: Date(timeIntervalSince1970: 1_700_000_000),
            instructions: "Call `run_task` …",
            taskID: UUID(),
            survivesTaskTermination: true,
            action: .run,
            extraInstructions: "Wait for the Mac to be idle."
        )
        let round = try JSONDecoder().decode(ScheduledWake.self, from: JSONEncoder().encode(wake))
        #expect(round.extraInstructions == "Wait for the Mac to be idle.")
        #expect(round.action == .run)

        // The field is additive: an older record simply has no key for it.
        let legacy = """
            {"id":"\(UUID().uuidString)","wakeAt":700000000,"instructions":"Call `run_task` on x",
             "structuredDispatch":true,"action":"run"}
            """
        let decoded = try JSONDecoder().decode(ScheduledWake.self, from: Data(legacy.utf8))
        #expect(decoded.extraInstructions == nil)
        #expect(decoded.action == .run)
    }

    // MARK: - The durable queue entry

    @Test("The queue decodes its pre-amendment bare-UUID form as well as the object form")
    func pendingScheduledRunDecodesLegacyAndCurrent() throws {
        let a = UUID(), b = UUID()
        // What every queue file written before the amendment existed looks like.
        let legacy = "[\"\(a.uuidString)\"]"
        let decodedLegacy = try JSONDecoder().decode([PendingScheduledRun].self, from: Data(legacy.utf8))
        #expect(decodedLegacy == [PendingScheduledRun(taskID: a, amendment: nil)])

        let current = [
            PendingScheduledRun(taskID: a, amendment: "Safari only"),
            PendingScheduledRun(taskID: b, amendment: nil)
        ]
        let round = try JSONDecoder().decode(
            [PendingScheduledRun].self,
            from: JSONEncoder().encode(current)
        )
        #expect(round == current)
    }

    // MARK: - Library-resident templates

    /// The trap this fix nearly walked into. `schedule_task_action` PROMOTES its task to a template
    /// whenever the schedule is recurring, and promotion MOVES the task out of the per-session store
    /// into the global library. So `TaskStore.task(id:)` — the lookup both start paths used — returns
    /// nil for exactly the target a recurring run creates, and `prepareForRun` (per-session by
    /// nature) reports `.refused` for a template that runs perfectly well.
    ///
    /// The contract this pins: resolve with `taskOrLibraryTemplate` and skip `prepareForRun` for a
    /// template. If someone "simplifies" a call site back to the per-session lookup, or drops the
    /// `isTemplate` gate, this fails.
    @Test("A promoted template leaves the session store, and prepareForRun cannot see it")
    func libraryTemplateIsInvisibleToPerSessionPrepare() async throws {
        let library = TemplateLibraryStore()
        let store = TaskStore(templateLibrary: library, templateLibraryPersistable: false)
        let task = await store.addTask(title: "Nightly report", description: "...")

        // Exactly what a recurring schedule_task_action does to its target.
        #expect(await store.setTemplate(id: task.id, isTemplate: true) == nil)

        #expect(
            await store.task(id: task.id) == nil,
            "promotion moves the task to the global library — the per-session lookup must miss it"
        )
        let resolved = try #require(
            await store.taskOrLibraryTemplate(id: task.id),
            "the library-aware lookup is the one both start paths must use"
        )
        #expect(resolved.isTemplate)

        // And this is why the isTemplate gate lives at the CALL SITE: asked directly, the
        // per-session method can only answer "not here".
        guard case .refused = await store.prepareForRun(id: task.id) else {
            Issue.record("prepareForRun cannot see a library template; a caller must gate on isTemplate first")
            return
        }
    }

    // MARK: - Rescheduling preserves the whole wake

    /// A reschedule changes WHEN and how often. Everything else must survive it.
    ///
    /// `RescheduleWakeTool` used to rebuild the request field by field, which drops any field the
    /// call site hasn't been taught about — `extraInstructions` was lost that way on the day it was
    /// added, so a rescheduled run silently shed its refinements while reporting success. The
    /// preserving initializer is what makes that structurally impossible; this pins it.
    @Test("Rescheduling a wake preserves action, extraInstructions, and survival")
    func rescheduleCopiesTheWholeWake() {
        let taskID = UUID()
        let existing = ScheduledWake(
            wakeAt: Date(timeIntervalSince1970: 1_000),
            instructions: "Call `run_task` on \(taskID.uuidString) to start the task \"X\". Safari only.",
            taskID: taskID,
            recurrence: nil,
            survivesTaskTermination: true,
            action: .run,
            extraInstructions: "Safari only."
        )
        let later = Date(timeIntervalSince1970: 9_000)
        let request = WakeRequest(replacing: existing, wakeAt: later, recurrence: nil)

        #expect(request.wakeAt == later, "the reschedule's whole job")
        #expect(request.replacesID == existing.id)
        #expect(request.action == .run)
        #expect(request.extraInstructions == "Safari only.")
        #expect(request.survivesTaskTermination)
        #expect(request.taskID == taskID)
        #expect(request.instructions == existing.instructions)
    }
}
