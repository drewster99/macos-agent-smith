#!/usr/bin/env python3
"""Synthesize memory-retrieval queries via the `claude` CLI.

Memories aren't naturally "queried" the way new tasks are, so we generate realistic
agent-style search queries for them. This step produces query TEXT only — the gold
relevance labels come uniformly from judge.py (against the full catalog), so we never
trust synthesis to decide what's relevant.

We ask for two things:
  - per-memory queries: natural searches that *should* surface each memory (paraphrased,
    not quoting it verbatim), at a mix of difficulty.
  - distractors: plausible on-topic-for-the-app queries that no stored memory actually
    covers — these become no-answer cases, which is how we measure false injections.

Output: data/queries_memories.json
"""
from __future__ import annotations
import json
import os
import hashlib
from _claude import call_claude

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

PROMPT = """You are helping build an information-retrieval test set for an on-device \
semantic memory used by a coding-assistant app called Agent Smith. Below is the COMPLETE \
set of stored memories (facts the assistant saved). Your job is to invent realistic search \
queries an agent might issue.

Return ONLY a JSON object, no prose, no code fence, no trailing signature:
{
  "per_memory": [
    {"memory_id": "<id>", "queries": ["<q1>", "<q2>"]}
  ],
  "distractors": ["<q>", "<q>", ...]
}

Rules:
- For each memory, write exactly 2 queries that SHOULD retrieve it. Phrase them as a person \
or agent would actually search (a question or a short keyword phrase). Paraphrase the idea; \
do NOT quote the memory text verbatim. Make at least one of the two non-obvious (conceptual / \
indirect wording) so the test isn't trivial.
- Write 12 "distractors": queries that are plausible for this app's domain (Swift, macOS, \
LLMs, the app's own subsystems) but that NONE of the stored memories actually answer. These \
create no-answer cases. Do not make them about topics any memory covers.

MEMORIES:
"""


def main() -> None:
    memories = json.load(open(os.path.join(DATA, "memories_for_synthesis.json")))
    catalog_text = "\n".join(
        f'- id={m["id"]} tags={m.get("tags")}: {m["content"]}' for m in memories
    )
    result, cost = call_claude(PROMPT + catalog_text, model="sonnet")

    valid_ids = {m["id"] for m in memories}
    queries = []
    for entry in result.get("per_memory", []):
        mid = entry.get("memory_id")
        origin = mid if mid in valid_ids else None
        for q in entry.get("queries", []):
            q = (q or "").strip()
            if not q:
                continue
            queries.append({
                "query_id": "mem-" + hashlib.sha1((q + str(origin)).encode()).hexdigest()[:8],
                "kind": "memory",
                "text": q,
                "origin_memory_id": origin,
                "exclude_ids": [],
                "sample": True,
            })
    for q in result.get("distractors", []):
        q = (q or "").strip()
        if not q:
            continue
        queries.append({
            "query_id": "mem-" + hashlib.sha1((q + "distractor").encode()).hexdigest()[:8],
            "kind": "memory",
            "text": q,
            "origin_memory_id": None,
            "exclude_ids": [],
            "sample": True,
        })

    # De-dup by query_id (identical text collisions).
    dedup = {q["query_id"]: q for q in queries}
    out = sorted(dedup.values(), key=lambda q: q["query_id"])
    json.dump(out, open(os.path.join(DATA, "queries_memories.json"), "w"), indent=2)
    print(f"synthesized {len(out)} memory queries "
          f"({sum(1 for q in out if q['origin_memory_id'])} targeted, "
          f"{sum(1 for q in out if not q['origin_memory_id'])} distractors) "
          f"| cost ${cost:.4f}")


if __name__ == "__main__":
    main()
