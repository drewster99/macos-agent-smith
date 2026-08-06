import Testing
import Foundation
@testable import AgentSmithKit

/// The bottom-pane filter model: every kind is grouped exactly once (so a new kind can't vanish from
/// the popover), and a config renders to the filter it claims.
@Suite struct TranscriptViewConfigTests {

    /// COMPLETENESS GUARD. Every `ChannelMessageKind` must belong to exactly one non-chat group.
    /// `chat` covers kindless messages and contributes no kinds, so the union of the other groups must
    /// equal `allCases`. A newly-added kind that nobody grouped fails here — it would otherwise be
    /// silently untoggleable in the popover (and, depending on the default, invisible or unfilterable).
    @Test func everyKindBelongsToExactlyOneGroup() {
        var seen: [ChannelMessageKind: [TranscriptKindGroup]] = [:]
        for group in TranscriptKindGroup.allCases {
            for kind in group.kinds {
                seen[kind, default: []].append(group)
            }
        }
        // No kind in two groups.
        let doubled = seen.filter { $0.value.count > 1 }
        #expect(doubled.isEmpty, "Kinds in more than one group: \(doubled)")
        // Every kind covered.
        let covered = Set(seen.keys)
        let all = Set(ChannelMessageKind.allCases)
        #expect(covered == all, "Ungrouped kinds: \(all.subtracting(covered))")
        // Chat contributes nothing.
        #expect(TranscriptKindGroup.chat.kinds.isEmpty)
        #expect(TranscriptKindGroup.chat.governsKindless)
    }

    @Test func everythingConfigIsTheFirehose() {
        let filter = TranscriptViewConfig.everything.makeFilter()
        #expect(filter == TranscriptFilter.all)
        if case .all = filter.kinds { } else { Issue.record("expected .all kind rule") }
    }

    @Test func conversationDefaultIsOrchestrationWithoutBrown() {
        let filter = TranscriptViewConfig.conversation.makeFilter()
        // Every kind group is on — the default's work is done by the scope + recipient axes, not kinds.
        #expect(filter.kinds == .all)
        // Nothing scoped to a task: only the Smith↔user orchestration layer.
        #expect(filter.taskScope == .orchestration)
        // Nothing FROM Brown.
        #expect(filter.allowedSenders?.contains(.agent(.brown)) == false)
        #expect(filter.allowedSenders?.contains(.agent(.smith)) == true)
        #expect(filter.allowedSenders?.contains(.user) == true)
        // Nothing TO Brown (a Security-Agent→Brown message is dropped by the recipient axis).
        #expect(filter.allowedRecipients?.contains(.agent(.brown)) == false)
        #expect(filter.allowedRecipients?.contains(.agent(.smith)) == true)
        // Errors still show by default.
        #expect(filter.hideErrors == false)
    }

    /// A REAL Security-review message about a Brown tool call is posted `sender: .system`, PUBLIC (no
    /// recipient), with `taskID` stamped to the worker's task (see `AgentActor.postSecurityReviewToChannel`
    /// + `ToolContext.post`). In the `.conversation` default it is therefore dropped by the TASK-SCOPE
    /// axis, not the recipient axis — this asserts the shape the code actually produces.
    @Test func conversationDropsRealSecurityReviewViaTaskScope() {
        let filter = TranscriptViewConfig.conversation.makeFilter()
        let securityReview = ChannelMessage(
            sender: .system,
            content: "Security Agent → Brown: SAFE Internal task management metadata update",
            taskID: UUID()
        )
        #expect(!filter.matches(securityReview))
        // Prove it's the task-scope axis doing the work: the same message with no task shows.
        let orchestrationScoped = ChannelMessage(
            sender: .system,
            content: "Security Agent → Brown: SAFE Internal task management metadata update"
        )
        #expect(filter.matches(orchestrationScoped))
    }

    /// The recipient axis is what drops a PRIVATE message ADDRESSED to a worker (e.g. `notify_brown`,
    /// validation punch-lists) — the case the sender axis can't catch when it's sent by an allowed
    /// sender. Exercised directly so it isn't conflated with the task-scope axis.
    @Test func recipientAxisDropsMessagesAddressedToExcludedAgent() {
        let filter = TranscriptFilter(allowedRecipients: [.user, .agent(.smith)])
        let toBrown = ChannelMessage(
            sender: .agent(.smith),
            recipientID: UUID(),
            recipient: .agent(.brown),
            content: "New guidance for your task"
        )
        #expect(!filter.matches(toBrown))
        // A public message (no recipient) always passes the recipient axis.
        let publicMessage = ChannelMessage(sender: .agent(.brown), content: "Working on it")
        #expect(filter.matches(publicMessage))
    }

    @Test func taskScopeThreadsThrough() {
        let id = UUID()
        let filter = TranscriptViewConfig.conversation.makeFilter(taskScope: .task(id))
        #expect(filter.taskScope == .task(id))
    }

    @Test func senderAllowListNarrows() {
        var config = TranscriptViewConfig.everything
        config.allowedSenders = [.user, .agent(.smith)]
        let filter = config.makeFilter()
        #expect(filter.allowedSenders == [.user, .agent(.smith)])
    }

    @Test func configRoundTripsThroughJSON() throws {
        let config = TranscriptViewConfig(
            visibleGroups: [.chat, .validation],
            allowedSenders: [.user, .agent(.brown), .validator],
            allowedRecipients: [.user, .agent(.smith)],
            visibility: .publicOnly,
            hideTaskScoped: true,
            showErrors: false
        )
        let back = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: JSONEncoder().encode(config))
        #expect(back == config)
    }

    /// A config persisted BEFORE the recipient/task-scope/error axes existed must still decode — the new
    /// fields fall back to their inits (nil recipients, task-scoped shown, errors shown). Group
    /// visibility comes from the legacy `visibleGroups` key; `securityReviews` inherits Chat's state
    /// because security-review rows were kindless when this config was written, so Chat is the toggle
    /// that actually governed them — the migrated config shows exactly what the original did.
    @Test func legacyConfigWithoutNewAxesDecodes() throws {
        let legacyJSON = """
        {"visibleGroups":["chat","system"],"visibility":"all"}
        """
        let back = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: Data(legacyJSON.utf8))
        #expect(back.allowedRecipients == nil)
        #expect(back.hideTaskScoped == false)
        #expect(back.showErrors == true)
        #expect(back.visibleGroups == [.chat, .system, .securityReviews])
    }

    /// The Chat-off half of the legacy migration: kindless security rows were hidden, so the migrated
    /// config keeps them hidden.
    @Test func legacyConfigWithChatOffKeepsSecurityReviewsHidden() throws {
        let legacyJSON = """
        {"visibleGroups":["toolCalls","system"],"visibility":"all"}
        """
        let back = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: Data(legacyJSON.utf8))
        #expect(back.visibleGroups == [.toolCalls, .system])
    }

    /// Group visibility persists INVERTED (`hiddenGroups`), so a config saved today with every group
    /// on stays "everything on" when a future build adds a group — the visible-set encoding silently
    /// hid any group the saving build didn't know about. Pins the wire shape, the everything-on case,
    /// and that an unknown hidden name from a newer build is ignored rather than failing the decode.
    @Test func groupVisibilityPersistsAsHiddenSet() throws {
        var config = TranscriptViewConfig.everything
        config.visibleGroups.remove(.securityReviews)
        let data = try JSONEncoder().encode(config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["hiddenGroups"] as? [String] == ["securityReviews"])
        #expect(json["visibleGroups"] == nil)

        let allOn = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: JSONEncoder().encode(TranscriptViewConfig.everything))
        #expect(allOn.visibleGroups == Set(TranscriptKindGroup.allCases))

        let futureJSON = """
        {"hiddenGroups":["memory","someFutureGroup"],"visibility":"all","hideTaskScoped":false,"showErrors":true}
        """
        let future = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: Data(futureJSON.utf8))
        #expect(future.visibleGroups == Set(TranscriptKindGroup.allCases).subtracting([.memory]))
    }
}
