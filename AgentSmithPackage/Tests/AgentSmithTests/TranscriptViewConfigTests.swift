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
            defaultKinds: TranscriptKindSelection(
                hiddenKinds: [.toolOutput, .memorySaved, .agentOnline], showsChat: false),
            senderKindOverrides: [
                .agent(.brown): TranscriptKindSelection(hiddenKinds: [.statusUpdate], showsChat: true),
                .system: TranscriptKindSelection(hiddenKinds: [], showsChat: false)
            ],
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
    /// kindless messages follow `showsChat` — the per-kind axis the popover edits directly.
    @Test func singleHiddenKindFiltersJustThatKind() {
        var config = TranscriptViewConfig.everything
        config.defaultKinds.setKind(.toolOutput, visible: false)
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

    /// A sender override replaces the DEFAULT selection for exactly that sender: Brown's hidden
    /// kind stays visible from Smith, Brown's other kinds still show, and a sender with no
    /// override follows the default — including for kinds the default hides.
    @Test func senderOverrideGovernsOnlyThatSender() {
        var config = TranscriptViewConfig.everything
        config.defaultKinds.setKind(.memorySaved, visible: false)
        config.setKindSelection(
            TranscriptKindSelection(hiddenKinds: [.toolOutput], showsChat: true),
            forSender: .agent(.brown))
        let filter = config.makeFilter()

        let brownToolOutput = ChannelMessage(
            sender: .agent(.brown), content: "out", metadata: ["messageKind": .kind(.toolOutput)])
        let smithToolOutput = ChannelMessage(
            sender: .agent(.smith), content: "out", metadata: ["messageKind": .kind(.toolOutput)])
        let brownToolRequest = ChannelMessage(
            sender: .agent(.brown), content: "req", metadata: ["messageKind": .kind(.toolRequest)])
        // Brown's OVERRIDE doesn't hide memorySaved, so it shows from Brown — the override is a
        // REPLACEMENT, not a delta on the default.
        let brownMemorySaved = ChannelMessage(
            sender: .agent(.brown), content: "mem", metadata: ["messageKind": .kind(.memorySaved)])
        let smithMemorySaved = ChannelMessage(
            sender: .agent(.smith), content: "mem", metadata: ["messageKind": .kind(.memorySaved)])

        #expect(!filter.matches(brownToolOutput))
        #expect(filter.matches(smithToolOutput))
        #expect(filter.matches(brownToolRequest))
        #expect(filter.matches(brownMemorySaved))
        #expect(!filter.matches(smithMemorySaved))
    }

    /// Per-sender chat: an override with `showsChat == false` hides that sender's KINDLESS
    /// messages while other senders' plain chat still shows.
    @Test func senderOverrideGovernsKindlessMessages() {
        var config = TranscriptViewConfig.everything
        config.setKindSelection(
            TranscriptKindSelection(hiddenKinds: [], showsChat: false),
            forSender: .system)
        let filter = config.makeFilter()
        #expect(!filter.matches(ChannelMessage(sender: .system, content: "notice")))
        #expect(filter.matches(ChannelMessage(sender: .user, content: "hi")))
    }

    /// The scope accessors: reading a sender without an override returns the default; setting
    /// writes the override; removing returns the sender to following the default.
    @Test func kindSelectionScopeAccessors() {
        var config = TranscriptViewConfig.everything
        config.defaultKinds.setKind(.advisory, visible: false)
        #expect(config.kindSelection(forSender: .agent(.brown)) == config.defaultKinds)
        #expect(!config.hasKindOverride(forSender: .agent(.brown)))

        var custom = config.defaultKinds
        custom.setKind(.toolOutput, visible: false)
        config.setKindSelection(custom, forSender: .agent(.brown))
        #expect(config.hasKindOverride(forSender: .agent(.brown)))
        #expect(config.kindSelection(forSender: .agent(.brown)) == custom)
        // The default scope is untouched by the override write.
        #expect(config.defaultKinds.isKindVisible(.toolOutput))

        config.removeKindOverride(forSender: .agent(.brown))
        #expect(config.kindSelection(forSender: .agent(.brown)) == config.defaultKinds)
    }

    /// The group checkbox is a convenience over the per-kind truth: group state derives from the
    /// hidden set (all / mixed / none), and setting the group rewrites exactly its own kinds.
    @Test func groupVisibilityDerivesFromHiddenKinds() {
        var selection = TranscriptKindSelection.allVisible
        #expect(selection.groupVisibility(of: .toolCalls) == .all)
        selection.setKind(.toolOutput, visible: false)
        #expect(selection.groupVisibility(of: .toolCalls) == .mixed)
        selection.setGroup(.toolCalls, visible: false)
        #expect(selection.groupVisibility(of: .toolCalls) == .none)
        #expect(selection.hiddenKinds == TranscriptKindGroup.toolCalls.kinds)
        selection.setGroup(.toolCalls, visible: true)
        #expect(selection == .allVisible)
        // Chat has no kinds; its group state is the kindless switch.
        selection.setGroup(.chat, visible: false)
        #expect(!selection.showsChat)
        #expect(selection.groupVisibility(of: .chat) == .none)
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
        #expect(back.defaultKinds.showsChat)
        let expectedHidden: Set<TranscriptKindGroup> = [.toolCalls, .taskLifecycle, .validation, .memory]
        #expect(back.defaultKinds.hiddenKinds == expectedHidden.reduce(into: Set()) { $0.formUnion($1.kinds) })
        #expect(back.defaultKinds.groupVisibility(of: .system) == .all)
        #expect(back.defaultKinds.groupVisibility(of: .securityReviews) == .all)
        #expect(back.senderKindOverrides.isEmpty)
    }

    /// The Chat-off half of the legacy migration: kindless security rows were hidden, so the migrated
    /// config keeps them hidden.
    @Test func legacyConfigWithChatOffKeepsSecurityReviewsHidden() throws {
        let legacyJSON = """
        {"visibleGroups":["toolCalls","system"],"visibility":"all"}
        """
        let back = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: Data(legacyJSON.utf8))
        #expect(!back.defaultKinds.showsChat)
        #expect(back.defaultKinds.groupVisibility(of: .securityReviews) == .none)
        #expect(back.defaultKinds.groupVisibility(of: .toolCalls) == .all)
        #expect(back.defaultKinds.groupVisibility(of: .system) == .all)
    }

    /// The group-persisted generation (`hiddenGroups`) migrates the same way: each hidden group
    /// expands to its kinds, and a hidden Chat becomes `showsChat == false`.
    @Test func hiddenGroupsGenerationMigratesToKinds() throws {
        let json = """
        {"hiddenGroups":["memory","chat"],"visibility":"all","hideTaskScoped":false,"showErrors":true}
        """
        let back = try JSONDecoder().decode(TranscriptViewConfig.self, from: Data(json.utf8))
        #expect(back.defaultKinds.hiddenKinds == TranscriptKindGroup.memory.kinds)
        #expect(!back.defaultKinds.showsChat)
    }

    /// Kind visibility persists INVERTED (`hiddenKinds`), so a config saved today with everything
    /// on stays "everything on" when a future build adds a kind — the visible-set encoding silently
    /// hid any kind the saving build didn't know about. Pins the wire shape (sorted raw values,
    /// flat default keys — the per-kind generation's exact format when no overrides exist, so
    /// yesterday's configs round-trip unchanged), the everything-on case, and that an unknown
    /// hidden name from a newer build is ignored rather than failing the decode.
    @Test func kindVisibilityPersistsAsHiddenSet() throws {
        var config = TranscriptViewConfig.everything
        config.defaultKinds.setKind(.securityReview, visible: false)
        config.defaultKinds.setKind(.memorySaved, visible: false)
        let data = try JSONEncoder().encode(config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["hiddenKinds"] as? [String] == ["memory_saved", "security_review"])
        #expect(json["hiddenGroups"] == nil)
        #expect(json["visibleGroups"] == nil)
        // No overrides -> no key at all, so the previous per-kind generation's shape is preserved.
        #expect(json["senderKindOverrides"] == nil)

        let allOn = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: JSONEncoder().encode(TranscriptViewConfig.everything))
        #expect(allOn.defaultKinds == .allVisible)

        let futureJSON = """
        {"hiddenKinds":["memory_saved","some_future_kind"],"showsChat":true,"visibility":"all","hideTaskScoped":false,"showErrors":true}
        """
        let future = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: Data(futureJSON.utf8))
        #expect(future.defaultKinds.hiddenKinds == [.memorySaved])
    }

    /// Override persistence: rows sort by sender for diff-stable JSON, and a row a NEWER build
    /// wrote with an unknown sender is dropped alone — that sender follows the default (fails
    /// open) — instead of losing the rows behind it or failing the whole config decode.
    @Test func senderOverridesPersistSortedAndFailOpen() throws {
        var config = TranscriptViewConfig.everything
        config.setKindSelection(TranscriptKindSelection(hiddenKinds: [.toolOutput], showsChat: true),
                                forSender: .system)
        config.setKindSelection(TranscriptKindSelection(hiddenKinds: [], showsChat: false),
                                forSender: .agent(.brown))
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(TranscriptViewConfig.self, from: data)
        #expect(back == config)
        // Deterministic ROW order (sorted by sender), proven with `.sortedKeys` so JSON object
        // key order — which JSONEncoder does not stabilize — can't fail the comparison; array
        // order is exactly what remains.
        let stable = JSONEncoder()
        stable.outputFormatting = .sortedKeys
        #expect(try stable.encode(back) == (try stable.encode(config)))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(json["senderKindOverrides"] as? [[String: Any]])
        // "agent(…brown)" sorts before "system" under the description sort the encoder uses.
        #expect(rows.count == 2)
        #expect(rows[0]["sender"] as? [String: Any] != nil)
        #expect((rows[0]["showsChat"] as? Bool) == false)   // brown's override
        #expect((rows[1]["showsChat"] as? Bool) == true)    // system's override

        let mixedJSON = """
        {"hiddenKinds":[],"showsChat":true,
         "senderKindOverrides":[
            {"sender":{"someFutureSender":{}},"hiddenKinds":["tool_output"],"showsChat":true},
            {"sender":{"system":{}},"hiddenKinds":["memory_saved"],"showsChat":false}
         ],
         "visibility":"all","hideTaskScoped":false,"showErrors":true}
        """
        let mixed = try JSONDecoder().decode(TranscriptViewConfig.self, from: Data(mixedJSON.utf8))
        #expect(mixed.senderKindOverrides.count == 1)
        #expect(mixed.kindSelection(forSender: .system)
                == TranscriptKindSelection(hiddenKinds: [.memorySaved], showsChat: false))
    }
}
