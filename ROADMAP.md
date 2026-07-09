# Agent Smith — Roadmap

## Planned

### Evaluator framework, acceptance validation, and the worker pool (agreed design, 2026-07-09)

Agreed with Drew in full; build order at the end. The unifying insight (Drew's): the
acceptance validator, the per-call tool approver, and the tool scoper are all the same
shape — a FUNCTION: fresh context, specific system prompt, structured input, constrained
output grammar, optional tool rounds, one parsed result. Build the function, then its
clients.

**Evaluator framework.**
- `EvaluatorDefinition` is DATA, hot-loaded from `AppSupport/AgentSmith/evaluators/*.json`
  (mcp_servers.json pattern), with shipped defaults bundled in Resources and copied on
  first launch (defaults.json pattern). Fields: name, description ("when to use" — the
  Smith-facing selection text), kind (`validator | approver | scoper | prepare`), system
  prompt, input template with named slots + declared required slots (validated at load;
  malformed files show as visible error entries), output grammar, model reference, tool
  allowlist, max turns, wall-clock timeout, max output tokens.
- One `EvaluationRunner` generalizing SecurityEvaluator's existing loop: render slots →
  LLM → allowlisted tool rounds → until the grammar parses → bounded retries. Two grammar
  kinds: first-line verdict (per-verdict reason requirements) and schema-validated JSON
  (used by the scoper and by prepare phases).
- Definition (data) vs payload (code): call sites build typed payloads; the runner
  auto-fills STANDARD SLOTS on any task-bound invocation (task id/title/description,
  recent updates, full step list incl. tombstones). Statefulness (WARN-retry tracking,
  recent-request history, failure breakers) stays at the call site — the function is pure.
- Model references are ROLE SLOTS ONLY in v1 (`validator`/`summarizer`/`smith`; a "smart
  validator" points at the smith slot). Explicit provider+model IDs are v2 (needs runtime
  provider construction). NO fallback chains: unconfigured → fail visible.
- Registry: user-owned. Smith SELECTS validators (kind=validator only; approver/scoper
  are system-reserved) via registry summaries embedded in tool descriptions at spawn
  (GhTool auth-status precedent) plus a list_validators tool. Consent gates CAPABILITY,
  not existence: Smith freely authors INLINE (task-scoped) validators and may persist
  capped-capability definitions to the registry; anything wanting tools beyond the
  read-only quartet (file_read, directory_listing, grep, glob) or a non-default model
  goes through propose → user approval. Shipped validators get the quartet by default —
  evidence-gathering is the default posture. Elevated tools still route through the
  per-call security check at runtime.

**Acceptance validation (replaces Smith's review entirely).**
- `AcceptanceCriterion` array ON the task (source of truth): id, text, waivable, origin,
  validator = .registry(name) | .inline(definition). create_task gains
  acceptance_criteria + steps params; Smith gets set/update criteria tools (every change
  posts to channel + task record; mid-round edits apply next round). User can specify
  validation in the prompt and edit criteria/inline definitions in the task UI.
- State machine: task_complete → `.validating` (new Status case — decode shim landed
  first) → all ACCEPT/WAIVE → auto-complete, no Smith. Any REJECT → punch list delivered
  DIRECTLY to the worker (review_work-rejection delivery path), bounded loop (default 3),
  then escalate to `.awaitingReview` with active user notification. Criterion-less tasks
  run the shipped `default-acceptance` definition (Smith's old review, distilled) — Smith
  is out of the review business; review_work becomes the escalation-resolution tool
  (accept-with-override + reason, send-back, edit-criteria).
- Verdicts: ACCEPT / REJECT(reason) / WAIVE(reason, only when waivable) / ERROR (timeout,
  turn-cap, backend, unparseable — retry once, then park for escalation; never counted as
  REJECT). ACCEPT is STICKY per criterion within a task attempt (rounds re-validate only
  rejected/errored criteria; editing a criterion resets stickiness). Validators default
  to temperature 0. Re-validated criteria receive a previous_verdict slot so round 2
  converges ("you said X was missing; here it is").
- Validation is idempotent and restartable: inputs and results live on the task; partial
  reports are never persisted; `.validating` tasks re-enqueue from sticky state on cold
  boot or cancel. Reports store verdicts + reasons + bounded evidence summaries — never
  raw tool output (prompt-injection of secrets into persistence, and tasks.json bloat).
  The task PINS definition content-hashes at first use; edits apply to future tasks;
  reports snapshot what ran (full body for inline).
- Caps: max items per prepare (fail-visible truncation), max validator calls per task
  attempt, per-report parallelism (Settings), and a GLOBAL evaluator-concurrency
  semaphore so validation can't starve workers.

**Steps (worker todo list).**
- `steps` array on the task. Smith seeds initials at create_task; the worker owns them
  after: add/update/reword/complete/skip(reason)/remove(reason) — but "delete" is a
  TOMBSTONE (status .removed): hidden from the worker's active view and progress UI,
  always visible to validators. The record under the plan is append-only, so a worker
  can grow its obligations but never erase evidence (the ratchet). Step list rides in
  the standard slots. Soft cap like task updates.
- Dynamic validation: prepare (kind=prepare evaluator, tools + JSON-array grammar) over
  ANY source — the step list arrives via slots, world sources (files in a folder) via
  tools; each emitted item maps through the per-item validator as {{item}} alongside the
  standard slots. Deterministic non-LLM prepare is a later optimization.

**Worker pool (parallel track, disjoint code).**
- Workers are 1:1 with tasks (taskID on AgentHandle); Settings gains "max simultaneous
  tasks". Correctness first. M1 runtime core (capacity check replaces the single-Brown
  terminate policy; per-agent callbacks; task-scoped lookups) behind capacity=1. M2
  inspector/worker cards re-keyed by agent ID (incl. terminatedAgentArchive + processing
  state, currently role-keyed). M3 orchestration gates (run_task/create_task/drains/
  wakes capacity-aware; the awaiting-review block drops — validation owns completion),
  Smith prompt + digest + message_brown task addressing. M4 polish (interrupt policy at
  capacity, MCP concurrency verification, scoping off the serialized spawn path).
  Cross-task file conflicts and vLLM load are explicitly out of scope (user-managed).

**Migration order:** decode shims (✅ with this entry) → EvaluatorDefinition +
EvaluationRunner + registry (✅ `5ea2cae`) → validation state machine +
default-acceptance + steps (✅ landed 2026-07-09: `4c1b758` model,
`509a83e` coordinator — task_complete → `.validating`, sticky accepts, punch lists
direct to the worker, bounded rounds with reset-on-review_work-reject, cold-boot
re-enqueue, mid-round criterion additions run a follow-on round; agent surface —
`manage_steps` (worker, tombstone rules), `set_acceptance_criteria` +
`list_validators` (Smith), create_task criteria/steps seeding, get_task_details
shows criteria+verdicts+steps, both prompts rewritten around validation) →
dynamic prepare/map (✅ 2026-07-09: `AcceptanceCriterion.prepare` names a
prepare-kind evaluator; items map through the per-item validator via {{item}};
empty item list auto-accepts, >50 items is a fail-visible ERROR not a silent
truncation; items run sequentially inside the round's parallel wave) →
worker pool M1 (✅ `792c656`: taskID+sequence on AgentHandle, handles(role:)/
workerHandle(taskID:), same-task cycle + oldest-eviction capacity check behind
maxConcurrentWorkers=1, pool-correct setToolSecurity/overrides/context-save;
M2 inspector re-key, M3 orchestration gates, M4 polish remain) →
Security Agent onto the runner LAST (scoper first, per-call
approver only after soak) → worker pool milestones in parallel. The `/compact` command
pattern applies: manual validation doubles as the prompt-tuning harness for
default-acceptance before the automatic gate carries weight.

### Agent lifecycle: supervised generations (post-incident 2026-07-08) ✅

The 2026-07-08 incident (full forensic report in the session artifact "Agent Smith —
Zombie Agent Incident"): during interleaved restarts an entire agent generation escaped
the runtime's registries without being stopped, survived 35 minutes invisibly through an
LLM outage, then acted on a live user message — welding a verbatim bug-bounty prompt onto
a scheduled 9 PM reminder via `run_task`'s description amendment. A self-resurrecting
scheduled wake drove 31 full restart generations in 8 seconds on top of it. Git history
showed ≥13 prior commits patching instances of the same class (`4a11812` "Eliminate
zombie Browns", `c46e408`, `99ad32f`, …) without removing it.

Landed in two phases:

**Phase 0 — stabilizers** (`c450b2a`, `98eab6e`): clear-first teardown (snapshot registries
synchronously before the first await); liveness lease / zombie tripwire
(`ToolContext.isAgentCurrent` checked at every run-loop tick and post-LLM, self-stops
orphans); wake replay filter (fired wakes don't resurrect from a stale disk snapshot;
recurring wakes roll forward instead of dying); `run_task` never amends an
inferred-target task and once-scheduled tasks are excluded from inference; runtime-held
scoping circuit breaker (3 failures → 120 s open, both queue drains gated so an outage
can't cascade the pending queue to `.failed`); per-tool failure-streak breaker (warn 5,
idle 10 — catches loops the identical-call breaker misses).

**Phase 1 — supervised lifecycle**: `AgentSupervisor` (a runtime-confined struct,
deliberately NOT a second actor — cross-actor awaits would reintroduce the interleaving
disease) owns the single `AgentHandle` registry (agent + role + epoch + evaluator +
subscriptions as one value; half-registered agents unrepresentable) and generation
records (epoch + sessionID). Every lifecycle transition — `start`, `stopAll`,
`restartForNewTask`, tool-driven `spawnBrown` / `terminateAgent` / `terminateTaskAgents`
— serializes through one FIFO `lifecycleQueue` (public entry points enqueue; `perform*`
implementations call each other directly, never enqueue — see the deadlock rule on the
queue). Registration on a stopped runtime fails cleanly instead of minting an untracked
agent. `abort()` sets its flag outside the queue so in-flight transitions bail.

Deliberately deferred: converting agent run loops to structured-concurrency children
(the current `stop()` grace-timeout design exists precisely because awaiting a wedged
child is the hang it dodges); channel-side epoch gating (serialized starts removed the
cross-stamping race, and the lease blocks stale subscribers from acting). The
acceptance-validator feature (checklist criteria judged per-criterion with
ACCEPT/REJECT/WAIVE verdicts) is designed to follow the `SecurityEvaluator` pattern —
stateless evaluation calls, no run loop, no lifecycle surface — and is not blocked on
any of this.

**Phase 2 — long-lived Smith + worker cycling ✅.** `restartForNewTask` (name kept for
its many callers) now cycles the WORKER when Smith is alive: save the outgoing Brown's
context if its task is resumable, spawn/brief a fresh Brown, and inform Smith with one
appended turn. The full teardown+boot survives only as the cold path (no live Smith).
This removes the restart amnesia behind the incident's double-amendment and retires the
`captureLastUserMessage` hand-off on the warm path — Smith simply remembers. Context
management: `/clear` resets Smith to system prompt + a task-state orientation rebuilt
from the task store; `/compact` (manual) and task-boundary auto-compaction (>50
messages, from the task-terminated hook) summarize via the Summarizer's provider and
splice to [system + summary + recent turns]. Ctrl-L remains display-only. Notices carry
the `context_management` kind, dropped by both agent filters. Semantics change:
`currentSessionID` now spans many tasks within one Smith generation (UsageRecords still
carry per-call taskIDs). Deferred refinement: provenance-tagged surgical episode
splicing (per-turn origin tags + homogeneous drain injections + a conservative
drop-only-what's-attributable rule) if summarizer-based compaction proves lossy; and a
staleness policy for past-due scheduled tasks. Smith still cold-boots across app
relaunches by choice — no context persistence.

Known-accepted behaviors and smaller follow-ups (from the third review pass):

- **Restart coalescing.** Queued restarts run strictly FIFO; N stacked restarts churn
  through N full stop/start cycles (each with MCP settle + scoping) before the last
  wins. Correct but wasteful under burst — a queue-level "drop superseded restarts"
  optimization is available when it matters.
- **Stop latency behind an in-flight transition — FIXED** after all three independent
  reviews converged on it: `stopAll()` now raises a `stopRequested` flag outside the
  queue (mirroring `aborted`) and calls `lifecycleQueue.cancelCurrent()`, which
  cooperatively cancels the running transition's slow awaits (the scoping LLM call and
  its backoff sleeps are cancellation-aware). Teardowns ignore cancellation by
  construction.
- **Per-Brown archive growth.** `archivedEvaluationRecords` accumulates one entry per
  terminated Brown for the app session (each capped at 50 records). Pre-existing;
  prune to last-N when it matters.
- **`evaluationHistory()` pull-path gap.** During the pre-registration scoping window
  the evaluator isn't yet on a handle, so the pull API misses it; the push callback
  (`onEvaluationRecorded`) still feeds the inspector live.
- **Worker-pool migration marker.** `AgentSupervisor.register` asserts the
  single-agent-per-role invariant (debug builds); a deliberate pool replaces
  `firstHandle(role:)` with `handles(role:)` and deletes the assertion.
- **Worker-pool blockers beyond the supervisor** (fresh-Opus review): the terminated-
  agent archive is keyed by ROLE (N Browns collapse to one slot; key by agent ID like
  `archivedEvaluationRecords`); processing/tool-execution UI state is role-keyed (two
  Browns overwrite each other's Thinking indicator); both queue drains gate on a global
  "any task running" check (a pool never drains past the first task); and each spawn
  pays a serial scoping LLM call inside the lifecycle queue — spawn needs to reserve
  its handle under the queue but scope outside it, commit-or-roll-back.
- **Per-tool failure-streak exemptions.** `bash` is exempt (its non-zero exits are the
  callee's semantics — failing tests, `grep -q` — not tool malfunction). If other
  exit-status-shaped tools are added, add them to
  `AgentActor.toolFailureStreakExemptTools`.

### Attachments — v2 follow-ups

A cluster of deferred items from the v1 attachment work (committed in `a150dae`,
`081bcd7`, `3cf96d2`, `ed7316f`, `7256b22`, `fb44815`, `92e4513`):

**Briefing budget — time-aware, not just last-N count.** The current `collectTaskAttachments`
caps eagerly-loaded image bytes to the last 3 updates' attachments. That's order-based —
if updates 1-2 happened today and updates 3-N are months old, recent attachments still
get culled in favor of the chronological tail. Switch to a hybrid that prefers (a)
recency by wall-clock time and (b) aggregate-bytes budget. `view_attachment(ids:)`
remains the on-demand fallback for older attachments.

**Per-task aggregate cap.** v1 ships per-file (default 25 MB) and per-message
(default 50 MB) caps; per-task aggregate (e.g. "no task may carry more than 200 MB
of attachments cumulatively across description / updates / result") was scoped out
because LLM cost is per-message. Add later if disk usage becomes a complaint.

**Settings caps live without restart.** Currently caps apply at session start;
mid-session changes need an agent restart. Wire the runtime to observe
`SharedAppState` mutations (Combine or `@Observable` change publisher) and push
them down. Settings UI text already documents the restart requirement.

**Format converters at ingestion.** SVG → PNG (qlmanage subprocess), DOCX/RTF/Pages
→ PDF (textutil + PDFKit chain), XLSX → CSV, HEIC → JPEG at ingestion (so storage
is JPEG, not HEIC — currently converted only at LLM-injection time via
ImageDownscaler). Each is a few-dozen-line function but needs subprocess management
and per-format error handling. v1 sidestepped via the mime-allowlist filter on
image injection (`ImageDownscaler.isProviderInjectable`); SVG specifically is still
useful via `file_read` (which maps `.svg` to text and returns the XML body).

**Folder drag-and-drop.** Reference-vs-bulk-ingest UX needs a real product call:
- Reference (default for ≥10 files or any single ≥5 MB): manifest-only, points at
  the original folder path. Brown reads via `bash` / `file_read`.
- Bulk-ingest (default for small folders): each file becomes its own `Attachment`
  with a synthetic group ID. Brown can iterate via `view_attachment(group:)`.
Settings should let the user override per-session ("reference / bulk / always ask").

**Per-model `ModelAttachmentCapabilities`.** Currently the image-injection filter is
a static set of provider-common mimes (jpg/png/gif/webp). A capability record per
model — in SwiftLLMKit's `ModelConfiguration` — would let us inject WebP only for
providers that accept it, fall back to JPEG for those that don't, declare PDF
support per provider for native document-block injection, etc. Required before we
can push image content through OpenAI Responses API or Gemini's
`functionResponse.parts` shape.

**Anthropic-style image content in tool results.** `view_attachment` currently uses
the universal user-message-injection path (works on every vision-capable provider).
For tools that produce images (`generate_image`, `take_screenshot`, `render_chart`),
returning the bytes directly in the tool result saves a round-trip when the
provider supports it (Anthropic, Gemini 3, OpenAI Responses, GLM-4.6V). Layer this
as an optimization on top of the JSON-handle pattern after `ModelAttachmentCapabilities`
lands. Note (2026-06-23): `web_fetch` now returns images via the staging path (mints an
`Attachment`, stages it into Brown's next turn) — it is a *weak* motivator for real
tool-result images (a fetched image is the rare case, and staging gives the same outcome
portably). The real motivators remain the tools that produce an image as their primary
output in tight loops — `take_screenshot` / `generate_image` / `render_chart`; build
tool-result image content when one of those lands, and `web_fetch` comes along for free.
The two paths are orthogonal — real support is additive, never a replacement for staging
(OpenAI Chat Completions `role:"tool"` messages stay text-only, so staging is always the
fallback). SwiftLLMKit blocker: `LLMMessage.Content.toolResult` is `content: String` today;
images ride the separate `images:` field, consumed only on `.text`/user turns.

**Security Agent evaluating `view_attachment` content.** `view_attachment` is currently
gated by Brown's normal Security Agent approval, but Security Agent evaluates only the tool args
(ids + detail), not the image bytes about to be loaded. A malicious image with
prompt injection in the visual or metadata payload could still reach Brown's
context. Security Agent doesn't have `view_attachment` in his tool list (text-only). Future
work: a Security Agent-side "viewing" path so the security agent can see the same bytes
before approving.

**OpenAI Responses API support in SwiftLLMKit.** Big task; mentioned earlier in
the attachment design discussion. Required before any OpenAI model can consume
images returned from a tool's `tool_result` (Chat Completions can't carry image
content in the `role: "tool"` message). Provides reasoning persistence for o-series
and GPT-5 as a side benefit.

**End-to-end attachment forwarding tests.** v1 ships unit tests for
`ImageDownscaler`, `AttachmentRegistry`, and `ViewAttachmentTool` in isolation. A
test that spins up `OrchestrationRuntime`, sends a user message with an image
attachment, watches Smith forward via `create_task(attachment_ids:)`, and verifies
Brown's seed briefing carries the image content — that's a real fixture investment
worth doing once the attachment surface stabilizes.

### Per-tool wall-clock timeouts ✅
Tool calls used to run with no enforced wall-clock cap. A pathological invocation — e.g. a `run_applescript` that walks every Contacts entry and shells out per phone — could pin the agent for minutes; in a parallel batch the slowest leg blocked every other result from being delivered to the LLM. Originally identified 2026-04-29 from the "brown stopped" diagnostic where a Contacts AppleScript ran 2m21s before returning.

**Implemented:** `AgentTool.executionTimeout` (default 120s) is now part of the protocol; `AgentActor.runToolWithTimeout` races `tool.execute(...)` against `Task.sleep(timeout)` in a `withThrowingTaskGroup`, cancels the tool on expiry, and synthesizes a `"Tool execution exceeded N s — cancelled"` failure result so the agent loop continues. Every tool-execution path (sequential `directExecute` and the parallel-batch leg) routes through it. Per-tool overrides: `bash` / `gh` 3700s (their `ProcessRunner` already enforces a user-supplied timeout — agent cap is the safety net); `glob` ~140s (covers its own `timeout` arg up to 120s); others inherit 120s. Plus a per-turn 10-minute stall watchdog logs an `os_log` error and posts a single channel warning so a stuck "Thinking" indicator is observable from `log stream`.

### File-discovery toolset: Spotlight-first `glob` + `directory_tree` + `directory_listing` ✅
`GlobTool` used to enumerate the entire subtree and flatten the whole pattern into one regex for the LLM to fish through — O(files) `stat`s + regex per call, slow on big trees, and an LLM that picked a pathological `path` like `~` or `/` could pin the agent indefinitely. There was also no cheap way for the LLM to *see* a directory's shape before choosing a scope.

**Implemented:** Three-tool rework. `glob` is now Spotlight-first (via `mdfind` through `ProcessRunner`, with `stat`-validation of every hit since the index can be stale) with a structural (pattern-directed) bounded walk as fallback — the walk's "frontier work-queue" only touches the dirs the pattern actually structures into, so `proj/src/**/*.swift` no longer descends `proj/other/`. Returns a JSON object: `search_root` + `matches` (relative paths) + `source` (`"spotlight_index"` | `"filesystem_walk"`) + `stop_reason` + `total_matched` + `more_available` + `resume_token` + `message`. Caller-settable `limit` (default 100, max 1000) and `timeout` (default 30, max 120). The walk fallback is **resumable across calls** via an opaque token backed by a live in-memory frontier (no rescan), so a needle-in-a-huge-unindexed-tree search isn't doomed by the timeout. Pathological roots (`/`, `/System`, `/usr`, …, `/Users`, `$HOME`/`~`) are refused with `stop_reason: too_broad`.

Two new tools land alongside: `directory_tree` (box-drawing dir-only tree to `max_depth` 3 by default with per-leaf annotations — depth-frontier / pruned / `(N files)`) and `directory_listing` (single-dir listing with `filter`/`sort`/`limit`/`offset` paging + `show_hidden_files`). All three share a `FilesystemSearchSupport` helper carrying the prune-list (VCS/build/dependency dirs + `.xcodeproj`/`.xcworkspace`/Photos/Music/TV libraries + the home-only opaque trees) and the root blocklist.

### .gitignore-aware `glob` — follow-up
The fixed prune-list already eats the big offenders (`node_modules`, `build`, `.build`, `DerivedData`, `Pods`, `.git`). For real `.gitignore` awareness, plan: add a `respect_gitignore: bool = true` arg. When the search base sits inside a git repo, find the root with `git -C <searchBase> rev-parse --show-toplevel` (non-zero exit ⇒ no-op), then run the match set through `git -C <repoRoot> check-ignore --stdin -z` and drop the ignored paths. Let *git* parse `.gitignore` / `.git/info/exclude` / `core.excludesFile` — don't reimplement it. Applies to both Spotlight and walk results. Graceful no-op when there's no repo or git isn't installed.

### Investigate `SessionManager.viewModel(for:)` load-state coupling
`SessionManager.viewModel(for:)` lazily creates an `AppViewModel` and fires `Task { await vm.loadPersistedState() }` without awaiting. Callers receive a VM that may not have loaded its disk state yet. Today this is fine because every consumer guards on `vm.hasLoadedPersistedState` — and the only consumer that matters (the UI) renders empty state until that flag flips. But the contract is fragile: a future caller assuming "I got a VM, I can read its tasks" will silently see empty arrays for one tick.

Investigate whether to (a) await the load inline (changes the call site to `async`, ripples through SwiftUI scene wiring), (b) return a richer "VM + load token" pair so callers can await readiness, or (c) leave it and add a precondition + comment. Identified during the 2026-04-27 concurrency review (item L2) — not a bug today, but worth pinning down before the codebase grows another consumer.

### Manage Sessions sheet (with deletion)
The previous "Close Session…" menu command was removed in 2026-04 because closing a window must NEVER mutate or delete the underlying session — Cmd-W is now strictly a UI operation, and there's no destructive command anywhere in the app. The Session menu lists all sessions and clicking one either focuses an existing window or opens a new one.

This means sessions accumulate forever until we add a deliberate management UI. Plan: a "Manage Sessions" sheet (probably in Settings or as a standalone window) that shows every session with last-used date, message count, task count, and disk size. Each row gets:
- Reveal in Finder (the session's data directory)
- Export (zip the session dir for archival)
- Delete (explicit confirmation, separate from any window action)

Deletion calls `PersistenceManager.deleteSessionData()` (which already exists, currently has no callers). Until this lands, sessions persist indefinitely on disk. `SessionManager.closeSession` is gone; do not reintroduce it as a window-close hook — the lesson from the previous design was that bundling deletion with window lifecycle made the destructive action too easy to hit.

Related: archived and recently-deleted **tasks** are still per-session (they live in the same `tasks.json` as active tasks, just with different `disposition`). When a session is eventually deleted via the Manage Sessions sheet, those buckets go with it. If we want a global trash that survives session deletion, that's a separate, larger refactor — promote `disposition: .recentlyDeleted` rows to a shared `recently_deleted_tasks.json` at the base level.

### Save API keys to Keychain ✅
API keys (e.g. Anthropic, OpenAI-compatible provider keys) are currently stored in plain text (UserDefaults or configuration files). Move all API key storage to the macOS Keychain using the Security framework (`SecItemAdd`/`SecItemCopyMatching`). This improves security by keeping secrets out of plist files and app defaults exports.

**Implemented:** As part of the SwiftLLMKit package rework. `KeychainService` wraps `SecItemAdd`/`SecItemUpdate`/`SecItemCopyMatching`/`SecItemDelete` with service scoped to `<keychainServicePrefix>.<appBundleID>` and account = provider ID. API keys are stored/retrieved when adding/editing providers and read at request preparation time. The old plaintext `apiKey` field in `LLMConfiguration` is still used at the provider-send level but populated from Keychain at runtime.

### Model configuration rework — SwiftLLMKit package ✅
Switching models previously required 5-6 manual steps. Created a reusable Swift package (`SwiftLLMKit`) with a three-tier architecture: Providers (connection details + Keychain API keys), Models (metadata entities enriched with LiteLLM data), and Model Configurations (provider + model + user settings). The package also prepares URLRequests with provider-appropriate auth and base parameters.

**Key components:**
- `LLMKitManager` (@Observable main class) — provider/config/model CRUD, refresh lifecycle, validation, persistence
- `KeychainService` — Keychain wrapper for API key storage
- `ModelFetchService` — queries Ollama/Anthropic/OpenAI APIs for model lists
- `ModelMetadataService` — LiteLLM metadata cache with YYYYMMDD refresh gate and conditional HTTP (ETag/Last-Modified)
- `StorageManager` — file-based persistence in Application Support
- Tab-based SettingsView (Providers, Configurations, Agent Assignments, Audio)
- `ConfigValidationView` — startup gate verifying all agent configs are valid
- `AnthropicProvider` updated to support extended thinking (`thinkingBudget`)
- `AppDefaults` schema v2 with providers, model configurations, and agent assignments

### Auto-start when all agents have valid configurations ✅
When all three agent roles have valid, assigned configurations on launch, skip the manual "Start" button and begin the orchestration runtime automatically. Currently the user must always click Start even when nothing has changed.

**Implemented:** `AppViewModel.autoStartEnabled` (defaults to `true`, persisted in UserDefaults). `MainView.onChange(of: viewModel.hasLoadedPersistedState)` checks: if nickname set, all configs valid, and autoStartEnabled → calls `viewModel.start()` automatically.

### Copy button for channel messages ✅
Text selection in the channel log is limited to one line at a time because each line is a separate SwiftUI `Text` view. Add a copy button (or context menu item) to each message row that copies the full message content to the clipboard, so users can easily grab multi-line output without fighting the selection model.

**Implemented:** Copy button exists on hover. The earlier hover-disappearance issue (button vanishing when the cursor moved toward it) is fixed.

### Completed tasks must always include a final result
When a task reaches `completed` status, its `result` field should contain a clear, meaningful summary of what was accomplished. Currently, completed tasks can end up with an empty or missing result — making it hard for the user (and Smith) to understand what was done without digging through the channel log. Enforce that `accept_work` requires a non-empty result, and ensure Brown's `task_complete` call always provides one.

### Task-scoped context and state for resumability
All context and state related to a given task needs to be tied to the task itself. Currently, when a task is interrupted (e.g. the app is stopped mid-task), the task status resets to pending but all associated context — Brown's conversation history, partial work, tool call results — is lost. When the task is later resumed, agents must start from scratch with no memory of prior progress.

**Goal:** An incomplete task should carry enough state that it can be resumed where it left off rather than restarting. This includes Brown's conversation history for the task, any intermediate results or artifacts, and the point at which work was interrupted.

### Smith fails to read task details when resuming interrupted tasks ✅
When the system restarts with tasks that were in-progress (now reset to pending), Smith notifies the user and asks how to proceed. When told to run the task, Smith asks clarifying questions that are already answered in the task's title and description — e.g. asking "what text should I append?" when the task description says `Append the text "monkies rock" to the end of the file`. Smith should use the `get_tasks` tool (or equivalent) to read the full task details before attempting to execute, rather than relying only on the summary from the startup notification.

**Implemented:** Added a prominent guideline in Smith's system prompt (SmithBehavior.swift) instructing Smith to always call `list_tasks` before acting on any task. The existing belt-and-suspenders instruction in OrchestrationRuntime.swift's initial message was retained.

### Preserve agent inspector data after termination
When an agent is terminated, its conversation history and LLM turn records are lost because the `AgentActor` is deallocated. Users should be able to review what happened in a terminated agent's session — especially useful for debugging why Brown failed or what Security Agent flagged.

**Approach:** Before removing an agent from the `agents` dictionary in `terminateAgent` and `handleAgentSelfTerminate`, snapshot the agent's `contextSnapshot()` and `turnsSnapshot()` into a separate archive keyed by agent ID. Expose this archive via `OrchestrationRuntime` so the UI inspector can display historical sessions alongside live ones.

### Power assertion to continue running with lid closed ✅
Use `IOPMAssertion` (or `ProcessInfo.processInfo.beginActivity`) to prevent the system from sleeping while agents are actively working. The behavior should be power-source-aware:

- **On battery**: Assert for up to **15 minutes** after the user closes the lid or goes idle, then release the assertion and allow sleep.
- **On AC power**: Assert for up to **1 hour** after lid close / idle, then release.

The assertion should only be held while there are active tasks or running agents. When all tasks complete or are cancelled, release the assertion immediately. Monitor power source changes via `IOPSNotificationCreateRunLoopSource` to adjust the timeout dynamically if the user plugs in or unplugs mid-task.

**Implemented:** Created `PowerAssertionManager` actor using `IOPMAssertionCreateWithName` with `kIOPMAssertionTypePreventSystemSleep`. Uses a single 15-minute inactivity timeout (no power source differentiation — simplified from original plan). Assertion is acquired on `start()`, reset on every LLM call or user message, and released when both the 15-minute timer fires AND no active tasks exist. Released immediately on `stopAll()`. Wired into `OrchestrationRuntime` via `sendUserMessage` and `notifyProcessingStateChange`.

### Show specific error messages from LLM model-fetch failures
When the model-list refresh button in Agent LLM Configuration gets an error response, the UI only shows a generic message like "Server returned HTTP 401. Check the endpoint URL and API key." The actual error body from the server contains a more specific message (e.g. `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`) but this detail is discarded. Parse the response body and surface the server's actual error message in the UI so users can diagnose issues without needing to check the Xcode console.

**Example log output from a 401:**
```
[AgentConfig] Model fetch: GET https://api.anthropic.com/v1/models
[AgentConfig]   Headers: x-api-key: (redacted), anthropic-version: 2023-06-01
[AgentConfig]   Response: HTTP 401 body={"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011CZGnZBBAcZALmp7nmj87a"}
```

### Task update history ✅
Store Brown's `task_update` messages as a `updates: [(Date, String)]` array on `AgentTask`. Currently these updates are only sent as ephemeral channel messages to Smith — they're lost on restart. Persisting them on the task gives a restarted Brown useful context about where the previous Brown left off.

**Implemented:** Brown's `task_update` calls are persisted on `AgentTask.updates` as `[(date: Date, message: String)]`. Displayed in task detail view.

### Remove implementation instructions from user-visible task descriptions
`CreateTaskTool` appends `"\n\nReport the detailed results to the user using task_complete."` to the task description at creation time (CreateTaskTool.swift:33). This implementation detail is persisted on the task and visible in the task list UI. The instruction should either be injected into Brown's initial message separately (not stored on the task), or moved into Brown's system prompt so it doesn't pollute user-facing task descriptions.

### Complete SwiftLLMKit migration — eliminate legacy LLMConfiguration ✅
The SwiftLLMKit package refactor is structurally complete but the runtime still uses the legacy `LLMConfiguration` struct in AgentSmithKit. `AppViewModel.resolvedLLMConfigs()` bridges between the two systems by converting SwiftLLMKit's `ModelConfiguration` into the old `LLMConfiguration` at startup. The actual LLM providers (`AnthropicProvider`, `OllamaProvider`, `OpenAICompatibleProvider`) consume only the legacy type.

**Goal:** Have the runtime providers consume SwiftLLMKit types directly (either `ModelConfiguration` + API key, or `PreparedRequest`), eliminating:
- The bridge code in `AppViewModel.resolvedLLMConfigs()`
- The legacy `LLMConfiguration` struct and its hardcoded defaults (`ollamaDefault`, `smithDefault`, `brownDefault`, `securityAgentDefault`)
- The redundant request-building logic in each provider (since `PreparedRequest` already handles auth headers and base body construction)

**Implemented:** All LLM provider implementations (`AnthropicProvider`, `GeminiProvider`, `OllamaProvider`, `OpenAICompatibleProvider`), conversation types (`LLMMessage`, `LLMResponse`, `LLMToolCall`, `LLMToolDefinition`), the `LLMProvider` protocol, and `LLMRequestLogger` moved into SwiftLLMKit. `LLMConfiguration` deleted entirely — providers now take `ModelConfiguration` + `ModelProvider` + a `@Sendable () -> String` closure that reads the API key from Keychain at point of use (no API key in any Codable struct). `ProviderType` renamed to `ProviderAPIType`. `LLMKitManager.makeProvider(for:)` factory resolves configuration → provider with keychain-based API key closure. `OrchestrationRuntime` takes pre-built providers at init. Default endpoint URLs moved to `ProviderAPIType.endpointPresets`. Remaining SwiftLLMKit improvements tracked in that package's own ROADMAP.

### Add `bash` tool for better environment availability ✅
The current `shell` tool may not provide full PATH and environment variable availability. Add a `bash` tool that executes commands via `/bin/bash -c <arguments>`, which sources the user's shell profile and provides access to the full PATH and environment values that the user would have in an interactive terminal session. This improves reliability for commands that depend on tools installed via Homebrew, nvm, pyenv, etc.

**Implemented:** `ShellTool` renamed to `BashTool` (`/bin/bash -c`). The old `shell` tool name removed. `BashTool` is now the sole command execution tool for Agent Brown.

### `get_task_details` tool ✅
Add a tool for both Smith and Brown to fetch full task details by ID, including title, description, commentary, progress updates, and summary.

**Implemented:** `GetTaskDetailsTool` available to both Smith and Brown via their respective behavior tool lists.

### Per-tool unit tests
Today only `GhTool.firstForbiddenSequence` has direct test coverage (`GhToolArgsFilterTests`). All 36 tools under `AgentSmithKit/Tools/` are otherwise uncovered. Tools are testable by design — `AgentTool` is a protocol, `execute()` returns a `ToolExecutionResult` value, and `ToolContext` is a struct of injectable closures — but three friction points need to be solved before per-tool tests scale:

1. **`ToolContext` has ~30 closure parameters.** Most have defaults, but `memoryStore`, `taskStore`, `channel`, `spawnBrown`, `terminateAgent`, `abort`, `agentRoleForID` are required, and three default to `fatalError(...)` (`setToolExecutionStatus`, `hasToolSucceeded`, `hasToolFailed`). Solution: a `TestToolContext.make(...)` factory that returns a sane default and lets each test override only what it touches.
2. **`MemoryStore` requires a real `SemanticSearchEngine`** which loads MLX weights. That's why `MemoryStoreIntegrationTests` is `--skip`'d in `swift test`. Most tools never call `memoryStore` — they just hold a reference. Solution: a fast-path `MemoryStore` constructor (or no-op engine adapter) that skips MLX so the bulk of tool tests can run in microseconds.
3. **Subprocess-running tools** (`BashTool`, `GhTool`, `RunAppleScriptTool`, `KillProcessTool`, `ListProcessesTool`) are best covered by extracting their pure logic (arg validation, output parsing) into testable helpers, the same template `GhToolArgsFilterTests` follows.

**Implementation waves:**
- **Wave 1 (no runtime deps):** `GlobTool`, `GrepTool`, `CurrentTimeTool`, `FileReadTool`, `FileWriteTool`, `FileEditTool`. Each takes a path + args and returns a string; tests use a per-test temp directory.
- **Wave 2 (TaskStore-only):** `CreateTaskTool`, `ListTasksTool`, `GetTaskDetailsTool`, `AmendTaskTool`, `UpdateTaskTool`, `ManageTaskDispositionTool`, `TaskUpdateTool`, `TaskCompleteTool`, `TaskAcknowledgedTool`. `TaskStore` is a regular actor — easy to construct and inspect.
- **Wave 3 (callback-driven):** `AbortTool`, `MessageUserTool`, `MessageBrownTool`, `ReplyToUserTool`, `ReviewWorkTool`, `TerminateAgentTool`, `RunTaskTool`, `ScheduleTaskActionTool`, `ScheduleWake`/`Cancel`/`Reschedule`/`List` tools. Each test asserts the right closure was invoked with the right args.
- **Wave 4 (subprocess pure-logic only):** `BashTool` arg validation, `RunAppleScriptTool` serialization, `KillProcessTool` pid validation, `ListProcessesTool` output parsing. End-to-end subprocess execution stays out of the unit suite.
- **Integration-only (excluded from `swift test`):** `SaveMemoryTool`, `SearchMemoryTool` — covered by the existing `MemoryStoreIntegrationTests` xcodebuild path.

### Web Search tool ⚠️ (shipped with a TEMPORARY backend)
Given a query and optional `allowed_domains` and `blocked_domains` arrays, perform a web search. Only return results from `allowed_domains` (if non-empty) and exclude results from `blocked_domains` (if non-empty).

**Implemented — TEMPORARY backend (2026-06-23):** `web_search` tool added to Brown (`WebSearchTool`). Returns ranked results; `allowed_domains`/`blocked_domains` filter on result host (equal-or-subdomain match, leading `www.` ignored); `max_results` caps output (default 10, max 20). `WebSearchResult` carries `title`/`url`/`snippet` (the universal fields) plus optional `age` (freshness), `score`, `extraSnippets`, and `faviconURL` — the common extras keyed APIs return — so a richer backend (Brave `page_age`/`extra_snippets`/`meta_url.favicon`, Tavily `published_date`/`score`) maps in with a direct field copy; the scrape backend just leaves them empty. The output formatter already surfaces `age` when present, so it lights up automatically on a backend swap. Classified open-world **but non-destructive** in `ToolSafetyClassification` (read-only network) — the first built-in that is open-world without being destructive — so Security Agent still gates it.

The search source sits behind a `WebSearchBackend` protocol (`WebSearchBackend.swift`). The shipped backend is `DuckDuckGoHTMLSearchBackend`, which **scrapes the DuckDuckGo HTML SERP** (`html.duckduckgo.com/html/`). This is explicitly **temporary** — it exists only so the rest of the harness can develop against a usable `web_search` with no API key. It was chosen after verifying (June 2026) that no major engine returns keyless *structured* results: DDG and Google both ignore `Accept: application/json` / `format=json` on their SERP and always return HTML; DDG's keyless JSON endpoint (`api.duckduckgo.com`) is the Instant Answer API (Wikipedia abstracts), not web search, and returns nothing for normal queries; Google's Custom Search JSON API is closed to new customers and fully discontinued 2027-01-01.

Why temporary matters: HTML scraping is brittle (breaks when DuckDuckGo reshuffles `result__a`/`result__snippet` markup), rate-limited, and ToS-gray.

**Replacement plan (re-evaluate week of 2026-06-30):** pick a permanent keyed JSON provider — leading candidates **Brave Search API** or **Tavily** (clean JSON, domain filters, recency, SLA) — implement it as another `WebSearchBackend`, store its key in Keychain (mirror `MCPSecretStore` / SwiftLLMKit `KeychainService`), and switch the default in `BrownBehavior.tools()`. `WebSearchTool` and Brown's wiring (and the domain-filter/cap logic, which is backend-agnostic) should not need to change. Google CSE is rejected (closed to new signups + sunsetting). The DDG-scrape backend can stay as a keyless fallback if desired.

### Global archived/deleted tasks + global attachments ✅
Archived and deleted tasks are now a single **global** set shared across all sessions/windows
(previously each session had its own archived/deleted buckets); **active tasks stay per-session**.
Attachments were made global at the same time so an archived/deleted task — which any window can now
display — resolves its files regardless of which session created them.

**Implemented (2026-06-30):**
- New `InactiveTaskStore` actor (one per process, owned by `SharedAppState`) holds the `.archived` +
  `.recentlyDeleted` tasks, persisted to a global `inactive_tasks.json`. Per-session `TaskStore` now
  holds only `.active` tasks and is injected with the global store; its disposition methods
  (`archive` / `softDelete` / `unarchive` / `undelete` / `permanentlyDelete` / `archiveStaleCompleted`)
  MOVE tasks across the boundary. New read-throughs `taskAnyDisposition(id:)` / `allInactiveTasks()`
  keep the agent tools working (`list_tasks` inactive/all, `get_task_details`, `manage_task_disposition`,
  and `run_task`'s reopen path) — Smith still sees archived+deleted, now globally. No `ToolContext`
  change (the global store is reached through `taskStore`), so every existing tool/test call site is
  untouched.
- **Restore lands in the current window's session** (a global task has to reactivate somewhere).
- UI sidebars read archived/deleted from `@Observable` mirror arrays on `SharedAppState`, so all
  windows update live; `TaskDetailWindow` / `TimersWindow` resolve via `AppViewModel.anyTask(id:)`.
  The expanded "Recently Deleted" header was renamed to "Deleted" to match the toggle button.
- **Attachments are global**: `PersistenceManager(sessionID:)` now points its attachments dir at the
  root `AgentSmith/attachments/` (files are UUID-named → no collisions); saved/loaded/resolved there
  for every session.
- **Semantic search**: deleted tasks are excluded from PUSHED auto-context (`create_task`'s
  relevant-prior-tasks + Smith's auto-memory inject) via a pushed `excludedTaskSummaryIDs` set in
  `MemoryStore`, but still returned by the EXPLICIT `search_memory` pull (`excludeDeletedTasks: false`).
  Permanent delete purges the summary (`removeTaskSummary`).

**One-time migrations (crash-safe, never delete data):**
- Tasks: read every session's `tasks.json`, union the non-active tasks, save the global file FIRST,
  then strip them from session files. A corrupt `inactive_tasks.json` is *quarantined* (renamed
  `inactive_tasks.corrupt-…`, never overwritten); a failed global save disables persistence for the
  launch so session files aren't stripped. The `AppViewModel` load split is an idempotent backstop
  that durably persists the global file before stripping any session file.
- Attachments: move every `sessions/<id>/attachments/*` into the global dir (move, never delete; a
  file already at the destination is left as-is), deduped + idempotent, UserDefaults-marked.

Verified (2026-06-30) on real data: 163 tasks (141 archived + 22 deleted) migrated to the global file,
all session files left active-only, 6 attachment files pooled, app launches clean. Covered by
`InactiveTaskStoreMoveTests` + `AttachmentMigrationTests`, plus a 3-reviewer (codex / agy / Claude)
pass whose data-loss findings (corrupt-file overwrite on flush, session strip before a durable global
save, `run_task`/PDF-export failing on auto-archived tasks) were fixed.

**Deferred:** attachments now live in one flat global dir with no GC when a task is permanently
deleted (orphaned files accumulate — harmless but unbounded). Add attachment GC if disk grows. The
cross-window wake-routing note elsewhere in this file is unaffected.

### Instant Answer tool ✅
`instant_answer` (`InstantAnswerTool`) — Brown tool wrapping DuckDuckGo's keyless Instant Answer JSON API (`api.duckduckgo.com`). Complements `web_search`: it returns a Wikipedia-style **entity** summary — abstract, infobox key facts, source URL, official site, related topics — for a recognized person/place/org/technology/concept, not a list of web pages.

**Implemented (2026-06-23):** `DuckDuckGoInstantAnswerService` (network + a pure, testable `parse` over the loosely-typed JSON via `JSONSerialization` — `RelatedTopics` mixes flat + grouped entries, `Infobox.content[].value` can be string or number). Classified open-world + non-destructive + read-only (same as `web_search`); Brown-only. Output formatter has three branches: entity summary, disambiguation ("ambiguous → use `web_search`"), and empty ("no instant answer → use `web_search`"). Unlike `web_search`, this is **not** temporary — it's a single official keyless JSON endpoint with no provider to swap.

Scope reality (verified June 2026): the JSON API returns useful data essentially only for recognized entities. Dictionary definitions and unit/currency conversions are **not** returned by the JSON API (they're JS-only "spice" endpoints), and open-ended queries return nothing — hence the tool description steers those to `web_search`.

### Web Fetch tool ✅
Given a URL and a prompt, fetch the URL content, convert to markdown, then run the prompt against the content to extract useful details. Useful for reading documentation, articles, and other web content.

**Implemented — hybrid mode (2026-06-23):** `web_fetch` (`WebFetchTool`), Brown-only. Fetches an http(s) URL via `URLSession` (injectable for tests), converts the page to readable markdown (`htmlToMarkdown`: drops script/style/head/comments, maps headings/links/list-items/block elements, strips remaining tags, decodes entities via the shared `DuckDuckGoHTMLSearchBackend.decodeEntities`, collapses whitespace). **Hybrid behavior:** if a `prompt` is supplied, the markdown is run through an extraction LLM and only the answer is returned (keeps large pages out of Brown's context); if `prompt` is omitted, the truncated markdown (cap 50k chars) is returned for Brown to read. Extraction reuses the **summarizer-role** model via `TaskSummarizer.extractWebContent(content:prompt:)`, wired through a new `ToolContext.extractWebContent` closure + `OrchestrationRuntime` (mirrors `mergeMemoryContent`); when no extraction model is wired it falls back to returning markdown. Classified open-world + non-destructive + read-only; Security Agent-gated. Output carries an untrusted-content warning. Tested: HTML→markdown conversion, both execute() modes + fallback, HTTP errors, URL validation, classification/wiring, a real Brown agent-loop invocation, and a gated live fetch.

**Non-text content (2026-06-23):** `web_fetch` now detects when the fetched URL is an image or PDF (Content-Type + magic-number sniff, with a NUL-byte binary heuristic for the ambiguous remainder; SVG routed to the text path) instead of lossy-decoding binary into garbage. An **image** is minted as an `Attachment` and staged into Brown's next turn via the universal user-message image path (`ToolContext.stageAttachmentsForNextTurn`) — Brown sees it on the following turn, no `view_attachment` round-trip. A **PDF** is saved as an `Attachment` and surfaced as a `file://` reference so Brown can `file_read` it (PDFKit text extraction). Any other binary (zip, octet-stream, audio/video/font) is **refused** with its content-type named, steering Brown to `bash`+`curl`. New plumbing: `AttachmentRegistry.ingestData(_:filename:mimeType:)` (mints from in-memory bytes; mirrors `ingestFile` minus the disk read) + `ToolContext.ingestAttachmentData` wired in `OrchestrationRuntime`. Chose staging over embedding the image in the `tool_result` block — see "Anthropic-style image content in tool results" for the why (portability; the two paths are orthogonal). Tested: pure classification (magic/declared/heuristic/filename derivation), execute paths for image-sniffed, image-by-Content-Type, PDF, image+prompt, binary refusal, and `ingestData` happy/guard paths.

**Hardening + structured output (2026-06-30):** `web_fetch` now returns a one-line JSON **envelope** (`success`/`kind`/`resolvedURL`/`status`/`contentType`/`charset`/`bytes`/`truncated`/`fileReference`/`note`) followed, when inline, by a **nonce-fenced** `<web_content>` block — the per-response nonce stops a fetched body that contains a literal `</web_content>` from breaking out of the fence. HTML still becomes markdown, but **JSON/XML/JS/plain text is returned verbatim** (no longer mangled by the HTML converter), with **charset-aware decoding** (BOM → Content-Type charset → HTML `<meta charset>` → UTF-8 → lossy) replacing the always-UTF-8 lossy decode. A new **`forceSaveToFile`** param writes any response's raw bytes to a file (returns only a `fileReference`); non-inlineable **binary now auto-saves to a file** instead of being refused. Security/robustness from the June review: an **SSRF redirect guard** (`EgressPolicy` — refuses 30x hops to loopback / link-local / RFC1918 / CGNAT / ULA / IPv4-mapped / metadata; direct requests stay Security Agent-gated), a **streamed byte cap** (no more buffering an unbounded/chunked body), and a **linear tag-strip + wall-clock conversion deadline** (kills the quadratic-regex hang the cooperative timeout couldn't preempt). Errors carry `success:false` + a machine-stable `errorKind`.

### Post-review hardening — June 2026 multi-agent code review ✅
A three-reviewer code review of `f0b4d4a..HEAD` produced a reconciled finding list; each item was independently re-verified against the code before action, then re-checked with a second model at commit time. Shipped fixes:

- **web_fetch** — SSRF redirect guard, streamed byte cap, linear/deadline-bounded HTML conversion, charset-aware decode, verbatim structured text, `forceSaveToFile`, and the JSON envelope (see "Web Fetch tool" above).
- **MCP editor save (M11)** — a failed orphaned-secret *cleanup* delete no longer blocks saving the server config (it left the Keychain and config inconsistent); cleanup failures are logged, write failures still block.
- **TaskSummarizer cancellation (M17)** — the three retry loops honor `Task.isCancelled` instead of retrying and posting a spurious "failed" message after an abort.
- **Memory re-embed migration (M15/M16)** — checkpoints progress (every 32 entries) and durably flushes the freshly-built store before clearing the migration flag, so an interrupted migration resumes instead of restarting; also surfaces a failed-entry count.
- **Prompt routing (M8)** — Brown is pointed at `web_fetch` for reading URLs (previously `bash curl`, and `web_fetch` appeared in zero prompts); `curl` retained for the GitHub API.
- **instant_answer URL validation (M7)** — echoed API URLs are validated as absolute http(s) before being shown to the agent.
- **Task-context cosine gate (M18)** — `taskInjectionCosineGate` raised 0.62 → 0.66 (above the false-positive figure, below gold), to be re-confirmed via `RetrievalEvalRunner`.

Investigated and found to be **false positives** (no change): an alleged `OrchestrationRuntime` self-scheduling restart loop, the MCP cancellation retry loop being "unbounded", and an `AttachmentRegistry.resolve` re-entrancy "lost update".

### MCP tool timeout — per-server / progress-aware (M10, follow-up)
The MCP bridged-tool execution timeout was raised to 4h so a legitimately long tool isn't chopped (calls are now cancellable via Stop/Pause). A wedged server with no progress signal can still park a worker for up to 4h, and the stall watchdog only *warns* at 10 min. Follow-up: make the cap per-server configurable and/or progress-aware (reset the deadline on MCP progress notifications), or escalate the watchdog to auto-abort after N warnings.

### Grep tool ✅
Ripgrep-based content search tool for Agent Brown. Parameters: `pattern` (required, regex), `path` (required), `output_mode` (enum: files_with_matches / content), `glob` (file filter).

**Implemented:** Native Swift implementation using `NSRegularExpression` for content search and `GlobTool.globToRegex` for file filtering. Supports `files_with_matches` (default) and `content` output modes. Skips hidden files, binary files, files >1MB. Limits: 500 matching files, 1000 content lines. Glob patterns without `/` match filename only (ripgrep convention).

### Multimodal file_read — image support
`file_read` currently returns metadata only for image files (filename, dimensions, size). To support actual image reading, the tool result format needs to carry multimodal content (base64 image data as a content part) instead of plain text strings. This requires changes to how `AgentActor` passes tool results to the LLM — currently all tool results are `String`, but multimodal results need structured content blocks. Once supported, the 250K character cap should be raised or replaced with a byte-based limit appropriate for images (2-5MB).

### Task-scoped working directory for relative paths
Currently all tools (except `file_read`) require absolute paths. Relative paths would save significant tokens — paths like `~/projects/agent-smith/AgentSmithPackage/Sources/AgentSmithKit/Tools/GrepTool.swift` are 100+ characters each, repeated across many tool calls per task. The approach: `CreateTaskTool` accepts an optional `working_directory` parameter. When set, all tools resolve relative paths against it. The working directory is immutable for the task's lifetime (no races). Tool output (glob/grep results) returns relative paths when a working directory is set, further reducing token usage. Full design documented in project memory.

### Manually start pending tasks from the UI ✅
Add a "Start" or "Run" button to pending tasks, accessible from both the task list (e.g., a play icon on the task row) and the task detail window. Clicking it should call `run_task` via the orchestration runtime, equivalent to Smith picking up the task. This lets the user manually kick off queued work without waiting for Smith or typing a command — especially useful when `autoRunNextTask` is disabled.

**Implemented:** `AppViewModel.startTask(_:)` drives `OrchestrationRuntime.restartForNewTask(taskID:)` — the same path the `run_task` tool uses. Eligible statuses are the runnable set (`.pending` / `.paused` / `.interrupted`); the verb is status-aware ("Resume" for paused/interrupted, "Run" otherwise — `runActionTitle(for:)` in `TaskListView.swift`). It refuses (surfacing `taskActionError` via an alert) when another task is `.running` or `.awaitingReview`, mirroring `RunTaskTool`'s guardrails. Surfaces: inline `play.fill` button on the sidebar row (alongside the existing running pause/stop inline controls), a context-menu item in the pending/paused/interrupted branch (`.scheduled` was split into its own case, unchanged — it already has a wake-driven "run now"), and a prominent Run/Resume button in `TaskDetailWindow`'s header (the window's `viewModel` became `@Bindable` for the alert binding). `.scheduled` tasks are intentionally excluded — `run_task` excludes them too.

### Streamline model configuration UI
The current Settings flow requires managing configurations as separate objects, then assigning them to agent roles across two different tabs. Redesign the UI to feel agent-centric — each agent/role has its own settings panel showing provider, model, temperature, max tokens, etc. directly. The underlying `ModelConfiguration` concept stays in the data model for reuse and persistence, but the UI abstracts it away so it feels like "adjusting Smith's settings" rather than "creating a configuration and assigning it." Goal: the user should essentially never have to manually create a model configuration.

### Built-in providers list with fixed identifiers
The Providers tab currently treats every provider — including well-known ones like OpenAI, Anthropic, Gemini, and Ollama — as user-created records that can be renamed, edited, or deleted. This is fragile: a provider's identity (e.g. "OpenAI" → OpenAI's API) should be a constant, not something the user can rename or accidentally delete.

**Redesign:** Show all known/built-in providers as a fixed, scrollable list at the top of the Providers screen. Each built-in row:
- Has a stable, hardcoded identifier (so "OpenAI" always means OpenAI regardless of user actions)
- Has a fixed, non-editable display name and provider type
- Exposes only an API key/token field and a Save button
- Cannot be removed

Below the built-in list, keep a manual "Add provider" affordance for custom OpenAI-compatible endpoints, self-hosted models, etc. Custom providers retain the existing edit/delete behavior.

This pairs with the agent-centric config rework above: with stable provider identities, agent role assignments can reference providers by their fixed ID rather than by user-created configuration objects.

### list_tasks search and semantic search
Add search capabilities to the `list_tasks` tool so Brown can find relevant tasks without retrieving the entire list. Support a `query` parameter for keyword matching against task titles and descriptions, and optionally a semantic search mode that uses the embedding service to find tasks by meaning rather than exact text. This would reduce token usage (no need to dump all tasks) and improve Brown's ability to find related prior work.

### Improve prior-task relevance in new task context
The current system injects prior task summaries into new tasks via semantic search against the task description. In practice this produces a fair number of irrelevant additions — the embedding similarity threshold is too loose, or the search query (the new task description) is too broad. Investigate: tighten the similarity threshold, limit to tasks from the same session or recent time window, weight completed tasks higher than abandoned ones, or let Smith curate which prior tasks to attach rather than auto-injecting. Goal: every prior task included in a new task's context should be genuinely useful, not noise.

### Auto-run next pending task ✅
Add a setting (persisted in UserDefaults) that controls whether the system automatically picks up the next pending task when the current one completes. When enabled, Smith or the orchestration runtime should detect task completion and immediately assign the next queued task to Brown without requiring user interaction. When disabled, the system idles after task completion and waits for the user. The setting should be exposed in the UI alongside the existing auto-start toggle.

**Implemented:** `AppViewModel.autoRunNextTask` (defaults to `true`, persisted in UserDefaults). Passed to `OrchestrationRuntime` at init, which forwards it to `SmithBehavior.systemPrompt(autoAdvanceEnabled:)` — the auto-advance instructions in Steps 6, the Key Constraints table, and the `create_task` docs are all conditional on the setting. `ReviewWorkTool` also includes advance guidance in its tool result when enabled. UI toggle added in Settings → Account tab under a "Behavior" section. Takes effect on next start (system prompt is generated at agent creation time).

### Skills — reusable prompt templates with arguments and embedded tool calls

Skills are saved, reusable prompt templates that generate fully-formed user messages to send to Smith. A skill encapsulates a repeatable workflow — instead of typing out a detailed prompt every time, the user defines the skill once (with variables for the parts that change) and invokes it with arguments.

#### Data model

A skill has the following fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | UUID | auto | Unique identifier |
| `name` | String | yes | Short name used for `/skill` invocation (no spaces; e.g. `code-review`, `summarize`) |
| `displayName` | String | yes | Human-readable name shown in the sidebar and detail view |
| `description` | String | yes | What the skill does, shown in the sidebar and detail view |
| `prompt` | String | yes | The prompt template. Supports variable substitutions (`{{var}}`) and embedded tool calls (`{{file_read:path}}`, `{{bash:command}}`). See "Prompt template syntax" below. |
| `arguments` | [SkillArgument] | no | Ordered list of arguments (required and optional). See "Arguments" below. |
| `createdAt` | Date | auto | Creation timestamp |
| `updatedAt` | Date | auto | Last modification timestamp |

**Arguments** (`SkillArgument`):

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | String | yes | Argument name, used in `{{name}}` substitutions and as the keyword in CLI invocation |
| `description` | String | yes | Shown in the run dialog and help text |
| `required` | Bool | yes | Whether the argument must be provided before the skill can run |
| `defaultValue` | String? | no | Default value if not provided. Only meaningful for optional arguments. |

#### Prompt template syntax

The prompt template is the core of a skill. It's a string that gets processed through two stages before being sent to Smith as a user message:

**Stage 1 — Variable substitution.** All occurrences of `{{variable_name}}` are replaced with the corresponding argument value. Substitution happens everywhere in the template, including inside `file_read` paths and `bash` commands (so `{{file_read:{{project_root}}/README.md}}` works — the inner `{{project_root}}` is substituted first, then the `file_read` is executed).

**Stage 2 — Embedded tool calls.** After variable substitution, the template is scanned for embedded tool calls:

- `{{file_read:/path/to/file}}` — Reads the file at the given path and replaces the token with the file's contents. Uses the same `FileReadTool` logic (respects blocked paths, size limits, etc.).
- `{{bash:command here}}` — Executes the command via `/bin/bash -c` and replaces the token with stdout. Uses the same `BashTool` logic (timeout, environment, etc.).

**Tool call failure semantics:** If any embedded tool call fails (file not found, command exits non-zero, blocked path, timeout, etc.), the entire skill invocation fails. The user sees an error message explaining which tool call failed and why. The prompt is NOT sent to Smith. This is intentional — a skill whose context-gathering steps fail should not produce a half-baked prompt.

**Escaping:** The double-brace `{{` / `}}` delimiters are chosen because single braces are common in code, JSON, and natural language. If the user needs literal `{{` in the output, they can use `\{{` to escape it. A trailing `\}}` escape is also supported. The backslash is consumed during processing.

**Processing order summary:**
1. Replace `\{{` → placeholder, `\}}` → placeholder
2. Substitute all `{{variable_name}}` with argument values
3. Execute all `{{file_read:...}}` and `{{bash:...}}`, replace with output
4. Restore escaped-brace placeholders to literal `{{` / `}}`
5. Result is the final prompt string sent to Smith as a user message

#### Invocation

Skills can be invoked three ways:

**1. `/skill` command in the message input field:**

- `/skill code-review` — If the skill has no required arguments (or all have defaults), runs immediately. If it has unfilled required arguments, opens the run dialog.
- `/skill code-review repo_url=https://github.com/foo/bar issue_number=42` — Provides arguments as keyword=value pairs. Positional arguments (without `=`) are assigned to required arguments in order. If all required arguments are satisfied, runs immediately; otherwise opens the run dialog with the provided values pre-filled.
- `/skill` with no name — Opens the skill sidebar/panel if not already visible.

**2. Run button on the skill sidebar:** Each skill in the sidebar has a small play button. Clicking it either runs immediately (no required args) or opens the run dialog.

**3. Run button on the skill detail view:** Same behavior as the sidebar run button.

**When a skill runs:** The generated prompt is sent to Smith as a user message (exactly as if the user typed it). Smith then creates a task, assigns Brown, etc. through the normal workflow. The skill system is purely a prompt-generation convenience — it does not bypass Smith or create tasks directly.

#### UI — Skill sidebar

The left panel currently has a task list. Add a segmented control or tab bar at the top to switch between "Tasks" and "Skills" views.

**Skill sidebar contents:**
- List of all skills, sorted by name
- Each row shows: skill `displayName`, a brief description (1 line, truncated), and a play (▶) button on the right
- Clicking a skill row opens the **skill detail view** (not the run dialog — the user can review before running)
- Clicking the play button opens the **run dialog** directly (or runs immediately if no required args)
- A "+" button at the top to create a new skill

#### UI — Skill detail view

Shown when the user clicks a skill in the sidebar. Could be a sheet, a panel, or an inline expansion — design to match the existing task detail view style.

**Contents:**
- Skill `displayName` and `name` (the `/skill` invocable name)
- Description (full text)
- Arguments list: for each argument, show name, description, required/optional badge, default value if any
- Prompt template preview: the raw template with `{{variable}}` markers visible, syntax-highlighted or at least in a monospaced font
- **Run** button — opens the run dialog (or runs immediately if no args needed)
- **Edit** button — opens the skill editor (see below)
- **Delete** button — with confirmation

#### UI — Run dialog (also serves as the "fill arguments" dialog)

A modal sheet that appears when a skill is invoked with unfilled required arguments. Also appears when the user clicks Run from the detail view (if there are arguments to fill).

**Contents:**
- Skill `displayName` at the top
- For each argument: a labeled text field, pre-filled with any provided value or the default value. Required arguments are visually marked (e.g., asterisk or red border if empty).
- A **prompt preview** section at the bottom showing the generated prompt after substitution (updated live as the user types). Embedded tool calls show as `[file_read: /path/...]` or `[bash: command...]` placeholders in the preview (they don't execute until the user confirms).
- **Cancel** button — dismisses without running
- **Run** button — enabled only when all required arguments are filled. Executes the template processing pipeline (substitution → tool calls → send to Smith). Shows a spinner during tool call execution. On failure, shows the error inline without dismissing.

#### UI — Skill editor

For creating and editing skills. A sheet or panel with fields for:

- `name` (the `/skill` invocable name) — validated: no spaces, no duplicates
- `displayName`
- `description` — multi-line text field
- `prompt` — large multi-line text editor (similar to the expanded editor for the message input). Should be tall enough to comfortably edit multi-paragraph prompts.
- **Arguments section:** a list of arguments with add/remove/reorder. Each argument has fields for `name`, `description`, `required` toggle, and `defaultValue` text field (shown only when not required, or always shown).
- **Save** and **Cancel** buttons

#### Persistence

Skills are stored as a JSON array in a file managed by `PersistenceManager`, similar to tasks and memories. File location: Application Support directory alongside existing persistence files. The `Skill` struct conforms to `Codable`.

A `SkillStore` (similar to `TaskStore`) manages in-memory state and persistence:
- CRUD operations
- `findByName(_ name: String) -> Skill?` for `/skill` command lookup
- `onChange` callback for UI refresh (same pattern as `TaskStore`)
- Owned by `AppViewModel` (not `OrchestrationRuntime` — skills are a UI/input concern, not an orchestration concern)

#### Implementation phases

**Phase 1 — Core data model and persistence:**
- `Skill` and `SkillArgument` structs (Codable)
- `SkillStore` with CRUD, persistence, and onChange callback
- Wire into `PersistenceManager` (load/save)
- Wire into `AppViewModel` (store ownership, published skill list)

**Phase 2 — Template processing engine:**
- `SkillRunner` or similar: takes a `Skill` + argument values, produces a final prompt string or an error
- Stage 1: variable substitution with `\{{` / `\}}` escape handling
- Stage 2: embedded `file_read` and `bash` execution (reuse existing tool logic or call the underlying functions directly)
- Clear error reporting: which variable is missing, which tool call failed and why

**Phase 3 — UI — Sidebar and detail view:**
- Segmented control on left panel (Tasks / Skills)
- Skill list view with play buttons
- Skill detail view with Run / Edit / Delete
- Skill editor (create + edit)

**Phase 4 — UI — Run dialog and `/skill` command:**
- Run dialog with argument fields, live prompt preview, Run/Cancel
- `/skill` command parsing in `UserInputView` or `AppViewModel.sendMessage()`
- Argument parsing: positional + keyword=value
- Integration: on successful run, send generated prompt via `runtime.sendUserMessage()`

#### Future additions (not part of initial implementation)

**1. Turn completed task into a skill.** After a task completes, offer a "Save as Skill" action. Use an LLM call (via the summarizer or a dedicated model config) to:
- Take the original task description and the completed result
- Generate a reusable prompt template
- Identify variable parts and suggest arguments (e.g., file paths, repo URLs, names that would change between invocations)
- Present the generated skill in the editor for the user to review and save

**2. Skill execution as agent tools.** Expose skills as tools available to Smith or Brown, so agents can invoke skills programmatically. This would allow meta-workflows where one skill's output feeds into another, or where Smith can decide which skill to run based on the user's request. Design TBD — needs careful thought about recursion depth, argument resolution, and whether tool-invoked skills skip the run dialog.

### Reject unavailable tool calls at execution time ✅
**Shipped.** `AgentActor` now re-checks each tool call against a freshly-built `ToolAvailabilityContext` immediately before dispatch at all three dispatch sites (lifecycle segment, parallel-approval segment, sequential-approval path). The check uses the same helper, `rejectionResultIfUnavailable(_:tool:)`, so behavior is identical across paths: an unavailable call gets a fixed `"Tool '<name>' is not currently available."` result, is recorded as a failure on the shared tracker (so a later retry isn't flagged as a duplicate), and is skipped before reaching Security Agent (so the system doesn't pay for a security evaluation on a call it was going to refuse anyway). A regression test (`AgentActorUnavailableToolTests`) drives a Brown actor with a hallucinated `reply_to_user` call (Smith-only at construction time but listed in Brown's tools) and asserts the execute path is not entered. Original design notes below.

Tool availability is currently enforced only at the definition level — tools excluded by `isAvailable` are omitted from the tool list sent to the LLM, but if the LLM hallucinates a call to an unavailable tool, `AgentActor` still executes it (line ~606, lookup is against the full `tools` array, not the filtered `toolDefinitions`). Add an execution-level guard: before running a tool call, re-check `isAvailable` and return an error result (e.g. "Tool '\(name)' is not currently available") instead of executing. This is defense-in-depth — the LLM shouldn't call tools it wasn't offered, but when it does, the system should refuse rather than silently comply.

### Per-MCP-server tool-control shortcuts ✅
**Shipped (2026-06-23).** Both tool-control surfaces gained a per-server aggregate that sets every tool a server advertises at once, rather than forcing the user to toggle each MCP tool individually:
- **Task detail → Tools** (`TaskToolOverrideEditor`): MCP tools are now grouped under a per-server header carrying an **Auto/On/Off** segmented control. The shortcut sets a `userToolOverride` for *every enabled tool the server advertises* (not just ones scoping approved for the task), so the user can grant/deny a whole server even when the security agent under-granted. The list shows all advertised tools of each connected server (approved ones checked, the rest open circles), plus a catch-all "Other (disconnected MCP)" section for approved/overridden tools whose server isn't currently connected. Per-server **disabled** tools (`MCPServerConfig.disabledTools`) are excluded — they're never bridged, so a control on them would be inert.
- **Settings → Tools** (`ToolsSettingsView`): each "MCP — <server>" header gained a **Default/Always/Never** aggregate that sets `globalToolPolicies` for all of that server's tools.
- The aggregate segmented control uses an optional binding (`Binding<State?>`) — uniform tool state selects that segment; a mixed set shows no selection (the standard SwiftUI no-selection idiom, no runtime warning).
- Engine plumbing: bulk setters `TaskStore.setUserToolOverrides(id:tools:enabled:)` + `OrchestrationRuntime.setTaskToolOverrides(taskID:tools:enabled:)` + `AppViewModel.setTaskToolOverrides(...)` apply one value across many tools in a single persist/worker-push (no fan-out into N writes). The Settings aggregate batches into one `globalToolPolicies` assignment (one save + observer notification).

**Latent bug fixed along the way:** `ToolsSettingsView` previously keyed `globalToolPolicies` for MCP tools by their **unprefixed** advertised name (`search`), but the engine resolves policies against the worker-facing **prefixed** name (`mcp__server__search`, `MCPBridgedTool.name`). So global Always/Never on any MCP tool was a silent no-op. The view now keys by the prefixed name (displaying the friendly unprefixed name), so MCP global policies actually take effect. Built-in tools were unaffected (name == key). Old unprefixed keys persisted in UserDefaults are harmless orphans; a previously-set MCP policy that was silently doing nothing now reads as Default until re-set.

**Known limitation:** both views recompute prefixed names via `MCPToolNaming.prefixedName(server.name, tool)`, which matches the bridge exactly *except* for the rare cross-server name-collision case where `MCPClientHost.currentBridgedTools()` suffixes a disambiguated name (`…_2`). For such a collided tool the per-server control/policy is inert (it matches no live candidate) rather than wrong — never grants the wrong tool. A fully authoritative fix would plumb the bridge's post-disambiguation names through `MCPServerStatus`; deferred since collisions are rare (server names are deduped at import) and the failure is benign.

### Per-task dynamic tool scoping for Brown (security-gated tool registry) ✅ (v1)
**Shipped (v1).** Built and verified (app builds clean; full package suite 401 tests green, incl. new `ToolRegistryTests` and `SecurityEvaluatorScopingTests`; launch smoke test clean). What landed:
- `AgentTool.isDestructive` / `isOpenWorld` + central fail-closed `ToolSafetyClassification` (all 36 built-ins classified); MCP `destructiveHint`/`openWorldHint` captured (untrusted) on `MCPBridgedTool`.
- `ToolRegistry` (registry + dispatcher gate) with the three-flag model, flag-preserving rebuilds, hallucinated-allow rejection, and the SHA-256 candidate fingerprint (full-schema, rug-pull defense). Wired as the single gate in `AgentActor.refreshActiveTools` — unavailable tools fall through to the existing "Unknown tool" path.
- `SecurityEvaluator.scopeTools(...)` + `SecurityAgentBehavior.toolScopingSystemPrompt`: text ALLOW/BLOCK, fail-closed, bounded retry, intersect-with-candidates; records an `EvaluationRecord` for audit; surfaces `destructive`/`open-world` (true-only) with built-in-vs-MCP trust labels.
- `OrchestrationRuntime.spawnBrown(for:)`: MCP settle (`MCPClientHost.waitUntilSettled`, 5 s) → scope → then enable Brown. `succeeded == false` → hard stop (surface to user, no Brown); zero approved → refusal (no Brown). `Preparing…` surfaced as a channel message.
- `AgentActor` scoped mode: candidates seeded disabled, approvals applied, forced lifecycle flags (phased `task_acknowledged` → `task_update`/`task_complete`, `reply_to_user` forced + context-gated), stateless per-turn re-eval on fingerprint change with the generic "Available tools have changed" nudge.
- `AgentTask.approvedTools` record (Codable `decodeIfPresent`) + `TaskStore.setApprovedTools` with replacement annotation in `updates`.

**v1 deviations to revisit (not yet done):**
- `Preparing…` is a channel message, not a formal `Task.Status` case (the `Task.Status` enum ripple was avoided for v1).
- `isUnavailableDueToContext` exists on the registry but is **not driven** in v1 — context gating (e.g. `reply_to_user` until the user messages, awaiting-review) still flows through the existing `isAvailable(in:)` filter, which composes with the registry gate. The flag is there for future use.
- The post-review re-spawn path (`ReviewWorkTool` → `context.spawnBrown()` with no task) is **unscoped** in v1 (falls back to the full tool set). The two primary task-start paths (new task, resume) are scoped.
- Abort-during-`Preparing` is handled by the `!aborted` recheck + `scopeTools` cancellation, but not exhaustively hardened.

Original design notes below.

Let the security agent (Security Agent) decide, per task, which of Brown's tools are available — including MCP tools. Brown starts each task with **nothing** enabled; Security Agent is shown the full candidate list in the context of the task and returns an explicit allow/block per tool. Only allowed tools are dispatchable. This replaces today's fixed `BrownBehavior.tools()` list with a per-task, security-curated subset, and gives the system a single enforcement surface.

**The registry (`ToolRegistry`) — registry and dispatcher in one.** A new type that owns a set of tool entries, each carrying three independent flags, and that is also the lookup surface at dispatch (replacing the scattered `activeTools.first(where:)` calls in `AgentActor`). One registry per agent instance, backed by the shared session MCP host for dynamic tools. A tool's availability is:

```
isAvailable = isForcedAvailableBySystem || (isApproved && !isUnavailableDueToContext)
```

- `isApproved` — **security permission.** Set *only* by the Security Agent scoping verdict.
- `isUnavailableDueToContext` — **transient orchestration context** (e.g. `reply_to_user` off until the user has messaged; work tools hidden during `awaitingTaskReview`). Set by orchestration code, never by Security Agent.
- `isForcedAvailableBySystem` — **system override / security bypass.** Short-circuits everything. Used to make a small set of trusted built-in lifecycle tools available exactly when the loop needs them.

`getAvailableTools()` returns the entries where `isAvailable` is true. The dispatcher looks tools up in the same registry, so the advertised set and the dispatchable set cannot drift; an unavailable tool is simply not found and falls through to the existing "Reject unavailable tool calls" guard above (rejected identically to a nonexistent tool — Brown can't distinguish "blocked" from "doesn't exist").

**Smith and Security Agent registries are trivial** — all built-ins, `isApproved` effectively always true, no scoping pass. Only Brown's registry runs the enable/disable flow.

**Everything goes through the security agent — no auto-grant.** Even read-only built-ins (`file_read`, `grep`, …) are scoped by Security Agent. (Earlier discussion considered auto-granting trusted read-only built-ins; rejected in favor of a uniform model.) MCP tool annotations (`readOnlyHint`/`destructiveHint`/`openWorldHint`) are **untrusted hints** and never gate anything; they are passed to Security Agent as advisory context only when `destructiveHint` or `openWorldHint` is true (we do *not* surface `readOnlyHint` or `idempotentHint`). For our own built-ins, the equivalent facts (`isDestructive`, `isOpenWorld`) are authored on the tool and surfaced to Security Agent as fact, not hint. Security Agent is instructed to construct the smallest, safest subset that can complete the task. The verdict is **fail-closed**: any tool omitted from Security Agent's response is treated as blocked. Security Agent's response stays text-based (allow/block list), consistent with the rest of its design — not tool calls.

**Verdict handling.** Security Agent's raw response is *not* stored; it is consumed once to mark known registry tools allowed/blocked. Robustness rules: intersect the allow list with the actual candidate set (ignore any tool name Security Agent invents or hallucinates — never enable something that isn't really there); and give the scoping call a bounded retry on a malformed/unparseable response (same spirit as `SecurityEvaluator`'s retry budget). **Two-tier, reaffirmed:** being on the approved list only means a tool is *offered* — `bash`/`gh`/`run_applescript`/MCP calls still get per-call Security Agent evaluation at execution time. Approved ≠ auto-run; don't let a later refactor collapse the two tiers.

**Zero approved = task refusal.** If Security Agent approves no work tools, do **not** spawn a hamstrung Brown that can only acknowledge and dead-end. Treat it as a refusal (tie into Security Agent's existing ABORT semantics): fail/abort the task with a surfaced reason rather than running it.

**Startup sequence (when Smith calls `create_task` or `run_task`).** Brown is **not** created until scoping is done:
1. Build the machinery and start MCP servers; wait up to a bounded **settle deadline (~5s)** for each to reach started-or-errored — never wait forever (ties to the MCP connect-deadline gotcha). Servers that miss the deadline are treated as absent; if they come up later they trigger a re-eval at a turn boundary (see below).
2. **MCP failure → ignore** that server; its tools are simply absent. Proceed.
3. Run the Security Agent scoping pass against the full candidate list (built-ins + available MCP tools) **exactly once** after the settle window — coalesce/debounce so N servers starting within the window produce a single scoping pass, not one evaluation per server.
4. **Security-LLM failure → hard stop, surfaced to the user.** This is a serious error, not a degrade-and-continue: we cannot safely scope, so we do not spawn Brown.
5. Only then create/assign Brown with the curated registry.

The task shows a **`Preparing…` status** during this window (which may update through sub-states like "Starting MCPs…", "Checking security…") since MCP startup + a Security Agent call adds real latency before Brown exists.

**Forced lifecycle tools (interim approach).** Rather than a permanent "always enabled" class, the loop drives `isForcedAvailableBySystem` to expose the few tools the system needs, when it needs them:
- Initially: force `task_acknowledged` available; `reply_to_user` is `isUnavailableDueToContext = true` (user hasn't messaged).
- On receiving `task_acknowledged`: clear its force / set `isUnavailableDueToContext = true`, and force `task_update` + `task_complete` available.
- For initial testing these lifecycle tools are *also* sent to Security Agent so we can observe its verdict — but because `isForcedAvailableBySystem` short-circuits the formula, the verdict is **observed/logged, not enforced** for forced tools. (Forcing is a deliberate security bypass; it may only ever be set by our code on trusted built-in lifecycle tools, never derived from MCP or any external input.)

**Per-turn re-evaluation is stateless.** At the start of each Brown turn, re-fetch the candidate tool list (built-ins + current MCP tools). Candidate identity is a **content hash of name + description + input schema** — *not name alone* — so a server that silently redefines a tool under the same name (a rug-pull) forces re-evaluation instead of riding a stale approval. If the candidate set (by hash) is identical to last turn, leave the registry alone. If it changed (MCP added/removed/`tools/list_changed`/redefined), run a **fresh** Security Agent scoping pass with no memory of prior verdicts — allow → `isApproved = true`, everything else → `isApproved = false`. (The stateless approach can re-litigate unchanged tools due to LLM non-determinism; accepted for simplicity, mitigated by the nudge below.) Changes apply at the **turn boundary**, never mid-turn; mind the known MCP actor-reentrancy gotcha (the async re-eval must resolve and apply at the boundary, not while the turn loop holds state).

When — and *only* when — a security re-eval changes the approved list, inject a generic synthetic user-role message into Brown's history: **"Available tools have changed - confirm availability before use."** Do **not** inject it for context/force flag flips the system drove deliberately (e.g. the `task_acknowledged` → `task_update` transition), or Brown gets nagged on every acknowledgement.

**Task storage (record, not gate).** Persist the latest approved list on `AgentTask` (`approvedTools: [String]?`; custom Codable already in place — use `decodeIfPresent` so old tasks load as `nil`). The registry remains the source of truth for gating; the task field is a record + future UI surface. On a mid-task replacement, overwrite the field and append a `TaskUpdate` ("approved tool list replaced. Previous: …"). On resume, a fresh stateless scope runs and (if different) annotates a replacement.

**Explicitly out of scope for v1 (start with the simplest thing):**
- No escape hatch / `request_tools` tool. If Security Agent under-grants, the task may dead-end; revisit later.
- No auto-grant of read-only tools.
- No verdict-seeded re-eval (the stability refinement over stateless) and no store-for-fast-resume optimization.
- Smith-side scoping (Smith's tools stay fixed; the annotations live on the tools for possible future use).

**Must handle in v1 (implementation traps, not deferrable):**
- **Abort/cancel during the `Preparing…` window.** The Stop/abort path today assumes Brown/Security Agent actors exist; the user can hit Stop while MCPs are starting or scoping is running, before Brown is created. That path must cancel cleanly with no Brown yet.
- **New `Task.Status` ripples.** Adding `Preparing…` touches persistence (Codable), sidebar rendering/filtering, auto-advance / next-pending logic, and the summarizer's terminal-state assumptions. Enumerate and update all sites before adding the case.
- **Test seam.** Security Agent is an LLM, so the scoping pass needs a mockable evaluator (inject a stub returning a fixed allow/block) to deterministically test registry wiring, the hash-based candidate diff, forced-flag transitions, and fail-closed/parse-retry handling — same pattern as the existing `SecurityEvaluator` tests.
- **Prompt-cache cost awareness.** Re-scoping changes Brown's tools array (breaks the cached prefix) and the synthetic "tools changed" message mutates history. Stable MCP config → fires once; a flapping server now costs a Security Agent call *and* a full Brown cache miss each changed turn. Document so a future cost-spike investigation has the explanation.

**Deferred to a follow-up milestone (after initial test rounds):** the *robust handling* of the under-grant / refusal failure modes. The mechanisms are decided but intentionally not in the first slice:
- **Refusal UX** for zero-approved (graceful surfaced refusal vs. today's abort plumbing).
- **Brown under-grant ergonomics:** prompt language asserting the task-scoped toolset is authoritative ("do not assume tools beyond those offered"), plus a clean `task_complete`-as-failed path so Brown reports "no tool for X" instead of looping on `"Unknown tool"` rejections.
- **Smith's blind spot:** Smith never sees the scoping decision, so re-running an under-granted task re-scopes the same way → same failure → loop. Smith needs a signal (the approved list, or "Brown was scoped and lacked X") to break the cycle or escalate to the user.

**Noted, not changing now:** Security Agent scopes from task title + description + ID only — task **attachments are invisible** to scoping, though a `.sql`/`.xcodeproj`/etc. attachment may imply needed tools. Cheap future improvement: feed Security Agent the attachment filenames/types. Left as a known limitation for v1.

### Harden `isRetryableError` in TaskSummarizer
`TaskSummarizer.isRetryableError` currently matches on `error.localizedDescription` strings (e.g. `hasPrefix("HTTP 429")`, regex for `^HTTP 5\d\d`). This works because `LLMProviderError.httpError` formats its description as `"HTTP \(code): \(body)"`, but it's fragile — if error wrapping or formatting changes, retries silently stop working. Replace with direct pattern matching on `LLMProviderError.httpError(statusCode:body:url:)` to check the status code as an integer.

### Decouple SecurityEvaluator iteration counters ✅
**Already shipped** — this ROADMAP entry was stale. `SecurityEvaluator.evaluate` already tracks `fileReadRounds` (cap 20) and `retryCount` (cap 5) independently, with the loop condition `while retryCount < Self.maxRetries && fileReadRounds < maxFileReadRounds`. File-read rounds bump on tool-call responses, parse retries bump on parse failure or LLM error. Original design notes preserved below for context.

`SecurityEvaluator.evaluate` uses a combined `totalIterations` counter (capped at 25) that conflates file-read rounds with parse-failure retries. If Security Agent reads many files (the prompt now says "up to 20 at a time"), it can exhaust the iteration budget before getting a chance to retry a parse failure. Fix: track `fileReadRounds` and `retryCount` independently, each with its own cap (e.g., 20 file reads, 5 retries). The combined counter was introduced to prevent unbounded loops, but separate caps achieve the same goal without the coupling.

### Search: Cmd-F and Cmd-Shift-F
Two levels of search:

**Cmd-F — Find in current transcript.** Opens a search bar (similar to browser/IDE find-in-page) that highlights and jumps between matches in the visible channel log. Should support case-insensitive text matching at minimum; regex would be a bonus. The search bar should appear at the top of the channel log area with next/previous navigation and a match count indicator.

**Cmd-Shift-F — Global search across tasks, transcript, and prior transcripts.** A more powerful search that covers:
- Current transcript messages
- All tasks (titles, descriptions, updates, results)
- Prior session transcripts that are not currently loaded/visible

Results should be grouped by source (current transcript, task, prior session) with enough context to understand each match. Clicking a result navigates to it or opens it in context.

> **Note:** This implies we need a way to view prior transcripts. Currently, transcripts from previous sessions are persisted but only partially restorable. Consider adding a "Session History" or "Prior Transcripts" view (perhaps accessible from the sidebar or a dedicated tab) that lets the user browse, search, and read past session transcripts. This would also support the Cmd-Shift-F global search by providing the underlying data source and navigation target for prior-session matches.

### Tool post-call behavior flags system
`AgentActor.updatePostCallFlags` currently uses stringly-typed matching on tool names and exact return value strings to determine post-call behavior (should the agent idle? did it send a message? did it complete a task?). This is fragile — adding a new tool or changing a return string requires manual sync with the agent loop, and mistakes cause bugs like the task_update spam loop.

Replace with a structured system where tools declare their post-call semantics via a protocol property or return type:
- `PostCallBehavior.idle` — agent should wait for new input after this call (e.g., `message_user`, `reply_to_user`)
- `PostCallBehavior.continue` — agent should keep working (e.g., `file_read`, `bash`, `task_update`)
- `PostCallBehavior.awaitReview` — agent enters review-wait state (e.g., `task_complete`)
- `PostCallBehavior.restart` — agent loop should exit for a system restart (e.g., `run_task`)

The tool's `execute` method could return a `ToolResult` struct containing both the result string and the behavior flag, eliminating the need for string matching entirely. This also makes the agent loop's control flow self-documenting — each tool explicitly declares what should happen after it runs.

### Enhanced model stats popover in inspector
The model stats popover (shown when clicking the model name on an agent card) currently shows session-level stats computed from `LLMTurnRecord` data: LLM call count, tool call count, average latency, context resets, and token breakdowns. Future enhancements:
- **Per-task breakdown**: Show stats grouped by task, so the user can see which tasks consumed the most tokens.
- **Historical stats from UsageStore**: Aggregate across sessions using persisted `UsageRecord` data (not just the current session's `LLMTurnRecord` array). Show all-time totals, daily averages, and trends.
- **Cost estimation**: Use pricing data from `ModelMetadataService` to show estimated dollar costs alongside token counts. See "Token usage cost estimation" below.
- **Security Agent-specific stats**: For the security agent, show approval/denial/warning/abort counts from `EvaluationRecord` data (already available in `securityAgentEvaluationRecords`).
- **Latency histogram or percentiles**: Show p50/p95/p99 latency instead of just the average.

### Token usage cost estimation
Add estimated cost columns to the Token Usage analytics window. Use LiteLLM pricing data (already available via `ModelMetadataService`) to calculate per-turn and per-task cost estimates based on model ID and token counts. Display in the Overview, By Task, and By Model/Provider tabs. Handle cache pricing correctly (Anthropic cached reads are cheaper than uncached input).

### Surface estimated cost in the inspector + task UI ✅
**Shipped.** Cost data is now visible in four places without the user having to open the analytics window:
- **Cost Estimate panel** above the Agents column in the inspector: a 4×2 grid (today / this week / this month / this year) × (current / prior). Windows are anchored on a local-TZ, Sunday-start Gregorian calendar (`CostBoard.calendar`).
- **Per-agent session cost** row on each agent card (Smith / Brown / Security Agent / Summarizer).
- **Compact cost chip** on every completed task row in the sidebar.
- **Tokens + Cost** rows in the task detail window's metadata grid.

Performance design (the key concern that drove the implementation): all eight dashboard totals come from a single cached `CostBoard.Snapshot` republished from a new `AgentSmithKit/Usage/CostBoard` actor. Bootstrap does one full `UsageStore` scan; every subsequent record updates the snapshot in O(1) via a new `UsageStore.onInsert` hook. A periodic watcher Task plus an on-appear refresh roll calendar boundaries lazily — prior-period totals are immutable until their boundary crosses, so the panel never re-aggregates on view redraws. Per-agent session cost is memoized by `turnsByRole[role].count`; per-task cost is cached on `AppViewModel` indefinitely (completed tasks don't grow new records). Tests: `CostBoardTests` covers bootstrap, incremental insert, day-boundary rollover, calendar configuration.

### Cross-window/cross-session wake routing
A scheduled wake currently fires on the same actor that scheduled it. This is fine for "wake Brown for the task he's working on now," but it's wrong in three other shapes the user has identified as desired behavior:

1. **Wake for the current task, fired during `awaitingTaskReview`.** Today the wake is held in the queue and fires on the next loop iteration after Smith resumes Brown (the local 2026-04 fix). The user's intent is broader: even if Smith *approves* and Brown terminates, the wake should still surface — re-routed to whatever runtime/window currently has access to the (now-completed) task, or to Smith.
2. **Wake for a different task.** The wake should be delivered to the runtime/window currently running that task (if any). If no window is currently running it, a new window/tab should be opened for the task, the agent awoken, and the wake delivered there. The UI should switch focus to that window.
3. **Wake not tied to any task.** The wake should land in any open window/tab that is not currently working on a task. If none qualify, a new window/tab opens to receive it.

**Why this is a separate redesign:** wakes today live inside `AgentActor.scheduledWakes` — actor-private state belonging to a single Brown or a single Smith. Cross-window delivery requires a coordinator above the actor: it has to enumerate sessions in `SessionManager`, find the runtime hosting a given task, and (in the new-window case) drive `openWindow(id:)` + the `pendingNewSessionIDs` queue from outside the SwiftUI scene graph. Likely shape: hoist scheduled wakes onto a `WakeRouter` actor owned by `SharedAppState`, with `AgentActor` only holding wakes that are local-by-construction (the silence-nudge timers). The router fans out on fire to the right runtime by task lookup, falling back to "any idle session" or "spawn a new window."

**Out of scope for the local-only fix landed in 2026-04:** that change just stops `checkScheduledWake` from dropping wakes during `awaitingTaskReview`. It does NOT add cross-runtime delivery, does NOT route to other windows, and does NOT preserve a wake whose Brown actor terminates between schedule and fire. ROADMAP entry tracks the full design.

### Brown silence — hard mode and synthetic-update fallback
The soft Brown silence nudge already injects a `[System]` user-role message into Brown's conversation when he hasn't sent a `task_update`/`task_complete` in `(≥5min AND ≥10 tool calls)` OR `≥15min`, instructing him to call `task_update` next. That handles the common case where the model just forgot.

Two follow-on mechanisms worth implementing if soft-mode proves insufficient:

**Hard mode — restrict tool list to `task_update` only.** If the soft nudge fires and Brown ignores it (continues making non-`task_update` tool calls past a second threshold — e.g., +5 more tool calls or +2 more minutes), strip Brown's tool list for the next turn down to *only* `task_update`. The system message that turn becomes "You ignored the previous nudge. Until you call `task_update`, no other tools are available." After Brown calls `task_update`, restore the full list. Implementation note: do NOT yank tools immediately on the first nudge — gpt-style models emit refusal-shaped text when their tool options run out (we already saw this). Forcing the constraint after a soft warning makes the resulting `task_update` call feel earned rather than confused. Rough hook: in `runLoop`'s tool-availability filter (`AgentActor.swift:454-456`), gate on a `forceTaskUpdateOnly: Bool` actor flag set by `checkBrownSilenceNudge` after the second threshold.

**Synthetic update — runtime-generated task_update on the agent's behalf.** Instead of (or alongside) hard mode, the runtime could generate its own factual digest of Brown's recent activity and write it as a `task_update` directly to the TaskStore (skipping the channel) so Smith's `get_task_details` sees something fresh without a Brown round-trip. The body would be derived from Brown's recent tool calls + channel messages — same data source as Smith's 10-minute digest. Pros: zero extra latency, zero token cost, always up-to-date. Cons: can hallucinate intent ("Brown is investigating X" when Brown was actually about to abandon X), so the framing must be strictly factual ("Brown made N tool calls including file_read of /foo/bar.swift") rather than narrative. Probably safer to default to nudging Brown to speak for himself, with synthetic updates as a fallback when even hard mode fails.

### Replace NLEmbedding with MLX Qwen3-Embedding-0.6B-4bit-DWQ ✅
**Shipped.** Embedding now runs through `SemanticSearch` (sibling package): `SemanticSearchEngine` + `MLXEmbedderBackend` load `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` via `MLXEmbedders`. `NLEmbedding`/NaturalLanguage is no longer used (survives only as a historical comment in `MemoryStore.swift`). Follow-ups in this entry are also done: the RRF blend in `MemoryStore` is now an equal-weight semantic+lexical fusion (the old 25%-weighted lexical channel is gone), and the noise floor was recalibrated for Qwen3's cosine distribution (`MemoryStore.defaultSearchThreshold = 0.10`). `MemoryStoreIntegrationTests` runs end-to-end against the real engine, gated behind `AGENT_SMITH_RUN_MLX_TESTS=1` + `xcodebuild` (plain `swift test` can't compile MLX's Metal shaders). Original design notes retained below for context.

The current `EmbeddingService` uses Apple's `NLEmbedding.sentenceEmbedding(for: .english)` from the NaturalLanguage framework — a 512-dim sentence embedding model that runs locally with no API cost. It works, but it's an older model and we've observed weak retrieval on rare technical terms, code, identifiers, and topical paraphrasing. The 25% lexical overlap component in our RRF blend (`MemoryStore.searchAll`) was added partly to compensate for this.

**Target model:** [`mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`](https://huggingface.co/mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ) — a 4-bit DWQ-quantized variant of Alibaba's Qwen3 Embedding 0.6B, runnable on Apple Silicon via the MLX framework. Demonstrated in the [`mlx-swift-examples`](https://github.com/ml-explore/mlx-swift-examples) repo's `embedder-tool` example.

**Why:** We compared this model against the current Apple NLEmbedding pipeline using a real corpus of our own task data (see methodology below) and got noticeably better results — top-K matches were more topically relevant and the model handled queries the Apple model would miss entirely (paraphrases, conceptual lookups, and queries about specific entities mentioned only briefly in long documents).

**Open question (resolved):** speed and memory footprint were the gating concern — whether to move fully to Qwen3, keep both and pick at runtime, or use Qwen3 for search only. Resolved in favor of moving fully to Qwen3 for both save-time and search-time embedding; measured latency (see below) was acceptable. `NLEmbedding` was dropped entirely, not kept as a fallback.

**Initial timing measurement (52-task corpus, M-series Mac, "how to send messages" query):**
```
timing: loaded 52 entries in 11.38 ms
timing: embedded query in 32.89 ms
timing: sanitized/normalized query in 0.01 ms
timing: ranked 52 entries in 0.03 ms (0.56 µs/entry)
timing: total search pipeline 44.50 ms
```
Top 4 results were all genuinely relevant (contact-sending tasks like "Send iMessage to <contact>", etc.) with similarity scores 0.69–0.74. ~44 ms total per search is acceptable for a corpus this size, but the bulk of that (~33 ms) is the query embedding step — that cost grows roughly linearly with query length. Wishlist: faster query-embedding path. The ranking step at 0.56 µs/entry is essentially free and would scale to thousands of documents without trouble; the bottleneck is the per-call embed cost, not the search pass. Need a second measurement on a larger corpus (200+ entries) to confirm the linear-search assumption holds and to see how `save_memory`/`task_complete` save-time embed latency feels in practice.

**Testing methodology used so far:**

1. **Corpus export.** Wrote a Python script (`/tmp/export_tasks_to_corpus.py`) that reads `~/Library/Application Support/AgentSmith/tasks.json`, decodes the Swift `Date` fields (default `JSONEncoder` uses seconds-since-2001-01-01-UTC, NOT Unix epoch), and writes one Markdown file per task to `/tmp/corpus/`. Each file has the task ID, status, disposition, all timestamps, the description, result, commentary, summary, and the full progress-update history — basically the same composite text we feed into `MemoryStore.composeEmbeddingText`. This gives us a static corpus we can re-run experiments against without depending on the live app state.

2. **Index build.** From a checkout of `mlx-swift-examples`:
    ```
    ./mlx-run embedder-tool \
        --model mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ \
        index \
        --output /tmp/embed_index.json \
        --directory /tmp/corpus \
        --extensions md txt \
        --recursive
    ```

3. **Queries run** (representative examples from our session):
    ```
    ./mlx-run embedder-tool search \
        --model mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ \
        --index /tmp/embed_index.json \
        --query "PRs submitted to github repos" --top 4

    ./mlx-run embedder-tool search \
        --model mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ \
        --index /tmp/embed_index.json \
        --query "info about my friends or family" --top 4

    ./mlx-run embedder-tool search \
        --model mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ \
        --index /tmp/embed_index.json \
        --query "how to send messages" --top 4
    ```

   All three returned visibly more relevant top-K results than what `searchAll` produces with the current Apple model on the same corpus.

**Implementation (as built):**
- The embedding stack moved into the `SemanticSearch` sibling package rather than adding MLX deps directly to `AgentSmithKit`: `SemanticSearchEngine` + `MLXEmbedderBackend` + `EmbeddingModel` wrap `MLXEmbedders` and load `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`. `MemoryStore` talks to the engine; `EmbeddingService`/`NLEmbedding` is gone.
- Vector dimension changed (Qwen3 > 512), so stored vectors needed a re-embed pass — handled via the existing `reembedAllMemories` / `reembedTaskSummariesFromTasks` mismatch-on-load migration path.
- Lexical-overlap weight in RRF: the old 25%-weighted lexical channel was dropped; `MemoryStore.reciprocalRankFusion` now does an equal-weight semantic+lexical fusion (`1/(k+sRank) + 1/(k+lRank)`, k=60).
- Noise floor recalibrated for Qwen3's cosine distribution: the old `0.55` gate is now `MemoryStore.defaultSearchThreshold = 0.10` (unrelated text scores sit well below 0.10; RRF does the real ordering).

**Risks (outcome):**
- Model weight download — one-time cost on first run; acceptable.
- Runtime memory — 4-bit quantized 0.6B is comfortable in-process.
- Per-embedding latency on save — within tolerance per measurements; `save_memory` / `task_complete` embeds are not noticeably slow.
- Re-embed pass on startup — no longer instant but acceptable at current corpus sizes; revisit if corpora grow into the thousands.

### SwiftUI review P3 — accessibility baseline pass
From the 2026-04-27 SwiftUI review (P3 follow-ups). The app currently has zero `.accessibilityLabel`, `.accessibilityHint`, or `.accessibilityIdentifier` calls. VoiceOver auto-derives labels from string content, which works for `Text("Start")` but fails for icon-only buttons (e.g. `InspectorView`'s speech-mute and gear buttons render as silent icons under VoiceOver). UI tests have no stable hooks either.

Plan:
1. Every icon-only `Button(action:, label: { Image(systemName: ...) })` gets `.accessibilityLabel("...")` matching its existing `.help("...")`.
2. Every primary action (Start, Stop All, Send, Pause/Stop on tasks, Mute/Unmute) gets a stable `.accessibilityIdentifier(...)` so future UI tests have hooks.
3. Custom-laid-out rows (channel banners, inspector rows) get `.accessibilityElement(children: .combine)` with a single composed label per row.

Estimated 30 minutes of mechanical work; no architectural change.

### SwiftUI review P3 — `@retroactive Identifiable` on UUID
`SpendingDashboardView.swift:705-707` adds `extension UUID: @retroactive Identifiable { public var id: UUID { self } }` to support `.sheet(item: $selectedTaskID)`. If a future Swift release adds Identifiable to UUID, this conflicts. Workaround: wrap the UUID in a private `IdentifiedTaskID` struct whose only purpose is `Identifiable` conformance for the sheet callsite. Low-risk, deferred until conflict appears.

### SwiftUI review P3 — `.scrollPosition` modernization
`ChannelLogView`'s auto-scroll-to-bottom is built on `ScrollViewReader` + `.onChange(of: messages.count)`. Modern SwiftUI offers `.scrollPosition(id:)` which is more declarative and integrates with `.scrollTargetBehavior`. Optional refactor — current implementation works.

### SwiftUI review P3 — SwiftLint rule for `: some View` antipattern
After the 2026-04-27 sweep eliminated 44 `: some View` property antipatterns, add a SwiftLint custom rule (or CI grep) to prevent reintroduction:

```regex
^\s*(@ViewBuilder\s+)?(private |fileprivate |internal )?var [a-zA-Z_]+: some View
```

The `swiftlint` skill is configured for this project. Pair with the `CodeStyleGuardTests` regression tests added in the same sweep so violations surface even without SwiftLint installed.

### SwiftUI review P3 — Inspector double-scroll redesign
`InspectorView.swift:22` (outer ScrollView) wraps `:315` and `:111` of `AgentInspectorWindow`, each a `ScrollView(.vertical) { ... }.frame(maxHeight: 300/400)`. The bounded-height inner scroll is intentional but on macOS produces double-scrollbar UX where users sometimes scroll the outer when meaning the inner. Lower priority — would need a custom container that lets the inner section grow up to N pt and then fold into the outer scroll.

## Blockers

### ~~SSH key not configured on this device~~ ✅ Resolved
Was misdiagnosed as an SSH key issue. The actual problem was corrupted SwiftPM caches. Fix: delete `~/.swiftpm`, `~/Library/org.swift.swiftpm`, and `~/Library/Caches/org.swift.swiftpm`, then quit and restart Xcode. May also need to verify the build succeeds — there may be pre-existing errors in `ProviderManagementView.swift` and `ModelConfigurationEditorView.swift` referencing `ProviderAPIType` that need investigation.
