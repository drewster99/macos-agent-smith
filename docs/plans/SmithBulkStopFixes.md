# Smith bulk stop/delete — fix plan

Status: F1, F2, F3-A, F5 ✅ implemented 2026-10-11 (tests in `SmithBulkStopTests.swift`; each failed before
its fix). F3-B and F4 await the user's decision. F3-A also corrected Smith's prompt, which wrongly
said only completed/failed tasks can be archived or deleted (the store refuses only in-progress ones).

## Incident

Session `8701B623…`, 2026-10-11 19:07:34 CDT. User: "stop and delete all of the app audit tasks that
aren't already finalized" (batch B32B2C4B, worker capacity 10). Sources: `channel_log.jsonl`, unified
log `com.agentsmith:Stop`, `tasks.json`.

What happened (verified):

1. **No stop was ever security-blocked.** All 14 `terminate_agent` calls were `autoApproved`. Every
   Smith security row matches a Smith `tool_request` by `requestID`, so nothing was misattributed.
2. **Every delete was security-blocked once.** All 10 `manage_task_disposition action=delete` calls
   got WARN ("Your tool was not allowed to execute…"), then an identical retry was auto-approved.
   The tool isn't in `SecurityEvaluator.autoApprovedToolsByRole[.smith]`. Each costs a reviewer call
   (~2–4 s), a denial and a retry. Several verdicts also said "this task ID is not identified as an
   unfinished audit": the reviewer sees only the UUID and the user's message, not the task title.
3. **Killing workers started more audits.** Every freed slot was refilled from the pending queue
   (`advanceAfterFreedWorkerSlot`). LockRattler started after Godot completed (+86 s). SystHist, ANIE,
   Crumb and Xcode_27.1_beta started after Smith's own kills (+118, +156, +189, +216 s). All five
   started AFTER the stop request, and Smith had to kill each one again.
4. **Stops waited 17–86 s.** `terminateAgent` is a lifecycle-queue item. Each auto-start runs
   `performSpawnBrown`, which makes the Security Agent tool-scoping model call ("Preparing task —
   starting MCP servers and checking security policy…") INSIDE the queue. The unified log shows that
   `Runtime.terminateAgent entry` for Sourcetree came 86 s after the request (19:11:12 → 19:12:38),
   SystHist 29 s and ANIE 17 s. `agent.stop` itself took 0–692 ms. ROADMAP P2 already lists this
   ("Scoping LLM call runs inside the lifecycle queue and serializes spawns"). A user's Stop button
   goes through the same queue and stalls the same way.
5. **One task couldn't be stopped.** "Reconcile non-MAS audit batch B32B2C4B" (`2D311F2C`) is in
   `awaitingHelp` with no live worker:
   - `provide_help`: can't spawn (10/10 workers live).
   - `terminate_agent`: "No live Brown worker", and it changes nothing.
   - `update_task status=failed is_template=false`: refused with "cannot be converted while it is
     awaitingHelp". The model sent `is_template=false` on a task that already isn't a template, and
     `TaskStore.setTemplate` checks `isInProgress` BEFORE checking whether the flag changes anything.
     `awaitingHelp → failed` under `.smithSetStatus` is permitted (`TaskStatusTransition.swift:208`),
     so the call would have succeeded without the no-op flag.
6. Context compacted three times during the cleanup, so Smith re-derived task IDs with `grep` /
   `file_read` on a tool-output overflow file (each one reviewed). This is a side effect, not a cause.
7. Unrelated: Brown put `manage_steps 2>/dev/null; true` inside a bash command, and the Security
   Agent correctly marked it UNSAFE. That's model confusion, not an app bug. No action.

## Fixes

### F1 — Pre-clear Smith's task-management tools (user request) ✅

Add to `autoApprovedToolsByRole[.smith]`: `manage_task_disposition`, `set_acceptance_criteria`,
`set_preconditions`, `manage_steps`. All are gated by the store, act only on this session's tasks, and
are recoverable or contract-only: `delete` is a soft delete to Recently Deleted, and the contract
tools are gated by `Status.isValidationContractEditable`. `save_memory` stays reviewed; it's pinned by
`smithStatefulToolsRemainReviewed`. Update the doc comment above the table.

- Test: extend `smithWorkerStopControlsArePreCleared`-style parameterized test for the four names
  (fails before, passes after).

### F2 — `setTemplate` no-op must not be refused ✅

In `TaskStore.setTemplate`, return success with no write when `isTemplate == task.isTemplate`, BEFORE
the `isInProgress` guard. Then `update_task(status: failed, is_template: false)` on an `awaitingHelp`
task applies the status. The `ToolArguments` rule doesn't apply: `false` is a real value, not an empty
sentinel. The defect is that a no-op flip gets refused.

- Regression test: an `awaitingHelp` non-template task; `update_task` with
  `status=failed, is_template=false` → succeeds, status `.failed`. Must fail before the fix.
- Test: `setTemplate(isTemplate: true)` on an in-progress non-template task is still refused.

### F3 — Stop the auto-start refill during a bulk stop (A ✅)

Root cause: Smith stops running tasks first, and each freed slot pulls in a still-pending sibling.
Options:

- **A (recommended): prompt guidance plus F1.** Smith's prompt says: to stop a group, first remove the
  pending/scheduled members (`manage_task_disposition delete`, or `update_task paused`), then terminate
  the running ones. With F1, each dequeue is instant. Cost: S. Weakness: relies on the model following it.
- **B: cascade from the coordinator.** Deleting or failing a coordinator task (`coordinatorTaskID`) also
  pauses its pending children. Here Smith deleted the coordinator at +82 s, and its children still
  auto-ran afterward. This is structural, but it changes task semantics: an **architecture decision
  for the user.**
- **C: hold auto-advance while Smith is stopping workers.** Rejected: legitimate queued work (the
  ScanSnap task) should still start, and a hold keyed to "Smith is stopping things" has no clean
  end signal.

Plan: A now. B only if the user approves it.

- Test (A): system-prompt content test asserting the ordering guidance is present.

### F4 — Scoping outside the lifecycle queue (ROADMAP P2 item, promoted)

Per the ROADMAP note: spawn reserves its handle and slot under the queue, runs `scopeTools` outside it,
then re-enters the queue to commit or roll back. On commit, re-check `aborted`, `stopRequested`, that
the task is still `.starting` (not deleted, paused or failed mid-scope), and capacity. The existing
post-scope `guard !aborted, !stopRequested` moves into the commit step. After this, a terminate or a
user Stop no longer waits behind a 30–60 s model call. **Architecture change to the lifecycle queue:
needs the user's explicit consent before implementation.** Size: M.

- Regression test: a scoping provider that blocks until released; start a task; while scoping is
  blocked, `terminateAgent` on another live worker returns promptly (bounded wait, e.g. < 1 s).
  Must fail before the change (it waits for the scoping call).
- Test: deleting or pausing the task during scoping → the commit rolls back, no worker spawns, the
  reserved slot is freed and the status is consistent.
- Test: `stopAll` during scoping → no worker is minted (existing guarantee preserved).

### F5 — `terminate_agent` with no live worker on a parked task ✅

When there's no live worker and the task is `awaitingHelp`, the failure text should tell Smith what to
do next: `update_task status=failed` (no worker to stop). The text is for the model only, and no
control flow reads it. Cost: S.

- Test: output names `update_task` for an `awaitingHelp` task with no worker.

## Validation

1. `swift test --skip MemoryStoreIntegrationTests` passes. New regression tests fail before and pass
   after. Delete `.build` afterward.
2. App builds via xcode-mcp with no new warnings.
3. Live replay: create 12 template-child tasks at capacity 4 with a 1-minute shell sleep, then tell
   Smith "stop and delete all of them". Pass criteria: no new `task_acknowledged` for that group after
   the request; no `security_review` WARN on `manage_task_disposition`; each `Runtime.terminateAgent
   entry` within 2 s of its `terminate_agent` request (unified log); all 12 in Recently Deleted.
4. An `awaitingHelp` task with no worker at full capacity: Smith fails it with `update_task` on its
   first try.

## Decisions needed from the user

1. F3-B: should deleting or failing a coordinator task pause its pending children?
2. F4: approve moving scoping out of the lifecycle queue now (it's already on the ROADMAP as P2)?
