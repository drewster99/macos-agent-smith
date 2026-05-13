import Foundation
import SwiftLLMKit

/// Metadata the caller provides to describe the context of an LLM call.
/// Separates "what the caller knows" from "what the response contains."
struct LLMCallContext: Sendable {
    let agentRole: AgentRole
    let taskID: UUID?
    let modelID: String
    let providerType: String
    let providerID: String?
    /// Full snapshot of the ModelConfiguration used for this call. Captured here
    /// rather than just its ID so historical records remain accurate even if the
    /// source config is later deleted or edited.
    let configuration: ModelConfiguration?
    let sessionID: UUID?
    let preResetInputTokens: Int?
    /// Wall-clock milliseconds spent executing tools this turn's response requested.
    /// Zero when the response had no tool calls or when the caller doesn't run tools.
    let totalToolExecutionMs: Int
    /// Total characters across all tool result strings returned from this turn's tool calls.
    let totalToolResultChars: Int

    public init(
        agentRole: AgentRole,
        taskID: UUID?,
        modelID: String,
        providerType: String,
        providerID: String?,
        configuration: ModelConfiguration?,
        sessionID: UUID?,
        preResetInputTokens: Int? = nil,
        totalToolExecutionMs: Int = 0,
        totalToolResultChars: Int = 0
    ) {
        self.agentRole = agentRole
        self.taskID = taskID
        self.modelID = modelID
        self.providerType = providerType
        self.providerID = providerID
        self.configuration = configuration
        self.sessionID = sessionID
        self.preResetInputTokens = preResetInputTokens
        self.totalToolExecutionMs = totalToolExecutionMs
        self.totalToolResultChars = totalToolResultChars
    }
}

/// Records LLM token usage to a ``UsageStore`` given a response and caller context.
///
/// All LLM callers should use this after every `provider.send()` call to ensure
/// consistent usage tracking across the entire app.
enum UsageRecorder {
    /// Records usage from an LLM response, if token usage data is present.
    ///
    /// No-op if `response.usage` is nil (e.g. local models that don't report tokens).
    public static func record(
        response: LLMResponse,
        context: LLMCallContext,
        latencyMs: Int,
        to store: UsageStore
    ) async {
        guard let usage = response.usage else { return }

        // Derive response-side fields that are free to compute from the LLMResponse.
        let outputCharCount = response.text?.count ?? 0
        let toolCallCount = response.toolCalls.count
        let toolCallNames = response.toolCalls.map(\.name)
        let toolCallArgumentsChars = response.toolCalls.reduce(0) { $0 + $1.arguments.count }

        await store.append(UsageRecord(
            agentRole: context.agentRole,
            taskID: context.taskID,
            modelID: context.modelID,
            providerType: context.providerType,
            providerID: context.providerID,
            configuration: context.configuration,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens,
            latencyMs: latencyMs,
            preResetInputTokens: context.preResetInputTokens,
            outputCharCount: outputCharCount,
            toolCallCount: toolCallCount,
            toolCallNames: toolCallNames,
            toolCallArgumentsChars: toolCallArgumentsChars,
            totalToolExecutionMs: context.totalToolExecutionMs,
            totalToolResultChars: context.totalToolResultChars,
            sessionID: context.sessionID,
            rawUsage: usage.rawUsage
        ))
    }
}
