# TODO_NEXT — Memory / RAG improvements

Assessment of the current memory embedding design in `AgentSmithPackage/Sources/AgentSmithKit/Memory/MemoryStore.swift`, captured as a working list of next steps. Items roughly ordered by ROI.

## Current design (baseline)

- Single-vector embedding per memory and per task summary (Qwen3 via MLX, L2-normalized).
- Cosine similarity fused with a keyword/text signal via Reciprocal Rank Fusion (k=60).
- Task summary embedding text is `title + description + summary + result + commentary + all updates`, joined with newlines, **no length cap**.
- No chunking, no overlap, no multi-level views, no reranker, no query rewriting.
- Brute-force search across all entries.

The Qwen3 + single-vector + RRF baseline is reasonable. The concerns below are about precision lifts that are well known in modern RAG and currently unaddressed.

## Concerns

1. **Topical dilution on long composites.** `composeEmbeddingText` concatenates the full task record with no cap. Even a 32k-context embedder still emits a *single fixed-dim vector* — the more topically diverse the input, the more the result is a smoothed centroid. Queries about one specific aspect of a long task collide with the average of many unrelated update messages.
2. **Single granularity.** No way to retrieve "the moment a specific decision was made" vs "the task as a whole." Dominant topic wins; secondary topics become near-unretrievable.
3. **Embedding noise in task summaries.** Update messages joined with spaces include operator chatter ("Brown started bash...", "got error E_BUSY"). Embedding text should be a canonicalized/summarized form distinct from display text.
4. **Likely no query/document asymmetry.** Qwen3-Embedding has separate query vs document modes and supports task instructions. Need to confirm whether `SemanticSearchEngine` exposes these — if not, we're leaving free precision on the table.
5. **No reranker stage.** Cosine + RRF is a recall mechanism, not a precision mechanism. A small cross-encoder rerank — or even a Haiku-as-judge pass over top-20 → top-5 — is the single highest-leverage RAG improvement and is missing here. Memory mistakes are especially costly because they pollute agent context for the rest of the run.
6. **No query expansion / HyDE.** Agent queries are often abstract ("did we decide anything about auth flow for project Y?"). Vocabulary mismatch with stored text is the main reason single-shot semantic search misses. HyDE (have the LLM hallucinate the answer, embed *that*) or multi-paraphrase expansion is cheap and substantial.
7. **Metadata is unused as a ranking signal.** `tags`, `source`, `sourceTaskID`, `createdAt`, `lastRetrievedAt`, `retrievalCount` exist on every entry but search appears to be content-only. Recency decay, tag-boost, and "frequently-retrieved" priors are well-known wins for personal-memory corpora.
8. **No hierarchical / multi-level view.** Smith's queries mix "what's the gist of all our prior work on X" with "did Brown specifically say Y last Tuesday." Single-level retrieval can't serve both. RAPTOR-style clustered summaries (cluster → cluster summary → embed cluster summary) is the textbook fix once corpus size justifies it.
9. **Brute-force search ceiling.** Linear cosine over all memories is fine at hundreds, painful at thousands. Not a quality issue, but an eventual ceiling — and it interacts with #2: when scaling forces an ANN index, having only one vector per noisy doc compounds recall loss.

## Priorities (by ROI)

1. **Section-level embeddings for task summaries.** Embed `title+description` ("what was asked"), `summary+result` ("what happened"), and optionally each significant update as a child vector. Retrieve best section, return parent task. Directly fixes #1, #2, #3.
2. **Add a reranker pass** (cross-encoder or LLM-as-judge) over top-K. Largest single precision lift.
3. **Use Qwen3 query vs document modes + instruction prefixes** if `SemanticSearchEngine` exposes them. Free quality boost. May require a small change in the sibling `swift-semantic-search` repo.
4. **Metadata-aware scoring.** Time decay + retrieval-count prior + tag boost folded into the existing RRF blend.
5. **HyDE / query rewriting** at agent-issued query time.
6. **RAPTOR-style hierarchical layer** as the corpus grows past ~1k entries.

## Files of interest

- `AgentSmithPackage/Sources/AgentSmithKit/Memory/MemoryStore.swift` — actor; `save`, `update`, `saveTaskSummary`, `composeEmbeddingText`, RRF search.
- `AgentSmithPackage/Sources/AgentSmithKit/Orchestration/OrchestrationRuntime.swift` — constructs `MemoryStore` with the engine.
- `AgentSmithPackage/Tests/AgentSmithTests/MemoryStoreIntegrationTests.swift` — needs Xcode build pipeline (MLX Metal).
- `../../swift-semantic-search` — sibling package owning `SemanticSearchEngine.embed(...)`. Check API surface for query/doc modes, instructions, and any reranker hooks.

## Verification approach (when implementing)

- Add focused tests under `AgentSmithPackage/Tests/AgentSmithTests/` for: section-level retrieval correctness, reranker top-K behavior, recency-decayed scoring, and query-rewriting wrapper.
- Build a small offline eval set (representative agent-issued queries → expected memory IDs) and track recall@5 / MRR before vs after each change. Without an eval set, RAG changes are guesswork.
- Smoke-test the app for ~15s after each landed change, screenshot, check logs.
