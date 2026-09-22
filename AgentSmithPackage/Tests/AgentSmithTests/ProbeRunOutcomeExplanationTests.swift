import AgentSmithKit
import SwiftLLMKit
import Testing

@Suite("Probe run outcome explanations")
struct ProbeRunOutcomeExplanationTests {
    @Test("A failed first live call surfaces the provider's explanation")
    func firstLiveCallFailureIsShown() {
        var profile = ModelProfile(providerID: "lm-studio", modelID: "gemma")
        profile.chat = .inconclusive("Failed to load model: insufficient system resources")
        profile.acceptsTemperature = .inconclusive("same request failed before temperature was graded")

        #expect(ProbeRunOutcomeExplanation.noStoredFindingsReason(for: profile)
                == "Failed to load model: insufficient system resources")
    }

    @Test("A genuinely empty profile retains the generic explanation")
    func emptyProfileUsesFallback() {
        let profile = ModelProfile(providerID: "p", modelID: "m")

        #expect(ProbeRunOutcomeExplanation.noStoredFindingsReason(for: profile)
                == "no established probed findings")
    }
}
