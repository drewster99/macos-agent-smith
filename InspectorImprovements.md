# Inspector and Sidebar Improvements

## Purpose

Make every inspector surface answer the same basic questions clearly:

1. What invoked this subsystem or model?
2. What exact context or request did it receive?
3. What did it return or mutate?
4. What was retained, truncated, skipped, or evicted?

The sidebar must remain a compact status surface. Large histories and detailed transcripts belong
in pop-out windows so high-frequency updates do not repeatedly build large SwiftUI trees in the
sidebar.

This document is the complete implementation plan for the Security Agent, Validator, Summarizer,
LLM-turn, and Memory inspector work discussed on 2026-09-23. Implement it in phases, recheck each
phase, build and test it, and commit each completed phase before continuing.

## User requirements

- Smith and Brown are the reference behavior: their inspector detail opens in a separate window and
  presents readable request/response history.
- Reuse the Smith/Brown inspector implementation wherever the underlying data permits. Do not create
  visually or behaviorally divergent one-off windows.
- Security Agent must retain its sidebar chevron. Expanding it should show the approximately ten most
  recent Security Evaluations.
- Security Agent must also have an `arrow.up.forward.square` pop-out button immediately to the right
  of its expandable title/chevron control and to the left of its speaker button.
- Security Agent's pop-out must show useful LLM turns with the outgoing request and response, not only
  the response.
- Validator must gain a pop-out inspector. It does not need inline expansion.
- Summarizer must become pop-out-only and present readable, fully formatted detail.
- Memory search rows must distinguish a corpus that was not searched from a corpus that was searched
  and returned zero results.
- Memory search rows must show exactly which memories and prior-task summaries were returned.
- Memory writes must appear in the Memory activity list.
- Memory consolidation must be visible and explain what existing content, proposed content, decision,
  and final content were involved.
- Do not change which retrieval corpora are enabled by default as part of this work. This is an
  observability/UI project, not a retrieval-policy change.

## Review decisions (2026-09-23)

Decided with the user after verifying this plan against the code:

1. **Memory tests stay MLX-gated.** `MemoryStore` keeps its concrete `SemanticSearchEngine`; no
   embedding protocol seam is added. Memory-store behavior tests live in
   `MemoryStoreIntegrationTests` and run only via the documented `AGENT_SMITH_RUN_MLX_TESTS=1`
   `xcodebuild` invocation, with the user's approval each time. Pure logic (labels, outcome types,
   reconciliation parsing) is tested in the normal `swift test` pass.
2. **Typed Memory origins wrap `RetrievalSource`.** The retrieval-point origins are
   `.retrieval(RetrievalSource)` alongside explicit non-retrieval cases; no parallel enum restates
   the five retrieval points.
3. **`MemoryQueryRecord.phaseBreakdown`'s claim that a zero timing identifies a skipped corpus is
   removed** along with the zero-ms inference.
4. **Reconciliation cancellation is its own typed outcome**, distinct from affirmative `DIFFERENT`,
   malformed, empty-body, and transport failure. All still save separately.
5. **`ToolContext.reconcileMemoryTexts` / `extractWebContent` closure signatures change** to carry
   task/correlation context.
6. **Security turns are numbered per role** across Smith's, each Brown's, and the validation
   evaluator; both tool-scoping call sites are captured.
7. **Validator records with no stored system prompt** (enumerator path) render that absence
   explicitly.
8. The `.userTaskAction` / auto-context regression test is new work, not already present.

Found during Phase 1: the per-role inspector "session cost" summed the retained turns, so it
undercounted after eviction and read $0 for Validator and Summarizer. It now reads a
`UsageRecord`-backed per-(run, role) rollup in `CostBoard` (`runRoleUsage`).

## Important recent correction: do not redo it

Task pause/stop/delete notices were previously sent through the direct-user-message path with text
such as `[System notice — user action in the app]`. Because Smith's auto-context hook keys off the
message sender rather than the prose, those app-generated notices were mistakenly treated as user
messages and triggered Memory `auto-context` queries.

Commit `9957345` corrected that behavior: `AppViewModel.notifySmithTaskStateChanged` now calls
`OrchestrationRuntime.notifySmithOfUserTaskAction`, which posts a typed `.system` message with
`.userTaskAction`. Smith accepts the notice, but it no longer qualifies as a user message for
auto-context retrieval.

Required regression coverage:

- A real `.user` message can trigger `.smithUserMessage` retrieval.
- A `.system` message of kind `.userTaskAction` reaches Smith but does not trigger auto-context.
- Existing Memory query records created before the correction are historical artifacts; do not
  migrate or reinterpret them.

## Current implementation: shared inspector code

Smith and Brown already share the same implementation:

- `AgentSmith/AgentSmith/Views/InspectorView.swift`
  - `RoleAgentCard`
  - `AgentCard`
  - `AgentCardHeaderRow`
  - `AgentCardTitleLabel`
- `AgentSmith/AgentSmith/Views/AgentInspectorWindow.swift`
- `AgentSmith/AgentSmith/Views/Inspector/AgentInspectorWindowHeader.swift`
- `AgentSmith/AgentSmith/Views/Inspector/AgentInspectorWindowSections.swift`
- `AgentSmith/AgentSmith/Views/LLMTurnViews.swift`
- `AgentSmith/AgentSmith/AgentSmithApp.swift`
  - The existing `WindowGroup("Agent Inspector", for: AgentInspectorTarget.self)` already routes by
    session and `AgentRole`.
  - `AgentInspectorTarget` can already represent every role; do not introduce separate target types
    per role without a concrete requirement.

`AgentCard.opensInWindow` currently returns true only for Smith and Brown. Security expands inline.
Validator and Summarizer use separate card implementations.

Refactor toward one common inspector-window shell with role-specific typed content. Keep shared
sections as actual reusable views rather than copying their source into role-specific files.

## Current implementation: LLM turns

### Representation and rendering

- `AgentSmithPackage/Sources/AgentSmithKit/LLM/LLMTurnRecord.swift` holds a response, incremental
  input, optional full context snapshot, configuration metadata, latency, and usage.
- `LLMTurnDisclosureRow` in `LLMTurnViews.swift` renders:
  - `turn.inputDelta` as **Outgoing**.
  - `turn.response.reasoning` as purple italic reasoning text.
  - Tool calls.
  - `turn.response.text` as the visible response.
- For Codex Responses models, the purple text is normally a provider-generated reasoning summary.
  `CodexResponsesProvider` requests `reasoning: { effort: ..., summary: "auto" }` and collects
  `response.reasoning_summary_text.delta` into `LLMResponse.reasoning`. It is not generated by the
  task Summarizer.

### Retention

- `AgentActor` retains the most recent 100 `LLMTurnRecord` values per agent instance.
- `AgentInspectorStore` independently retains the most recent 100 turns per role and per tracked
  instance.
- Only the latest 10 role-level turns retain a full `contextSnapshot`; older retained turns keep
  their response and `inputDelta` but lose the heavy full-context copy.
- The store tracks at most 32 agent instances.
- The current UI enumerates the retained array and labels it `1...count`. After eviction, this
  silently renumbers lifetime turn 44 as displayed turn 1.
- Turn records are in-memory inspector data. `stopAll` and abort clear them.
- A successful provider response becomes a turn even when its content later fails parsing.
  Transport attempts that throw before producing an `LLMResponse` do not become turns.

### Required retention transparency

Introduce stable, role-level inspector ordinals at the point where `AgentInspectorStore` receives
turns. Do not use the retained-array index as identity or lifetime numbering.

The UI must show:

- `LLM Turns (61)` while nothing has been evicted.
- `LLM Turns — latest 100 of 143` after eviction.
- Stable original ordinals on retained rows.
- An explicit indication when the full context snapshot was discarded.
- Failed provider attempts separately when the provider never returned an `LLMResponse`; do not
  fabricate a normal response turn. A small typed failure record or a failed-attempt row is
  preferable to silently omitting the attempt.

Keep the 100-turn retention limit unless measurements justify another value. This work makes the
limit honest; it does not remove bounded retention.

## Security Agent

### Current behavior

`SecurityEvaluator.emitTurnRecord` currently creates `LLMTurnRecord` with:

- `inputDelta: []`
- The default empty `contextSnapshot`
- The full returned `LLMResponse`

That is why Security turns show reasoning and SAFE/WARN/UNSAFE text but no outgoing request.

`AgentInspectorStore` retains at most 200 `EvaluationRecord` values globally. The inline Security
section renders only the newest 10. That inline list is useful and should remain.

`AgentInspectorWindow` already has Security-specific display-name and status handling, but Security
cannot currently open it. `AgentInspectorWindowSections` also lacks Security Evaluation input and
unconditionally includes Direct Message, which is invalid for Security Agent.

### Required sidebar behavior

- Keep the Security title/chevron as an inline-expansion control.
- Insert a separate `arrow.up.forward.square` button after that control and before
  `AgentCardMuteButton`.
- Give the button a clear help string and accessibility label such as `Open Security Agent
  inspector`.
- Inline expansion contains only `Security Evaluations`, newest first, limited to 10 rows.
- Remove Available Tools, Recent Tool Calls, Recent Messages, Context, LLM Turns, and Direct Message
  from Security's inline expansion. These belong in the pop-out.
- Do not change Smith/Brown title-click behavior while adding Security's second control.

### Required turn capture

Change `SecurityEvaluator.emitTurnRecord` to receive the exact `[LLMMessage]` sent to the provider,
not merely a message count.

For every successful call:

- Set `inputDelta` to the exact outgoing messages needed to understand that call.
- Set `contextSnapshot` to the full exact request message array.
- Preserve response reasoning, text, tool calls, usage, model configuration, and latency.
- Capture normal reviews, parsing retries, evidence-gathering rounds, forced-verdict rounds, and
  task-start tool-scoping calls.
- Make attachment-reference text visible. Continue honoring existing image/document privacy and
  lifetime behavior; the inspector need not duplicate binary attachment data.
- Emit the turn before parsing the verdict, as today, so malformed-but-returned responses remain
  inspectable.
- Emit a typed failed-attempt record when the provider throws, including latency, classification,
  and error text, without pretending that a response existed.

For a multi-round review, each provider call is a distinct turn. The outgoing messages must be the
actual messages for that round, including prior assistant tool calls, tool results, staged
attachment references, and the evidence-limit instruction when present.

### Required pop-out sections

Use the shared `AgentInspectorWindow` shell and shared section/row components. Security's window
must show:

1. Header, model/configuration summary, status, and session cost.
2. Security Evaluations, newest first, with the full retained count and visible retention wording.
3. Recent Security messages/errors where useful.
4. LLM Turns using `LLMTurnDisclosureRow`.
5. No Direct Message section.

Improve `EvaluationRecordRow` for the wider window so it can reveal the full stored prompt and full
response, not only five parameter lines and three response lines. Inline rows may remain compact.

## Validator

### Current behavior and authoritative data

Validator is not a resident `AgentActor`. It runs transiently per criterion, so it has no persistent
conversation, tool list, speech state, or `LLMTurnRecord` array.

The authoritative record already exists on each task as append-only `CriterionVerdictRecord` values:

- Verdict.
- Validator name and definition hash.
- Validation round and timestamp.
- Fully rendered system prompt, capped at 20,000 characters.
- Fully rendered input/evidence, capped at 20,000 characters.
- Turn-by-turn response log, capped at 12,000 characters.

Task Detail already renders these through `TaskDetailVerdictTranscripts`. Do not create a second
validator-history truth source that can disagree with the task ledger.

### Required sidebar and pop-out behavior

- Validator remains pop-out-only; do not add an inline chevron.
- Add `arrow.up.forward.square` before the gear button.
- Continue showing the assigned model/no-model state and session cost.
- Open the common `AgentInspectorWindow` target with role `.validator`.

Aggregate the current session's task verdict ledgers for display. Group and label records by:

1. Task title and task identifier.
2. Criterion number/text and criterion identifier.
3. Validation round.
4. Recorded timestamp.

For each record, show:

- Accepted/rejected/waived/error outcome.
- Validator name/hash.
- Exact stored system prompt.
- Exact stored user input/evidence.
- Turn-by-turn response/tool log.
- Explicit truncation markers already written by the coordinator; do not describe capped text as
  complete when it is capped.

Extract shared transcript-box UI from Task Detail rather than reproducing a second formatting style.
The inspector may adapt layout and headings but must read the same `CriterionVerdictRecord` values.

## Summarizer

### Current behavior

`TaskSummarizer` is a standalone actor, not an `AgentActor`. The current sidebar card derives an
activity list from channel messages and shows only the newest eight messages when expanded.

It does not emit `LLMTurnRecord` values. Therefore the inspector cannot currently show exact
requests, provider reasoning, responses, or retries.

The same actor/provider performs three operation classes, all billed to `.summarizer`:

1. Completed/failed task summarization.
2. Memory reconciliation/consolidation decisions.
3. Web-page content extraction for prompted `web_fetch` calls.

The inspector must account for all three; showing only task-summary calls would disagree with the
Summarizer session cost.

### Required sidebar behavior

- Remove the Summarizer inline expansion and chevron.
- Make the title open the common inspector window, matching Smith/Brown.
- Show the square-arrow affordance in the title.
- Keep configuration and current activity/status behavior.
- Keep the existing speaker placeholder unless speech support is separately implemented; do not
  silently make it functional as part of this work.

### Required turn capture and pop-out

Give the per-runtime Summarizer a stable inspector instance identifier and a turn-record callback
wired through `OrchestrationRuntime` into `AgentInspectorStore`.

For every provider call, record:

- Typed operation: task summary, memory reconciliation, or web extraction.
- Associated task ID/title when applicable.
- Exact system and user messages sent.
- Full `LLMResponse`, including reasoning and tool calls if a provider violates the no-tools
  request.
- Model/configuration, latency, finish reason, and usage.
- Attempt number and failure records for transport retries.

The Summarizer pop-out must show:

1. Header, model, activity, and session cost.
2. Operation/activity overview.
3. LLM Turns using the shared renderer, with an operation badge and task association.
4. Errors and retry history.

Do not infer turns from channel messages. Channel messages remain user-visible activity notices;
the new turn callback is the inspector's exact model-call source.

## Memory inspector

### Current behavior

The current `MemoryQueryCard` is a global, app-wide read-side log. It is not a memory agent and it is
not an audit log of mutations.

- `MemoryStore.setOnQueryRecorded` pushes `MemoryQueryRecord` into
  `SharedAppState.memoryQueryRecords`.
- The in-memory list retains 200 records.
- Inline rendering shows only the newest 40.
- Each record stores only query text, hit counts, latency phases, and a string source.
- It does not retain the identities or content of returned hits.
- It cannot distinguish `taskLimit == 0` from a searched task corpus that returned zero because
  both render as `0t`.
- It does not record saves, edits, deletes, task-summary writes, or consolidation mutations.

Today, a chip such as `1m · 0t` literally means that the query returned one memory result and zero
prior-task-summary results. It does **not** establish that prior tasks were searched: `0t` currently
conflates "search disabled" with "searched and no matches." The typed corpus outcomes below remove
that ambiguity.

The current raw source names include:

- `auto-context`: Smith automatically searched based on a real pending user message and injected
  returned memories into Smith's local copy of that message inside an `[AUTO_MEMORY_CONTEXT]`
  block. The original channel transcript is not modified. Default policy searches memories and
  does not search prior-task summaries.
- `security-tool-review`: before a real, non-auto-approved Security review, the runtime searches
  using `toolName + toolParams + task title + task description`. Default policy searches memories
  and does not search prior-task summaries. Returned content is appended to the Security prompt
  under `Possibly relevant context`.
- `task-context`: task creation/start context retrieval; both memories and prior tasks are enabled
  by default.
- `validator-review`: both corpora are disabled by default.
- `security-scoping`: both corpora are disabled by default.
- Direct calls to `searchMemories` currently default to the unhelpful source string `system` unless
  the caller supplies something better.

### Replace query-only storage with a typed activity feed

Introduce a single chronological, bounded, app-wide Memory activity feed. Prefer a new typed model
over arrays of interacting booleans and string special cases.

Suggested shape:

```swift
enum MemoryActivityRecord: Identifiable, Sendable, Equatable {
    case query(MemoryQueryActivity)
    case mutation(MemoryMutationActivity)
}

enum CorpusSearchOutcome<Hit: Sendable & Equatable>: Sendable, Equatable {
    case notSearched
    case searched(hits: [Hit])
}
```

Use typed origins with user-facing labels. Preserve an `.other(String)` case only for genuinely
external/forward-compatible origins; do not scatter comparisons against magic source strings
through the UI.

Each activity receives a monotonically increasing sequence from the authoritative actor before it
is delivered to the main actor. Sort/display by that sequence so asynchronous callback tasks cannot
reorder searches and mutations.

Keep the feed bounded. A reasonable initial cap is the existing 200 records, now shared by reads and
writes. The header and expanded section must disclose both retained and lifetime counts, for example
`Latest 200 of 327 activities` and `Showing latest 40`.

Do not persist the activity feed in this phase. The durable memories and task summaries continue to
persist as they do today; this remains a bounded runtime-inspection surface. If durable audit history
is desired later, design that separately rather than quietly expanding existing JSON files.

### Query records: searched versus skipped

Record a separate typed outcome for the memory corpus and the prior-task-summary corpus.

- `notSearched` means its resolved limit was zero and no embedding/scan was performed for that
  corpus.
- `searched(hits: [])` means the corpus was actually searched and nothing passed ranking/gating.
- `searched(hits: [...])` contains immutable snapshots of exactly what the search returned, in
  returned rank order.

Do not infer skipped state from `0ms`; a genuinely fast scan can also round to zero milliseconds.

Memory hit snapshots must include:

- Rank.
- Memory identifier.
- Full content at query time.
- Tags.
- Original source and source task ID.
- Cosine similarity, lexical score, and reciprocal-rank-fusion score.

Prior-task hit snapshots must include:

- Rank.
- Task identifier.
- Title.
- Full summary at query time.
- Status and relevant dates.
- Cosine similarity, lexical score, and reciprocal-rank-fusion score.

Snapshots are required. Looking records up later would let an edit or deletion rewrite history and
would make a returned-but-now-deleted memory impossible to inspect.

Update all query producers:

- `MemoryStore.searchMemories`: memories searched; task summaries not searched.
- `MemoryStore.searchTaskSummaries`: memories not searched; task summaries searched.
- `MemoryStore.searchAll`: each corpus outcome derives directly from its limit and actual results.
- Agent `search_memory`, task context, auto-context, validator retrieval, Security scoping, Security
  review, Memory Browser searches, and consolidation candidate searches must supply typed origins.

### Query-row UI

Collapsed rows must state corpus behavior honestly. Examples:

- `1m · tasks off`
- `0m · 2t`
- `memory off · 0t`
- `0m · 0t` only when both corpora were searched and both returned zero

The compact visual may use `m` and `t`, but help and accessibility text must expand them to
`memories` and `prior task summaries`.

Use human-readable source labels such as:

- `Smith auto-context`
- `Security tool review`
- `New-task context`
- `Validator review`
- `Memory consolidation candidate search`
- `Agent search_memory`
- `Memory Browser search`

Expanded query rows show:

1. Exact query.
2. Embedding, memory-scan, and task-scan timing.
3. `Memories not searched`, `No memories matched`, or `Returned memories (N)`.
4. Every returned memory with selectable full content and metadata.
5. `Prior task summaries not searched`, `No prior task summaries matched`, or
   `Returned prior task summaries (N)`.
6. Every returned task summary with selectable full content and metadata.

Do not change the resolved retrieval toggles. In particular, `auto-context` and
`security-tool-review` still default to memory on / prior tasks off.

### Memory writes and mutations

The Memory activity feed must include every successful logical content mutation:

- Create memory.
- Edit memory content and/or tags.
- Delete memory.
- Consolidate/merge memory.
- Create or replace a task summary.
- Delete a task summary if a supported path exists.

Do not emit feed noise for:

- Retrieval-count and last-retrieved updates.
- Injection-count and last-injected updates.
- Re-embedding caused only by an embedding-model/scheme migration.
- Persistence flushes that do not change logical content.

Publish mutation activity from the authoritative `MemoryStore` actor only after a mutation commits.
Do not synthesize successful writes independently in `SaveMemoryTool`, `SharedAppState`, or views.
Those callers must pass typed origin/context into the store; the store owns the final before/after
snapshot and event emission.

Mutation snapshots must include:

- Operation kind.
- Sequence and timestamp.
- Memory or task-summary identifier.
- Typed origin: user editor, Smith, Brown, automatic consolidation, task summarization, or other
  explicit origin.
- Associated task ID when applicable.
- Before content/tags for edits, deletes, and consolidation.
- Proposed content/tags when consolidation was attempted.
- Final committed content/tags.
- Whether the existing identifier was retained.
- Consolidation correlation ID when applicable.

Failed mutations must not appear as successful write records. Surface a typed failed activity only
if it helps diagnose a real attempted operation; label it as failed and include the handled error.

Compact mutation badges:

- `CREATE`
- `EDIT`
- `MERGE`
- `DELETE`
- `TASK SUMMARY`

Expanded mutation rows show selectable before/proposed/after blocks as applicable.

### Memory consolidation: existing behavior

Consolidation is not periodic compaction. It currently occurs only when an agent invokes
`save_memory`; manual Memory Browser saves bypass it.

Current flow in `SaveMemoryTool` and `TaskSummarizer`:

1. Search up to 20 existing memories with a permissive candidate floor of `0.50`.
2. Select the candidate with the highest raw cosine similarity.
3. Only consult the LLM reconciler when that score is at least `0.70`.
4. Send the full existing memory and proposed new memory to the Summarizer model.
5. The model answers `SAME` plus reconciled content, or `DIFFERENT`.
6. `SAME` updates the existing memory in place, retains its identifier/source, unions tags, and
   marks `lastUpdatedBy = .system`.
7. `DIFFERENT`, no qualifying candidate, malformed reconciliation, or reconciliation transport
   failure saves a new memory instead.
8. If the in-place update fails, the current code falls back to saving a new memory.

This is potentially destructive because `SAME` rewrites an existing memory and there is no built-in
undo. `ToolSafetyClassification` therefore classifies `save_memory` as destructive.

### Consolidation observability improvements

- Give the candidate search a typed `memoryConsolidation` origin instead of `system`.
- Give each consolidation attempt a correlation ID shared across:
  - Candidate query activity.
  - Summarizer LLM turn.
  - Final Memory mutation activity.
- Evolve `MemoryReconciliation` so `different` and `reconcilerUnavailable/malformed` are distinct
  typed outcomes. Preserve the current safety behavior—both save separately—but do not report a
  failed judge as an affirmative `DIFFERENT` decision.
- A merge mutation row shows candidate similarity, existing content, proposed content, reconciled
  content, retained ID, and combined tags.
- A kept-separate create row shows whether there was no qualifying candidate, an affirmative
  `DIFFERENT`, or a reconciler failure.
- The Summarizer pop-out shows the exact consolidation request/response; the Memory feed shows the
  resulting durable mutation. Link them by correlation ID rather than duplicating or recomputing
  truth.

### Memory sidebar scope

Keep Memory expandable inline in this phase. The expanded card shows the newest 40 compact activity
rows and clearly says when more retained activity exists. Detailed rows may expand to show exact
results and before/after text.

Do not add a new Memory Activity pop-out in this phase unless the completed inline rows prove
unusable at the sidebar's maximum width. The existing Memory Browser remains the place for browsing
and editing current durable memories; the inspector activity feed explains runtime use and mutation.

## Common window and view design

`AgentInspectorWindow` remains the one window shell. Introduce a typed role-content model or small
role-specific content views inside that shell rather than a monolithic body full of unrelated
booleans.

Recommended content routing:

- Smith/Brown: resident-agent sections already present.
- Security: evaluation sections plus captured LLM turns; no Direct Message.
- Validator: task-ledger verdict/transcript sections.
- Summarizer: operation activity plus captured LLM turns.

Extract/reuse these focused components:

- Turn-list section with honest retention heading.
- Full selectable transcript text box.
- Model/configuration and session-cost line.
- Compact activity/result row conventions.
- Error/failed-attempt row.

Follow the project's SwiftUI rules:

- Keep view bodies small by extracting real `View` types, not computed `some View` properties or
  functions returning `some View`.
- Use stable identities in every `ForEach`.
- Do not perform heavy filtering/sorting directly in repeatedly evaluated bodies. Prepare typed,
  stable arrays in the owning model/store or cached wrapper.
- Preserve the current narrow per-role watchers and reconciliation heartbeat behavior. Adding a
  pop-out must not make high-frequency Security activity rebuild Smith/Brown/sidebar trees.
- Use semantic centralized colors and existing `AppFonts`/`AppColors`.
- Use spacing from the established 4-point grid.
- Use `Button`, help text, and accessibility labels for every header control.
- Keep sheet/lifecycle modifier ordering compliant with project rules.
- Do not mutate observed state synchronously inside `.onChange`.

## Data ownership and concurrency

- `AgentInspectorStore` remains the single main-actor owner of live per-role inspector state.
- Runtime actors emit immutable records through callbacks; views never query actors directly during
  rendering.
- `MemoryStore` remains the single mutation point and single publisher of Memory activity.
- Assign activity/turn sequence numbers before crossing actor boundaries.
- Capture immutable local request arrays before provider `await` calls and use those snapshots when
  recording turns. Actor methods are reentrant; never reconstruct the request afterward from mutable
  actor state.
- Emit a successful mutation record only after the in-memory commit succeeds.
- Keep existing safe re-read-after-embedding behavior in `MemoryStore.update`; event creation must
  use the fresh committed entry, not the pre-suspension snapshot for invariant fields.
- Do not use NotificationCenter or a singleton to bridge these updates. Extend the existing callback
  and observable-store architecture.

## Expected implementation touchpoints

This list is a starting map, not permission to bypass repository search when a symbol has moved.
Keep new types beside the domain that owns their truth and keep view-only formatting in the app
target.

### Shared inspector and role cards

- `AgentSmith/AgentSmith/ViewModels/AgentInspectorStore.swift`
  - Stable turn ordinals/lifetime counts, failed attempts, Summarizer instance state, and the
    session-level Validator projection.
- `AgentSmith/AgentSmith/Views/InspectorView.swift`
  - Security header controls and inline evaluation-only content; Memory activity card/rows.
- `AgentSmith/AgentSmith/Views/Inspector/ValidatorAgentCard.swift`
  - Validator pop-out affordance.
- `AgentSmith/AgentSmith/Views/SummarizerCard.swift`
- `AgentSmith/AgentSmith/Views/Inspector/SummarizerCardHeader.swift`
- `AgentSmith/AgentSmith/Views/Inspector/SummarizerCardExpandedSections.swift`
  - Remove the Summarizer inline path and route its title to the common window. Delete obsolete
    expanded-section code once no caller remains.
- `AgentSmith/AgentSmith/Views/AgentInspectorWindow.swift`
- `AgentSmith/AgentSmith/Views/Inspector/AgentInspectorWindowHeader.swift`
- `AgentSmith/AgentSmith/Views/Inspector/AgentInspectorWindowSections.swift`
- `AgentSmith/AgentSmith/Views/LLMTurnViews.swift`
  - Shared role routing, transcript/turn/failure rendering, and retention wording.
- `AgentSmith/AgentSmith/AgentSmithApp.swift`
  - Existing inspector `WindowGroup`; extend routing rather than declaring parallel windows.

### Provider-call capture and Validator source data

- `AgentSmithPackage/Sources/AgentSmithKit/LLM/LLMTurnRecord.swift`
  - Domain-level presentation metadata or adjacent typed inspector records. Keep the provider's
    `LLMResponse` model free of UI labels.
- `AgentSmithPackage/Sources/AgentSmithKit/Agents/SecurityEvaluator.swift`
  - Exact Security request snapshots and successful/failed attempt callbacks.
- `AgentSmithPackage/Sources/AgentSmithKit/Memory/TaskSummarizer.swift`
  - Exact turns for all three Summarizer operation classes and typed reconciliation outcomes.
- `AgentSmithPackage/Sources/AgentSmithKit/Orchestration/OrchestrationRuntime.swift`
  - Callback wiring, stable instance identifiers, and task/system-notice regression boundary.
- `AgentSmithPackage/Sources/AgentSmithKit/Tasks/TaskValidation.swift`
- `AgentSmithPackage/Sources/AgentSmithKit/Evaluation/TaskValidationCoordinator.swift`
- `AgentSmith/AgentSmith/Views/TaskDetailWindow.swift`
  - Authoritative verdict records, session projection inputs, and reusable transcript UI. Do not
    move verdict ownership into the inspector store.

### Memory activity and consolidation

- `AgentSmithPackage/Sources/AgentSmithKit/Memory/MemoryStore.swift`
  - Authoritative query snapshots, mutation publication, sequence assignment, retention, and
    typed origins.
- `AgentSmithPackage/Sources/AgentSmithKit/Memory/MemoryEntry.swift`
  - Reuse durable memory/task-summary types where appropriate; do not make the durable record
    itself carry transient inspector state.
- `AgentSmithPackage/Sources/AgentSmithKit/Tools/SearchMemoryTool.swift`
  - Typed `Agent search_memory` query origin.
- `AgentSmithPackage/Sources/AgentSmithKit/Tools/SaveMemoryTool.swift`
  - Consolidation correlation and explicit kept-separate reason; successful mutation remains
    emitted by `MemoryStore`.
- `AgentSmith/AgentSmith/ViewModels/SharedAppState.swift`
  - Replace `memoryQueryRecords` plumbing with the bounded typed activity feed.
- `AgentSmith/AgentSmith/Views/MemoryEditorView.swift`
  - Pass manual-edit origins into the store; do not publish UI-synthesized success events.
- `AgentSmith/AgentSmith/ViewModels/AppViewModel.swift`
  - Verify the typed system-notice path remains intact; no new sender-attribution workaround.

### Tests

Start with the suites named in the Test plan below. Add small focused files when a concern has no
natural home rather than inflating an unrelated suite. Update `CodeStyleGuardTests.swift` only when
a new reusable rule is justified; do not weaken existing guards to admit the implementation.

## Compatibility and rollout constraints

- No durable-data migration is required: new inspector/activity records are transient.
- Existing persisted memories, task summaries, task verdict records, and session cost ledgers keep
  their current formats unless implementation proves a narrowly scoped schema addition necessary.
- Callback additions must have safe defaults so existing tests and isolated constructors do not
  require an app-level inspector.
- Keep current retention constants initially: 100 turns per role/instance, 10 full turn snapshots,
  32 instances, 200 Security evaluations, and 200 Memory activities. The UI may show smaller recent
  subsets as specified.
- Preserve current retrieval defaults, consolidation thresholds (`0.50` candidate floor and `0.70`
  reconciliation threshold), and save-separately fallback behavior.
- Treat transcript/request text as potentially sensitive. Keep it local and in-memory, use
  selectable text, and do not add logging, analytics, clipboard writes, or persistence.
- Land phases independently where practical. During intermediate phases, do not expose a pop-out
  that claims completeness before its exact-call capture/source projection exists.

## Implementation phases

### Phase 1: Shared inspection record foundations

1. Add stable inspector turn ordinals, lifetime counts, visible eviction state, and typed failed-call
   records.
2. Add an optional typed operation/correlation descriptor to turn presentation without making
   provider/domain models depend on UI strings.
3. Extract shared retention heading and full transcript components.
4. Add unit tests for numbering, eviction, snapshot stripping, and failed attempts.
5. Recheck, build/test, and commit.

### Phase 2: Security capture and window

1. Capture exact Security request messages on every provider call.
2. Add Security failed-attempt records.
3. Add the separate pop-out button in the required header position.
4. Reduce inline expansion to the newest 10 evaluations.
5. Route Security into the shared inspector window with evaluations and LLM turns.
6. Remove Direct Message from Security window content.
7. Recheck, build/test, and commit.

### Phase 3: Validator pop-out

1. Add Validator's pop-out control.
2. Build a stable session aggregate from task criterion verdict ledgers.
3. Reuse transcript components to render exact prompts/input/output.
4. Route `.validator` through the common window shell.
5. Recheck, build/test, and commit.

### Phase 4: Summarizer capture and window

1. Add a stable Summarizer inspector identity and turn callback.
2. Capture task-summary, memory-reconciliation, and web-extraction calls and failures.
3. Remove Summarizer inline expansion.
4. Route `.summarizer` through the common window shell.
5. Ensure session cost and displayed operations cover the same provider calls.
6. Recheck, build/test, and commit.

### Phase 5: Typed Memory query activity

1. Replace hit counts with per-corpus `notSearched`/`searched(hits:)` outcomes.
2. Snapshot exact memory/task hits and scores.
3. Replace raw source strings with typed origins and human-readable labels.
4. Update every query producer.
5. Update compact and expanded query rows.
6. Add the system-notice/auto-context regression tests.
7. Recheck, build/test, and commit.

### Phase 6: Memory mutations and consolidation

1. Unify query and mutation events into the bounded Memory activity feed.
2. Emit create/edit/delete/task-summary activity from committed `MemoryStore` operations.
3. Add typed mutation origins and before/proposed/after snapshots.
4. Add consolidation correlation and typed failure/distinct outcomes.
5. Add Memory activity mutation rows and visible retention wording.
6. Verify manual editor changes, agent saves, consolidation, and task summarization each produce one
   authoritative event.
7. Recheck, build/test, and commit.

### Phase 7: Integrated performance and accessibility pass

1. Exercise simultaneous Brown work, Security reviews, validation, summarization, and Memory search.
2. Confirm pop-outs update live without rebuilding large sidebar detail trees.
3. Inspect accessibility labels, keyboard navigation, text selection, light/dark appearance, narrow
   sidebar layout, and large window layout.
4. Verify all retention headings and failure states.
5. Run the full test suite and the required Xcode build with `drews-xcode-mcp`; address every new
   warning and runtime warning.
6. Recheck and commit.

## Test plan

Extend the closest existing suites rather than concentrating unrelated behavior in one giant test
file:

- `InspectorRecomputeCacheTests.swift`
  - Per-role invalidation remains narrow.
  - Security inline evaluation changes do not rebuild unrelated card content.
- Agent-turn tests / a focused new inspector-store test file
  - Stable ordinals.
  - 100-record eviction.
  - Latest 10 full snapshots.
  - `latest N of total` values.
  - Failed-attempt retention.
- `SecurityEvaluatorTests.swift`
  - Exact outgoing messages for first call, parse retry, evidence round, and forced verdict.
  - Transport failure record.
  - Returned malformed response remains a normal inspectable turn.
- `SecurityEvaluatorScopingTests.swift`
  - Exact scoping request is captured.
- `TaskValidationCoordinatorTests.swift` and `TaskValidationModelTests.swift`
  - Session aggregation does not change verdict truth.
  - Grouping preserves task, criterion, round, and timestamp.
  - Capped transcript markers remain visible.
- New/focused TaskSummarizer inspector tests
  - Every operation class emits a turn.
  - Retries/failures are represented.
  - Task/correlation metadata is correct.
- `MemoryStoreIntegrationTests.swift`
  - Memories-only search records tasks as not searched.
  - Tasks-only search records memories as not searched.
  - Searched empty is distinct from not searched.
  - Exact returned hit snapshots preserve rank, ID, content, tags/title, and scores.
  - Later edit/delete does not mutate historical snapshots.
  - Create/edit/delete/task-summary mutations emit exactly once after commit.
  - Retrieval/injection counters and re-embedding do not emit logical-write events.
  - Failed mutations do not emit success.
- `MemoryReconciliationParseTests.swift` and SaveMemoryTool coverage
  - Merge, affirmative different, malformed response, transport failure, no candidate, and update
    failure are distinguishable.
  - Merge retains ID/source, unions tags, and logs before/proposed/final content.
  - Kept-separate outcomes save exactly one new memory and explain why.
- Pending/user-message tests
  - `.userTaskAction` system notices reach Smith but do not trigger auto-context.
  - Real user messages still trigger it.

Add pure presentation tests for compact Memory labels and accessibility text. UI strings must not
infer corpus state from hit counts or elapsed milliseconds.

## Acceptance criteria

Status as of 2026-09-23 (phases 1–7 committed).

- [x] Smith and Brown still open the same shared inspector window with no regression.
- [x] Security retains inline expansion showing only the newest 10 evaluations.
- [x] Security has the requested pop-out control between expansion and speaker controls.
- [x] Security pop-out shows exact outgoing and response content for every successful retained call
      (including the validation evaluator's calls — wired in phase 7 after the live run exposed it).
- [x] Security transport failures are visible and not represented as fake responses.
- [x] Security pop-out has no Direct Message UI.
- [x] Validator has a pop-out-only inspector backed by task verdict ledgers.
- [x] Validator detail shows task, criterion, round, prompt, evidence, result, and truncation state.
- [x] Summarizer is pop-out-only.
- [x] Summarizer turns cover task summaries, memory consolidation, web extraction, and Smith context
      compaction (the fourth Summarizer-billed call, found in review).
- [x] LLM retention limits and missing snapshots are explicit.
- [x] Retained turns keep stable lifetime ordinals after eviction.
- [x] Memory distinguishes not searched from searched with zero hits.
- [x] Every Memory query shows the exact returned memories and prior-task summaries.
- [x] `auto-context` and `security-tool-review` still default to memory-only retrieval.
- [x] App-generated task-action system notices do not trigger auto-context.
- [x] The Memory feed includes creates, edits, deletes, consolidations, and task-summary writes.
- [x] Memory consolidation rows show existing, proposed, decision, and final content.
- [x] Candidate query, Summarizer turn, and final mutation share a correlation ID.
- [x] Manual Memory Browser mutations and agent mutations use the same authoritative event path.
- [x] Internal retrieval/injection/statistics maintenance does not pollute the activity feed.
- [x] Sidebar rendering remains compact and responsive during concurrent activity. Live runs logged
      SwiftUI "onChange … tried to update multiple times per frame" faults, but they are the
      pre-existing, render-neutral class documented in `4ec1756` (driven by the role-card watcher
      VALUE expressions). This work only swapped `turnsByRole[role]` → `callLogsByRole[role]` and
      `evaluationRecords.count` → `evaluationLifetimeCount` in those watchers and added none; the
      proper fix (one per-role Equatable snapshot) remains the open item that commit names.
- [x] All new controls have help and accessibility labels.
- [x] All affected tests pass — full `swift test` suite (1,288) and the MLX-gated
      `MemoryStoreIntegrationTests` (13, via `TEST_RUNNER_AGENT_SMITH_RUN_MLX_TESTS=1 xcodebuild`),
      with a mutation check confirming the new MLX assertions fail when the behavior breaks.
- [x] The full project builds without errors or new warnings.

## Non-goals

- Changing which retrieval points enable memory or prior-task searching.
- Removing bounded inspector retention.
- Persisting full inspector activity history across application launches.
- Adding Validator speech, tools, or a synthetic persistent conversation.
- Adding Security direct messaging.
- Making the Summarizer speaker placeholder functional.
- Replacing the Memory Browser.
- Reworking embedding/ranking algorithms or consolidation thresholds.
- Revisiting the already-fixed system-message sender attribution except for regression coverage.

## Recheck checklist before implementation is declared complete

1. Compare the finished behavior against every acceptance criterion above.
2. Confirm one source of truth for each surface:
   - Agent/model turns: runtime callbacks into `AgentInspectorStore`.
   - Validator truth: task `CriterionVerdictRecord` ledgers.
   - Memory truth: committed `MemoryStore` operations and query results.
3. Confirm no success record is emitted before its operation commits.
4. Confirm every provider suspension uses a captured immutable request snapshot.
5. Confirm no old retained row is silently renumbered or presented as complete after truncation.
6. Confirm `0 results` never means `not searched` in UI or accessibility text.
7. Confirm returned-memory content is the query-time snapshot, not a later lookup.
8. Confirm consolidation failures are not mislabeled as affirmative `DIFFERENT` decisions.
9. Confirm role-specific pop-outs reuse the shared shell and common transcript/turn components.
10. Confirm large histories are absent from collapsed sidebar view trees.
11. Inspect `git diff` for unrelated changes and preserve all pre-existing work.
12. Run focused tests, the full test suite, and the required Xcode build; resolve all warnings.
