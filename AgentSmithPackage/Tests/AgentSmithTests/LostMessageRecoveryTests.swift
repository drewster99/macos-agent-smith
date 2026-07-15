import Testing
import Foundation
@testable import AgentSmithKit

/// The send-during-restart recovery decision: `OrchestrationRuntime.lostMessageToRecover`. A user
/// message can reach the transcript (UI echo) but not the pending buffer if the app restarts between
/// the two writes. Recovery re-enqueues it ONLY when it was genuinely lost — never when it was
/// already handled (an incorporated tombstone) or is still queued.
///
/// `knownMessageIDs` is the set of `pendingUserMessageID`s the runtime already knows about — both
/// still-queued messages AND incorporated tombstones. "Handled" is determined by that set, NOT by the
/// presence of a later agent message: a Brown message about an unrelated task is not an
/// acknowledgement of this user message.
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
        let recovered = OrchestrationRuntime.lostMessageToRecover(recentTail: tail, knownMessageIDs: [])
        #expect(recovered?.id == pid)
        #expect(recovered?.text == "inventory my repos")
    }

    @Test("known id (queued or incorporated tombstone) → handled, not recovered")
    func notRecoveredWhenKnown() {
        let pid = UUID()
        let tail = [userMessage("already handled or queued", pendingID: pid)]
        #expect(OrchestrationRuntime.lostMessageToRecover(recentTail: tail, knownMessageIDs: [pid]) == nil)
    }

    /// Regression for the SILENT-LOSS bug: recovery must search user echoes independently, so an
    /// unrelated Brown message posted after the user echo doesn't mask a genuinely-lost message.
    @Test("unrelated agent traffic after the echo does NOT mask a lost message → recovered")
    func unrelatedAgentTrafficDoesNotMaskLostMessage() {
        let pid = UUID()
        let tail = [
            userMessage("scan my repos", pendingID: pid),
            ChannelMessage(sender: .agent(.brown), content: "Working on a different task…")
        ]
        let recovered = OrchestrationRuntime.lostMessageToRecover(recentTail: tail, knownMessageIDs: [])
        #expect(recovered?.id == pid)
    }

    /// Regression for the DUPLICATE-REDELIVERY bug: an incorporated message (its id is a known
    /// tombstone) is never recovered, even when its response hasn't flushed and unrelated agent
    /// traffic follows the echo.
    @Test("incorporated message (known tombstone) is not re-delivered despite trailing traffic")
    func incorporatedMessageNotReDelivered() {
        let pid = UUID()
        let tail = [
            userMessage("create the task", pendingID: pid),
            ChannelMessage(sender: .agent(.brown), content: "unrelated progress")
        ]
        #expect(OrchestrationRuntime.lostMessageToRecover(recentTail: tail, knownMessageIDs: [pid]) == nil)
    }

    @Test("the most-recent unknown user echo is the one recovered")
    func recoversMostRecentUnknown() {
        let older = UUID()
        let newer = UUID()
        let tail = [
            userMessage("older, already handled", pendingID: older, at: Date(timeIntervalSince1970: 100)),
            userMessage("newer, lost", pendingID: newer, at: Date(timeIntervalSince1970: 200))
        ]
        let recovered = OrchestrationRuntime.lostMessageToRecover(recentTail: tail, knownMessageIDs: [older])
        #expect(recovered?.id == newer)
    }

    @Test("trailing system/chrome rows after the user message are ignored")
    func ignoresTrailingChrome() {
        let pid = UUID()
        let tail = [
            userMessage("still unanswered", pendingID: pid),
            ChannelMessage(sender: .system, content: "System online. Smith agent active.",
                           metadata: ["messageKind": .string("restart_chrome")])
        ]
        let recovered = OrchestrationRuntime.lostMessageToRecover(recentTail: tail, knownMessageIDs: [])
        #expect(recovered?.id == pid)
    }

    @Test("no user message at all → nothing to recover")
    func noUserMessage() {
        let tail = [ChannelMessage(sender: .agent(.smith), content: "hello")]
        #expect(OrchestrationRuntime.lostMessageToRecover(recentTail: tail, knownMessageIDs: []) == nil)
    }

    @Test("a user message without a pendingUserMessageID is not recoverable")
    func userMessageWithoutPendingID() {
        let tail = [ChannelMessage(sender: .user, content: "legacy message with no marker")]
        #expect(OrchestrationRuntime.lostMessageToRecover(recentTail: tail, knownMessageIDs: []) == nil)
    }
}
