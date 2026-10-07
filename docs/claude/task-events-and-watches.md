# Task state events and task watches

_Split verbatim from `CLAUDE.md` (2026-10-07); `CLAUDE.md` keeps the binding summary and links here._

### Task state events and task watches (decided 2026-09-24, revised 2026-09-25 — see `docs/plans/TaskStateEventsPlan.md`)

**One event source, two kinds of subscriber.** Every live task status change goes through ONE `TaskStore` writer, `applyStatus`. It emits ONE typed `TaskStatusTransition`, carrying a per-task `statusRevision` and a required typed `TaskTransitionCause`, validated against a single `TaskTransitionMatrix`; an illegal combination is refused. Everything that reacts to a status change subscribes to it:

- the runtime's own reactions. The store has ONE `setEventObserver`, which yields `TaskStoreEvent`s (transitions AND `TaskLifecycleEvent`s, in write order) into a FIFO that one serialized runtime consumer drains (`installTaskEventConsumerIfNeeded` / `react(to:)`). There is no `onTaskTerminated` or `onTaskMovedToInactive` any more;
- the built-in Smith briefing (defined in code, always on);
- user-defined **task watches**: data on `AgentTask.watches` saying "when task X reaches state S, do A", where A is start another task, a macOS notification, Smith summarizes to the user, or instructions for Smith.

Don't add a status write that bypasses the writer, and don't add a second notification path for task state. Add a subscriber.

- **Crash consistency is structural.** A subscriber's effect is recorded on the task (`pendingEffects`, id `taskID|statusRevision|subscriber`) in the same snapshot as the status.
  - An effect is released only after the caller's ordered side effects (banner, teardown, briefing) and only once its revision is DURABLE.
  - One serialized per-session consumer submits effects to the broker. Store callbacks only enqueue; nothing awaits the broker inside the writer.
  - Persistence distinguishes "drained" from "durable". `TaskStore` is the SINGLE writer of its session's `tasks.json`. Every mutation goes through `didMutate()`, which schedules an in-order, coalesced write of the store's own state. The view model only mirrors tasks for display and never writes them. When one store replaces another (the standalone store at runtime start, or a prior run's store), the old one is `retirePersistence()`d first.
- **Disposition is not status.** Archive, delete and restore emit a separate `TaskLifecycleEvent`.
- **Cold-boot recovery** is one rule (`ColdBootRunningRecovery`) applied through the store at session load, independent of Start.
- **Holds live on the dependent task.** A chained task carries `startHolds` (a set), enforced at the final claim gate against a typed `TaskStartOrigin` on EVERY start input. Only the user's explicit Play overrides a hold.

Decisions:
- The Smith briefing (`SmithTaskBriefing`) keeps today's set of notified transitions. It is recorded as a durable effect in the status write and delivered through the broker's Smith queue, effectively once. Smith acknowledges a delivery (`acknowledgeDeliveries`, with the lease generation) only when its run loop next goes idle, so the only duplicate window is a crash mid-turn. Don't reintroduce `appendUserMessage` for a status note: it is dropped when no Smith is live.
- Watches fire for crash-recovery transitions but not for session shutdown or deletion.
- Template watches are blueprints for the notifying actions only. `startTask` is same-session, ordinary tasks only.
- A watch never reopens a completed task or resets a failed one.
- **An effect leaves its task only when the broker durably owns it.** `NotificationBroker.submit` returns that ownership: settled in the ledger, or durably queued. Keep the record until it is true; resubmitting is safe because ids dedup.
- **Never block the task-event consumer on a person.** It is one serialized task: anything it awaits delays every slot refill, briefing and chain start. `TaskNotificationService` therefore refuses (and asks for permission in the background) instead of awaiting the permission prompt.
- **Brown's first-turn acknowledgement never writes a status** (`TaskStore.acknowledgeTask`). Every start path sets `.running` before the briefing.
- **Cancelling a watch withdraws its handed-off deliveries before `cancelWatch` returns** (`TaskStore.setWatchWithdrawal`, installed by the runtime → `NotificationBroker.withdraw`, settled `.dropped(.withdrawn)`): anything still queued (even while its enqueue is being written) or waiting on a push retry is taken back, one mid-attempt is withdrawn when the attempt ends, and an id the broker has not seen yet is tombstoned so a submit still on its way dedups. A cancel before Start (no runtime yet) is caught at start by `reconcileInFlightWatchFirings`. A note Smith has already been handed, or a start already under way, cannot be recalled — that is the one residual.
- **Archive and delete cancel ALL of a task's wakes**, including `survivesTaskTermination` ones (`WakeScheduler.cancelAllWakes(forRemovedTask:)`). Only a terminal status spares those.
