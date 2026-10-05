import Testing
import Foundation
@testable import AgentSmithKit

/// A worker only takes in operational notices about ITSELF.
///
/// Every public system message used to reach every live worker and wake it for an LLM turn: one
/// worker's stall warning, Smith's provider-error streak, the running-tasks digest, "Preparing
/// task". None of it was anything the receiving worker could act on. The rule is typed: a public
/// operational notice reaches a worker only when it carries that worker's task id.
@Suite("Worker message filter")
struct WorkerMessageFilterTests {

    private let ownTask = UUID()
    private let otherTask = UUID()

    private func notice(_ kind: ChannelMessageKind, taskID: UUID?, recipientID: UUID? = nil) -> ChannelMessage {
        ChannelMessage(
            sender: .system,
            recipientID: recipientID,
            content: "notice",
            metadata: ["messageKind": .kind(kind), "severity": .severity(.warning)],
            taskID: taskID
        )
    }

    @Test("another worker's or Smith's operational notices are dropped")
    func othersNoticesDropped() {
        for kind in OrchestrationRuntime.operationalNoticeKinds {
            #expect(!OrchestrationRuntime.workerAccepts(notice(kind, taskID: otherTask), workerTaskID: ownTask), "\(kind) for another task reached the worker")
            #expect(!OrchestrationRuntime.workerAccepts(notice(kind, taskID: nil), workerTaskID: ownTask), "an untasked \(kind) (Smith's, the runtime's) reached the worker")
        }
    }

    @Test("the worker's own notices still reach it")
    func ownNoticesKept() {
        for kind in OrchestrationRuntime.operationalNoticeKinds {
            #expect(OrchestrationRuntime.workerAccepts(notice(kind, taskID: ownTask), workerTaskID: ownTask), "the worker's own \(kind) was dropped")
        }
    }

    @Test("a notice addressed to the worker is never filtered as an operational notice")
    func addressedNoticeKept() {
        let message = notice(.agentLifecycle, taskID: nil, recipientID: UUID())
        #expect(OrchestrationRuntime.workerAccepts(message, workerTaskID: ownTask))
    }

    @Test("a worker with no task takes no public operational notices")
    func untaskedWorker() {
        #expect(!OrchestrationRuntime.workerAccepts(notice(.agentRecovery, taskID: ownTask), workerTaskID: nil))
    }

    @Test("other traffic is unchanged: Smith's messages pass, transcript echoes stay dropped")
    func otherTrafficUnchanged() {
        let fromSmith = ChannelMessage(sender: .agent(.smith), content: "please also check X")
        #expect(OrchestrationRuntime.workerAccepts(fromSmith, workerTaskID: ownTask))
        let echo = ChannelMessage(sender: .agent(.brown), content: "x", metadata: ["messageKind": .kind(.toolOutput)], taskID: ownTask)
        #expect(!OrchestrationRuntime.workerAccepts(echo, workerTaskID: ownTask))
    }
}
