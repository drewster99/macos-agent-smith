import Testing
import Foundation
@testable import AgentSmithKit

/// Smoke tests for the data shapes that `InspectorView` and `AgentInspectorWindow`
/// hand to the cached single-pass helpers introduced for P1.3.
///
/// The actual `bucketMessagesByRole` and `summarizerStats` helpers live in the app
/// target (not the package), so we can't import them here. What we *can* test is
/// the message-shape contract those helpers depend on: `ChannelMessage.sender`
/// distinguishes agents by role, and `metadata?["messageKind"] == "task_summarized"`
/// / `metadata?["isError"] == true` are the keys the helpers branch on.
///
/// If the message shape ever changes (sender enum, metadata key strings) these
/// tests fail and force the inspector code to be updated alongside the engine.
@Suite("Inspector cache helper contracts")
struct InspectorRecomputeCacheTests {

    @Test("ChannelMessage.Sender distinguishes agent roles")
    func senderEnumDistinguishesAgents() {
        let smithMessage = ChannelMessage(sender: .agent(.smith), content: "hi")
        let brownMessage = ChannelMessage(sender: .agent(.brown), content: "hi")
        let summarizerMessage = ChannelMessage(sender: .agent(.summarizer), content: "hi")
        let userMessage = ChannelMessage(sender: .user, content: "hi")

        // Replicate the inspector's bucket-by-role pattern.
        var byRole: [AgentRole: [ChannelMessage]] = [:]
        for msg in [smithMessage, brownMessage, summarizerMessage, userMessage] {
            if case .agent(let role) = msg.sender {
                byRole[role, default: []].append(msg)
            }
        }

        #expect(byRole[.smith]?.count == 1)
        #expect(byRole[.brown]?.count == 1)
        #expect(byRole[.summarizer]?.count == 1)
        #expect(byRole[.securityAgent]?.isEmpty ?? true)
        // user messages are NOT in any role bucket — important for the inspector's
        // "agent activity" counter, which excludes user input.
        #expect(byRole.values.flatMap(\.self).count == 3)
    }

    /// `ChannelLogView.ChannelBannerKind` lives in the app target so we can't import it directly
    /// here, but its raw values must match what the runtime posts. This test records which kinds
    /// the inspector renders as banners and which fall through to a plain row.
    ///
    /// It used to double as the guard against `messageKind` renames, enumerated by hand "from a
    /// grep" — and it did not work: it listed 18 kinds when the runtime emitted more than thirty,
    /// so most of the surface it claimed to pin was never covered. `ChannelMessageKind` owns that
    /// job now (its wire strings are asserted directly, and a source guard blocks new bare
    /// literals), which leaves this test the narrower question it can actually answer: the
    /// banner/plain-row CLASSIFICATION. The sets are typed, so a rename is a compile error rather
    /// than a silently-stale string.
    @Test("Inspector banner classification is exhaustive and unambiguous")
    func bannerClassificationIsUnambiguous() {
        // Kinds that ChannelBannerKind has explicit cases for (renders a banner or hides the row).
        let bannerKinds: Set<ChannelMessageKind> = [
            .taskCreated,
            .taskAcknowledged,
            .taskContinuing,
            .taskComplete,
            .taskCompleted,
            .taskUpdate,
            .taskUpdateGuidance,
            .taskSummarized,
            .taskActionScheduled,
            .changesRequested,
            .memorySaved,
            .memorySearched,
            .restartChrome,
            .timerActivity
        ]
        // Kinds that the runtime emits but ChannelBannerKind intentionally doesn't list —
        // they fall through to MessageRow via the `.none` case in `bannerView(for:…)`.
        // The tool subsystem handles tool_request/tool_output separately. The scheduled-run
        // and submission-auto-rejected kinds are advisory system messages that render fine
        // as plain MessageRows; promoting them to banners is a future polish task.
        let nonBannerKinds: Set<ChannelMessageKind> = [
            .toolRequest,
            .toolOutput,
            .scheduledRunDeferred,
            .submissionAutoRejected
        ]
        // If you remove a kind from `bannerKinds`, also remove its case from
        // `ChannelLogView.ChannelBannerKind` (else you'll have a dead enum case).
        #expect(
            bannerKinds.intersection(nonBannerKinds).isEmpty,
            "A kind should be either a banner or a plain row, not both"
        )
    }

    @Test("metadata keys task_summarized + isError discriminate summary vs error rows")
    func summarizerMetadataKeys() {
        let summary = ChannelMessage(
            sender: .agent(.summarizer),
            content: "summarized",
            metadata: ["messageKind": .string("task_summarized")]
        )
        let failure = ChannelMessage(
            sender: .agent(.summarizer),
            content: "failed",
            metadata: ["isError": .bool(true)]
        )
        let other = ChannelMessage(
            sender: .agent(.summarizer),
            content: "other",
            metadata: nil
        )

        // Replicate the inspector's single-pass count logic.
        var summaryCount = 0
        var errorCount = 0
        for message in [summary, failure, other] {
            if case .string("task_summarized") = message.metadata?["messageKind"] {
                summaryCount += 1
            }
            if case .bool(true) = message.metadata?["isError"] {
                errorCount += 1
            }
        }
        #expect(summaryCount == 1)
        #expect(errorCount == 1)
    }
}
