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
            hiddenKinds: [.toolOutput, .memorySaved, .agentOnline],
            showsChat: false,
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

    /// Hiding one kind must hide exactly that kind: siblings in the same group still match, and
    /// kindless messages follow `showsChat` — the per-kind axis the popover now edits directly.
    @Test func singleHiddenKindFiltersJustThatKind() {
        var config = TranscriptViewConfig.everything
        config.setKind(.toolOutput, visible: false)
        let filter = config.makeFilter()
        let hidden = ChannelMessage(
            sender: .agent(.brown), content: "output",
            metadata: ["messageKind": .kind(.toolOutput)])
        let sibling = ChannelMessage(
            sender: .agent(.brown), content: "request",
            metadata: ["messageKind": .kind(.toolRequest)])
        let kindless = ChannelMessage(sender: .user, content: "hi")
        #expect(!filter.matches(hidden))
        #expect(filter.matches(sibling))
        #expect(filter.matches(kindless))
    }

    /// The group checkbox is a convenience over the per-kind truth: group state derives from the
    /// hidden set (all / mixed / none), and setting the group rewrites exactly its own kinds.
    @Test func groupVisibilityDerivesFromHiddenKinds() {
        var config = TranscriptViewConfig.everything
        #expect(config.groupVisibility(of: .toolCalls) == .all)
        config.setKind(.toolOutput, visible: false)
        #expect(config.groupVisibility(of: .toolCalls) == .mixed)
        config.setGroup(.toolCalls, visible: false)
        #expect(config.groupVisibility(of: .toolCalls) == .none)
        #expect(config.hiddenKinds == TranscriptKindGroup.toolCalls.kinds)
        config.setGroup(.toolCalls, visible: true)
        #expect(config == .everything)
        // Chat has no kinds; its group state is the kindless switch.
        config.setGroup(.chat, visible: false)
        #expect(!config.showsChat)
        #expect(config.groupVisibility(of: .chat) == .none)
    }

    /// A config persisted BEFORE the recipient/task-scope/error axes existed must still decode — the new
    /// fields fall back to their inits (nil recipients, task-scoped shown, errors shown). Kind
    /// visibility comes from the legacy `visibleGroups` key expanded to each hidden group's kinds;
    /// `securityReviews` inherits Chat's state because security-review rows were kindless when this
    /// config was written, so Chat is the toggle that actually governed them — the migrated config
    /// shows exactly what the original did.
    @Test func legacyConfigWithoutNewAxesDecodes() throws {
        let legacyJSON = """
        {"visibleGroups":["chat","system"],"visibility":"all"}
        """
        let back = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: Data(legacyJSON.utf8))
        #expect(back.allowedRecipients == nil)
        #expect(back.hideTaskScoped == false)
        #expect(back.showErrors == true)
        #expect(back.showsChat)
        let expectedHidden: Set<TranscriptKindGroup> = [.toolCalls, .taskLifecycle, .validation, .memory]
        #expect(back.hiddenKinds == expectedHidden.reduce(into: Set()) { $0.formUnion($1.kinds) })
        #expect(back.groupVisibility(of: .system) == .all)
        #expect(back.groupVisibility(of: .securityReviews) == .all)
    }

    /// The Chat-off half of the legacy migration: kindless security rows were hidden, so the migrated
    /// config keeps them hidden.
    @Test func legacyConfigWithChatOffKeepsSecurityReviewsHidden() throws {
        let legacyJSON = """
        {"visibleGroups":["toolCalls","system"],"visibility":"all"}
        """
        let back = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: Data(legacyJSON.utf8))
        #expect(!back.showsChat)
        #expect(back.groupVisibility(of: .securityReviews) == .none)
        #expect(back.groupVisibility(of: .toolCalls) == .all)
        #expect(back.groupVisibility(of: .system) == .all)
    }

    /// The group-persisted generation (`hiddenGroups`) migrates the same way: each hidden group
    /// expands to its kinds, and a hidden Chat becomes `showsChat == false`.
    @Test func hiddenGroupsGenerationMigratesToKinds() throws {
        let json = """
        {"hiddenGroups":["memory","chat"],"visibility":"all","hideTaskScoped":false,"showErrors":true}
        """
        let back = try JSONDecoder().decode(TranscriptViewConfig.self, from: Data(json.utf8))
        #expect(back.hiddenKinds == TranscriptKindGroup.memory.kinds)
        #expect(!back.showsChat)
    }

    /// Kind visibility persists INVERTED (`hiddenKinds`), so a config saved today with everything
    /// on stays "everything on" when a future build adds a kind — the visible-set encoding silently
    /// hid any kind the saving build didn't know about. Pins the wire shape (sorted raw values),
    /// the everything-on case, and that an unknown hidden name from a newer build is ignored rather
    /// than failing the decode.
    @Test func kindVisibilityPersistsAsHiddenSet() throws {
        var config = TranscriptViewConfig.everything
        config.setKind(.securityReview, visible: false)
        config.setKind(.memorySaved, visible: false)
        let data = try JSONEncoder().encode(config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["hiddenKinds"] as? [String] == ["memory_saved", "security_review"])
        #expect(json["hiddenGroups"] == nil)
        #expect(json["visibleGroups"] == nil)

        let allOn = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: JSONEncoder().encode(TranscriptViewConfig.everything))
        #expect(allOn.hiddenKinds.isEmpty)
        #expect(allOn.showsChat)

        let futureJSON = """
        {"hiddenKinds":["memory_saved","some_future_kind"],"showsChat":true,"visibility":"all","hideTaskScoped":false,"showErrors":true}
        """
        let future = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: Data(futureJSON.utf8))
        #expect(future.hiddenKinds == [.memorySaved])
    }
}
