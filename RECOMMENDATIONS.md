# Agent Smith Project - Swift/SwiftUI Expert Review

**Date of review:** 2026-05-05

## Executive Summary

Agent Smith is already a thoughtful and unusually mature Swift 6/macOS codebase: it uses actors pervasively, has targeted regression tests, has moved several hot paths away from unsafe persistence races, and contains many comments documenting hard-won concurrency fixes. The main risks now are platform-foundation risks rather than simple bugs: plaintext/verbose LLM data handling, heavy reliance on unstructured tasks and actor-reentrant mutable state, approximate context management, monolithic JSON persistence, and UI/data models that will become brittle as the app grows into MCP, Skills, local models, document pipelines, scheduled automations, and accessibility control.

## Top 20 Findings

### 1. Full LLM Request/Response Logging Is Enabled by Default and Writes Sensitive Conversation Data to Disk

- **Severity:** Critical
- **Category:** Security / Privacy / LLM Handling
- **Location:**
  - `AgentSmith/AgentSmith/ViewModels/SharedAppState.swift:252-255`
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/LLMRequestLogger.swift:6-14, 41-80, 82-131`
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/AnthropicProvider.swift:45-57, 59-62`
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/OpenAICompatibleProvider.swift:72-84, 86-89`
- **Description:** `SharedAppState.performLoadPersistedState()` unconditionally enables `llmKit.verboseLogging`, `ModelFetchService.verboseLogging`, and `ModelMetadataService.verboseLogging`. Provider implementations then write full request and response bodies to `$TMPDIR/AgentSmith-LLM-Logs`. Those bodies contain user messages, task descriptions, file contents, tool results, memory context, and potentially pasted secrets. HTTP error paths also log response bodies with public privacy.
- **Impact:** This creates a persistent local privacy leak and makes future document handling, messaging integrations, app control, and MCP/Skills particularly risky. Sensitive work product, personal messages, credentials accidentally pasted into chat, file contents, and tool outputs can remain on disk outside the app’s normal data-management model.
- **Recommendation:** Default verbose LLM logging to off. Add a Settings-controlled debug toggle with an explicit privacy warning and retention period. Redact or omit message bodies, tool outputs, file contents, API headers, and image/document payloads by default. Store debug logs under Application Support with controlled cleanup rather than `$TMPDIR`, or preferably use `Logger` summaries only. Add tests asserting verbose logging is off in production/default startup.
- **Effort:** Medium

**TODO: Continue logging as-is in Debug builds. Release builds default to completely off, but add a user setting to indicate logging level for LLM calls: None, errors only, basic (errors only + endpoint calls time, response http status code, timestamp and elapsed time) , complete (same as now).**
---

### 2. Arbitrary Bash Execution Depends Primarily on an LLM Security Gate Instead of Deterministic Policy

- **Severity:** Critical
- **Category:** Security / Architecture / App Control
- **Location:**
  - `AgentSmithPackage/Sources/AgentSmithKit/Tools/BashTool.swift:3-6, 40-77`
  - `AgentSmithPackage/Sources/AgentSmithKit/Agents/SecurityEvaluator.swift:88-93, 241-300`
  - `AgentSmithPackage/Sources/AgentSmithKit/Agents/AgentActor.swift:1240-1280, 1436-1453`
- **Description:** `BashTool` executes arbitrary commands through `/bin/bash -l -c` after Brown receives model-driven approval. The `SecurityEvaluator` is itself an LLM with retries and parsing heuristics; it is not a deterministic sandbox, allowlist, or capability system. The code does have a strong process runner and a review flow, but a prompt-injected or misconfigured evaluator can still approve high-impact commands.
- **Impact:** As the platform adds MCP servers, Skills, messaging, local file/document ingestion, and Accessibility app control, the blast radius of a single bad tool approval grows dramatically. A model mistake can mutate or exfiltrate user data, spawn processes, or run network commands.
- **Recommendation:** Keep Jones as an advisory layer, but add deterministic enforcement beneath it: per-tool capability declarations, path allow/deny policies, dry-run classifications, side-effect levels, command allowlists for common operations, blocked shell metacharacter classes where feasible, explicit user approval for high-risk classes, and sandboxed execution for commands that do not need full user privileges. Treat LLM approval as necessary but not sufficient.
- **Effort:** Large

---

### 3. Public Tool Surface Uses `fatalError` Defaults for Missing Wiring

- **Severity:** Critical
- **Category:** Error Handling / Safety / Architecture
- **Location:**
  - `AgentSmithPackage/Sources/AgentSmithKit/Agents/SecurityEvaluator.swift:189-199`
  - `AgentSmithPackage/Sources/AgentSmithKit/Tools/AgentTool.swift:262-271`
- **Description:** `SecurityEvaluator` and `ToolContext` provide default closure implementations that call `fatalError` when execution tracking is not configured. The comments intentionally use crash-fast behavior to catch wiring bugs, but these are production code paths in the agent platform.
- **Impact:** A future runtime, MCP server, Skill host, test harness, or extension can crash the entire app by constructing these types without every closure wired. Crashing is especially bad for scheduled tasks and long-running automations because it can lose in-memory context and interrupt user work.
- **Recommendation:** Replace `fatalError` defaults with required initializer parameters where the closures are mandatory. If compatibility requires defaults, return explicit `.failure`/`SecurityDisposition(approved: false, message: ...)` and log a fault instead of terminating. Add a dedicated runtime assembly test that verifies every production `ToolContext` and `SecurityEvaluator` dependency is present.
- **Effort:** Small

---

### 4. The Codebase Still Violates the User’s “No Force Unwrap” Rule in Production Code

- **Severity:** High
- **Category:** Code Quality / Safety
- **Location:**
  - `AgentSmithPackage/Sources/AgentSmithKit/Orchestration/OrchestrationRuntime.swift:32-34`
  - `AgentSmithPackage/Sources/AgentSmithKit/Tools/CreateTaskTool.swift:247`
  - `AgentSmithPackage/Sources/AgentSmithKit/Usage/UsageAggregator.swift:88-91`
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/OllamaProvider.swift:26-51`
- **Description:** Production code still uses force unwraps/force tries for UUID literals, optional task references, timestamp comparisons, and regex construction. Some are probably safe today, but they directly violate the stated project rule: never use force unwrapping without explicit approval.
- **Impact:** This weakens project consistency and leaves avoidable crash points in code that will be copied as patterns into future features. In an agent platform, “impossible” assumptions tend to become possible when new providers, tasks, Skills, or migration data enter the system.
- **Recommendation:** Replace literal force unwraps with static validated constants initialized through `guard` plus non-crashing fallback, or with throwing factory functions. Replace `blockingTask!` with `guard let blockingTask`. Replace timestamp force unwraps with tuple accumulation or guarded local variables. Replace `try! NSRegularExpression` with static factory helpers that return `Result` or fail tests at startup rather than production runtime.
- **Effort:** Small

---

### 5. The Codebase Still Uses `try?` Broadly in Production, Including Places That Hide Data and Parsing Failures

- **Severity:** High
- **Category:** Error Handling / Code Quality
- **Location:**
  - `AgentSmithPackage/Sources/AgentSmithKit/Tools/GrepTool.swift:199-202`
  - `AgentSmithPackage/Sources/AgentSmithKit/Tools/FileReadTool.swift:228-230`
  - `AgentSmithPackage/Sources/AgentSmithKit/Tools/RunAppleScriptTool.swift:103`
  - `AgentSmithPackage/Sources/AgentSmithKit/Agents/SecurityEvaluator.swift:740, 828, 897, 951`
  - `AgentSmithPackage/Sources/AgentSmithKit/Memory/MemoryEntry.swift:103-109`
  - `AgentSmithPackage/Sources/AgentSmithKit/Memory/TaskSummaryEntry.swift:54-64`
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/LLMRequestLogger.swift:70, 92, 114-115`
- **Description:** Several production paths use `try?` to collapse real failure causes into `nil` or fallback behavior. Some comments justify this as best-effort parsing, but the user’s explicit rule is stricter: never use `try?` without approval. Memory and task-summary decoding silently converts legacy or malformed embeddings into empty vectors, disabling semantic search for those entries.
- **Impact:** Silent failures make debugging difficult and can degrade core features without visible errors. Search quality can drop to keyword-only, grep can skip files without explaining why, AppleScript result encoding can silently fall back, and security parsing can conceal malformed metadata.
- **Recommendation:** Replace `try?` with `do/catch` and explicit degradation paths. For tolerated legacy formats, decode each known shape intentionally and log migration status. For best-effort debug logging, catch and log why logging failed. Add a style guard test scanning production sources for `try?` and requiring documented, reviewed exceptions if any remain.
- **Effort:** Medium

**TODO: FIX ALL POINTS**
---

### 6. Actor-Reentrant Memory Updates Can Overwrite Newer State After Suspension Points

- **Severity:** High
- **Category:** Concurrency / Data Safety
- **Location:**
  - `AgentSmithPackage/Sources/AgentSmithKit/Memory/MemoryStore.swift:149-180`
  - `AgentSmithPackage/Sources/AgentSmithKit/Memory/MemoryStore.swift:125-142`
- **Description:** `MemoryStore.update(id:content:tags:updatedBy:)` reads `existing`, then awaits `engine.embed(newContent)`, then writes a reconstructed entry based on the stale `existing` snapshot. Because actor methods are reentrant at `await`, another update or delete can occur while the embedding is running.
- **Impact:** Concurrent memory edits, consolidation, user edits, and agent saves can overwrite each other. This becomes more likely as multiple sessions, MCP servers, Skills, scheduled jobs, and background summarizers write to the shared memory corpus.
- **Recommendation:** Account for actor reentrancy explicitly. After every suspension point, re-read the current entry and merge against current state, or use a per-entry revision number / compare-and-swap check. If the entry was deleted while embedding, abort the update. If tags changed while content was embedding, merge tag updates rather than restoring stale tags.
- **Effort:** Medium

**TODO: DATA INTEGRITY ISSUE - FIX IMMEDIATELY**
---

### 7. Shared Memory and Task Summary Embeddings Are Persisted as Monolithic Plaintext JSON Without Robust Migration or Recovery

- **Severity:** High
- **Category:** Persistence / Scalability / Privacy
- **Location:**
  - `AgentSmithPackage/Sources/AgentSmithKit/Persistence/PersistenceManager.swift:202-232`
  - `AgentSmithPackage/Sources/AgentSmithKit/Memory/MemoryEntry.swift:3-10, 103-109`
  - `AgentSmithPackage/Sources/AgentSmithKit/Memory/TaskSummaryEntry.swift:3-8, 54-64`
- **Description:** Memories and task summaries are saved as full-array JSON files. Legacy embedding shapes decode to empty vectors rather than going through an explicit migration. There is no schema version field, per-record migration status, backup/rollback strategy, or corruption quarantine.
- **Impact:** A partial corruption or schema mismatch can degrade or block the entire corpus. Empty embeddings silently harm semantic search. As memory volume grows, rewriting entire JSON arrays becomes expensive and increases the chance of last-writer-wins data loss.
- **Recommendation:** Introduce a versioned persistence layer for memories and summaries. Prefer SQLite/SwiftData or append-only JSONL with compaction. Store schema version and embedding model version per record. Add migrations for legacy embedding shapes and a re-embedding queue for empty/stale vectors. Keep backup snapshots before destructive migrations.
- **Effort:** Large

**TODO: CONSIDER MIGRATION TO DATABASE**
---

### 8. Conversation Logs, Tasks, Memories, Usage Records, and Attachments Are Stored Plaintext Without an App Privacy Model

- **Severity:** High
- **Category:** Security / Privacy / Data Handling
- **Location:**
  - `AgentSmithPackage/Sources/AgentSmithKit/Persistence/PersistenceManager.swift:7-18, 118-180, 202-264, 266-312`
  - `AgentSmithPackage/Sources/AgentSmithKit/Channel/AttachmentRegistry.swift:18-21, 118-165`
- **Description:** The persistence layer stores channel logs, task descriptions/results, timer events, memories, task summaries, usage records, model overrides, and attachment files under Application Support as plaintext JSON/files. API keys are correctly in Keychain, but user-generated and agent-generated content does not have retention, encryption, export/delete, or privacy classification.
- **Impact:** The planned roadmap includes messaging integrations, full document handling, audio/video/images/PDFs/Word docs, app control, and local/private data. Plaintext persistence makes accidental disclosure, backup leakage, and forensic recovery much easier.
- **Recommendation:** Define a data-classification model now: credentials, private user content, tool outputs, debug logs, attachments, usage analytics, and derived embeddings. Add retention controls, “delete all session data,” per-session export/delete, optional encryption-at-rest for sensitive stores, and clear UI explaining what is persisted. Consider excluding transient debug logs and large attachments from backups where appropriate.
- **Effort:** Large

---

### 9. `Task { ... }` Is Used Widely as Fire-and-Forget Without a Standard Error/Cancellation Policy

- **Severity:** High
- **Category:** Concurrency / Error Handling
- **Location:**
  - `AgentSmith/AgentSmith/AgentSmithApp.swift:32-37, 74-78, 299, 336`
  - `AgentSmith/AgentSmith/ViewModels/SessionManager.swift:106`
  - `AgentSmith/AgentSmith/ViewModels/AppViewModel.swift:391-396, 529-577, 590-626, 735-736, 826, 1298-1329`
  - `AgentSmithPackage/Sources/AgentSmithKit/Orchestration/OrchestrationRuntime.swift:834-846, 853-874, 881-884, 1208-1212, 1712-1722, 1846-1849`
  - `AgentSmithPackage/Sources/AgentSmithKit/Agents/AgentActor.swift:508-518, 2591-2596, 2663-2668, 2783-2788`
- **Description:** The project intentionally uses many unstructured tasks for UI actions, callbacks, persistence enqueueing, channel subscription delivery, timer event recording, and runtime restarts. Many are non-throwing today, but the pattern creates no uniform place to handle future thrown errors, cancellation, lifecycle ownership, or task leakage. The code even comments at `OrchestrationRuntime.swift:834-839` that if calls later throw they must be caught, which is easy to miss.
- **Impact:** Future feature additions will add throwing operations to these closures. Without a standard helper, errors will disappear, cancellation will be inconsistent, and tasks can outlive their owning session/runtime. This is especially risky for scheduled tasks, app-control automation, MCP calls, and long-running local model work.
- **Recommendation:** Add a small `TaskRunner`/`FireAndForget` utility with named tasks, owner cancellation, `do/catch`, logging, and optional UI error reporting. Use structured concurrency where possible, store task handles for lifecycle-bound work, and add a style guard that discourages raw `Task {}` except in approved wrappers.
- **Effort:** Medium
**TODO: EVALUATE EACH POINT OF USE ON A CASE-BY-CASE BASIS - RECOMMENDATIONS ABOVE ARE GOOD**
---

### 10. Context Management Uses Approximate Character Heuristics Instead of Provider Tokenizers and Explicit Budgets

- **Severity:** High
- **Category:** LLM Architecture / Scalability / Reliability
- **Location:**
  - `AgentSmithPackage/Sources/AgentSmithKit/Agents/AgentActor.swift:177-180, 752-758, 2570-2587, 2625-2668, 2671-2790`
  - `AgentSmithPackage/Sources/AgentSmithKit/Memory/MemoryStore.swift:201-221, 224-245`
- **Description:** Context pruning and rebuild logic estimate tokens from characters (`estimatedCharacterCount`, `apiOverheadChars`, and divisions by approximate ratios). The code also embeds full task result/commentary/update text with “No length caps” for task summaries. There is no provider-specific tokenizer budget, no exact accounting for images/documents/tools/system prompts, and no central context policy.
- **Impact:** The app can still hit context overflows, over-prune useful context, or pay excessive token costs. Full document handling, images, PDFs, Word documents, audio transcripts, MCP tool outputs, and local LLMs with smaller windows will amplify this.
- **Recommendation:** Build a central `ContextBudgeter`: provider/model-specific tokenizers where available, conservative fallback estimators, per-message token accounting, image/document cost estimates, tool-definition overhead accounting, and explicit budgets for system prompt, task state, memories, prior tasks, attachments, and recent dialogue. Expose token counts in the inspector.
- **Effort:** Large
**INVESTIGATE FURTHER. A FIRST STEP COULD BE TO USE TOKEN COUNTS WE ALREADY RECEIVE BACK FROM RESPONSES TO AUGMENT OR REPLACE THE CURRENT METHOD**
---

### 11. LLM Provider Abstraction Is Too Chat-Completions-Centric for the Planned Roadmap

- **Severity:** High
- **Category:** LLM Architecture / Scalability
- **Location:**
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/LLMProvider.swift:3-20, 23-45`
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/OpenAICompatibleProvider.swift:37-92, 95-175`
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/AnthropicProvider.swift:28-66, 68-142`
  - `swift-llm-kit/Sources/SwiftLLMKit/Models/PreparedRequest.swift:3-18`
- **Description:** `LLMProvider.send` returns one full `LLMResponse` and takes only messages/tools/max-output override. It does not model streaming events, structured response schemas, tool-choice controls, provider capabilities at call time, cancellation metadata, multimodal document parts beyond the current image support, computer-use/action APIs, or local model backends with different prompting requirements. `PreparedRequest` exists but is not the main abstraction and carries `[String: Any]` with `@unchecked Sendable`.
- **Impact:** Adding unlimited agents from any service, local LLM support, full documents, MCP, Skills, and app-control APIs will force provider-specific branches throughout the agent layer unless the abstraction evolves now.
- **Recommendation:** Introduce a richer request/response layer: `LLMRequest`, `LLMEvent` streaming, `LLMCapabilitySet`, `ToolPolicy`, `ResponseFormat`, `MediaPart`, `ProviderAdapter`, and structured usage/cost data. Move provider quirks into adapters and keep `AgentActor` provider-agnostic.
- **Effort:** Large

---

### 12. Network Layer Lacks Centralized Retry, Rate-Limit, Backoff, and Request Classification

- **Severity:** Medium
- **Category:** Networking / Reliability / Performance
- **Location:**
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/LLMProvider.swift:33-45`
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/OpenAICompatibleProvider.swift:77-90`
  - `swift-llm-kit/Sources/SwiftLLMKit/Providers/AnthropicProvider.swift:50-63`
  - `swift-llm-kit/Sources/SwiftLLMKit/SwiftLLMKit.swift:426-535, 622-671`
  - `AgentSmithPackage/Sources/AgentSmithKit/Agents/AgentActor.swift:837-899`
- **Description:** Providers issue `URLSession.data(for:)` directly and throw HTTP errors. `AgentActor` applies broad exponential backoff after failures, but the provider layer does not centrally parse `Retry-After`, rate-limit headers, transient network errors, provider-specific overload signals, or idempotency/retry classes.
- **Impact:** Multiple agents and future unlimited agents can stampede providers or local servers. Bad retry timing wastes money/tokens, delays tasks, and can cause avoidable failures. Model catalog refresh also runs provider fetches sequentially and lacks shared rate-limit coordination.
- **Recommendation:** Add a network client layer with request classification, per-provider concurrency limits, retry policies, `Retry-After` handling, exponential backoff with jitter, circuit breakers, and observability. Feed retry/backoff status to the UI/inspector.
- **Effort:** Medium

---

### 13. Persistence Is Actor-Isolated but Performs Large Synchronous File I/O and Whole-File Rewrites

- **Severity:** Medium
- **Category:** Performance / Persistence / Scalability
- **Location:**
  - `AgentSmithPackage/Sources/AgentSmithKit/Persistence/PersistenceManager.swift:70-180, 202-264, 268-288`
  - `swift-llm-kit/Sources/SwiftLLMKit/Persistence/StorageManager.swift:49-86`
- **Description:** Persistence methods synchronously read/write entire JSON files via `Data(contentsOf:)`, `JSONEncoder`, and `.write(..., .atomic)` from actor methods. Serial writers reduce ordering races, but the underlying storage model is still whole-file rewrite.
- **Impact:** Large channel logs, task histories, memory stores, usage records, and attachments will increasingly block actor executors and consume memory. As sessions and documents scale, startup and save latency will grow nonlinearly.
- **Recommendation:** Move high-volume stores to SQLite/SwiftData or append-only logs with periodic compaction. Keep session metadata small. Separate blob storage from metadata. Add file size metrics and startup/load performance instrumentation.
- **Effort:** Large

---

### 14. Attachment Pipeline Is File-Blob Oriented and Not Ready for Full Document Handling

- **Severity:** Medium
- **Category:** Data Handling / LLM Architecture / Scalability
- **Location:**
  - `AgentSmithPackage/Sources/AgentSmithKit/Channel/AttachmentRegistry.swift:118-165, 167-189`
  - `AgentSmithPackage/Sources/AgentSmithKit/Tools/FileReadTool.swift:1-10, 143-166, 300-320`
  - `AgentSmithPackage/Sources/AgentSmithKit/Orchestration/OrchestrationRuntime.swift:335-424, 426-465`
- **Description:** Attachments are stored as whole blobs with MIME guessed by extension. `file_read` supports text and PDF text extraction, images as metadata, and binary as metadata. Brown briefings render markdown `file://` links and eagerly inject only selected image bytes. There is no common document-ingestion pipeline for PDFs, Word docs, spreadsheets, audio/video transcripts, OCR, page/chunk indexing, or provider-specific multimodal upload APIs.
- **Impact:** The planned full document handling will become ad hoc if built on top of current file_read/attachment behavior. Large files will either be rejected, read wholesale, or represented only as metadata, limiting agent usefulness.
- **Recommendation:** Introduce a `DocumentIngestion` subsystem with MIME sniffing, chunking, extraction plugins, OCR/transcription hooks, page/timecode metadata, semantic indexing, thumbnails/previews, and provider-specific content-part generation. Keep raw blobs separate from derived text/chunks. Add user-visible controls for what is sent to LLMs.
- **Effort:** Large

---

### 15. `ChannelLogView` Redraw Optimization Assumes Append-Only Messages and Will Break Streaming or In-Place Updates

- **Severity:** Medium
- **Category:** SwiftUI / Architecture / Scalability
- **Location:**
  - `AgentSmith/AgentSmith/Views/ChannelLogView.swift:145-177`
  - `AgentSmith/AgentSmith/Views/ChannelLogView.swift:184-243, 245-324`
- **Description:** `ChannelLogView` implements custom `Equatable` by comparing only `messages.count` and `messages.last?.id`, with a comment stating correctness depends on append-only messages. The view also computes several lookup dictionaries by scanning the full message array on each body evaluation.
- **Impact:** Streaming LLM output, live tool-progress rows, metadata updates, edited messages, attachment load-state changes, or grouped MCP/tool events can fail to redraw if they mutate existing messages. The O(N) scans per append produce cumulative O(N²) behavior over long sessions.
- **Recommendation:** Move channel-log derivation into an observable view model that incrementally maintains request/output/review indexes. Use explicit row view models and update existing row IDs when streaming or metadata changes. If custom `Equatable` remains, compare a monotonic `messagesRevision` rather than count/last ID.
- **Effort:** Medium

---

### 16. Several SwiftUI Views Still Mutate `@State` Directly in Lifecycle/Callback Closures Despite the Project’s Own Deferral Pattern

- **Severity:** Medium
- **Category:** SwiftUI / Code Quality
- **Location:**
  - `AgentSmith/AgentSmith/Views/SettingsView.swift:47-50`
  - `AgentSmith/AgentSmith/Views/UserInputView.swift:141-144`
  - `AgentSmith/AgentSmith/Views/TaskDetailWindow.swift:290-291`
  - Contrast with `AgentSmith/AgentSmith/Views/MainView.swift:62-89` and `ChannelLogView.swift:787-794`, which explicitly defer state mutations.
- **Description:** The codebase has adopted a local convention of deferring `@State` mutations out of `.onChange`/lifecycle callbacks via `DispatchQueue.main.async`, but this is not consistently applied. `SettingsView.onAppear` assigns `availableVoices` directly, and attachment thumbnail `.task` assigns `chipImage` directly.
- **Impact:** Inconsistent SwiftUI mutation rules make future view work fragile. The app already has comments acknowledging SwiftUI update-loop warnings in similar contexts. New developers or agents will copy whichever pattern they see nearby.
- **Recommendation:** Codify the rule. Either relax it explicitly to only `.onChange`, or enforce deferral consistently. Add source guards for direct `@State` mutation inside `.onChange`, `.onAppear`, `.onDisappear`, `.task`, and scroll callbacks where the project wants deferral. For async `.task`, prefer local loader view models or `@Observable` image state instead of direct row state mutation where possible.
- **Effort:** Small

---

### 17. SwiftUI Rule Enforcement Exists but Covers Only a Small Subset of the User’s Explicit Rules

- **Severity:** Medium
- **Category:** Code Quality / SwiftUI
- **Location:**
  - `AgentSmithPackage/Tests/AgentSmithTests/CodeStyleGuardTests.swift:81-163`
- **Description:** The project has useful code-style guards for `: some View` properties, Lazy containers, `.onTapGesture`, `.foregroundColor`, `@ObservedObject`, and inline `.font(.system(size:))` in views. It does not enforce many of the user’s explicit rules: no force unwraps, no `try?`, no raw `Task {}` without error policy, no modifier-order violations, no `didSet/willSet` on `@State/@Binding`, no custom identity-only `Equatable`, no comments crediting LLMs, and no inline colors outside styling.
- **Impact:** The codebase already has violations that a guard could catch. As more agents or contributors work on the app, regressions will be frequent unless these rules are executable.
- **Recommendation:** Expand `CodeStyleGuardTests` or adopt SwiftLint custom rules. Start with production-source scans for `try?`, `!`, `try!`, raw `Task {`, `.sheet/.alert` ordering, inline `Color(red:)`/`.font(...)` outside `AppStyling`, and `Equatable` implementations that compare only `id`. Allow explicit per-line suppressions only with a reason.
- **Effort:** Medium

---

### 18. User Input and Attachment UI Pass Computed Values to Subviews, Violating a Stated SwiftUI Preference

- **Severity:** Low
- **Category:** SwiftUI / Code Quality
- **Location:**
  - `AgentSmith/AgentSmith/Views/UserInputView.swift:37-45, 72-74`
  - `AgentSmith/AgentSmith/Views/UserInputView.swift:109-110`
- **Description:** `UserInputView` passes the computed `hasContent` property to `UserInputTextField`, and `PendingAttachmentChip` computes a fallback cached image inline in `body`. This conflicts with the user’s preference to avoid passing computed values to subviews and use local state instead.
- **Impact:** Low today, but it contributes to body recomputation and inconsistent project style. As input grows to include richer attachments, dictation/audio, paste processing, and document previews, explicit state/view-model boundaries will be cleaner.
- **Recommendation:** Store `hasContent` as derived state in the parent view model or pass the raw values and let the subview own the derivation. Move thumbnail lookup into `ImageCache`/observable loader state so `body` reads a simple value.
- **Effort:** Small

---

### 19. Image Cache Singleton Is a Global Service Without Clear Memory Policy or Dependency Injection

- **Severity:** Medium
- **Category:** Architecture / Performance / SwiftUI
- **Location:**
  - `AgentSmith/AgentSmith/Views/UserInputView.swift:109-144`
  - `AgentSmith/AgentSmith/Styling/ImageCache.swift` (global `ImageCache.shared` usage)
- **Description:** Views reach for `ImageCache.shared` directly to synchronously check cached thumbnails and asynchronously load images. This creates a singleton dependency in the view layer and makes cache size, eviction, testing, and per-session behavior harder to control.
- **Impact:** Full image/document/video handling will make thumbnail and preview caching a major memory consumer. A global singleton can retain data across sessions, complicate privacy expectations, and make previews harder to test.
- **Recommendation:** Inject an `ImageLoading`/`ThumbnailCache` service through the environment or session view model. Define memory limits, eviction, per-session scoping, and explicit clearing when sessions close/delete. Add metrics for cached bytes and thumbnail generation latency.
- **Effort:** Medium

---

### 20. Local Swift Package Dependencies Are Path-Based and Not Versioned for Reproducible Builds

- **Severity:** Medium
- **Category:** Dependency Management / Architecture
- **Location:**
  - `AgentSmithPackage/Package.swift:13-20`
  - `swift-semantic-search/Package.swift:15-20`
- **Description:** `AgentSmithPackage` depends on local `../../swift-llm-kit` and `../../swift-semantic-search` packages. Comments note that these should become versioned git dependencies before release. `swift-semantic-search` also tightly pins `mlx-swift-lm` to `.upToNextMinor(from: "2.29.2")` because of upstream API churn.
- **Impact:** Builds are not reproducible outside this local folder layout. Future agents, CI, release builds, and external contributors can accidentally build against different local package states. The local package arrangement also obscures which versions of LLM and semantic-search APIs Agent Smith expects.
- **Recommendation:** Establish a workspace/dependency policy now: tag `swift-llm-kit` and `swift-semantic-search`, use versioned package dependencies or a monorepo with one top-level package/workspace, commit `Package.resolved`, and add CI that builds from a clean checkout. Keep the MLX pin documented and test migrations in a branch before relaxing it.
- **Effort:** Medium

## Additional Notes

- The codebase shows strong progress on concurrency hygiene: `SerialPersistenceWriter`, `SerialChainedTaskQueue`, cancellation-aware `ProcessRunner`, actor-based stores, and explicit comments around prior races are all good foundations.
- The highest-leverage next step is to convert implicit conventions into executable architecture: deterministic tool policy, versioned persistence, centralized context budgeting, provider capability abstractions, and source-level style guards for the user’s rules.
- The most urgent security fix is to disable full LLM verbose logging by default and add retention/redaction controls before expanding document and messaging integrations.
