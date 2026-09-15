import Testing
import Foundation
@testable import AgentSmithKit

/// `SessionState` hand-rolls `CodingKeys`, `init(from:)` and `encode(to:)`, which costs it the
/// synthesized key list and creates the exact footgun CLAUDE.md names: a stored property with no
/// case is silently never persisted, and every round-trip test stays GREEN because the missing
/// field decodes back to the same default the fixture left it at.
///
/// The existing guard in `OrchestrationSettingsTests` is field-specific — it pins
/// `orchestrationOverride` and nothing else, so it could not have caught `taskTranscriptViewConfig`
/// going in uncovered. This one is by REFLECTION, the same shape as `ledgerCodingKeyCoverage`, so it
/// covers every field added from here on without anyone remembering to extend it.
@Suite("SessionState Codable coverage")
struct SessionStateCodingTests {

    /// Properties deliberately absent from the encoded form, with the reason each is exempt.
    /// A name may only appear here because writing it would be WRONG — never to silence the guard.
    private static let deliberatelyNotEncoded: Set<String> = [
        // Decode-only migration carrier: a pre-2026-07-31 session's pool-UUID assignments, mapped to
        // `agentAssignments` at load. Re-encoding it would resurrect the retired pool indirection.
        "legacyConfigAssignments"
    ]

    /// Properties whose persisted key deliberately differs from the property name.
    private static let persistedKey: [String: String] = [
        // The new direct (provider, model) assignments are written under `agentModelAssignments`;
        // the bare `agentAssignments` key is the retired pool-UUID form, decoded but never written.
        "agentAssignments": "agentModelAssignments"
    ]

    /// Every stored property populated — `encodeIfPresent` omits nils, so a fixture that left one
    /// nil would look identical to one whose case is missing.
    private static func fullyPopulated() -> SessionState {
        SessionState(
            agentAssignments: [.smith: ModelAssignment(providerID: "p", modelID: "m")],
            agentPollIntervals: [.smith: 5],
            agentMaxToolCalls: [.smith: 100],
            agentMessageDebounceIntervals: [.smith: 1.5],
            toolsEnabled: ["bash": true],
            autoRunNextTask: false,
            autoRunInterruptedTasks: false,
            orchestrationOverride: OrchestrationSettingsOverride(enableTaskCompletionValidators: false),
            selectedTaskID: UUID(),
            transcriptViewConfig: .conversation,
            taskTranscriptViewConfig: .everything
        )
    }

    @Test("Every stored property has a CodingKeys case, by reflection")
    func everyPropertyIsPersisted() throws {
        let state = Self.fullyPopulated()
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        let expected = Set(
            Mirror(reflecting: state).children
                .compactMap(\.label)
                .filter { !Self.deliberatelyNotEncoded.contains($0) }
                .map { Self.persistedKey[$0] ?? $0 }
        )
        let missing = expected.subtracting(object.keys).sorted()
        #expect(missing.isEmpty, """
            \(missing.joined(separator: ", ")) is a stored property with no CodingKeys case, so it \
            is silently never persisted. Add it to SessionState.CodingKeys, init(from:) and \
            encode(to:) — or, if omitting it is deliberate, to `deliberatelyNotEncoded` with a reason.
            """)
    }

    @Test("The reflection guard actually fails when a field is dropped")
    func guardCatchesAnUncoveredProperty() throws {
        // Proves the check can fail: a name the encoder does not write must be reported. Without
        // this, a guard that silently passed everything would look identical to a correct one.
        let state = Self.fullyPopulated()
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        #expect(!object.keys.contains("legacyConfigAssignments"))
        #expect(Set(["legacyConfigAssignments"]).subtracting(object.keys).isEmpty == false)
    }

    @Test("Both pane configs round-trip independently")
    func bothTranscriptConfigsRoundTrip() throws {
        var state = Self.fullyPopulated()
        // Distinct values, so a mix-up between the two fields cannot pass.
        var topConfig = TranscriptViewConfig.everything
        topConfig.defaultKinds.setTool("bash", visible: false)
        state.taskTranscriptViewConfig = topConfig
        state.transcriptViewConfig = .conversation

        let back = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state))
        #expect(back.taskTranscriptViewConfig == topConfig)
        #expect(back.taskTranscriptViewConfig?.defaultKinds.hiddenToolNames == ["bash"])
        #expect(back.transcriptViewConfig == .conversation)
        #expect(back.transcriptViewConfig?.defaultKinds.hiddenToolNames.isEmpty == true,
                "the bottom pane's config must not pick up the top pane's hidden tools")
    }

    @Test("A pre-feature state.json decodes with no top-pane config, not a throw")
    func preFeatureStateMigratesToNil() throws {
        let oldJSON = """
        {"agentModelAssignments":{},"agentPollIntervals":{},"agentMaxToolCalls":{},\
        "agentMessageDebounceIntervals":{},"toolsEnabled":{},"autoRunNextTask":true,\
        "autoRunInterruptedTasks":true}
        """
        let back = try JSONDecoder().decode(SessionState.self, from: Data(oldJSON.utf8))
        #expect(back.taskTranscriptViewConfig == nil)
    }

    /// The top pane's default must reproduce the filter it used before it had a config at all, or
    /// every existing session's task pane silently changes what it shows on upgrade.
    @Test("The top pane's default filter equals the bare task-scoped filter it replaced")
    func defaultTopConfigPreservesPriorBehavior() {
        let id = UUID()
        let previous = TranscriptFilter(taskScope: .task(id))
        let now = TranscriptViewConfig.everything.makeFilter(taskScope: .task(id))
        #expect(now == previous)

        // And with nothing selected, the pane still matches nothing rather than the whole session.
        #expect(TranscriptViewConfig.everything.makeFilter(taskScope: .matchNone)
                == TranscriptFilter(taskScope: .matchNone))
    }

    /// An explicit scope must beat the config's own `hideTaskScoped`, or turning that switch on in
    /// the top pane's popover would silently repoint the pane at the orchestration conversation.
    @Test("An explicit task scope overrides the config's hideTaskScoped switch")
    func explicitScopeWinsOverHideTaskScoped() {
        let id = UUID()
        var config = TranscriptViewConfig.everything
        config.hideTaskScoped = true
        #expect(config.makeFilter(taskScope: .task(id)).taskScope == .task(id))
        // Without an explicit scope the switch still governs, which is the bottom pane's behavior.
        #expect(config.makeFilter().taskScope == .orchestration)
    }
}
