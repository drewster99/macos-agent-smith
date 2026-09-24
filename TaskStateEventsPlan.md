# Task state events and task watches

> **Status:** design approved in principle 2026-09-24 ("one event source, two kinds of subscriber");
> this document is the finalized plan after a research recheck. Decisions marked **[CONFIRM]** need
> the user's answer before the phase that depends on them starts.

## Goal

1. Every task status change becomes ONE typed event, produced in exactly one place.
2. Everything that reacts to a status change subscribes to that event:
   - the runtime's own reactions (refill worker slots, cancel the task's timers, start validation);
   - the harness's Smith briefing (what Smith is told today, from scattered call sites);
   - user-defined **watches**: "when task X reaches state S, do A".
3. Watch actions: start another task, macOS notification, summarize to the user, instructions for
   Smith. Authored by Smith (`watch_task` tool) and in the UI (Task Detail + Timers window).

There is no second mechanism: the harness notifier and watches are two subscribers of the same
event. They differ only in who defines them (code vs user data).

## What the research established (verified against the code)

### Status writes today
- `TaskStore` (an actor, one per session) owns status, but writes it through **three shapes**:
  - `updateStatus(id:status:)` (`TaskStore.swift:811`) — the main funnel. Sets `startedAt` /
    `completedAt` / disposition, fires `onTaskTerminated` on non-terminal→terminal only.
  - Two CAS wrappers (`:856`, `:2105`) that **return `true` even when the inner write refuses**
    (`.awaitingReview` with no result, `:817-825`). Verified.
  - **Eight direct writes that bypass the funnel**: `normalizeTemplateLauncher` :496,
    `promoteScheduledToPending` :758, `resetFailedTask` :891, `reopenCompletedTask` :932,
    `requestHelp` :1681, `blockValidation` :1704, `releaseValidationBlockedTasks` :1721 (bulk),
    and the `restore` migration :2133 (load time).
- One write bypasses the store entirely: `AppViewModel.swift:716-722` (load-time running →
  interrupted on the raw array).
- ~40 call sites across runtime, validation coordinator, tools, app, watchdog.
- No-op transitions happen and are not suppressed (Brown's ack running→running on every start,
  `update_task` to the current status, template normalization pending→pending).
- Load-time/bulk transitions that must NOT be treated as live events: `restore`, the app's
  load-time demotion, cold-boot reconciliation in `performStart` (:2681-2720, :1620, :2705 — Smith
  gets a whole-state initial instruction instead), `stopAll` / session-delete bulk interrupts,
  template-clone births (:479).

### How Smith hears today
- Roughly ten status transitions produce a Smith note, each composed at its own call site and
  injected with `AgentActor.appendUserMessage` — never persisted, **silently dropped when no Smith is
  live** — or posted as a `.userTaskAction` channel row.
- Many transitions reach Smith with no note (validator escalation, block/release, rejections
  returned, user Fail / Re-validate / Send back, scheduled pause/interrupt, scheduled→pending,
  worker self-terminate, task_complete→validating). Some are deliberate (escalation is the user's).
- Disposition changes (archive, delete, undelete, Retry, Run Again) are not status changes; their
  notices stay where they are.

### Notification broker
- Per-session actor with a durable ledger (effectively-once, deterministic ids) and a durable pull
  outbox for Smith (leased, acked on next drain). Only producer today: the `WakeScheduler`.
- Adding a trigger means a new `TriggerSource` case with a **permanent** namespace string plus its
  hand-written Codable and round-trip test.
- `.acted` / push outcomes are durable only if the SOURCE can re-produce them after a crash — so a
  watch firing must be recorded durably by us before submission.
- No startup guard verifies every notification type has a handler (designed in ROADMAP, never built).

### Starting a task from a trigger
- The timer path (`dispatchAutoRunWake` → pending scheduled-run queue → `restartForNewTask`) is the
  analogue. It never evicts, queues at capacity, reports refusals — but its wording and channel
  kinds say "Scheduled run", and it calls `prepareForRun`, which **silently reopens a completed task
  or resets a failed one**. Reusing it unchanged would let a watch reopen a completed task, against
  the 2026-09-22 "a completed contract is immutable" rule.
- **Auto-advance would start the dependent task early**: a pending B is picked up by "Auto-run next
  task" as soon as any slot frees, long before A completes. Chaining needs B held.

### macOS notifications
- Nothing exists (no `UserNotifications` anywhere). Sandbox off, hardened runtime on, Developer ID —
  no entitlement or plist key needed. Needs: authorization request, a delegate set at launch
  (`willPresent` so banners show while the app is frontmost; `didReceive` for clicks), and click
  routing to Task Detail through a `SharedAppState` request flag (the app's existing pattern — there
  is no URL deep-linking).

### Where watches live
- On the task (`AgentTask.watches`), not in a per-session file: the watch travels with the task
  through archive/restore and cross-session unarchive, is deleted with it, and its trigger check can
  run in the same actor step as the status write (no TOCTOU). `AgentTask` has hand-written Codable
  with no key-coverage guard — the new field needs all four places plus a round-trip test.

## Design

### A. `TaskStatusTransition` — one funnel, one event

```swift
public struct TaskStatusTransition: Sendable, Equatable {
    public let taskID: UUID
    public let taskTitle: String
    public let from: AgentTask.Status
    public let to: AgentTask.Status
    public let at: Date
    public let cause: TaskTransitionCause   // typed, required
}
```

- **`TaskTransitionCause`** is a typed enum naming why the status changed, with the context
  subscribers need as associated values — e.g. `.startClaimed`, `.workerStarted`,
  `.spawnFailed(reason)`, `.submittedForValidation`, `.validationPassed(validationWasRun:)`,
  `.validationFailedNoProgress(summary)`, `.validationEscalated`, `.rejectionsReturned`,
  `.userPaused`, `.userStopped`, `.userAccepted`, `.userFailed`, `.userRevalidated`,
  `.userSentBack`, `.capacityShed(newCapacity:)`, `.scheduledAction(TaskActionKind)`,
  `.scheduledTimeReached`, `.helpRequested`, `.helpProvided`, `.workerSelfTerminated(reason)`,
  `.orphanRecovered`, `.smithSetStatus`, `.resetForRun`, `.reopenedForRun`,
  `.validationBlocked(reason)`, `.validationReleased`, `.coldBootReconciliation`,
  `.sessionShutdown`.
- **One private writer** in `TaskStore` (`applyStatus(_:to:cause:)`) that every live status write
  routes through — the funnel, both CAS wrappers, and the eight direct writers. It performs the
  bookkeeping (`startedAt`, `completedAt` including the deliberate clears on reset/reopen,
  disposition), suppresses no-op transitions (`from == to`), reads `from` itself (never trusts a
  caller snapshot), and emits exactly one event per real write.
- Every public status-writing API gains a **required** `cause:` parameter, so the compiler
  enumerates all ~40 call sites; none can be forgotten.
- The CAS wrappers return whether the write **actually happened** (fixes the lying `true`).
- Excluded by construction (no event): `restore` and its migration, the app's load-time demotion
  (moved into `restore` as a typed load-time repair), template normalization, clone births.
- Cold-boot reconciliation and shutdown bulk writes DO emit, tagged `.coldBootReconciliation` /
  `.sessionShutdown`, so each subscriber decides (the Smith briefing skips them; watches — see
  [CONFIRM 4]).
- Delivery: emitted synchronously inside the actor to registered subscribers, in write order
  (per-store FIFO). `onTaskTerminated` becomes a derived subscriber of this stream (same trigger:
  first entry into completed/failed), so the runtime's slot refill and timer cancellation keep
  their behavior with one source.

### B. The harness Smith briefing (built-in subscriber)

- One `SmithTaskBriefing` maps `(to, cause)` → the note Smith receives, or nothing. It replaces the
  scattered per-site notes for STATUS transitions; the wording of today's notes is preserved.
- Behavior-preserving in its first commit: same transitions notified, same text, same channel
  (`appendUserMessage` vs `.userTaskAction` row). Gaps and delivery durability are follow-up
  decisions ([CONFIRM 1], [CONFIRM 2]) — changing what Smith is told is a behavior change, kept out of
  the refactor commit.
- Disposition notices (delete, undelete, Retry, Run Again) stay where they are — they are not status
  transitions.

### C. Task watches

```swift
public struct TaskWatch: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var triggers: Set<TaskWatchTrigger>        // see "Watchable states"
    public var action: TaskWatchAction
    public var lifetime: TaskWatchLifetime            // .once / .everyTime
    public let createdBy: TaskAuthorship               // .user / .smith
    public let createdAt: Date
    public var firings: [TaskWatchFiring]             // durable record, drives delivery
}

public enum TaskWatchAction: Codable, Sendable, Equatable {
    case startTask(taskID: UUID)
    case macOSNotification
    case summarizeToUser
    case instructSmith(String)
}
```

- **Watchable states** (user-meaningful): started, completed, failed, needs help (`awaitingHelp`),
  needs review (`awaitingReview`), interrupted. Matched on the typed transition, not the bare status
  pair: "started" means cause `.workerStarted` — NOT any entry into `running`, which would also fire
  when validation hands rejections back (validating → running) or help is provided. The watchable
  state is therefore its own small enum (`TaskWatchTrigger`) mapped from `(to, cause)` in one place.
- **Lifetime defaults**: `startTask` → `.once` (a chain link runs once); the notifying actions →
  `.everyTime`. Editable.
- **Firing** happens inside `applyStatus`, in the same actor step as the status write: each matching
  watch appends a `TaskWatchFiring(occurrence: n, transition: …, state: .pending)`. Because it lands
  in the same in-memory write as the status, both persist together — there is no window where the
  status changed but the firing was lost.
- **Delivery** through the NotificationBroker: new `TriggerSource.taskWatch(watchID:occurrence:)`
  (namespace `"taskwatch"`, permanent), idempotency key `watchID|occurrence`. On settle, the firing
  is marked `.delivered`/`.refused(reason)`. At cold boot, every `.pending` firing is re-submitted —
  the ledger dedups, and the firing record (not the 5,000-id ledger alone) is the real dedup.
- **Actions**
  - `startTask(B)`: a watch-specific run path (NOT `prepareForRun`'s reopen/reset): B must be
    runnable (pending / paused / interrupted, or a template → cloned instance). Completed or failed
    B is refused visibly, never reopened. Queues at capacity like a scheduled run; refusals get their
    own typed channel kind (`.taskWatchRefused`), `.error` severity, plus a Smith note.
    **Holding B until A fires** — see [CONFIRM 3].
  - `macOSNotification`: push recipient `.external("macos")`, supplied by the app. Title = task
    title + state; body = result excerpt (completed) / reason (failed, help, review). Identifier =
    the notification id (a re-post replaces, never duplicates). Authorization requested lazily when
    the first such watch is created; denied permission surfaces as a visible `.warning`, never a
    silent drop. Click opens that task's Task Detail.
  - `summarizeToUser`: delivered to Smith's durable pull queue with an explicit instruction to send
    the user a short summary via `message_user` — the note overrides the completion briefing's "no
    action needed". Uses `task.summary` when present, else the result. See [CONFIRM 6].
  - `instructSmith(text)`: delivered to Smith's durable pull queue, framed with the task and the
    state reached.
- **Templates**: a watch on a template is a blueprint — `instantiateTemplate` copies it into each
  instance with a fresh id and empty firings (e.g. "every nightly run: notify me if it fails").
  The preserved-history child and every other copy get none. See [CONFIRM 5].
- **Archive / delete**: a watch on an archived task is dormant (the task can't change state);
  delete removes it with the task. A `startTask` target that is archived is refused, not restored.

### D. Authoring and display

- **`watch_task` Smith tool** — `create` / `list` / `cancel`, typed argument enums, optional
  arguments through `ToolArguments`. Pre-cleared in Smith's `autoApprovedToolsByRole` (same class as
  `schedule_task_action`), classified low-risk side-effecting, in a built-in tool group, billed to
  the watched task, prompt guidance next to `## Timers`.
- **Task Detail**: a "When this task…" section (list, add, cancel; task picker for `startTask`).
- **Timers window**: a "Watches" tab listing every watch in the session with cancel.
- **`get_task_details`** renders a task's watches.
- **Transcript**: a typed `.taskWatchFired` row per delivered firing (visible, filterable) and
  `.taskWatchRefused` at `.error`.

## Phases

Each phase: implement → recheck → build (xcode-mcp) → full `swift test` (+ MLX suite when memory is
touched) → commit → push.

1. **Transition funnel.** `TaskStatusTransition`, `TaskTransitionCause`, `applyStatus`, required
   `cause:` at every call site, truthful CAS returns, no-op suppression, load-time exclusions,
   `onTaskTerminated` derived from the stream. Tests: every writer emits exactly once, no-ops and
   restore emit nothing, CAS returns false on refusal, per-store ordering, cold-boot causes tagged.
2. **Smith briefing subscriber.** Move the status-transition notes into `SmithTaskBriefing`,
   behavior-preserving. Tests: each cause → exact note (or none), parity with today's set.
3. **Watch model + firing.** `TaskWatch` on `AgentTask` (Codable in all four places + round trip),
   firing inside `applyStatus`, `TriggerSource.taskWatch`, handlers, cold-boot re-submission, the
   startup handler guard (every `KnownNotificationType` has a handler). Tests: firing is atomic with
   the write, once vs everyTime, crash-replay dedup, template blueprint copy.
4. **Actions.** `startTask` path (+ hold, per [CONFIRM 3]), `instructSmith`, `summarizeToUser`,
   macOS notifications (app target: authorization, delegate, push target, click routing).
5. **Authoring + UI.** `watch_task` tool (all registration points), Task Detail section, Timers tab,
   `get_task_details`, transcript kinds (+ ChannelMessageKind guard table).
6. **Integrated recheck.** Live run: chain A→B, notifications, restart mid-chain; CLAUDE.md entry.

## Decisions needed

1. **[CONFIRM 1] Smith briefing gaps.** Today Smith is not told about escalation, block/release,
   rejections returned, user Fail/Re-validate/Send back, scheduled pause/interrupt, worker
   self-terminate. Keep that exact set (recommended for Phase 2), or widen it in a follow-up?
2. **[CONFIRM 2] Briefing durability.** Today's notes are dropped if no Smith is live. Route the
   briefing through the broker's durable Smith queue (delivered after a restart) — recommended —
   or keep direct injection?
3. **[CONFIRM 3] Holding the chained task.** For "start B when A completes", B must not be started
   early by auto-advance. Recommended: a typed hold on B (`startHold: .awaitingTask(A)`) that
   auto-advance skips and the task list shows as "Waiting on A"; Play still starts it (explicit
   override). If A fails or is deleted, B stays held and the user is told. Alternative: B stays a
   normal pending task (auto-advance may start it early).
4. **[CONFIRM 4] Cold-boot transitions and watches.** A task found mid-run after a crash is marked
   interrupted at launch. Should an "interrupted" watch fire for that? Recommended: yes — it is a
   real event the user asked to hear about.
5. **[CONFIRM 5] Template watches as blueprints** (copied into every run). Recommended: yes.
6. **[CONFIRM 6] "Summarize to me".** Smith writes it (an LLM call, natural wording — recommended),
   or a deterministic post of the stored summary/result (no LLM cost).

## Existing defects found during research (fixed in the phase noted)

- CAS status wrappers report success when the write was refused — Phase 1.
- `TaskStore.permanentlyDelete` of an active task fires no hook, orphaning its scheduled wakes —
  Phase 1 (the transition/disposition hooks are being reworked anyway).
- `NotificationBroker` has no startup guard that every first-party type has a handler — Phase 3.
- Brown's acknowledgement writes running→running on every start (a no-op write) — Phase 1
  (suppressed as a no-op).
- `update_task` can set `.paused` on a running task without stopping its worker; `request_help` can
  move a `.validating` task to `.awaitingHelp` — reported, not changed (behavior decisions, out of
  scope).
