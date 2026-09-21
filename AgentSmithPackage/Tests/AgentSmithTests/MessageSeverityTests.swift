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

    /// A JSON null says no severity was RECORDED — absent, not corrupt. Reading it as `.error`
    /// would make every null-stamped row unfilterable.
    @Test("A null severity is absent, not corrupt")
    func nullSeverityIsAbsent() {
        #expect(message(metadata: ["severity": .null]).severity == .info)
        #expect(message(metadata: ["severity": .null, "isError": .bool(true)]).severity == .error)
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

    // MARK: Scope axes are NOT noise axes

    private func failureInTask(_ taskID: UUID?) -> ChannelMessage {
        ChannelMessage(
            sender: .agent(.brown), content: "boom",
            metadata: ["messageKind": .kind(.toolOutput), "severity": .severity(.error)],
            taskID: taskID
        )
    }

    /// The floor defeats NOISE filters (a kind, a sender, a tool the user chose not to read). It
    /// must never defeat SCOPE — which pane a message belongs to. A per-task pane showing another
    /// task's errors is not "surfacing" anything; it is putting a row where it is not about.
    @Test("The floor does NOT leak an error across task scopes")
    func floorRespectsTaskScope() {
        let mine = UUID(), theirs = UUID()
        let pane = TranscriptFilter(taskScope: .task(mine))
        #expect(pane.matches(failureInTask(mine)))
        #expect(pane.matches(failureInTask(theirs)) == false)
        #expect(pane.matches(failureInTask(nil)) == false)
    }

    /// The orchestration pane is the mirror image: it shows what is NOT tied to a task.
    @Test("The orchestration scope still excludes task-scoped errors")
    func floorRespectsOrchestrationScope() {
        let pane = TranscriptFilter(taskScope: .orchestration)
        #expect(pane.matches(failureInTask(nil)))
        #expect(pane.matches(failureInTask(UUID())) == false)
    }

    /// `.matchNone` exists to show NOTHING until a task is picked. "Nothing" includes errors.
    @Test("matchNone shows nothing, errors included")
    func matchNoneShowsNothing() {
        #expect(TranscriptFilter(taskScope: .matchNone).matches(failureInTask(UUID())) == false)
        #expect(TranscriptFilter(taskScope: .matchNone).matches(failureInTask(nil)) == false)
    }

    /// Public/private is a scope boundary too — an error addressed privately must not appear in a
    /// pane that shows only public traffic.
    @Test("The floor respects the public/private boundary")
    func floorRespectsVisibility() {
        let privateFailure = ChannelMessage(
            sender: .system, recipientID: UUID(), recipient: .agent(.brown),
            content: "blocked",
            metadata: ["messageKind": .kind(.securityReview), "severity": .severity(.error)]
        )
        #expect(TranscriptFilter(visibility: .publicOnly).matches(privateFailure) == false)
        #expect(TranscriptFilter(visibility: .privateOnly).matches(privateFailure))
    }
}

/// A failed tool call is an error — EXCEPT where "failure" means the callee's exit status.
@Suite("Tool outcome severity")
struct ToolOutcomeSeverityTests {

    @Test("A successful call is routine")
    func successIsInfo() {
        #expect(AgentActor.severityForToolOutcome(toolName: "create_task", succeeded: true) == .info)
        #expect(AgentActor.severityForToolOutcome(toolName: "bash", succeeded: true) == .info)
    }

    /// The case the whole floor exists for.
    @Test("An ordinary tool failure is an error")
    func ordinaryFailureIsError() {
        #expect(AgentActor.severityForToolOutcome(toolName: "create_task", succeeded: false) == .error)
        #expect(AgentActor.severityForToolOutcome(toolName: "file_read", succeeded: false) == .error)
    }

    /// `swift test` returning 1 is the agent WORKING. Stamping it `.error` would pierce every
    /// filter on every iteration of an edit-build-test loop and drown the signal it carries.
    @Test("A non-zero exit from a callee-status tool is not an error")
    func calleeExitStatusIsNotAnError() {
        #expect(AgentActor.severityForToolOutcome(toolName: "bash", succeeded: false) == .info)
    }

    /// The streak breaker and the severity call must agree about what counts as a real failure;
    /// they read one set so they cannot drift apart.
    @Test("The exempt set is shared with the failure-streak breaker")
    func exemptSetIsShared() {
        for tool in AgentActor.calleeExitStatusTools {
            #expect(AgentActor.severityForToolOutcome(toolName: tool, succeeded: false) == .info)
        }
    }
}

/// Security dispositions map to severity by gravity AND frequency — a level that fires on every
/// call would be unfilterable noise rather than signal, since the floor treats `.warning` as
/// always-visible.
@Suite("SecurityDisposition severity")
struct SecurityDispositionSeverityTests {

    @Test("Allowed calls are routine, including the unjudged ones")
    func allowedCallsAreInfo() {
        #expect(SecurityDisposition(outcome: .approved).severity == .info)
        #expect(SecurityDisposition(outcome: .autoApproved).severity == .info)
        // Fires on EVERY call when review is off. Visible by kind; never unfilterable.
        #expect(SecurityDisposition(outcome: .approvedWithoutReview).severity == .info)
    }

    @Test("Blocked-but-recoverable is a warning")
    func blockedRecoverableIsWarning() {
        #expect(SecurityDisposition(outcome: .warned).severity == .warning)
        // User pressed Stop — blocked and unjudged, but nobody's failure.
        #expect(SecurityDisposition(outcome: .reviewCancelled).severity == .warning)
    }

    @Test("A refusal or a missing reviewer is an error")
    func refusalsAreErrors() {
        #expect(SecurityDisposition(outcome: .refused(.unsafe)).severity == .error)
        #expect(SecurityDisposition(outcome: .refused(.abort)).severity == .error)
        #expect(SecurityDisposition(
            outcome: .reviewerUnavailable(.noEvaluatorConfigured)
        ).severity == .error)
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


/// Guards the rule rather than trusting it: severity is read through the accessor, never by
/// unwrapping the metadata by hand.
///
/// This is not hypothetical tidiness. Converting the producers from `isError` to `severity` left
/// four hand-rolled `metadata["isError"]` readers behind, and every one of them silently stopped
/// matching: the transcript's error background, the Summarizer card's red/green verdict (a FAILED
/// summary was about to render with a green checkmark), its error count, and the error sound.
/// Nothing failed — they just quietly answered "not an error" forever.
@Suite("Severity accessor guard")
struct SeverityAccessorGuardTests {

    private static var sourceRoots: [URL] {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repo.deleteLastPathComponent() }
        return [
            repo.appendingPathComponent("AgentSmithPackage/Sources", isDirectory: true),
            repo.appendingPathComponent("AgentSmith/AgentSmith", isDirectory: true)
        ]
    }

    /// The single accessor, plus the type that defines the wire strings.
    private static let exemptFileNames: Set<String> = ["ChannelMessage.swift", "MessageSeverity.swift"]

    @Test("No hand-rolled severity or isError metadata access")
    func noHandRolledSeverityReads() throws {
        // Both the retired flag and the current key: reading either by hand is the bug.
        let regex = try NSRegularExpression(pattern: #"metadata\??\["(?:isError|isWarning|severity)"\]"#)
        var hits: [String] = []
        var filesScanned = 0
        for root in Self.sourceRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else {
                Issue.record("Could not enumerate \(root.path) — this guard covers less than it claims.")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard !Self.exemptFileNames.contains(url.lastPathComponent) else { continue }
                filesScanned += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                    // Doc comments legitimately name the keys.
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") else { continue }
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    if regex.firstMatch(in: line, options: [], range: range) != nil {
                        hits.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
                    }
                }
            }
        }
        #expect(filesScanned > 100, "only \(filesScanned) files scanned — the roots are wrong")
        #expect(hits.isEmpty, Comment(rawValue: """
            Severity read by hand instead of through `ChannelMessage.severity`:

            \(hits.joined(separator: "\n"))

            Use `message.severity`. A hand-rolled unwrap of `isError` / `isWarning` / `severity`
            silently answers "not an error" the moment producers change which key they write —
            which is exactly what happened to four UI read sites on 2026-09-20.
            """))
    }
}
