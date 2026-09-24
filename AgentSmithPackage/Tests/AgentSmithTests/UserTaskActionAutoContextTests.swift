import Testing
import Foundation
@testable import AgentSmithKit

/// Regression for the 2026-09 fix: app-generated task-action notices reach Smith as typed
/// `.system` / `.userTaskAction` messages and must NOT trigger Smith's per-user-message memory
/// auto-context search; a real user message still must.
@Suite("User task-action notices and Smith auto-context")
struct UserTaskActionAutoContextTests {

    private func taskActionNotice() -> ChannelMessage {
        ChannelMessage(
            sender: .system,
            recipientID: UUID(),
            recipient: .agent(.smith),
            content: "The user paused this task.",
            metadata: ["messageKind": .kind(.userTaskAction), "userTaskAction": .userTaskAction(.paused)],
            taskID: UUID()
        )
    }

    @Test("a task-action notice reaches Smith")
    func noticeReachesSmith() {
        #expect(OrchestrationRuntime.smithAcceptsMessage(taskActionNotice()))
    }

    @Test("a task-action notice does not trigger auto-context")
    func noticeDoesNotTriggerAutoContext() {
        #expect(AgentActor.autoContextTriggerMessage(in: [taskActionNotice()]) == nil)
    }

    @Test("a real user message reaches Smith and triggers auto-context")
    func userMessageTriggersAutoContext() {
        let userMessage = ChannelMessage(sender: .user, content: "Please build the report")
        #expect(OrchestrationRuntime.smithAcceptsMessage(userMessage))
        let trigger = AgentActor.autoContextTriggerMessage(in: [userMessage, taskActionNotice()])
        #expect(trigger?.id == userMessage.id, "the notice after it must not displace the user's message")
    }

    @Test("the auto-context retrieval point still defaults to memories only")
    func autoContextDefaultsAreUnchanged() {
        let toggle = OrchestrationSettings.builtIn.retrieval.toggle(for: .smithUserMessage)
        #expect(toggle.memory)
        #expect(toggle.task == false)
        let securityToggle = OrchestrationSettings.builtIn.retrieval.toggle(for: .securityToolReview)
        #expect(securityToggle.memory)
        #expect(securityToggle.task == false)
    }

    @Test("UserTaskAction raw values are pinned — they are persisted on every notice")
    func rawValuesArePinned() {
        let expected: [UserTaskAction: String] = [
            .paused: "paused", .stopped: "stopped", .deleted: "deleted",
            .retryRequested: "retry_requested", .runAgainRequested: "run_again_requested",
            .undeleted: "undeleted",
        ]
        #expect(Set(UserTaskAction.allCases) == Set(expected.keys), "a new case must be pinned here")
        for (action, raw) in expected {
            #expect(action.rawValue == raw)
        }
    }

    @Test("orchestration scope admits task-action notices but no other task-scoped message")
    func orchestrationScopeAdmitsTaskActionNotices() {
        let filter = TranscriptFilter(taskScope: .orchestration)
        #expect(filter.matches(taskActionNotice()), "the notice must reach the conversation pane, where its inline control lives")
        let otherTaskScoped = ChannelMessage(sender: .system, content: "progress", taskID: UUID())
        #expect(filter.matches(otherTaskScoped) == false)
        #expect(filter.matches(ChannelMessage(sender: .user, content: "hi")))
        #expect(TranscriptFilter(taskScope: .matchNone).matches(taskActionNotice()) == false)
    }
}
