# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Agent Smith is a macOS app (Swift 6 / SwiftUI; the app target deploys to macOS 26.2, the `AgentSmithKit` package to macOS 15) that orchestrates a small fixed cast of LLM-driven agents working together on user-supplied tasks. The roles are not abstract — they are baked into `AgentRole` and the codebase assumes all four exist:

- **Smith** — orchestrator. Talks to the user, creates tasks (with acceptance criteria), spawns/supervises Brown, and resolves validation escalations. Never does work itself, and does NOT review routine submissions — the acceptance-validation system does (see below).
- **Brown** — single worker spawned per task. Holds the bash/file/process tools and owns the task's step list (`manage_steps`) while it runs. Smith also has `manage_steps` (with `task_id`) to shape a task's plan when no worker is active — e.g. adjusting a premade/template task's seeded steps; it's gated by `Status.isValidationContractEditable` — the same predicate the UI uses, and the same gate `set_acceptance_criteria` carries (`docs/claude/acceptance-validation.md`) — so Smith can never edit steps out from under a running Brown or an in-flight validator. Steps authored by Smith carry `.smith` origin; Brown's carry `.worker`.
- **Security Agent** — silent security gatekeeper that runs alongside Brown. Returns plain-text `SAFE/WARN/UNSAFE/ABORT` verdicts on Brown's tool calls (text-based, *not* tool calls — see `SecurityAgentBehavior.swift` and `SecurityEvaluator.swift`). This is deliberate (see memory/roadmap). Don't "improve" it by giving Security Agent tool-call evaluation.
- **Summarizer** — summarizes completed/failed tasks (`TaskSummarizer`).

A fifth `AgentRole` case, **`.validator`**, is the acceptance-validation judge. It is not one of the four agents — a validator is a per-criterion evaluation, never a long-lived `AgentActor`, so it has no inspector panel, system prompt, poll interval, or tool-call budget — but it *is* an ordinary configurable slot: `agentAssignments[.validator]`, `llmProviders[.validator]`, its own usage attribution and channel provenance, and its own `ToolContext` for the read-only evidence tools. Assign its model from the Validator card in the Agents inspector (`ValidatorAgentCard`).

**No role falls back to another role's model** — resist re-introducing that as a convenience. `providerForModelSlot` resolves each slot against its own role and returns nil otherwise. An unassigned validator does not quietly borrow the Summarizer's model — it parks each submitted task in `.awaitingReview` with `AgentTask.validationBlockedReason` set. That park is **nobody's to resolve**: `isUserResolvableEscalation` requires `validationBlockedReason == nil`, so the user's four task-row actions are not offered on it — accepting a task no validator ever judged is exactly the unjudged pass validation exists to prevent. Assigning a validator model releases every parked task automatically (`setProviders` → `releaseValidationBlockedTasks` → re-enqueue). `.validator` is deliberately absent from `requiredRoles` so a missing validator blocks validation rather than app launch.

The full design history, rationale, and completed/planned features live in `ROADMAP.md` at the repo root — read it before proposing architectural changes. Per the global rules, completed roadmap items stay in the file; mark them ✅ rather than deleting.

## Repo layout

- `AgentSmith/` — the Xcode app target (`AgentSmith.xcodeproj`, scheme `AgentSmith`). Contains the SwiftUI layer (`Views/`, `ViewModels/`), the `ExportDefaults` CLI target, and bundled `Resources/defaults.json`.
- `AgentSmithPackage/` — local Swift package `AgentSmithKit` containing the entire engine: `Agents/`, `Channel/`, `Evaluation/`, `LLM/`, `Memory/`, `Orchestration/`, `Persistence/`, `Tasks/`, `Tools/`, `Usage/`. The app depends on this package; almost all logic lives here.
- `AgentSmithPackage/Tests/AgentSmithTests/` — Swift Testing (`@Suite` / `@Test`) tests for tools, channel, and usage aggregation.
- `SafetySystemTesting/` — isolated harness and scripts for exercising the safety/gatekeeper system. Self-contained; has its own README.
- `scripts/` — one-off Python utilities (e.g. `backfill_tool_calls.py`).
- `ROADMAP.md` — long-form plan + completed-work log. Authoritative source for "why is it this way."
- `docs/plans/` — historical sub-plans (`ROADMAP_implement_tabs.md`, `InspectorImprovements.md`, …).
- `docs/audits/` — past code-review and SwiftUI audit reports.
- `docs/claude/` — reference sections split out of this file; see "Reference docs" at the end for when to read each.
- `docs/model-capability-audit.md` — model capability audit.
- `docs/assets/` — app icon, screenshot, and social-preview images.

## Package dependencies (versioned git)

`AgentSmithPackage/Package.swift` depends on versioned git releases (NOT path-based; sibling checkouts are for development of those packages only):

- `drewster99/swift-llm-kit` (SwiftLLMKit — providers, model configs, Keychain API key storage, `LLMKitManager`, `ModelConfiguration`, `ProviderAPIType`). Releasing a change there means: change → build → commit → push → tag → push tag → bump the `from:` version here.
- `drewster99/swift-semantic-search` (SemanticSearch — `SemanticSearchEngine` used by `MemoryStore`)
- `modelcontextprotocol/swift-sdk` (MCP client support)

## Building and running

Always build via the drews-xcode-mcp tools — never `xcodebuild`, `swift build`, or `swift package build`. The app target requires Xcode (Assets.xcassets, entitlements, Info.plist).

- Build: `mcp__drews-xcode-mcp__build_project --project_path /Users/andrew/cursor/macos-agent-smith/AgentSmith/AgentSmith.xcodeproj` (scheme `AgentSmith`). (The repo is also reachable as `~/Documents/ncc_source/cursor/macos-agent-smith` — same directory.)
- Run the app: `mcp__drews-xcode-mcp__run_project_unmonitored` (or `run_project_until_terminated`) against the same project path, then `stop_project` + `get_runtime_output`. Do NOT use `run_project_with_user_interaction` — it blocks on a dialog click.
- Run tests: **two commands required, not one.**
  - `mcp__drews-xcode-mcp__run_project_tests` against `AgentSmith.xcodeproj` covers any tests that live in the .xcodeproj test bundle. Today there are none here, but it's the right hook if .xcodeproj-side tests ever get added.
  - **Package tests** (everything under `AgentSmithPackage/Tests/AgentSmithTests/` — the bulk of the suite) must be run manually from the terminal:
    ```
    cd /Users/andrew/cursor/macos-agent-smith/AgentSmithPackage && swift test --skip MemoryStoreIntegrationTests
    ```
    Why two commands: the AgentSmith scheme's auto-created test plan does not include the local package's test target (Xcode 16 does not auto-discover test targets from referenced local Swift packages). Adding an explicit `.xctestplan` was attempted and reverted because Xcode's IDE-side index couldn't resolve the package test target reliably; the terminal command sidesteps that entirely.
  - `MemoryStoreIntegrationTests` is skipped above because it requires Xcode's build pipeline to compile MLX Metal shaders (`swift test` alone can't). To run it, run the file's documented `xcodebuild` invocation by hand — but ask the user first; the project rule is xcode-mcp-only for builds.
  - To run a subset, use `--filter`, e.g. `swift test --filter GhToolArgsFilterTests`.
- After non-trivial changes, follow the smoke-test pattern noted in user memory (run app ~15s, screenshot, check logs).

## Where to look when you need to know what an agent actually saw

**LLM request/response logs: `$TMPDIR/AgentSmith-LLM-Logs/`** — on this machine `/var/folders/…/T/AgentSmith-LLM-Logs/`. One JSON file per call, named `<timestamp>-<seq>_<provider>_<model>_{request,response}.json`. The request file contains the **full message array as the model received it**, so it is the only place that shows what was actually in an agent's context.

Written by `LLMRequestLogger` (SwiftLLMKit), configured in `SharedAppState` — **DEBUG builds only**, since the bodies contain everything: user messages, file contents, tool I/O, anything pasted. The model in the filename identifies the agent (Smith and Brown normally run different models), which makes "did X reach Smith or only Brown?" a `grep -l` away.

This matters because several things are **never persisted anywhere else**:

- **Task briefings.** Not in `channel_log.jsonl`, not in `tasks.json`. Searching those for briefing content returns zero hits whether or not delivery worked — a check that cannot fail is not a check. (Verified 2026-07-27: `## Your working directories`, present in every briefing, appears 0 times in both files.)
- **Injected system corrections** and anything else appended straight to an agent's conversation.
- **Which agent actually received a message.** A public message from Brown is posted to the channel — so it appears in the transcript and in the UI — but `smithMessageFilter` drops it before Smith's context. The channel log shows it; Smith never saw it. Only the request logs distinguish these.

Other runtime state, for completeness: `~/Library/Application Support/AgentSmith/sessions/<uuid>/channel_log.jsonl` (the transcript as posted), `tasks.json` (task records), and `~/Library/Application Support/SwiftLLMKit/com.nuclearcyborg.AgentSmith/` (model catalog/config, not per-call).

## Architecture: the parts you must understand

### Per-session isolation (multi-window/tabs)

The app supports multiple concurrent sessions, each in its own window/tab. The wiring:

- `AgentSmithApp` owns a single `SharedAppState` (LLM catalog, memories, speech, billing) and a single `SessionManager`.
- `SessionManager` lazily creates one `AppViewModel` per `Session.id` and caches it. View models are *not* recreated on focus changes.
- Each `AppViewModel` owns its own `OrchestrationRuntime`, `TaskStore`, channel log buffer, attachments, and `PersistenceManager(sessionID:)`.
- `PersistenceManager` has two flavors: the root-flavored init writes legacy/global paths (used for migration + truly shared data like memories/usage/session list); `init(sessionID:)` writes under `AppSupport/AgentSmith/sessions/<uuid>/`. Don't mix them — session-scoped state must use the session-scoped manager.
- Window↔session focus is tracked via `WindowKeyObserver` (NSWindow key notifications) republishing onto `shared.focusedSessionID` so menu commands target the frontmost tab. Use `@SceneStorage("sessionID")` to remember which session a restored window belongs to; the cross-scene `pendingNewSessionIDs` queue hands fresh windows their intended session when "New Session" was the trigger.

When adding session-scoped state, put it on `AppViewModel` (not `SharedAppState`) and persist it via the session-scoped `PersistenceManager`.

### OrchestrationRuntime is an actor

`OrchestrationRuntime` (in `AgentSmithKit/Orchestration/`) is the actor that owns all `AgentActor` instances, the `MessageChannel`, the `TaskStore`, the `MemoryStore`, the `UsageStore`, the `MonitoringTimer`, and the `PowerAssertionManager`. It is constructed with pre-built `LLMProvider` instances per role (the app's `AppViewModel.start()` calls `LLMKitManager.makeProvider(for:)` to build them with Keychain-resolved API keys). All cross-agent coordination — spawning Brown, security evaluation, abort, auto-advance, terminated-agent archival — flows through this actor.

The runtime fires `@Sendable` callbacks (`onAbort`, `onProcessingStateChange`, `onAgentStarted`, `onTurnRecorded`, `onEvaluationRecorded`, `onContextChanged`) so the SwiftUI layer can observe activity without poking into actor state.

### Never drive behavior by matching free text in the transcript

**No control flow may depend on the wording of a tool's output, a message's content, or any other prose in the transcript.** That text is written for a model or for a human. It gets reworded, localized, given a variant for an edge case — and every reword silently changes behavior somewhere else, because a string comparison that stops matching does not throw, log, or fail a test.

This is not hypothetical; it is the most repeated defect in this codebase's history:

- `message_brown` (since renamed `notify_brown`) set `sentMessage` only when its output equalled `"Message sent to Brown."`. The tool had been reworded to name the task, so the match never fired and **Smith never parked after messaging a worker** — it kept acting instead of waiting for the reply. Found 2026-07-27, live for an unknown period.
- The same comparisons broke for **every message carrying an attachment**, because the attachment path returns a different sentence.
- `create_task`'s `result.contains("System is restarting")` was dead for the same reason.
- The parked-worker spin that started all of this was the same shape one level up: a gate keyed on the wrong property of a message instead of a typed discriminator.

**Instead:** the producer declares a typed fact and the consumer reads it.

- Tool caused something the run loop must react to → declare `successEffects` (`ToolEffect`) on the tool. See `AgentTool.swift`.
- Tool succeeded or failed → `ToolExecutionResult.succeeded`, never the output text.
- Message means something structural → `ChannelMessageKind`, never the content (below).

The one legitimate exception is a deliberately fuzzy heuristic over **model-authored** prose, where there is no typed signal to read because the model wrote the words — e.g. `detectActionClaimWithoutToolCall`, which notices Smith *claiming* it terminated an agent without calling the tool. Those must fail safe (a miss costs a correction, never a wrong action) and must never be the only thing standing between the system and a wrong state.

### Message kinds are typed, never bare strings

Every structural `ChannelMessage` carries a `messageKind` discriminator in its metadata, and readers key both display AND control flow off it. **These are never written or compared as string literals.** Use `ChannelMessageKind` (`AgentSmithKit/Channel/ChannelMessageKind.swift`):

- **Posting**: `metadata: ["messageKind": .kind(.toolRequest)]` — never `.string("tool_request")`.
- **Reading**: `message.kind == .toolRequest` — never unwrap `metadata?["messageKind"]` by hand. `ChannelMessage.kind` is the single accessor; `ChannelMessage.swift` and `ChannelMessageKind.swift` are the only files exempt from that rule.
- **Adding a kind**: add a static member to `ChannelMessageKind` and use it.

`ChannelMessageKind` is a **`String`-backed enum** (`case toolRequest = "tool_request"`). Because it is closed, `init(rawValue:)` returns nil for anything not listed — and rather than let that nil propagate and silently send every reader down the wrong branch, **`ChannelMessage.kind` traps on an unrecognized kind.** A missing case is a bug in the enum, not a data condition to absorb. `nil` from that accessor therefore means exactly one thing: the message carries no `messageKind` at all — with one derived exception: a kindless message carrying `securityDisposition` metadata answers `.securityReview`, because security-review rows were posted kindless for months before that kind existed (2026-08-05) and the persisted corpus is full of them. The derivation lives in the accessor (the one exempt file), never at read sites. **Completeness is a correctness requirement, not a tidiness one.**

The set that matters is *what has ever been written to disk*, not *what the current code emits*. Those differ, and grepping the sources does not close the gap: it misses kinds referenced in collections that never mention `messageKind` (`taskLifecycle` lives in a bare `Set` literal), and it cannot see **retired** kinds — no longer emitted anywhere, still sitting in the logs in quantity. `agent_online` occurs ~4,000 times and appears in no source file. A prior test that enumerated the surface "from a grep" listed 18 kinds when there were 37.

**So the case list was derived by scanning the persisted corpus** (~520 MB across `channel_log.jsonl`, `channel_log.json`, the `.old`/`.old2` rotations, `backups/`, and `sessions_removed_backup-*/`), unioned with what the sources emit. When adding a kind, add a case. **When retiring one, do not delete its case** — move it to the `// MARK: Retired` section, because the logs outlive the code that wrote them. Re-run the corpus scan if you suspect drift.

Four guard tests in `ChannelMessageKindTests.swift` enforce all of this: wire strings asserted against an independent literal table (renaming a case is free, changing a `rawValue` is a build failure); `allCases` checked against that table so a new case can't go unpinned; the observed-on-disk corpus checked to still decode; and a source scan over **both** targets that fails on any new bare `messageKind` literal or hand-rolled metadata unwrap. The type alone is a convenience; the guards are what keep the antipattern from coming back.

### Severity and the transcript filter

`MessageSeverity` (`info < warning < error`) is orthogonal to `ChannelMessageKind`; read it only through `ChannelMessage.severity` (unknown → `.error`, fail visible). `TranscriptFilter` has a floor (`alwaysShowAtOrAbove`, default `.warning`) and the order in `matches()` is load-bearing: `hideErrors` → scope → floor → noise. `TranscriptViewConfig` is ONE participant × activity relation; identity is the AUTHOR (`ChannelMessage.author` / `addressee`), a role becomes a participant only via `Sender.participant(for:)`, security verdicts filter by typed class, and a tool row's verdict icon is always shown. Don't re-enable hidden default groups to surface errors — that is the floor's job. Details: `docs/claude/transcript-filter.md`.

### An agent that goes quiet with a tool still failing must say so

`AgentActor.reportAbandonedToolFailures` runs at the idle transition and posts a user-addressed `.error` naming the tool, the count and the last error. The signal is **structural, never prose** — an unresolved entry in `toolFailureStreaks` when the run loop parks; a streak clears only when that tool SUCCEEDS. Do not replace this with a check on what the model wrote: the existing mid-streak correction already tells the model to "report the blocker" and the model ignored it, which is the whole reason this exists. The stop-threshold breaker reports BEFORE clearing the streak (otherwise the worst case is the only silent one), the no-evaluator block path records its outcome like every other blocked path, and "already reported" lives INSIDE `ToolFailureStreak` so it cannot outlive the streak it describes.

### Optional tool arguments: empty means ABSENT

**Some models emit every optional property on every call.** `gpt-5.6-sol` on the Codex endpoint does it unprompted — no `strict` flag, only `title`/`description` required, and it still sent `scheduled_run_at: ""`, `template_inputs: []`, `attachment_ids: []` on every `create_task`. A tool that pattern-matches on PRESENCE reads the sentinel as a deliberate value and rejects it, and **the caller cannot comply because it cannot stop sending the key.**

- Read every OPTIONAL argument through **`ToolArguments`** (`optionalString` / `optionalArray` / `optionalBool` / `optionalInt` / `optionalUUID`). A REQUIRED argument keeps `guard case` and keeps rejecting empty.
- **Opt-in per call site, never a blanket rule.** For some arguments empty IS the meaning — `FileEditTool`'s `new_string: ""` is a deletion. Normalizing centrally at the dispatch boundary would be a bug.
- **`optionalUUID` returns three cases, not two.** Absent and malformed demand opposite responses; collapsing to `UUID?` forces one behavior for both. The all-zero UUID reads as ABSENT — it is worse than `""` because it *parses*, and `list_tasks` accepted it and filtered to the children of a task that cannot exist.
- Two guard tests enforce this: an absolute one (no `if case` unwrap of an optional argument — there are none) and a ratchet on the `guard case` sites that read required arguments.
- `strict: true` is a per-TOOL flag on a function definition, not a request-level one, and this app sets it nowhere. It would have prevented the bug (its canonical unset value is `null`, which `AnyCodable.null` already handles), but it is a per-model capability requiring strict-valid schemas — a complement, never a substitute for reading arguments correctly.

### Tool model

`AgentTool` is the protocol every tool implements. Each role gets a fixed tool list assembled in its `*Behavior.swift` file (`SmithBehavior`, `BrownBehavior`, `SecurityAgentBehavior`). When adding a tool:

1. Implement it under `AgentSmithKit/Tools/`.
2. Add it to the appropriate behavior's `tools()` list — that's the only thing that grants access.
3. If it touches files, integrate with the per-agent `FileReadTracker` (FileEditTool requires a prior FileReadTool call on the same path).
4. If it's a destructive/side-effecting tool, expect `SecurityEvaluator` (Security Agent) to gate the call.

**Varying what a tool shows an agent.** Per role: override `description(for:)` / `parameters(for:)` (today only `manage_steps`, which shows `purge` to Smith alone). Per turn: override `definition(for:in:)` (today only `update_task`'s `completed` status choice — the rule is in `docs/claude/acceptance-validation.md`). All three are PROTOCOL REQUIREMENTS on purpose — an extension-only helper is statically dispatched through `any AgentTool`, so every override is silently ignored. That is exactly what happened from 2026-03 to 2026-10: Smith never saw `purge`, and fifteen Brown-only "security review" description suffixes never reached Brown (deleted 2026-10-04 as redundant with, and less accurate than, Brown's system prompt). Test an override through `any AgentTool`, not the concrete type.

**Worker tools, coordinator tasks and required capabilities (decided 2026-10-05, user).** The Security Agent scopes a worker's tools; only the USER overrides them (per task, and Settings › Tools). Smith cannot change a task's tools, and a global Never is absolute (`ToolPolicy.effectiveApprovedTools`). A worker can coordinate CHILD tasks (`create_child_task` / `wait_for_child_tasks`, linked by `AgentTask.coordinatorTaskID`, never `parentTaskID`); outcomes go to the coordinator through the notification broker, not Smith. `AgentTask.requiredCapabilities` lists abilities (never tool names), is written only through `TaskStore`, is locked by `requiredCapabilitiesLockReason`, and a change re-scopes the live worker. Details: `docs/claude/coordinator-tasks-and-capabilities.md`.

Brown's `BashTool` shells out via `/bin/bash -c` (sources the user profile — full PATH). There is no separate `shell` tool anymore.

### Worker pool

Worker pool: up to `maxConcurrentWorkers` tasks run concurrently (Settings "Max simultaneous tasks", default 4, 1–10), each with its own Brown. Capacity NEVER evicts a live worker — `run_task`/the play button refuse at capacity, `create_task` queues, and the race-free gate in `performStartTaskWithLiveSmith` (serialized on the lifecycle queue) pends any start that slips past the tool checks. Auto-advance fills free slots oldest-pending-first, including at cold boot. Coordinator-child overshoot and resume-at-capacity rules: `docs/claude/coordinator-tasks-and-capabilities.md`.

### Acceptance validation and the acceptance contract

Brown's `task_complete` → `.validating`; each criterion is judged independently on the `.validator` model by a custom (non-empty `validationPrompt`) or the shipped default evaluator — no registry, no stored validators. Rejections go straight back to Brown; rounds without new approvals fail the task at the limit; validator errors escalate to the USER. Validators are read-only; never hand routine review back to Smith. The contract is edited per criterion (`CriterionAction`), staleness is `ValidationRoundToken` checked inside the store, criteria are editable only when `Status.isValidationContractEditable`, a completed contract is immutable (follow-ups are successor tasks), and the optional user-acceptance gate has one writer (`TaskStore.editAcceptanceContract`). Details: `docs/claude/acceptance-validation.md`.

### LLM/provider configuration and model switching

API keys live in the Keychain only. A role's model is a per-session `ModelAssignment { providerID, modelID }` (shared config pool retired 2026-07-31; do not reintroduce `LLMConfiguration`), and tuning lives in the per-(role, model) override store. A live agent follows its role's model at a run-loop boundary (`scheduleModelChange`); a switch makes history portable via `ModelSwitchHistory.adapt`. Every retry sleep goes through `ProviderWaitBoard` — no bare sleep. Loading a session never deletes its assignments (`AgentAssignmentResolution.resolve`). Smith's compaction and task summaries never block other work. Details: `docs/claude/model-switching-and-llm-config.md`.

### Orchestration settings

`OrchestrationSettings` + sparse `OrchestrationSettingsOverride`, layered shipped → downloaded → app-wide → per-session; `applying` is the ONE merge, and the runtime reads a pushed snapshot and never loads files. Guiding rule (user, 2026-08-01): NEVER change the architecture of WHAT gets called; flags change IN-CALL behavior, and a disabled branch reports that it was disabled. Details: `docs/claude/orchestration-settings.md`.

### ChatGPT-subscription provider, effort, and model probes

`builtin.codex-chatgpt` speaks the Responses shape (`CodexResponsesProvider`) with credentials from `~/.codex/auth.json` — ask the kit (`providerHasCredential` / `modelListingCredential(for:)`), never the Keychain. Forced probes ask the kit for wire spellings; sweeps probe only what is new. General effort ≠ reasoning effort. Model-override sheets mutate only what they own, and every `ModelMetadataOverride` field needs a UI control. `LOCAL` is a distinct LiteLLM mapping, not `nil`. Deep Probe stays an explicit action and always runs the standard battery first. Details: `docs/claude/codex-chatgpt-provider-and-probes.md`.

### Persistence and storage

JSON files only (no database) under `~/Library/Application Support/AgentSmith/`. Per-session vs global boundaries are fixed; API keys are in the Keychain. Usage records are append-only JSONL — never rewrite earlier lines. Per-task cost and tokens have ONE source, `CostBoard.taskUsage`. Usage `taskID` attribution, retrieval scope, and the full path table: `docs/claude/persistence-and-storage.md`.

### Step plan and template inputs

`delete` is the single producer of `.removed`; tombstones are never resurrected, and wholesale `setSteps` callers must pass them back; `purge` is Smith-only and only for draft/template plans. Template substitution covers every authored field; rendering is LENIENT, authoring is STRICT; every write validates only the text it writes — there is deliberately no whole-task sweep. Details: `docs/claude/step-plan-and-template-inputs.md`.

### Inspector

Terminated agents are archived (`terminatedAgentArchive` / `archivedEvaluationRecords`) — keep that surface intact. Every LLM call site that records usage emits an `LLMCallEvent`. Inspector display state is derived in the model (`InspectorLiveState`); views watch nothing — don't add `.onChange` watchers back, and never write outputs inside `computeOutputs()`. The role-keyed surfaces are still current; the instance-keyed "Now" panel is planned, not built. The window's inspector is the app-owned `InspectorSidePane`, never SwiftUI's `.inspector` column (a platform layout-loop bug hung the app). Details: `docs/claude/inspector.md`.

### Task state events and task watches

Every live status change goes through ONE `TaskStore` writer, `applyStatus`, which emits a typed `TaskStatusTransition` validated by `TaskTransitionMatrix`. Don't bypass the writer or add a second notification path — add a subscriber. Subscriber effects are recorded in the status write and released only once durable; `TaskStore` is the single writer of `tasks.json`; never block the task-event consumer on a person. Details: `docs/claude/task-events-and-watches.md`.

## Conventions specific to this repo

Model-metadata and probe conventions (`LOCAL` mapping, Standard vs Deep Probe): `docs/claude/codex-chatgpt-provider-and-probes.md`. The long-form rationale for the one-line invariants below marked † is in `docs/claude/reliability-conventions.md`.

- All actor state mutation must happen inside the actor; UI observers run via the `@Sendable` callbacks listed above. Don't add `MainActor` reach-ins from inside actors.
- † `AgentActor.conversationHistory` has a single writer — the run loop; external `.user` injections are queued (`pendingInjectedMessages`), never appended directly.
- Smith's prompt explicitly forbids it from answering the user — every request becomes a task assigned to Brown. Don't add tools that let Smith do the *work* directly (bash/file/process execution). Orchestration-side authoring of a task's contract is Smith's job, not "work": Smith owns acceptance criteria (`set_acceptance_criteria`) and the step plan (`manage_steps` with `task_id`) — this is deliberate, not a violation of the no-work rule. Both are gated as described in the roles section above.
- † The Security Agent is an unconditional chokepoint: every tool call runs through `executeWithApproval`, which DENIES when no evaluator is configured; per-emitter review toggles skip the verdict, never the visibility.
- † What varies is verdict COST, not routing: `SecurityEvaluator.autoApprovedToolsByRole` is hardcoded and fail-closed — never make it user-configurable.
- † The Security Agent provider is REQUIRED regardless of the review toggles.
- † Every LLM call retries through the one `LLMRetryPolicy` — no bespoke retry loops.
- † An unusable worker model puts tasks ON HOLD (`.interrupted`, "on hold" not "paused"), never fails them; the breaker gates every start in `passesProviderOutageGate`.
- † A server's own error object is surfaced on the FIRST occurrence; three memory refusals in a row shrink the context once.
- † A worker's task binding is `taskForAgent(agentID:)`, never "whatever is running."
- † Address a worker by TASK (`liveWorkerID(taskID:)`), never by role.
- † A worker takes in only operational notices about itself (`OrchestrationRuntime.workerAccepts`).
- † There is ONE worker briefing composer: `OrchestrationRuntime.composeBrownTaskBriefing`.
- † In the app target, only `@concurrent` means off-main — `async` and `nonisolated` don't.
- † No continuously-repeating SwiftUI animation; spin with `LayerSpinningSymbol`.
- Debug/recovery/sanitize utilities should be manually triggered (CLI/menu), never wired into normal startup or hot paths.
- `__PUBLIC_REPO` (an empty file at the repo root) marks this as a public repo. Don't commit secrets, internal hostnames, or customer data.
- `SessionManager.loadSessions()` no longer migrates legacy single-session data — that migration was retired in 2026-04 once the install base had moved over. An empty session list now bootstraps a single "Default" session via `bootstrapDefaultSession()`. Preserved here so anyone reading old commit messages doesn't try to revert.
- Wakes scheduled by an agent fire on the same agent's run loop today. There is **no** cross-window/cross-session routing — a wake belonging to a task running in another tab still fires on the originating agent. ROADMAP.md captures the design for the cross-window routing that was requested; until it lands, callers can rely on wakes firing in-place but should be aware they don't follow the task across windows.

## Reference docs — read before touching X

- `docs/claude/transcript-filter.md` — message severity, the transcript filter, presets, verdict classes, filter migration.
- `docs/claude/coordinator-tasks-and-capabilities.md` — worker tool grants/policy, coordinator (child) tasks, admission/drain, required capabilities, re-scoping.
- `docs/claude/acceptance-validation.md` — validators, evaluator resolution, validation flow, metrics ledger, acceptance-contract edits, user-acceptance gate.
- `docs/claude/model-switching-and-llm-config.md` — model assignments/overrides, live retune and model switch, compaction and task summaries, `ProviderWaitBoard`, assignment loading.
- `docs/claude/orchestration-settings.md` — orchestration settings layers and OFF behaviors.
- `docs/claude/codex-chatgpt-provider-and-probes.md` — `builtin.codex-chatgpt`, effort/reasoning UI, model-override sheets, capability probes, `LOCAL` mapping, Standard/Deep Probe.
- `docs/claude/persistence-and-storage.md` — on-disk paths, global vs per-session files, usage JSONL, usage attribution, retrieval scope, per-task cost.
- `docs/claude/step-plan-and-template-inputs.md` — `manage_steps` semantics and `{{placeholder}}` template inputs.
- `docs/claude/inspector.md` — inspector archive, data sources, model-derived display state.
- `docs/claude/task-events-and-watches.md` — task status writer, subscribers, durable effects, watches, holds.
- `docs/claude/reliability-conventions.md` — the long-form conventions marked † above (history writer, security chokepoint, retries, provider outages, worker addressing, concurrency, animation).
