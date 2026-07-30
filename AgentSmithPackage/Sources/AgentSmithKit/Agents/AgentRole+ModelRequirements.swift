import Foundation
import SwiftLLMKit

// Bridges the app's fixed cast of agent roles to swift-llm-kit's capability/availability filter.
// Each role declares — in one readable value — the capabilities a model MUST have, the ones it must
// NOT have, and which special availability states it tolerates. `LLMKitManager.availableModels(_:)`
// then does ALL filtering at query time; nothing is ever dropped from the catalog itself.
//
// FIRST DRAFT — tune the per-role sets. Two judgment calls are flagged inline:
//   (a) securityAgent / validator emit text/grammar verdicts but use tool calls to GATHER evidence;
//       requiring `.toolUse` filters a non-tool model out of those slots. Keep or relax?
//   (b) `.toolUse` is a plain Bool today (unknown == false), so requiring it also excludes every
//       model no probe/LiteLLM has confirmed tool use for. That may be stricter than intended until
//       more of the catalog is probed.

extension AgentRole {
    /// What a model must satisfy to back this role. The three fields are exactly the arguments to
    /// ``SwiftLLMKit/LLMKitManager/availableModels(requiredCapabilities:mustNotBePresent:alsoIncludingAvailabilityStates:)``.
    public var modelRequirements: ModelRequirements {
        switch self {
        case .smith:
            // Orchestrator: every turn is tool-driven (create_task, notify_brown, manage_steps,
            // set_acceptance_criteria, scheduling, memory). Tool use is a hard requirement.
            return ModelRequirements(requiredCapabilities: [.toolUse])
        case .brown:
            // Worker: holds bash/file/process tools and cannot do the work without them.
            return ModelRequirements(requiredCapabilities: [.toolUse])
        case .securityAgent:
            // Text-based verdicts, but gathers evidence via read-only tool calls (file_read,
            // attach_file). (a) above: requiring `.toolUse` excludes a pure-text model here.
            return ModelRequirements(requiredCapabilities: [.toolUse])
        case .summarizer:
            // Reads a transcript, writes a summary. No tools — no capability floor.
            return ModelRequirements()
        case .validator:
            // Acceptance judge: allowlisted read-only evidence tools (file_read, directory_listing,
            // grep, glob) then a grammar-parsed verdict. Same flag (a) as securityAgent.
            return ModelRequirements(requiredCapabilities: [.toolUse])
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
