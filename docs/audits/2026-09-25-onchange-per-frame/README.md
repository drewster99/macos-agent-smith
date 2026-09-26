# SwiftUI "onChange(of:) action tried to update multiple times per frame" — investigation (2026-09-25)

Status: **open**. The harness mechanism below is real but is NOT what the app hits: the frame-batching
fix built on it made the app worse (live A/B, 2026-09-25). The warning sites are now identified
exactly (below). Nothing here is committed to the app.

## What the harnesses measured

All three are standalone SwiftUI apps (`swiftc -O -parse-as-library harnessN.swift`), one watcher
per view unless stated; warnings counted with `/usr/bin/log stream` on the message text. SwiftUI
logs each watcher SITE at most once per process, so a count says which sites are affected, not how
often.

`harness.swift` — one `.onChange` watcher, 200 bursts:

| Variant | What changes | Warned |
|---|---|---|
| A | watched dict key, 4 separate main-actor hops per burst | yes |
| B | watched dict key, 4 changes inside ONE hop | no |
| C | only ANOTHER key of the same dict, 4 hops | no |
| D | array, 4 hops | yes |
| E | property on its own `@Observable` object, 4 hops | yes |
| F | watched key, one hop per 50 ms | no |

`harness2.swift` — realistic bursts (3–6 hops, 0–6 ms apart, every 30–90 ms, 600 bursts), 3 runs each:

| Strategy for applying writes | Warned |
|---|---|
| direct (each hop writes) | 3/3 |
| next main-queue turn (what `RecomputeCoalescer` does) | 3/3 |
| 16 ms timer batch | 0/3 |
| display-link batch | 0/3 |
| 25 ms timer / display link, main thread blocked 60 ms every 100 ms | 0/1 each |

`harness3.swift` — 2 or 4 watchers on ONE view, all values changed in one hop every 60 ms, with and
without deferred / synchronous `@State` writes in the actions: **no warnings** in any variant.

## Conclusions

1. A watched value changing in more than one main-queue turn within one frame produces the warning.
   Several changes in one turn do not, and several watchers firing together do not.
2. This refutes the explanation in `4ec1756` (value expressions reading whole `@Observable`
   dictionaries): variant C changes another key of the watched dictionary and never warns.
3. Batching writes on a timer longer than a frame removes the mechanism in isolation.

## The fix that was tried, and what it did

`FrameBatchedMainActorQueue` (a thread-safe, order-preserving queue applied in one main-queue turn
per 25 ms) with every runtime UI feed routed through it — processing / tool-execution / agent-started
/ LLM-call / context / evaluation callbacks, the transcript providers, the `tasks` mirror, the
live-activity mirror — plus `RecomputeCoalescer` and `InspectorView.rebucket` scheduling through it.
Files: `FrameBatchedMainActorQueue.swift` (+ tests, all passing) and `batcher-app-changes.patch`.

Measured in the app with the screen locked: launch still logged the same three
`Array<ChannelMessage>` warnings as without it, at the moment two error messages were posted,
with batches ≥ 65 ms apart. Probe logging showed the warning is raised during the update pass
right after a batch, before any `onChange` action runs, and that `NowLiveSection`'s messages watcher
did not run in that pass — i.e. a flagged action appears to be SKIPPED, not merely logged, which
makes this more than log noise (its 10 s sweep recovers).

## Live A/B (screen unlocked, one small task per run)

| Build | Warning sites |
|---|---|
| main (baseline) | 11 |
| + `batcher-app-changes.patch` | 17 |

Batching does not help; it made it worse. Reverted.

## Exact sites (per-site tagging)

Each watched value was temporarily wrapped in a per-site generic type (`OnChangeSite<Tag, T>`), so
the log line names the site. One run, 19 warnings, 12 distinct sites — ALL on two views:

- `RoleAgentCard` / `RoleAgentCardWatchers` / `AgentCardActivityTimers` (`InspectorView.swift`):
  `isProcessing`, `roleMessages`, `callLogsByRole[role]`, `liveContexts[role]`,
  `evaluationLifetimeCount`, `processingRoles.contains(role)`, `securityEvaluations`.
- `NowLiveSection`: `taskSignature`, `messages`, `processingInstances`, `toolExecutingByInstance`,
  `liveActivitySnapshot`.

Never: `SummarizerAgentCard` (same pattern, idle in these runs), `InspectorView`'s own `messages`
watcher, and every other `.onChange` in the app.

## What the probe timeline shows

With body-evaluation and source-write probes, a SINGLE change warns: at 23:37:48.560 one
processing-state change (the previous one 16 s earlier) warned on `processingRoles.contains(role)`
and `processingInstances` at once. So these warnings are not "two changes within one frame".

The flagged action is skipped: after that warning the card's cache was not rebuilt until the 2 s
reconciliation heartbeat (`write cached` at 23:37:50.481). So the warning has a visible cost — card
state lags up to 2 s (the Live section up to its 10 s sweep) — and the heartbeats are what hide it.

## Harness hypotheses that did NOT reproduce it (all 0 warnings)

`harness3` several watchers on one view in one turn (with/without `@State` writes) · `harness4` a
value computed from two sources; a slice passed down from a parent's `@State` · `harness5` forced
`layoutSubtreeIfNeeded` / `displayIfNeeded` between two writes in one turn · `harness6` watchers on
a `Group` (two children, toggling child, `VStack` child) · `harness7` the window offscreen.

## Recommended direction (not started — needs a decision)

Take `.onChange` out of these two views: have the view model (or `AgentInspectorStore`) publish
the derived per-role card snapshot and the live rows as stored `Equatable` properties, rebuilt
where the inputs change, and let the views read them directly. This is the "per-role Equatable
snapshot" `4ec1756` proposed, and it removes the heartbeat-hidden lag along with the warnings.
It changes where the inspector's derived state lives, so it is an architecture decision.
