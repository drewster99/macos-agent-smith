# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Agent Smith is a macOS app (Swift 6 / SwiftUI, macOS 15+) that orchestrates a small fixed cast of LLM-driven agents working together on user-supplied tasks. The roles are not abstract — they are baked into `AgentRole` and the codebase assumes all four exist:

- **Smith** — orchestrator. Talks to the user, creates tasks (with acceptance criteria), spawns/supervises Brown, and resolves validation escalations. Never does work itself, and does NOT review routine submissions — the acceptance-validation system does (see below).
- **Brown** — single worker spawned per task. Holds the bash/file/process tools and owns the task's step list (`manage_steps`).
- **Security Agent** — silent security gatekeeper that runs alongside Brown. Returns plain-text `SAFE/WARN/UNSAFE/ABORT` verdicts on Brown's tool calls (text-based, *not* tool calls — see `SecurityAgentBehavior.swift` and `SecurityEvaluator.swift`).
- **Summarizer** — summarizes completed/failed tasks (`TaskSummarizer`).

The full design history, rationale, and completed/planned features live in `ROADMAP.md` at the repo root — read it before proposing architectural changes. Per the global rules, completed roadmap items stay in the file; mark them ✅ rather than deleting.

## Repo layout

- `AgentSmith/` — the Xcode app target (`AgentSmith.xcodeproj`, scheme `AgentSmith`). Contains the SwiftUI layer (`Views/`, `ViewModels/`), the `ExportDefaults` CLI target, and bundled `Resources/defaults.json`.
- `AgentSmithPackage/` — local Swift package `AgentSmithKit` containing the entire engine: `Agents/`, `Channel/`, `Evaluation/`, `LLM/`, `Memory/`, `Orchestration/`, `Persistence/`, `Tasks/`, `Tools/`, `Usage/`. The app depends on this package; almost all logic lives here.
- `AgentSmithPackage/Tests/AgentSmithTests/` — Swift Testing (`@Suite` / `@Test`) tests for tools, channel, and usage aggregation.
- `SafetySystemTesting/` — isolated harness and scripts for exercising the safety/gatekeeper system. Self-contained; has its own README.
- `scripts/` — one-off Python utilities (e.g. `backfill_tool_calls.py`).
- `ROADMAP.md` — long-form plan + completed-work log. Authoritative source for "why is it this way."
- `ROADMAP_implement_tabs.md` — historical sub-plan for the multi-session tab work.

## Package dependencies (versioned git)

`AgentSmithPackage/Package.swift` depends on versioned git releases (NOT path-based; siblings checkouts are for development of those packages only):

- `drewster99/swift-llm-kit` (SwiftLLMKit — providers, model configs, Keychain API key storage, `LLMKitManager`, `ModelConfiguration`, `ProviderAPIType`). Releasing a change there means: change → build → commit → push → tag → push tag → bump the `from:` version here.
- `drewster99/swift-semantic-search` (SemanticSearch — `SemanticSearchEngine` used by `MemoryStore`)
- `modelcontextprotocol/swift-sdk` (MCP client support)

## Building and running

Always build via the xcode-mcp-server tools — never `xcodebuild`, `swift build`, or `swift package build`. The app target requires Xcode (Assets.xcassets, entitlements, Info.plist).

- Build: `mcp__xcode-mcp-server__build_project --project_path /Users/andrew/cursor/macos-agent-smith/AgentSmith/AgentSmith.xcodeproj` (scheme `AgentSmith`). (The repo is also reachable as `~/Documents/ncc_source/cursor/macos-agent-smith` — same directory.)
- Run the app: `mcp__xcode-mcp-server__run_project_unmonitored` (or `run_project_until_terminated`) against the same project path, then `stop_project` + `get_runtime_output`. Do NOT use `run_project_with_user_interaction` — it blocks on a dialog click.
- Run tests: **two commands required, not one.**
  - `mcp__xcode-mcp-server__run_project_tests` against `AgentSmith.xcodeproj` covers any tests that live in the .xcodeproj test bundle. Today there are none here, but it's the right hook if .xcodeproj-side tests ever get added.
  - **Package tests** (everything under `AgentSmithPackage/Tests/AgentSmithTests/` — the bulk of the suite) must be run manually from the terminal:
    ```
    cd /Users/andrew/cursor/macos-agent-smith/AgentSmithPackage && swift test --skip MemoryStoreIntegrationTests
    ```
    Why two commands: the AgentSmith scheme's auto-created test plan does not include the local package's test target (Xcode 16 does not auto-discover test targets from referenced local Swift packages). Adding an explicit `.xctestplan` was attempted and reverted because Xcode's IDE-side index couldn't resolve the package test target reliably; the terminal command sidesteps that entirely.
  - `MemoryStoreIntegrationTests` is skipped above because it requires Xcode's build pipeline to compile MLX Metal shaders (`swift test` alone can't). To run it, run the file's documented `xcodebuild` invocation by hand — but ask the user first; the project rule is xcode-mcp-only for builds.
  - To run a subset, use `--filter`, e.g. `swift test --filter GhToolArgsFilterTests`.
- After non-trivial changes, follow the smoke-test pattern noted in user memory (run app ~15s, screenshot, check logs).

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

### Tool model

`AgentTool` is the protocol every tool implements. Each role gets a fixed tool list assembled in its `*Behavior.swift` file (`SmithBehavior`, `BrownBehavior`, `SecurityAgentBehavior`). When adding a tool:

1. Implement it under `AgentSmithKit/Tools/`.
2. Add it to the appropriate behavior's `tools()` list — that's the only thing that grants access.
3. If it touches files, integrate with the per-agent `FileReadTracker` (FileEditTool requires a prior FileReadTool call on the same path).
4. If it's a destructive/side-effecting tool, expect `SecurityEvaluator` (Security Agent) to gate the call.

Brown's `BashTool` shells out via `/bin/bash -c` (sources the user profile — full PATH). There is no separate `shell` tool anymore.

### Acceptance validation (replaces Smith's routine review)

`AgentSmithKit/Evaluation/` holds the evaluator framework: `EvaluatorDefinition` (data-defined evaluation functions), `EvaluationRunner` (render slots → LLM → allowlisted tool rounds → grammar parse), `EvaluatorRegistry` (built-ins from `EvaluatorDefaults.builtInDefinitions` — always the current shipped version, NOT editable, duplicate under a new name to customize — merged with user-authored `evaluators/*.json` files; a file shadowing a built-in name is a visible load failure, and all load failures are visible entries, never silent skips), and `TaskValidationCoordinator` (an `OrchestrationRuntime` extension). Smith authors custom evaluators through `EvaluatorDefaults.makeCustomDefinition` (via the `define_validator` tool, or `custom_validator` inline on a criterion): Smith supplies only the judgment/enumeration prompt while the SYSTEM supplies the output grammar, standard input slots, the read-only evidence-tool cap, and limits — keep that division; never let an authored definition carry its own tool list or grammar.

The flow: Brown's `task_complete` puts the task in `.validating` and each acceptance criterion is judged independently (`ACCEPT` is sticky; `WAIVE` only when the criterion is waivable; `ERROR` retries once then escalates — never counted as a rejection). Rejections send a punch list DIRECTLY back to Brown. Convergence is judged by PROGRESS, not an absolute round cap: `maxValidationStallRounds` (3) CONSECUTIVE rejection rounds with nothing newly settled FAIL the task — never parked on Smith. Only machine-can't-judge outcomes (validator errors, unconfigured registry) escalate to `.awaitingReview`, where Smith's `review_work` is the resolution tool. Counters reset on `review_work` reject, `run_task`'s failed-task auto-reset, and any criteria edit (an edited contract gets a fresh budget). Validation is idempotent and restartable — everything lives on the task (`acceptanceCriteria`, `steps`, `validation` ledger with pinned definition bodies); `.validating` tasks re-enqueue at cold boot. Don't hand routine review back to Smith, and don't make validators mutate anything — they hold the read-only evidence quartet (file_read, directory_listing, grep, glob).

Worker pool: up to `maxConcurrentWorkers` tasks run concurrently (Settings "Max simultaneous tasks", default 4, 1–10), each with its own Brown. Capacity NEVER evicts a live worker — `run_task`/the play button refuse at capacity, `create_task` queues, and the race-free gate in `performStartTaskWithLiveSmith` (serialized on the lifecycle queue) pends any start that slips past the tool checks. Auto-advance fills free slots oldest-pending-first, including at cold boot.

### LLM/provider configuration

LLM provider/model state is owned by `SwiftLLMKit.LLMKitManager` (`@Observable`, on `SharedAppState`). API keys are stored in Keychain only; `ModelConfiguration` does not carry secrets. At runtime, `OrchestrationRuntime` is constructed with `(providers, configurations, providerAPITypes, agentTuning)` dictionaries keyed by `AgentRole`. The legacy `LLMConfiguration` struct is gone — do not reintroduce it.

`AppDefaults` (schema v2, `defaults.json` bundled in app resources) seeds first-launch state. The `ExportDefaults` CLI target exists to regenerate `defaults.json` from the current user's installed configuration. UserDefaults-set values always win over bundled defaults.

### Persistence boundaries

- Per-session: channel log, tasks, attachments, session-local state JSON. Path: `AppSupport/AgentSmith/sessions/<uuid>/`.
- Global: `memories/`, task summaries, `UsageRecord` history, model configurations (via SwiftLLMKit), session list. Path: `AppSupport/AgentSmith/`.
- Keychain: provider API keys (service `com.agentsmith.SwiftLLMKit.com.nuclearcyborg.AgentSmith`, account = provider ID).

Every `UsageRecord` and `ChannelMessage` is stamped with `OrchestrationRuntime.currentSessionID` (a fresh UUID per `start()` call) so analytics can group by run without timestamp joins.

### Inspector / archive of terminated agents

When an agent terminates, its conversation history, LLM turn records, and Security Agent evaluations are snapshotted into `terminatedAgentArchive` / `archivedEvaluationRecords` on `OrchestrationRuntime` before the actor is dropped. The `AgentInspectorWindow` UI reads both live and archived agents through this surface — keep it intact when refactoring agent lifecycle code.

## Conventions specific to this repo

- All actor state mutation must happen inside the actor; UI observers run via the `@Sendable` callbacks listed above. Don't add `MainActor` reach-ins from inside actors.
- Smith's prompt explicitly forbids it from answering the user — every request becomes a task assigned to Brown. Don't add tools that let Smith do work directly.
- Security Agent uses **text-based verdicts** (`SAFE/WARN/UNSAFE/ABORT`), not tool calls. This is deliberate (see memory/roadmap). Don't "improve" it by giving Security Agent tool-call evaluation.
- Debug/recovery/sanitize utilities should be manually triggered (CLI/menu), never wired into normal startup or hot paths.
- `__PUBLIC_REPO` (an empty file at the repo root) marks this as a public repo. Don't commit secrets, internal hostnames, or customer data.
- `SessionManager.loadSessions()` no longer migrates legacy single-session data — that migration was retired in 2026-04 once the install base had moved over. An empty session list now bootstraps a single "Default" session via `bootstrapDefaultSession()`. Preserved here so anyone reading old commit messages doesn't try to revert.
- Wakes scheduled by an agent fire on the same agent's run loop today. There is **no** cross-window/cross-session routing — a wake belonging to a task running in another tab still fires on the originating agent. ROADMAP.md captures the design for the cross-window routing that was requested; until it lands, callers can rely on wakes firing in-place but should be aware they don't follow the task across windows.
