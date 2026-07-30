import Foundation
import Testing
@testable import AgentSmithKit

/// `defaults.json` is a hand-edited resource with no compile-time checking, and the only thing
/// that reads it swallows a decode failure: `SharedAppState` catches, logs, and continues with a
/// `startupError`. So a typo there does not crash, it silently degrades first launch — a fresh
/// install gets no seeded providers, no configurations, and no fallback role assignments, and the
/// only symptom is a line in the log.
///
/// The file lives in the app target, which this package cannot see, so it is read by path
/// relative to this source file rather than from a bundle.
@Suite("Bundled defaults.json")
struct BundledDefaultsDecodeTests {

    private var defaultsURL: URL {
        URL(fileURLWithPath: #filePath)                 // …/AgentSmithPackage/Tests/AgentSmithTests/<this>
            .deletingLastPathComponent()                // AgentSmithTests
            .deletingLastPathComponent()                // Tests
            .deletingLastPathComponent()                // AgentSmithPackage
            .deletingLastPathComponent()                // repo root
            .appendingPathComponent("AgentSmith/AgentSmith/Resources/defaults.json")
    }

    private func loadDefaults() throws -> AppDefaults {
        let data = try Data(contentsOf: defaultsURL)
        return try JSONDecoder().decode(AppDefaults.self, from: data)
    }

    @Test("The shipped file decodes as AppDefaults")
    func decodes() throws {
        let defaults = try loadDefaults()
        #expect(defaults.version == 2)
    }

    /// Every required role must be assigned, or `AppViewModel` refuses to start and the user is
    /// sent to the configuration gate on a fresh install. `.validator` is deliberately not in
    /// `requiredRoles` — a missing one parks tasks rather than blocking launch — but leaving it
    /// unseeded is what parks every submitted task in `.awaitingReview` with a blocked reason
    /// that not even Smith can resolve, so it is seeded too.
    @Test("Every role is assigned, including validator and summarizer")
    func everyRoleAssigned() throws {
        let defaults = try loadDefaults()
        for role in AgentRole.allCases {
            #expect(defaults.agentAssignments[role] != nil, "no assignment seeded for \(role.rawValue)")
        }
    }

    /// An assignment is a `ModelConfiguration.id`. One pointing at a configuration the file does
    /// not also carry is a dangling reference that seeds a role with nothing.
    @Test("Each assignment resolves to a configuration in the same file")
    func assignmentsResolve() throws {
        let defaults = try loadDefaults()
        let configIDs = Set(defaults.modelConfigurations.map(\.id))
        for (role, id) in defaults.agentAssignments {
            #expect(configIDs.contains(id), "\(role.rawValue) points at a configuration not in the file")
        }
    }

    /// Onboarding passes `temperature: nil`, and these defaults are meant to mirror that profile.
    /// An asserted temperature here would make the seeded setup differ from the one a user gets
    /// by walking through first-run setup with the same provider.
    @Test("Seeded configurations omit temperature, matching onboarding")
    func temperatureOmitted() throws {
        for config in try loadDefaults().modelConfigurations {
            #expect(config.temperature == nil, "\(config.name) asserts a temperature")
        }
    }
}
