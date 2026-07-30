import Foundation
import SwiftLLMKit

// Bridges the app's fixed cast of agent roles to swift-llm-kit's capability/availability filter.
// Each role declares — in one readable value — the capabilities a model MUST have, the ones it must
// NOT have, and which special availability states it tolerates. `LLMKitManager.availableModels(_:)`
// then does ALL filtering at query time; nothing is ever dropped from the catalog itself.
//
// Capabilities are TRI-STATE, so a requirement rejects only a model KNOWN to lack it — an unprobed
// model is never hidden. That is why `.toolUse` can be required even for the evidence-gathering
// roles (securityAgent, validator): it excludes only models the catalog has confirmed can't call
// tools, not the large unprobed tail. Every role requires `.chat` (all agents talk to the chat
// endpoint), and every role tolerates FUTURE-deprecated models (still usable, going away later)
// while excluding unavailable / access-denied / already-deprecated ones.

extension AgentRole {
    /// What a model must satisfy to back this role. The three fields are exactly the arguments to
    /// ``SwiftLLMKit/LLMKitManager/availableModels(requiredCapabilities:mustNotBePresent:alsoIncludingAvailabilityStates:)``.
    public var modelRequirements: ModelRequirements {
        // Every role talks to the chat endpoint and accepts a model that is scheduled for a future
        // deprecation but still live.
        let tolerated: Set<ModelAvailabilityState> = [.isFutureDeprecated]
        switch self {
        case .smith, .brown:
            // Orchestrator and worker are entirely tool-driven and cannot function without tools.
            return ModelRequirements(requiredCapabilities: [.chat, .toolUse], includedAvailabilityStates: tolerated)
        case .securityAgent, .validator:
            // Text/grammar verdicts, but both gather evidence via read-only tool calls. Requiring
            // `.toolUse` (tri-state) excludes only models KNOWN to lack tools, never the unprobed.
            return ModelRequirements(requiredCapabilities: [.chat, .toolUse], includedAvailabilityStates: tolerated)
        case .summarizer:
            // Reads a transcript, writes a summary. No tools — chat is the only floor.
            return ModelRequirements(requiredCapabilities: [.chat], includedAvailabilityStates: tolerated)
        }
    }
}

extension LLMKitManager {
    /// The catalog models that satisfy `role`'s ``AgentRole/modelRequirements``. The app-side
    /// counterpart to the capability-argument overloads on ``LLMKitManager`` — a picker for a given
    /// role asks the role, not a hand-rolled predicate, what it may show.
    public func availableModels(_ role: AgentRole) -> [ModelInfo] {
        availableModels(role.modelRequirements)
    }
}
