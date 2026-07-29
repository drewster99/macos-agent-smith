import Foundation
import os

/// One acceptance-validation judgment, flattened for offline analysis (histograms of turns,
/// tool calls, rounds-to-accept, error taxonomy). This is the durable record the task-local
/// verdict ledger deliberately is NOT: `resetFailedTask`, `reopenCompletedTask`, and criteria
/// edits each empty `validation.verdictRecords` for correctness reasons, which also erases
/// exactly the runs (rewrites, retries) an economics analysis most wants to see. A row here is
/// telemetry — nothing in the validation machinery ever reads it back, so it survives every
/// destroyer without coupling to any of them.
public struct ValidationMetricsRow: Codable, Sendable, Equatable {
    public var recordedAt: Date
    /// `OrchestrationRuntime.currentSessionID` — the per-`start()` run UUID usage records carry,
    /// so rows group by app run the same way costs do.
    public var sessionID: UUID?
    public var taskID: UUID
    public var taskTitle: String
    public var criterionID: UUID
    /// Captured because for a default-validated criterion the name IS the judging instruction,
    /// and because the criterion may be edited or deleted after this row is written.
    public var criterionName: String
    /// "accepted" / "rejected" / "waived" / "error".
    public var verdict: String
    /// The rejection reason or error message, capped — kept so identical-rejection convergence
    /// analysis works from this file alone. Nil for accepts.
    public var detail: String?
    public var round: Int
    public var contractVersion: Int
    public var validatorName: String
    public var validatorHash: String
    /// LLM turns in the judgment conversation, derived from the runner's own transcript
    /// rendering. Telemetry only — never behavior.
    public var llmTurns: Int
    /// Evidence tool calls across those turns, same derivation.
    public var evidenceToolCalls: Int

    /// Derives (turns, tool calls) from a `CriterionVerdictRecord.responseLog`, which
    /// `EvaluationRunner` composes as turn entries joined by "\n---\n", tool rounds rendered as
    /// lines starting "→ name(…) → …". Parsing a format this module itself renders is fine for
    /// TELEMETRY; it must never steer behavior (see the no-prose-control-flow rule).
    public static func transcriptCounts(fromResponseLog log: String) -> (turns: Int, toolCalls: Int) {
        guard !log.isEmpty else { return (0, 0) }
        let turns = log.components(separatedBy: "\n---\n").count
        let toolCalls = log.components(separatedBy: "\n")
            .filter { $0.hasPrefix("→ ") }
            .count
        return (turns, toolCalls)
    }

    private static let maxDetailLength = 2000

    public init(
        record: CriterionVerdictRecord,
        criterionName: String,
        taskID: UUID,
        taskTitle: String,
        sessionID: UUID?,
        contractVersion: Int
    ) {
        self.recordedAt = record.recordedAt
        self.sessionID = sessionID
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.criterionID = record.criterionID
        self.criterionName = criterionName
        switch record.verdict {
        case .accepted:
            self.verdict = "accepted"
            self.detail = nil
        case .rejected(let reason):
            self.verdict = "rejected"
            self.detail = String(reason.prefix(Self.maxDetailLength))
        case .waived(let reason):
            self.verdict = "waived"
            self.detail = String(reason.prefix(Self.maxDetailLength))
        case .error(let message):
            self.verdict = "error"
            self.detail = String(message.prefix(Self.maxDetailLength))
        }
        self.round = record.round
        self.contractVersion = contractVersion
        self.validatorName = record.validatorName
        self.validatorHash = record.validatorHash
        let counts = Self.transcriptCounts(fromResponseLog: record.responseLog ?? "")
        self.llmTurns = counts.turns
        self.evidenceToolCalls = counts.toolCalls
    }
}

/// Append-only JSONL writer for validation judgment telemetry — one row per landed verdict,
/// written by the validation coordinator right after `recordCriterionVerdicts` returns
/// `.recorded` (the single producer of verdict records, so the two cannot drift).
///
/// SINGLE SYNCHRONIZED WRITER, by construction: every session's `OrchestrationRuntime` is
/// handed the same `shared` instance, and actor isolation serializes the appends — two
/// concurrent sessions validating at once interleave whole rows, never bytes. JSONL because
/// appends must not rewrite the file (`usage_records.json`'s whole-file rewrite is not a
/// pattern to repeat on an ever-growing log).
///
/// Tests MUST NOT touch `shared` — construct with a temp-file URL instead, same rule as
/// `PersistenceManager.init(testingRoot:)`. Runtimes default to NO ledger, so a test that
/// never opts in cannot write the real file.
public actor ValidationMetricsLedger {
    /// The process-wide writer for the real global file
    /// (`~/Library/Application Support/AgentSmith/validation_metrics.jsonl`).
    public static let shared = ValidationMetricsLedger(
        fileURL: PersistenceManager.appSupportURL()
            .appendingPathComponent("AgentSmith", isDirectory: true)
            .appendingPathComponent("validation_metrics.jsonl")
    )

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.nuclearcyborg.AgentSmith", category: "ValidationMetrics")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Appends rows as one JSON object per line. A failed append logs and drops — telemetry
    /// must never fail a validation round — but it logs loudly rather than silently, per the
    /// no-silent-fallback rule.
    public func append(_ rows: [ValidationMetricsRow]) {
        guard !rows.isEmpty else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = Data()
            for row in rows {
                data.append(try encoder.encode(row))
                data.append(0x0A)
            }
            let manager = FileManager.default
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            logger.error("validation metrics append failed (\(rows.count) row(s) dropped): \(error.localizedDescription, privacy: .public)")
        }
    }
}
