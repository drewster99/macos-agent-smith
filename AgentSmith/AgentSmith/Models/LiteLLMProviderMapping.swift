import SwiftLLMKit

/// Provider-mapping values owned by Agent Smith rather than LiteLLM's catalog.
enum LiteLLMProviderMapping {
    /// The provider is intentionally local and has no LiteLLM metadata source.
    static let local = "LOCAL"

    static func isLocal(_ provider: ModelProvider) -> Bool {
        provider.liteLLMProviderName == local
    }
}
