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

    @Test func conversationHidesToolAndMemoryNoise() {
        let filter = TranscriptViewConfig.conversation.makeFilter()
        guard case .only(let kinds, let includingKindless) = filter.kinds else {
            Issue.record("expected .only kind rule"); return
        }
        #expect(includingKindless)                      // Chat is on
        #expect(kinds.contains(.taskCompleted))         // Task lifecycle on
        #expect(kinds.contains(.validationReport))      // Validation on
        #expect(!kinds.contains(.toolRequest))          // Tool calls off
        #expect(!kinds.contains(.memorySaved))          // Memory off
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
            visibility: .publicOnly
        )
        let back = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: JSONEncoder().encode(config))
        #expect(back == config)
    }
}
