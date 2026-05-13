import Foundation

/// Records a single LLM request/response turn for per-turn inspection.
public struct LLMTurnRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    /// New messages added to conversationHistory since the previous turn.
    public let inputDelta: [LLMMessage]
    /// The full response from the LLM.
    public let response: LLMResponse
    /// Total message count in history when this call was made (for reference).
    public let totalMessageCount: Int
    /// Snapshot of the full message array sent to the LLM for this turn.
    /// Stripped to an empty array on older turns to avoid O(n^2) memory growth.
    public private(set) var contextSnapshot: [LLMMessage]
    /// Wall-clock time for the LLM API call, in milliseconds.
    public let latencyMs: Int

    // MARK: - Model / Configuration Info

    /// The model ID used for this turn (e.g. "claude-sonnet-4-20250514", "gpt-4o").
    public let modelID: String
    /// The provider type name (e.g. "anthropic", "openAICompatible", "ollama") — wire
    /// protocol family.
    public let providerType: String
    /// Stable provider identifier (e.g. "anthropic", "openrouter") — needed for
    /// pricing lookup since `providerType` alone can't disambiguate Anthropic-direct
    /// from OpenRouter-via-Anthropic-protocol. Optional only for records constructed
    /// in older test fixtures that pre-date this field.
    public let providerID: String?
    /// Temperature setting used for this turn.
    public let temperature: Double
    /// Max output tokens configured for this turn.
    public let maxOutputTokens: Int
    /// Thinking budget configured for this turn (Anthropic only), nil if disabled.
    public let thinkingBudget: Int?
    /// Token usage reported by the provider for this turn, if available.
    public let usage: TokenUsage?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        inputDelta: [LLMMessage],
        response: LLMResponse,
        totalMessageCount: Int,
        contextSnapshot: [LLMMessage] = [],
        latencyMs: Int = 0,
        modelID: String = "",
        providerType: String = "",
        providerID: String? = nil,
        temperature: Double = 0,
        maxOutputTokens: Int = 0,
        thinkingBudget: Int? = nil,
        usage: TokenUsage? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.inputDelta = inputDelta
        self.response = response
        self.totalMessageCount = totalMessageCount
        self.contextSnapshot = contextSnapshot
        self.latencyMs = latencyMs
        self.modelID = modelID
        self.providerType = providerType
        self.providerID = providerID
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.thinkingBudget = thinkingBudget
        self.usage = usage
    }

    /// Releases the heavy context snapshot to reclaim memory on older turn records.
    public mutating func stripContextSnapshot() {
        contextSnapshot = []
    }
}
