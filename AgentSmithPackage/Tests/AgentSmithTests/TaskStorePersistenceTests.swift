import Testing
import Foundation
@testable import AgentSmithKit

/// The store is the single writer of its session's `tasks.json` and can say whether a given
/// mutation is on disk.
@Suite("TaskStore persistence")
struct TaskStorePersistenceTests {

    private actor Disk {
        private(set) var writes: [[AgentTask]] = []
        var failing = false
        func setFailing(_ value: Bool) { failing = value }
        func save(_ snapshot: [AgentTask]) throws {
            if failing { throw CocoaError(.fileWriteNoPermission) }
            writes.append(snapshot)
        }
        var last: [AgentTask]? { writes.last }
    }

    @Test("Every mutation reaches disk, and the latest state wins")
    func mutationsArePersisted() async {
        let disk = Disk()
        let store = TaskStore()
        await store.attachPersistence(save: { try await disk.save($0) }, writeNow: false)
        let task = await store.addTask(title: "A", description: "d")
        await store.updateStatus(id: task.id, status: .running)
        #expect(await store.awaitDurable(through: store.currentMutationSeq))
        #expect(await disk.last?.first?.status == .running)
    }

    @Test("A failed write is reported as not durable; a later success covers it")
    func failureIsNotDurable() async {
        let disk = Disk()
        let store = TaskStore()
        await store.attachPersistence(save: { try await disk.save($0) }, writeNow: false)
        await disk.setFailing(true)
        _ = await store.addTask(title: "A", description: "d")
        let failedSeq = await store.currentMutationSeq
        #expect(await store.awaitDurable(through: failedSeq) == false)
        await disk.setFailing(false)
        #expect(await store.persistDurablyNow())
        #expect(await store.awaitDurable(through: failedSeq), "a later complete snapshot covers the earlier seq")
    }

    @Test("writeNow: false leaves the file alone until the first mutation")
    func attachWithoutWrite() async {
        let disk = Disk()
        let store = TaskStore()
        await store.restore([AgentTask(title: "restored", description: "d")])
        await store.attachPersistence(save: { try await disk.save($0) }, writeNow: false)
        _ = await store.persistDurablyNow()   // an explicit request still writes
        #expect(await disk.writes.count == 1)
    }

    @Test("writeNow: true writes the current state at once")
    func attachWithWrite() async {
        let disk = Disk()
        let store = TaskStore()
        await store.restore([AgentTask(title: "restored", description: "d")])
        await store.attachPersistence(save: { try await disk.save($0) }, writeNow: true)
        #expect(await store.awaitDurable(through: store.currentMutationSeq))
        #expect(await disk.last?.map(\.title) == ["restored"])
    }

    @Test("A retired store never writes again and reports nothing durable")
    func retiredStoreIsSilent() async {
        let disk = Disk()
        let store = TaskStore()
        await store.attachPersistence(save: { try await disk.save($0) }, writeNow: false)
        _ = await store.addTask(title: "A", description: "d")
        await store.retirePersistence()
        let writesAtRetirement = await disk.writes.count
        _ = await store.addTask(title: "B", description: "d")
        #expect(await store.persistDurablyNow() == false)
        #expect(await disk.writes.count == writesAtRetirement)
    }

    @Test("Retiring waits for the in-flight write to land first")
    func retireWaitsForInFlightWrite() async {
        let disk = Disk()
        let store = TaskStore()
        await store.attachPersistence(save: { snapshot in
            try await Task.sleep(for: .milliseconds(30))
            try await disk.save(snapshot)
        }, writeNow: false)
        _ = await store.addTask(title: "A", description: "d")
        await store.retirePersistence()
        #expect(await disk.last?.map(\.title) == ["A"])
    }

    @Test("A memory-only store treats every mutation as durable")
    func memoryOnlyIsDurable() async {
        let store = TaskStore()
        _ = await store.addTask(title: "A", description: "d")
        #expect(await store.awaitDurable(through: store.currentMutationSeq))
        #expect(await store.persistDurablyNow())
    }
}
