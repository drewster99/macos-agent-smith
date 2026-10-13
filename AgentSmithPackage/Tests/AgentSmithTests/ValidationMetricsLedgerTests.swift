import Foundation
import Testing
@testable import AgentSmithKit

@Suite("Validation metrics ledger")
struct ValidationMetricsLedgerTests {

    private func makeRow(
        verdict: CriterionVerdictRecord.Verdict,
        errorKind: ValidationErrorKind? = nil,
        responseLog: String = "",
        telemetry: ValidationJudgmentTelemetry = ValidationJudgmentTelemetry()
    ) -> ValidationMetricsRow {
        let record = CriterionVerdictRecord(
            criterionID: UUID(),
            verdict: verdict,
            errorKind: errorKind,
            validatorName: "default",
            validatorHash: "abcd1234",
            round: 3,
            renderedInput: "{}",
            renderedSystemPrompt: "system",
            responseLog: responseLog
        )
        return ValidationMetricsRow(
            record: record,
            criterionName: "Build succeeds",
            waivable: false,
            usesDefaultValidator: false,
            taskID: UUID(),
            taskTitle: "Test task",
            parentTaskID: UUID(),
            sessionID: UUID(),
            contractVersion: 2,
            modelID: "gpt-5.5",
            providerID: "builtin.openai",
            telemetry: telemetry
        )
    }

    @Test("Appends are JSONL: one decodable object per line, later batches appended not rewritten")
    func appendsAreAppendOnlyJSONL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = dir.appendingPathComponent("validation_metrics.jsonl")
        let ledger = ValidationMetricsLedger(fileURL: fileURL)

        ledger.append([makeRow(verdict: .accepted), makeRow(verdict: .rejected(reason: "missing evidence"))])
        ledger.append([makeRow(verdict: .error(message: "timed out after 600s"))])
        ledger.flush()

        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rows = try lines.map { try decoder.decode(ValidationMetricsRow.self, from: Data($0.utf8)) }
        #expect(rows.map(\.verdict) == ["accepted", "rejected", "error"])
        #expect(rows[0].detail == nil)
        #expect(rows[1].detail == "missing evidence")
        #expect(rows[2].detail == "timed out after 600s")
        #expect(rows.allSatisfy { $0.round == 3 && $0.contractVersion == 2 && $0.v == 1 })
        #expect(rows.allSatisfy { $0.modelID == "gpt-5.5" && $0.providerID == "builtin.openai" })
    }

    @Test("Live telemetry wins over transcript derivation and carries tokens, attempts, and duration")
    func telemetryPopulatesExecutionFields() {
        let telemetry = ValidationJudgmentTelemetry(
            llmTurns: 12,
            evidenceToolCalls: 21,
            inputTokens: 400_000,
            outputTokens: 9_000,
            cacheReadTokens: 350_000,
            attempts: 2,
            firstAttemptError: "exhausted 10 turns without a conforming result",
            durationMs: 481_000,
            dynamicItemCount: nil
        )
        let row = makeRow(verdict: .rejected(reason: "still missing"), responseLog: "ACCEPT", telemetry: telemetry)
        #expect(row.llmTurns == 12)
        #expect(row.evidenceToolCalls == 21)
        #expect(row.inputTokens == 400_000)
        #expect(row.attempts == 2)
        #expect(row.firstAttemptError == "exhausted 10 turns without a conforming result")
        #expect(row.durationMs == 481_000)
    }

    @Test("Turn and tool-call counts come from live telemetry, never from the transcript's text")
    func countsComeFromTelemetryNotTranscript() {
        // A log that LOOKS like three turns and four tool calls, rendered the way the runner renders.
        let log = [
            "→ file_read({\"path\":\"/a\"}) → contents\n→ grep({\"pattern\":\"x\"}) → hits\n→ file_read({\"path\":\"/b\"}) → contents",
            "→ directory_listing({\"path\":\"/c\"}) → entries",
            "ACCEPT"
        ].joined(separator: "\n---\n")
        let row = makeRow(verdict: .accepted, responseLog: log,
                          telemetry: ValidationJudgmentTelemetry(llmTurns: 1, evidenceToolCalls: 0))
        #expect(row.llmTurns == 1)
        #expect(row.evidenceToolCalls == 0)
        #expect(row.attempts == 1)
    }

    @Test("Oversized rejection detail is capped, not dropped")
    func detailIsCapped() {
        let row = makeRow(verdict: .rejected(reason: String(repeating: "x", count: 5000)))
        #expect(row.detail?.count == 2000)
    }

    @Test("Every error kind keeps its wire string, retired ones included")
    func errorKindWireStrings() throws {
        // Independent of the enum: renaming a case is free, changing what is written is a failure.
        let wire: [ValidationErrorKind: String] = [
            .timeout: "timeout", .cancelled: "cancelled", .transport: "transport",
            .modelChanged: "model_changed", .emptyResponse: "empty_response", .unparseable: "unparseable",
            .forcedVerdictFailed: "forced_verdict_failed", .contradictionGuard: "contradiction_guard",
            .waiveNonWaivable: "waive_non_waivable", .unexpectedVerdictToken: "unexpected_verdict_token",
            .itemsWhereVerdict: "items_where_verdict", .enumeratorFailure: "enumerator_failure",
            .invalidValidatorPrompt: "invalid_validator_prompt", .noModel: "no_model",
            .noWorkerScope: "no_worker_scope", .turnExhaustion: "turn_exhaustion", .other: "other"
        ]
        #expect(Set(ValidationErrorKind.allCases) == Set(wire.keys), "a new kind needs a pinned wire string")
        for (kind, raw) in wire {
            #expect(kind.rawValue == raw)
            #expect(try JSONDecoder().decode(ValidationErrorKind.self, from: Data("\"\(raw)\"".utf8)) == kind)
        }
    }

    @Test("Judgment and round-outcome rows share the file, discriminated by rowKind")
    func roundOutcomeRowsInterleave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = dir.appendingPathComponent("validation_metrics.jsonl")
        let ledger = ValidationMetricsLedger(fileURL: fileURL)

        ledger.append([makeRow(verdict: .rejected(reason: "nope"))])
        ledger.append(outcome: ValidationRoundOutcomeRow(
            sessionID: UUID(),
            taskID: UUID(),
            taskTitle: "Test task",
            parentTaskID: nil,
            round: 8,
            contractVersion: 1,
            outcome: .failedNoProgress,
            settledCriteria: 4,
            totalCriteria: 7,
            rejectedCriteria: 3,
            erroredCriteria: 0,
            consecutiveRoundsWithoutNewApprovals: 8,
            detail: "3 criterion(s) still rejected after 8 round(s) without a new approval"
        ))
        ledger.flush()

        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        struct KindProbe: Decodable { let rowKind: String }
        let kinds = try lines.map { try JSONDecoder().decode(KindProbe.self, from: Data($0.utf8)).rowKind }
        #expect(kinds == ["judgment", "roundOutcome"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outcome = try decoder.decode(ValidationRoundOutcomeRow.self, from: Data(lines[1].utf8))
        #expect(outcome.outcome == .failedNoProgress)
        #expect(outcome.v == 2)
        #expect(lines[1].contains(#""outcome":"failed_no_progress""#))
        #expect(outcome.settledCriteria == 4 && outcome.totalCriteria == 7)
        #expect(outcome.consecutiveRoundsWithoutNewApprovals == 8)
    }

    /// Raw values are the file format: renaming a case is free, changing a wire string is not.
    @Test("Round-outcome wire strings are pinned")
    func roundOutcomeWireStringsArePinned() {
        let table: [(ValidationRoundOutcome, String)] = [
            (.completed, "completed"),
            (.userAcceptanceRequested, "user_acceptance_requested"),
            (.escalatedOnValidatorError, "escalated"),
            (.failedNoProgress, "failed_no_progress"),
            (.rejectionsReturned, "rejections_returned")
        ]
        for (outcome, wire) in table {
            #expect(outcome.rawValue == wire)
        }
        #expect(Set(ValidationRoundOutcome.allCases) == Set(table.map(\.0)))
        #expect(ValidationRoundOutcome.allCases.count == table.count)
    }

    /// v1 rows (every outcome string ever written) still decode, with their own version.
    @Test("v1 round-outcome rows still decode")
    func v1RoundOutcomeRowsDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let expected: [(String, ValidationRoundOutcome)] = [
            ("completed", .completed), ("escalated", .escalatedOnValidatorError),
            ("failed_no_progress", .failedNoProgress), ("rejections_returned", .rejectionsReturned)
        ]
        for (wire, outcome) in expected {
            let line = #"{"contractVersion":1,"erroredCriteria":0,"outcome":"\#(wire)","recordedAt":"2026-10-01T12:00:00Z","rejectedCriteria":0,"round":1,"rowKind":"roundOutcome","settledCriteria":1,"taskID":"\#(UUID().uuidString)","taskTitle":"t","totalCriteria":1,"v":1}"#
            let row = try decoder.decode(ValidationRoundOutcomeRow.self, from: Data(line.utf8))
            #expect(row.v == 1)
            #expect(row.outcome == outcome)
        }
    }

    @Test("A park's outcome is derived from its reason")
    func parkReasonMapsToOutcome() {
        #expect(ValidationRoundOutcome(parkingFor: .validatorError) == .escalatedOnValidatorError)
        #expect(ValidationRoundOutcome(parkingFor: .userAcceptanceRequested) == .userAcceptanceRequested)
    }

    @Test("An errored judgment row carries the kind its producer declared, whatever the message says")
    func errorRowsCarryKind() {
        let telemetry = ValidationJudgmentTelemetry(attempts: 2, firstAttemptError: "LLM call failed: timed out after 600s",
                                                    firstAttemptErrorKind: .transport)
        // A message that reads like a different kind: the declared kind is what's written.
        let row = makeRow(verdict: .error(message: "timed out after 600s, then cancelled"), errorKind: .forcedVerdictFailed,
                          telemetry: telemetry)
        #expect(row.errorKind == .forcedVerdictFailed)
        #expect(row.firstAttemptErrorKind == .transport)
        #expect(makeRow(verdict: .rejected(reason: "timed out")).errorKind == nil)
    }

    @Test("The telemetry box accumulates across attempts and keeps the FIRST error")
    func telemetryBoxAccumulates() {
        let box = JudgmentTelemetryBox()
        box.noteRetry(firstError: EvaluationRunner.Failure(.timeout, "first failure"))
        box.noteRetry(firstError: EvaluationRunner.Failure(.transport, "second failure"))
        box.noteDynamicItemCount(7)
        let snapshot = box.snapshot()
        #expect(snapshot.attempts == 3)
        #expect(snapshot.firstAttemptError == "first failure")
        #expect(snapshot.firstAttemptErrorKind == .timeout)
        #expect(snapshot.dynamicItemCount == 7)
        #expect(snapshot.llmTurns == 0)
    }
}
