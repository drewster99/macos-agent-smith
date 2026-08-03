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

    @Test func conversationDropsSecurityAgentToBrown() {
        let filter = TranscriptViewConfig.conversation.makeFilter()
        let securityToBrown = ChannelMessage(
            sender: .agent(.securityAgent),
            recipientID: UUID(),
            recipient: .agent(.brown),
            content: "SAFE Internal task management metadata update"
        )
        #expect(!filter.matches(securityToBrown))
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
    /// fields fall back to their inits (nil recipients, task-scoped shown, errors shown).
    @Test func legacyConfigWithoutNewAxesDecodes() throws {
        let legacyJSON = """
        {"visibleGroups":["chat","system"],"visibility":"all"}
        """
        let back = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: Data(legacyJSON.utf8))
        #expect(back.allowedRecipients == nil)
        #expect(back.hideTaskScoped == false)
        #expect(back.showErrors == true)
        #expect(back.visibleGroups == [.chat, .system])
    }
}
