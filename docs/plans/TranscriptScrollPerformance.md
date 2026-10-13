# Transcript scroll performance — permanent fix

Status: PLAN (2026-10-13). Needs the user's architecture decision (§4) before Phase 2.

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
