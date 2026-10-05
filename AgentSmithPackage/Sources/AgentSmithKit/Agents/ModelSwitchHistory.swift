import Foundation
import SwiftLLMKit

/// Adapts a live agent's conversation so a DIFFERENT model can continue it.
///
/// Called only on a SWITCH (different model or provider); a retune of the same model keeps the
/// history untouched. The conversation itself — text, tool calls, tool results, `reasoning` — is
/// kept. Three kinds of provider-shaped data are not, and each has one rule that applies to every
/// switch, whatever the two providers are:
///
/// - **Continuation** (`LLMMessage.continuation`) is dropped, all of it. Every field is an opaque,
///   signed artifact of the model that produced it (Anthropic thinking blocks, Gemini parts and
///   the legacy signatures, Codex reasoning items), so none is guaranteed to be readable by the
///   next model — and a provider that does verify one fails the request with a 400, which is
///   permanent and stops the agent. Anthropic thinking blocks are the one case where keeping them
///   might work, and they are dropped too:
///   - Anthropic's preserved-thinking prefix check invalidates a thinking block when ANY earlier
///     message changes, explicitly including an earlier `tool_use`. The id rewrite below edits
///     every tool turn, and media removal edits messages too, so the blocks this function would
///     keep are the blocks the API is documented to reject (a 400 by default for accounts created
///     on or after 2026-08-31; older accounts are checked only when a request opts in).
///   - A provider that merely speaks the Anthropic API (a compatible third-party endpoint) never
///     produced those signatures and has no reason to accept them.
///   - Removing thinking blocks is documented as always valid ("Remove `thinking` blocks … all of
///     them: Valid (the model loses that reasoning)"), and a tool turn left without one makes the
///     API disable thinking for that request rather than error ("Mid-turn conflicts degrade
///     gracefully"). Sources: platform.claude.com/docs/en/build-with-claude/thinking and
///     /preserved-thinking, checked 2026-10-05.
///
///   The cost is the earlier turns' hidden reasoning on an Anthropic→Anthropic switch the target
///   model could have read (e.g. Opus 5 → Opus 5.5). Many such switches drop it server-side
///   anyway (a model reads only a fixed set of other models' blocks). Gemini then replays plain
///   content with its documented validation-bypass signature, as the kit already does for
///   cross-model history; Codex replays the history without reasoning items, exactly as it does a
///   history that began on another provider.
/// - **Tool-call ids** are reissued on every switch: each call OCCURRENCE gets a fresh `c` + 8
///   digits — 9 alphanumerics, the one shape every supported API accepts (Mistral requires exactly
///   9; OpenAI caps length at 40; Anthropic allows `[a-zA-Z0-9_-]`) — and each result is re-pointed
///   at its call. Neither the provider nor the API family is a reliable signal that ids can stay:
///   a router (OpenRouter, Hugging Face, Ollama Cloud) keeps one provider id while hosting
///   vendors with different id rules, so `toolu_…` ids minted by Claude are not valid when the
///   same provider next routes to Mistral. Per occurrence, not per distinct id, because some
///   servers reuse `call_0` every turn: one id per distinct value would give several `tool_use`
///   blocks the same id, which Anthropic rejects ("tool_use ids must be unique"), and the Gemini
///   encoder, which names each result by looking its id up among the calls, would name every
///   earlier result after the latest call carrying that id.
/// - **Media.** Images and documents are runtime-only fields, sent as-is to whatever model is
///   next. A model without image (or document) input would reject the request permanently, so
///   they are removed, with a note left in the message so the model knows something was there.
///
/// `reasoning` text is kept: it is plain text, and the providers that replay it do so only for
/// models flagged to want it.
enum ModelSwitchHistory {

    /// What the model being switched TO can take as input.
    struct Destination: Equatable {
        let supportsVision: Bool
        let supportsDocuments: Bool
    }

    static func adapt(_ history: [LLMMessage], for destination: Destination) -> [LLMMessage] {
        canonicalizingToolCallIDs(in: history).map { message in
            var adapted = message
            adapted.continuation = nil
            removeUnsupportedMedia(from: &adapted, destination: destination)
            return adapted
        }
    }

    /// The history with every tool call given a fresh canonical id and every tool result
    /// re-pointed at the call it answers.
    ///
    /// Pairing is positional, because the old ids may not be unique: each assistant message with
    /// tool calls opens a turn, and a result answers the first still-unanswered call of the most
    /// recent such turn that carried its old id. That is first-in-first-out among calls sharing an
    /// id inside one message, which is the order `AgentActor` appends results in (by batch index).
    /// A result with no unanswered call to claim — an orphan, or a second result for one call —
    /// gets a fresh id of its own, so no two results ever share one either; it was already
    /// unpaired, and stays so.
    ///
    /// Only a new tool-call turn replaces the open one. An assistant text message between a call
    /// and its result does not close it: that history is already malformed for every API, and
    /// keeping the pairing at least keeps the result truthful about which call it answers.
    ///
    /// Deterministic, and idempotent: ids are issued in history order, so adapting an adapted
    /// history reissues the same ids.
    static func canonicalizingToolCallIDs(in history: [LLMMessage]) -> [LLMMessage] {
        var issuedCount = 0
        func issueID() -> String {
            issuedCount += 1
            return String(format: "c%08d", issuedCount)
        }
        // Old id → canonical ids of the open turn's calls that carried it and await a result,
        // in call order.
        var unansweredCallIDs: [String: [String]] = [:]
        func openTurn(_ calls: [LLMToolCall]) -> [LLMToolCall] {
            unansweredCallIDs = [:]
            return calls.map { call in
                var call = call
                let canonical = issueID()
                unansweredCallIDs[call.id, default: []].append(canonical)
                call.id = canonical
                return call
            }
        }
        func answer(_ oldID: String) -> String {
            guard var pending = unansweredCallIDs[oldID], !pending.isEmpty else { return issueID() }
            let canonical = pending.removeFirst()
            unansweredCallIDs[oldID] = pending
            return canonical
        }

        var canonicalized: [LLMMessage] = []
        canonicalized.reserveCapacity(history.count)
        for message in history {
            var message = message
            switch message.content {
            case .toolCalls(let calls):
                message.content = .toolCalls(openTurn(calls))
            case .mixed(let text, let calls):
                message.content = .mixed(text: text, toolCalls: openTurn(calls))
            case .toolResult(let toolCallID, let resultText):
                message.content = .toolResult(toolCallID: answer(toolCallID), content: resultText)
            case .text:
                break
            }
            canonicalized.append(message)
        }
        return canonicalized
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
