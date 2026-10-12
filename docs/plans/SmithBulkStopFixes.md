# Smith bulk stop/delete — fix plan

Status: F1, F2, F3-A, F5 ✅ implemented 2026-10-11 (tests in `SmithBulkStopTests.swift`; each failed before
its fix). F3-B ✅ implemented 2026-10-11 (user approved; see below). F4 ✅ implemented 2026-10-11 by a different design (below). F3-A also corrected Smith's prompt, which wrongly
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

**B — approved and implemented (2026-10-11).** User: "Deleting or failing coordinator should also
pause/stop/cancel its child tasks... if they're not running in service of the parent, why are they
running at all?" Implemented for any coordinator end (completed, failed, archived, deleted): see
`docs/claude/coordinator-tasks-and-capabilities.md`. **It would NOT have changed this incident:** none
of the 113 batch audit tasks had `coordinatorTaskID`. They were template instances (`parentTaskID` =
template B100BA59) that Smith started directly with `run_task`. The two "coordinator" tasks were
ordinary tasks Smith created and named that way.

- Test (A): system-prompt content test asserting the ordering guidance is present.

### F4 — Scoping outside the lifecycle queue (ROADMAP P2 item, promoted) — ✅ by a different design

**As built (2026-10-11):** the split below was REJECTED by the user ("we can't create races"): it
leaves a half-started task visible to every other operation. Instead a stop INTERRUPTS a start that is
choosing its tools: its scoping call is cancelled, the task goes back to pending (interrupted when the
start was resuming an interrupted task, same rule as a capacity refusal), and it is started again
through `restartForNewTask`, queued behind the stop. Every operation still runs alone on the lifecycle
queue. Only stops interrupt (`terminateAgent`, `terminateTaskAgents`, a coordinator-ended child stop), and only
when they end a live worker (an archive of a finished task must not throw away a scoping call — once per
task in a bulk archive);
a stop of the starting task itself waits, as before. The stop interrupts and enqueues in ONE actor turn
(`SerialChainedTaskQueue.enqueue`, synchronous): `run` is a nonisolated async function and gives up the
actor before it queues, which would let the retry jump ahead of the stop. A stop that arrives before
the scoping call begins (MCP settle) cancels it before it starts. One that arrives after it ended waits
for the short remainder. Tests: `StopInterruptsStartTests`.

Original (rejected) plan, kept for the record:

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

## Why "Reconcile non-MAS audit batch B32B2C4B" (`2D311F2C`) was stuck (investigated 2026-10-11)

Sources: `tasks.json` updates, LLM request logs for 10-09 (the channel log has no rows from
10-09 09:52:54 to 10-10 13:38:09; see below).

1. 10-06: its worker couldn't do the job. It had no tool to list a template's instances or
   instantiate/retry them, and asked for help twice. Smith added required capabilities, but no worker
   tool provides those abilities.
2. 10-09 ~10:09: Smith first tried `update_task(status: paused, is_template: false)`, which the F2
   bug refused. It then told the worker to "remain inactive pending new lifecycle evidence".
3. A worker can't sit idle. By the worker's own account, the run loop rejected its empty turn, so it
   used `request_help` as a parking spot and asked Smith NOT to answer until evidence arrived. Smith
   complied: its next turn was "(no response)". The task stayed in `awaitingHelp` from then on.
4. 10-11: Smith created a second coordinator task (`4068A9A4`) for the same batch and never closed this one.
5. 10-11 19:02 and 19:09 (stop request): `update_task status=failed is_template=false` was refused (F2),
   `provide_help` couldn't spawn a worker (10/10 slots), and `terminate_agent` found no worker. No
   working path remained. F2 and F5 close this.

Underlying gap, NOT fixed: a task waiting on outside events (other tasks finishing) has no structural
way to wait. `wait_for_child_tasks` covers only its own `coordinatorTaskID` children, and this task had
none. Parking in `request_help` is a misuse.

**Separate finding: lost transcript.** `channel_log.jsonl` has no rows from 10-09 09:52:54 until the
next launch (10-10 13:37), yet that run kept working until at least 10:47 (LLM logs, `tasks.json`
updates at 10:00–10:28). About 55 minutes of transcript never reached disk. No crash report exists;
that day's default-level unified logs are gone. Not investigated further.

## Follow-up: a terminated coordinator's slot went to its child (fixed 2026-10-11)

`terminate_agent` ends the worker, then fails the task. The drain the freed slot triggers ran in
between and, reading only the coordinator's STATUS (`occupiesWorkerSlot`), started its queued child,
which the cascade then stopped. Now a coordinator counts as working only while its worker is live.
Test: `coordinatorWithoutWorkerDoesNotStartItsChild`.

## Recheck fixes (2026-10-11)

- A stop interrupts a start only when it ends a LIVE worker (`liveWorkerID(for:)`). Before this,
  archiving a finished task (`terminateTaskAgents` with nothing to end) discarded the start's scoping
  call, and a bulk archive would have discarded it again for each task. Test:
  `stopWithoutWorkerDoesNotInterrupt` (fails ungated).
- `liveWorkerID(for:)` is the synchronous form of `liveWorkerID(taskID:)`, which now calls it, so the
  drain's "working coordinator" check and the stop interrupt use the ONE task-to-worker lookup.
- The coordinator-ended cascade runs on every task's end; it now skips the inactive-store scan for a
  task that never created a child (`childTasksCreated == 0`).
- Independent review (codex + fresh Opus), all four verified against the code and fixed:
  1. Routine worker teardown (`TaskValidationCoordinator` after every completion, rework rollbacks,
     a worker's self-block) went through `terminateAgent` and so interrupted unrelated starts. Now
     only `stopWorker` (Smith's `terminate_agent`) and `terminateTaskAgents` (user/scheduled stops)
     interrupt; `terminateAgent` waits its turn. Test: `routineTeardownDoesNotInterrupt`.
  2. A Stop All landing during the requeue's awaits: the retry would run after the teardown (which
     clears `stopRequested`) and cold-start the stopped session. The requeue now checks
     `aborted`/`stopRequested` last, before scheduling.
  3. The drain (auto-advance, resume queues) could start a pending child of an ended coordinator
     before its stop ran. The drain now never starts one (`isChildOfEndedCoordinator`).
  4. A coordinator reopened (run_task retry) after its children's stop was scheduled still lost
     them. The child is now failed through `TaskStore.failChildOfEndedCoordinator`, which re-checks the
     coordinator in the same write, BEFORE its worker is terminated.

## Live replay (2026-10-11 20:33–20:41) and the fix it forced

12 "Replay sleeper" tasks (`sleep 240`), worker capacity full: 6 running, 1 starting, 5 queued when
the user's "stop and delete all of the Replay sleeper tasks" was sent.

Passed:
- Every Smith call auto-approved; zero WARN on `manage_task_disposition`.
- Smith deleted the 4 queued tasks FIRST (F3), then terminated the running ones, then deleted them.
- No sleeper started after the request except the one already starting; all 12 ended in Recently
  Deleted (2 had completed on their own first).
- The start that was choosing its tools was interrupted ("set aside so a stop could run first").

Failed: the first terminate still waited 33 s (request 20:38:37.7, `Runtime.terminateAgent entry`
20:39:10.96). The interrupt worked, but a DUPLICATE start of the same task was already queued AHEAD of
the stop (from `create_task`'s auto-start and the drain). It claimed the task the interrupt had just
set back to pending, and ran a full scoping call. The general case: any start queued ahead of a stop
made it wait — the incident's auto-advance backlog.

Fix: deliberate stops are counted while queued (`deliberateStopsWaiting`, via `enqueueDeliberateStop`),
and a start that comes up while one waits steps behind it before claiming anything. Test:
`stopRunsAheadOfQueuedStarts` (fails without it).

## Archive of a finished task skips the queue (2026-10-12, user)

The user's 2026-10-11 19:12:38 archive clicks waited out the 86 s stall: the app's `archiveTask` calls
`terminateTaskAgents`, which queued behind the start choosing its tools even with no worker to end.
Now `terminateTaskAgents` returns without queuing when the task has no live worker and is in a status
no worker can be arriving for (`statusesWithNoWorkerComing`: pending, scheduled, paused, interrupted,
completed, failed). Tests: `archiveOfFinishedTaskSkipsQueue`; `stopWithoutWorkerDoesNotInterrupt` now
asserts the stop returns immediately (user-approved change to that test).
