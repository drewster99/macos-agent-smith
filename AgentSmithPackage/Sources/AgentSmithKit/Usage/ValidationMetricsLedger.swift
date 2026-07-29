import Foundation
import os

/// Per-judgment execution telemetry, captured live by the coordinator (LLM calls observed via
/// `onResponse`, retries noted where they happen) rather than re-derived from the persisted
/// transcript. Optional on a row: rows built without it (or read from old files) simply carry
/// nil token fields and transcript-derived counts.
public struct ValidationJudgmentTelemetry: Sendable, Equatable {
    /// LLM calls across the whole judgment — BOTH attempts when an ERROR was retried, and for
    /// dynamic criteria the prepare exchange plus every per-item exchange.
    public var llmTurns: Int
    /// Evidence tool calls across those turns, same scope.
    public var evidenceToolCalls: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    /// 1 for a clean judgment; +1 per internal ERROR retry (plain criteria retry once; a
    /// dynamic criterion's prepare and each item can each retry once).
    public var attempts: Int
    /// The first attempt's error when a retry happened — the previously INVISIBLE population
    /// (a rescued turn-exhaustion left no trace anywhere but the usage records).
    public var firstAttemptError: String?
    public var durationMs: Int
    /// For dynamic (enumerated) criteria: how many items the prepare emitted. Nil for plain.
    public var dynamicItemCount: Int?

    public init(
        llmTurns: Int = 0,
        evidenceToolCalls: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        attempts: Int = 1,
        firstAttemptError: String? = nil,
        durationMs: Int = 0,
        dynamicItemCount: Int? = nil
    ) {
        self.llmTurns = llmTurns
        self.evidenceToolCalls = evidenceToolCalls
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.attempts = attempts
        self.firstAttemptError = firstAttemptError
        self.durationMs = durationMs
        self.dynamicItemCount = dynamicItemCount
    }
}

/// One acceptance-validation judgment, flattened for offline analysis (histograms of turns,
/// tool calls, tokens, rounds-to-accept, error taxonomy, per-template economics). This is the
/// durable record the task-local verdict ledger deliberately is NOT: `resetFailedTask`,
/// `reopenCompletedTask`, and criteria edits each empty `validation.verdictRecords` for
/// correctness reasons, which also erases exactly the runs (rewrites, retries) an economics
/// analysis most wants to see. A row here is telemetry — nothing in the validation machinery
/// ever reads it back, so it survives every destroyer without coupling to any of them.
///
/// Flat keys, no nesting, ISO-8601 dates, and a schema version — deliberately `jq`-friendly:
/// `jq 'select(.verdict=="rejected") | .llmTurns'` should never need a join or a nested path.
public struct ValidationMetricsRow: Codable, Sendable, Equatable {
    /// Schema version; bump when a field changes meaning (adding fields is free).
    public var v: Int = 1
    public var recordedAt: Date
    /// `OrchestrationRuntime.currentSessionID` — the per-`start()` run UUID usage records carry,
    /// so rows group by app run the same way costs do.
    public var sessionID: UUID?
    public var taskID: UUID
    public var taskTitle: String
    /// The template this task was instantiated from, when it was — per-template economics
    /// ("what does a SwiftUI-audit run cost?") group by this.
    public var parentTaskID: UUID?
    public var criterionID: UUID
    /// Captured because for a default-validated criterion the name IS the judging instruction,
    /// and because the criterion may be edited or deleted after this row is written.
    public var criterionName: String
    public var waivable: Bool
    public var usesDefaultValidator: Bool
    /// "accepted" / "rejected" / "waived" / "error".
    public var verdict: String
    /// The rejection reason or error message, capped — kept so identical-rejection convergence
    /// analysis works from this file alone. Nil for accepts.
    public var detail: String?
    public var round: Int
    public var contractVersion: Int
    public var validatorName: String
    public var validatorHash: String
    /// Traceability to the exact model that judged (validator-slot config at judgment time).
    public var modelID: String?
    public var providerID: String?
    /// See `ValidationJudgmentTelemetry.attempts` / `.firstAttemptError`.
    public var attempts: Int
    public var firstAttemptError: String?
    /// From live telemetry when available (total across attempts); otherwise derived from the
    /// record's own transcript rendering (final attempt only).
    public var llmTurns: Int
    public var evidenceToolCalls: Int
    /// Nil = unknown (no live telemetry, e.g. rows synthesized from old verdict records).
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var durationMs: Int?
    public var dynamicItemCount: Int?

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
        waivable: Bool,
        usesDefaultValidator: Bool,
        taskID: UUID,
        taskTitle: String,
        parentTaskID: UUID?,
        sessionID: UUID?,
        contractVersion: Int,
        modelID: String?,
        providerID: String?,
        telemetry: ValidationJudgmentTelemetry?
    ) {
        self.recordedAt = record.recordedAt
        self.sessionID = sessionID
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.parentTaskID = parentTaskID
        self.criterionID = record.criterionID
        self.criterionName = criterionName
        self.waivable = waivable
        self.usesDefaultValidator = usesDefaultValidator
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
        self.modelID = modelID
        self.providerID = providerID
        if let telemetry {
            self.attempts = telemetry.attempts
            self.firstAttemptError = telemetry.firstAttemptError.map { String($0.prefix(Self.maxDetailLength)) }
            self.llmTurns = telemetry.llmTurns
            self.evidenceToolCalls = telemetry.evidenceToolCalls
            self.inputTokens = telemetry.inputTokens
            self.outputTokens = telemetry.outputTokens
            self.cacheReadTokens = telemetry.cacheReadTokens
            self.durationMs = telemetry.durationMs
            self.dynamicItemCount = telemetry.dynamicItemCount
        } else {
            let counts = Self.transcriptCounts(fromResponseLog: record.responseLog ?? "")
            self.attempts = 1
            self.firstAttemptError = nil
            self.llmTurns = counts.turns
            self.evidenceToolCalls = counts.toolCalls
            self.inputTokens = nil
            self.outputTokens = nil
            self.cacheReadTokens = nil
            self.durationMs = nil
            self.dynamicItemCount = nil
        }
    }
}

/// Append-only JSONL writer for validation judgment telemetry — one row per landed verdict,
/// written by the validation coordinator right after `recordCriterionVerdicts` returns
/// `.recorded` (the single producer of verdict records, so the two cannot drift).
///
/// SINGLE SYNCHRONIZED WRITER, by construction: every session's `OrchestrationRuntime` is
/// handed the same `shared` instance, and one private SERIAL `DispatchQueue` performs every
/// encode and write — two concurrent sessions validating at once interleave whole rows,
/// never bytes. Deliberately a dispatch queue and NOT an actor: `append` is a synchronous
/// fire-and-forget enqueue, so the validation path never suspends on file I/O, and the
/// blocking write itself runs on a GCD utility thread instead of parking a thread of the
/// Swift-concurrency cooperative pool.
///
/// Tests MUST NOT touch `shared` — construct with a temp-file URL instead, same rule as
/// `PersistenceManager.init(testingRoot:)`. Runtimes default to NO ledger, so a test that
/// never opts in cannot write the real file.
public final class ValidationMetricsLedger: Sendable {
    /// The process-wide writer for the real global file
    /// (`~/Library/Application Support/AgentSmith/validation_metrics.jsonl`).
    public static let shared = ValidationMetricsLedger(
        fileURL: PersistenceManager.appSupportURL()
            .appendingPathComponent("AgentSmith", isDirectory: true)
            .appendingPathComponent("validation_metrics.jsonl")
    )

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.nuclearcyborg.AgentSmith.validation-metrics", qos: .utility)
    private let logger = Logger(subsystem: "com.nuclearcyborg.AgentSmith", category: "ValidationMetrics")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Enqueues rows and returns immediately; the serial queue encodes and appends them as one
    /// JSON object per line (ISO-8601 dates, sorted keys). A failed write logs and drops —
    /// telemetry must never fail a validation round — but it logs loudly rather than silently,
    /// per the no-silent-fallback rule.
    public func append(_ rows: [ValidationMetricsRow]) {
        guard !rows.isEmpty else { return }
        queue.async { [fileURL, logger] in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
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

    /// Blocks until every append enqueued so far has hit the file. For tests and shutdown
    /// paths only — production callers fire and forget.
    public func flush() {
        queue.sync {}
    }
}
