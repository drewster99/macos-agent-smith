import Foundation
import Testing
@testable import AgentSmithKit

/// The task rows' "Next:" chip reads this index (#23). It covers every open session, because a
/// library template — where a recurring schedule lives — is listed in every window.
@Suite("Pending wake index")
struct PendingWakeIndexTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("reminders and wakes already past are left out; each task's wakes are soonest first")
    func filtersAndSorts() {
        let task = UUID(), session = UUID()
        let later = ScheduledWake(wakeAt: now.addingTimeInterval(600), instructions: "run", taskID: task)
        let sooner = ScheduledWake(wakeAt: now.addingTimeInterval(60), instructions: "run", taskID: task)
        let past = ScheduledWake(wakeAt: now.addingTimeInterval(-60), instructions: "run", taskID: task)
        let reminder = ScheduledWake(wakeAt: now.addingTimeInterval(60), instructions: "remind")

        let index = PendingWakeIndex.build([session: [later, past, reminder, sooner]], now: now)

        #expect(Array(index.keys) == [task])
        #expect(index[task]?.map(\.wake.id) == [sooner.id, later.id])
        #expect(index[task]?.allSatisfy { $0.sessionID == session } == true)
    }

    @Test("a template's wakes from two sessions merge under the template, each keeping its owner")
    func mergesSessions() {
        let template = UUID(), sessionA = UUID(), sessionB = UUID()
        let fromA = ScheduledWake(wakeAt: now.addingTimeInterval(300), instructions: "run", taskID: template)
        let fromB = ScheduledWake(wakeAt: now.addingTimeInterval(120), instructions: "run", taskID: template)

        let index = PendingWakeIndex.build([sessionA: [fromA], sessionB: [fromB]], now: now)

        #expect(index[template]?.map(\.wake.id) == [fromB.id, fromA.id])
        #expect(index[template]?.map(\.sessionID) == [sessionB, sessionA])
    }

    @Test("no sessions, or only past wakes, is an empty index")
    func empty() {
        #expect(PendingWakeIndex.build([:], now: now).isEmpty)
        let past = ScheduledWake(wakeAt: now, instructions: "run", taskID: UUID())
        #expect(PendingWakeIndex.build([UUID(): [past]], now: now).isEmpty, "a wake due exactly now is no longer pending")
    }
}
