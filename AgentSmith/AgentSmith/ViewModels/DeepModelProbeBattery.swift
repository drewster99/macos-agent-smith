import Foundation
import SwiftLLMKit

/// Extends the ordinary model probe with every safe, applicable probe supported by SwiftLLMKit.
@MainActor
enum DeepModelProbeBattery {
    static func probing(
        _ initial: ModelProfile,
        llm: any LLMProvider,
        provider: ModelProvider,
        modelID: String,
        kit: LLMKitManager
    ) async -> ModelProfile {
        var profile = initial
        guard profile.chat.value == true else { return profile }
        let started = Date()

        let catalog = kit.modelInfo(providerID: provider.id, modelID: modelID)
        let forcing: @MainActor @Sendable ([String: AnyCodable]) async -> any LLMProvider = { overrides in
            // Keep the standard probe's guardrails while forcing the one raw parameter under
            // test. In particular, omit parallel_tool_calls so its rejection cannot poison an
            // otherwise unrelated reasoning, response-format, or tool-choice measurement.
            kit.makeProbeProvider(
                configuration: ModelConfiguration(
                    name: "deep-probe:\(modelID)", providerID: provider.id, modelID: modelID,
                    temperature: nil, maxOutputTokens: 512, streaming: false,
                    extraJSONOverrides: overrides),
                provider: provider)
        }

        if provider.apiType != .anthropic {
            for level in EffortRank.allKnown where profile.reasoningEffortLevels[level] == nil {
                let forced = await forcing(ReasoningControl.reasoningEffortOverrides(
                    level: level, for: provider.apiType))
                profile.reasoningEffortLevels[level] = await ModelProber.probeParameterAcceptance(
                    llm: forced, parameterDescription: "reasoning_effort=\(level)",
                    rejectionKeywords: ["reasoning_effort", "reasoning", "effort"])
                profile.callCount += 1
            }
        }

        let formats: [LLMResponseFormat] = [
            .jsonObject,
            .jsonSchema(name: "probe", schema: CapabilityProbe.probeResponseSchema)
        ]
        for format in formats where profile[format.requiredCapability] == nil {
            guard let finding = await ModelProber.probeStructuredOutput(
                format, apiType: provider.apiType, makeProviderForcing: forcing) else { continue }
            profile[format.requiredCapability] = finding
            profile.callCount += 1
        }

        if profile[.reasoningCanBeEnabled] == nil || profile[.reasoningCanBeDisabled] == nil {
            let calls = ProbeCallCounter()
            let found = await ModelProber.probeReasoningMechanism(
                apiType: provider.apiType, makeProviderForcing: forcing, calls: calls)
            profile.callCount += calls.value
            if let control = found.control, found.mechanismWasEstablished {
                profile.reasoningControl = .established(control, "deep probe established \(control.editorTitle)")
            }
            let conclusions = ModelProber.concludeReasoning(
                on: found.on, off: found.off, mechanism: found.control)
            keepBetter(found.on.finding, for: .reasoningCanBeEnabled, in: &profile)
            keepBetter(conclusions.canBeDisabled, for: .reasoningCanBeDisabled, in: &profile)
            if profile[.reasoning] == nil, conclusions.reasons.status == .established {
                profile[.reasoning] = conclusions.reasons
            }
        }

        let mechanism = profile.reasoningControl?.value ?? catalog?.reasoningControl
        let disableReasoning = profile[.reasoningCanBeDisabled]?.value == false
            ? nil : mechanism.flatMap { $0.reasoningDisableOverrides(for: provider.apiType) }
        let choices: [LLMToolChoice] = [
            .required, .textOnly, .specific(name: CapabilityProbe.probeToolName)
        ]
        for choice in choices where profile[choice.requiredCapability] == nil {
            guard let finding = await ModelProber.probeToolChoice(
                choice, apiType: provider.apiType, disableReasoningWith: disableReasoning,
                makeProviderForcing: forcing) else { continue }
            profile[choice.requiredCapability] = finding
            profile.callCount += 1
        }

        if profile[.thinkingSupportsKeepAll] == nil {
            let calls = ProbeCallCounter()
            if let finding = await ModelProber.probeThinkingKeep(
                reasoningControl: mechanism, acceptedThinkingBlock: false,
                makeProviderForcing: forcing, calls: calls) {
                profile[.thinkingSupportsKeepAll] = finding
            }
            profile.callCount += calls.value
        }
        if profile[.toolDefinitionsSupportStrict] == nil,
           let finding = await ModelProber.probeStrictToolDefinitions(
               apiType: provider.apiType, makeProviderForcing: forcing) {
            profile[.toolDefinitionsSupportStrict] = finding
            profile.callCount += 1
        }
        if profile[.systemMessages] == nil {
            profile[.systemMessages] = await ModelProber.probeSystemMessages(llm: llm)
            profile.callCount += 1
        }
        if profile[.assistantPrefill] == nil {
            profile[.assistantPrefill] = await ModelProber.probeAssistantPrefill(llm: llm)
            profile.callCount += 1
        }
        if profile[.parallelToolCalls] == nil, profile.toolCalling.value != false {
            profile[.parallelToolCalls] = await ModelProber.probeParallelToolCalls(llm: llm)
            profile.callCount += 1
        }

        let reasons = profile[.reasoning]?.value == true
        let vendorClaimsBudget = catalog?.capabilities.state(of: .thinkingSupportsTokenBudget) == true
        if profile.maxThinkingBudgetTokens == nil,
           profile[.thinkingSupportsTokenBudget]?.value != false,
           reasons || vendorClaimsBudget,
           let mechanism, mechanism.carriesTokenBudget {
            let calls = ProbeCallCounter()
            profile.maxThinkingBudgetTokens = await ModelProber.probeThinkingBudgetRange(
                accounting: catalog?.thinkingBudgetAccounting,
                maxOutputTokens: profile.maxOutputTokens.value ?? catalog?.maxOutputTokens,
                maxContextTokens: profile.maxContextTokens.value ?? catalog?.maxInputTokens,
                makeProviderWithBudget: { budget, pairedMax in
                    await forcing(mechanism.budgetForcingOverrides(
                        budget: budget, pairedMaxTokens: pairedMax) ?? [:])
                }, calls: calls)
            profile.callCount += calls.value
            if profile.minThinkingBudgetTokens == nil,
               let accepted = profile.maxThinkingBudgetTokens?.value, accepted > 0 {
                let minimumCalls = ProbeCallCounter()
                profile.minThinkingBudgetTokens = await ModelProber.probeThinkingBudgetMinimum(
                    knownAcceptedBudget: accepted,
                    makeProviderWithBudget: { budget, pairedMax in
                        await forcing(mechanism.budgetForcingOverrides(
                            budget: budget, pairedMaxTokens: pairedMax) ?? [:])
                    }, calls: minimumCalls)
                profile.callCount += minimumCalls.value
            }
        }
        profile.duration += Date().timeIntervalSince(started)
        return profile
    }

    private static func keepBetter(
        _ candidate: ProbeFinding<Bool>,
        for capability: ModelCapability,
        in profile: inout ModelProfile
    ) {
        guard profile[capability]?.status != .established || candidate.status == .established else { return }
        profile[capability] = candidate
    }
}
