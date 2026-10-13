import Testing
import Foundation
@testable import AgentSmithKit

/// Smoke tests for the data shapes that `InspectorView` and `AgentInspectorWindow`
/// hand to the cached single-pass helpers introduced for P1.3.
///
/// The actual `bucketMessagesByRole` helper lives in the app
/// target (not the package), so we can't import them here. What we *can* test is
/// the message-shape contract those helpers depend on: `ChannelMessage.sender`
/// distinguishes agents by role, and `metadata?["messageKind"] == "task_summarized"`
/// / `metadata?["isError"] == true` are the keys the helpers branch on.
///
/// If the message shape ever changes (sender enum, metadata key strings) these
/// tests fail and force the inspector code to be updated alongside the engine.
@Suite("Inspector cache helper contracts")
struct InspectorRecomputeCacheTests {

    @Test("ChannelMessage.Sender distinguishes agent roles")
    func senderEnumDistinguishesAgents() {
        let smithMessage = ChannelMessage(sender: .agent(.smith), content: "hi")
        let brownMessage = ChannelMessage(sender: .agent(.brown), content: "hi")
        let summarizerMessage = ChannelMessage(sender: .agent(.summarizer), content: "hi")
        let userMessage = ChannelMessage(sender: .user, content: "hi")

        // Replicate the inspector's bucket-by-role pattern.
        var byRole: [AgentRole: [ChannelMessage]] = [:]
        for msg in [smithMessage, brownMessage, summarizerMessage, userMessage] {
            if case .agent(let role) = msg.sender {
                byRole[role, default: []].append(msg)
            }
        }

        #expect(byRole[.smith]?.count == 1)
        #expect(byRole[.brown]?.count == 1)
        #expect(byRole[.summarizer]?.count == 1)
        #expect(byRole[.securityAgent]?.isEmpty ?? true)
        // user messages are NOT in any role bucket — important for the inspector's
        // "agent activity" counter, which excludes user input.
        #expect(byRole.values.flatMap(\.self).count == 3)
    }

    /// `ChannelLogView.ChannelBannerKind` lives in the app target, so it can't be imported here. This
    /// test records which kinds the transcript renders as banners and which fall through to a plain
    /// row — and, so the record can't go stale again, reads the app's own `init?(_ kind:)` switch from
    /// source and requires the two to agree exactly.
    ///
    /// It used to double as the guard against `messageKind` renames, enumerated by hand "from a
    /// grep" — and it did not work: it listed 18 kinds when the runtime emitted more than thirty.
    /// `ChannelMessageKind` owns that job now (its wire strings are asserted directly, and a source
    /// guard blocks new bare literals). The hand list then drifted too: `.mcpStatus` became a banner
    /// (`mcpFailed`) without this test noticing, which is why the source comparison exists.
    @Test("Inspector banner classification is exhaustive, unambiguous, and matches the app")
    func bannerClassificationIsUnambiguous() throws {
        // Kinds that ChannelBannerKind has explicit cases for (renders a banner or hides the row).
        let bannerKinds: Set<ChannelMessageKind> = [
            .taskCreated,
            .taskAcknowledged,
            .taskContinuing,
            .taskComplete,
            .taskCompleted,
            .taskUpdate,
            .taskUpdateGuidance,
            .taskSummarized,
            .taskActionScheduled,
            .changesRequested,
            .memorySaved,
            .memorySearched,
            .mcpStatus,
            .restartChrome,
            .timerActivity,
            .userTaskAction
        ]
        // Every other kind falls through to MessageRow (`ChannelBannerKind.init?` returns nil).
        let nonBannerKinds = Set(ChannelMessageKind.allCases).subtracting(bannerKinds)
        #expect(
            bannerKinds.intersection(nonBannerKinds).isEmpty,
            "A kind should be either a banner or a plain row, not both"
        )

        let source = try String(
            contentsOf: CodeStyleGuardTests.appTargetRoot.appendingPathComponent("Views/ChannelLogView.swift"),
            encoding: .utf8)
        let scanned = try Self.bannerSwitch(in: source)
        // The switch spells case names; the kinds here only expose wire strings.
        let caseNames = try Self.caseNamesByWireString()
        #expect(scanned.banner == Set(bannerKinds.compactMap { caseNames[$0.rawValue] }), "banner kinds in ChannelBannerKind.init? differ from this test's list")
        #expect(scanned.plain == Set(nonBannerKinds.compactMap { caseNames[$0.rawValue] }), "plain-row kinds in ChannelBannerKind.init? differ from every other kind")
    }

    /// Every `ChannelMessageKind` case name keyed by its wire string, read from the enum's source
    /// (`case toolRequest = "tool_request"`). Complete or the test fails.
    private static func caseNamesByWireString() throws -> [String: String] {
        let url = CodeStyleGuardTests.appTargetRoot
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AgentSmithPackage/Sources/AgentSmithKit/Channel/ChannelMessageKind.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let declaration = try NSRegularExpression(pattern: #"^\s*case\s+(\w+)\s*=\s*"([^"]+)""#, options: .anchorsMatchLines)
        var names: [String: String] = [:]
        for match in declaration.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let name = Range(match.range(at: 1), in: source), let wire = Range(match.range(at: 2), in: source) else { continue }
            names[String(source[wire])] = String(source[name])
        }
        #expect(Set(names.keys) == Set(ChannelMessageKind.allCases.map(\.rawValue)), "couldn't read every case of ChannelMessageKind")
        return names
    }

    /// The case names `ChannelBannerKind.init?(_ kind:)` maps to a banner (`self = …`) and to a plain
    /// row (`return nil`), read from the app's source.
    private static func bannerSwitch(in source: String) throws -> (banner: Set<String>, plain: Set<String>) {
        let start = try #require(source.range(of: "init?(_ kind: ChannelMessageKind) {"), "ChannelBannerKind.init? not found")
        let body = String(source[start.upperBound...])
        let clause = try NSRegularExpression(pattern: #"case\s+((?:\.\w+\s*,\s*)*\.\w+)\s*:\s*(self\s*=|return nil)"#)
        var banner: Set<String> = [], plain: Set<String> = []
        for match in clause.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let list = Range(match.range(at: 1), in: body), let action = Range(match.range(at: 2), in: body) else { continue }
            let names = body[list].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst() }.map(String.init)
            if body[action].hasPrefix("self") { banner.formUnion(names) } else { plain.formUnion(names) }
            if body[action] == "return nil" { break }
        }
        return (banner, plain)
    }

    @Test("metadata keys task_summarized + isError discriminate summary vs error rows")
    func summarizerMetadataKeys() {
        let summary = ChannelMessage(
            sender: .agent(.summarizer),
            content: "summarized",
            metadata: ["messageKind": .string("task_summarized")]
        )
        let failure = ChannelMessage(
            sender: .agent(.summarizer),
            content: "failed",
            metadata: ["isError": .bool(true)]
        )
        let other = ChannelMessage(
            sender: .agent(.summarizer),
            content: "other",
            metadata: nil
        )

        // Replicate the inspector's single-pass count logic.
        var summaryCount = 0
        var errorCount = 0
        for message in [summary, failure, other] {
            if case .string("task_summarized") = message.metadata?["messageKind"] {
                summaryCount += 1
            }
            if case .bool(true) = message.metadata?["isError"] {
                errorCount += 1
            }
        }
        #expect(summaryCount == 1)
        #expect(errorCount == 1)
    }
}

