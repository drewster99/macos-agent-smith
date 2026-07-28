import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// Smith addresses a worker by task, but the worker's existence is a race Smith cannot observe:
/// `create_task` and `run_task` both return before the worker is spawned. A message sent in that
/// window used to fail outright, and the suggested remedy — "use `amend_task` instead" — asked
/// Smith to notice a scheduling detail it has no visibility into and pick a different tool for it.
///
/// The message is queued on the task instead and handed over in the worker's briefing.
@Suite("Queued worker messages")
struct QueuedWorkerMessageTests {

    @Test("A message queued for a task survives on the task")
    func enqueueStores() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let ok = await store.enqueueWorkerMessage(taskID: task.id, message: QueuedWorkerMessage(text: "do the thing"))
        #expect(ok)
        let stored = await store.task(id: task.id)?.pendingWorkerMessages
        #expect(stored?.count == 1)
        #expect(stored?.first?.text == "do the thing")
    }

    @Test("Queuing for a task that doesn't exist reports failure rather than silently dropping")
    func enqueueUnknownTaskFails() async {
        let store = TaskStore()
        #expect(await !store.enqueueWorkerMessage(taskID: UUID(), message: QueuedWorkerMessage(text: "x")))
    }

    @Test("Draining returns the messages AND clears them, so delivery happens once")
    func drainIsReadAndClear() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        await store.enqueueWorkerMessage(taskID: task.id, message: QueuedWorkerMessage(text: "first"))
        await store.enqueueWorkerMessage(taskID: task.id, message: QueuedWorkerMessage(text: "second"))

        let drained = await store.takePendingWorkerMessages(taskID: task.id)
        #expect(drained.map(\.text) == ["first", "second"], "order preserved — instructions are sequential")

        // The second drain must be empty. If it weren't, a restart would re-deliver instructions
        // the worker already acted on, which reads to the worker as a fresh request.
        #expect(await store.takePendingWorkerMessages(taskID: task.id).isEmpty)
        #expect(await store.task(id: task.id)?.pendingWorkerMessages.isEmpty == true)
    }

    @Test("Queued messages accumulate in order across several sends")
    func multipleSendsAccumulate() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        for i in 1...5 {
            await store.enqueueWorkerMessage(taskID: task.id, message: QueuedWorkerMessage(text: "m\(i)"))
        }
        let drained = await store.takePendingWorkerMessages(taskID: task.id)
        #expect(drained.map(\.text) == ["m1", "m2", "m3", "m4", "m5"])
    }

    @Test("Queued messages round-trip through Codable, and old JSON without the field still decodes")
    func codableAndBackwardCompatible() throws {
        var task = AgentTask(title: "t", description: "d")
        task.pendingWorkerMessages = [QueuedWorkerMessage(text: "queued")]
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(AgentTask.self, from: data)
        #expect(decoded.pendingWorkerMessages.map(\.text) == ["queued"])

        // Every task already on disk predates this field. Decoding must default it, not throw —
        // otherwise adding the queue would make the existing task store unreadable.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "pendingWorkerMessages")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let fromLegacy = try JSONDecoder().decode(AgentTask.self, from: legacy)
        #expect(fromLegacy.pendingWorkerMessages.isEmpty)
    }

    @Test("message_brown stays available with no live worker, because the call now queues")
    func toolRemainsAvailableWithoutLiveWorker() {
        // The opposite gate was considered and rejected: hiding the tool when no worker is alive
        // removes it at exactly the moment Smith most expects it — right after create_task.
        let context = ToolAvailabilityContext(agentRole: .smith, hasAwaitingReviewTasks: false)
        #expect(MessageBrownTool().isAvailable(in: context))
    }

    @Test("message_brown is still withheld while a worker is blocked on request_help")
    func withheldWhileAwaitingHelp() {
        let blocked = ToolAvailabilityContext(agentRole: .smith, hasAwaitingReviewTasks: true)
        #expect(!MessageBrownTool().isAvailable(in: blocked))
        #expect(ProvideHelpTool().isAvailable(in: blocked))
    }

    @Test("A queued message keeps its attachments, so they can be delivered with it")
    func attachmentsSurviveTheQueue() async {
        // message_brown accepts attachment_ids. Storing the text but dropping the files would
        // accept an attachment at the call site and lose it somewhere the sender never sees.
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let attachment = Attachment(filename: "evidence.png", mimeType: "image/png", byteCount: 1, data: Data([0x1]))
        await store.enqueueWorkerMessage(
            taskID: task.id,
            message: QueuedWorkerMessage(text: "see the screenshot", attachments: [attachment])
        )
        let drained = await store.takePendingWorkerMessages(taskID: task.id)
        #expect(drained.first?.attachments.map(\.filename) == ["evidence.png"])
    }
}

/// How a message from Smith is presented to a worker.
@Suite("Orchestrator message envelope")
struct OrchestratorMessageEnvelopeTests {

    @Test("The envelope names the sender's role and the one channel back")
    func envelopeContent() {
        let wrapped = AgentActor.orchestratorMessageEnvelope("Please reply with 'Hello'")
        #expect(wrapped.contains("AGENT SMITH"))
        #expect(wrapped.contains("TASK ORCHESTRATOR"))
        #expect(wrapped.contains("request_help"))
        #expect(wrapped.hasSuffix("Please reply with 'Hello'"), "the body must come last, intact")
    }

    @Test("It does not use the generic transcript label")
    func notTheGenericLabel() {
        // `[AGENT Smith]: …` is what every other channel line looks like. A directed message from
        // the orchestrator reading identically to ambient transcript is the whole defect.
        #expect(!AgentActor.orchestratorMessageEnvelope("x").contains("[AGENT Smith]"))
    }

    @Test("message_brown tags its post so the formatter can recognise it")
    func messageBrownIsTagged() {
        // The formatter keys on the KIND, not on the sender or the text — a worker gets the
        // envelope because the message is an orchestrator message, not because of who sent it.
        let tagged = ChannelMessage(
            sender: .agent(.smith),
            recipientID: UUID(),
            recipient: .agent(.brown),
            content: "do the thing",
            metadata: ["messageKind": .kind(.orchestratorMessage)]
        )
        #expect(tagged.kind == .orchestratorMessage)

        // A help ANSWER is a different kind and must NOT get the "if you need help" framing.
        let help = ChannelMessage(
            sender: .agent(.smith),
            recipientID: UUID(),
            recipient: .agent(.brown),
            content: "here is the answer",
            metadata: ["messageKind": .kind(.helpProvided)]
        )
        #expect(help.kind != .orchestratorMessage)
    }
}
