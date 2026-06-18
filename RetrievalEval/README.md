# RetrievalEval

An objective test harness for the memory/task **retrieval-precision** work
(ROADMAP: *"Improve prior-task relevance in new task context"*). It measures whether a
change to `MemoryStore`'s search/fusion/gating actually improves what gets surfaced —
for both **prior tasks** and **memories** — instead of eyeballing it.

> **Privacy:** the corpus is the user's *real* tasks and memories. This is a public repo
> (`__PUBLIC_REPO`). Only the harness **code** here is tracked; everything generated lands
> under `data/`, which is gitignored. Do not commit `data/`.

## Why this exists / why it's built this way

The earlier NLEmbedding→Qwen3 work tuned with `mlx-swift-examples`' `embedder-tool`, which
only scores raw cosine similarity. That **cannot** catch the bug #2 is about: the production
path (`MemoryStore.searchAll`) runs reciprocal-rank fusion over a thresholded candidate set,
and RRF is purely *ordinal* — a barely-above-noise match (cosine ~0.12) and a strong one
(~0.85) get the same rank-1 score if each is the top survivor, so weak matches get injected
as "relevant." Measuring that requires running the **real** fusion + gating, not pure cosine,
and a query set that includes **no-answer** cases.

## Data

The corpus documents already carry their 1024-dim Qwen3 embeddings on disk, so **no document
re-embedding is needed** — only the query strings get embedded (once).

| file (`data/`) | what |
| --- | --- |
| `frozen/task_summaries.json`, `frozen/memories.json` | verbatim corpus snapshot (with vectors) — frozen so the eval is stable across code changes |
| `catalog.json` | text-only view of all 156 docs; small enough to fit a whole corpus in one judge call (⇒ complete, non-pooled judgments) |
| `queries_tasks.json` | task→task queries from real raw session tasks (`title`+`description`); `exclude_ids` drops the query's own summary |
| `queries_memories.json` | synthesized agent-style memory searches (targeted + distractors for no-answer cases) |
| `labels.json` | the relevance ground truth (see below) |

## Pipeline

```
python3 build_corpus.py          # freeze corpus, build catalog + task queries  (no LLM)
python3 synthesize_queries.py    # generate memory queries                       (claude CLI)
python3 judge.py                 # label every query against the full catalog    (claude CLI)
#   judge.py --limit 4           # validate on a few first
#   judge.py --model opus        # stronger/costlier judge
```

All LLM steps shell out to the local **`claude`** CLI (`-p --output-format json`), so no API
key is needed. Judging is **resumable** (re-runs skip labeled queries) and the catalog forms a
stable prompt prefix so sequential calls reuse the prompt cache.

### Ground truth (`labels.json`)

LLM-judge-only, with hedges: each query is judged against the **complete** corpus (so misses
are measurable, not just what some retriever surfaced), graded **2/1/0** with a one-line
rationale per positive, and **double-passed** — the strict `gold` is the *agreement* of both
passes; items in only one pass go to `disagreements` (flagged, not trusted). A query a pass
silently drops is marked `uncovered` and excluded from scoring, so model drops never get
miscounted as no-answer.

## Metrics (computed by the Swift runner)

Run through the production `searchAll` path at the production limit (K=3):

- **Precision@3** — of what we inject, how much is gold-relevant. *Headline metric for #2.*
- **Recall@3** — did we miss genuinely-relevant prior work / memories.
- **nDCG@3** — rewards ranking the strongest (grade-2) hit first (uses graded gold).
- **No-answer false-inject rate** — fraction of empty-gold queries where we wrongly inject ≥1.
  Directly measures the lone-survivor-rides-RRF bug.

Reported overall and split by pool (task hits vs memory hits), since `searchAll` ranks both at once.

## Swift eval-runner (planned)

A test/CLI under `AgentSmithPackage` that:
1. loads `frozen/*.json` into a real `MemoryStore` via `MemoryStore.restore(memories:taskSummaries:)`
   (corpus vectors load directly — no re-embed),
2. embeds each query via the real Qwen3 engine (the MLX path: `AGENT_SMITH_RUN_MLX_TESTS=1` +
   `xcodebuild`, same gate as `MemoryStoreIntegrationTests`) and runs `searchAll`,
3. scores results against `labels.json` and prints the metrics above.

To sweep thresholds/weights cheaply, query vectors are embedded once and cached so the scoring
config can be re-run without paying MLX each time. This is also where the wishlisted
no-op/stub-engine `MemoryStore` seam (`ROADMAP.md:210`) gets built.
