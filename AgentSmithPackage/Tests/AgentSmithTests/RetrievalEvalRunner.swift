import Testing
import Foundation
@testable import AgentSmithKit
import SemanticSearch

// Gated on a compile flag, NOT a runtime env var: `swift test` can't compile the MLX Metal
// shaders this needs, and xcodebuild doesn't forward shell env to the package-scheme test
// runner. Build with `xcodebuild test -scheme AgentSmithPackage OTHER_SWIFT_FLAGS='$(inherited) -DRETRIEVAL_EVAL'`
// so a normal `swift test` simply never compiles this file.
#if RETRIEVAL_EVAL

/// Objective retrieval-precision eval for the "improve prior-task relevance" work (ROADMAP #2).
///
/// Runs the **real** `MemoryStore.searchAll` path (real Qwen3 embeddings, real RRF + gating)
/// over a frozen snapshot of the user's actual corpus, scored against LLM-judged ground truth.
/// See `RetrievalEval/README.md` for how the corpus + labels are built.
///
/// Requires Xcode's build pipeline (MLX Metal shaders). Run via the package scheme with the
/// `RETRIEVAL_EVAL` compile flag (`swift test` can't compile the shaders, and the `#if` keeps
/// this file out of a normal `swift test`):
///
///   xcodebuild test -scheme AgentSmithPackage -destination 'platform=macOS' \
///       -only-testing:AgentSmithTests/RetrievalEvalRunner \
///       OTHER_SWIFT_FLAGS='$(inherited) -DRETRIEVAL_EVAL'
///
/// The data dir is found via `#filePath` (no env needed); set `$RETRIEVAL_EVAL_DATA` to override.
///
/// The run over-fetches candidates and applies an injection-gate filter in-harness, so a single
/// MLX run prints the current baseline AND a sweep over candidate gate thresholds — i.e. it
/// quantifies Lever 1 (an absolute relevance gate) before any production change.
@Suite("Retrieval Eval", .serialized)
struct RetrievalEvalRunner {

    // Production attaches up to this many per pool (CreateTaskTool: memoryLimit:3, taskLimit:3).
    private static let K = 3
    // Injection-gate thresholds to sweep. 0.0 == current behavior (no absolute gate).
    // Range pushed high because Qwen3 cosines are compressed into a high band.
    private static let gates: [Double] = [0.0, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85]

    // Frozen corpus dir to score against. "frozen" = original mean-pooled vectors (NEVER
    // overwritten). Any other name is generated once by re-embedding the canonical text with the
    // package's CURRENT pooling, so we can A/B without touching the original or production data.
    private static let frozenSubdir = "frozen_lasttoken"

    // Qwen3-Embedding instruction prefixes — applied to the QUERY only; documents stay raw.
    // Two-way (per pool): prior-task retrieval vs memory/notes retrieval.
    private static let taskInstruct = "Return related tasks"
    private static let memoryInstruct = "Return related memories"

    private func instructed(_ instruction: String, _ query: String) -> String {
        "Instruct: \(instruction)\nQuery: \(query)"
    }

    @Test
    func baselineAndGateSweep() async throws {
        let data = try dataDir()
        let engine = SemanticSearchEngine()
        for try await _ in engine.prepare() { /* drain progress */ }
        // Generate the chosen frozen corpus (once) by re-embedding the canonical text with the
        // package's current pooling. Writes only NEW files; `frozen/` and production stay untouched.
        try await ensureFrozen(Self.frozenSubdir, data: data, engine: engine)
        let tasks = try decodeJSON([TaskSummaryEntry].self, data.appending(path: "\(Self.frozenSubdir)/task_summaries.json"))
        let memories = try decodeJSON([MemoryEntry].self, data.appending(path: "\(Self.frozenSubdir)/memories.json"))
        let labels = try decodeJSON([String: Label].self, data.appending(path: "labels.json"))
        let excludeByQuery = try loadExcludeIDs(data)
        let store = MemoryStore(engine: engine)

        // Two rankings, scored side by side and split into ALL / TASK pool / MEMORY pool:
        //  • RRF — production's fused semantic+lexical ranking (top-K per pool, no gate).
        //  • Semantic — pure cosine ranking, swept across the absolute gate. This is the surface
        //    we optimize in isolation; lexical is recombined (back to RRF) once it's tuned.
        // Gold is partitioned the same way, so a task query whose only relevant doc is a memory
        // is a no-answer case *for the task pool* — exactly how production buckets them.
        let taskIDs = Set(tasks.map { $0.id.uuidString })
        let memoryIDs = Set(memories.map { $0.id.uuidString })
        var semAll = [Double: GateTally](), semTask = [Double: GateTally](), semMem = [Double: GateTally]()
        for g in Self.gates { semAll[g] = GateTally(); semTask[g] = GateTally(); semMem[g] = GateTally() }
        var rrfAll = GateTally(), rrfTask = GateTally(), rrfMem = GateTally()
        // Semantic + per-pool Qwen3 instruction prefix.
        var semInstrTask = [Double: GateTally](), semInstrMem = [Double: GateTally]()
        for g in Self.gates { semInstrTask[g] = GateTally(); semInstrMem[g] = GateTally() }
        var semInstrAll = GateTally()
        var scored = 0
        // Cosine separability of the semantic-baseline injected docs (gold hits vs false positives),
        // for raw queries and for instruction-prefixed queries.
        var goldSims: [Double] = [], otherSims: [Double] = []
        var instrGoldSims: [Double] = [], instrOtherSims: [Double] = []

        for (qid, label) in labels.sorted(by: { $0.key < $1.key }) {
            if label.uncovered == true { continue }
            let excluded = Set((excludeByQuery[qid] ?? []))
            // Simulate "the source task's own summary doesn't exist at search time": exclude it
            // from candidates, not just from results, so ranking happens over the real set.
            await store.clear()
            await store.restore(
                memories: memories,
                taskSummaries: tasks.filter { !excluded.contains($0.id.uuidString) }
            )

            // Fetch the whole corpus per pool so a cosine re-rank can't miss a high-cosine /
            // low-RRF doc that a small top-N would truncate.
            let results = try await store.searchAll(query: label.text, memoryLimit: 200, taskLimit: 200)
            let docs = rankedDocs(results)
            let gold = Dictionary(uniqueKeysWithValues: label.gold.map { ($0.id, $0.grade) })
            let goldTasks = gold.filter { taskIDs.contains($0.key) }
            let goldMems = gold.filter { memoryIDs.contains($0.key) }
            scored += 1

            // Production RRF ranking: top-K per pool by the fused score, no cutoff.
            let rTasks = Array(docs.filter { $0.isTask }.sorted { $0.rrf > $1.rrf }.prefix(Self.K))
            let rMems = Array(docs.filter { !$0.isTask }.sorted { $0.rrf > $1.rrf }.prefix(Self.K))
            rrfAll.accumulate(injected: (rTasks + rMems).sorted { $0.rrf > $1.rrf }, gold: gold)
            rrfTask.accumulate(injected: rTasks, gold: goldTasks)
            rrfMem.accumulate(injected: rMems, gold: goldMems)

            // Semantic-only ranking: pure cosine, swept across the absolute gate.
            let semRanked = docs.sorted { $0.cosine > $1.cosine }
            for g in Self.gates {
                let kept = semRanked.filter { $0.cosine >= g }
                let injTasks = Array(kept.filter { $0.isTask }.prefix(Self.K))
                let injMems = Array(kept.filter { !$0.isTask }.prefix(Self.K))
                let injectedSet = Set(injTasks.map(\.id)).union(injMems.map(\.id))
                let injectedOrdered = kept.filter { injectedSet.contains($0.id) }
                semAll[g]?.accumulate(injected: injectedOrdered, gold: gold)
                semTask[g]?.accumulate(injected: injTasks, gold: goldTasks)
                semMem[g]?.accumulate(injected: injMems, gold: goldMems)
                if g == 0.0 {
                    for d in injectedOrdered {
                        if gold[d.id] != nil { goldSims.append(d.cosine) } else { otherSims.append(d.cosine) }
                    }
                }
            }

            // Semantic + per-pool instruction (query-side only; docs already raw → no re-embed).
            let instrTaskDocs = rankedDocs(try await store.searchAll(
                query: instructed(Self.taskInstruct, label.text), memoryLimit: 200, taskLimit: 200))
                .filter { $0.isTask }.sorted { $0.cosine > $1.cosine }
            let instrMemDocs = rankedDocs(try await store.searchAll(
                query: instructed(Self.memoryInstruct, label.text), memoryLimit: 200, taskLimit: 200))
                .filter { !$0.isTask }.sorted { $0.cosine > $1.cosine }
            for g in Self.gates {
                let injT = Array(instrTaskDocs.filter { $0.cosine >= g }.prefix(Self.K))
                let injM = Array(instrMemDocs.filter { $0.cosine >= g }.prefix(Self.K))
                semInstrTask[g]?.accumulate(injected: injT, gold: goldTasks)
                semInstrMem[g]?.accumulate(injected: injM, gold: goldMems)
                if g == 0.0 {
                    semInstrAll.accumulate(injected: injT + injM, gold: gold)
                    for d in injT + injM {
                        if gold[d.id] != nil { instrGoldSims.append(d.cosine) } else { instrOtherSims.append(d.cosine) }
                    }
                }
            }
        }

        printComparison(rows: [("ALL", rrfAll, semAll[0.0]!, semInstrAll),
                               ("TASK", rrfTask, semTask[0.0]!, semInstrTask[0.0]!),
                               ("MEMORY", rrfMem, semMem[0.0]!, semInstrMem[0.0]!)])
        printReport(title: "SEMANTIC-ONLY · TASK POOL", tally: semTask)
        printReport(title: "SEMANTIC-ONLY · MEMORY POOL", tally: semMem)
        printReport(title: "SEMANTIC+INSTRUCT · TASK POOL", tally: semInstrTask)
        printReport(title: "SEMANTIC+INSTRUCT · MEMORY POOL", tally: semInstrMem)
        print("-- cosine separability: gold hits (TP) vs false positives (FP) --")
        print("  raw semantic    GOLD: " + percentiles(goldSims))
        print("  raw semantic    FP:   " + percentiles(otherSims))
        print("  + instruction   GOLD: " + percentiles(instrGoldSims))
        print("  + instruction   FP:   " + percentiles(instrOtherSims))
        print("========================================================\n")
        #expect(scored > 0, "no scorable queries found — check the RetrievalEval/data dir")
    }

    // MARK: - Metrics

    private struct GateTally {
        var precisionSum = 0.0, precisionN = 0       // over queries that injected ≥1
        var recallSum = 0.0, recallN = 0             // over queries with non-empty gold
        var ndcgSum = 0.0, ndcgN = 0                 // over queries with non-empty gold
        var noAnswerN = 0, falseInjectN = 0          // over queries with empty gold

        // Per-query outcome categories (mutually exclusive within each group).
        // with-gold group:
        var perfect = 0            // injected == gold exactly
        var allRightPlusExtra = 0  // every gold doc returned, but with non-gold extras (recall=1, prec<1)
        var partial = 0            // some gold hit, but missed some and/or added junk
        var allWrong = 0           // returned ≥1, none relevant
        var missed = 0             // returned nothing despite gold existing
        var topRelevant = 0        // #1-ranked injected doc is gold (overlay on the above)
        var topBest = 0            // #1-ranked injected doc is a highest-graded gold doc (overlay)
        // no-answer group:
        var correctlySilent = 0    // empty gold, returned nothing ✓

        // Micro (document-pooled) confusion counts across all queries:
        // TP = relevant doc injected, FP = non-relevant doc injected, FN = relevant doc missed.
        // (TN is degenerate here — the whole corpus minus a handful — so we report P/R/F1, not accuracy.)
        var tp = 0, fp = 0, fn = 0
        var fpNoAnswer = 0, fpWithGold = 0   // where the false positives come from

        mutating func accumulate(injected: [RankedDoc], gold: [String: Int]) {
            let injectedIDs = injected.map(\.id)
            let injectedSet = Set(injectedIDs)
            let goldSet = Set(gold.keys)
            let hits = injectedSet.intersection(goldSet).count

            if gold.isEmpty {
                noAnswerN += 1
                fp += injected.count; fpNoAnswer += injected.count   // every inject on a no-answer query is a FP
                if injected.isEmpty { correctlySilent += 1 } else { falseInjectN += 1 }
                return
            }
            // with-gold: pool document-level confusion counts.
            tp += hits
            fp += injected.count - hits; fpWithGold += injected.count - hits
            fn += gold.count - hits

            // Outcome category (with-gold).
            if injected.isEmpty {
                missed += 1
            } else if hits == 0 {
                allWrong += 1
            } else if injectedSet == goldSet {
                perfect += 1
            } else if goldSet.isSubset(of: injectedSet) {
                allRightPlusExtra += 1
            } else {
                partial += 1
            }
            if let top = injectedIDs.first, gold[top] != nil {
                topRelevant += 1
                if let maxGrade = gold.values.max(), gold[top] == maxGrade { topBest += 1 }
            }

            if !injected.isEmpty {
                precisionSum += Double(hits) / Double(injected.count); precisionN += 1
            }
            recallSum += Double(hits) / Double(gold.count); recallN += 1

            // nDCG@(K per pool) over the injected docs in their fused-rank order, grade = gain.
            var dcg = 0.0
            for (i, id) in injectedIDs.enumerated() {
                let gain = Double(gold[id] ?? 0)
                if gain > 0 { dcg += (pow(2, gain) - 1) / log2(Double(i + 2)) }
            }
            let ideal = gold.values.sorted(by: >).prefix(injected.count).enumerated()
                .reduce(0.0) { $0 + (pow(2, Double($1.element)) - 1) / log2(Double($1.offset + 2)) }
            ndcgSum += ideal > 0 ? dcg / ideal : 0; ndcgN += 1
        }

        // Macro (per-query averaged) — every query counts equally regardless of gold size.
        var precision: Double { precisionN > 0 ? precisionSum / Double(precisionN) : 0 }
        var recall: Double { recallN > 0 ? recallSum / Double(recallN) : 0 }
        var ndcg: Double { ndcgN > 0 ? ndcgSum / Double(ndcgN) : 0 }
        var falseInjectRate: Double { noAnswerN > 0 ? Double(falseInjectN) / Double(noAnswerN) : 0 }

        // Micro (document-pooled) — the headline correctness numbers.
        var microPrecision: Double { (tp + fp) > 0 ? Double(tp) / Double(tp + fp) : 0 }
        var microRecall: Double { (tp + fn) > 0 ? Double(tp) / Double(tp + fn) : 0 }
        var microF1: Double {
            let p = microPrecision, r = microRecall
            return (p + r) > 0 ? 2 * p * r / (p + r) : 0
        }
    }

    /// A returned doc carrying BOTH scores: `cosine` (pure semantic) and `rrf` (production's
    /// fused semantic+lexical). Callers sort by whichever ranking they're measuring.
    private struct RankedDoc { let id: String; let cosine: Double; let rrf: Double; let isTask: Bool }

    private func rankedDocs(_ r: SemanticSearchResults) -> [RankedDoc] {
        r.taskSummaries.map { RankedDoc(id: $0.summary.id.uuidString, cosine: $0.similarity, rrf: $0.rrfScore, isTask: true) }
        + r.memories.map { RankedDoc(id: $0.memory.id.uuidString, cosine: $0.similarity, rrf: $0.rrfScore, isTask: false) }
    }

    /// Right-pads `s` to width `w` for tabular alignment.
    private func col(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
    }
    private func pct(_ x: Int, _ total: Int) -> String {
        total > 0 ? String(format: "%.1f%%", Double(x) / Double(total) * 100) : "—"
    }

    /// Percentile summary of a list of cosine values, for the separability readout.
    private func percentiles(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "n=0" }
        let s = xs.sorted()
        func p(_ q: Double) -> Double { s[Int(q * Double(s.count - 1))] }
        return String(format: "n=%d  min=%.3f  p10=%.3f  p25=%.3f  med=%.3f  p75=%.3f  p90=%.3f  max=%.3f",
                      s.count, s.first ?? 0, p(0.10), p(0.25), p(0.50), p(0.75), p(0.90), s.last ?? 0)
    }

    /// Headline: production's fused RRF ranking vs pure-semantic ranking, baseline (no cutoff),
    /// per pool — so we can see how much the lexical channel is buying before optimizing semantic.
    private func printComparison(rows: [(String, GateTally, GateTally, GateTally)]) {
        func f(_ x: Double) -> String { String(format: "%.1f", x * 100) }
        print("\n=== RANKING COMPARISON · baseline, no cutoff ===")
        print("RRF = production fused semantic+lexical · Semantic = cosine only · Sem+Instruct = Qwen3 instruction-prefixed query")
        print(col("pool", 8) + col("ranking", 14) + col("P%", 8) + col("R%", 8) + col("F1%", 8) + col("falseInj%", 11))
        for (pool, rrf, sem, instr) in rows {
            for (name, t) in [("RRF", rrf), ("Semantic", sem), ("Sem+Instruct", instr)] {
                print(col(pool, 8) + col(name, 14) + col(f(t.microPrecision), 8) + col(f(t.microRecall), 8)
                      + col(f(t.microF1), 8) + col(f(t.falseInjectRate), 11))
            }
        }
    }

    /// Counts come from the baseline tally itself (recallN = #with-gold, noAnswerN = #no-answer)
    /// so each pool view reports its own with-gold / no-answer split correctly.
    private func printReport(title: String, tally: [Double: GateTally]) {
        guard let b0 = tally[0.0] else { return }
        let withGold = b0.recallN
        let noAnswer = b0.noAnswerN

        print("\n==================== \(title) ====================")
        print("with-gold: \(withGold)   no-answer: \(noAnswer)")
        print("Document-level correctness per injection gate (micro-pooled):")
        print("  TP = relevant doc injected · FP = non-relevant injected · FN = relevant missed\n")
        print(col("gate", 5) + col("TP", 6) + col("FP", 6) + col("FN", 6)
              + col("Prec%", 9) + col("Rec%", 9) + col("F1%", 9) + col("falseInj%", 11))
        for g in Self.gates {
            let t = tally[g]!
            print(col(String(format: "%.2f", g), 5) + col("\(t.tp)", 6) + col("\(t.fp)", 6) + col("\(t.fn)", 6)
                  + col(String(format: "%.1f", t.microPrecision * 100), 9)
                  + col(String(format: "%.1f", t.microRecall * 100), 9)
                  + col(String(format: "%.1f", t.microF1 * 100), 9)
                  + col(String(format: "%.1f", t.falseInjectRate * 100), 11))
        }

        if let b = tally[0.0] {
            print("\n-- baseline (gate 0.00) detail --")
            print("  Correctness: precision \(String(format: "%.1f%%", b.microPrecision * 100))"
                  + " · recall \(String(format: "%.1f%%", b.microRecall * 100))"
                  + " · F1 \(String(format: "%.1f%%", b.microF1 * 100))")
            print("  False positives: \(b.fp) total — \(b.fpNoAnswer) from no-answer queries, "
                  + "\(b.fpWithGold) from with-gold queries")
            print("  False negatives (relevant docs missed): \(b.fn)")
            print("  WITH-GOLD query outcomes (\(withGold)):")
            print("    perfect (all & only right):   \(b.perfect)  (\(pct(b.perfect, withGold)))")
            print("    all right + junk extras:      \(b.allRightPlusExtra)  (\(pct(b.allRightPlusExtra, withGold)))")
            print("    partial (missed and/or junk): \(b.partial)  (\(pct(b.partial, withGold)))")
            print("    all wrong (only junk):        \(b.allWrong)  (\(pct(b.allWrong, withGold)))")
            print("    missed (returned nothing):    \(b.missed)  (\(pct(b.missed, withGold)))")
            print("    top hit relevant:             \(b.topRelevant)  (\(pct(b.topRelevant, withGold)))"
                  + " — best-graded: \(b.topBest)  (\(pct(b.topBest, withGold)))")
            print("  NO-ANSWER query outcomes (\(noAnswer)):")
            print("    correctly silent:             \(b.correctlySilent)  (\(pct(b.correctlySilent, noAnswer)))")
            print("    false inject (the bug):       \(b.falseInjectN)  (\(pct(b.falseInjectN, noAnswer)))")
            print("  (macro per-query avg: precision \(String(format: "%.1f%%", b.precision * 100)),"
                  + " recall \(String(format: "%.1f%%", b.recall * 100)), nDCG@3 \(String(format: "%.3f", b.ndcg)))")
        }
        print("========================================================\n")
    }

    // MARK: - Loading

    private struct Label: Decodable {
        let kind: String
        let text: String
        let uncovered: Bool?
        let gold: [GoldItem]

        // `uncovered` rows omit `gold`; default it to empty.
        enum CodingKeys: String, CodingKey { case kind, text, uncovered, gold }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            text = try c.decode(String.self, forKey: .text)
            uncovered = try c.decodeIfPresent(Bool.self, forKey: .uncovered)
            gold = try c.decodeIfPresent([GoldItem].self, forKey: .gold) ?? []
        }
    }
    private struct GoldItem: Decodable { let id: String; let grade: Int }

    private struct QueryRow: Decodable { let query_id: String; let exclude_ids: [String]? }

    private func loadExcludeIDs(_ data: URL) throws -> [String: [String]] {
        var out = [String: [String]]()
        for name in ["queries_tasks.json", "queries_memories.json"] {
            let url = data.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            for row in try decodeJSON([QueryRow].self, url) {
                out[row.query_id] = row.exclude_ids ?? []
            }
        }
        return out
    }

    /// Locates `RetrievalEval/data`. Prefers `$RETRIEVAL_EVAL_DATA`; otherwise derives the
    /// path from the compiler-provided `#filePath` (this source lives at
    /// `<repo>/AgentSmithPackage/Tests/AgentSmithTests/RetrievalEvalRunner.swift`, so four
    /// parent hops reach the repo root). No hardcoded user path, no runtime env dependency.
    /// Generates `<subdir>/{task_summaries,memories}.json` by re-embedding the canonical TEXT from
    /// `frozen/` with the live engine — capturing the package's current pooling. Idempotent: skips
    /// if already present. Writes only NEW files; `frozen/` and production data are never touched.
    private func ensureFrozen(_ subdir: String, data: URL, engine: SemanticSearchEngine) async throws {
        if subdir == "frozen" { return }
        let dir = data.appending(path: subdir)
        if FileManager.default.fileExists(atPath: dir.appending(path: "task_summaries.json").path) { return }
        let srcTasks = try decodeJSON([TaskSummaryEntry].self, data.appending(path: "frozen/task_summaries.json"))
        let srcMems = try decodeJSON([MemoryEntry].self, data.appending(path: "frozen/memories.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var newTasks: [TaskSummaryEntry] = []
        for t in srcTasks {
            let v = try await engine.embed(t.embeddingSourceText)
            newTasks.append(TaskSummaryEntry(id: t.id, title: t.title, summary: t.summary,
                embeddingSourceText: t.embeddingSourceText, embedding: v, status: t.status,
                taskCreatedAt: t.taskCreatedAt, createdAt: t.createdAt))
        }
        var newMems: [MemoryEntry] = []
        for m in srcMems {
            let v = try await engine.embed(m.content)
            newMems.append(MemoryEntry(id: m.id, content: m.content, embedding: v, source: m.source,
                tags: m.tags, sourceTaskID: m.sourceTaskID, createdAt: m.createdAt,
                lastRetrievedAt: m.lastRetrievedAt, retrievalCount: m.retrievalCount,
                lastUpdatedAt: m.lastUpdatedAt, lastUpdatedBy: m.lastUpdatedBy))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(newTasks).write(to: dir.appending(path: "task_summaries.json"))
        try enc.encode(newMems).write(to: dir.appending(path: "memories.json"))
        print("ensureFrozen: re-embedded \(newTasks.count) tasks + \(newMems.count) memories → \(subdir)/")
    }

    private func dataDir() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["RETRIEVAL_EVAL_DATA"], !env.isEmpty {
            return URL(filePath: env)
        }
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()   // AgentSmithTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // AgentSmithPackage/
            .deletingLastPathComponent()   // <repo root>
        let dir = repoRoot.appending(path: "RetrievalEval/data")
        guard FileManager.default.fileExists(atPath: dir.path) else { throw EvalError.missingDataDir }
        return dir
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private enum EvalError: Error { case missingDataDir }
}
#endif
