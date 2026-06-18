#!/usr/bin/env python3
"""Build the frozen corpus + judge-facing catalog + task->task query set for the
retrieval-precision eval (ROADMAP item: "Improve prior-task relevance in new task context").

Reads the live AgentSmith data, snapshots it, and emits everything the downstream
LLM-judge and Swift eval-runner need. All outputs land under RetrievalEval/data/,
which is gitignored: the corpus is the user's real (personal) task/memory data and
this is a public repo.

Outputs (under data/):
  frozen/task_summaries.json   verbatim snapshot (carries 1024-dim embeddings)
  frozen/memories.json         verbatim snapshot (carries 1024-dim embeddings)
  catalog.json                 judge-facing text view: {tasks:[...], memories:[...]} (no vectors)
  queries_tasks.json           task->task queries derived from raw session tasks
  memories_for_synthesis.json  raw memory list; input to the (LLM) memory-query synthesis step

Idempotent: re-running overwrites the data/ outputs from the current live state.
"""
from __future__ import annotations
import json
import os
import glob
import shutil
import hashlib

APP_SUPPORT = os.path.expanduser("~/Library/Application Support/AgentSmith")
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
FROZEN = os.path.join(DATA, "frozen")

# Deterministic sample size for the task->task query set. All eligible tasks are
# written out; `sample` flags the subset the judge/runner use by default so a run
# stays cheap. Bump or ignore the flag to widen coverage.
TASK_QUERY_SAMPLE = 45


def _load_list(path: str) -> list:
    d = json.load(open(path))
    if isinstance(d, list):
        return d
    return next((v for v in d.values() if isinstance(v, list)), [])


def _qid(prefix: str, seed: str) -> str:
    return f"{prefix}-{hashlib.sha1(seed.encode()).hexdigest()[:8]}"


def main() -> None:
    os.makedirs(FROZEN, exist_ok=True)

    # 1. Freeze the corpus verbatim (these files carry the embeddings).
    for name in ("task_summaries.json", "memories.json"):
        shutil.copy2(os.path.join(APP_SUPPORT, name), os.path.join(FROZEN, name))

    summaries = _load_list(os.path.join(FROZEN, "task_summaries.json"))
    memories = _load_list(os.path.join(FROZEN, "memories.json"))
    summary_ids = {s["id"] for s in summaries}

    # 2. Judge-facing catalog: text only, no vectors. Small enough to fit a whole
    #    corpus in one LLM context, which is what lets us get *complete* (non-pooled)
    #    relevance judgments.
    catalog = {
        "tasks": sorted(
            (
                {
                    "id": s["id"],
                    "title": s["title"],
                    "summary": s["summary"],
                    "status": s["status"],
                    "taskCreatedAt": s.get("taskCreatedAt"),
                }
                for s in summaries
            ),
            key=lambda x: x["id"],
        ),
        "memories": sorted(
            (
                {
                    "id": m["id"],
                    "content": m["content"],
                    "tags": m.get("tags", []),
                    "source": m.get("source"),
                }
                for m in memories
            ),
            key=lambda x: x["id"],
        ),
    }
    json.dump(catalog, open(os.path.join(DATA, "catalog.json"), "w"), indent=2, sort_keys=False)

    # 3. task->task queries from the RAW session tasks (clean title + description,
    #    the exact production query material: CreateTaskTool searches on title+" "+description).
    #    Only tasks that produced a summary are eligible (so they live in the corpus and
    #    can be excluded as the trivial self-match). Deterministic order by id.
    raw_tasks = {}
    for f in glob.glob(os.path.join(APP_SUPPORT, "sessions", "*", "tasks.json")):
        for t in _load_list(f):
            raw_tasks[t["id"]] = t

    eligible = sorted(
        (t for tid, t in raw_tasks.items() if tid in summary_ids),
        key=lambda t: t["id"],
    )

    # Stratified deterministic sample: even stride across the id-sorted list so the
    # subset spans the corpus rather than clustering. No RNG (Date/random are also
    # banned in the Swift runner; keep the whole pipeline reproducible).
    stride = max(1, len(eligible) // TASK_QUERY_SAMPLE)
    queries = []
    for i, t in enumerate(eligible):
        text = (t.get("title", "") + "\n" + t.get("description", "")).strip()
        queries.append(
            {
                "query_id": _qid("task", t["id"]),
                "kind": "task",
                "source_task_id": t["id"],
                "title": t.get("title", ""),
                "text": text,
                "status": t.get("status"),
                "disposition": t.get("disposition"),
                # The runner MUST exclude the source task's own summary from candidates.
                "exclude_ids": [t["id"]],
                "sample": (i % stride == 0),
            }
        )
    json.dump(queries, open(os.path.join(DATA, "queries_tasks.json"), "w"), indent=2)

    # 4. Memory-query synthesis input (the synthesis itself is the LLM step).
    json.dump(catalog["memories"], open(os.path.join(DATA, "memories_for_synthesis.json"), "w"), indent=2)

    sampled = sum(1 for q in queries if q["sample"])
    print("=== retrieval-eval corpus built ===")
    print(f"  task summaries (corpus):   {len(summaries)}")
    print(f"  memories (corpus):         {len(memories)}")
    print(f"  raw session tasks:         {len(raw_tasks)}")
    print(f"  eligible task queries:     {len(eligible)}  (sampled for default run: {sampled})")
    print(f"  outputs in:                {DATA}")
    print("  NEXT (LLM steps, need an API key):")
    print("    - synthesize memory queries from memories_for_synthesis.json")
    print("    - judge each query against catalog.json (complete, graded 2/1/0, double-pass)")


if __name__ == "__main__":
    main()
