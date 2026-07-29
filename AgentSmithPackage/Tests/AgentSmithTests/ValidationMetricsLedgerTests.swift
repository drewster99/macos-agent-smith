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
