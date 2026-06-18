#!/usr/bin/env python3
"""LLM-judge the eval queries against the full corpus, via the `claude` CLI.

For each query, an independent judge sees the COMPLETE catalog (all task summaries +
memories — it fits in one context, so judgments are complete, not pooled) and marks
which documents are relevant enough to be worth attaching to that query's context.
This mirrors production `MemoryStore.searchAll`, which ranks over both corpora at once,
so gold labels may contain task ids and/or memory ids.

Quality hedges for the user's chosen LLM-judge-only path:
  - complete corpus per query (measures misses, not just what retrieval found)
  - graded 2/1/0 with a short rationale per positive (skimmable)
  - DOUBLE-PASS: each query judged twice; strict gold = agreement of both passes,
    disagreements recorded rather than silently trusted.

Resumable: writes data/labels.json incrementally; re-running skips already-judged queries.
Catalog + instructions form a stable prompt prefix so sequential calls hit the prompt cache.

Usage:
  python3 judge.py                  # judge all pending queries
  python3 judge.py --limit 4        # validation: judge only the next 4 pending
  python3 judge.py --model opus     # stronger (costlier) judge
"""
from __future__ import annotations
import argparse
import json
import os
from _claude import call_claude

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
LABELS = os.path.join(DATA, "labels.json")

INSTRUCTIONS = """You are a strict relevance judge building an information-retrieval test \
set for Agent Smith, a coding-assistant app. You are given the COMPLETE catalog of stored \
documents (prior task summaries and saved memories), then a batch of search queries. For \
each query decide which catalog documents are genuinely relevant.

"Relevant" means: if this document were automatically attached to the context for this query, \
it would actually HELP — same project/component, a direct prior attempt at the same problem, \
a fact that answers the query. Mere topical adjacency (both mention Swift, both touch the app) \
is NOT relevant. Be strict: most queries should match few or zero documents, and returning an \
empty list is correct and expected when nothing genuinely helps.

Grades: 2 = clearly relevant, should definitely surface; 1 = related and borderline-useful. \
Do NOT list grade-0 documents. Never list an id from the query's "exclude_ids".

Return ONLY this JSON, no prose, no code fence, no trailing signature or marker:
{"judgments":[{"query_id":"<id>","relevant":[{"id":"<doc id>","grade":2,"why":"<=12 words"}]}]}

CATALOG:
"""


def build_catalog_text() -> str:
    cat = json.load(open(os.path.join(DATA, "catalog.json")))
    lines = ["## TASK SUMMARIES"]
    for t in cat["tasks"]:
        lines.append(f'[task id={t["id"]}] {t["title"]} ({t["status"]})\n  {t["summary"]}')
    lines.append("\n## MEMORIES")
    for m in cat["memories"]:
        lines.append(f'[memory id={m["id"]}] tags={m.get("tags")}\n  {m["content"]}')
    valid_ids = {t["id"] for t in cat["tasks"]} | {m["id"] for m in cat["memories"]}
    return "\n".join(lines), valid_ids


def load_queries() -> list:
    tasks = [q for q in json.load(open(os.path.join(DATA, "queries_tasks.json"))) if q["sample"]]
    mem_path = os.path.join(DATA, "queries_memories.json")
    mem = json.load(open(mem_path)) if os.path.exists(mem_path) else []
    return tasks + mem


def judge_batch(batch, catalog_text, valid_ids, model):
    """One judge call. Returns (relevant_map, covered_ids, cost). `covered_ids` is the
    set of query_ids the model actually returned a judgment for — distinct from a query
    it judged as empty — so callers can tell a genuine no-answer from a silent drop."""
    qblock = "\n\nQUERIES TO JUDGE:\n" + json.dumps(
        [{"query_id": q["query_id"], "text": q["text"], "exclude_ids": q.get("exclude_ids", [])}
         for q in batch], indent=2)
    result, cost = call_claude(INSTRUCTIONS + catalog_text + qblock, model=model)
    excl_of = {q["query_id"]: set(q.get("exclude_ids", [])) for q in batch}
    out, covered = {}, set()
    for j in result.get("judgments", []):
        qid = j.get("query_id")
        if qid not in excl_of:
            continue
        covered.add(qid)
        rel = []
        for r in j.get("relevant", []):
            did = r.get("id")
            if did in valid_ids and did not in excl_of[qid]:
                rel.append({"id": did, "grade": int(r.get("grade", 1)), "why": r.get("why", "")})
        out[qid] = rel
    return out, covered, cost


def judge_pass_complete(batch, catalog_text, valid_ids, model):
    """A full judging pass over `batch` with one coverage retry. Returns (map, uncovered, cost):
    `map` has every covered query_id; `uncovered` are ids the model dropped even after retry
    (caller excludes those from metrics rather than miscounting them as no-answer)."""
    out, covered, cost = judge_batch(batch, catalog_text, valid_ids, model)
    missing = [q for q in batch if q["query_id"] not in covered]
    if missing:
        retry_out, retry_cov, retry_cost = judge_batch(missing, catalog_text, valid_ids, model)
        out.update(retry_out)
        covered |= retry_cov
        cost += retry_cost
    uncovered = {q["query_id"] for q in batch} - covered
    return out, uncovered, cost


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0, help="judge only the next N pending (0=all)")
    ap.add_argument("--passes", type=int, default=2)
    args = ap.parse_args()

    catalog_text, valid_ids = build_catalog_text()
    queries = load_queries()
    labels = json.load(open(LABELS)) if os.path.exists(LABELS) else {}

    pending = [q for q in queries if q["query_id"] not in labels]
    if args.limit:
        pending = pending[:args.limit]
    print(f"{len(queries)} total queries, {len(labels)} already judged, judging {len(pending)} now "
          f"(model={args.model}, batch={args.batch}, passes={args.passes})")

    total_cost = 0.0
    for i in range(0, len(pending), args.batch):
        batch = pending[i:i + args.batch]
        pass_results, pass_uncovered = [], []
        for p in range(args.passes):
            res, uncovered, cost = judge_pass_complete(batch, catalog_text, valid_ids, args.model)
            total_cost += cost
            pass_results.append(res)
            pass_uncovered.append(uncovered)
        for q in batch:
            qid = q["query_id"]
            # A query dropped by any pass even after retry can't be scored honestly
            # (we can't tell no-answer from a drop), so flag it for exclusion.
            if any(qid in unc for unc in pass_uncovered):
                labels[qid] = {"kind": q["kind"], "text": q["text"],
                               "origin_memory_id": q.get("origin_memory_id"),
                               "uncovered": True}
                continue
            passes = [pr.get(qid, []) for pr in pass_results]
            sets = [{r["id"] for r in pr} for pr in passes]
            agree = set.intersection(*sets) if sets else set()
            union = set.union(*sets) if sets else set()
            grade_of = {}
            for pr in passes:
                for r in pr:
                    grade_of[r["id"]] = max(grade_of.get(r["id"], 0), r["grade"])
            labels[qid] = {
                "kind": q["kind"],
                "text": q["text"],
                "origin_memory_id": q.get("origin_memory_id"),
                "passes": passes,
                "gold": sorted([{"id": d, "grade": grade_of[d]} for d in agree], key=lambda x: x["id"]),
                "gold_union": sorted(union),
                "disagreements": sorted(union - agree),
            }
        json.dump(labels, open(LABELS, "w"), indent=2)
        done = min(i + args.batch, len(pending))
        print(f"  judged {done}/{len(pending)} pending | running cost ${total_cost:.3f}")

    judged = [labels[q["query_id"]] for q in queries if q["query_id"] in labels]
    scorable = [l for l in judged if not l.get("uncovered")]
    uncovered = sum(1 for l in judged if l.get("uncovered"))
    with_gold = sum(1 for l in scorable if l["gold"])
    no_answer = sum(1 for l in scorable if not l["gold"])
    disag = sum(len(l["disagreements"]) for l in scorable)
    print(f"done. {len(judged)} judged ({uncovered} uncovered/excluded) | "
          f"{with_gold} have gold, {no_answer} no-answer "
          f"| {disag} disagreement items flagged | total cost ${total_cost:.3f}")


if __name__ == "__main__":
    main()
