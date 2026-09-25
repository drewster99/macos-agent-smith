# Task state events and task watches

> **Status:** design approved 2026-09-24 ("one event source, two kinds of subscriber"). Revised
> 2026-09-25 after an independent review against the code (Codex). The review found the first
> draft directionally sound but not implementation-ready, citing crash consistency, cold-boot
> behavior, hold enforcement, and actor/event ordering. Every finding was verified and the user
> approved every recommended remedy (Decisions 7–11). The live defect it exposed, cold-boot
> recovery of submitted work, is already fixed (`9056501`).

## Goal

1. Every task status change becomes ONE typed event, produced in exactly one place.
2. Everything that reacts to a status change subscribes to that event:
   - the runtime's own reactions (refill worker slots, cancel the task's timers, start validation);
   - the harness's Smith briefing (what Smith is told today, from scattered call sites);
   - user-defined **watches**: "when task X reaches state S, do A".
3. Watch actions: start another task, macOS notification, summarize to the user, instructions for
   Smith. Authored by Smith (`watch_task` / `list_task_watches`) and in the UI (Task Detail +
   Timers window).
4. Every effect of a transition is **crash-consistent**: it is either durably recorded with the
   status that caused it, or neither is.

There is no second mechanism: the harness notifier and watches are two subscribers of the same
event. They differ only in who defines them (code vs user data).

## What the research established (verified against the code)

### Status writes today
- `TaskStore` (an actor, one per session) owns status, but writes it in **three shapes**:
  - `updateStatus(id:status:)` (`TaskStore.swift:811`) is the main funnel. It sets `startedAt` /
    `completedAt` / disposition and fires `onTaskTerminated` on non-terminal→terminal only.
  - Two CAS wrappers (`:856`, `:2105`) **return `true` even when the inner write refuses**
    (`.awaitingReview` with no result, `:817-825`).
  - **Eight direct writes bypass the funnel**: `normalizeTemplateLauncher` :496 (can turn a
    completed/failed task back into pending), `promoteScheduledToPending` :758, `resetFailedTask`
    :891, `reopenCompletedTask` :932, `requestHelp` :1681, `blockValidation` :1704,
    `releaseValidationBlockedTasks` :1721 (bulk), and the `restore` migration :2133.
- The session loader also writes status on the raw array before any store exists. It used to demote
  every `.running` task to `.interrupted`, which blinded the runtime's submitted-result recovery.
  Since `9056501`, both places apply one rule (`ColdBootRunningRecovery`). The loader write still
  bypasses the store, and Phase 2 moves it into it.
- There are 39 direct call sites of the writer APIs.
- No-op transitions happen and are not suppressed: Brown's acknowledgement (`AgentActor.swift:2891`)
  writes running→running, `update_task` can write the current status, and template normalization
  writes pending→pending.
- **Two bulk interrupts, which are not the same behavior:** `stopAll` interrupts only `.running`
  (`AppViewModel.swift:2375`). Session deletion interrupts every `isInProgress` task
  (`moveAllActiveTasksToInactive`, `:2405`).
- **Status is written BEFORE the facts its effects depend on:**
  - completion precedes worker teardown, the completion banner, and summarization
    (`TaskValidationCoordinator.swift:1276`);
  - failure precedes its explanatory update (`:448`);
  - `.running` precedes worker assignment and briefing (`OrchestrationRuntime.swift:2268`);
  - `.validating` precedes the submission banner and validation kickoff (`TaskCompleteTool.swift:121`).
- Deletion and disposition are NOT status changes. Permanent delete of an active task fires only
  `onChange` (`TaskStore.swift:2058`). Archive/restore have their own inactive hook (`:17`).

### Persistence (why "persists together" was false)
- A status write fires `onChange` synchronously. The app then hops through two unstructured tasks
  before writing (`AppViewModel.swift:1182`, `:2791`), so nothing can await "this revision is
  durable".
- `SerialPersistenceWriter` advances its watermark on failure (`SerialPersistenceWriter.swift:75`).
  `flush()` means "drained", not "durable".
- The broker's pending-delivery persistence swallows errors (`AppViewModel.swift:1398`).

### How Smith hears today
- About ten status transitions produce a Smith note. Each note is composed at its own call site and
  injected with `AgentActor.appendUserMessage`. Those notes are never persisted and are **silently
  dropped when no Smith is live**. Other notices are posted as `.userTaskAction` channel rows.
- Several transitions reach Smith with no status note. Some of those are deliberate: escalation is
  the user's to resolve. Correction to the first draft: worker self-termination is not silent,
  because `.agentLifecycle` rows reach Smith through its channel whitelist
  (`OrchestrationRuntime.swift:4217`).
- Some notices have no status change at all, so they can never move onto a transition subscriber.
  The clearest case is a scheduled-run refusal (`OrchestrationRuntime.swift:985`). They stay at
  their call sites.

### Notification broker
- The broker is a per-session actor with a durable ledger (deterministic ids, bounded to 5,000
  entries) and a durable, leased pull outbox for Smith. Delivery is **at-least-once**
  (`NotificationBroker.swift:349`). The runtime drops notification ids (`.map(\.text)`,
  `OrchestrationRuntime.swift:2531`), and AgentActor receives bare text (`AgentActor.swift:3610`).
- The only producer today is `WakeScheduler`. A new `TriggerSource` case needs a permanent namespace
  string, plus hand-written Codable and a round-trip test.
- **Settlement is lossy:**
  - observers run before handling and are best-effort (`:260`);
  - a handler's refusal reason collapses to `.runtimeRefused` (`:281`);
  - a push target returning `false` leaves the id unsettled with no retry (`:294`);
  - there is no settlement callback.
- No startup guard checks that every notification type has a handler.

### Starting a task from a trigger
- The start inputs are independent:
  - auto-advance's three queues (capacity-deferred, launch-resume, pending; `:1236`);
  - scheduled wakes (`:901`);
  - `run_task`;
  - the UI's Play;
  - cold-launch resume, which spawns workers directly (`:2903`) instead of going through
    `restartForNewTask` (`:2071`).
- None of them carries a start origin (`AppViewModel.swift:2256`, `RunTaskTool.swift:155`), so a
  hold enforced in one place is bypassed by the others.
- `prepareForRun` resets failed tasks and reopens completed ones in place (`TaskStore.swift:984`).
  Reusing it would let a watch reopen a completed task, against the 2026-09-22 immutable-contract
  rule.
- Auto-advance starts any ordinary pending task (`:1249`), so a chained B would start early.

### Sessions and templates
- Templates are global. `TaskStore` and the broker are per session. `AgentTask.sessionID` is the
  immutable ORIGIN session (`AgentTask.swift:100`). A cross-session unarchive keeps it while placing
  the task in the current store. Cross-session routing does not exist.

### macOS notifications
- Nothing exists yet: `UserNotifications` is not used anywhere.
- Task Detail opens through `OpenWindowAction` with a typed `(sessionID, taskID)` target
  (`AgentSmithApp.swift:250`, `:372`). `SharedAppState` has request flags for other windows but none
  for Task Detail.
- The delegate must be installed before launch completes.
- Authorization can be revoked at any time.

### `AgentTask` Codable
- `AgentTask` has hand-written Codable: declaration, init, CodingKeys, decode, encode
  (`AgentTask.swift:403`, `:483`, `:487`).
- There is no key-coverage guard. A round-trip test cannot catch an omitted default-valued key
  (CLAUDE.md, "Persisted keys outlive property renames").

## Design

### A. The transition funnel

```swift
public struct TaskStatusTransition: Sendable, Equatable {
    public let taskID: UUID
    public let statusRevision: Int          // per-task, monotonic, persisted
    public let from: AgentTask.Status
    public let to: AgentTask.Status
    public let at: Date
    public let cause: TaskTransitionCause   // typed, required, validated
}
```

- **One private writer**, `TaskStore.applyStatus(_:to:cause:)`.
  - **Scope:** every live status write goes through it: the funnel, both CAS wrappers, the eight
    direct writers, and cold-boot reconciliation.
  - **Behavior:**
    - reads `from` itself and suppresses no-ops;
    - does the bookkeeping (`startedAt`, `completedAt`, deliberate clears, disposition);
    - increments `AgentTask.statusRevision`;
    - builds the transition.
  - **Returns** whether the write happened. The CAS wrappers pass that through, so they stop
    returning `true` for a refused write.
- **Causes are validated, not just typed.** A single `TaskTransitionMatrix` lists every legal
  `(from, to, cause)`. `applyStatus` REFUSES an illegal combination: it logs an error and returns
  false, so a wrong cause fails visibly instead of silently steering watches. Free-form text is
  display context only. Watch matching reads `cause`, never prose.
  - Cause cases: `.startClaimed`, `.workerStarted`, `.spawnFailed`, `.submittedForValidation`,
    `.validationPassed(validationWasRun:)`, `.validationFailedNoProgress`, `.validationEscalated`,
    `.rejectionsReturned`, `.userPaused`, `.userStopped`, `.userAccepted`, `.userFailed`,
    `.userRevalidated`, `.userSentBack`, `.capacityShed`, `.scheduledAction(TaskActionKind)`,
    `.scheduledTimeReached`, `.helpRequested`, `.helpProvided`, `.workerSelfTerminated`,
    `.orphanRecovered`, `.smithSetStatus`, `.resetForRun`, `.reopenedForRun`,
    `.validationBlocked`, `.validationReleased`, `.templateLauncherNormalized`,
    `.coldBootRecovery(ColdBootRunningRecovery)`, `.coldBootSpawnAbandoned`,
    `.sessionShutdown`, `.sessionDeletion`.
- **The effect outbox lives on the task, in the same snapshot as the status.** In the same actor
  step as the write, each subscriber that cares appends a `TaskEffectRecord` to
  `AgentTask.pendingEffects`:
  - **Id:** deterministic, `taskID|statusRevision|subscriber`.
  - **Kind:** Smith briefing, or watch firing.
  - **State:** held, then released, then submitted, then settled.

  Status and effect become durable in one write, or not at all.
- **Release after ordered side effects.** A transition whose effects depend on later facts is
  written with `.deferredRelease`, which returns a `TransitionReleaseTicket`. The caller releases
  the ticket after its side effects finish:
  - the completion banner, teardown and summary;
  - the failure's explanatory update;
  - worker assignment and briefing;
  - the submission banner.

  Every other write releases immediately. An unreleased ticket is a code bug. After 30 s it is
  logged at `.error` and released, which is visible rather than silent loss (Decision R2). At cold
  boot, held effects of a task that is no longer mid-transition are released during reconciliation.
- **Nothing is submitted before it is durable.** Persistence becomes awaitable and truthful:
  - `SerialPersistenceWriter` gains a **durable** watermark, advanced only by a successful write,
    alongside the drained one;
  - `persistTasks` exposes `awaitDurable(revision:) -> Bool`;
  - the broker's persistence errors surface instead of being swallowed.

  A released effect is handed to the consumer only after its task's revision is durable.
- **One serialized consumer.** `TaskEffectConsumer` is runtime-owned, one per session. It drains
  released, durable effects in FIFO order, submits them to the broker, and writes settlement back
  through the store.
  - Store callbacks only ENQUEUE, synchronously. Nothing awaits the broker from inside the writer,
    so the store never suspends mid-transition and cannot reenter.
  - Subscriptions carry tokens with replace semantics, so a runtime restart cannot pile up
    duplicate callbacks.
  - `onTaskTerminated` becomes a derived subscriber, but only after the consumer is proven. Until
    then the old hook stays alongside it (Phase 2).
- **Lifecycle events are separate.** `TaskLifecycleEvent` is emitted by the disposition writers:
  archived, softDeleted, restored, permanentlyDeleted. On delete or archive the runtime:
  - cancels the task's wakes (fixing the permanent-delete wake leak);
  - cancels its unsettled effects;
  - finds dependents holding on it and surfaces the dangling hold.
- **Cold boot runs through the store.** `ColdBootRunningRecovery` and the other boot repairs become
  `TaskStore.reconcileAfterLaunch()`. It runs at session load on the store, with typed causes,
  recording effects in the outbox. The consumer delivers them when the runtime attaches, so
  reconciliation no longer depends on the user pressing Start. The loader's raw-array write is
  deleted.
- **Excluded by construction (no event):** `restore` / decode migrations and clone births.
  Template normalization emits, with `.templateLauncherNormalized`, and no subscriber reacts to it.

### Transition matrix (authoritative; the code's `TaskTransitionMatrix` must match)

| Cause | from → to | Watches | Smith briefed | Adjacent effect kept at call site |
|---|---|---|---|---|
| `.startClaimed` | pending/paused/interrupted → starting | — | — | — |
| `.workerStarted` | starting → running | **started** | as today | Brown briefing |
| `.spawnFailed` | starting → pending/failed | failed (if →failed) | as today | channel error |
| `.submittedForValidation` | running → validating | — | as today (none) | submission banner |
| `.validationPassed` | validating → completed | **completed** | as today | banner, teardown, summary |
| `.validationFailedNoProgress` | validating → failed | **failed** | as today | failure update |
| `.validationEscalated` | validating → awaitingReview | **needs review** | as today (none) | escalation row |
| `.rejectionsReturned` | validating → running | — | as today (none) | punch list to Brown |
| `.validationBlocked` / `.validationReleased` | ↔ awaitingReview / validating | — | as today (none) | — |
| `.helpRequested` / `.helpProvided` | → awaitingHelp / → running | needs help / — | as today | — |
| `.user*` (paused, stopped, accepted, failed, revalidated, sentBack) | per action | completed / failed / interrupted when reached | as today | `.userTaskAction` row |
| `.capacityShed` | running → paused | — | as today | capacity row |
| `.scheduledAction` / `.scheduledTimeReached` | per action / scheduled → pending | interrupted when reached | as today | — |
| `.workerSelfTerminated` / `.orphanRecovered` | running → interrupted/failed | interrupted / failed | as today (`.agentLifecycle` row) | — |
| `.smithSetStatus` | per `update_task` | per state reached | — (Smith did it) | — |
| `.resetForRun` / `.reopenedForRun` | failed/completed → pending | — | as today | — |
| `.coldBootRecovery` | running → validating/interrupted | interrupted (crash) | no (initial instruction covers launch) | recovery note |
| `.coldBootSpawnAbandoned` | starting → pending | — | no | — |
| `.sessionShutdown` / `.sessionDeletion` | running/in-progress → interrupted | **no** (Decision 9) | no | — |
| `.templateLauncherNormalized` | any → pending | — | no | — |

"As today" is pinned by the Phase 3 parity table. That table is exact wording per cause, and it is
written and committed BEFORE the move.

### B. The harness Smith briefing (built-in subscriber)

- `SmithTaskBriefing` maps `(to, cause)` to the note Smith receives, or nothing. It replaces the
  per-site notes for STATUS transitions only. Non-transition notices, such as the scheduled-run
  refusal and disposition notices, stay at their sites.
- **Delivery is effectively once** (Decision 8):
  - Notes go to the broker's durable Smith queue as `QueuedDelivery` values carrying their
    `NotificationID`, not bare text.
  - `AgentActor` records a delivery's id as consumed when the turn that received it COMPLETES. The
    consumed-id set is persisted per session, and the drain skips consumed ids.
  - A crash mid-turn redelivers, so the residual duplicate window is one interrupted Smith turn.
    This is documented, not hidden.

### C. Task watches

```swift
public struct TaskWatch: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var triggers: Set<TaskWatchTrigger>
    public var action: TaskWatchAction
    public var lifetime: TaskWatchLifetime            // .once / .everyTime
    public var state: TaskWatchState                  // .active / .cancelled(at:) / .consumed(at:)
    public var nextOccurrence: Int                    // monotonic; survives firing compaction
    public let createdBy: TaskAuthorship              // .user / .smith
    public let createdAt: Date
    public var recentFirings: [TaskWatchFiring]       // bounded audit (Decision R4)
}

public enum TaskWatchAction: Codable, Sendable, Equatable {
    case startTask(taskID: UUID)
    case macOSNotification
    case summarizeToUser
    case instructSmith(String)
}
```

- **Watchable states:** started, completed, failed, needs help, needs review, interrupted. They are
  mapped from `(to, cause)` in the matrix above and nowhere else. "Started" is `.workerStarted`
  only.
- **Firing:** inside `applyStatus`, each active matching watch takes `nextOccurrence`, increments
  it, and appends an effect record. A `.once` watch becomes `.consumed` in that same step, so it can
  never fire twice. The firing's states are pending, inFlight, delivered, refused(reason), and
  cancelled.
- **Cancel** marks the watch `.cancelled` and cancels its unsettled firings. It never deletes them,
  so the audit survives. Every handler re-reads the watch and firing state before acting, so a
  cancelled watch cannot act late.
- **Delivery** uses `TriggerSource.taskWatch(watchID:occurrence:)` (namespace `"taskwatch"`,
  permanent), keyed `watchID|occurrence`.
- **Typed settlement:**
  - The broker gains a settlement stream: notification id, outcome, and bounded reason.
  - `RecipientTarget` returns `.delivered` / `.refused(reason)` / `.retryable(reason)`, replacing
    `Bool`.
  - Retryable results retry at the next drain with backoff, up to a bound. After that the result is
    refused, with the last reason.
  - The consumer writes settlement back to the firing through the store.
- **Reconciliation at launch.** For every mismatch between firing state, outbox, and ledger:

  | Firing | Ledger | Result |
  |---|---|---|
  | pending/inFlight | settled | adopt the ledger outcome |
  | inFlight | absent | resubmit |
  | settled | — | drop the outbox entry |
  | older than ledger retention | — | the firing record is the dedup, never the ledger alone |

- **Holds live on the dependent task.** Setting up `startTask(B)` on A adds
  `TaskStartHold.awaitingTask(A, watchID)` to `B.startHolds`, which is a set, so several upstream
  tasks are allowed. At creation, self-links and cycles are rejected.
  - The hold is enforced at the **final claim gate**, before template cloning or `.starting`, keyed
    on a typed `TaskStartOrigin`:
    - `.explicitUser` (Play) overrides the hold;
    - `.watchSatisfied(watchID)` clears only its own hold;
    - `.scheduled`, `.smithTool`, `.autoAdvance`, `.launchResume` and `.capacityResume` are refused
      while any hold remains.
  - Every start input carries an origin. Cold-launch resume is routed through the gate.
  - Deleting or archiving A leaves B held and tells the user; the lifecycle event finds B through
    its holds. Cancelling the watch removes its hold.
- **`startTask(B)` action:** a watch-specific run path, not `prepareForRun`. B must be an ordinary
  task in the same session's store, in pending, paused or interrupted. Completed, failed, archived,
  missing, cross-session and template targets are refused visibly (`.taskWatchRefused`, `.error`,
  plus a Smith note), never reopened. At capacity it queues like a scheduled run.
- **Templates (Decision 10):** a watch on a template is a blueprint for the notifying actions only.
  `startTask` is not allowed on a template or targeting one. `instantiateTemplate` copies blueprints
  with fresh ids, empty firings and `nextOccurrence` 0. The preserved-history child and every other
  copy get none.
- **Cross-session unarchive:** targets resolve against the CURRENT store, never `task.sessionID`.
  A target that is not there is refused.
- **Retention (Decision R4):** keep the latest 20 settled firings per watch. `nextOccurrence` keeps
  the count. Unsettled firings are never compacted.

### D. Authoring, display, and the macOS bridge

- **Smith tools:** `watch_task` covers create and cancel, and is side-effecting. `list_task_watches`
  is read-only. Both use typed argument enums and `ToolArguments` for optional arguments. Every
  roster is updated:
  - `SmithBehavior`;
  - `autoApprovedToolsByRole`: pre-cleared like `schedule_task_action`, still routed through the
    Security chokepoint;
  - `ToolSafetyClassification`;
  - `BuiltInToolGroup`;
  - `smithTaskActionTools`: attribution resolves `watch_id` to the watched task, so cancel is billed
    correctly;
  - the prompt guidance next to `## Timers`.

  Registration and attribution tests are required.
- **Task Detail:** a "When this task…" section (list, add, cancel, holds shown as "Waiting on A").
  **Timers window:** a Watches tab. **`get_task_details`** renders watches and holds.
- **Transcript:** typed `.taskWatchFired` and `.taskWatchRefused` (`.error`) rows, stamped with
  top-level `taskID` and `sessionID` so the task pane shows them. They are kept out of Smith's
  channel whitelist, because Smith is told through the broker and a channel copy would duplicate it.
- **macOS bridge (app target):**
  - `TaskNotificationService` owns authorization and the `UNUserNotificationCenter` delegate,
    installed at launch.
  - It registers the `.external("macos")` push target before pending deliveries replay.
  - Authorization is checked AT DELIVERY. Denied is `.refused(reason)`, surfaced as a `.warning`.
  - Clicks set a typed `SharedAppState` task-detail request `(sessionID, taskID)`, which opens
    through the existing `OpenWindowAction` target.
  - The runtime receives authorization and registration as injected closures.

## Phases

Each phase: implement → recheck → build (xcode-mcp) → full `swift test` (+ MLX suite when memory is
touched) → commit → push.

0. ✅ **Cold-boot recovery fix** (`9056501`): one `ColdBootRunningRecovery` rule for the loader and
   the runtime.
1. ✅ **Truthful persistence.** Built: `TaskStore` is now the single writer of its session's
   `tasks.json` (`attachPersistence` / `retirePersistence` / `awaitDurable(through:)` /
   `persistDurablyNow`). The view model's mirror no longer writes, and a replaced store is retired
   after its in-flight write lands. Notification-store load and save failures reach the user, and a
   store that failed to load runs in memory only rather than overwriting the file.
   - Durable watermark in `SerialPersistenceWriter`.
   - Awaitable `awaitDurable(revision:)`.
   - Broker persistence errors surfaced.
   - A reflection-based `AgentTask` coding-key coverage guard.
   - Tests: a failed write does not advance durability; `flush` semantics.
2. ✅ **Transition funnel.** Built:
   - `TaskStore.applyStatus` / `changeStatus` are the only live status writers, with
     `TaskTransitionCause.permits` as the matrix. A refusal is logged as a fault and returns
     false, so it can be tested.
   - The CAS results are truthful, no-ops are suppressed, and `statusRevision` is persisted.
   - The store has one event observer. The runtime drains `TaskStoreEvent`s through one serialized
     consumer, which replaced `onTaskTerminated` and `onTaskMovedToInactive`.
   - `TaskLifecycleEvent` is emitted, which fixes the permanent-delete wake leak.
   - `reconcileAfterLaunch` runs at session load and at runtime start. The loader's raw-array write
     is gone.
   - `update_task` refuses statuses outside `UpdateTaskStatusPolicy`.
   - Stop All leaves a submitted-result task `.running`, so the next launch resumes its validation.
   - **Moved to Phase 3:** the effect outbox and release tickets. They ship with their first real
     subscriber, the Smith briefing, instead of as unused machinery.
   - Original scope:
   - `TaskStatusTransition`, `statusRevision`, the matrix and its validation, `applyStatus` at all
     call sites.
   - Truthful CAS returns, no-op suppression, the effect outbox, release tickets.
   - `TaskEffectConsumer` and subscription tokens, `TaskLifecycleEvent`, and
     `reconcileAfterLaunch` (the loader write deleted).
   - The old hooks are kept until the consumer is proven, then `onTaskTerminated` is derived.
   - Tests: every writer emits once; illegal causes are refused; no-ops and restore are silent;
     ordering; the release-ticket ordering pinned per call site; lifecycle events.
3. ✅ **Smith briefing.** Built:
   - **Effect outbox.** `TaskEffectRecord` lives on `AgentTask.pendingEffects` and is written in
     the same write as the status, with the id `taskID|statusRevision|subscriber`.
   - **Held effects.** A writer can hold effects with `updateStatusHoldingEffects`, returning a
     ticket for `releaseEffects`. A 30 s watchdog releases a forgotten ticket and logs an error;
     effects still held at launch are released.
   - **Delivery.** The runtime's consumer delivers only after `awaitDurable`, via the broker (new
     `TriggerSource.taskTransition` and `task_briefing` type), and retries after a failed write.
   - **Smith briefing notes.** The four `appendUserMessage` notes moved into `SmithTaskBriefing`:
     started, spawn failed, completed, and failed with no progress. They keep today's wording,
     except the user-Accept note, which no longer claims validation passed. Starts and failures
     during runtime start use their own causes (`workerStartedAtRuntimeStart`,
     `spawnFailedAtRuntimeStart`), because the new Smith's initial instruction already covers them.
   - **Effectively-once delivery.** The broker no longer acknowledges on the next drain. Smith
     acknowledges a delivery when its run loop next goes idle, meaning every turn the note triggered
     has finished. Lease generations stop a torn-down Smith's late acknowledgement from removing
     what its successor was handed. The broker's own outbox and ledger are the consumed record, so
     no separate consumed-id file was needed.
   - **Effects on archived tasks.** A task leaving the active store drops its undelivered effects.
   - Original scope:
   - The parity table, committed first.
   - The move into `SmithTaskBriefing`, delivered the same way as today.
   - Then durable delivery with `QueuedDelivery` ids and the consumed-id set.
   - Tests: exact note per cause; delivery after restart; no redelivery after a completed turn.
4. ✅ **Watch model and firing.** Built:
   - **Model.** `TaskWatch` has a trigger set, an action, a lifetime, state
     (active / cancelled / consumed), a monotonic `nextOccurrence`, and bounded `recentFirings`
     (20 settled kept). Firings are recorded in `changeStatus`, and a `.once` watch is consumed when
     its firing is created.
   - **Firing and cancelling.** `TaskWatchTrigger` is mapped from the typed transition. Shutdown
     and deletion never fire; a crash found at launch does. `addWatch` refuses empty triggers, empty
     instructions, self-starts, missing targets, templates, and loops. `cancelWatch` cancels
     unsettled firings and removes their undelivered effects.
   - **Templates.** Template blueprints are copied into each instance, and `startTask` is refused
     on a template. A preserved-history child carries no watches or effects.
   - **Broker and delivery.** A new `task_watch` type and `TriggerSource.taskWatch` exist, and
     `TaskWatchDelivery` composes the notification. The broker now settles typed: push targets
     answer delivered / refused / retryable, retryable backs off up to 5 attempts, and
     `setOnSettled` reports every final outcome with its reason.
   - **Startup and launch checks.** A startup guard verifies every `KnownNotificationType` has a
     handler. At launch, in-flight firings adopt the broker ledger's outcome.
   - **Actions and rows.** `startTask` goes through the durable scheduled-run queue, and a target
     that isn't runnable is refused, never reopened. Refusals post a `.taskWatchRefused` row with
     severity `.error` plus a Smith note; deliveries post a `.taskWatchFired` row. Both kinds are in
     the task-lifecycle group and carry a top-level `taskID`.
   - Original scope:
   - `TaskWatch` / holds on `AgentTask`, firing in `applyStatus`, `TriggerSource.taskWatch`.
   - Typed broker settlement, launch reconciliation, the startup handler guard.
   - Tests: firing atomic with status; `.once` consumed at firing; cancel mid-flight; compaction
     keeps the counter; every reconciliation row.
5. ✅ **Start origins and chaining.** Built:
   - **Origins.** Every call to `restartForNewTask` requires a `TaskStartOrigin`. Queued runs
     persist theirs, and old entries decode as `.scheduled`.
   - **Holds.** A hold is stored on its target (`AgentTask.startHolds`) and is added and removed
     together with its `startTask` watch.
   - **The gate.** `passesStartGate` runs before template cloning and before the claim.
     `.explicitUser` overrides a hold: it cancels the superseded watch and posts a note. Scheduled
     starts are refused and reported, Smith's are refused with a warning, and the automatic queues
     (auto-advance, launch resume, capacity resume) and launch auto-resume skip held tasks.
     `run_task` refuses a held task before `prepareForRun` can reset it.
   - **Multiple upstream tasks.** A task waiting on several starts only when the last hold
     releases.
   - **Stranded holds.** The user is warned when the task a hold waits on fails or completes
     without firing, or leaves the active list.
   - Original scope:
   - `TaskStartOrigin` on every start input, the final-gate hold check, cold-launch resume via the
     gate.
   - The `startTask` action and its refusal paths.
   - Tests: every origin against a held task; Play override; multi-dependency; cycles; delete of
     the upstream task.
6. ✅ **Other actions and the macOS bridge.** Built:
   - **Smith-bound actions.** `summarizeToUser` and `instructSmith` go through Smith's durable
     queue. They landed in Phase 4, and their tests are here.
   - **macOS notifications.** `TaskNotificationService` (app target, `@Observable`) is installed as
     the `UNUserNotificationCenter` delegate in `AgentSmithApp.init`, before launch completes.
     - It asks for permission the first time a notification is due and checks it on every delivery.
     - "Denied" becomes a refusal with the reason, shown in the transcript as `.taskWatchRefused`.
     - The notification's id is the identifier, so a redelivery replaces the banner.
     - Banners show even while the app is frontmost.
     - A click publishes a typed `TaskDetailTarget`; the first session scene consumes it and opens
       the window through `showOrOpenTaskDetail`.
   - **Wiring.** The runtime takes app bridges with `setExternalRecipientTarget`, which registers
     them on the broker as it is built.
   - Original scope: `instructSmith`, `summarizeToUser`,
   `TaskNotificationService`, click routing. Tests: permission denied at delivery.
7. ✅ **Authoring and UI.** Built:
   - **Smith tools.** `watch_task` (create / cancel; `task_id` is required for both, so cost is
     billed to the watched task) and the read-only `list_task_watches`. They are registered in
     `SmithBehavior`, the auto-approve table (still routed through the Security Agent),
     `ToolSafetyClassification`, the scheduling tool group, and `smithTaskActionTools`.
   - **Smith's prompt.** A "When a task changes state (watches)" section.
   - **`get_task_details`.** Renders a task's watches and holds.
   - **Task Detail.** A "When this task…" section with watches, a hold banner, Cancel, and an
     add-watch editor. Adding a macOS-notification watch asks for permission then.
   - **Timers window.** A Watches tab.
   - **Transcript rows.** Shipped in Phase 4.
   - Original scope: Tools with all rosters, Task Detail, the Timers tab, `get_task_details`,
   transcript kinds (+ the `ChannelMessageKind` guard table).
8. **Integrated recheck.** Failure injection: a crash at each point (after the write before durable,
   after durable before submit, after settle before write-back), persistence failure, permission
   denial, template, cross-session, capacity-deferred, every start origin. Then a live run: chain
   A→B, notifications, restart mid-chain. Update CLAUDE.md.

## Decisions

Resolved 2026-09-24:
1. **Smith briefing set:** exactly today's notified transitions. Widening it is a later decision.
2. **Briefing durability:** through the broker's durable Smith queue.
3. **Holding the chained task:** a typed hold on B; auto-advance cannot start it; Play overrides.
   Refined by Decision 7 into a hold set enforced at the final claim gate for every start origin.
4. **Cold-boot transitions:** watches fire for crash recovery. Smith's briefing skips them.
5. **Template watches:** blueprints. Narrowed by Decision 10.
6. **"Summarize to me":** Smith writes it with `message_user`.

Resolved 2026-09-25 (after review):
7. **Scope:** the full hardening: truthful persistence, `statusRevision`, the task-side outbox,
   the serialized consumer, typed settlement, `TaskStartOrigin`, and lifecycle events.
8. **Smith delivery:** effectively once through a durable consumed-id set. The residual window is
   one interrupted Smith turn.
9. **Session shutdown and deletion transitions do not fire watches.** A crash is still caught by the
   next launch's reconciliation.
10. **Templates:** no `startTask` on or targeting a template. Task-targeting watches are
    same-session ordinary tasks only. Notifying watches remain blueprints.
11. **The cold-boot recovery defect** was fixed on its own, ahead of the feature (`9056501`).

Implementation defaults chosen while revising (revisit if they surprise):
- R1. Illegal `(from, to, cause)` combinations are REFUSED, not merely logged.
- R2. The unreleased-ticket timeout is 30 s, and the ticket is then released with an `.error` log.
- R3. The retryable push-delivery bound is shared with the broker's existing backoff; after it the
  delivery is refused with the last reason.
- R4. Retention is the latest 20 settled firings per watch.

## Existing defects found during research (fixed in the phase noted)

- ✅ The loader's load-time demotion blinded the runtime's submitted-result recovery — `9056501`.
- `stopAll` interrupts a `.running` task even when its result was already submitted, which is the
  same loss at clean shutdown in a narrow window. Fixed in Phase 2, where the shutdown path applies
  `ColdBootRunningRecovery`.
- `SerialPersistenceWriter` reports drained as durable, and broker persistence errors are swallowed —
  Phase 1.
- The CAS status wrappers report success when the write was refused — Phase 2.
- `TaskStore.permanentlyDelete` of an active task fires no hook, orphaning its scheduled wakes —
  Phase 2 (`TaskLifecycleEvent`).
- Brown's acknowledgement writes running→running on every start — Phase 2 (suppressed as a no-op).
- Broker refusal reasons collapse to `.runtimeRefused`, and a push target's `false` is never
  retried — Phase 4.
- `NotificationBroker` has no startup guard that every first-party type has a handler — Phase 4.
- Cold-launch resume spawns workers outside `restartForNewTask` — Phase 5 (routed through the gate).
- `update_task` can set `.paused` on a running task without stopping its worker, and `request_help`
  can move a `.validating` task to `.awaitingHelp`. Reported, not changed: these are behavior
  decisions and out of scope.
