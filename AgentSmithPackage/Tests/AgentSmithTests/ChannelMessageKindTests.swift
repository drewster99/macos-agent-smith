import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// `ChannelMessageKind` is the typed replacement for the bare `messageKind` metadata strings.
///
/// Three things need pinning, and they fail in different ways:
///
/// 1. The WIRE STRINGS. These are persisted in `channel_log.jsonl` and read back on every launch,
///    so a raw value is a storage format, not an implementation detail. Renaming a Swift case is
///    free; changing its `rawValue` silently orphans every historical message carrying the old
///    spelling.
///
/// 2. COMPLETENESS against the persisted corpus. The enum is closed, so any kind sitting in a log
///    without a case here decodes to nil and every reader keyed on it takes the wrong branch. The
///    set that matters is "what has ever been written to disk", which is strictly larger than
///    "what the current sources emit".
///
/// 3. The ABSENCE of new bare literals. A type only removes an antipattern if the antipattern
///    can't come back, and nothing stops the next hand-written `"messageKind": .string(…)`.
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
        (.securityReview, "security_review"),
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
        (.taskAmendment, "task_amendment"),
        (.changesRequested, "changes_requested"),
        (.criteriaUpdated, "criteria_updated"),
        (.validationReport, "validation_report"),
        (.validationFailed, "validation_failed"),
        (.validationEscalation, "validation_escalation"),
        (.submissionAutoRejected, "submission_auto_rejected"),
        (.validationBlocked, "validation_blocked"),
        (.validationBlockedWorkerNotice, "validation_blocked_worker_notice"),
        (.orchestratorMessage, "orchestrator_message"),
        (.helpRequested, "help_requested"),
        (.helpProvided, "help_provided"),
        (.memorySaved, "memory_saved"),
        (.memorySearched, "memory_searched"),
        (.inboundUserMessage, "inbound_user_message"),
        (.contextManagement, "context_management"),
        (.timerActivity, "timer_activity"),
        (.mcpStatus, "mcp_status"),
        (.restartChrome, "restart_chrome"),
        (.preparing, "preparing"),
        (.agentLifecycle, "agent_lifecycle"),
        (.agentRecovery, "agent_recovery"),
        (.rateLimit, "rate_limit"),
        (.statusUpdate, "status_update"),
        (.advisory, "advisory"),
        (.agentOnline, "agent_online"),
        (.validationWaitNotice, "validation_wait_notice"),
        (.validationOverride, "validation_override"),
        (.taskInterrupted, "task_interrupted")
    ]

    @Test("Wire strings are stable — they are a persisted storage format")
    func wireStringsAreStable() {
        for (kind, expected) in Self.expectedWireStrings {
            #expect(kind.rawValue == expected, "kind \(kind) should serialize as \"\(expected)\"")
        }
    }

    @Test("Every case is covered by the wire-string table")
    func wireStringTableIsExhaustive() {
        // Without this, adding a case and forgetting to list it above would leave its raw value
        // unpinned — free to be edited later with nothing failing.
        let tabled = Set(Self.expectedWireStrings.map(\.0))
        let missing = Set(ChannelMessageKind.allCases).subtracting(tabled)
        #expect(missing.isEmpty, "cases missing from expectedWireStrings: \(missing.map(\.rawValue).sorted())")
    }

    /// Every distinct `messageKind` found in the persisted corpus on 2026-07-27: a scan of
    /// ~520 MB across `channel_log.jsonl`, `channel_log.json`, the `.old`/`.old2` rotations, the
    /// `backups/` directory, and `sessions_removed_backup-20260709/`.
    ///
    /// Four of these — `agent_online` (~4,000 occurrences), `validation_wait_notice`,
    /// `validation_override`, `task_interrupted` — appear in NO source file. They are retired
    /// kinds that only a corpus scan can find, and a closed enum without them decodes real
    /// historical messages to nil. That is the failure this test exists to prevent recurring.
    private static let kindsObservedOnDisk: [String] = [
        "tool_request", "tool_output", "agent_online", "validation_report", "task_complete",
        "restart_chrome", "task_update", "task_update_guidance", "task_summarized",
        "task_completed", "preparing", "timer_activity", "memory_searched", "task_created",
        "task_acknowledged", "changes_requested", "task_continuing", "memory_saved",
        "task_lifecycle", "task_action_scheduled", "context_management", "validation_failed",
        "criteria_updated", "scheduled_run_deferred", "validation_escalation",
        "validation_wait_notice", "help_requested", "help_provided", "validation_override",
        "mcp_status", "task_queued_at_capacity", "inbound_user_message", "task_interrupted",
        "submission_auto_rejected", "validation_blocked_worker_notice", "validation_blocked"
    ]

    @Test("Every kind ever persisted still decodes to a case")
    func historicalCorpusIsFullyDecodable() {
        let undecodable = Self.kindsObservedOnDisk.filter { ChannelMessageKind(rawValue: $0) == nil }
        #expect(
            undecodable.isEmpty,
            "these kinds exist in persisted logs but have no case — they would decode to nil: \(undecodable.sorted())"
        )
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

    /// Security-review rows were posted kindless for months before `securityReview` existed, so the
    /// persisted corpus is full of them. The accessor derives the kind from the `securityDisposition`
    /// key their producers have always stamped — this pins that historical rows classify like
    /// current ones (and that the derivation doesn't leak onto unrelated kindless messages).
    @Test("A kindless message with securityDisposition derives the securityReview kind")
    func legacySecurityReviewRowsDeriveTheirKind() {
        let legacyVerdict = ChannelMessage(
            sender: .system,
            content: "Security Agent → Brown: SAFE Read-only file access",
            metadata: ["requestID": .string("call_1"), "securityDisposition": .string("approved")]
        )
        #expect(legacyVerdict.kind == .securityReview)
        // Unrelated metadata does not trigger the derivation.
        let plainNotice = ChannelMessage(
            sender: .system,
            content: "Status update",
            metadata: ["isWarning": .bool(true)]
        )
        #expect(plainNotice.kind == nil)
        // An explicit messageKind always wins over the derivation.
        let explicit = ChannelMessage(
            sender: .system,
            content: "x",
            metadata: ["messageKind": .kind(.toolOutput), "securityDisposition": .string("approved")]
        )
        #expect(explicit.kind == .toolOutput)
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

    /// Scans both source roots, returning `(hits, scannedFileCount)`.
    ///
    /// Every failure mode here is fatal rather than skipped. A guard test that quietly ignores a
    /// root it couldn't enumerate, or a file it couldn't read, reports "no violations" for a
    /// codebase it never looked at — the most expensive kind of green.
    private static func scan(regex pattern: String) throws -> (hits: [String], filesScanned: Int) {
        let regex = try NSRegularExpression(pattern: pattern)
        var hits: [String] = []
        var filesScanned = 0
        for root in sourceRoots {
            guard let e = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else {
                Issue.record("Could not enumerate \(root.path) — the scan below covers less than it claims.")
                continue
            }
            for case let url as URL in e {
                guard url.pathExtension == "swift",
                      !exemptFileNames.contains(url.lastPathComponent) else { continue }
                let text: String
                do {
                    text = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    Issue.record("Could not read \(url.lastPathComponent): \(error). Unscanned files hide violations.")
                    continue
                }
                filesScanned += 1
                for (i, line) in text.components(separatedBy: .newlines).enumerated() {
                    // Comments may quote the old shape while explaining why it's gone.
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") else { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, range: range) != nil {
                        hits.append("\(url.lastPathComponent):\(i + 1) — \(trimmed)")
                    }
                }
            }
        }
        // A scan that found no files is not a passing scan — it means the paths are wrong and
        // the guards below would report clean for a codebase nobody looked at.
        #expect(filesScanned > 100, "only \(filesScanned) files scanned; source roots are likely wrong")
        return (hits, filesScanned)
    }

    @Test("No bare messageKind string literals are written")
    func noBareKindWrites() throws {
        // Covers both the dictionary-literal form and assignment into an existing metadata dict,
        // so a post site can't sidestep the rule by building its metadata in two steps.
        let (hits, _) = try Self.scan(regex: #""messageKind"\]?\s*[:=]\s*\.string\("#)
        if !hits.isEmpty {
            let formatted = hits.joined(separator: "\n")
            Issue.record("Use `.kind(.someKind)` instead of a raw string:\n\(formatted)")
        }
    }

    @Test("No bare messageKind string literals are compared")
    func noBareKindReads() throws {
        // Read sites must use `message.kind == .someKind`, not a hand-rolled metadata unwrap
        // compared against a literal.
        let (hits, _) = try Self.scan(regex: #"metadata\?\["messageKind"\]|stringMetadata\("messageKind"\)"#)
        if !hits.isEmpty {
            let formatted = hits.joined(separator: "\n")
            Issue.record("Use `message.kind` instead of unwrapping the metadata by hand:\n\(formatted)")
        }
    }
}
