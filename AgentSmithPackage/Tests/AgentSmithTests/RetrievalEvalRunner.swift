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

    /// Standalone (no MLX needed) bake-off of candidate LEXICAL scoring functions for the relevance
    /// gate, over the frozen corpus TEXT + labels. The naive `matched/N` fraction inflates on short
    /// common-word queries and deflates on long ones; this compares it against an N-scaled form and
    /// an IDF-weighted (term-rarity) form. The decisive readout is the **no-answer top score**: the
    /// strongest spurious lexical match on a query that should inject nothing — the false-inject fuel
    /// a lexical escape would add. A good variant keeps GOLD high while keeping that low.
    @Test
    func lexicalVariantAnalysis() throws {
        let data = try dataDir()
        let tasks = try decodeJSON([TaskSummaryEntry].self, data.appending(path: "frozen/task_summaries.json"))
        let memories = try decodeJSON([MemoryEntry].self, data.appending(path: "frozen/memories.json"))
        let labels = try decodeJSON([String: Label].self, data.appending(path: "labels.json"))

        // Doc id → token set (production tokenizer), and document frequency for IDF.
        var docTokens: [String: Set<String>] = [:]
        for t in tasks { docTokens[t.id.uuidString] = Set(MemoryStore.tokenize(t.embeddingSourceText)) }
        for m in memories { docTokens[m.id.uuidString] = Set(MemoryStore.tokenize(m.content)) }
        let numDocs = docTokens.count
        var docFreq: [String: Int] = [:]
        for toks in docTokens.values { for tok in toks { docFreq[tok, default: 0] += 1 } }
        func idf(_ tok: String) -> Double { log(Double(numDocs + 1) / Double((docFreq[tok] ?? 0) + 1)) }

        // Scoring functions of (matched query tokens, query size N):
        //  naive  = matched/N                  (current production lexical channel)
        //  nScale = tanh(frac · (1 + ln√N))    (reward matching many words; floor short queries at N=1)
        //  idf    = Σidf(matched) / Σidf(all)  (term-rarity: common words contribute ~0)
        //  idfN   = tanh(idf · (1 + ln√N))     (rarity + length combined)
        struct Acc { var gold: [Double] = []; var other: [Double] = []; var naMax: [Double] = [] }
        var naive = Acc(), nScale = Acc(), idfA = Acc(), idfN = Acc()
        var goldMatchedZero = 0, goldTotal = 0

        for (_, label) in labels where label.uncovered != true {
            let q = MemoryStore.queryTokenSet(from: label.text)
            guard !q.isEmpty else { continue }
            let N = Double(q.count)
            let lenScale = 1.0 + log(sqrt(N))
            let qIdfTotal = q.reduce(0.0) { $0 + idf($1) }
            let goldIDs = Set(label.gold.map(\.id))
            var mNaive = 0.0, mN = 0.0, mIdf = 0.0, mIdfN = 0.0
            for (docID, toks) in docTokens {
                let matched = q.intersection(toks)
                let frac = Double(matched.count) / N
                let vNaive = frac
                let vN = tanh(frac * lenScale)
                let idfFrac = qIdfTotal > 0 ? matched.reduce(0.0) { $0 + idf($1) } / qIdfTotal : 0
                let vIdf = idfFrac
                let vIdfN = tanh(idfFrac * lenScale)
                if goldIDs.contains(docID) {
                    goldTotal += 1
                    if matched.isEmpty {
                        goldMatchedZero += 1   // gold doc with NO lexical overlap — cosine-only territory
                    } else {
                        naive.gold.append(vNaive); nScale.gold.append(vN); idfA.gold.append(vIdf); idfN.gold.append(vIdfN)
                    }
                } else if !matched.isEmpty {   // spurious match on a non-gold doc — what a lexical gate must reject
                    naive.other.append(vNaive); nScale.other.append(vN); idfA.other.append(vIdf); idfN.other.append(vIdfN)
                }
                mNaive = max(mNaive, vNaive); mN = max(mN, vN); mIdf = max(mIdf, vIdf); mIdfN = max(mIdfN, vIdfN)
            }
            if goldIDs.isEmpty {   // no-answer query: strongest spurious lexical match across the corpus
                naive.naMax.append(mNaive); nScale.naMax.append(mN); idfA.naMax.append(mIdf); idfN.naMax.append(mIdfN)
            }
        }

        print("\n================ LEXICAL VARIANTS (no MLX) ================")
        print("corpus docs: \(numDocs)   gold pairs: \(goldTotal)   zero lexical overlap: "
              + "\(goldMatchedZero) (\(pct(goldMatchedZero, goldTotal))) ← only cosine can see these")
        print("GOLD = relevant pairs (matched>0) · NON-gold = spurious matches · NO-ANSWER = top score per silent query")
        func block(_ name: String, _ a: Acc) {
            print("\n[\(name)]")
            print("  GOLD     " + percentiles(a.gold))
            print("  NON-gold " + percentiles(a.other))
            print("  NO-ANS   " + percentiles(a.naMax))
        }
        block("naive  matched/N", naive)
        block("nScale tanh(frac·(1+ln√N))", nScale)
        block("idf    Σidf(hit)/Σidf(all)", idfA)
        block("idfN   tanh(idf·(1+ln√N))", idfN)
        print("==========================================================\n")
        #expect(numDocs > 0)
    }

    /// Query-construction experiment ("what do we search WITH"). CreateTaskTool searches with
    /// `title + " " + description` — a 271-word-median string that embeds to one diffuse vector.
    /// This retrieves related prior TASKS using **title-only** vs **title+description** (the
    /// `\n\n[Amendment]:` blocks AmendTaskTool appends are stripped first), each ranked by cosine
    /// and by the lexical variants, so we can see whether the shorter, focused query retrieves better.
    @Test
    func queryConstructionExperiment() async throws {
        let data = try dataDir()
        let engine = SemanticSearchEngine()
        for try await _ in engine.prepare() { /* drain progress */ }
        try await ensureFrozen(Self.frozenSubdir, data: data, engine: engine)
        let tasks = try decodeJSON([TaskSummaryEntry].self, data.appending(path: "\(Self.frozenSubdir)/task_summaries.json"))
        let memories = try decodeJSON([MemoryEntry].self, data.appending(path: "\(Self.frozenSubdir)/memories.json"))
        let labels = try decodeJSON([String: Label].self, data.appending(path: "labels.json"))
        let titleByID = Dictionary(uniqueKeysWithValues:
            try decodeJSON([QTaskRow].self, data.appending(path: "queries_tasks.json")).map { ($0.query_id, $0.title) })
        let excludeByQuery = try loadExcludeIDs(data)
        let taskIDs = Set(tasks.map { $0.id.uuidString })

        // IDF over the TASK corpus (the docs we rank), via the production tokenizer.
        var docTokens: [String: Set<String>] = [:]
        for t in tasks { docTokens[t.id.uuidString] = Set(MemoryStore.tokenize(t.embeddingSourceText)) }
        let numDocs = docTokens.count
        var docFreq: [String: Int] = [:]
        for toks in docTokens.values { for tok in toks { docFreq[tok, default: 0] += 1 } }
        func idf(_ t: String) -> Double { log(Double(numDocs + 1) / Double((docFreq[t] ?? 0) + 1)) }

        let store = MemoryStore(engine: engine)
        struct Tally { var r3 = 0.0, r10 = 0.0, mrr = 0.0, n = 0; var goldCos: [Double] = []; var fpCos: [Double] = [] }
        var T: [String: Tally] = [:]
        let constructionsOrder = ["title", "title+desc"]
        let signalsOrder = ["cosine", "naive", "idf"]

        // Rank by score desc; fold recall@3, recall@10, and MRR (reciprocal rank of first gold).
        func rank(_ ids: [(id: String, s: Double)], gold: Set<String>, into t: inout Tally) {
            let ordered = ids.sorted { $0.s > $1.s }.map(\.id)
            let top3 = Set(ordered.prefix(3)), top10 = Set(ordered.prefix(10))
            t.r3 += Double(gold.intersection(top3).count) / Double(gold.count)
            t.r10 += Double(gold.intersection(top10).count) / Double(gold.count)
            for (i, id) in ordered.enumerated() where gold.contains(id) { t.mrr += 1.0 / Double(i + 1); break }
            t.n += 1
        }

        for (qid, label) in labels.sorted(by: { $0.key < $1.key })
        where label.kind == "task" && label.uncovered != true {
            let goldTasks = Set(label.gold.map(\.id).filter { taskIDs.contains($0) })
            guard !goldTasks.isEmpty, let title = titleByID[qid] else { continue }
            // text == title + "\n" + description; strip the title prefix, then drop trailing amendments.
            let text = label.text
            let desc = text.hasPrefix(title) ? String(text.dropFirst(title.count)) : text
            let stripped = (desc.components(separatedBy: "\n\n[Amendment]:").first ?? desc)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let constructions = ["title": title, "title+desc": title + " " + stripped]

            let excluded = Set(excludeByQuery[qid] ?? [])
            await store.clear()
            await store.restore(memories: memories, taskSummaries: tasks.filter { !excluded.contains($0.id.uuidString) })

            for cName in constructionsOrder {
                guard let q = constructions[cName] else { continue }
                let docs = rankedDocs(try await store.searchAll(query: q, memoryLimit: 0, taskLimit: 400)).filter { $0.isTask }

                var cosT = T["\(cName)|cosine"] ?? Tally()
                rank(docs.map { ($0.id, $0.cosine) }, gold: goldTasks, into: &cosT)
                for d in docs where goldTasks.contains(d.id) { cosT.goldCos.append(d.cosine) }
                for d in docs.sorted(by: { $0.cosine > $1.cosine }).prefix(3) where !goldTasks.contains(d.id) {
                    cosT.fpCos.append(d.cosine)
                }
                T["\(cName)|cosine"] = cosT

                let qTokens = MemoryStore.queryTokenSet(from: q)
                let N = Double(max(qTokens.count, 1))
                let qIdfTotal = qTokens.reduce(0.0) { $0 + idf($1) }
                func textScores(idfWeighted: Bool) -> [(id: String, s: Double)] {
                    docs.map { d in
                        let matched = qTokens.intersection(docTokens[d.id] ?? [])
                        let s = idfWeighted
                            ? (qIdfTotal > 0 ? matched.reduce(0.0) { $0 + idf($1) } / qIdfTotal : 0)
                            : Double(matched.count) / N
                        return (id: d.id, s: s)
                    }
                }
                var nT = T["\(cName)|naive"] ?? Tally(); rank(textScores(idfWeighted: false), gold: goldTasks, into: &nT); T["\(cName)|naive"] = nT
                var iT = T["\(cName)|idf"] ?? Tally(); rank(textScores(idfWeighted: true), gold: goldTasks, into: &iT); T["\(cName)|idf"] = iT
            }
        }

        let n0 = T["title|cosine"]?.n ?? 0
        print("\n========== QUERY CONSTRUCTION × SIGNAL — related prior TASKS ==========")
        print("task queries scored: \(n0)  ·  no gate, ranking only  ·  recall@K = frac of gold tasks in top-K")
        print(col("construction", 14) + col("signal", 8) + col("recall@3", 10) + col("recall@10", 11) + col("MRR", 8))
        for c in constructionsOrder {
            for s in signalsOrder {
                let t = T["\(c)|\(s)"] ?? Tally()
                let n = Double(max(t.n, 1))
                print(col(c, 14) + col(s, 8)
                      + col(String(format: "%.3f", t.r3 / n), 10)
                      + col(String(format: "%.3f", t.r10 / n), 11)
                      + col(String(format: "%.3f", t.mrr / n), 8))
            }
        }
        print("\n-- cosine separability: gold task cosine vs top-3 non-gold (FP) cosine --")
        for c in constructionsOrder {
            print("  " + col(c, 12) + " GOLD: " + percentiles(T["\(c)|cosine"]?.goldCos ?? []))
            print("  " + col(c, 12) + " FP:   " + percentiles(T["\(c)|cosine"]?.fpCos ?? []))
        }
        print("====================================================================\n")
        #expect(n0 > 0)
    }

    /// Full (query-type × pool) retrieval matrix — the four real production paths:
    ///   long→task  : CreateTaskTool (title+desc) finding prior tasks
    ///   long→mem   : CreateTaskTool (title+desc) finding memories
    ///   short→task : auto-context / search_memory (user message) finding prior tasks
    ///   short→mem  : auto-context / search_memory (user message) finding memories
    /// Each query is bucketed by kind (task=long, memory=short) and scored against its task-gold and
    /// memory-gold separately. Reports cosine recall + the gold-vs-FP cosine GAP, because that gap is
    /// what decides whether a path can be cosine-gated at all (≈0 ⇒ no usable gate).
    @Test
    func retrievalMatrix() async throws {
        let data = try dataDir()
        let engine = SemanticSearchEngine()
        for try await _ in engine.prepare() { /* drain progress */ }
        try await ensureFrozen(Self.frozenSubdir, data: data, engine: engine)
        let tasks = try decodeJSON([TaskSummaryEntry].self, data.appending(path: "\(Self.frozenSubdir)/task_summaries.json"))
        let memories = try decodeJSON([MemoryEntry].self, data.appending(path: "\(Self.frozenSubdir)/memories.json"))
        let labels = try decodeJSON([String: Label].self, data.appending(path: "labels.json"))
        let excludeByQuery = try loadExcludeIDs(data)
        let taskIDs = Set(tasks.map { $0.id.uuidString })
        let memIDs = Set(memories.map { $0.id.uuidString })

        // Per-pool tokens + IDF (rank within a pool ⇒ rarity is relative to that pool).
        func buildIDF(_ pairs: [(String, String)]) -> (tokens: [String: Set<String>], idf: (String) -> Double) {
            var toks: [String: Set<String>] = [:]
            for (id, text) in pairs { toks[id] = Set(MemoryStore.tokenize(text)) }
            let n = toks.count
            var df: [String: Int] = [:]
            for s in toks.values { for t in s { df[t, default: 0] += 1 } }
            return (toks, { log(Double(n + 1) / Double((df[$0] ?? 0) + 1)) })
        }
        let taskPool = buildIDF(tasks.map { ($0.id.uuidString, $0.embeddingSourceText) })
        let memPool = buildIDF(memories.map { ($0.id.uuidString, $0.content) })

        struct Cell { var r3 = 0.0, r10 = 0.0, mrr = 0.0, r3idf = 0.0, n = 0; var goldCos: [Double] = []; var fpCos: [Double] = [] }
        var cells: [String: Cell] = [:]
        func recallMRR(_ ranked: [(id: String, s: Double)], _ gold: Set<String>) -> (Double, Double, Double) {
            let ord = ranked.sorted { $0.s > $1.s }.map(\.id)
            let t3 = Set(ord.prefix(3)), t10 = Set(ord.prefix(10))
            var mrr = 0.0
            for (i, id) in ord.enumerated() where gold.contains(id) { mrr = 1.0 / Double(i + 1); break }
            return (Double(gold.intersection(t3).count) / Double(gold.count),
                    Double(gold.intersection(t10).count) / Double(gold.count), mrr)
        }
        func measure(_ key: String, docs: [RankedDoc], gold: Set<String>, q: String,
                     tokens: [String: Set<String>], idf: (String) -> Double) {
            guard !gold.isEmpty else { return }
            var c = cells[key] ?? Cell()
            let (r3, r10, mrr) = recallMRR(docs.map { ($0.id, $0.cosine) }, gold)
            c.r3 += r3; c.r10 += r10; c.mrr += mrr; c.n += 1
            let qTokens = MemoryStore.queryTokenSet(from: q)
            let qIdfTotal = qTokens.reduce(0.0) { $0 + idf($1) }
            let idfScores = docs.map { d -> (id: String, s: Double) in
                let m = qTokens.intersection(tokens[d.id] ?? [])
                return (d.id, qIdfTotal > 0 ? m.reduce(0.0) { $0 + idf($1) } / qIdfTotal : 0)
            }
            c.r3idf += recallMRR(idfScores, gold).0
            for d in docs where gold.contains(d.id) { c.goldCos.append(d.cosine) }
            for d in docs.sorted(by: { $0.cosine > $1.cosine }).prefix(3) where !gold.contains(d.id) { c.fpCos.append(d.cosine) }
            cells[key] = c
        }

        let store = MemoryStore(engine: engine)
        for (qid, label) in labels.sorted(by: { $0.key < $1.key }) where label.uncovered != true && !label.gold.isEmpty {
            let q = label.text
            let tag = label.kind == "task" ? "long " : "short"
            let excluded = Set(excludeByQuery[qid] ?? [])
            await store.clear()
            await store.restore(memories: memories, taskSummaries: tasks.filter { !excluded.contains($0.id.uuidString) })
            let docs = rankedDocs(try await store.searchAll(query: q, memoryLimit: 400, taskLimit: 400))
            let goldTasks = Set(label.gold.map(\.id).filter { taskIDs.contains($0) })
            let goldMems = Set(label.gold.map(\.id).filter { memIDs.contains($0) })
            measure("\(tag)→task", docs: docs.filter { $0.isTask }, gold: goldTasks, q: q, tokens: taskPool.tokens, idf: taskPool.idf)
            measure("\(tag)→mem", docs: docs.filter { !$0.isTask }, gold: goldMems, q: q, tokens: memPool.tokens, idf: memPool.idf)
        }

        func med(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }
        print("\n============= RETRIEVAL MATRIX (query-type × pool, cosine, no gate) =============")
        print(col("cell", 12) + col("nQ", 5) + col("rec@3", 8) + col("rec@10", 8) + col("MRR", 7)
              + col("idf@3", 8) + col("goldCos", 9) + col("fpCos", 8) + col("gap", 8))
        for key in ["long →task", "long →mem", "short→task", "short→mem"] {
            guard let c = cells[key] else { continue }
            let n = Double(max(c.n, 1))
            let gc = med(c.goldCos), fc = med(c.fpCos)
            print(col(key, 12) + col("\(c.n)", 5)
                  + col(String(format: "%.3f", c.r3 / n), 8)
                  + col(String(format: "%.3f", c.r10 / n), 8)
                  + col(String(format: "%.3f", c.mrr / n), 7)
                  + col(String(format: "%.3f", c.r3idf / n), 8)
                  + col(String(format: "%.3f", gc), 9)
                  + col(String(format: "%.3f", fc), 8)
                  + col(String(format: "%+.3f", gc - fc), 8))
        }
        print("gap = median(gold cosine) − median(top-3 FP cosine); larger ⇒ a cosine gate can separate.")
        print("================================================================================\n")
        #expect(!cells.isEmpty)
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

    /// Row of `queries_tasks.json` — carries the clean `title` separately from the combined `text`,
    /// so the query-construction experiment can rebuild title-only vs title+description.
    private struct QTaskRow: Decodable { let query_id: String; let title: String }

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
