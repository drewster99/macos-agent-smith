import Foundation
import Testing
@testable import AgentSmithKit

@Suite("Validation metrics ledger")
struct ValidationMetricsLedgerTests {

    private func makeRow(
        verdict: CriterionVerdictRecord.Verdict,
        responseLog: String = "",
        telemetry: ValidationJudgmentTelemetry? = nil
    ) -> ValidationMetricsRow {
        let record = CriterionVerdictRecord(
            criterionID: UUID(),
            verdict: verdict,
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

    @Test("Without telemetry, turn and tool-call counts derive from the runner's transcript rendering")
    func transcriptCountsMatchRendering() {
        // Two tool-round turns (three calls, then one) and a final text turn, joined the way
        // EvaluationRunner composes responseLog.
        let log = [
            "→ file_read({\"path\":\"/a\"}) → contents\n→ grep({\"pattern\":\"x\"}) → hits\n→ file_read({\"path\":\"/b\"}) → contents",
            "→ directory_listing({\"path\":\"/c\"}) → entries",
            "ACCEPT"
        ].joined(separator: "\n---\n")
        let row = makeRow(verdict: .accepted, responseLog: log)
        #expect(row.llmTurns == 3)
        #expect(row.evidenceToolCalls == 4)
        #expect(row.inputTokens == nil)
        #expect(row.attempts == 1)

        let empty = ValidationMetricsRow.transcriptCounts(fromResponseLog: "")
        #expect(empty.turns == 0)
        #expect(empty.toolCalls == 0)
    }

    @Test("Oversized rejection detail is capped, not dropped")
    func detailIsCapped() {
        let row = makeRow(verdict: .rejected(reason: String(repeating: "x", count: 5000)))
        #expect(row.detail?.count == 2000)
    }

    @Test("Error kinds classify from our own message formats, including dynamic-criterion wrappers")
    func errorKindClassification() {
        let cases: [(String, String)] = [
            ("exhausted 10 turns without a conforming result", "turn_exhaustion"),
            ("item 3 (foo.txt): exhausted 10 turns without a conforming result", "turn_exhaustion"),
            ("timed out after 600s", "timeout"),
            ("prepare 'x-input-enumerator' failed: timed out after 600s", "timeout"),
            ("cancelled", "cancelled"),
            ("LLM call failed: The request timed out.", "transport"),
            ("empty response from validator; retrying requires a fresh validator conversation", "empty_response"),
            ("unparseable after 3 attempts: no verdict token", "unparseable"),
            ("validator rejection contradicted successful file_read for /a; discarding this validator attempt", "contradiction_guard"),
            ("validator attempted to WAIVE a non-waivable criterion: n/a", "waive_non_waivable"),
            ("unexpected verdict token 'MAYBE' ()", "unexpected_verdict_token"),
            ("validator returned items where a verdict was required", "items_where_verdict"),
            ("prepare 'x' emitted 900 items (cap 200) — narrow the prepare or split the criterion", "enumerator_failure"),
            ("input enumerator is unavailable", "enumerator_failure"),
            ("no model is assigned to the Validator role", "no_model"),
            ("worker tool scope (task.approvedTools) is unavailable — cannot judge feasibility; escalating for manual review", "no_worker_scope"),
            ("something entirely new", "other")
        ]
        for (message, expected) in cases {
            #expect(ValidationErrorKind.classify(message) == expected, "\(message)")
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
            outcome: "failed_no_progress",
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
        #expect(outcome.outcome == "failed_no_progress")
        #expect(outcome.settledCriteria == 4 && outcome.totalCriteria == 7)
        #expect(outcome.consecutiveRoundsWithoutNewApprovals == 8)
    }

    @Test("An errored judgment row carries the typed kind alongside the prose")
    func errorRowsCarryKind() {
        let telemetry = ValidationJudgmentTelemetry(attempts: 2, firstAttemptError: "timed out after 600s")
        let row = makeRow(verdict: .error(message: "exhausted 10 turns without a conforming result"), telemetry: telemetry)
        #expect(row.errorKind == "turn_exhaustion")
        #expect(row.firstAttemptErrorKind == "timeout")
    }

    @Test("The telemetry box accumulates across attempts and keeps the FIRST error")
    func telemetryBoxAccumulates() {
        let box = JudgmentTelemetryBox()
        box.noteRetry(firstError: "first failure")
        box.noteRetry(firstError: "second failure")
        box.noteDynamicItemCount(7)
        let snapshot = box.snapshot()
        #expect(snapshot.attempts == 3)
        #expect(snapshot.firstAttemptError == "first failure")
        #expect(snapshot.dynamicItemCount == 7)
        #expect(snapshot.llmTurns == 0)
    }
}
