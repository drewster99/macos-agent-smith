import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// `MessageSeverity` and the transcript filter FLOOR built on it.
///
/// The bug these pin: a failed tool call was posted with the identical kind and metadata as a
/// successful one, so a user who hid `tool_output` to quiet the transcript also hid every
/// failure. On 2026-09-20 that hid seven consecutive `create_task` failures — nothing reached
/// the user and the request they had made was silently abandoned.
///
/// Three separable things have to hold, and they fail in different ways:
///
/// 1. The wire strings, which are persisted in `channel_log.jsonl`.
/// 2. The READ side: legacy `isError` rows, unknown values, and absent metadata each resolve
///    to the right level. This is where the historical corpus lives or dies.
/// 3. The FLOOR: that a message at or above it survives filters which would otherwise hide it.
@Suite("MessageSeverity")
struct MessageSeverityTests {

    /// Spelled out independently of the declaration, so renaming a case stays free while
    /// changing a `rawValue` — a storage format — fails the build.
    private static let expectedWireStrings: [MessageSeverity: String] = [
        .info: "info",
        .warning: "warning",
        .error: "error"
    ]

    @Test("Wire strings are pinned")
    func wireStringsArePinned() {
        for (severity, expected) in Self.expectedWireStrings {
            #expect(severity.rawValue == expected)
        }
    }

    /// Catches a case added without a pinned wire string — the same gap `allCases` closes for
    /// `ChannelMessageKind`.
    @Test("Every case is pinned")
    func everyCaseIsPinned() {
        #expect(Set(MessageSeverity.allCases) == Set(Self.expectedWireStrings.keys))
    }

    /// The floor is expressed as `severity >= floor`, so the ordering IS the feature.
    @Test("Ordering runs info < warning < error")
    func orderingIsCorrect() {
        #expect(MessageSeverity.info < .warning)
        #expect(MessageSeverity.warning < .error)
        #expect(MessageSeverity.info < .error)
        #expect(MessageSeverity.allCases.sorted() == [.info, .warning, .error])
    }

    // MARK: Read side

    private func message(metadata: [String: AnyCodable]?) -> ChannelMessage {
        ChannelMessage(sender: .system, content: "x", metadata: metadata)
    }

    @Test("No metadata reads as info")
    func absentSeverityIsInfo() {
        #expect(message(metadata: nil).severity == .info)
        #expect(message(metadata: ["tool": .string("bash")]).severity == .info)
    }

    @Test("Explicit severity round-trips")
    func explicitSeverityRoundTrips() {
        for severity in MessageSeverity.allCases {
            #expect(message(metadata: ["severity": .severity(severity)]).severity == severity)
        }
    }

    /// The persisted corpus is full of rows stamped `isError: true` by producers that predate
    /// this type. They must read as errors, or every historical failure silently becomes routine.
    @Test("Legacy isError rows read as errors")
    func legacyIsErrorReadsAsError() {
        #expect(message(metadata: ["isError": .bool(true)]).severity == .error)
        #expect(message(metadata: ["isError": .bool(false)]).severity == .info)
    }

    /// An explicit severity wins over a legacy flag, so a row carrying both is never ambiguous.
    @Test("Explicit severity beats a legacy isError flag")
    func explicitSeverityBeatsLegacyFlag() {
        let both = message(metadata: ["severity": .severity(.warning), "isError": .bool(true)])
        #expect(both.severity == .warning)
    }

    /// Unlike `kind`, an unrecognized severity must NOT trap — it drives display, not control
    /// flow. But it must fail toward visible: reading as `.info` would let a row written by a
    /// newer build vanish from a filtered pane, which is the whole failure being fixed.
    @Test("Unparseable severity fails toward visible, not routine")
    func unknownSeverityResolvesToError() {
        #expect(message(metadata: ["severity": .string("catastrophe")]).severity == .error)
        #expect(message(metadata: ["severity": .int(3)]).severity == .error)
    }
}

/// The floor's actual job: surviving a filter that hides the message on another axis.
@Suite("TranscriptFilter severity floor")
struct TranscriptFilterSeverityFloorTests {

    private func toolOutput(succeeded: Bool) -> ChannelMessage {
        var metadata: [String: AnyCodable] = [
            "messageKind": .kind(.toolOutput),
            "tool": .string("create_task")
        ]
        if !succeeded { metadata["severity"] = .severity(.error) }
        return ChannelMessage(sender: .agent(.smith), content: "…", metadata: metadata)
    }

    /// The exact 2026-09-20 configuration: `tool_output` hidden, which silently hid the failures.
    private var hidingToolOutput: TranscriptFilter {
        TranscriptFilter(kinds: .allExcept([.toolRequest, .toolOutput]))
    }

    @Test("A hidden kind still hides SUCCESSFUL tool output")
    func successfulToolOutputStaysHidden() {
        #expect(hidingToolOutput.matches(toolOutput(succeeded: true)) == false)
    }

    /// The regression this whole change exists to prevent.
    @Test("A hidden kind does NOT hide a FAILED tool call")
    func failedToolOutputSurvivesHiddenKind() {
        #expect(hidingToolOutput.matches(toolOutput(succeeded: false)))
    }

    @Test("The floor defeats the sender and tool axes too")
    func floorDefeatsEveryExclusionAxis() {
        let bySender = TranscriptFilter(allowedSenders: [.agent(.brown)])
        #expect(bySender.matches(toolOutput(succeeded: true)) == false)
        #expect(bySender.matches(toolOutput(succeeded: false)))

        let byTool = TranscriptFilter(hiddenToolNames: ["create_task"])
        #expect(byTool.matches(toolOutput(succeeded: true)) == false)
        #expect(byTool.matches(toolOutput(succeeded: false)))
    }

    /// Default floor is `.warning`, so warnings surface without the user configuring anything.
    @Test("Warnings clear the default floor")
    func warningsClearDefaultFloor() {
        let warned = ChannelMessage(
            sender: .system, content: "WARN",
            metadata: ["messageKind": .kind(.securityReview), "severity": .severity(.warning)]
        )
        #expect(TranscriptFilter(kinds: .allExcept([.securityReview])).matches(warned))
    }

    /// `.error` only — a warning is then subject to the ordinary axes again.
    @Test("Raising the floor to errors lets warnings be filtered")
    func raisingFloorExcludesWarnings() {
        let warned = ChannelMessage(
            sender: .system, content: "WARN",
            metadata: ["messageKind": .kind(.securityReview), "severity": .severity(.warning)]
        )
        let errorsOnly = TranscriptFilter(
            kinds: .allExcept([.securityReview]), alwaysShowAtOrAbove: .error
        )
        #expect(errorsOnly.matches(warned) == false)
    }

    @Test("A nil floor restores pure exclusion behavior")
    func nilFloorDisablesTheFeature() {
        let noFloor = TranscriptFilter(
            kinds: .allExcept([.toolRequest, .toolOutput]), alwaysShowAtOrAbove: nil
        )
        #expect(noFloor.matches(toolOutput(succeeded: false)) == false)
    }

    /// `hideErrors` is an explicit "not in this pane" and must outrank the floor, which exists
    /// only to defeat filters that hide errors INCIDENTALLY.
    @Test("An explicit hideErrors beats the floor")
    func explicitHideErrorsBeatsFloor() {
        let hidden = TranscriptFilter(hideErrors: true, alwaysShowAtOrAbove: .warning)
        #expect(hidden.matches(toolOutput(succeeded: false)) == false)
    }
}

/// The config is the persisted surface, and it hand-writes its `Codable` — a property added to
/// the struct but not to those keys is silently never saved.
@Suite("TranscriptViewConfig severity floor persistence")
struct TranscriptViewConfigSeverityFloorTests {

    private func roundTrip(_ config: TranscriptViewConfig) throws -> TranscriptViewConfig {
        try JSONDecoder().decode(TranscriptViewConfig.self, from: JSONEncoder().encode(config))
    }

    @Test("The floor survives a round trip at every setting")
    func floorRoundTrips() throws {
        for floor: MessageSeverity? in [.warning, .error, nil] {
            var config = TranscriptViewConfig()
            config.alwaysShowAtOrAbove = floor
            #expect(try roundTrip(config).alwaysShowAtOrAbove == floor)
        }
    }

    /// A config written before the floor existed is exactly one that was hiding failures. It must
    /// adopt the default rather than decoding to `nil` — an upgrade must not preserve the broken
    /// behavior it is fixing.
    @Test("A config predating the floor adopts the default, not nil")
    func legacyConfigAdoptsDefaultFloor() throws {
        let legacy = Data(#"{"showsChat":true,"showErrors":true,"hideTaskScoped":false}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptViewConfig.self, from: legacy)
        #expect(decoded.alwaysShowAtOrAbove == .warning)
    }

    /// The floor has to reach the filter, not just the struct.
    @Test("makeFilter carries the floor through")
    func makeFilterCarriesFloor() {
        var config = TranscriptViewConfig()
        config.alwaysShowAtOrAbove = .error
        #expect(config.makeFilter().alwaysShowAtOrAbove == .error)
    }
}
