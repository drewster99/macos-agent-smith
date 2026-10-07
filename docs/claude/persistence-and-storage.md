# Persistence and storage

_Split verbatim from `CLAUDE.md` (2026-10-07); `CLAUDE.md` keeps the binding summary and links here._

### Persistence boundaries

- Per-session: channel log, tasks, attachments, session-local state JSON. Path: `AppSupport/AgentSmith/sessions/<uuid>/`.
- Global: `memories/`, task summaries, `UsageRecord` history, model catalog (via SwiftLLMKit); per-role overrides in `role_model_config_overrides.json`, session list. Path: `AppSupport/AgentSmith/`.
- Keychain: provider API keys (service `com.agentsmith.SwiftLLMKit.com.nuclearcyborg.AgentSmith`, account = provider ID).

Every `UsageRecord` and `ChannelMessage` is stamped with `OrchestrationRuntime.currentSessionID` (a fresh UUID per `start()` call) so analytics can group by run without timestamp joins.

**Usage `taskID` attribution.** A `UsageRecord`'s `taskID` decides which task a turn's cost lands on in the spending dashboard. Brown → its bound task (`taskForAgent`). The validator → the task being judged. Smith → the task **its own tool calls acted on this turn**: `AgentActor.smithTurnTargetTaskID` scans `response.toolCalls` and returns the FIRST that targets a task (`smithTaskActionTools` by `task_id` arg, or `create_task`'s freshly-created id), else `nil`. `nil` is genuine **Orchestration** overhead — Smith planning/replying/deciding with no task-targeting call — shown as its own dashboard section above Tasks. This replaced an older `currentActiveTask()` heuristic that misattributed all of Smith's work to one task when several ran concurrently. Read-only Smith tools (`get_task_details`, `list_tasks`) deliberately don't count as "acting on" a task. Blast radius is analytics only — a wrong `taskID` mis-buckets cost, it never affects task execution. The spending dashboard live-refreshes off `SharedAppState.costBoardSnapshot` (the main-thread mirror of the `CostBoard` actor's snapshot).

**Retrieval scope differs by trigger, deliberately.** Auto-retrieval runs on **every** user message — each message is its own question and deserves its own memories. There is no once-per-conversation throttle and no flag for one; the `autoMemoryOncePerConversation` switch and its `conversationHasAutoMemoryContext` marker-scan were deleted rather than left parked at `false`. Per-message retrieval is affordable precisely because of the scoping below. A user message to Smith auto-retrieves **memories only** (`AgentActor.injectAutoMemoryContextIfNeeded`, `taskLimit: 0`); prior-task summaries are retrieved only when a task is **created or started** (`TaskContextRetrieval.attachRelevantContext`, from `CreateTaskTool`, `RunTaskTool`, and `OrchestrationRuntime.resolveStartTarget`). "What earlier work resembles this?" is a question about a task, not about a conversational turn — and asking it on every user message cost a second query embedding plus a full second corpus scan every time. `taskLimit: 0` is load-bearing: `searchAll` skips both the task embedding and the task scan when a pool's limit is zero, and `searchMemoriesInternal`/`searchTaskSummariesInternal` return early rather than scoring a corpus whose results get discarded. `searchAll` embeds each pool's instruction-prefixed query in ONE batched forward pass (`embedDistinct`) — the prefixes still differ per pool, so retrieval is unchanged; only the second sequential pass is gone.

### Storage model (verified 2026-07-29)

Agent Smith uses **JSON files** for all persistence — no SQLite or other database. Primary task storage is a per-session "giant JSON blob" (`tasks.json`), with archived/deleted tasks in a global `inactive_tasks.json`. All data lives under `~/Library/Application Support/AgentSmith/`, which **IS included in Time Machine backups** by default.

| Component | Absolute Path | Description |
|-----------|--------------|-------------|
| **Session List** | `/Users/andrew/Library/Application Support/AgentSmith/sessions.json` | Array of session metadata (ID, name, timestamps) |
| **Active Tasks (per session)** | `/Users/andrew/Library/Application Support/AgentSmith/sessions/{SESSION_ID}/tasks.json` | JSON array of active tasks for that session |
| **Inactive/Deleted Tasks** | `/Users/andrew/Library/Application Support/AgentSmith/inactive_tasks.json` | Global archive of completed/deleted tasks |
| **Task Summaries** | `/Users/andrew/Library/Application Support/AgentSmith/task_summaries.json` | Global task summary entries (for memory/retrieval) |
| **Task Evidence (per task)** | `/Users/andrew/Library/Application Support/AgentSmith/sessions/{SESSION_ID}/tasks/{TASK_ID}/evidence/` | Per-task evidence files (usually empty or contains task-specific outputs) |
| **Attachments (global)** | `/Users/andrew/Library/Application Support/AgentSmith/attachments/` | Shared attachment store with UUID-named files |
| **Session State** | `/Users/andrew/Library/Application Support/AgentSmith/sessions/{SESSION_ID}/state.json` | Session configuration (agent assignments, poll intervals, etc.) |
| **Channel Log** | `/Users/andrew/Library/Application Support/AgentSmith/sessions/{SESSION_ID}/channel_log.jsonl` | Newline-delimited JSON message log |
| **Memories** | `/Users/andrew/Library/Application Support/AgentSmith/memories.json` | Semantic memory entries with embeddings |
| **Usage Records** | `/Users/andrew/Library/Application Support/AgentSmith/usage_records.jsonl` | Token/cost tracking — append-only `UsageLogEntry` lines (see below); the legacy `usage_records.json` array is a migration backup, never written |
| **Role Model Overrides** | `/Users/andrew/Library/Application Support/AgentSmith/role_model_config_overrides.json` | Per-role model configuration overrides |
| **Validation Metrics** | `/Users/andrew/Library/Application Support/AgentSmith/validation_metrics.jsonl` | Append-only validation metrics log |
| **Orchestration Override** | `/Users/andrew/Library/Application Support/AgentSmith/orchestration_settings_override.json` | App-level orchestration settings override |
| **Downloaded Orchestration Defaults** | `/Users/andrew/Library/Application Support/AgentSmith/orchestration_defaults_downloaded.json` | Last downloaded orchestration defaults |
| **Backups** | `/Users/andrew/Library/Application Support/AgentSmith/backups/` | Automatic backups from migrations |

**Global vs per-session model:**

- **GLOBAL (shared across all sessions):** `sessions.json` (the list), `inactive_tasks.json`, `task_summaries.json`, `attachments/`, `memories.json`, `usage_records.jsonl`, `backups/`, `mcp_servers.json`, `model_overrides.json`, `role_model_config_overrides.json`, `validation_metrics.jsonl`, `orchestration_settings_override.json`, `orchestration_defaults_downloaded.json`
- **PER-SESSION (scoped to `sessions/{SESSION_ID}/`):** `tasks.json` (active tasks only), `tasks/{TASK_ID}/evidence/`, `state.json`, `channel_log.jsonl`, `timer_events.json`, `scheduled_wakes.json`, `pending_scheduled_run_queue.json`, `notification_ledger.json`, `notification_pending.json`, `pending_user_messages.json`

**Usage records are append-only JSONL (decided 2026-10-05).** `usage_records.jsonl` holds one `UsageLogEntry` per line: a bare `UsageRecord` object, or a row naming its `rowKind` (`UsageLogRowKind`; today only `task_backfill`). The whole-array `usage_records.json` it replaced had reached 151 MB and was re-encoded and rewritten every five seconds while agents ran, holding a second full copy of every record in memory for each encode. `UsageStore.backfillTaskID` — the one operation that changes stored records — appends a backfill ROW that load replays onto the records before it (`UsageLogEntry.replay`, shared with the live mutation via `UsageTaskBackfill.apply(to:)`); never rewrite earlier lines. Both JSONL logs append through `JSONLAppendWriter`, whose `enqueue` is synchronous on purpose: line order must equal call order, and two awaited hops to an actor are not ordered.

**Task summaries usage:** Task summaries (`task_summaries.json`) are used primarily for **semantic search / memory lookup** via `MemoryStore.searchAll()`. They are NOT used by `list_tasks` — that tool loads actual task objects from the JSON files (both per-session `tasks.json` and global `inactive_tasks.json`).

**Evidence scoping:** Evidence directories are scoped to their session (`sessions/{SESSION_ID}/tasks/{TASK_ID}/evidence/`). This is acceptable because attachments (the actual files) are stored globally in `attachments/`, so they remain accessible from any session. Evidence directories typically contain only task-specific outputs that are session-contextual.

**Search scope:**
- `search_memory` (semantic search): **GLOBAL** — searches all task summaries in `task_summaries.json`, excludes recently-deleted by default
- `list_tasks` with `disposition_filter: "active"` (default): **PER-SESSION** — only current session's active tasks
- `list_tasks` with `disposition_filter: "all"`: **GLOBAL** — active + archived + deleted

**Per-task cost AND tokens have ONE source: `CostBoard.taskUsage`,** mirrored to the main thread as `SharedAppState.taskUsage` and read through `AppViewModel.cachedTaskCost` / `cachedTaskTokens`. Don't reintroduce a per-view usage fetch. Every one of those surfaces used to scan the whole `UsageStore` on appear and cache the result, refreshed only when the task reached `.completed`/`.failed` — so an in-flight task displayed whatever had accrued at the instant its view first rendered, which is nothing for any task started while its view was already on screen, and a permanently stale figure for one that was mid-run at launch. Cost and tokens share one entry so they can never disagree about which records they describe. The rollup is a full grouped pass, not an incremental increment, because `UsageStore.backfillTaskID` re-attributes already-stored records (no insert to observe) and `append` enqueues delivery after mutating its array (so an incremental rebuild could double-count); it is coalesced to at most one pass per 750ms and re-runs on the 60s watcher as a convergence backstop. The pass FOLDS on `UsageStore`'s actor (`reduceRecords(into:_:)`), never over an `allRecords()` export: an exported array shares the store's buffer, so any append landing while a caller holds it copies the entire history (~150 MB at 65k records). No production code calls `allRecords()` (tests only). Readers fetch a filtered, independently owned array (`records(from:to:)`, `records(for:)`) and never keep records in long-lived state: the Spending Dashboard aggregates its range off-main (`DashboardAggregate.compute`, `@concurrent`) and keeps only the finished figures — it used to hold the whole array in `@State`, which copied the full history on every append while the window was open. `AppViewModel.estimatedCost(from:)` and `tokenTotals(from:)` survive for the PDF exporter only — it computes from its own fetch so one document describes one instant — and must keep applying the same formula as `CostBoard.costOf`.
