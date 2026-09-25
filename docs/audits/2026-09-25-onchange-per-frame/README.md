# SwiftUI "onChange(of:) action tried to update multiple times per frame" — investigation (2026-09-25)

Status: **open**. The mechanism below is proven in isolation; a fix built on it did not change the
three warnings seen at app launch, and a live A/B measurement was blocked (screen locked, and the
ChatGPT-subscription provider returning HTTP 401 so no task could run). Nothing here is committed
to the app.

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

## Next step

Re-run the A/B with the screen unlocked and a working Smith provider: the same small task with and
without `batcher-app-changes.patch`, counting warning sites. The pre-fix baseline for a two-task run
was 25 sites (8 `Bool`, 4 `Array<ChannelMessage>`, 3 `Optional<InspectorCallLog>`, 2 each of
`Optional<Dictionary<String, Int>>`, `Optional<Array<LLMMessage>>`, `Int`, and 1 each of `Snapshot`,
`Set<AgentInstanceRef>`, `Dictionary<AgentInstanceRef, Dictionary<String, Int>>`, `Array<String>`).
The launch-time residual needs its own probe with the window actually on screen.
