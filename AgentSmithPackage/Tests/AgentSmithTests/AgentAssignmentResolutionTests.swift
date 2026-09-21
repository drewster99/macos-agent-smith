import Testing
import Foundation
@testable import AgentSmithKit

/// Loading a session must never delete the assignments it just loaded.
///
/// On 2026-09-20 it did: the prune this replaced cleared any assignment whose provider was not in
/// the configured list, guarded only by "the list is not EMPTY". A partially loaded list passes
/// that guard, so the providers that had arrived kept their roles while the ones still loading had
/// theirs deleted — and the caller persists, making it permanent. Three Codex assignments and a
/// DeepSeek validator were replaced by Anthropic defaults with no record of what had been there.
@Suite("Agent assignment resolution")
struct AgentAssignmentResolutionTests {

    private let codexSmith = ModelAssignment(providerID: "builtin.codex-chatgpt", modelID: "gpt-5.6-sol")
    private let codexBrown = ModelAssignment(providerID: "builtin.codex-chatgpt", modelID: "gpt-6-astra")
    private let deepseekValidator = ModelAssignment(providerID: "builtin.deepseek", modelID: "deepseek-flash")
    private let anthropicSummarizer = ModelAssignment(providerID: "builtin.anthropic", modelID: "claude-sonnet-5")

    private var defaults: [AgentRole: ModelAssignment] {
        [
            .smith: ModelAssignment(providerID: "builtin.anthropic", modelID: "claude-opus-4-8"),
            .brown: ModelAssignment(providerID: "builtin.anthropic", modelID: "claude-sonnet-5"),
            .securityAgent: ModelAssignment(providerID: "builtin.anthropic", modelID: "claude-haiku-4-5"),
            .summarizer: ModelAssignment(providerID: "builtin.anthropic", modelID: "claude-haiku-4-5"),
            .validator: ModelAssignment(providerID: "builtin.anthropic", modelID: "claude-sonnet-5")
        ]
    }

    /// The exact 2026-09-20 shape: Anthropic had loaded, Codex and DeepSeek had not.
    @Test("A partially loaded provider list never deletes an assignment")
    func partialProviderListKeepsEverything() {
        let saved: [AgentRole: ModelAssignment] = [
            .smith: codexSmith, .brown: codexBrown,
            .validator: deepseekValidator, .summarizer: anthropicSummarizer
        ]
        let result = AgentAssignmentResolution.resolve(
            saved: saved,
            configuredProviderIDs: ["builtin.anthropic"],   // the stragglers have not arrived
            defaults: defaults
        )

        // Every saved choice survives, byte for byte.
        #expect(result.assignments[.smith] == codexSmith)
        #expect(result.assignments[.brown] == codexBrown)
        #expect(result.assignments[.validator] == deepseekValidator)
        #expect(result.assignments[.summarizer] == anthropicSummarizer)

        // …and the three whose providers are missing are REPORTED rather than removed.
        #expect(Set(result.unavailable.keys) == [.smith, .brown, .validator])
        #expect(result.unavailable[.smith] == codexSmith)
    }

    /// The resolution is only ever additive — the property that makes deletion unrepresentable.
    @Test("The result is always a superset of what was saved")
    func resultIsAlwaysASuperset() {
        let saved: [AgentRole: ModelAssignment] = [.smith: codexSmith, .brown: codexBrown]
        for providers in [Set<String>(), ["builtin.anthropic"], ["builtin.codex-chatgpt"],
                          ["builtin.anthropic", "builtin.codex-chatgpt", "builtin.deepseek"]] {
            let result = AgentAssignmentResolution.resolve(
                saved: saved, configuredProviderIDs: providers, defaults: defaults
            )
            for (role, assignment) in saved {
                #expect(result.assignments[role] == assignment,
                        "\(role.rawValue) changed with providers \(providers)" as Comment)
            }
        }
    }

    /// The role that was never healed, because healing walked `requiredRoles` and the validator is
    /// deliberately outside it. Its absence parks every submitted task unresolvably.
    @Test("An absent validator is healed, even though it is not a required role")
    func validatorIsHealed() {
        #expect(AgentRole.requiredRoles.contains(.validator) == false, "premise: validator is not required")

        let result = AgentAssignmentResolution.resolve(
            saved: [.smith: codexSmith],
            configuredProviderIDs: ["builtin.anthropic", "builtin.codex-chatgpt"],
            defaults: defaults
        )
        #expect(result.assignments[.validator] == defaults[.validator])
        #expect(result.healed[.validator] == defaults[.validator])
    }

    @Test("Every role with a default is healed when absent")
    func everyRoleIsHealed() {
        let result = AgentAssignmentResolution.resolve(
            saved: [:], configuredProviderIDs: ["builtin.anthropic"], defaults: defaults
        )
        #expect(Set(result.assignments.keys) == Set(AgentRole.allCases))
        #expect(result.unavailable.isEmpty)
    }

    /// Healing fills; it must never overwrite. This is what separates it from the prune.
    @Test("Healing does not touch a role that already has an assignment")
    func healingNeverOverwrites() {
        let result = AgentAssignmentResolution.resolve(
            saved: [.smith: codexSmith],
            configuredProviderIDs: ["builtin.anthropic", "builtin.codex-chatgpt"],
            defaults: defaults
        )
        #expect(result.assignments[.smith] == codexSmith)
        #expect(result.healed[.smith] == nil)
    }

    /// A default pointing at an unconfigured provider is not usable, so the role stays empty and
    /// the UI asks — rather than binding to an arbitrary provider that happens to be loaded.
    @Test("A default whose own provider is unconfigured does not heal")
    func unusableDefaultDoesNotHeal() {
        let result = AgentAssignmentResolution.resolve(
            saved: [:], configuredProviderIDs: ["builtin.deepseek"], defaults: defaults
        )
        #expect(result.assignments.isEmpty)
        #expect(result.healed.isEmpty)
    }

    /// Zero providers almost always means the catalog has not loaded, not that the user deleted
    /// every provider. Flagging all of them would be the same false signal in a louder voice —
    /// and there is nothing to heal to either.
    @Test("An empty provider list reports nothing and heals nothing")
    func emptyProviderListIsInconclusive() {
        let saved: [AgentRole: ModelAssignment] = [.smith: codexSmith, .validator: deepseekValidator]
        let result = AgentAssignmentResolution.resolve(
            saved: saved, configuredProviderIDs: [], defaults: defaults
        )
        #expect(result.assignments == saved)
        #expect(result.unavailable.isEmpty, "the catalog not having loaded is not evidence of staleness")
        #expect(result.healed.isEmpty)
    }

    /// An assignment with no model is as unusable as one with no provider, and is reported the
    /// same way — but still not deleted.
    @Test("An empty modelID reads as unavailable, and is still kept")
    func emptyModelIsUnavailableButKept() {
        let blank = ModelAssignment(providerID: "builtin.anthropic", modelID: "")
        let result = AgentAssignmentResolution.resolve(
            saved: [.brown: blank], configuredProviderIDs: ["builtin.anthropic"], defaults: defaults
        )
        #expect(result.assignments[.brown] == blank)
        #expect(result.unavailable[.brown] == blank)
        #expect(result.healed[.brown] == nil, "a present-but-blank assignment is not an empty slot")
    }

    /// Nothing to report when everything resolves — the quiet path stays quiet.
    @Test("A fully configured session reports nothing")
    func fullyConfiguredIsSilent() {
        let saved: [AgentRole: ModelAssignment] = [
            .smith: codexSmith, .brown: codexBrown, .securityAgent: codexSmith,
            .summarizer: anthropicSummarizer, .validator: deepseekValidator
        ]
        let result = AgentAssignmentResolution.resolve(
            saved: saved,
            configuredProviderIDs: ["builtin.anthropic", "builtin.codex-chatgpt", "builtin.deepseek"],
            defaults: defaults
        )
        #expect(result.assignments == saved)
        #expect(result.unavailable.isEmpty)
        #expect(result.healed.isEmpty)
    }
}
