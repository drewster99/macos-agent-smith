import Foundation
import SwiftLLMKit

/// Adapts a live agent's conversation so a DIFFERENT model can continue it.
///
/// A conversation carries three kinds of provider-shaped data, and each has a rule:
///
/// - **Continuation** (`LLMMessage.continuation`). Each provider family reads only its own field
///   and ignores the others' (Anthropic `anthropicThinkingBlocks`, Gemini `geminiResponseParts`
///   and the legacy signatures, Codex `codexReasoningItems`).
///   - Same API family, different model: Anthropic's thinking blocks are KEPT. Anthropic documents
///     passing them back unchanged across a model switch; the API ignores or drops blocks the new
///     model can't read, and a mid-turn mismatch disables thinking for that request instead of
///     erroring (platform.claude.com/docs/en/build-with-claude/thinking, "Switching models
///     mid-conversation" and "Mid-turn conflicts degrade gracefully"). Gemini parts and Codex
///     reasoning items are dropped: they are opaque signed artifacts of the model that produced
///     them. Gemini then replays the plain content with its documented validation-bypass
///     signature, which is what the kit already does for cross-model history.
///   - Different API family: all continuation is dropped. The new provider would ignore it, and
///     keeping it would only resurrect stale artifacts if the agent later switched back.
/// - **Tool-call ids.** Minted in the old provider's format; on a change of API family they are
///   remapped, consistently in calls and results, to `c` + 8 digits — 9 alphanumerics, the one
///   shape every supported API accepts (Mistral requires exactly 9; OpenAI caps length at 40;
///   Anthropic allows `[a-zA-Z0-9_-]`).
/// - **Media.** Images and documents are runtime-only fields, sent as-is to whatever model is
///   next. A model without image (or document) input would reject the request permanently, so
///   they are removed, with a note left in the message so the model knows something was there.
///
/// `reasoning` text is kept: it is plain text, and the providers that replay it do so only for
///   models flagged to want it.
enum ModelSwitchHistory {

    struct Destination: Equatable {
        let previousAPIType: ProviderAPIType
        let apiType: ProviderAPIType
        let supportsVision: Bool
        let supportsDocuments: Bool
    }

    static func adapt(_ history: [LLMMessage], for destination: Destination) -> [LLMMessage] {
        let changesAPIFamily = destination.previousAPIType != destination.apiType
        let idMap = changesAPIFamily ? canonicalToolCallIDs(in: history) : [:]
        return history.map { message in
            var adapted = message
            adapted.continuation = portableContinuation(message.continuation, changesAPIFamily: changesAPIFamily)
            if !idMap.isEmpty {
                adapted.content = remapToolCallIDs(in: message.content, using: idMap)
            }
            removeUnsupportedMedia(from: &adapted, destination: destination)
            return adapted
        }
    }

    private static func portableContinuation(
        _ continuation: ProviderContinuation?,
        changesAPIFamily: Bool
    ) -> ProviderContinuation? {
        guard let continuation, !changesAPIFamily,
              let thinkingBlocks = continuation.anthropicThinkingBlocks, !thinkingBlocks.isEmpty else {
            return nil
        }
        return ProviderContinuation(anthropicThinkingBlocks: thinkingBlocks)
    }

    /// Every distinct tool-call id, in order of first appearance, mapped to its canonical form.
    static func canonicalToolCallIDs(in history: [LLMMessage]) -> [String: String] {
        var map: [String: String] = [:]
        func note(_ id: String) {
            guard map[id] == nil else { return }
            map[id] = String(format: "c%08d", map.count + 1)
        }
        for message in history {
            switch message.content {
            case .toolCalls(let calls), .mixed(_, let calls):
                calls.forEach { note($0.id) }
            case .toolResult(let toolCallID, _):
                note(toolCallID)
            case .text:
                break
            }
        }
        return map
    }

    private static func remapToolCallIDs(
        in content: LLMMessage.Content,
        using map: [String: String]
    ) -> LLMMessage.Content {
        func remapped(_ calls: [LLMToolCall]) -> [LLMToolCall] {
            calls.map { call in
                var call = call
                if let canonical = map[call.id] { call.id = canonical }
                return call
            }
        }
        switch content {
        case .toolCalls(let calls):
            return .toolCalls(remapped(calls))
        case .mixed(let text, let calls):
            return .mixed(text: text, toolCalls: remapped(calls))
        case .toolResult(let toolCallID, let resultText):
            return .toolResult(toolCallID: map[toolCallID] ?? toolCallID, content: resultText)
        case .text:
            return content
        }
    }

    private static func removeUnsupportedMedia(from message: inout LLMMessage, destination: Destination) {
        var notes: [String] = []
        if !destination.supportsVision, let images = message.images, !images.isEmpty {
            message.images = nil
            notes.append("\(images.count) image(s) removed: this agent switched to a model without image input")
        }
        if !destination.supportsDocuments, let documents = message.documents, !documents.isEmpty {
            message.documents = nil
            notes.append("\(documents.count) document(s) removed: this agent switched to a model without document input")
        }
        guard !notes.isEmpty else { return }
        let note = notes.map { "[\($0)]" }.joined(separator: "\n")
        switch message.content {
        case .text(let text):
            message.content = .text(text.isEmpty ? note : text + "\n\n" + note)
        case .mixed(let text, let calls):
            message.content = .mixed(text: text.isEmpty ? note : text + "\n\n" + note, toolCalls: calls)
        case .toolResult(let toolCallID, let resultText):
            message.content = .toolResult(toolCallID: toolCallID, content: resultText + "\n\n" + note)
        case .toolCalls:
            break   // an assistant tool-call turn carries no media of the agent's making
        }
    }
}
