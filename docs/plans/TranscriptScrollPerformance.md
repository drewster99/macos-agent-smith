# Transcript scroll performance — permanent fix

Status: ✅ all phases (2026-10-14). Phase 1 superseded; Release numbers still to take — see §8.

## 1. Problem

The main transcript (`ChannelLogView`) scrolls very slowly. This has been "fixed" many times —
`git log` shows ~40 transcript performance commits since 2026-04 (row `Equatable`, `@State` caches,
grouping-index windowing, per-line style caching, body splits) — and it keeps coming back. None of
those changed the structure, and none added a measurement, so nothing stops the next regression.

## 2. Root causes (from the code; Phase 0 confirms with numbers)

### 2a. Structural: every rendered row is a live view, all the time

`ScrollView { VStack { ForEach(rows) } }` — non-lazy, by design (project rule against SwiftUI lazy
stacks). To bound it, the view renders a window: 400 rows by default, +800 per "Load earlier",
up to 3,000 while scrolled up (`ChannelLogView.initialWindowSize` / `windowGrowStep` /
`maxFrozenWindowRows`). Every one of those rows is laid out and kept live, not just the ~30 on screen.

Per-row cost multiplies it:

- `MarkdownText` renders **one `Text` per line**, inside a `VStack`, with `.textSelection(.enabled)`.
  A 40-line message is 40 selectable text views. 400 rows → thousands of selectable texts.
- Every `MessageRow` has `.onHover` (a tracking area), so moving over the list during a scroll
  writes `@State` on each row passed.
- Any layout change (append, expand/collapse, window resize, filter change) re-measures the whole
  window, because a `VStack` has no height cache.

The window size is the only lever this design has, and it trades scrollback against speed.

### 2b. Regression, 2026-10-09 (`dc593769`, issue #34): `.scrollTargetLayout()`

Added so "Load earlier" could anchor on `ScrollPosition.viewID`. Side effect: the `ScrollPosition`
binding now updates every time a row crosses the top of the viewport while scrolling. That is an
`@State` write in `ChannelLogView`, so its body re-runs mid-scroll, rebuilding
`ChannelLogMessageList` (not `Equatable`; takes fresh closures) → 400–3,000 `ChannelMessageBanner`
bodies → 400–3,000 `MessageRow ==` checks (synthesized `ChannelMessage ==`, metadata dictionaries
included). The comment at `ChannelLogView.swift:487` still claims "the position is not tracked while
the user scrolls, so scrolling never re-renders this view" — no longer true. This is the most likely
cause of "now".

### 2c. Possible amplifier: Debug build

The app is being run as a Debug build (`DerivedData/.../Debug/AgentSmith.app`). Unoptimized SwiftUI
view code can be several times slower. Phase 0 measures Debug and Release separately so this is a
number, not a guess.

## 3. Phase 0 — Measure, and build the guard (before changing anything)

The reason this keeps regressing is that there's no number. Fix that first.

1. **Fixture.** A copy of a real large session (the current one: 148,317 messages, 551 MB
   `channel_log.jsonl`), loaded read-only into a scratch session. Never the live session.
2. **Scroll benchmark (DEBUG menu command, manually triggered per project convention).**
   Programmatically scrolls the main transcript top→bottom→top at a fixed speed over a fixed
   duration, reading frame times from the window's display link. It logs:
   hitch time ratio (ms of hitch per s of scrolling), p50/p95/max frame time, dropped frames,
   rows live. The output is written to a file so runs can be compared.
3. **Instruments.** One `SwiftUI` + `Animation Hitches` + `Time Profiler` trace of the same scroll
   (`xcrun xctrace record --attach <pid>`), Debug and Release. Record the top body-update and
   layout costs.
4. **Baseline table** saved in this file: Debug/Release × window 400 / 3,000 × idle / streaming.

Exit: the numbers say which of 2a/2b/2c dominates.

## 4. Decision needed — the structural fix

| | Option | Live views | Keeps row SwiftUI code | Risk |
|---|---|---|---|---|
| **A (recommended)** | `NSTableView` (view-based) in an `NSViewRepresentable`; each cell hosts the existing SwiftUI row in a reused `NSHostingView`; row heights cached by (message id, width, expanded state) | ~visible rows + a few | Yes | Medium: height invalidation on expand/resize, hosting-view reuse |
| B | `LazyVStack` | visible + buffer | Yes | Contradicts the project rule; known macOS mis-sizing / scroll jumps with variable-height rows |
| C | Keep the `VStack`; only cut per-row cost (2d below) | 400–3,000 | Yes | Low, but leaves 2a in place; the next feature regresses it again |

Why A:

- Cost becomes proportional to what's on screen, not to the window. The 400/800/3,000 window,
  the frozen-anchor logic, and "Load earlier" can go: the table holds all 5,000 resident rows
  (`AppViewModel.residentMessageCap`). Restore History stays.
- `NSScrollView` already keeps position when rows are appended below, and supports
  "stick to bottom" — the two behaviors that `ChannelLogScrollTracking`, `frozenAnchorID` and
  `userInteracting` rebuild by hand today, and that have their own bug history (`c50630a5`, `e40b67d0`).
- Row views, banners, filtering, grouping (`ChannelGroupingIndex`) and the three
  `MainViewDetailColumn` call sites are unchanged; only the container changes.

This is an architecture change: it needs your OK. The project's "avoid SwiftUI lazy stacks" rule is
untouched by A (it's AppKit), but it should be recorded in CLAUDE.md that the transcript container is
an `NSTableView` and why.

## 5. Phases

Each phase: do the work → recheck → build (no new warnings) → run package tests → run the benchmark
→ commit → push.

### Phase 1 — Undo the regression (2b). Small, independent of the decision.

- Remove `.scrollTargetLayout()` and the `scrollPosition.viewID` read in `loadEarlier()`.
- Anchor "Load earlier" to the first rendered row id (the pre-`dc593769` behavior), or if A is
  approved, skip this: A deletes "Load earlier".
- Fix the now-false comment at `ChannelLogView.swift:487`.
- Benchmark vs baseline.

### Phase 2 — Structural container (Option A, if approved)

1. `TranscriptTableView: NSViewRepresentable` → `NSScrollView` + single-column view-based
   `NSTableView`, no header, no selection highlight, `usesAutomaticRowHeights = false`.
2. Data source over the already-filtered, already-grouped row list (suppressed follow-ups
   removed before they reach the table — one row per visible item, not per message).
3. Cell: `NSTableCellView` holding an `NSHostingView<ChannelMessageBanner>`; reused by identifier,
   `rootView` swapped on reuse. Environment (`timestampPreferences`, task-action handler) injected
   once on the hosting root.
4. Heights: measured via `fittingSize` at the current width, cached by (id, width bucket,
   expanded). Invalidated by `noteHeightOfRows(withIndexesChanged:)` when a row expands/collapses or
   its follow-up (tool output / verdict) arrives; whole cache dropped on width change (debounced
   live resize).
5. Appends: `insertRows(at:)` (no reload). Front-trim at the resident cap: `removeRows`.
   Keep scroll position when not at the bottom; scroll to end when at the bottom.
6. Expand/collapse state per row moves from `MessageRow`'s `@State` (lost on cell reuse) to a
   per-pane `Set<ChannelMessage.ID>` owned by the coordinator.
7. Delete: windowing (`maxVisibleCount`, `cachedWindowStart`, `windowStartIndex`, `frozenAnchorID`,
   `maxFrozenWindowRows`), `ChannelLogScrollTracking`, `ChannelLogLoadEarlierButton`.
   Keep: scroll-to-bottom button (driven by the clip view's bounds notifications), Restore History.

### Phase 3 — Per-row cost (2a multipliers; applies under A or C)

- `MarkdownText`: build one `AttributedString` per paragraph run instead of one `Text` per line;
  tables and code blocks stay separate blocks. `textSelection` once per message, not per line —
  which also lets a selection span lines.
- Replace per-row `.onHover` with one hover tracker for the table (row-under-mouse index) that
  drives the copy overlay.
- Any parse/regex still in a row `body` (e.g. `remainderWithoutPath`'s closure form) moves to the
  row's cached derived data.

### Phase 4 — Lock it in

- Benchmark thresholds written here and in CLAUDE.md ("Transcript performance budget"): target
  hitch ratio < 5 ms/s (Apple's "good" band) and p95 frame ≤ one refresh interval, on the fixture,
  in Release; plus a Debug ceiling.
- CLAUDE.md: transcript container is an `NSTableView`; never put a row-count-proportional view tree
  or a per-scroll-frame `@State` write back in the transcript; run the benchmark before committing
  transcript changes.
- Investigate an XCTest scroll performance test with `XCTOSSignpostMetric` on macOS (availability to
  verify) so the guard runs without a person.

## 6. Validation (every phase)

Numbers: benchmark vs baseline table — must improve or hold; never regress.

Behavior checklist, all three `ChannelLogView` call sites (main pane, task-filtered pane,
cross-session pane):

- Tail-follow while streaming; scrolling up stops it; new messages append below without moving
  what you're reading; scroll-to-bottom button appears/works; returning to bottom resumes following.
- Restore History; (Phase 1 only) Load earlier keeps the reading position.
- Tool rows: verdict icon + popover, inline verdict text per filter, output fold, expand/collapse,
  file-path click (Quick Look / Finder), inline diffs for `file_edit` / `file_write`.
- Banners: every `ChannelBannerKind`, PDF export, MCP banner → Settings, Resume/Undelete inline control.
- Markdown: headings, lists, tables, code blocks, links, linkified paths; text selection and copy;
  hover copy button.
- Image attachment tap → viewer.
- Transcript filter changes; timestamp preference toggles update existing rows.
- Window resize reflows heights; light/dark; VoiceOver reads rows in order.
- Resident cap front-trim (5,000) while scrolled up and at the bottom.

## 7. Open questions

1. Approve Option A (NSTableView container)?
2. Phase 0 needs a scroll of the live app for the Instruments trace: you scroll while I record, or
   I drive the scroll (takes mouse focus for ~30 s)?

## 8. Progress

### 2026-10-14 — Option A built (Phase 2 ✅)

- **Phase 0 — partial.** No baseline trace of the old code: driving the scroll needs the user idle,
  and posting scroll events to the app's pid (`CGEvent.postToPid`, with and without the window id)
  did not scroll it. The user's call was to proceed without the baseline. The new build WAS traced
  (Debug, 30 s, scrolling the session pane through the 5,000-message resident tail): 12 hitches,
  10 of one frame (16.7 ms), one of 33 ms, one of 67 ms (that one after the user took the mouse);
  main thread busy 478 ms of the 30 s, almost all SwiftUI text layout of rows coming on screen.
  The user's report: "feels nice". The scroll benchmark command is not built yet.
- **Phase 1 — superseded.** `.scrollTargetLayout()` and "Load earlier" went away with the
  `VStack` they existed for.
- **Phase 2 — done, as planned, with these differences:**
  - Rows report their own height (`onGeometryChange` under `fixedSize(vertical:)`) instead of
    being measured with `fittingSize`: `NSHostingView` has no height-for-width API, and a separate
    measuring instance would not share the row's state (expanded, loaded content).
  - Row state is kept by caching the HOSTING VIEW per message (LRU, 400, never evicting an
    on-screen row) instead of moving every row's `@State` into the coordinator. Moving it would
    have meant rewriting every expandable banner; the cache keeps it for any row scrolled back to
    within the last 400 shown.
  - The row rules (`ChannelGroupingIndex`, `shouldSuppress`, three `EmptyView` branches) moved
    into one pure kit type, `TranscriptRows`, with the edit planner, under 16 tests
    (`TranscriptRowsTests`). The provider's incrementally maintained `toolRequestIDs`, the view
    model's forward of it and the cross-session loader's copy were deleted: the rows are derived
    from the pane's own messages, one source.
  - `MarkdownText` now parses in `init` (it used a `.task`, so every row's first layout was
    empty — fatal for self-sizing rows).
  - Rows are rebuilt from the pane's messages (O(n), n ≤ 5,000) on each change; the table edit is
    still incremental. Make the rebuild incremental only if a trace shows it.

- **Independent review (Codex), 2026-10-14:** two anchoring defects fixed before commit — expanding
  a visible row anchored on the row BELOW it and scrolled the expansion's start away (the anchor is
  now the first row whose top is on screen), and a table mutation shortly after a wheel scroll could
  re-pin to the bottom (the whole mutation/tile/re-anchor transaction now counts as programmatic).
  Third finding NOT fixed, by decision: a row evicted from the 400-view cache loses its expanded
  state. The old design lost it sooner (any row that slid out of the 400-row window); persisting
  every banner's expansion outside its view is the fix if this ever matters.

### 2026-10-14 — Phases 3, 0 and 4 ✅

- **Phase 3 — text selection and text cost.** SwiftUI cannot select across `Text` views, and a
  merged `Text` loses list hanging indents (SwiftUI ignores `NSParagraphStyle.headIndent` —
  measured with `ImageRenderer`). So `MarkdownText` now draws each run of prose lines as ONE
  selectable `NSTextView` (`SelectableProseView`); tables and code blocks are unchanged. Both
  renderers draw from one line model (`MarkdownLine`) and one font source (`MarkdownFont`, an
  `NSFont` per face with the SwiftUI `Font` derived from it). PDF export can't draw AppKit views,
  so it sets `.markdownRendering(.staticText)` and keeps the per-line `Text`. Colors moved from an
  outer `.foregroundStyle` to a `textColor:` parameter, which reaches the AppKit view. Verified in
  the app: one drag selected and copied four bullet lines.
  - Not done, by decision: the single table-wide hover tracker. It existed for 400–3,000 live
    rows' tracking areas; with only visible rows alive it would buy nothing measurable.
- **Phase 0 — benchmark.** Debug-only View › Run Transcript Scroll Benchmark: scrolls the focused
  session's main transcript up and down at 4,000 pt/s for 10 s (reversing at each end, so it never
  idles), judges every frame against its own refresh interval (`FrameTimingStats`, 6 tests), shows
  the numbers and saves JSON to `$TMPDIR/AgentSmith-Benchmarks/`. It refuses a transcript under
  five screenfuls of scrollback.
- **Found with it:** about a tenth of the main thread during a scroll was the WINDOW's SwiftUI
  layout (the split view, the inspector) re-running every frame — the table's re-tiling
  invalidated its way up through the `NSViewRepresentable`. The scroll view now sits in a container
  view that absorbs those invalidations (`TranscriptContainerView`). Hitch time halved.
- **Independent review (Codex)** of these phases: five findings, all fixed — measuring the text view
  re-wrapped its drawn text at the last proposed width (now measured on a separate layout
  manager); trailing blank lines measured a full line tall; a selectable preview inside the
  "(show more)" button swallowed its click (that label now renders static text); the benchmark
  idled at the ends on short transcripts; one refresh budget misjudged variable-refresh frames.

**Baseline** (Debug, session pane, 452 rows / 62,000 pt, 4,000 pt/s):

| Run | Hitch ratio | Hitches | p95 | Max |
|---|---|---|---|---|
| Cold — rows never shown since launch | 91.1 ms/s | 52 | 33.3 ms | 57.0 ms |
| Warm — second run | 43.3 ms/s | 25 | 16.7 ms | 50.0 ms |
| (before the container fix) cold / warm | 203.8 / 85.2 ms/s | 110 / 51 | 33.3 ms | 99.5 ms |

What remains is SwiftUI building a row the first time it comes on screen (framework time —
AttributeGraph, SwiftUICore — not app code). 4,000 pt/s through never-seen rows is a stress test;
the user's report of everyday scrolling is "feels nice".

### Open

1. A Release-build baseline. Not taken: the project rule is builds through Xcode only, and the
   scheme's Run action is Debug.
2. If cold-row cost ever needs to come down: build hosts for rows just outside the viewport while
   idle, or raise the 400-host cache to cover a whole pane.

## 9. Phase 5 — the same fix for the app's other long lists (2026-10-14, user: "Inspector context sections always get sluggish"; "Task detail can sometimes get long")

Where (from the code and the user's data):

- **Inspector Context section** (`AgentInspectorWindowSections`) — every message of Smith's or Brown's
  live context, hundreds, in a non-lazy stack, rebuilt every turn.
- **Inspector call log** (`LLMCallLogSection` → `LLMTurnViews`) — the newest call auto-expands and
  lists every outgoing message: the same hundreds again.
- **Turn context viewer** (`LLMTurnViews` full-context window) — every message of a turn's context,
  and an `.id("\(i)-\(allExpanded)")` that rebuilds every row on "expand all".
- **Security Agent / Summarizer inspectors** — every evaluation / message, uncapped.
- **Task detail** — the largest real tasks ("Full static audit …") carry ~300 KB of validation
  records and 66–176 result attachments, all laid out at once.

Steps:

1. **One table component.** Extract the transcript table's engine — self-sizing hosted rows, the
   per-row view cache, reading-position preservation, tail-following, the benchmark — into a generic
   `HostedRowsTable` keyed by row identity and render key. The edit planner becomes a generic kit
   function that `TranscriptRows.edit` uses. The transcript becomes its first client, with no
   behavior change; the benchmark must not regress against §8.
2. **Inspector lists onto it**: the Context section, the call log's outgoing messages, the turn
   context viewer. Cap the Security Agent and Summarizer lists to their newest entries.
3. **Task detail**: profile opening and scrolling the largest real task, then fix what the profile
   shows (expected: the attachment list and the validation records).

Validation: build clean; package tests pass; transcript benchmark within §8 budget; each converted
list checked in the running app on the largest real data (Smith's context, the largest audit task).

### Phase 5 progress (2026-10-14)

1. ✅ **`HostedRowsTable`** (`Views/HostedRows/HostedRowsTable.swift`): the transcript table's engine,
   generic over a `HostedTableRow` (identity, render key, height estimate). The transcript is now a
   client of it; the edit planner is `RowListEdit.plan` in AgentSmithKit, with `TranscriptRows.edit`
   forwarding (its 16 tests unchanged). New: `onContentHeightChange`, for a table sized to its rows up
   to a cap.
2. ✅ **Inspector**: the Context section (400 pt, follows the newest message), each call's outgoing
   messages (sized to its rows, at most 320 pt), and the full-context window all use
   `ContextMessagesTable`. "Expand all" rebuilds rows through the table's identity revision instead
   of an `.id("\(i)-\(allExpanded)")` per row. Not changed: the Security Agent window draws up to 200
   full evaluation cards (store cap) — not reported slow; the Summarizer lists were already capped.
3. ✅ **Task detail**: the large tasks carry 66–176 result attachments; `TaskAttachmentList` called
   `FileManager.fileExists` in every row's `body`, a disk read per row per redraw. Existence is now
   checked once per list, off the main thread (`AttachmentFileState.resolve`, `@concurrent`), and a
   list over 12 shows the first 12 with "(more)". `DeliverablesView` had the same in-body check; it
   shares the fix. Validation records were ruled out: 18 records, their large fields rendered only
   when a record's debug view is opened.
- **Codex review**: two findings, both fixed — a cancelled file check could overwrite a newer one; a
  short outgoing list stayed at its collapsed height when a message was expanded.
- **Tests**: `ProviderOutageTests`, `ValidationEconomicsTests` and `TaskWatchTests` failed once each
  in full-suite runs under load (another Xcode project building) and passed alone twice; one full run
  hung with the test helper idle and was killed. Neither is in code this phase touched.
