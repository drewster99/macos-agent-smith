import Foundation
import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// The roles shown on the onboarding "review models" screen, in the order the agents
/// are actually used during a task: the orchestrator plans, the worker executes, the
/// security monitor gates each tool call, the validator judges the finished work, and the
/// summarizer records the outcome.
///
/// Not every role is an `AgentRole`: the validator has no `AgentRole` case (it runs on a
/// dedicated model slot, falling back to the summarizer). `agentRole` is nil for it, which
/// the confirm step uses to route its config to `validatorAssignment` instead of
/// `agentAssignments`.
enum OnboardingRole: String, CaseIterable, Identifiable {
    case smith
    case brown
    case securityAgent
    case validator
    case summarizer

    var id: String { rawValue }

    /// The `AgentRole` this maps to, or nil for the validator (which has no `AgentRole`).
    var agentRole: AgentRole? {
        switch self {
        case .smith: return .smith
        case .brown: return .brown
        case .securityAgent: return .securityAgent
        case .summarizer: return .summarizer
        case .validator: return nil
        }
    }

    var title: String {
        switch self {
        case .smith: return "Smith — Orchestrator"
        case .brown: return "Brown — Worker"
        case .securityAgent: return "Security Agent"
        case .validator: return "Validator"
        case .summarizer: return "Summarizer"
        }
    }

    /// Prefix used when naming the configuration this role creates. For the four `AgentRole`
    /// roles it matches `AgentRole.displayName` so the load-time auto-heal can re-bind a role
    /// to its config by name after a catalog reshuffle.
    var configNamePrefix: String {
        switch self {
        case .smith: return "Smith"
        case .brown: return "Brown"
        case .securityAgent: return "Security Agent"
        case .validator: return "Validator"
        case .summarizer: return "Summarizer"
        }
    }

    /// One-line description plus a consideration to help the user pick a model.
    var considerations: String {
        switch self {
        case .smith:
                   """
                   Agent Smith is strong and capable manager of your team and generally benefits from a strong reasoning model.
                   
                   All your communication is with Smith. He organizes, tracks and manages your requests, \
                   flushing out details, steps to be performed and detailed final acceptance requirements. He'll track the progress of the worker assigned to your task and \
                   help resolve any issues that arise. If you have questions or it if it looks like things are going sidewise, shoot Smith a message. Smith can also \
                   help you set up recurring tasks, create templates, or find information in old tasks. If you have any hard and fast rules, just tell Smith and \
                   he'll add a new memory so things go smoother in the future.
                   
                   Smith generally has read-only access to things outside of the Agent Smith app, though he can create, start, stop, schedule and modify tasks and \
                   perform other administrative tasks within the app. When it's time to get to work, he'll orchestrate everything but will assign a fresh Agent Brown \
                   to get it done.
                   
                   Each session will only ever have a single active Agent Smith, but he can manage a number of tasks at the same time.
                   """
        case .brown:
                   """
                   Agent Brown is your dedicated and diligent worker and does best with a strong capable model with good parallel tool use.
                   
                   He'll usually be the one sarching files, making edits, fetching from the web, writing code, and \
                   otherwise doing the majority of the work in the tasks you want done. \
                   Every time a task is started, an Agent Brown is assigned to work on that task. His entire world exists in that task - title, description, \
                   todo list, and deliverables.
                   
                   While Agent Smith will usually make an initial to-do list when the task is created, once the task is in progress, Agent Brown owns \
                   the list and will keep it updated as he works. Watching the to-do list is an easy way to see how things are going. \
                   When he believes everything is done, he'll submit his work to be reviewed by the Validator agent team.
                   """
        case .securityAgent:
                   """
                   The Security Agent is a safety net to help ensure that bad things don't happen and should generally be driven by a smart but fast model.
                   
                   Security's job is to make decisions about which tool calls are acceptable and which are not. 
                   
                   Tool calls are how everything gets done. \
                   Agent Smith makes tool calls to manage tasks and read files. Agent Brown uses tools for -- essentially everything.
                   
                   Before work begins on a task, a Security Agent will review the task and all the tools and MCP servers that are configured in the app, \
                   and put together the precise combination of tools that will be made available to the Agent Brown that's assigned to work on the task. \
                   If the list of MCP servers or tools changes while a task ongoing, Security will re-evaluate and possibly update the approved tools list. \
                   The goal here is to authorize only the set of tools that will probably be needed and that with which Agent Brown will have a high likelihood \
                   of being able to complete the task.
                   
                   But that's just the starting point. Every time an agent makes a tool call, a Security Agent will evaluate that specific tool call and its \
                   parameters, in order to determine if the call is appropriate. In general, "appropriate" means unlikely to cause data loss AND closely \
                   aligned with your intent and goals -- as described by the task. For each attempted tool call, a Security Agent will respond with \
                   accept, warn or block. When responding with a warning or a block, additional detail and guidance will be provided to the tool-calling agent.
                   
                   There may be several Security Agent instances active at any one time.
                   """
        case .validator:
                   """
                   Validation Agents are the gate-keepers of quality who make the final decision as to if a task is really finished.
                   
                   When an Agent Brown submits work he believes to be complete, the completed work will be assigned to parallel Validation agents, who \
                   carefully review the work against each pre-determined acceptance requirement. Each task will have 1 or more such requirements. \
                   In general, acceptance criteria are written such that the work-completing agent (Brown) must prove that the work actually got done. \
                   This might be a screenshot or a file or something else. The acceptance criteria will explicitly spell out exactly what sort of proof \
                   will be accepted.
                   
                   If any work items / deliverables / requirements are not acceptable, the result will be partly or wholly rejected and returned, \
                   with specific feedback, to the worker agent Brown.
                   
                   A capable mid-tier model keeps validation accurate.
                   """
        case .summarizer:
                   """
                   Writes short summaries of completed and failed tasks. A fast, inexpensive model is a great fit.
                   """
        }
    }

    var accentColor: Color {
        switch self {
        case .smith: return AppColors.smithAgent
        case .brown: return AppColors.brownAgent
        case .securityAgent: return AppColors.securityAgent
        case .validator: return .purple
        case .summarizer: return .secondary
        }
    }

    /// Generation cap for configs this role creates during onboarding. The orchestrator and
    /// worker produce longer output; the reviewer roles are terse. The runtime clamps these
    /// down if a model reports a lower ceiling, so a generous value here is safe.
    var maxOutputTokens: Int {
        switch self {
        case .smith, .brown: return 8192
        case .securityAgent, .validator, .summarizer: return 4096
        }
    }

    /// Conversation-pruning budget for configs this role creates during onboarding.
    var maxContextTokens: Int { 128_000 }
}

/// A tested per-provider mapping of each onboarding role to a recommended model. Authored by
/// us so a user who pastes one key reaches a working setup without knowing any model IDs. When
/// a recommended ID isn't in the provider's live catalog, the review screen flags that row and
/// makes the user pick — the rest stay pre-filled.
struct ProviderProfile: Identifiable {
    /// The built-in provider ID this profile targets (e.g. `builtin.anthropic`).
    let providerID: String
    let displayName: String
    /// Whether the provider needs an API key (false for local providers like Ollama).
    let requiresAPIKey: Bool
    /// Where the user gets a key, shown as a link on the provider screen.
    let keyConsoleURL: URL?
    /// Recommended model ID per role. Resolved against the live catalog with a prefix/contains
    /// fallback so date-suffixed variants (e.g. `claude-…-20260101`) still match.
    let recommendedModels: [OnboardingRole: String]

    var id: String { providerID }

    /// The four providers we ship tested defaults for, in the order shown in the picker.
    static let all: [ProviderProfile] = [anthropic, openAI, gemini, ollama]

    static func profile(forProviderID providerID: String) -> ProviderProfile? {
        all.first { $0.providerID == providerID }
    }

    static let anthropic = ProviderProfile(
        providerID: BuiltInProviders.ID.anthropic,
        displayName: "Anthropic",
        requiresAPIKey: true,
        keyConsoleURL: URL(string: "https://console.anthropic.com/settings/keys"),
        recommendedModels: [
            .smith: "claude-opus-4-8",
            .brown: "claude-sonnet-5",
            .securityAgent: "claude-haiku-4-5",
            .validator: "claude-sonnet-5",
            .summarizer: "claude-haiku-4-5"
        ]
    )

    static let openAI = ProviderProfile(
        providerID: BuiltInProviders.ID.openai,
        displayName: "OpenAI",
        requiresAPIKey: true,
        keyConsoleURL: URL(string: "https://platform.openai.com/api-keys"),
        recommendedModels: [
            .smith: "gpt-5.5",
            .brown: "gpt-5.5",
            .securityAgent: "gpt-5.4-mini",
            .validator: "gpt-5.4",
            .summarizer: "gpt-5.4-nano"
        ]
    )

    static let gemini = ProviderProfile(
        providerID: BuiltInProviders.ID.gemini,
        displayName: "Google Gemini",
        requiresAPIKey: true,
        keyConsoleURL: URL(string: "https://aistudio.google.com/apikey"),
        recommendedModels: [
            .smith: "gemini-3.1-pro-preview",
            .brown: "gemini-3.1-pro-preview",
            .securityAgent: "gemini-3.5-flash",
            .validator: "gemini-3.5-flash",
            .summarizer: "gemini-3.1-flash-lite-preview"
        ]
    )

    static let ollama = ProviderProfile(
        providerID: BuiltInProviders.ID.ollama,
        displayName: "Ollama (local)",
        requiresAPIKey: false,
        keyConsoleURL: URL(string: "https://ollama.com/library"),
        // Ollama models are whatever the user has pulled locally, so these are popular picks
        // rather than guaranteed-present IDs — unresolved rows go red and prompt a pick from the
        // installed models.
        recommendedModels: [
            .smith: "qwen2.5:32b",
            .brown: "qwen2.5-coder:32b",
            .securityAgent: "llama3.1:8b",
            .validator: "qwen2.5:14b",
            .summarizer: "llama3.1:8b"
        ]
    )

    /// Resolves a recommended model ID against a live catalog. Tries an exact match first, then
    /// a prefix match (for date-suffixed variants), then a loose contains match. Returns the
    /// actual catalog `modelID` to use, or nil when nothing matches (the row goes red).
    static func resolveModelID(_ wanted: String, in catalog: [ModelInfo]) -> String? {
        if let exact = catalog.first(where: { $0.modelID == wanted }) {
            return exact.modelID
        }
        let lowerWanted = wanted.lowercased()
        if let prefix = catalog.first(where: { $0.modelID.lowercased().hasPrefix(lowerWanted) }) {
            return prefix.modelID
        }
        if let contains = catalog.first(where: { $0.modelID.lowercased().contains(lowerWanted) }) {
            return contains.modelID
        }
        return nil
    }
}
