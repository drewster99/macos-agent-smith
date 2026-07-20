import Foundation

/// A data-defined evaluation function: fresh context in, one parsed result out.
///
/// The unifying observation behind this type (Drew's): the acceptance validator, the
/// per-call tool approver, and the tool scoper are all the same shape — a specific
/// system prompt, a structured input, a constrained output grammar, optional tool
/// rounds, and a single parsed result. `EvaluatorDefinition` captures everything that
/// makes one such function DISTINCT as data, hot-loadable from
/// `AppSupport/AgentSmith/evaluators/*.json` with no rebuild. What it deliberately does
/// NOT capture is the live payload (task fields, tool params, candidate lists) — that is
/// runtime state, assembled by typed call sites (e.g. the validation coordinator, which
/// builds the criterion into the system prompt and the evidence as a JSON object) and
/// run through `EvaluationRunner`.
public struct EvaluatorDefinition: Codable, Sendable, Equatable {

    /// What role this function plays. Smith's selection surface only exposes
    /// `.validator`; `approver` and `scoper` are system-reserved (the security gate is
    /// never Smith-selectable), and `prepare` functions feed dynamic validation's
    /// map phase.
    public enum Kind: String, Codable, Sendable {
        case validator
        case approver
        case scoper
        case prepare
    }

    /// One allowed verdict token for the `verdictLine` grammar.
    public struct VerdictSpec: Codable, Sendable, Equatable {
        /// The exact first-word token, conventionally uppercase (e.g. "ACCEPT").
        public let token: String
        /// Whether text must follow the token (e.g. REJECT demands a reason).
        public let requiresReason: Bool

        public init(token: String, requiresReason: Bool) {
            self.token = token
            self.requiresReason = requiresReason
        }
    }

    /// The two output shapes the runner can parse. `verdictLine` covers the
    /// validator/approver family (first line begins with an allowed token);
    /// `jsonArray` covers the scoper and prepare phases (the response must contain a
    /// JSON array, each element becoming one item downstream).
    public enum OutputGrammar: Sendable, Equatable {
        case verdictLine(allowed: [VerdictSpec])
        case jsonArray
    }

    /// Which configured model runs this function. V1 deliberately restricts references
    /// to ROLE SLOTS (no arbitrary provider/model IDs — that needs runtime provider
    /// construction and Keychain plumbing; a "smart validator" simply points at the
    /// `smith` slot). Raw values match the configuration dictionary keys.
    public enum ModelSlot: String, Codable, Sendable {
        case validator
        case summarizer
        case smith
    }

    /// Stable identifier and registry key (kebab-case by convention, e.g.
    /// "default").
    public let name: String
    /// The Smith-facing "when to use" text — this is what selection reads, exactly as
    /// tool descriptions drive tool choice.
    public let description: String
    public let kind: Kind
    public let systemPrompt: String
    public let outputGrammar: OutputGrammar
    public let modelSlot: ModelSlot
    /// Names of tools the function may call during its tool rounds. The read-only
    /// evidence quartet (file_read, directory_listing, grep, glob) is the capped set an
    /// inline/Smith-authored definition may use; anything beyond it requires user
    /// approval of the definition (consent gates capability).
    public let toolNames: [String]
    /// Hard cap on LLM turns within one evaluation (tool rounds count).
    public let maxTurns: Int
    /// Wall-clock budget for one evaluation, checked between turns.
    public let timeoutSeconds: TimeInterval
    public let maxOutputTokens: Int

    public init(
        name: String,
        description: String,
        kind: Kind,
        systemPrompt: String,
        outputGrammar: OutputGrammar,
        modelSlot: ModelSlot,
        toolNames: [String] = [],
        maxTurns: Int = 8,
        timeoutSeconds: TimeInterval = 300,
        maxOutputTokens: Int = 10_000
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.systemPrompt = systemPrompt
        self.outputGrammar = outputGrammar
        self.modelSlot = modelSlot
        self.toolNames = toolNames
        self.maxTurns = maxTurns
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputTokens = maxOutputTokens
    }

    /// A copy under a different name — used when migrating a user-edited copy of a
    /// built-in definition out of the built-in's (reserved) name.
    public func renamed(to newName: String) -> EvaluatorDefinition {
        EvaluatorDefinition(
            name: newName,
            description: description,
            kind: kind,
            systemPrompt: systemPrompt,
            outputGrammar: outputGrammar,
            modelSlot: modelSlot,
            toolNames: toolNames,
            maxTurns: maxTurns,
            timeoutSeconds: timeoutSeconds,
            maxOutputTokens: maxOutputTokens
        )
    }

    /// Load-time validation: a malformed definition must fail when installed, not
    /// mid-task. Returns human-readable problems; empty means valid.
    public func validationProblems() -> [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("name must not be empty")
        }
        if systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("systemPrompt must not be empty")
        }
        if case .verdictLine(let allowed) = outputGrammar {
            if allowed.isEmpty {
                problems.append("verdictLine grammar requires at least one verdict token")
            }
            let tokens = allowed.map(\.token)
            if Set(tokens).count != tokens.count {
                problems.append("verdict tokens must be unique")
            }
            if tokens.contains(where: { $0.contains(" ") || $0.isEmpty }) {
                problems.append("verdict tokens must be single non-empty words")
            }
        }
        if maxTurns < 1 { problems.append("maxTurns must be >= 1") }
        if timeoutSeconds <= 0 { problems.append("timeoutSeconds must be > 0") }
        if maxOutputTokens < 1 { problems.append("maxOutputTokens must be >= 1") }
        return problems
    }

    // MARK: - Codable (OutputGrammar has an associated value, so it's hand-rolled for
    // JSON friendliness: {"type": "verdictLine", "verdicts": [...]} / {"type": "jsonArray"})

    private enum CodingKeys: String, CodingKey {
        case name, description, kind, systemPrompt
        case outputGrammar, modelSlot, toolNames, maxTurns, timeoutSeconds, maxOutputTokens
    }

    private enum GrammarCodingKeys: String, CodingKey {
        case type, verdicts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        kind = try c.decode(Kind.self, forKey: .kind)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        modelSlot = try c.decode(ModelSlot.self, forKey: .modelSlot)
        toolNames = try c.decodeIfPresent([String].self, forKey: .toolNames) ?? []
        maxTurns = try c.decodeIfPresent(Int.self, forKey: .maxTurns) ?? 8
        timeoutSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? 300
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 10_000

        let g = try c.nestedContainer(keyedBy: GrammarCodingKeys.self, forKey: .outputGrammar)
        let type = try g.decode(String.self, forKey: .type)
        switch type {
        case "verdictLine":
            outputGrammar = .verdictLine(allowed: try g.decode([VerdictSpec].self, forKey: .verdicts))
        case "jsonArray":
            outputGrammar = .jsonArray
        default:
            throw DecodingError.dataCorruptedError(
                forKey: GrammarCodingKeys.type, in: g,
                debugDescription: "Unknown output grammar type '\(type)' (expected verdictLine or jsonArray)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(kind, forKey: .kind)
        try c.encode(systemPrompt, forKey: .systemPrompt)
        try c.encode(modelSlot, forKey: .modelSlot)
        try c.encode(toolNames, forKey: .toolNames)
        try c.encode(maxTurns, forKey: .maxTurns)
        try c.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try c.encode(maxOutputTokens, forKey: .maxOutputTokens)
        var g = c.nestedContainer(keyedBy: GrammarCodingKeys.self, forKey: .outputGrammar)
        switch outputGrammar {
        case .verdictLine(let allowed):
            try g.encode("verdictLine", forKey: .type)
            try g.encode(allowed, forKey: .verdicts)
        case .jsonArray:
            try g.encode("jsonArray", forKey: .type)
        }
    }

    /// Stable content hash for pinning: a task records the hash of each definition at
    /// first use so later edits can't silently rewrite what historical (or in-flight)
    /// validation meant.
    public var contentHash: String {
        let payload = [
            name, description, kind.rawValue, systemPrompt, modelSlot.rawValue,
            toolNames.joined(separator: ","),
            String(maxTurns), String(timeoutSeconds), String(maxOutputTokens),
            grammarDescription
        ].joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in payload.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private var grammarDescription: String {
        switch outputGrammar {
        case .verdictLine(let allowed):
            return "verdictLine:" + allowed.map { "\($0.token)\($0.requiresReason ? "!" : "")" }.joined(separator: "|")
        case .jsonArray:
            return "jsonArray"
        }
    }
}
