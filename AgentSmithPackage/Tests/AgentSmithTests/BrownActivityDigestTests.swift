import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `OrchestrationRuntime.assembleBrownActivityDigest`, the periodic Brown-activity
/// summary that wakes Smith without polling.
///
/// Regression context: the digest used to suppress only on a literally-empty channel window
/// (`recent.isEmpty`). But Smith's own idle "No action needed." replies land on the channel,
/// so every window was non-empty — and the digest fired a misleading "Brown made 0 tool
/// calls — likely stuck" body even when Brown was idle. That woke Smith every 10 minutes into
/// a self-sustaining text-only loop the circuit breaker eventually terminated. The fix
/// suppresses on the absence of *Brown* activity, not on window emptiness.
@Suite("Brown activity digest")
struct BrownActivityDigestTests {

    private static func brownToolRequest(tool: String) -> ChannelMessage {
        ChannelMessage(
            sender: .agent(.brown),
            content: "\(tool): doing work",
            metadata: ["messageKind": .string("tool_request"), "tool": .string(tool)]
        )
    }

    @Test("No Brown activity (only Smith's own idle chatter) suppresses the digest")
    func suppressesWhenOnlySmithChatter() async {
        let channel = MessageChannel()
        let since = Date(timeIntervalSinceNow: -60)

        // The window is non-empty, but contains zero Brown activity — exactly the loop trigger.
        await channel.post(ChannelMessage(sender: .agent(.smith), content: "No action needed."))
        await channel.post(ChannelMessage(sender: .system, content: "some unrelated system note"))

        let digest = await OrchestrationRuntime.assembleBrownActivityDigest(channel: channel, since: since)
        #expect(digest == nil)
    }

    @Test("Real Brown tool activity produces a non-nil digest")
    func producesDigestForBrownActivity() async {
        let channel = MessageChannel()
        let since = Date(timeIntervalSinceNow: -60)

        await channel.post(Self.brownToolRequest(tool: "glob"))
        await channel.post(ChannelMessage(sender: .agent(.smith), content: "No action needed."))

        let digest = await OrchestrationRuntime.assembleBrownActivityDigest(channel: channel, since: since)
        let unwrapped = try? #require(digest)
        #expect(unwrapped?.contains("1 tool call") == true)
    }

    @Test("A genuinely empty window suppresses the digest")
    func suppressesWhenWindowEmpty() async {
        let channel = MessageChannel()
        let digest = await OrchestrationRuntime.assembleBrownActivityDigest(
            channel: channel,
            since: Date(timeIntervalSinceNow: -60)
        )
        #expect(digest == nil)
    }
}
