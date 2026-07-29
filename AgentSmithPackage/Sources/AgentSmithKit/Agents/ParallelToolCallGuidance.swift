import Foundation

/// The parallel tool-calling contract, phrased ONCE and shared by every prompt that offers
/// tools — Brown, the acceptance validators / input enumerators, and the Security Agent's
/// evidence reads — so the guidance cannot drift between surfaces. What motivated sharing
/// it: Brown, whose prompt carried this text, batches up to 20 calls per turn; the
/// validators, whose prompts never mentioned batching, averaged ~2 calls per turn over the
/// same read-only tools and burned turn budget on sequential reads (measured 2026-07-28
/// across 1,025 persisted verdict records).
public enum ParallelToolCallGuidance {
    /// The core contract with per-surface example lines spliced in. Examples must name only
    /// tools the surface actually holds — an example naming `bash` reads as a capability
    /// grant to a validator that has no shell.
    public static func text(examples: [String]) -> String {
        var lines: [String] = [
            "First, determine if you can accomplish your goal with a single tool call. If so, you MUST do that.",
            "If you NEED to make multiple tool calls, think carefully about what you REALLY need. Then emit them all in a single response, with multiple tool calls in a single response. (This is called parallel tool calling.)",
            "**You MUST emit parallel tool calls (multiple tools calls within a single response) whenever you need to call multiple tools AND when the tool call results are independent of each other -- i.e., the result of one tool call won't affect the other calls you are going to make.** This is critical for efficiency."
        ]
        if !examples.isEmpty {
            lines.append("Examples:")
            lines.append(contentsOf: examples.map { "- \($0)" })
        }
        lines.append("Only sequence calls when one depends on the result of another.")
        lines.append("There is no limit to the level of parallelism. A good rule of thumb is that up to 20 parallel calls is usually fine.")
        return lines.joined(separator: "\n")
    }
}
