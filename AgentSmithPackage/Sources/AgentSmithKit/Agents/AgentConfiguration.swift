import Foundation

/// Full configuration for a single agent instance.
struct AgentConfiguration: Sendable {
    /// The agent's role in the system (smith, brown, jones, or summarizer).
    private(set) var role: AgentRole
    /// LLM provider and model parameters for this agent's API calls.
    private(set) var llmConfig: ModelConfiguration
    /// The API type of the provider (for turn record observability).
    private(set) var providerAPIType: ProviderAPIType
    /// The full system prompt injected at the start of every LLM conversation.
    private(set) var systemPrompt: String
    /// Names of tools this agent is allowed to call.
    private(set) var toolNames: [String]
    /// When `true`, all tool calls except messaging and task-lifecycle tools are held for Jones' approval before execution.
    private(set) var requiresToolApproval: Bool
    /// When `true`, raw LLM text responses are not posted to the channel.
    /// The text is still stored in the agent's conversation history and visible in the inspector.
    private(set) var suppressesRawTextToChannel: Bool
    /// How long the agent's idle loop waits before draining pending messages and querying the LLM.
    /// A longer interval causes the agent to batch accumulated messages into a single context update.
    private(set) var pollInterval: TimeInterval
    /// Seconds of channel silence required after a new message before the agent acts.
    private(set) var messageDebounceInterval: TimeInterval
    /// Optional additional filter applied after all routing rules. Return `false` to drop a message
    /// entirely — it will not be added to the agent's pending queue and will not trigger a wake.
    private(set) var messageAcceptFilter: (@Sendable (ChannelMessage) -> Bool)?
    /// Maximum number of tool calls executed per LLM response. Extra calls are dropped with a
    /// channel notice. Exists to prevent runaway tool loops.
    private(set) var maxToolCallsPerIteration: Int

    public init(
        role: AgentRole,
        llmConfig: ModelConfiguration,
        providerAPIType: ProviderAPIType = .openAICompatible,
        systemPrompt: String? = nil,
        toolNames: [String] = [],
        requiresToolApproval: Bool = false,
        suppressesRawTextToChannel: Bool = false,
        pollInterval: TimeInterval = 5,
        messageDebounceInterval: TimeInterval = 1,
        messageAcceptFilter: (@Sendable (ChannelMessage) -> Bool)? = nil,
        maxToolCallsPerIteration: Int = 100
    ) {
        self.role = role
        self.llmConfig = llmConfig
        self.providerAPIType = providerAPIType
        self.systemPrompt = systemPrompt ?? role.baseSystemPrompt
        self.toolNames = toolNames
        self.requiresToolApproval = requiresToolApproval
        self.suppressesRawTextToChannel = suppressesRawTextToChannel
        self.pollInterval = pollInterval
        self.messageDebounceInterval = messageDebounceInterval
        self.messageAcceptFilter = messageAcceptFilter
        self.maxToolCallsPerIteration = maxToolCallsPerIteration
    }
}
