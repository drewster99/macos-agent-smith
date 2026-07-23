import Foundation
import SwiftLLMKit
import os

/// Executes one `EvaluatorDefinition` against a payload: render slots → LLM →
/// allowlisted tool rounds → until the output grammar parses → bounded retries.
///
/// This is the generalization of `SecurityEvaluator`'s existing evaluate loop (which
/// already supports multi-turn tool use within a single evaluation — its file_read
/// rounds). The runner is STATELESS by design: anything an evaluation family needs to
/// remember across calls (WARN-retry auto-approval, recent-request history, failure
/// breakers) lives at the call site, which assembles it into the payload. The function
/// is pure; memory belongs to the caller.
public enum EvaluationRunner {

    /// The single parsed result of one evaluation.
    public enum Outcome: Sendable, Equatable {
        /// A `verdictLine` grammar matched: the token plus any reason text.
        case verdict(token: String, reason: String?)
        /// A `jsonArray` grammar matched: each element re-encoded as its own compact
        /// JSON fragment, ready to become an `{{item}}` slot downstream.
        case items([String])
        /// The evaluation could not produce a grammar-conforming result: timeout, turn
        /// exhaustion, provider failure, or persistent parse failure. NEVER to be
        /// conflated with a rejection — an error parks work for escalation, it does not
        /// send a worker chasing ghosts.
        case error(String)
    }

    /// How many grammar-violating responses are re-prompted before giving up.
    /// Verdict validators get one same-context repair; an empty response aborts the
    /// attempt so the coordinator retries with a fresh validator conversation.
    static let maxVerdictParseRetries = 1
    static let maxJSONParseRetries = 8

    private static let logger = Logger(subsystem: "com.agentsmith", category: "EvaluationRunner")

    /// The debugging record of one evaluation run: exactly what was sent and what came
    /// back, so a surprising verdict can be diagnosed after the fact. Persisted (capped)
    /// on the task's verdict ledger by the validation coordinator.
    public struct Transcript: Sendable, Equatable {
        /// The input template with all slots rendered — the user message the model saw.
        public var renderedInput: String
        /// The FULL system message the model saw — the composed prompt including the criterion
        /// and the response-format contract, not just the definition's base text. This is what the
        /// inspector needs to show what the validator was actually told.
        public var renderedSystemPrompt: String
        /// One entry per LLM turn: text responses verbatim (including grammar-retry
        /// nudge rounds), tool rounds summarized as call → result-preview lines.
        public var turnLog: [String]

        public init(renderedInput: String = "", renderedSystemPrompt: String = "", turnLog: [String] = []) {
            self.renderedInput = renderedInput
            self.renderedSystemPrompt = renderedSystemPrompt
            self.turnLog = turnLog
        }
    }

    /// The evaluation loop over already-composed messages: LLM → allowlisted tool rounds →
    /// until the output grammar parses → bounded retries. The caller composes the system
    /// prompt and user message — as the validation coordinator does, placing the criterion
    /// in the system prompt and delivering the evidence as a labeled JSON object so the
    /// judged result can never be confused with the rubric. `tools` is the already-resolved
    /// allowlist (the caller maps `definition.toolNames` to live tools — the runner never
    /// conjures capabilities). `temperature` overrides the model's configured sampling:
    /// validators pass 0 for a deterministic verdict; nil inherits the provider's config.
    /// `onResponse` lets the caller record usage per LLM call.
    public static func runMessages(
        definition: EvaluatorDefinition,
        systemPrompt: String,
        userMessage: String,
        provider: any LLMProvider,
        tools: [any AgentTool],
        toolContext: ToolContext,
        temperature: Double? = nil,
        modelSupportsVision: Bool = false,
        modelSupportsDocuments: Bool = false,
        drainStagedAttachments: (@Sendable () async -> [Attachment])? = nil,
        onResponse: (@Sendable (LLMResponse, Int) async -> Void)? = nil,
        onToolResult: (@Sendable (LLMToolCall, String) async -> Void)? = nil,
        securityGate: (@Sendable (LLMToolCall, any AgentTool) async -> Bool)? = nil
    ) async -> (outcome: Outcome, transcript: Transcript) {
        var transcript = Transcript()
        transcript.renderedInput = userMessage
        transcript.renderedSystemPrompt = systemPrompt

        var messages: [LLMMessage] = [
            .system(systemPrompt),
            .user(userMessage)
        ]
        let toolDefinitions = tools.map { $0.definition(for: .securityAgent) }
        let deadline = Date().addingTimeInterval(definition.timeoutSeconds)
        var parseRetries = 0
        var turns = 0
        var toolObservations: [ToolObservation] = []

        while turns < definition.maxTurns {
            if Date() > deadline {
                return (.error("timed out after \(Int(definition.timeoutSeconds))s"), transcript)
            }
            if Task.isCancelled {
                return (.error("cancelled"), transcript)
            }
            turns += 1

            let response: LLMResponse
            let callStart = Date()
            do {
                // Models that reject a temperature override (reasoning models) are handled
                // proactively by SwiftLLMKit's `mustNeverSendTemperatureParam` metadata — the
                // provider omits temperature for those, so a 0 here reaches every other model
                // and never 400s a flagged one.
                response = try await provider.send(
                    messages: messages,
                    tools: toolDefinitions,
                    overrides: LLMCallOverrides(maxOutputTokens: definition.maxOutputTokens, temperature: temperature)
                )
            } catch {
                return (.error("LLM call failed: \(error.localizedDescription)"), transcript)
            }
            await onResponse?(response, Int(Date().timeIntervalSince(callStart) * 1000))

            // Tool round: execute allowlisted calls and loop for the next turn.
            if !response.toolCalls.isEmpty {
                messages.append(.assistant(from: response))
                var toolLines: [String] = []
                for call in response.toolCalls {
                    var parsedArguments: [String: AnyCodable]?
                    let result: String
                    // The tool's OWN outcome flag, captured at execution. Never re-derived by
                    // sniffing the result text: evidence tools return file contents, and a file
                    // that happens to contain a phrase like "no such file" would otherwise read
                    // back as a failed call.
                    let succeeded: Bool
                    if let tool = tools.first(where: { $0.name == call.name }) {
                        // When a security gate is provided (validators), every tool call is routed
                        // through it first. For read-only evidence tools it auto-approves without an
                        // LLM call, so this is a central choke point (tightenable later) rather than
                        // a behavior change. A denial short-circuits execution.
                        if let securityGate, await securityGate(call, tool) == false {
                            result = "Tool execution denied by security."
                            succeeded = false
                            parsedArguments = try? call.parsedArguments()
                        } else {
                            do {
                                let arguments = try call.parsedArguments()
                                parsedArguments = arguments
                                let outcome = try await tool.execute(arguments: arguments, context: toolContext)
                                result = outcome.output
                                succeeded = outcome.succeeded
                            } catch {
                                parsedArguments = try? call.parsedArguments()
                                result = "Tool error: \(error.localizedDescription)"
                                succeeded = false
                            }
                        }
                    } else {
                        parsedArguments = try? call.parsedArguments()
                        result = "Tool '\(call.name)' is not permitted for this evaluation."
                        succeeded = false
                    }
                    await onToolResult?(call, result)
                    toolObservations.append(ToolObservation(
                        call: call,
                        parsedArguments: parsedArguments,
                        result: result,
                        succeeded: succeeded
                    ))
                    toolLines.append("→ \(call.name)(\(call.arguments.prefix(200))) → \(result.prefix(300))")
                    messages.append(.toolResult(Self.capToolResult(result), callID: call.id))
                }
                transcript.turnLog.append(toolLines.joined(separator: "\n"))
                // Drain anything `attach_file` staged this round into a user turn so the model
                // actually perceives it next iteration — images as content blocks (vision-gated),
                // every attachment as a reference line. Mirrors AgentActor's stage→drain.
                if let drainStagedAttachments {
                    let staged = await drainStagedAttachments()
                    if !staged.isEmpty {
                        let assembled = AttachmentInjection.assemble(
                            staged,
                            modelSupportsVision: modelSupportsVision,
                            modelSupportsDocuments: modelSupportsDocuments,
                            urlProvider: toolContext.attachmentURLProvider
                        )
                        let header = "[Attached for review via attach_file]"
                        let body = assembled.referenceLines.isEmpty
                            ? header
                            : ([header] + assembled.referenceLines).joined(separator: "\n")
                        if assembled.images.isEmpty && assembled.documents.isEmpty {
                            messages.append(.user(body))
                        } else {
                            messages.append(.user(body, images: assembled.images, documents: assembled.documents))
                        }
                    }
                }
                continue
            }

            // Text turn: parse against the grammar.
            let text = response.text ?? ""
            transcript.turnLog.append(text)
            switch parse(text, grammar: definition.outputGrammar) {
            case .success(let outcome):
                if let contradiction = contradictedToolClaim(in: outcome, observations: toolObservations) {
                    transcript.turnLog.append("[validator runtime guard] \(contradiction)")
                    return (.error(contradiction), transcript)
                }
                return (outcome, transcript)
            case .failure(let why):
                if isEmptyParseFailure(why) && isVerdictGrammar(definition.outputGrammar) {
                    return (.error("empty response from validator; retrying requires a fresh validator conversation"), transcript)
                }
                parseRetries += 1
                guard parseRetries <= maxParseRetries(for: definition.outputGrammar) else {
                    return (.error("unparseable after \(parseRetries) attempts: \(why)"), transcript)
                }
                messages.append(.assistant(from: response))
                messages.append(.user(formatRetryNudge(for: definition.outputGrammar, problem: why)))
            }
        }
        return (.error("exhausted \(definition.maxTurns) turns without a conforming result"), transcript)
    }

    private struct ToolObservation {
        var call: LLMToolCall
        var parsedArguments: [String: AnyCodable]?
        var result: String
        /// The tool's own reported outcome, recorded at execution time.
        var succeeded: Bool

        var pathArgument: String? {
            guard case .string(let path)? = parsedArguments?["path"] else { return nil }
            return path
        }
    }

    private static func maxParseRetries(for grammar: EvaluatorDefinition.OutputGrammar) -> Int {
        switch grammar {
        case .verdictLine:
            return maxVerdictParseRetries
        case .jsonArray:
            return maxJSONParseRetries
        }
    }

    private static func isVerdictGrammar(_ grammar: EvaluatorDefinition.OutputGrammar) -> Bool {
        if case .verdictLine = grammar { return true }
        return false
    }

    private static func isEmptyParseFailure(_ problem: String) -> Bool {
        problem.localizedCaseInsensitiveContains("empty response")
    }

    /// Phrases a rejection uses to claim a file was missing or unreadable. Matching prose is
    /// unavoidable here — the reason is free-form LLM text — but it is only ever a PRE-FILTER.
    /// The load-bearing check is structural: the reason must name the exact path of a file_read
    /// this very evaluation ran and that the tool itself reported as succeeded.
    private static let missingFileClaimPhrases = [
        "returned an error", "return an error", "tool error",
        "does not exist", "did not exist", "not exist",
        "not found", "not readable"
    ]

    /// Detects a REJECT whose stated reason is "I couldn't read <path>" when this evaluation
    /// actually read that path successfully. Returning `.error` (rather than the verdict) makes
    /// the coordinator retry with a fresh validator conversation instead of sending the worker a
    /// punch list built on a false premise.
    private static func contradictedToolClaim(in outcome: Outcome, observations: [ToolObservation]) -> String? {
        guard case .verdict("REJECT", let reason?) = outcome else { return nil }
        let lowerReason = reason.lowercased()
        guard lowerReason.contains("file_read") || lowerReason.contains("file read") else { return nil }
        guard missingFileClaimPhrases.contains(where: { lowerReason.contains($0) }) else { return nil }

        // Case-insensitive path match: macOS filesystems are case-insensitive by default, so a
        // validator echoing a path with different casing is naming the same file.
        let contradicted = observations.first { observation in
            guard observation.call.name == "file_read", observation.succeeded,
                  let path = observation.pathArgument, !path.isEmpty else { return false }
            return lowerReason.contains(path.lowercased())
        }
        guard let path = contradicted?.pathArgument else { return nil }
        return "validator rejection contradicted successful file_read for \(path); discarding this validator attempt"
    }

    // MARK: - Parsing

    enum ParseResult {
        case success(Outcome)
        case failure(String)
    }

    static func parse(_ text: String, grammar: EvaluatorDefinition.OutputGrammar) -> ParseResult {
        switch grammar {
        case .verdictLine(let allowed):
            return parseVerdictLine(text, allowed: allowed)
        case .jsonArray:
            return parseJSONArray(text)
        }
    }

    /// First non-empty line must begin with an allowed token (optionally followed by
    /// ':' and reason text; remaining lines join the reason).
    static func parseVerdictLine(_ text: String, allowed: [EvaluatorDefinition.VerdictSpec]) -> ParseResult {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty else {
            return .failure("empty response")
        }
        // Split on any whitespace (space OR tab — a tab-separated verdict is still a verdict) and
        // match the token case-insensitively (a judge emitting "Reject" instead of "REJECT" is a
        // rejection, not an unparseable line that would wrongly escalate to Smith). The canonical
        // `spec.token` is what we return, so downstream comparisons stay exact.
        let firstWord = first
            .split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            .first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: ":.,")) ?? ""
        guard let spec = allowed.first(where: { $0.token.caseInsensitiveCompare(firstWord) == .orderedSame }) else {
            return .failure("first word '\(firstWord)' is not one of: \(allowed.map(\.token).joined(separator: ", "))")
        }
        var reasonParts: [String] = []
        let remainderOfFirstLine = first.dropFirst(firstWord.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":., ").union(.whitespaces))
        if !remainderOfFirstLine.isEmpty { reasonParts.append(remainderOfFirstLine) }
        reasonParts.append(contentsOf: lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) })
        let reason = reasonParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if spec.requiresReason && reason.isEmpty {
            return .failure("verdict \(spec.token) requires a reason and none was given")
        }
        return .success(.verdict(token: spec.token, reason: reason.isEmpty ? nil : reason))
    }

    /// Extracts the first top-level JSON array of strings from the text.
    static func parseJSONArray(_ text: String) -> ParseResult {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close else {
            return .failure("no JSON array found in response")
        }
        let candidate = String(text[open...close])
        guard let data = candidate.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return .failure("bracketed text is not a valid JSON array")
        }
        var strings: [String] = []
        for element in array {
            guard let string = element as? String else {
                return .failure("every JSON array element must be a string")
            }
            strings.append(string)
        }
        return .success(.items(strings))
    }

    static func formatRetryNudge(for grammar: EvaluatorDefinition.OutputGrammar, problem: String) -> String {
        switch grammar {
        case .verdictLine(let allowed):
            let menu = allowed
                .map { "\($0.token)\($0.requiresReason ? ": <reason — required>" : "")" }
                .joined(separator: "\n")
            return """
                Your response did not match the required format (\(problem)). Respond again. \
                Your FIRST line must begin with exactly one of:
                \(menu)
                """
        case .jsonArray:
            return """
                Your response did not match the required format (\(problem)). Respond again with a \
                single JSON array containing only strings (no prose outside it).
                """
        }
    }

    /// Evidence-tool results are capped exactly like agent tool results (shared overflow handling —
    /// see `ToolResultCap`): oversized output spills to a file the validator reads back in slices.
    static func capToolResult(_ result: String) -> String {
        ToolResultCap.cap(result)
    }
}
