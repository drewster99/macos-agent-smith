import SwiftLLMKit

/// Presentation-ready provenance for the resolved per-response output ceiling. The value always
/// comes from `ModelConfigurationOverride.resolved`, while `source` explains which resolver layer
/// supplied it so settings never present a fallback as a model-reported fact.
struct EffectiveOutputLimitDisplay: Equatable {
    enum Source: Equatable {
        case explicitOverride
        case modelMetadata
        case contextFallback(contextTokens: Int)
    }

    let tokens: Int
    let source: Source

    init(override: ModelConfigurationOverride, modelInfo: ModelInfo) {
        let resolved = override.resolved(against: modelInfo, name: modelInfo.displayName)
        tokens = resolved.maxOutputTokens

        if override.maxOutputTokens != nil {
            source = .explicitOverride
        } else if modelInfo.maxOutputTokens != nil {
            source = .modelMetadata
        } else {
            source = .contextFallback(contextTokens: resolved.maxContextTokens)
        }
    }
}
