# SwiftUI Code Review — Agent Smith

Reviewer: SwiftUI specialist · 2026-04-27

Scope: `AgentSmith/AgentSmith/` (App, ViewModels, Views, Styling) — 17 view files, 4 view models, App entry, AppStyling, Assets — totalling **10,493 LOC**. Plus the UI-touching surfaces of the local package (`OrchestrationRuntime` callbacks, `TaskStore`, `MessageChannel`, `AgentInspectorStore`).

Findings are graded against your project rules in `CLAUDE.md` and the global SwiftUI/Swift rules in `~/.claude/CLAUDE.md`.

---

## 1. Executive summary

The architecture is fundamentally sound: per-session `AppViewModel`s with their own runtimes, `@Observable` everywhere (zero `@ObservedObject`), proper actor isolation, scene plumbing for multi-tab windows, and several hard-won concurrency patterns (`SerialPersistenceWriter`, `isApplyingPersistedState` flag, in-flight `Task` deduplication). State ownership and per-session isolation contracts are followed cleanly.

The themes that need attention are mostly **surface polish and project-rule conformance**, not architectural:

1. **`: some View` properties pervade the UI layer** — 44 instances across 10 files. `CLAUDE.md` calls this an antipattern and forbids it. This is the single largest rule violation, concentrated in the four 1k+ LOC views.
2. **`.onTapGesture` on tappable controls** — 14 instances; most are `Button` candidates per the explicit project rule, with measurable accessibility and keyboard-focus consequences on macOS.
3. **Hardcoded colors and inline `.font(.system(size:))`** — 30+ color leaks, 33 inline font literals, 61 hardcoded `.foregroundStyle(.<color>)` calls. `AppColors` and `AppFonts` exist; they're under-used. The asset catalog has only `AccentColor` + `AppIcon`.
4. **`.onChange` mutating @State without `DispatchQueue.main.async`** — direct violation of the project rule in several views (`AgentModelSettingsSection`, `MemoryEditorView`, `InspectorView`, `AgentInspectorWindow`).
5. **Zero accessibility surface** — no `.accessibilityLabel`, `.accessibilityHint`, or `.accessibilityIdentifier` calls anywhere. VoiceOver works only via auto-derived labels; UI tests have nothing stable to target.

Two systemic positives worth keeping: the `Equatable` conformances on `ChannelLogView` and `MarkdownText` (cuts re-renders dramatically); the `AgentInspectorStore` pattern of decoupling inspector data from `AppViewModel` (so inspector pushes don't invalidate `MainView.body`).

### Severity rollup

| Severity | Count | Notes |
| --- | --- | --- |
| **P0** — direct project-rule violations | ~75 | Mostly `: some View` (44), `.onTapGesture` over `Button` (14), `Lazy*` (2), List for variable-height (4), inline color/font literals concentrated in ChannelLogView/InspectorView |
| **P1** — correctness & concurrency | 12 | `.onChange` @State mutation without `DispatchQueue.main.async`, recursive `.onChange` self-mutation in `AgentModelSettingsSection`, `@State`-from-init in `AgentConfigSheet` |
| **P2** — architecture & decomposition | 8 | Four files >800 LOC, repeated `.filter` recomputation in body, monolithic `MessageRow` switch ladder, `ModelStats` rebuilt every body |
| **P3** — modern API & accessibility | 3+ | Zero a11y surface; 2 deprecated `.foregroundColor`; opportunity for `@Bindable` over `Binding(get:set:)` glue |

---

## 2. P0 — Project-rule violations

### 2.1 `: some View` properties besides `body` (the project's #1 rule violation)

`CLAUDE.md` (SwiftUIRules): *"AVOID having properties other than 'body' with a signature of `var somePropertyName: some View`, with or without the viewbuilder annotation, in your SwiftUI views. This is an antipattern."*

These computed view properties take a hidden re-render hit (SwiftUI can't track their dependencies the way it tracks subviews) and obscure invalidation. The fix is to either inline into `body`, factor each into a real `View` struct, or convert to a `@ViewBuilder` *function* (the rule excludes functions — only properties are flagged).

**44 instances** (each one a P0):

`ChannelLogView.swift`
- **[P0]** :772 — `toolRequestBody`. Fix: extract `ToolRequestRow` struct.
- **[P0]** :783 — `fileWriteRequestBody`. Fix: extract `FileWriteRequestRow` struct.
- **[P0]** :909 — `genericToolRequestBody`. Fix: extract `GenericToolRequestRow` struct.
- **[P0]** :1042 — `standaloneToolOutput`. Fix: extract `StandaloneToolOutputRow` struct.
- **[P0]** :1955 — `expandedBody` (in `MemoryBanner`). Fix: extract `MemoryBannerExpandedBody` struct.
- **[P0]** :2025 — `imageView` (in `AttachmentView`). Fix: extract `AttachmentImageView`.
- **[P0]** :2048 — `fileBadge`. Fix: extract `AttachmentFileBadge`.

`InspectorView.swift`
- **[P0]** :779 — `turnHeaderLabel`. Fix: inline into `DisclosureGroup` label closure.
- **[P0]** :809 — `responseTypeBadge`. Fix: extract `ResponseTypeBadge` struct.
- **[P0]** :968 — `modelInfoBar`. Fix: extract `TurnModelInfoBar` struct.

`SpendingDashboardView.swift` (the most repeated offender — 11 instances)
- **[P0]** :192, :252, :291, :427, :560, :762, :811, :854, :874, :908, :928 — `headlineCard`, `deltaLabel`, `costOverTimeChart`, `breakdownPanels`, `taskLedger`, `headerSection`, `costBreakdownSection`, `efficiencySection`, `toolUsageSection`, `configurationSection`, `turnTimelineSection`. Fix: extract each into a small `View` struct (one struct per section). This file is the strongest candidate for decomposition — see §4.

`AgentModelSettingsSection.swift`
- **[P0]** :144, :266, :321, :381 — `modelDropdown`, `parametersSection`, `thinkingSection`, `cacheTTLSection`. Fix: extract `ModelDropdown`, `ParametersSection`, `ThinkingSection`, `CacheTTLSection` structs.

`ModelConfigurationEditorView.swift`
- **[P0]** :59, :66, :78, :103, :146, :200, :209, :233 — eight section properties. Fix: same pattern.

`MemoryEditorView.swift`
- **[P0]** :165, :242, :309, :364, :580 — `statsFooter`, `headerBar`, `memoryList`, `newMemoryRow`, `taskSummaryList`. Fix: extract structs.

`SettingsView.swift`
- **[P0]** :55, :129, :328 — `generalTab`, `configurationsTab`, `audioSettingsSection`. Fix: each becomes a top-level struct (`GeneralTabView`, `ConfigurationsTabView`, `AudioSettingsView`).

`ProviderManagementView.swift`
- **[P0]** :59, :87, :426 — `builtInSection`, `customSection`, `endpointPresetMenu`. Fix: extract structs.

> Pattern: this antipattern is concentrated in the four largest files (>500 LOC each). Splitting these properties into real subviews simultaneously addresses §4 (decomposition) and gets each file under the 500-line guideline that's emerging as a soft cap in this codebase.

### 2.2 `.onTapGesture` where `Button` is the right primitive

`CLAUDE.md`: *"NEVER use `.onTap` when a `Button` will work. Button is quite flexible and gives us improved accessibility automatically, so use it whenever possible."*

Buttons get keyboard focus, hover/pressed states, accessibility announcements, and right-click affordances for free. `.onTapGesture` gets none of these. Where the visual treatment matters, wrap in `Button { ... } label: { ... }.buttonStyle(.plain)`.

**14 instances** — every one is a P0:

`ChannelLogView.swift`
- **[P0]** :814 — file_write row expand toggle. Fix: wrap the `HStack` in `Button { isExpanded.toggle() } label: { ... }.buttonStyle(.plain)`.
- **[P0]** :922 — `ToolPathText` open-in-Finder. Fix: `Button { openFileOrFallback(path: path) } label: { ToolPathText(path: path) }.buttonStyle(.plain)`.
- **[P0]** :965 — generic tool request expand toggle. Same fix as :814.
- **[P0]** :1102 — "(show less)" tap. Fix: `Button("(show less)") { isExpanded = false }.buttonStyle(.plain).foregroundStyle(.blue)`.
- **[P0]** :1124 — collapsed body expand. Same as :814.
- **[P0]** :1262 — context expand toggle in `TaskCreatedBanner`. Same.
- **[P0]** :1779 — `TaskSummarizedBanner` row expand. Same.
- **[P0]** :2036 — image attachment open lightbox. Fix: `Button { onTapImage?() } label: { Image(nsImage: nsImage)... }.buttonStyle(.plain)`.
- **[P0]** :2090 — lightbox backdrop dismiss. Edge case — backdrop tap. Fix: `Button { onDismiss() } label: { Color.black.opacity(0.85).ignoresSafeArea() }.buttonStyle(.plain)` keeps a11y semantics.
- **[P0]** :2209 — `FileWritePathView` open. Same as :922.
- **[P0]** :2218 — symlink destination open. Same.

`DiffView.swift`
- **[P0]** :86 — diff truncation expand. Fix: `Button { if needsTruncation { isExpanded.toggle() } } label: { HStack { ... } }.buttonStyle(.plain)`.

`InspectorView.swift`
- **[P0]** :158 — model name tap to show stats popover. Fix: wrap `Text(config.modelID)` in `Button { showingModelStats = true } label: { Text(config.modelID) }.buttonStyle(.plain).popover(...)`.

`SpendingDashboardView.swift`
- **[P0]** :602 — task row tap to open detail sheet. Fix: wrap `taskRow(...)` in `Button { selectedTaskID = taskID } label: { taskRow(...) }.buttonStyle(.plain)`.

### 2.3 `Lazy*` containers and `List` for variable-height content

`CLAUDE.md`: *"AVOID all SwiftUI lazy view types - LazyVStack, LazyHStack, LazyVGrid, LazyHGrid and List."*

- **[P0]** `InspectorView.swift:921` — `LazyVStack(alignment: .leading, spacing: 6)` inside `FullContextSheet`. Fix: `VStack(alignment: .leading, spacing: 6)` — the sheet has a finite enclosing height and the rows are short, so non-lazy is fine.
- **[P0]** `SpendingDashboardView.swift:430` — `LazyVGrid` for the four breakdown cards. The grid is exactly 2×2 and never exceeds four cards. Fix: a static 2×2 layout with two `HStack`s wrapping pairs of `breakdownCard(...)` calls.
- **[P0]** `MemoryEditorView.swift:346` — `List` for memory rows (variable-length content). Fix: `ScrollView { VStack { ForEach(...) { ... } } }`.
- **[P0]** `MemoryEditorView.swift:607` — `List` for task summary rows. Same fix.
- **[P0]** `TimersWindow.swift:52` — `List(viewModel.activeTimers, id: \.id)` for active timers. Same fix.
- **[P0]** `TimersWindow.swift:133` — `List(history, id: \.id)` for timer history. Same fix.

> Note: `List` does have a use case for fixed-height rows on macOS (it gets you native selection / column-resizing semantics for free), but neither memory rows nor scheduled-wake rows are fixed-height here.

### 2.4 Hardcoded colors that should be in `AppColors`

`CLAUDE.md`: *"ALWAYS define colors centrally, preferring the app's asset catalog whenever possible, rather than hardcoding them at the point of use."*

`AppColors` exists but is under-populated; the asset catalog has only `AccentColor` + `AppIcon`. The 30+ hardcoded `Color.<name>.opacity(...)` calls below are mostly the same five values (0.04, 0.05, 0.06, 0.08, 0.12) repeated across views. Recommended: add semantic entries to `AppColors` (e.g. `subtleSelectionTint`, `warningRowTint`, `errorRowTint`, `roleRowTint(for: AgentRole)`) and migrate. The asset catalog is preferable per the global rule, but a struct-based approach is acceptable.

Highest-value migrations (visible to the user, repeated):

`InspectorView.swift`
- **[P0]** :568–571 — `Color.secondary.opacity(0.05)`, `Color.blue.opacity(0.05)`, `Color.green.opacity(0.05)`, `Color.orange.opacity(0.05)` — the `ContextMessageRow` role tint switch. Fix: `AppColors.contextRowBackground(for: message.role)`.
- **[P0]** :1509 — `isError ? Color.red.opacity(0.05) : Color.green.opacity(0.05)` (Summarizer activity row). Fix: same kind of helper.
- **[P0]** :867 — `Color.orange.opacity(0.05)` (tool call inspector row). Fix: `AppColors.toolCallInspectorTint`.
- **[P0]** :469, :488, :770, :1204, :1378 — `Color.secondary.opacity(0.05/0.06/0.08)` row backgrounds. Fix: `AppColors.subtleRowBackground` (one constant).

`ChannelLogView.swift`
- **[P0]** :682 — `Color.orange.opacity(0.10)` warning/denied row. Fix: `AppColors.warningRowBackground`.
- **[P0]** :2088 — `Color.black.opacity(0.85)` lightbox backdrop. Fix: `AppColors.lightboxBackdrop` (and pin to a fixed value in light *and* dark mode — `.black` here happens to render correctly, but a named asset future-proofs it).

`DiffView.swift`
- **[P0]** :125, :136 — `Color.red.opacity(0.12)` / `Color.green.opacity(0.12)`. Fix: `AppColors.diffRemovedBackground`, `AppColors.diffAddedBackground`.

`MarkdownText.swift`
- **[P0]** :170, :174, :196, :204 — `Color.secondary.opacity(0.1/0.12/0.2/0.25)` for code-block and table chrome. Fix: two semantic entries (`AppColors.codeBlockBackground`, `AppColors.tableHeaderBackground`).

`SettingsView.swift`
- **[P0]** :307 — `Color.blue.opacity(0.15)` for behavior-flag chip. Fix: `AppColors.flagChipBackground`.

`MainView.swift`
- **[P0]** :119 — `.blue.opacity(0.08)` drop-target overlay. Fix: `AppColors.dropTargetTint`.

`AppStyling.swift` itself
- **[P0]** :22 — `Color(red: 0.85, green: 0.65, blue: 0.13)` (taskCompletedAccent). Fix: move to asset catalog as `Color.taskCompletedAccent`; the global SwiftUI rule prefers compiler-generated names.
- **[P0]** :30 — `Color(red: 0.90, green: 0.35, blue: 0.35)` (changesRequestedAccent). Same fix.

### 2.5 Inline `.font(.system(size:))` literals bypassing `AppFonts`

`CLAUDE.md`: *"ALWAYS define font styles centrally, such as in an `AppStyling.swift`, with semantic names and static members."*

**33 inline `.font(.system(size:))` literals** across views — concentrated in `ChannelLogView` (banner icon sizes 9–13) and `InspectorView` (label sizes 8–11). Each reads as a one-off magic number. `AppFonts` already has `inspectorLabel` (caption, monospaced) and `inspectorBody` (caption2, monospaced); add semantic siblings for the icon-adjacent sizes:

Recommended additions to `AppFonts`:

```swift
static let bannerIcon = Font.system(size: 13)            // 13pt - banner header icons
static let bannerIconSmall = Font.system(size: 11)        // 11pt - banner secondary icons
static let metaIcon = Font.system(size: 9)                // 9pt - inspector / inline meta icons
static let microMonoBadge = Font.system(size: 9, weight: .medium, design: .monospaced)  // 9pt mono badge
```

Then migrate the literal `.font(.system(size: 13))` (lines 1185, 1370, 1427, 1499, 1544 in `ChannelLogView`, and similar) to `.font(AppFonts.bannerIcon)`. Keep this as one PR, since the literal sizes are scattered.

The exception: `MainView.swift:390` — `Image.font(.system(size: 40))` for the welcome-sheet wave icon — is a one-off display size; leave inline or add `AppFonts.welcomeIcon`.

### 2.6 Deprecated `.foregroundColor`

The view-level `.foregroundColor` modifier is soft-deprecated in favor of `.foregroundStyle` (better dynamic-style support, hierarchical styles, etc.).

- **[P0]** `MarkdownText.swift:325` — `Text(...).foregroundColor(.cyan)` (inline code). Fix: `.foregroundStyle(.cyan)` — but per §2.4, this should be `.foregroundStyle(AppColors.inlineCode)`.
- **[P0]** `DiffView.swift:75` — `.foregroundColor(.green)` / `.foregroundColor(.red)` for the +/- counts. Fix: switch to `.foregroundStyle`. (These are the *only* sensible inline colors in the diff context, but the API still wants the modern call site.)

---

## 3. P1 — Correctness & concurrency risks

### 3.1 `@State` mutated inside `.onChange` without `DispatchQueue.main.async`

`CLAUDE.md`: *"NEVER modify @State, @Binding, @Published, @Observed etc variables inside of a `.onChange` closure UNLESS you wrap them with `DispatchQueue.main.async { }`."*

These work in current SwiftUI but are exactly the rule the project chose to enforce. They also create subtle re-entrancy when the modification re-fires the same `.onChange`.

`AgentModelSettingsSection.swift` — the worst offender, with **recursive** mutation:
- **[P1]** :329–349 — `.onChange(of: thinkingBudget) { _, newValue in ... thinkingBudget = 1024 ... temperature = 1.0 ... }`. Mutates `thinkingBudget` (the very @State the closure observes — relies on a comment saying "no double-commit" that's hard to verify by reading) and mutates `temperature`. Fix: `DispatchQueue.main.async { self.thinkingBudget = 1024 }`. The comment-described behavior is correct, but the rule wants the explicit hop.
- **[P1]** :278–284 — `.onChange(of: temperature) { ... thinkingBudget = 0 ... commit() }`. Fix: wrap `thinkingBudget = 0` in `DispatchQueue.main.async`.
- **[P1]** :300–304, :312–316 — `.onChange(of: maxOutputTokens)` / `maxContextTokens` with `if newValue < 1 { maxOutputTokens = 1 }` clamp. Same fix; or move clamp into a custom `Binding` set closure on the `TextField` so there's no `.onChange` self-mutation.

`MemoryEditorView.swift`
- **[P1]** :63–119 — `.onChange(of: searchText)` directly mutates `memorySimilarities`, `taskSummarySimilarities`, `isSearching`, `searchErrorMessage`, `searchStats`. The synchronous-path mutations (lines 67–72, 74–75) are inside the closure body before the `Task`; lines 97–117 inside the `Task` are fine because the Task hops off the immediate stack. Fix: wrap the synchronous mutations in `DispatchQueue.main.async`, or move them into the `Task` body so everything runs after the closure returns.

`InspectorView.swift`
- **[P1]** :347–349 — `.onChange(of: llmTurns.count) { if let last = llmTurns.last { expandedTurnIDs.insert(last.id) } }`. Fix: `DispatchQueue.main.async { ... }`.
- **[P1]** :385–387 — `.onChange(of: isProcessing) { _, newValue in processingStartDate = newValue ? Date() : nil }`. Same fix.

`AgentInspectorWindow.swift`
- **[P1]** :143–145 — same pattern as InspectorView:347. Same fix.
- **[P1]** :163–165 — same pattern as InspectorView:385. Same fix.

### 3.2 `@State` initialized from view init parameters

`CLAUDE.md`: *"AVOID initializing @State and @Binding properties based on values passed in the View initializer. This often results in unexpected behaviors."*

- **[P1]** `InspectorView.swift:1058–1076` — `AgentConfigSheet.init(...)` does `_draftPrompt = State(initialValue: initialSystemPrompt)`, same for `_draftPollInterval`, `_draftMaxToolCalls`. Because this is sheet content presented via `.sheet(isPresented:)`, the sheet view is reconstructed each time it appears, which is why this works in practice — but the rule is there because subtle reuse cases break the pattern. Fix: change the pattern to `.task` — give each draft a default `@State`, then in `.task { draftPrompt = initialSystemPrompt; ... }` (or use `.onAppear`). Alternatively, lift draft state to the parent and pass `@Binding`s.

### 3.3 Computed properties recomputed on every body invocation

These aren't direct rule violations (the project rule is about computed *views*, not computed values), but they materially impact performance — see §4.

- **[P1]** `ChannelLogView.swift:150–200` — `toolRequestIDs`, `securityReviewByRequestID`, `toolOutputByRequestID`, `taskIDsWithSchedulingBanner` each iterate `messages` once per access. Mitigated by caching as locals at lines 222–225, but the helper properties themselves still allocate fresh sets on each `body`. Fix: keep the locals; mark the helpers `@inlinable` is fine, but consider folding them into a single one-pass `MessageIndexes` struct computed once at the top of `body`.
- **[P1]** `InspectorView.swift:24–37` — inside the `ForEach` loop, four roles each compute `roleMessages = viewModel.messages.filter { ... }` independently → 4× full-message scans per body. Fix: build `messagesByRole: [AgentRole: [ChannelMessage]]` once before the `ForEach`.
- **[P1]** `InspectorView.swift:1306–1327` — `summarizerMessages`, `summaryCount`, `errorCount` each filter the entire `messages` array. Used 3+ times in `body`. Fix: cache `let summarizerMsgs = ...` at top of `body`, derive counts from it.
- **[P1]** `InspectorView.swift:1605` — `private var stats: ModelStats { ModelStats(turns: turns) }` allocates and iterates `turns` multiple times per `body`. Fix: hoist to `let stats = ModelStats(turns: turns)` at the top of `body`, or compute once and store in a `@State` (re-init via `.onChange(of: turns.count)`).
- **[P1]** `AgentInspectorWindow.swift:29–39` — `roleMessages`, `recentMessages`, `recentToolUses` each re-filter. Same fix as InspectorView.

### 3.4 `Task { ... }` blocks and error swallowing

`CLAUDE.md`: *"WARNING `Task { ... }` will eat thrown errors. Be sure we handle them."*

The view layer has ~80 `Task { await ... }` blocks. Spot-audit:
- Most call viewModel methods that don't throw — safe.
- **[P1-INFO]** `InspectorView.swift:304-306` (and the other inspector turn-action callbacks that fan out via `Task { await viewModel.sendDirectMessage(...) }`, `Task { await viewModel.updateSystemPrompt(...) }`, etc.) — these methods don't throw today, so no errors are being eaten. But that's a contract that's easy to break: if `sendDirectMessage` ever becomes throwing, the `Task` swallows silently. Recommended: wrap each callsite in `Task { do { try await ... } catch { logger.error(...) } }` or change the helper methods to never throw on these paths.
- **[P1]** `MainView.swift:265–278` and `:283–308` — `provider.loadItem` / `provider.loadDataRepresentation` callbacks dispatch to `Task { @MainActor in viewModel.addAttachments(...) }`. The outer `Task` is fine; the surrounding callback's `if let error` paths only `print`, not `logger.error`. Fix: switch to `os.Logger`. Minor.

### 3.5 Other concurrency / safety notes

- **[P1]** `AgentSmithApp.swift:344–348, :354–362` — `MainActor.assumeIsolated` inside `NotificationCenter.addObserver` blocks. Correct because `.queue: .main` guarantees main-thread delivery, and `assumeIsolated` is the right pattern to bridge the callback into MainActor context. Keep as-is, but verify that any future change to `.queue` (e.g. `.queue: nil`) updates these calls.
- **[INFO]** `SharedAppState.swift:90–93` — `boolDefault(key:default:)` is a nice fix for the `bool(forKey:)` "missing key returns false" gotcha. Worth promoting to a small extension on `UserDefaults` so other call sites can use it consistently.
- **[P1]** `AgentModelSettingsSection.swift:446–452` — `defer { DispatchQueue.main.async { self.isSyncingFromExternal = false } }` is correct (you want the flag to remain true during the synchronous `onChange` notifications that the @State assignments fire, then reset on the next runloop), but it's the only `DispatchQueue.main.async` in the codebase. Add a one-line comment block above the `defer` documenting the invariant — readers will otherwise file this as "weird" and "fix" it.
- **[INFO]** `AppViewModel.swift:611, :626` — `try?` on `Data(contentsOf:)` and `Task.sleep` in autopilot debug. Acceptable.
- **[INFO]** `AppViewModel.swift:251–253` — `try? JSONDecoder().decode(...)` for message history. Silent failure means the up-arrow recall starts empty if persisted history corrupts. Low-stakes, but a `logger.error` line in the failure branch would help diagnose.
- **[P1]** `ImageCache.swift:50` — `preconditionFailure("Caches directory unavailable...")`. This is a hard crash, not a force-unwrap, but it's reachable on misconfigured systems. Realistically `cachesDirectory` is always present on macOS, so the assertion is fine — but consider `fatalError` with a more actionable message, or fall back to `URL(fileURLWithPath: NSTemporaryDirectory())` as a secondary path so the cache degrades to "RAM only" instead of crashing.

---

## 4. P2 — Architecture & decomposition

### 4.1 Files that exceed reasonable bounds

| File | LOC | Recommendation |
| --- | --- | --- |
| `ChannelLogView.swift` | **2,266** | Split: keep `ChannelLogView` + `MessageRow` + `ChannelTimestamp` here; move all banners (`TaskCreatedBanner`, `TaskCompletedBanner`, `TaskAcknowledgedBanner`, `TaskContinuingBanner`, `TaskReadyForReviewBanner`, `ChangesRequestedBanner`, `TaskUpdateBanner`, `TaskSummarizedBanner`, `MemoryBanner`, `TaskActionScheduledBanner`) into `Views/Banners/`. Move `AttachmentView`, `ImageLightbox`, `ToolNameChip`, `ToolPathText`, `FileWritePathView`, `HoverTooltip` into their own files. Estimate: shrinks `ChannelLogView.swift` to ~600 lines. |
| `InspectorView.swift` | **1,713** | Split: extract `AgentCard`, `SummarizerCard`, `LLMTurnDisclosureRow`, `FullContextSheet`, `ModelStatsPopover`, `AgentConfigSheet`, `EvaluationRecordRow`, `ContextMessageRow` each into their own file. The eight-way switch in `MessageRow.body` (line 614+) is also a candidate for extraction if you adopt the `messageKind`-keyed switch (see §4.2). |
| `SpendingDashboardView.swift` | **1,064** | Split: this file is mostly the section antipattern from §2.1. After extracting each `: some View` property to a real struct, the dashboard frame view itself reads down to ~100 lines. Move `TaskCostDetailSheet` to its own file. |
| `MemoryEditorView.swift` | **701** | Split: extract `MemoryRow`, `TaskSummaryRow`, the new-memory composer, and the stats footer to their own structs. |

### 4.2 The `messageKind`-keyed switch ladder in `ChannelLogView.body`

`ChannelLogView.swift:227–356` — 16 `else if case .string(let kind) = message.metadata?["messageKind"], kind == "..."` branches. Each one re-decodes the metadata entry. Even if the SwiftUI overhead is negligible, it's a maintenance hazard — adding a new banner kind requires editing this ladder *and* a banner-pair lookup.

Recommended pattern:

```swift
private enum BannerKind: String {
    case taskCreated, taskAcknowledged, taskContinuing, taskComplete,
         changesRequested, taskActionScheduled, taskUpdate, taskCompleted,
         taskSummarized, memorySaved, memorySearched, agentOnline,
         restartChrome, timerActivity, taskUpdateGuidance
}

ForEach(messages) { message in
    let kind = message.stringMetadata("messageKind").flatMap(BannerKind.init(rawValue:))
    bannerView(for: message, kind: kind, suppressed: scheduledTaskBannerIDs)
        .id(message.id)
}

@ViewBuilder
private func bannerView(for message: ChannelMessage, kind: BannerKind?, suppressed: Set<String>) -> some View {
    switch kind {
    case .taskCreated: TaskCreatedBanner(...)
    case .taskAcknowledged: TaskAcknowledgedBanner(...)
    // ...
    case .none: MessageRow(message: message, ...)
    }
}
```

This converts the ladder from O(N) per row to O(1) and gives the reader an enum to grep for when adding a new banner.

### 4.3 `@Bindable` over `Binding(get:set:)` glue

There are many places where bindings are assembled with the `Binding(get:set:)` pattern when the property is on an `@Observable` type:

- `MainView.swift:29–32` — `Binding(get: { viewModel.autoRunNextTask }, set: { viewModel.autoRunNextTask = $0 })` is exactly what `$viewModel.autoRunNextTask` provides on a `@Bindable` view-model. `MainView` already has `@Bindable var viewModel`, so `Toggle("...", isOn: $viewModel.autoRunNextTask)` is the idiomatic form.
- `MainView.swift:36–39` — same.
- `MainView.swift:98–101` — same.
- `SettingsView.swift:343–348` and the audio-section bindings throughout — `Binding(get: { speechController.userVoiceIdentifier }, set: { speechController.setUserVoice($0) })`. If `speechController.userVoiceIdentifier` is mutable on an `@Observable`, switch to `$speechController.userVoiceIdentifier`. If the setter has side effects (`setUserVoice` does sound/voice setup), the explicit binding is correct — leave it.

(I'd flag this as P3 except that the same boilerplate is repeated dozens of times in `SettingsView`'s audio section. Worth a single grep-and-migrate pass.)

### 4.4 `ChannelLogView.equatable()` is gold — keep it

`MainView.swift:84` — `ChannelLogView(...).equatable()` — combined with the `nonisolated static func ==` at `ChannelLogView.swift:135` (compares last message id + counts + display prefs), this prevents body re-evaluation on unrelated parent changes (input text, attachments, hover state). Keep this pattern. `MarkdownText` does the same (line 13 / line 18). When extracting new view structs from the antipattern fixes in §2.1, consider conformance to `Equatable` for the row-shaped ones too.

### 4.5 Inspector double-scroll

`InspectorView.swift:22` (outer ScrollView) wraps `:315` (`ScrollView(.vertical) { ... }.frame(maxHeight: 300)`) and `:111` of `AgentInspectorWindow` (same pattern). The inner scroll-view-with-bounded-frame is intentional and works, but on macOS it produces double-scroll-bar UX where users sometimes scroll the outer when they meant the inner. Lower priority: consider a custom container that lets the inner section grow up to 300pt and then becomes part of the outer scroll.

---

## 5. P3 — Modern API & accessibility hygiene

### 5.1 Zero accessibility surface

- **[P3]** No `.accessibilityLabel`, `.accessibilityHint`, or `.accessibilityIdentifier` calls anywhere in `AgentSmith/`. VoiceOver auto-derives labels from string content, which works for `Text("Start")` but fails for icon-only buttons (e.g. `MainView.swift:194` — `Button("Mute All", systemImage: "speaker.wave.2.fill")` is fine because `Button(_, systemImage:)` uses the title as the label, but custom-labeled buttons like `InspectorView.swift:251` — `Button(action: ..., label: { Image(systemName: "speaker.wave.1") })` produce no readable label).
- **[P3]** No `.accessibilityIdentifier` means UI tests have no stable hooks. Even if you don't ship UI tests today, adding identifiers to load-bearing controls (Start, Stop All, message input, send) is a 10-minute change that pays back the first time you write a UI test.

Recommended baseline pass:
1. Every icon-only `Button(action:, label: { Image(systemName: ...) })` gets `.help("Description")` (already done in many places — keep going) and `.accessibilityLabel("Description")`.
2. Every primary action gets a stable `.accessibilityIdentifier("startButton")` etc.

### 5.2 Modern API opportunities

- **[P3]** `MarkdownText.swift:325` — `.foregroundColor(.cyan)`. Migrate to `.foregroundStyle`.
- **[P3]** `DiffView.swift:75` — same.
- **[P3]** `SpendingDashboardView.swift:705–707` — `extension UUID: @retroactive Identifiable { public var id: UUID { self } }`. Retroactive conformance to a stdlib type is a forward-compat risk (Swift could add `Identifiable` to `UUID` later, conflicting with this). Workaround: wrap UUID in a private struct whose only purpose is `Identifiable` conformance for the `.sheet(item:)` callsite. Low priority — `@retroactive` annotation makes this explicit and the risk is small.
- **[INFO]** `MainView.swift:144–148` — `.onKeyPress(.escape)` and `.onKeyPress(characters: ...)` are modern (iOS 17 / macOS 14+) and correctly used.
- **[INFO]** `ChannelLogView.swift:362–382` — `.onScrollGeometryChange(for:of:action:)` is the right modern API for the auto-scroll-to-bottom behavior. Keep.

### 5.3 Polish

- **[P3]** `MainView.swift:273–276` and the matching image-drop branch — `Task { @MainActor in viewModel.addAttachments(from: [url]) }`. This wrapping is needed because the `loadItem` callback runs off main, but the `addAttachments` call is synchronous; consider extracting a tiny `@MainActor private func handleDroppedURL(_ url: URL)` helper to make the intent obvious.
- **[P3]** `ChannelLogView.swift:202` — `ScrollViewReader` wraps the entire view. Modern alternative: `.scrollPosition(id: $scrollPosition)` on the ScrollView pairs with `ForEach` IDs and is more declarative. Optional — current implementation works.

---

## 6. Cross-cutting recommendations

### 6.1 `AppFonts` / `AppColors` migration list

Add the following to `AppStyling.swift`:

```swift
extension AppFonts {
    static let bannerIcon = Font.system(size: 13)
    static let bannerIconSmall = Font.system(size: 11)
    static let metaIcon = Font.system(size: 9)
    static let microMonoBadge = Font.system(size: 9, weight: .medium, design: .monospaced)
    static let lockIcon = Font.system(size: 9)
}

extension AppColors {
    static let warningRowBackground = Color.orange.opacity(0.10)
    static let lightboxBackdrop = Color.black.opacity(0.85)
    static let dropTargetTint = Color.blue.opacity(0.08)
    static let diffAddedBackground = Color.green.opacity(0.12)
    static let diffRemovedBackground = Color.red.opacity(0.12)
    static let codeBlockBackground = Color.secondary.opacity(0.10)
    static let codeBlockBorder = Color.secondary.opacity(0.20)
    static let tableHeaderBackground = Color.secondary.opacity(0.12)
    static let tableBorder = Color.secondary.opacity(0.25)
    static let subtleRowBackground = Color.secondary.opacity(0.06)
    static let toolCallInspectorTint = Color.orange.opacity(0.05)
    static let inactiveDot = Color.secondary.opacity(0.40)

    static func contextRowBackground(for role: LLMMessage.Role) -> Color {
        switch role {
        case .system: return Color.secondary.opacity(0.05)
        case .user: return Color.blue.opacity(0.05)
        case .assistant: return Color.green.opacity(0.05)
        case .tool: return Color.orange.opacity(0.05)
        }
    }
}
```

Then sweep the 30+ hardcoded `Color.<name>.opacity(...)` callsites listed in §2.4 with substitutions. The taskCompletedAccent and changesRequestedAccent inline RGB literals belong in the asset catalog (preferable per global SwiftUI rule).

### 6.2 Accessibility baseline pass

For every `Button(action:, label: { Image(systemName: ...) })` in:
- `InspectorView.swift:251–267` (speech mute, gear)
- `ChannelLogView.swift:692–704` (per-row copy)
- `UserInputView.swift:30–50` (paperclip, expand editor) — already mostly good
- `MainView.swift` toolbar buttons — already use `Button(_, systemImage:)` form which auto-labels
- `TaskListView.swift:210–224` (pause/stop inline)

Add `.accessibilityLabel("...")` matching the existing `.help("...")` text, and `.accessibilityIdentifier("...")` for primary actions (Start, Stop All, Send).

### 6.3 The "view properties" antipattern as a lint target

This codebase has 44 instances of the `: some View` property antipattern. If this rule is going to stick, consider adding a SwiftLint rule (or a one-shot `grep` in CI) to catch new instances. Pattern: `^\s*(@ViewBuilder\s+)?private var [a-zA-Z_]+: some View`. The `swiftlint` skill is configured for this project per the available skills list.

### 6.4 Force-unwrap / `try?` audit notes

- 13 `try?` callsites total. Most are intentional (history decoding, regex compilation, autopilot debug, JSON decode of optional metadata). None flagged as risky.
- The earlier "248 force-unwraps" count (from initial exploration) is misleading — the regex captured optional-chain `?` patterns. A targeted scan of actual `!` unwraps in the app target is small (`AgentSmithApp.swift:264` is preceded by an `isEmpty` guard; `ImageCache.swift:50` is `preconditionFailure` not unwrap). No force-unwrap fixes required.

---

## 7. Per-file appendix

### `AgentSmithApp.swift` (419 LOC) — **healthy**
- Multi-window scene wiring and `WindowKeyObserver` are well thought through. The `pendingNewSessionIDs` queue + `@SceneStorage("sessionID")` handoff is the right pattern.
- **[INFO]** :235 `.sheet` placement is correct (after `.task`, `.background`, `.onChange`).
- **[INFO]** :345, :355 — `MainActor.assumeIsolated` is correct here.
- **[INFO]** :369 — `isolated deinit` (Swift 6) is the modern way to clear NotificationCenter observers from a MainActor type.
- No P0/P1 findings.

### `ViewModels/AppViewModel.swift` (1198 LOC) — **healthy**
- The `SerialPersistenceWriter` + `isApplyingPersistedState` flag combo (lines 130, 138–142, 176) is a solid response to the persistence races described in the comments. Keep the comment block on `isApplyingPersistedState`.
- **[INFO]** `didSet` on `autoRunNextTask`/`autoRunInterruptedTasks` is fine — these are stored properties on an `@MainActor @Observable class`, *not* `@State`. The project rule about `didSet` is specifically for `@State`/`@Binding`.
- **[INFO]** :437–447, :450–459, etc. — runtime callback registrations correctly use `[weak self]` capture and dispatch back to `@MainActor`.
- **[INFO]** :784–790 `Task.detached` for attachment persistence has a `do/catch` with `logger.error` — error handling intact.
- No P0/P1 findings within the view-model itself; bindings consumed by views have findings (see `MainView.swift`).

### `ViewModels/SharedAppState.swift` (554 LOC) — **healthy**
- `loadTask`, `semanticEngineTask`, `memoryStoreTask` patterns prevent duplicate setup work across concurrent windows. Solid.
- **[INFO]** :90–93 `boolDefault` helper — promote to a `UserDefaults` extension for reuse.

### `ViewModels/SessionManager.swift` (186 LOC) — **healthy**
- Clean. No findings.

### `ViewModels/AgentInspectorStore.swift` (107 LOC) — **healthy**
- The reassignment-through-subscript pattern at :39–44 (with the docstring explaining why) is exactly the right level of comment for a non-obvious workaround.
- No findings.

### `Styling/AppStyling.swift` (120 LOC) — **mostly healthy**
- See §2.4 / §6.1: two inline RGB literals belong in the asset catalog; `AppColors` and `AppFonts` should grow several semantic siblings.
- **[INFO]** `PricingFormatter` and `TaskStatusBadge` enums in this file are fine — they're tightly related.

### `Styling/ImageCache.swift` (245 LOC) — **healthy**
- Singleton is appropriate (it's an infrastructure cache, not view-driven state). The disk eviction on init via `Task.detached(priority: .utility)` is correct.
- **[P1-INFO]** :50 `preconditionFailure` on missing cachesDirectory — see §3.5.

### `Views/MainView.swift` (420 LOC) — **mostly healthy**
- See §2.4 (`.blue.opacity(0.08)` overlay) and §4.3 (`Binding(get:set:)` glue that should be `$viewModel.autoRunNextTask`).
- Two near-identical `.onChange` bodies (lines 214–223 and 224–233) waiting on `hasLoadedPersistedState` — could be one block listening for the AND of both.
- **[P0]** :119 — hardcoded blue. Fix: `AppColors.dropTargetTint`.
- **[P0]** :354, :377 — `.red.gradient`, `.orange.opacity(0.08)` — semantic but inline. Acceptable to leave as-is or move.

### `Views/ChannelLogView.swift` (2266 LOC) — **needs P0 cleanup + decomposition**
- See §2.1 (7 antipattern view-properties), §2.2 (11 onTapGesture), §2.4 (warning-row + lightbox color), §2.5 (banner-icon font literals), §4.1 (split file), §4.2 (switch ladder).
- Strong points: `Equatable` conformance, request-id lookup caching, `ChannelTimestamp` environment-keyed reusable, `.onScrollGeometryChange` integration.

### `Views/InspectorView.swift` (1713 LOC) — **needs P0/P1 cleanup + decomposition**
- See §2.1 (3 antipattern view-properties), §2.2 (1 onTapGesture), §2.3 (1 LazyVStack), §2.4 (~10 hardcoded colors), §3.1 (2 onChange @State mutations), §3.2 (`@State` from init in `AgentConfigSheet`), §3.3 (4 recompute hot spots), §4.1 (split file).
- The push-callback architecture into `AgentInspectorStore` is excellent — it's the reason the inspector doesn't tank `MainView` re-renders.

### `Views/AgentInspectorWindow.swift` (169 LOC) — **mostly healthy**
- See §3.1 (2 `.onChange` violations), §3.3 (`roleMessages` recomputed). Otherwise clean.

### `Views/TaskListView.swift` (557 LOC) — **healthy**
- Rare positive: this file follows the project rules well — proper `Button` usage everywhere, proper local caching of `activeTasks`/`archivedTasks`/`deletedTasks` at body top, good `ContextMenu` wiring.
- **[P0]** :132 hardcoded `Color.secondary.opacity(0.06)` (section header background). Trivial fix.
- **[P0]** :382 `Color.secondary.opacity(0.35)` (deleted row icon tint). Trivial fix.

### `Views/SettingsView.swift` (487 LOC) — **needs P0 cleanup**
- See §2.1 (3 view-properties), §2.4 (`Color.blue.opacity(0.15)` flag chip), §4.3 (audio section's `Binding(get:set:)` boilerplate). The structure is otherwise fine.

### `Views/ProviderManagementView.swift` (497 LOC) — **needs P0 cleanup**
- See §2.1 (3 view-properties). Otherwise clean.

### `Views/AgentModelSettingsSection.swift` (568 LOC) — **needs P0/P1 cleanup**
- See §2.1 (4 view-properties), §3.1 (3 self-mutating `.onChange`s with the recursive thinking-budget clamp), §3.5 (the unusual `defer { DispatchQueue.main.async { ... } }` is correct but under-commented).
- The `WrappingHStack: Layout` (lines 511–567) is well-implemented and exactly the use case for the modern `Layout` protocol. Keep.

### `Views/ModelConfigurationEditorView.swift` (372 LOC) — **needs P0 cleanup**
- See §2.1 (8 view-properties — the most concentrated antipattern density per LOC). Otherwise straightforward.

### `Views/BehaviorFlagsEditorSheet.swift` (214 LOC) — *not exhaustively reviewed*
- No P0 issues found in spot-checks. (Not flagged in any cross-cutting grep.)

### `Views/ConfigValidationView.swift` (85 LOC) — *not exhaustively reviewed*
- Small, clean.

### `Views/MemoryEditorView.swift` (701 LOC) — **needs P0/P1 cleanup**
- See §2.1 (5 view-properties), §2.3 (2 `List`), §3.1 (`.onChange(of: searchText)` synchronous @State mutations).
- Strong points: search debouncing pattern (line 76–78 with cancellable Task), corpus-stats snapshot before search.

### `Views/SpendingDashboardView.swift` (1064 LOC) — **needs P0 cleanup + decomposition**
- See §2.1 (11 view-properties — the worst offender), §2.2 (1 onTapGesture), §2.3 (1 LazyVGrid), §4.1 (split file), §5.2 (`@retroactive Identifiable`).
- Strong points: `recomputeDerivedState()` caching pattern (lines 176–188) is exactly right; chart hover tooltip implementation is solid; provider snapshot at load time avoids actor crossings.

### `Views/MarkdownText.swift` (421 LOC) — **mostly healthy**
- See §2.4 (4 hardcoded code-block / table colors), §2.6 (`.foregroundColor(.cyan)`).
- Strong points: `Equatable` conformance prevents re-parsing; static-let regex compilation; safe `try?` on regex init.

### `Views/UserInputView.swift` (255 LOC) — **healthy**
- Clean — proper `Button` usage, `AppFonts` and `AppColors` consumed correctly.
- The keyboard handling at :72–103 (Enter, Shift+Enter, Cmd+V interception) is sophisticated and correctly uses modern `.onKeyPress`.
- No findings.

### `Views/DiffView.swift` (148 LOC) — **needs P0 cleanup**
- See §2.2 (1 onTapGesture), §2.4 (2 diff colors), §2.6 (`.foregroundColor`).

### `Views/TaskDetailWindow.swift` (352 LOC) — **mostly healthy**
- **[P0]** :148 — `.purple.opacity(0.06)` for summary section. Fix: `AppColors.summarySectionBackground`.
- Otherwise clean.

### `Views/TimersWindow.swift` (~250 LOC) — *not exhaustively reviewed*
- See §2.3 (2 `List` for variable-height content).

### Package surface (`OrchestrationRuntime`, `TaskStore`, `MessageChannel`, `AgentInspectorStore` consumers)

The view-layer consumption pattern is correct:
- All callbacks (`setOnAbort`, `setOnProcessingStateChange`, `setOnAgentStarted`, `setOnTurnRecorded`, `setOnContextChanged`, `setOnEvaluationRecorded`, `setOnTimerEventForChannel`) are registered with `[weak self]` capture and dispatch onto `@MainActor` via inner `Task { @MainActor in ... }` blocks. No `MainActor`-from-actor reach-ins.
- `channelStreamTask` (`AppViewModel.swift:117, :468–476`) drains the channel's `AsyncStream` on MainActor and explicitly cancels in `stopAll`. Good lifecycle management.
- `flushPersistence` (line 960) provides the synchronous flush guarantee `stopAll` needs.
- `setScheduledWakesInterruptResolver` (line 546) takes a closure that does `await MainActor.run { ... }` — correct because it's read from the actor and needs an isolated read of the @Observable property.

No P0/P1 findings on the consumer side.

---

## Final note

This codebase is in good shape — the top-five themes in §1 are mostly *consistency* and *rule-conformance* work, not architectural. The patterns the project has chosen (per-session VMs, `@Observable`, runtime callbacks for inspector data, `SerialPersistenceWriter`) are sound and worth defending. The `: some View` antipattern is the largest single thing to address; it's also the one that most directly funds future decomposition work, since each fix moves the code one step toward the smaller, file-per-view structure that newer views in this project (e.g. `TaskListView`, `UserInputView`) already use.

Recommended order of attack (if you decide to fix any of this):

1. **One-shot mechanical pass**: §2.4 + §2.5 + §2.6 — extend `AppColors` and `AppFonts`, sweep the literals. Low risk, high consistency win.
2. **One-shot accessibility baseline**: §6.2 — 30 minutes of `.accessibilityLabel` / `.accessibilityIdentifier` adds.
3. **Per-file decomposition**: tackle `SpendingDashboardView` first (most antipattern density, no concurrency entanglement), then `ChannelLogView`, then `InspectorView`. Each is a self-contained PR.
4. **`.onChange` `DispatchQueue.main.async` wrap**: §3.1 — handful of files, mechanical.
5. **`onTapGesture` → `Button` conversion**: §2.2 — low-risk if you keep `.buttonStyle(.plain)`.

The accessibility pass (#2) should probably go first if anyone outside the dev team is going to use this app — VoiceOver opens it and announces nothing for the icon-only buttons.
