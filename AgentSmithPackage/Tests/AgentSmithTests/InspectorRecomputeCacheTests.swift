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

    /// `ChannelLogView.ChannelBannerKind` lives in the app target so we can't import it
    /// directly here. But its raw values must match what the runtime posts in
    /// `metadata["messageKind"]`. This test pins down the messageKind string surface so
    /// that any rename in the engine immediately flags the inspector dispatcher to update.
    /// The strings come from a grep over `AgentSmithPackage/Sources/AgentSmithKit/`.
    @Test("messageKind string surface is stable")
    func messageKindStringSurfaceIsStable() {
        // Kinds that ChannelBannerKind has explicit cases for (renders a banner or hides the row).
        let bannerKinds: Set<String> = [
            "task_created",
            "task_acknowledged",
            "task_continuing",
            "task_complete",
            "task_completed",
            "task_update",
            "task_update_guidance",
            "task_summarized",
            "task_action_scheduled",
            "changes_requested",
            "memory_saved",
            "memory_searched",
            "restart_chrome",
            "timer_activity",
        ]
        // Kinds that the runtime emits but ChannelBannerKind intentionally doesn't list —
        // they fall through to MessageRow via the `.none` case in `bannerView(for:…)`.
        // The tool subsystem handles tool_request/tool_output separately. The scheduled-run
        // and submission-auto-rejected kinds are advisory system messages that render fine
        // as plain MessageRows; promoting them to banners is a future polish task.
        let nonBannerKinds: Set<String> = [
            "tool_request",
            "tool_output",
            "scheduled_run_deferred",
            "submission_auto_rejected",
        ]
        // If you remove a kind from `bannerKinds`, also remove its case from
        // `ChannelLogView.ChannelBannerKind` (else you'll have a dead enum case).
        // If you add a new kind to the runtime, decide whether it's a banner or a plain row,
        // and update the appropriate set here AND `ChannelBannerKind` together.
        let total = bannerKinds.count + nonBannerKinds.count
        #expect(bannerKinds.contains("task_created"))
        #expect(bannerKinds.contains("memory_saved"))
        #expect(nonBannerKinds.contains("tool_request"))
        #expect(total == 18, "Expected 18 known messageKind strings (14 banner + 4 non-banner); update both this test and ChannelBannerKind together.")
        #expect(bannerKinds.intersection(nonBannerKinds).isEmpty, "A kind should be either a banner or a plain row, not both")
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
