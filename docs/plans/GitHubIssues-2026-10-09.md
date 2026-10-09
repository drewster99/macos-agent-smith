# GitHub issues plan — 2026-10-09

Triage of every open issue on `drewster99/macos-agent-smith`, cross-checked with codex.

- **Closed as already resolved:** #9 (live model switch: `scheduleModelChange` + `ModelSwitchHistory.adapt`; non-agent holders refreshed by `setProviders`; `AgentCardRunningModelNotice`).
- **Partial:** #14 (provide_help passes the task; the task-less spawn path remains), #16 (credits-depleted already holds the task via `ProviderUnavailableKind.paymentRequired`, but never re-checks).
- **Not addressed:** everything else below.

Constraints for this run: the app is running from Xcode — no Xcode test runs, never stop the run. Package tests run from the terminal (`swift test`), and the `.build` folder it creates is deleted afterward. Every bug fix gets a failing regression test first.

Order: correctness bugs → designed features → UI → tests/docs. Within a tier, smaller blast radius first.

---

## Tier 1 — correctness bugs

### #1 Process-wide SIGPIPE ignore in `MCPClientHost`
**Root cause.** `MCPClientHost.swift:128-137` calls `signal(SIGPIPE, SIG_IGN)` from a static initializer.
**Fix.** We own the MCP child's stdin pipe (`launchProcess`, `MCPClientHost.swift:~522-554`, which hands `StdioTransport` the raw write fd). Set `fcntl(fd, F_SETNOSIGPIPE, 1)` on that write fd before `process.run()`. That is per-open-file and macOS-native: an EPIPE becomes the thrown `MCPError.transportError` that `MCPBridgedTool` already catches. Delete the global ignore. If `fcntl` fails, the launch fails (fail closed) and is reported through the existing server-status path.
**Audit.** Nothing else depends on the global ignore:
- `ProcessRunner` gives the child `/dev/null` as stdin.
- `MCPProcessEnvironment` gives the child the null device as stdin.
- Every other `Process` user only reads.
- Networking sets `SO_NOSIGPIPE` itself.
**Tests.**
- With the read end closed, a write to the fd returns `-1/EPIPE` and `F_GETNOSIGPIPE == 1`.
- `MCPClientHost.init` leaves the SIGPIPE disposition unchanged (`sigaction` before/after).

### #13 1-hour cache writes priced at the 5-minute rate
**Root cause.** Four copies of the cost formula call `effectiveRates(totalInputTokens:)` without `extendedCache:`:
- `CostBoard.swift:~448`
- `UsageAggregator.swift:~77`
- `AppViewModel.swift:~3062`
- `TaskCostDetailSheet.swift:~262`

`TaskCostDetailSheet` also returns 0 for a nil `providerID`, where the others look pricing up anyway.
**Fix.**
- `UsageRecord.configuration` is already the typed per-call snapshot of the config the request was sent with, so its `extendedCacheTTL` is the fact. No new stored field and no JSONL schema change.
- A missing snapshot means 5-minute pricing. That is explicit and documented.
- New `UsageRecord+Cost.swift` holds `usedExtendedCacheTTL`, `costBreakdown(pricing:)` and `cost(of:pricingLookup:) -> Double?` (nil = unpriced).
- All four sites call it. The kit already has the `extendedCache:` parameter, so no kit release is needed.

A flag on a non-Anthropic route prices at the base rate, because that pricing has no `extendedCacheTier`.
**Tests.**
- extended vs standard TTL write rate
- no configuration → 5-minute rate
- extended threshold override above 200k
- unpriced → nil
- CostBoard, UsageAggregator and the helper agree
- legacy JSONL line decodes

### #14 Remaining task-less (unscoped) Brown spawn
**Fix.**
- `spawnBrown(for:)` and `performSpawnBrown(for:)` take a non-optional `AgentTask`. Every production caller already passes one; only `Phase1SupervisorTests:504,518` don't, and they get a task. Those tests check the stopped-runtime refusal, which runs before the task is touched, so nothing is weakened.
- Drop the `if let task` branches.
- Rewrite the stale "(review_work respawn)" comment and the "no task context" scoping comment.
**Test.** A `provide_help` respawn of a task with no live worker, with scoping on and a mock Security Agent returning `file_read` only:
- the live worker's tool names include `file_read` and exclude `bash`
- `approvedTools == ["file_read"]`

### #15 A task restored from another session runs in place
**Root cause.**
- Nothing compares `AgentTask.sessionID` with the session's identity. That identity is `TaskStore.sessionID`, set from `Session.id`; it is NOT `runtime.currentSessionID`, which is a per-run UUID.
- `restoreFromInactive` keeps the foreign `sessionID`.
- `prepareForRun` then resets the task in place.
**Fix.**
- `TaskStore.originatesElsewhere(_:)`: true when the store has a session, the task is not a template, and `task.sessionID != store.sessionID`. A nil task session counts as foreign. A store without a session never reports foreign.
- `TaskStore.cloneForRunInThisSession(sourceID:)`, one write, modelled on `instantiateTemplate`:
  - Copies title, description, attachments, user tool overrides, the acceptance-gate flag, required capabilities, `parentTaskID`, and template-input definitions/values.
  - Copies active steps, reset to pending.
  - Gives criteria fresh ids and no verdicts.
  - Stamps this session and sets status pending.
  - Drops the coordinator link, watches, holds, result, validation, approved tools, assignees and saved context.
  - Notes the clone on both tasks.
- `prepareForRun` leaves a foreign task untouched (`.ready`), the same as templates.
- `resolveStartTarget` (the one start chokepoint): template → existing branch; foreign → clone and run the clone. Share the template branch's announce tail (amendment, context retrieval, note, `.taskCreated` banner); lineage key `clonedFromTask`.
- `drainPendingTaskQueue` skips foreign tasks, so auto-advance can't re-clone forever. They start only explicitly.
- `RunTaskTool` output tells Smith it ran as a copy. This is model-facing text only.
**Tests.** Store level:
- `originatesElsewhere` truth table
- clone field matrix
- `prepareForRun` foreign no-op

Runtime level:
- Play on a foreign task runs a clone with the original untouched
- `run_task` on an archived foreign completed task clones
- auto-advance never clones
- an amendment lands on the clone
- a nil-session legacy task is cloned
- same-session restore runs in place
- a template stamped elsewhere instantiates once

### #16 Codex credits depleted: park + hourly re-check
**State.** `LLMRetryPolicy` returning `.permanent` is correct: it means "don't retry in the loop". The runtime then holds the task (`.interrupted`, "on hold") via `.paymentRequired`. Missing:
- an hourly re-check that self-resumes, per the settled ROADMAP decision
- the specific "credits" reason, and the owner vs member distinction
**Fix.**
- **New kind.** `ProviderUnavailableKind.creditsDepleted(userCanResolve:)`:
  - display "the account's credits are used up"
  - retry text: owner "top up", member "ask a workspace owner", both "(re-checked hourly)"
  - `recheckInterval` from the named constant `creditsRecheckSeconds = 3600`
- **Re-check loop.**
  - Driven by the existing `workerOutage` breaker: when it trips with a re-checking kind, start one probe loop (one per outage).
  - The probe is a minimal `send` on the worker's provider, through `ProviderWaitBoard`, with usage recorded.
  - Success → `releaseProviderOutage(because: .recheckSucceeded)`; held tasks drain on the existing path. The same failure kind → re-arm silently (still one advisory per outage). Other errors → re-arm and log.
  - Cancelled by release, model change, Play and `stopAll`.
- **Spend cap.** `.spendControlReached` stays on hold with no re-check. It is an administrative cap with no balance to poll; Play or a model change releases it.
- **Scope.** Non-worker roles are out of scope (noted in the ROADMAP).
**Tests.**
- `codexLimits` mapping for owner and member
- self-resume when the re-check succeeds (exactly one advisory)
- still depleted → stays held silently
- transient error re-arms
- the spend cap never probes
- Play cancels the loop; a model change cancels the loop
- the constant is pinned

### #28 `task_complete` evidence sweep misses subdirectories
**Fix.**
- `ingestEvidenceDirectory` walks the tree with `FileManager.enumerator` (skips hidden files and package descendants, regular files only), in a deterministic sorted order.
- The attachment filename is the path relative to the evidence directory.
- Cap: `maxEvidenceFiles = 200`.
- Returns `(attachments, problems)`: a file that can't be read or ingested, an unreadable directory, and hitting the cap are all reported in `task_complete`'s output (and the posted message) instead of being dropped silently.
- Replace the `try?` sites with handled errors.
**Tests.**
- nested files ingested with relative names
- hidden files and directories skipped
- the cap is reported
- an unreadable file is reported
- existing dedup tests still pass

### #23 "Next: <time>" chip missing on scheduled rows
**Root cause** (from code and data; the refresh chain was verified to work):
1. Wakes belong to one session's runtime, but library templates — which carry recurring wakes — are listed in every window. Any session other than the scheduling one, or the scheduling session before its runtime starts, shows no chip.
2. `refreshActiveTimers` publishes `[]` while the runtime or wake scheduler is nil: a blocked start, after Stop or Abort, and before start.
3. Paused or awaiting rows use the running layout, which has no chip.
**Fix.**
- **Kit.** `PendingWakeIndex.build(_:now:)` is a pure function holding the existing filter, grouping and sort logic.
- **SharedAppState.** `publishScheduledWakes(sessionID:wakes:)` keeps the wakes per session and builds one merged index (task ids are UUIDs). `removeSessionObservers` drops the session's entry.
- **AppViewModel.**
  - Publishes `activeTimers`, and `pendingWakesByTaskID` reads the shared index.
  - Seeds `activeTimers` from the session's persisted `scheduled_wakes.json` at load.
  - Stops overwriting it with `[]` while there is no runtime.
- **Running layout.** Shows the indicator when the status is not `.running`/`.starting`/`.validating`.
**Tests.**
- `PendingWakeIndex`: drops nil task id and past wakes, groups, sorts
- the merge across two sessions

---

## Tier 2 — designed features

### #17 Validation economics
1. **Forced final verdict** (`EvaluationRunner`).
   - The last allowed turn, or a near-deadline turn, sends `tools: []`, preceded by a verdict instruction if the previous turn was a tool round. Mirrors `SecurityEvaluator`'s `offerTools`.
   - A tool call on the forced turn is never executed. If its text parses as a verdict, accept it. Otherwise pair each call with a synthetic "not executed" tool result and spend one repair turn (`maxForcedVerdictRepairs = 1`).
   - The error becomes "no conforming verdict after forced final turn (N turns)", classified `forced_verdict_failed`.
   - `maxTurns == 1` is forced from turn 1, with no extra user message.
2. **Rejection-history seed.**
   - `previousRejectionSeed(history:criterion:)`: same-contract rejections only, latest text plus a count, capped at 4,000 chars.
   - Goes into a `previousRejection` payload field for ordinary validator runs only: not prepare, not per-item.
   - The system prompt gets an anti-anchoring bullet: judge the current state fresh, accept if the issues are resolved, add nothing beyond the criterion.
   - Payload text only, never a verdict record, so settled counts can't change. Replaces the "no prior verdict on purpose" comment.
3. **Identical-rejection convergence.**
   - `TaskValidationState.identicalRejectionStreak(for:)`: newest-first run of consecutive-round rejections of that criterion whose normalized reasons (lowercased, trimmed, whitespace collapsed) are equal.
   - Compares validator output to validator output, never to a fixed phrase. A paraphrase only costs the existing budget, so it fails safe.
   - Fails when the no-new-approval count ≥ `maxIdenticalRejectionRounds` (3) AND some criterion's streak ≥ 3.
   - Typed outcome: `ValidationRoundOutcome.failedIdenticalRejections`, plus `NonConvergenceBasis` on `.validationFailedNoProgress`. Smith's briefing says the criteria are deadlocked and should be rewritten.
4. **Unjudged vs rejected.**
   - `CriterionTally` (settled/rejected/errored/unjudged/total) and `summaryText` live in the kit.
   - Used by `TaskDetailWindow` and `TaskOverlayBar`.

**Tests:** listed per part in the agent analysis, chiefly in `EvaluatorFrameworkTests`, `TaskValidationModelTests`, `TaskValidationCoordinatorTests` and `ValidationMetricsLedgerTests`.

### #18 First-class task preconditions and a fail-fast blocked outcome
**Decision: blocked = `status == .failed` + a stored `preconditionFailure` record**, surfaced as `TaskOutcome.blocked`. It is not a new `Status` case:
- An old build decodes an unknown status as `.interrupted` and would auto-resume — re-run — a blocked task.
- Every terminal-failed behavior (slot refill, wake cancel, watches, coordinator notes, `run_task` reset) is already right.

**Model.**
- `TaskPrecondition { id, kind, failureMessage, origin }`
- `Kind`: `workerModelSupports(vision|pdf)`, `fileExists(path)` (absolute or `~`), `commandAvailable(name)`, `workerAttested(statement)`, and `unknown` (fail closed)
- `PreconditionFailureRecord`
- `AgentTask.preconditions` and `preconditionFailure`: decode-if-present, encoded only when non-empty; templates copy them to instances.

**Status.**
- New cause `.preconditionUnmet(checkedBy:)`, from startable or running states → `.failed`.
- `changeStatus` refuses it without a record, and clears the record on any exit from `.failed`.
- Single writer: `TaskStore.blockOnPrecondition`.
- Never touches the validation counters or the ledger.

**Checks.**
- Authoritative mechanical check at start, in `performStartTaskWithLiveSmith` after the claim and before capacity and spawn, and on the cold-start resume path.
- Advisory "currently unmet" note in `create_task` and `set_preconditions`.

**Worker tool.** `report_precondition_unmet(precondition_id, evidence)` (Brown):
- declared ids only (undeclared blockers still use `request_help`)
- only while running
- tears down the worker the way `failValidation` does

**Smith.**
- `set_preconditions` (gated by `isValidationContractEditable`; can't remove the failed one or a user-authored one)
- a `create_task` parameter
- a briefing note
- `run_task` re-checks the mechanical preconditions and refuses if they are still unmet

**Prompt and UI.**
- The prompt's HARD GATES rule becomes "use a precondition, not a criterion".
- UI: a Blocked badge and a preconditions section in Task Detail; a `task_blocked` message kind.

**Tests:** transition matrix; outcome short-circuit; coding compatibility; evaluator kinds; start gate (no spawn, before capacity, a pause wins); tool refusals; `set_preconditions` gating; `run_task` re-check; Smith briefing; watch fires `.failed`; message-kind table.

---

## Tier 3 — UI

### #35 Top task-card click selects the task's transcript
- `TaskOverlayColumn` gets an optional `onSelect` and `isSelected`. The body is wrapped in a plain `Button`; tear-off and dismiss stay nested buttons, the sidebar's pattern.
- The action sets `viewModel.selectedTaskID`, the single source of truth that the sidebar drives.
- Collapsed strip items likewise.
- Torn-off panel windows: no selection.
- Selection tint matches the sidebar.

**Verify:** manually in the running app.

### #32 Attachment caps apply live
- `SharedAppState` cap `didSet`s notify registered observers (the auto-archive/orchestration pattern). Observers are removed in `removeSessionObservers`.
- `AppViewModel` registers at start and pushes both caps through a serialized task, so the last value wins.
- Settings text: "Changes apply immediately to all sessions."

**Test:** a runtime cap change is visible to `currentMaxAttachmentBytesPerMessage()`.

### #25 Temperature slider clamped to `maxTemperature`
- Range `0...(modelInfo?.maxTemperature ?? 2)`.
- A saved override above the max is left untouched, with an inline warning like the off-ladder effort warning.
- The slider gets a clamped binding for display only, and never writes unless the user drags. Writes nothing on appear.

### #26 Sidebar acceptance-progress chip
- `TaskAcceptanceProgressChip` ("3/5") in `TaskRowMetadataLine`.
- Counts come from `settledCriterionIDs(in: acceptanceCriteria)`.
- Hidden with no criteria or no ledger, and for templates.
- Styled like `TaskCostChip`.

### #27 PDF export: acceptance criteria and steps
- "Acceptance criteria": each criterion's name plus its latest verdict (accepted / waived / rejected / not yet judged), from `latestVerdict`.
- "Steps": active (non-removed) steps in order, with status.
- Each section is omitted when empty, in the existing section style.

### #24 `ProviderManagementView` helpers → View structs
- `builtInSection`, `customSection`, `customProviderRow` and `endpointPresetMenu` become private `View` structs.
- The Keychain lookup is hoisted so it isn't repeated per render. `hasAPIKey` is computed once per section body and passed in as `let`.
- `someViewFunctionBudget` goes from 4 to 0, with the total updated.

### #33 `ChannelBannerKind` maps from `ChannelMessageKind`
- No raw values.
- `init?(_ kind: ChannelMessageKind)` with an exhaustive `switch`, so a new message kind forces a decision there.
- Call site: `message.kind.flatMap(ChannelBannerKind.init)`.

### #34 Transcript scrolling → `.scrollPosition`
- Replace `ScrollViewReader`/`proxy.scrollTo` with `@State ScrollPosition` + `.scrollPosition($position)`.
- Bottom pinning is unchanged: pinned while at the bottom, no yank when scrolled up, using the existing at-bottom tracking.
- Jump-to-message and anchor restore become `position.scrollTo(id:anchor:)`.
- Keep the "last id that actually has a view" target logic.
- Verified manually with a long live transcript.

### #19 Accessibility baseline
- Every icon-only `Button` and `Menu` gets an `.accessibilityLabel`, reusing its `.help` text.
- Stable `.accessibilityIdentifier`s for Start, Stop All, Send, task Pause/Stop and Mute/Unmute.
- Custom rows (channel banners, inspector rows) get `.accessibilityElement(children: .combine)`.
- A guard test scans the app sources for an icon-only `Button` label with `.help` but no `.accessibilityLabel` in the same modifier chain (ratchet).

---

## Tier 4 — tests and comments

### #22 `ToolResultCap` tests
- At or under the limit, including exactly at the boundary → unchanged.
- One character over → head marker plus a preview of exactly `previewCharacters`, a path under `overflowDirectory`, and a file byte-identical to the input.
- Multibyte input → no split grapheme, exact round trip.
- Two overflows → two distinct files.
- Cleanup.

### #30 Tests for the ten untested tools
Each tool gets:
- argument parsing (missing, empty, malformed optional arguments)
- the success path
- every refusal

All assertions are on `ToolExecutionResult.succeeded`. The AppleScript tools are tested only on argument validation and the paths that don't launch AppleScript.

### #31 `Phase2LongLivedSmithTests` finds workers by task
- Replace `agentIDForRole(.brown)` with `liveWorkerID(taskID:)`.
- Revert the raised poll timeout only if the test proves stable.
- Run the suite repeatedly.

### #29 `glob respect_gitignore`
- Optional bool via `ToolArguments.optionalBool`, default false.
- When true: find the work tree (`git -C <root> rev-parse --show-toplevel`), then filter results with one `git check-ignore --stdin -z` batch.
- Not a repo, or git missing → the result says the flag could not be applied (never silently ignored).

**Tests:** ignored file filtered; non-repo note; flag absent or empty → unchanged.

### #20, #21 Stale comments
- Rewrite the "BY NAME" comment: the replace-all path matches by id.
- Drop "legacy validator selection" from the comment.
- Fix the `review_work` comments (AgentActor ~3083, OrchestrationRuntime ~5032 and ~6239, and any others found by grep) and the MainViewDetailColumn "TODO" (shipped as `CrossSessionTranscriptView`).
- No behavior change.

---

## Decisions taken without the user (to review)
1. **#16:** follows the settled ROADMAP decision (park + hourly re-check) for credits only. The spend cap stays held with no re-check.
2. **#18:** blocked is stored as `.failed` + a typed record, not a new `Status` case (compatibility with older builds). Adds one Brown tool and one Smith tool — an architectural addition the issue explicitly requests.
3. **#15:** a foreign task is always cloned, never run in place, and auto-advance never starts it.
4. **#13:** reuses the existing `UsageRecord.configuration` snapshot instead of adding a stored field.
5. **#1:** per-fd `F_SETNOSIGPIPE` instead of any signal-disposition change.

---

## Review consensus (codex + independent Claude session)

Both reviewers checked every section against the code. Where they raised a point, the plan is amended as follows. These amendments override the sections above.

**Cross-cutting**
- **Edits to existing tests.** Some fixes make an existing test's call shape or pins obsolete:
  - #14: `Phase1SupervisorTests` spawn calls
  - #16: `ProviderOutageTests.codexLimits` mapping
  - #18: new message-kind rows in `ChannelMessageKindTests`
  - #33: `InspectorRecomputeCacheTests` raw-value assertion
  - #31: the issue itself asks for the test edit

  These are edited only to follow the API or the new case; no assertion is weakened. Logged as a decision.
- **Coverage tests that can't fail first** are labelled as coverage: #14's type change is the real guard; #22, #30 and #31 are test-only issues.
- **One acceptance tally.** `CriterionTally` (#17) is the only computation. #26's chip and the coordinator's counts use it.

**#1** Extract `MCPClientHost.disableSIGPIPE(onWriteFD:)`, called by `launchProcess` and tested directly. Tests are `.serialized`; they force `SIG_DFL` for their duration and restore it afterwards, so a regression kills the run loudly.

**#13**
- The decision stands: intent is taken from the `UsageRecord.configuration` snapshot.
- OpenRouter `anthropic/*` does send `ttl: "1h"`, and the catalog has 1-hour rates for it, so those calls are priced correctly too. The earlier "non-Anthropic prices at base" claim is withdrawn.
- Accepted limit: the flag records the TTL we asked for, not the TTL the server confirmed. The exact split (`cache_creation.ephemeral_1h_input_tokens`) would need a swift-llm-kit usage-shape change; recorded in "What's left".
- The helper stays synchronous (`CostBoard.recordInserted`).

**#14**
- Every optional-task use goes non-optional, including `admitsWorker(for:)`.
- The dead `assigneeIDs` match, which existed only for the retired task-less flow, is removed. The task stamp is the binding.
- Fix the stale "single Brown policy" comment.

**#15** Redesigned around one resolver.
- `TaskStore` resolves a foreign task, active or inactive, to a clone, synchronously.
  - `RunTaskTool` clones BEFORE any restore or amend, applies the amendment to the clone, and returns the clone's id to Smith.
  - The original is never restored, re-homed or amended.
- `resolveStartTarget` keeps the same guard for Play, scheduled starts and watch starts.
- Foreign tasks are excluded from every automatic path:
  - the drain's candidate lists, before `prefix(freeSlots)`
  - cold-boot launch resume
  - the cold-boot "starts automatically" list
  - `rearmScheduledTaskWakes`
- The clone resets or omits `pendingEffects`, `scheduledRunAt`, `childTasksCreated`, `statusRevision`, `resultAttachments`, `updates` and `pendingWorkerMessages`.
- Retry state (context, steps) deliberately does not carry across sessions: the invariant is one task per session transcript.

**#16**
- Outage generation token, re-checked after every `await` before releasing.
- One trip function starts the loop.
- Probe failures:
  - a newly permanent kind (for example a spend cap) re-classifies the outage and stops probing
  - a different error is surfaced once, not silently swallowed
- The probe:
  - goes through the shared `LLMRetryPolicy` and `ProviderWaitBoard`, with new reason and purpose cases
  - emits an `LLMCallEvent`
  - pins low effort
- Correct names: `ProviderUnavailableKind.spendLimitReached`.
- The ROADMAP's stale "fails the task" line is fixed. A relaunch loses the loop; Play is still the documented retry.

**#17**
- **Part 3 is ADVISORY ONLY.** Both reviewers agree that terminating on prose equality breaks CLAUDE.md's "never drive behavior by matching free text". An identical-rejection streak of 3 or more:
  - posts one `.warning` notice naming the deadlocked criteria
  - adds a briefing note telling Smith to consider rewriting them

  Termination stays on the typed no-new-approvals budget.
- The streak is computed from `verdictRecords`, which carry rounds.
- **Part 1:**
  - The forced-turn instruction is grammar-specific (prepare runs use JSON-array wording).
  - `contradictedToolClaim` still applies.
  - Hard bound: `maxTurns + 1` calls.
  - Use `toolChoice` text-only if the kit supports it (cache-friendly); otherwise `tools: []`.
  - Fold any pending attachment drain into the same user turn.
- **Part 2:** the seed uses `statesSameContract`. The comment rewrite cites the ROADMAP reversal and keeps the anti-anchoring rationale.
- **Part 4:** the tally shows criteria in flight as "judging", not "rejected", while the task is validating.
- The new persisted enum payloads are optional (Codable compatibility).

**#18**
- **One `PreconditionEvaluator`** called at every spawn site: the live-Smith start, the cold start, launch resume, the `provide_help` respawn and the validation-recovery respawn. `run_task` re-checks too.
- **Vision capability** carries known vs unknown into the gate (fail closed).
- **`commandAvailable`** runs through the login shell, with the name passed as `$1` (no splicing).
- **`fileExists`** accepts absolute paths or `~/` only.
- **Worker tool:**
  - tears down through a `ToolEffect`, not a self-terminate
  - wired into forced availability, the lifecycle sets, `autoApprovedToolsByRole[.brown]`, `knownBuiltInNames` and the tool groups
  - the runtime re-verifies a mechanical precondition the worker reports
- **Protected preconditions** (the failed one, user-authored ones) can't be rewritten under the same id either.
- **Authored fields:** template substitution covers precondition text; `optionalArray` for `create_task`; authorship reuses `TaskAuthorship`.
- **A block at start** kicks the drain.
- **Downgrade risk:** an older build drops the preconditions field when it rewrites `tasks.json`. Documented.
- `workerAttested` stays because the issue explicitly asks for a worker fail-fast path. It is limited to declared ids and logged as a decision against the ROADMAP's earlier rejection.

**#23**
- Corrected cause: only a nil runtime clears the list (a nil scheduler keeps it).
- Fix, in-architecture and display-only:
  - Wakes stay owned by their session.
  - A kit-side `PendingWakeIndex` builds the per-session index.
  - `SharedAppState` publishes a read-only display index tagged with the owning session.
  - A row in another session shows the chip; its popover is read-only ("scheduled in <session>"), and cancel is offered only in the owning session.
  - No seeding from disk (it would be a second source of truth).
  - The running layout shows the chip only (no timestamp fallback) for paused and awaiting rows.
- Sessions that were never opened publish nothing: accepted limit.

**#24**
- Credential state is memoized outside rendering, keyed on `apiKeyChangeCounter`. The Codex sign-in state is preserved.
- `endpointPresetMenu` takes a `@Binding`.
- Bodies are split to stay within the 20-line rule.

**#25** The over-max warning already exists. Only the range changes, guarded for a positive, finite `maxTemperature`, through a named default constant. The override toggle's seed value is clamped to the max.

**#26**
- The chip appears in all three layouts (standard, running, compact) and comes from `CriterionTally`.
- Not cost-orange; it gets `.help` and an accessibility label.
- With criteria but no ledger yet it shows "0/N", consistent with Task Detail.

**#27**
- The verdict list covers all four states, including `.error`, through the existing `displayLabel`/`detailText`.
- One block per item, for pagination.
- A `TaskPDFFieldOptions` toggle for each section; the `.transcript` preset is unchanged.

**#28**
- Dedup by bytes, matching the filename against either the relative or the last path component.
- Resolve symlinks on both sides.
- Check `.fileSizeKey` before reading; aggregate byte cap.
- Every ingest error is reported, including the previously discarded `ingestAttachmentData` error.
- Symlinks are never followed, and are reported.
- A missing evidence directory is a no-op.
- MIME type from `AttachmentRegistry`'s table (one source).
- Nested explicit-plus-swept regression test.

**#29**
- `ProcessRunner` wires stdin to `/dev/null`, so `git check-ignore` gets paths as chunked arguments, with `-c core.fsmonitor=false`.
- Exit codes: 0 = some ignored, 1 = none, other = failure, reported.
- Git availability is checked without triggering the Command Line Tools install dialog.
- The flag is persisted in `WalkState` for resume.
- Filtering happens before paging and counts, for both Spotlight and walk results. Ignored directories are pruned during the walk.
- Tests: resume; a root below the repo root; a non-repo root.

**#30** Tools covered:
- Abort, CancelWake, ListScheduledWakes, RescheduleWake, ScheduleTaskAction
- ManageTaskDisposition, SearchMemory
- RunAppleScript, ListScriptableApps, GetAppScriptingSchema

Tests assert expected throws, persisted state on success, and no mutation on refusal. Tests that depend on MLX or on which apps are installed pin only the deterministic refusals.

**#31** Keep the timeout, which guards only the Smith-context polls. Add the lost "only worker" assertions: the old worker is gone, and the refused task has no worker.

**#32**
- One chained push task reads the current values when it runs.
- Push again once the runtime is assigned (closes the start window).
- The test covers the app-side chain: Settings → observer → runtime, for both caps.

**#33** Exhaustive mapping. The `InspectorRecomputeCacheTests` raw-value assertion moves to the mapping.

**#34**
- There is no jump-to-message: only `scrollToLatest` and the `loadEarlier` anchor.
- Use `scrollTo(edge: .bottom)` for pinning and `scrollTo(id:)` for the anchor restore.
- Fix the existing bug: `EmptyView` rows still carry an `.id`.

**#35**
- No conditional in `body`: a separate selectable wrapper view; the torn-off panel uses the plain column.
- The selection tint is centralized in `AppColors`.
- Manually verified that nested buttons and scrolling stay independent.

**#19**
- The scanner uses the comment- and string-aware helper, and skips `Button("…", systemImage:)` (already labelled).
- Identifiers carry per-task or per-role suffixes where duplicated.
- Manual VoiceOver check of nested controls.

**#22** Covers the write-failure fallback through an injectable directory. Tests delete only the files they created.

**#20 / #21** Comments explain why (display uniqueness), not what. Also fix `TaskValidationCoordinator:1427`.
