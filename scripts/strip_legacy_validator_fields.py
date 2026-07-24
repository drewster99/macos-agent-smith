#!/usr/bin/env python3
"""One-shot on-disk cleanup for the removed evaluator-registry cruft.

Run this ONLY while the AgentSmith app is NOT running (it would otherwise
overwrite these files from its in-memory state). It:

  1. Strips the removed `validator` / `prepare` keys from every acceptance
     criterion in the app's task stores (a migration — no task is deleted).
  2. Moves the two orphaned user-authored evaluator JSON files out of the
     (no-longer-read) evaluators/ directory into a timestamped backup.

Every file it edits is backed up first. Safe to re-run (idempotent).
"""
import json
import os
import shutil
import sys
from datetime import datetime

BASE = os.path.expanduser("~/Library/Application Support/AgentSmith")
STAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
BACKUP = os.path.join(BASE, f"backups/legacy-validator-cleanup-{STAMP}")


def task_iter(data):
    """Yield task dicts from whatever top-level shape the store used."""
    if isinstance(data, list):
        yield from data
    elif isinstance(data, dict):
        inner = data.get("tasks", data)
        yield from (inner if isinstance(inner, list) else inner.values())


def strip_task_file(path):
    if not os.path.exists(path):
        return
    with open(path) as f:
        data = json.load(f)
    removed = 0
    for task in task_iter(data):
        for crit in task.get("acceptanceCriteria") or []:
            for key in ("validator", "prepare"):
                if key in crit:
                    del crit[key]
                    removed += 1
    if removed == 0:
        print(f"  {path}: already clean")
        return
    os.makedirs(BACKUP, exist_ok=True)
    shutil.copy2(path, os.path.join(BACKUP, os.path.basename(path)))
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)
    print(f"  {path}: stripped {removed} legacy key(s) (backup in {BACKUP})")


def main():
    if not os.path.isdir(BASE):
        sys.exit(f"AgentSmith support dir not found: {BASE}")

    print("Stripping legacy validator/prepare keys from task stores:")
    files = [os.path.join(BASE, "inactive_tasks.json")]
    sessions = os.path.join(BASE, "sessions")
    if os.path.isdir(sessions):
        for sid in os.listdir(sessions):
            files.append(os.path.join(sessions, sid, "tasks.json"))
    for path in files:
        strip_task_file(path)

    evaldir = os.path.join(BASE, "evaluators")
    if os.path.isdir(evaldir):
        orphans = [f for f in os.listdir(evaldir) if f.endswith(".json")]
        if orphans:
            os.makedirs(BACKUP, exist_ok=True)
            print("Moving orphaned evaluator files out of the (unread) evaluators/ dir:")
            for f in orphans:
                shutil.move(os.path.join(evaldir, f), os.path.join(BACKUP, f))
                print(f"  moved {f}")
        remaining = os.listdir(evaldir)
        if not remaining:
            os.rmdir(evaldir)
            print("  removed empty evaluators/ dir")

    print("Done.")


if __name__ == "__main__":
    main()
