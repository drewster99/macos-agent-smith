import Foundation
import Testing
@testable import AgentSmithKit

@Suite("Validation metrics ledger")
struct ValidationMetricsLedgerTests {

    private func makeRow(verdict: CriterionVerdictRecord.Verdict, responseLog: String = "") -> ValidationMetricsRow {
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
            taskID: UUID(),
            taskTitle: "Test task",
            sessionID: UUID(),
            contractVersion: 2
        )
    }

    @Test("Appends are JSONL: one decodable object per line, later batches appended not rewritten")
    func appendsAreAppendOnlyJSONL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = dir.appendingPathComponent("validation_metrics.jsonl")
        let ledger = ValidationMetricsLedger(fileURL: fileURL)

        await ledger.append([makeRow(verdict: .accepted), makeRow(verdict: .rejected(reason: "missing evidence"))])
        await ledger.append([makeRow(verdict: .error(message: "timed out after 600s"))])

        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        let decoder = JSONDecoder()
        let rows = try lines.map { try decoder.decode(ValidationMetricsRow.self, from: Data($0.utf8)) }
        #expect(rows.map(\.verdict) == ["accepted", "rejected", "error"])
        #expect(rows[0].detail == nil)
        #expect(rows[1].detail == "missing evidence")
        #expect(rows[2].detail == "timed out after 600s")
        #expect(rows.allSatisfy { $0.round == 3 && $0.contractVersion == 2 })
    }

    @Test("Turn and tool-call counts derive from the runner's transcript rendering")
    func transcriptCountsMatchRendering() {
        // Two tool-round turns (three calls, then one) and a final text turn, joined the way
        // EvaluationRunner composes responseLog.
        let log = [
            "→ file_read({\"path\":\"/a\"}) → contents\n→ grep({\"pattern\":\"x\"}) → hits\n→ file_read({\"path\":\"/b\"}) → contents",
            "→ directory_listing({\"path\":\"/c\"}) → entries",
            "ACCEPT"
        ].joined(separator: "\n---\n")
        let counts = ValidationMetricsRow.transcriptCounts(fromResponseLog: log)
        #expect(counts.turns == 3)
        #expect(counts.toolCalls == 4)

        let empty = ValidationMetricsRow.transcriptCounts(fromResponseLog: "")
        #expect(empty.turns == 0)
        #expect(empty.toolCalls == 0)
    }

    @Test("Oversized rejection detail is capped, not dropped")
    func detailIsCapped() {
        let row = makeRow(verdict: .rejected(reason: String(repeating: "x", count: 5000)))
        #expect(row.detail?.count == 2000)
    }
}
