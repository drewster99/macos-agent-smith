import Testing
import Foundation
@testable import AgentSmithKit

/// The send-during-restart recovery decision: `OrchestrationRuntime.lostMessageToRecover`. A user
/// message can reach the transcript (UI echo) but not the pending buffer if the app restarts between
/// the two writes. Recovery re-enqueues it ONLY when it was genuinely lost — never when it was
/// already processed or is already queued.
@Suite("Lost-message recovery decision")
struct LostMessageRecoveryTests {

    private func userMessage(_ text: String, pendingID: UUID, at date: Date = Date(timeIntervalSince1970: 100)) -> ChannelMessage {
        ChannelMessage(
            timestamp: date,
            sender: .user,
            content: text,
            metadata: [
                "bufferOrigin": .bool(true),
                "pendingUserMessageID": .string(pendingID.uuidString)
            ]
        )
    }

    @Test("trailing undelivered user message → recovered")
    func recoversLostMessage() {
        let pid = UUID()
        let tail = [
            ChannelMessage(sender: .agent(.smith), content: "earlier reply"),
            userMessage("inventory my repos", pendingID: pid)
        ]
        let recovered = OrchestrationRuntime.lostMessageToRecover(recentTail: tail, alreadyQueuedIDs: [])
        #expect(recovered?.id == pid)
        #expect(recovered?.text == "inventory my repos")
    }

    @Test("an agent reply AFTER the user message → already handled, not recovered")
    func notRecoveredWhenAnswered() {
        let tail = [
            userMessage("do the thing", pendingID: UUID()),
            ChannelMessage(sender: .agent(.smith), content: "on it")
        ]
        #expect(OrchestrationRuntime.lostMessageToRecover(recentTail: tail, alreadyQueuedIDs: []) == nil)
    }

    @Test("already queued for delivery (in pending buffer) → not recovered")
    func notRecoveredWhenAlreadyQueued() {
        let pid = UUID()
        let tail = [userMessage("queued already", pendingID: pid)]
        #expect(OrchestrationRuntime.lostMessageToRecover(recentTail: tail, alreadyQueuedIDs: [pid]) == nil)
    }

    @Test("trailing system/chrome rows after the user message are ignored")
    func ignoresTrailingChrome() {
        let pid = UUID()
        let tail = [
            userMessage("still unanswered", pendingID: pid),
            ChannelMessage(sender: .system, content: "System online. Smith agent active.",
                           metadata: ["messageKind": .string("restart_chrome")])
        ]
        let recovered = OrchestrationRuntime.lostMessageToRecover(recentTail: tail, alreadyQueuedIDs: [])
        #expect(recovered?.id == pid)
    }

    @Test("no user message at all → nothing to recover")
    func noUserMessage() {
        let tail = [ChannelMessage(sender: .agent(.smith), content: "hello")]
        #expect(OrchestrationRuntime.lostMessageToRecover(recentTail: tail, alreadyQueuedIDs: []) == nil)
    }

    @Test("a user message without a pendingUserMessageID is not recoverable")
    func userMessageWithoutPendingID() {
        let tail = [ChannelMessage(sender: .user, content: "legacy message with no marker")]
        #expect(OrchestrationRuntime.lostMessageToRecover(recentTail: tail, alreadyQueuedIDs: []) == nil)
    }
}
