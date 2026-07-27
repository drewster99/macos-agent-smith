import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// `ChannelMessageKind` is the typed replacement for the bare `messageKind` metadata strings.
///
/// Two things need pinning, and they are different in character:
///
/// 1. The WIRE STRINGS. These are persisted in `channel_log.jsonl` and read back on every
///    launch, so a raw value is a storage format, not an implementation detail. Renaming a
///    Swift member is free; changing its `rawValue` silently orphans every historical message
///    carrying the old spelling. The first test makes that a build failure instead.
///
/// 2. The ABSENCE of new bare literals. A type only removes an antipattern if the antipattern
///    can't come back — and nothing stops the next `"messageKind": .string("whatever")` from
///    being written by hand. The guard test is what actually enforces the rule; the type alone
///    is just a convenience.
@Suite("ChannelMessageKind")
struct ChannelMessageKindTests {

    /// Every kind's wire string, spelled out independently of the declaration.
    ///
    /// Deliberately a literal table rather than something derived from the type — a test that
    /// reads the value it is checking proves nothing. If a `rawValue` is edited, this fails and
    /// forces the question "is there persisted data using the old spelling?" (there always is).
    private static let expectedWireStrings: [(ChannelMessageKind, String)] = [
        (.toolRequest, "tool_request"),
        (.toolOutput, "tool_output"),
        (.taskCreated, "task_created"),
        (.taskAcknowledged, "task_acknowledged"),
        (.taskContinuing, "task_continuing"),
        (.taskComplete, "task_complete"),
        (.taskCompleted, "task_completed"),
        (.taskFailed, "task_failed"),
        (.taskUpdate, "task_update"),
        (.taskUpdateGuidance, "task_update_guidance"),
        (.taskSummarized, "task_summarized"),
        (.taskActionScheduled, "task_action_scheduled"),
        (.taskQueuedAtCapacity, "task_queued_at_capacity"),
        (.taskLifecycle, "task_lifecycle"),
        (.scheduledRunDeferred, "scheduled_run_deferred"),
        (.changesRequested, "changes_requested"),
        (.criteriaUpdated, "criteria_updated"),
        (.validationReport, "validation_report"),
        (.validationFailed, "validation_failed"),
        (.validationEscalation, "validation_escalation"),
        (.submissionAutoRejected, "submission_auto_rejected"),
        (.validationBlocked, "validation_blocked"),
        (.validationBlockedWorkerNotice, "validation_blocked_worker_notice"),
        (.helpRequested, "help_requested"),
        (.helpProvided, "help_provided"),
        (.memorySaved, "memory_saved"),
        (.memorySearched, "memory_searched"),
        (.inboundUserMessage, "inbound_user_message"),
        (.contextManagement, "context_management"),
        (.timerActivity, "timer_activity"),
        (.mcpStatus, "mcp_status"),
        (.restartChrome, "restart_chrome"),
        (.preparing, "preparing")
    ]

    @Test("Wire strings are stable — they are a persisted storage format")
    func wireStringsAreStable() {
        for (kind, expected) in Self.expectedWireStrings {
            #expect(kind.rawValue == expected, "kind \(kind) should serialize as \"\(expected)\"")
        }
    }

    @Test("An unrecognized kind round-trips instead of decoding as nil")
    func unknownKindsSurvive() {
        // The whole reason this is a RawRepresentable struct rather than a closed enum. A kind
        // that exists only in historical logs must still compare correctly, not vanish — if it
        // decoded as nil, every reader keyed on it would silently take the wrong branch.
        let legacy = ChannelMessageKind(rawValue: "some_kind_retired_long_ago")
        #expect(legacy.rawValue == "some_kind_retired_long_ago")
        #expect(legacy != .toolRequest)
        #expect(legacy == ChannelMessageKind(rawValue: "some_kind_retired_long_ago"))
    }

    @Test("The metadata accessor reads what the metadata factory writes")
    func metadataRoundTrip() {
        let message = ChannelMessage(
            sender: .system,
            content: "x",
            metadata: ["messageKind": .kind(.validationBlockedWorkerNotice)]
        )
        #expect(message.kind == .validationBlockedWorkerNotice)
        // And the on-disk shape is still a plain string, unchanged from before the type existed.
        #expect(message.metadata?["messageKind"] == .string("validation_blocked_worker_notice"))
    }

    @Test("A message with no metadata has no kind")
    func absentKind() {
        #expect(ChannelMessage(sender: .system, content: "x").kind == nil)
    }
}

/// Guards the rule rather than trusting it: no new bare `messageKind` string literals.
///
/// The migration to `ChannelMessageKind` is only worth anything if the strings stay gone. This
/// scans BOTH targets — the engine package and the app — because kinds are posted and read on
/// both sides, and the previous hand-maintained approach failed precisely because a kind could
/// hide in a file nobody thought to grep.
@Suite("ChannelMessageKind literal guard")
struct ChannelMessageKindLiteralGuardTests {

    /// The two source roots that post or interpret channel messages.
    private static var sourceRoots: [URL] {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repo.deleteLastPathComponent() }  // -> <repo>/
        return [
            repo.appendingPathComponent("AgentSmithPackage/Sources", isDirectory: true),
            repo.appendingPathComponent("AgentSmith/AgentSmith", isDirectory: true)
        ]
    }

    /// The only two files allowed to touch the raw representation.
    ///
    /// `ChannelMessageKind.swift` declares the wire strings, and `ChannelMessage.swift` holds the
    /// single accessor that unwraps the metadata slot. Everything else goes through `.kind`, which
    /// is the entire point: one place converts the stored string into a type, and no other site
    /// gets to re-derive it.
    private static let exemptFileNames: Set<String> = [
        "ChannelMessageKind.swift",
        "ChannelMessage.swift"
    ]

    private static func scan(regex pattern: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        var hits: [String] = []
        for root in sourceRoots {
            guard let e = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in e {
                guard url.pathExtension == "swift",
                      !exemptFileNames.contains(url.lastPathComponent),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (i, line) in text.components(separatedBy: .newlines).enumerated() {
                    // Comments may quote the old shape while explaining why it's gone.
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") else { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, range: range) != nil {
                        hits.append("\(url.lastPathComponent):\(i + 1) — \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        return hits
    }

    @Test("No bare messageKind string literals are written")
    func noBareKindWrites() {
        // Post sites must name the kind: `"messageKind": .kind(.toolRequest)`.
        let hits = Self.scan(regex: #""messageKind"\s*:\s*\.string\("#)
        if !hits.isEmpty {
            let formatted = hits.joined(separator: "\n")
            Issue.record("Use `.kind(.someKind)` instead of a raw string:\n\(formatted)")
        }
    }

    @Test("No bare messageKind string literals are compared")
    func noBareKindReads() {
        // Read sites must use `message.kind == .someKind`, not a hand-rolled metadata unwrap
        // compared against a literal.
        let hits = Self.scan(regex: #"metadata\?\["messageKind"\]"#)
        if !hits.isEmpty {
            let formatted = hits.joined(separator: "\n")
            Issue.record("Use `message.kind` instead of unwrapping the metadata by hand:\n\(formatted)")
        }
    }
}
