import Testing
import Foundation
@testable import AgentSmithKit

/// Pins the layered-config resolver that every orchestration OFF-behavior reads through.
///
/// The load-bearing properties: `applying` is a pure sparse merge (set fields win, `nil` inherits),
/// the four-layer chain composes left-to-right, the shipped defaults carry the agreed per-point
/// matrix, and every field survives a JSON round-trip (the settings are persisted both as a shipped
/// file and as user overrides on disk).
@Suite struct OrchestrationSettingsTests {

    @Test func builtInDefaultsMatchTheAgreedMatrix() {
        let d = OrchestrationSettings.builtIn
        #expect(d.summarizeCompletedTasks)
        #expect(d.summarizeForContextCompaction)
        #expect(d.enableTaskCompletionValidators)
        #expect(d.scopeToolSetOnTaskStart)
        #expect(d.reviewSmithToolCalls && d.reviewBrownToolCalls && d.reviewValidatorToolCalls)
        #expect(d.retrieval.newTask == RetrievalToggle(memory: true, task: true))
        #expect(d.retrieval.userMessage == RetrievalToggle(memory: true, task: false))
        // Validator-review memory is OFF by decision: injecting memories would make a verdict depend
        // on the live corpus, which the validator audit hash does not cover.
        #expect(d.retrieval.beforeValidatorReview == RetrievalToggle(memory: false, task: false))
        #expect(d.retrieval.beforeSecurityScoping == RetrievalToggle(memory: false, task: false))
        #expect(d.retrieval.beforeSecurityToolReview == RetrievalToggle(memory: true, task: false))
    }

    @Test func emptyOverrideIsIdentity() {
        let base = OrchestrationSettings.builtIn
        #expect(base.applying(OrchestrationSettingsOverride()) == base)
        #expect(OrchestrationSettingsOverride().isEmpty)
    }

    @Test func overrideReplacesOnlySetFields() {
        let base = OrchestrationSettings.builtIn
        let over = OrchestrationSettingsOverride(
            retrieval: RetrievalSettingsOverride(userMessage: RetrievalToggleOverride(task: true)),
            enableTaskCompletionValidators: false,
            reviewBrownToolCalls: false
        )
        let r = base.applying(over)
        #expect(r.enableTaskCompletionValidators == false)
        #expect(r.reviewBrownToolCalls == false)
        // Everything not named is inherited.
        #expect(r.reviewSmithToolCalls == true)
        #expect(r.summarizeCompletedTasks == true)
        // Only the overridden axis of a toggle changes; the other axis inherits.
        #expect(r.retrieval.userMessage == RetrievalToggle(memory: true, task: true))
        #expect(!over.isEmpty)
    }

    @Test func fourLayerChainComposesLeftToRight() {
        let shipped = OrchestrationSettings.builtIn
        // A "downloaded" complete baseline that flips one field.
        let downloaded = shipped.applying(OrchestrationSettingsOverride(scopeToolSetOnTaskStart: false))
        let appWide = OrchestrationSettingsOverride(reviewSmithToolCalls: false)
        let session = OrchestrationSettingsOverride(summarizeCompletedTasks: false, reviewSmithToolCalls: true)

        let resolved = downloaded.applying(appWide).applying(session)
        #expect(resolved.scopeToolSetOnTaskStart == false)   // from downloaded
        #expect(resolved.reviewSmithToolCalls == true)       // session wins over app-wide
        #expect(resolved.summarizeCompletedTasks == false)   // from session
        #expect(resolved.reviewBrownToolCalls == true)       // untouched, from shipped
    }

    @Test func roundTripsThroughJSON() throws {
        let over = OrchestrationSettingsOverride(
            summarizeForContextCompaction: false,
            retrieval: RetrievalSettingsOverride(beforeSecurityToolReview: RetrievalToggleOverride(memory: false)),
            reviewValidatorToolCalls: false
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let settingsBack = try decoder.decode(OrchestrationSettings.self,
                                              from: encoder.encode(OrchestrationSettings.builtIn))
        let overBack = try decoder.decode(OrchestrationSettingsOverride.self, from: encoder.encode(over))
        #expect(settingsBack == OrchestrationSettings.builtIn)
        #expect(overBack == over)
    }

    @Test func reviewsToolCallsFailsClosedForUnlistedRoles() {
        let none = OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            reviewSmithToolCalls: false, reviewBrownToolCalls: false, reviewValidatorToolCalls: false))
        #expect(none.reviewsToolCalls(by: .smith) == false)
        #expect(none.reviewsToolCalls(by: .brown) == false)
        #expect(none.reviewsToolCalls(by: .validator) == false)
        // Unlisted emitters review by default even when the three named ones are off.
        #expect(none.reviewsToolCalls(by: .securityAgent) == true)
        #expect(none.reviewsToolCalls(by: .summarizer) == true)
    }
}

/// Guards the per-session override field on `SessionState`, whose hand-rolled `CodingKeys` are the
/// exact "missing case → silently never persisted" footgun CLAUDE.md warns about.
@Suite struct SessionStateOrchestrationOverrideTests {

    @Test func overrideRoundTrips() throws {
        var s = SessionState(autoRunNextTask: false)
        s.orchestrationOverride = OrchestrationSettingsOverride(enableTaskCompletionValidators: false)
        let back = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(s))
        #expect(back.orchestrationOverride == s.orchestrationOverride)
        #expect(back.autoRunNextTask == false)   // existing fields still round-trip
    }

    @Test func nilOverrideOmitsKeyAndDecodesAsInherit() throws {
        let data = try JSONEncoder().encode(SessionState())
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("orchestrationOverride"))   // encodeIfPresent omits it entirely
        let back = try JSONDecoder().decode(SessionState.self, from: data)
        #expect(back.orchestrationOverride == nil)
    }

    @Test func preFeatureStateMigratesToNil() throws {
        // A pre-feature state.json carrying no orchestrationOverride key must decode, not throw.
        let oldJSON = """
        {"agentModelAssignments":{},"agentPollIntervals":{},"agentMaxToolCalls":{},\
        "agentMessageDebounceIntervals":{},"toolsEnabled":{},"autoRunNextTask":true,\
        "autoRunInterruptedTasks":true}
        """
        let back = try JSONDecoder().decode(SessionState.self, from: Data(oldJSON.utf8))
        #expect(back.orchestrationOverride == nil)
    }
}
