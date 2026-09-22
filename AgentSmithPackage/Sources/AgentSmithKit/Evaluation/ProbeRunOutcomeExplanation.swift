import SwiftLLMKit

/// Turns a probe-empty run into the most actionable explanation the probe recorded.
public enum ProbeRunOutcomeExplanation {
    public static func noStoredFindingsReason(for profile: ModelProfile) -> String {
        for finding in [profile.chat, profile.acceptsTemperature]
        where finding.status == .inconclusive {
            if let evidence = finding.evidence, !evidence.isEmpty {
                return evidence
            }
        }
        return "no established probed findings"
    }
}
