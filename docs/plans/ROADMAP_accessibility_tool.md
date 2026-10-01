# Roadmap: Accessibility Tool for Agent Smith

Plan for adding macOS Accessibility (AX) tooling to Agent Smith, lifted from
the working code in `macos-accessibility-client`.

## Background reading done

**Source repo** at `/Users/andrew/Documents/ncc_source/cursor/macos-accessibility-client/MacOSAccessibilityClient/MacOSAccessibilityClient/`:

- `Core/AXElement.swift` — `nonisolated struct AXElement: @unchecked Sendable`
  wrapping `AXUIElement` with `attributeNames`, `actionNames`, `attribute(_:)`,
  `setAttribute`, `perform(_:)`, `setMessagingTimeout(_:)`, `pid`, `role/subrole/title/frame/children/parent/ancestorChain`.
  Plus `AXValueFormatter` for stringifying CFTypeRefs.
- `Core/AXObserverWrapper.swift` — `final class @unchecked Sendable`, holds an
  `AXObserver`, registers its run-loop source on the **main** run loop,
  dispatches the C callback through `MainActor.assumeIsolated`. Curated
  `standardNotifications` list.
- `Core/ElementSnapshot.swift` — `nonisolated struct ElementSnapshot` plus an
  `actor ElementSnapshotBuilder` that pulls the snapshot off the main actor
  (the synchronous AX reads are cross-process, so they shouldn't block the UI).
- `Core/AXError+ext.swift` — `AXErrorWrapper: LocalizedError` and `axCheck(...)`.
  `AXError.apiDisabled` ⇒ permission missing.
- `Core/Formatting.swift` — `Formatting.frame/dimension`, `ElementLabel.long/short`.
- `Permissions/AccessibilityPermissions.swift` — `@MainActor @Observable`
  wrapper around `AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions` and a
  `x-apple.systempreferences:` URL opener. **Swift 6 quirk:** uses literal
  `"AXTrustedCheckOptionPrompt"` because the framework constant is non-Sendable.
- `Models/RunningAppsViewModel.swift` — enumerates regular foreground apps,
  applies a 2.0s messaging timeout per app element. Useful for "list scriptable
  targets."
- `Models/MenuChainWalker.swift` — synthesizes a `[root → leaf] AXPress` walk
  to open submenus that AX won't otherwise populate. Worth lifting for
  "click menu item by path."
- `Models/AppInspectionSession.swift` — pairs an app root with one observer;
  capped event log. Direct template for streaming notifications.

**Destination repo** at `/Users/andrew/cursor/macos-agent-smith/`:

- `AgentSmithPackage/Package.swift` — local Swift package `AgentSmithKit`,
  macOS 15+, Swift 6.
- `AgentSmithPackage/Sources/AgentSmithKit/Tools/AgentTool.swift` — protocol
  `AgentTool: Sendable` with `name`, `toolDescription`, `parameters`,
  `execute(arguments:context:)`, `isAvailable(in:)`. Tools return
  `ToolExecutionResult.success/.failure`. Brown-only tools gate via
  `isAvailable { context.agentRole == .brown }`.
- `AgentSmithKit/Tools/RunAppleScriptTool.swift` — closest existing template;
  uses an actor-backed `AppleScriptRunner.shared`.
- `AgentSmithKit/Utilities/AppleScriptRunner.swift` — `actor` with
  `static let shared`, runs scripts on a private dispatch queue at
  user-initiated QoS, returns a `Codable AppleScriptResult`. Mirrors the
  shape we want for `AccessibilityService.shared`.
- `AgentSmithKit/Agents/BrownBehavior.swift` — registers the Brown tool list;
  the only place that grants Brown access.
- `AgentSmith/AgentSmith/AgentSmith.entitlements` — currently has
  `com.apple.security.automation.apple-events`, **no** `app-sandbox`
  entitlement, so AX should work after grant.

## 1. Code reuse vs. extraction — recommendation: **copy-and-adapt into AgentSmithKit**

Trade-offs:

- **SwiftPM dependency on macos-accessibility-client.** Bad fit. That repo is
  an Xcode app project, not a Swift package — no `Package.swift`, no library
  target. Restructuring it is a multi-day side quest. The CLAUDE.md sibling
  convention also expects siblings under `~/cursor/`, and this lives elsewhere.
- **Git submodule.** Same "it's an app, not a library" problem; adds release
  overhead before public release. Pass.
- **Copy-and-adapt.** Best fit. Reusable surface is small — six `Core/` files
  plus one permissions file plus selected `Models/` walkers. Copying lets us
  strip the SwiftUI tangles while keeping `nonisolated struct AXElement: @unchecked Sendable`
  intact. Preserve the original file-headers for attribution.

**Concretely:** create `AgentSmithPackage/Sources/AgentSmithKit/Accessibility/`
and copy `AXElement.swift`, `AXError+ext.swift`, `AXObserverWrapper.swift`,
`ElementSnapshot.swift`, `Formatting.swift` (rename to `AXFormatting.swift`),
`AccessibilityPermissions.swift`. Strip unnecessary `import AppKit` where
possible.

## 2. Tool API shape — five tools, small and composable

All Brown-only. All registered in `BrownBehavior.tools()`. Each uses a shared
`AccessibilityService` actor for IPC, mirroring `AppleScriptRunner.shared`.

### `list_ax_apps`
List foreground apps the agent can target. Cheap, no AX trust required.

```
args:    { query?: string }
returns: success("Found N: <name> [<bundleID>] pid=<pid> ...")
```

### `inspect_ax_element`
Unified read tool. Inspects an app's root, a window, or a specific element by
**selector**. Returns role, title, frame, attributes, children summary,
supported actions.

```
args: {
  target: { kind: "app", bundleID|pid: ... }
        | { kind: "selector", path: [{role, title?, identifier?, index?}], rootBundleID|rootPID }
  maxDepth?: int (default 1)
  includeAttributeNames?: [string]?
  includeAllAttributes?: bool        // default false (truncate large values)
}
returns: success(JSON ElementSnapshot — role/subrole/title/frame/attributes/actions/children[])
         failure("permission_required" | "no_such_app" | "no_match" | AXError text)
```

### `find_ax_elements`
Tree search with a predicate; returns paths suitable for re-targeting later.

```
args: {
  rootBundleID|rootPID,
  predicate: { role?, subrole?, title?, identifier?, value?, regex?: bool }
  maxResults?: int (default 50)
  maxDepth?: int (default 12)
}
returns: success([{ path: [...], role, title, frame, snippet }])
```

### `perform_ax_action`
Drive the UI. Plain `AXPress` plus the menu-walker case (open chain of menu
items in order so the leaf becomes addressable). Also `set_value` for text
fields, `focus`, `raise_window`.

```
args: {
  target: { kind: "selector", path: [...], rootBundleID|rootPID },
  action: "press" | "show_menu" | "raise" | "focus" | "set_value" | "<AXFooAction>",
  value?: string,
  menuWalk?: bool        // if true and target is a menu item, walks ancestors
  pressDelayMS?: int (default 80)
  verifyAfterMS?: int (default 200)
}
returns: success({ performed: true, verifiedRole?, verifiedValue? })
         failure("action_unsupported"|"element_invalid"|"timed_out"|"permission_required")
```

### `watch_ax_events`
One-shot windowed capture of an app's `AXObserver` notification stream.
Brown's tool model is request/response, so v1 is windowed; streaming is a
later expansion.

```
args: {
  target: { rootBundleID|rootPID },
  notifications?: [string]?         // default standardNotifications
  durationMS: int (clamp 100..30000)
  maxEvents?: int (default 200)
}
returns: success([{ ts, notification, elementSummary, userInfo: {...} }])
```

**Why five and not one** — mirrors how `glob`/`grep`/`file_read`/etc decompose;
the LLM picks the right verb.

**Selector format.** Path-based, not opaque pointers. AXUIElement handles
aren't stable across calls (CF refs to live cross-process pointers; the target
app's element graph mutates underneath us). Each path step is
`{ role, title?, identifier?, index?, subrole? }`. Resolving the path
re-walks the tree. Costs per-call AX reads but is robust against UI changes
between calls.

## 3. File additions / edits in agent-smith

**New files** (all under `AgentSmithPackage/Sources/AgentSmithKit/`):

- `Accessibility/AXElement.swift` — copied; trimmed to non-UI use. Drop
  `Identifiable` (UI-only).
- `Accessibility/AXError+ext.swift` — copied verbatim.
- `Accessibility/AXObserverWrapper.swift` — copied; tweak callback to deliver
  to a dedicated `AXEventBuffer` actor instead of `@MainActor` `EventHandler`
  (run-loop source still installs on the main run loop, but the bridge to the
  buffer is `Task { await buffer.append(...) }`).
- `Accessibility/AXFormatting.swift` — `Formatting` + `ElementLabel`, renamed.
- `Accessibility/ElementSnapshot.swift` — copied; the `actor ElementSnapshotBuilder`
  is exactly what we want.
- `Accessibility/AccessibilityPermissions.swift` — copied; promoted to `public`
  so the app target can read `isTrusted`.
- `Accessibility/AccessibilityService.swift` — **new**. Top-level actor,
  `static let shared`. Public surface:
  - `func appElement(forBundleID:) -> AXElement?` / `forPID:`
  - `func snapshot(target:maxDepth:includeAll:) -> Result<JSON, AXToolError>`
  - `func find(rootPID:predicate:maxDepth:maxResults:) -> [PathHit]`
  - `func perform(target:action:value:menuWalk:) -> Result<PerformOutcome, AXToolError>`
  - `func captureEvents(rootPID:notifications:duration:maxEvents:) async -> [AXObserverWrapper.Event]`
  - All public methods first call `AXIsProcessTrusted()` and short-circuit
    with `.permissionRequired`.
  - Owns `setMessagingTimeout(2.0)` per-app caching.
- `Accessibility/AXSelector.swift` — **new**. Path codable type plus the
  resolver: `func resolve(_ selector: AXSelector, root: AXElement) throws -> AXElement?`.
  Separate file gives us a unit-test target.
- `Accessibility/AXMenuWalker.swift` — **new**. Lift
  `MenuChainWalker.collectMenuChain` (the static collection); replace the
  SwiftUI-coupled `performAXPressWalk` with a non-`@MainActor`, settings-free
  async version. Original calls `runningApp.activate()` (`AppKit`); keep that
  — `import AppKit` is fine in the package.
- `Tools/InspectAXElementTool.swift`, `Tools/FindAXElementsTool.swift`,
  `Tools/PerformAXActionTool.swift`, `Tools/ListAXAppsTool.swift`,
  `Tools/WatchAXEventsTool.swift` — **new**. One per public tool. Structured
  like `RunAppleScriptTool`: `isAvailable { $0.agentRole == .brown }`,
  Brown-facing description with `BrownBehavior.approvalGateNote(...)`,
  JSON-schema parameters, `execute` parses args and dispatches to
  `AccessibilityService.shared`.

**Edits:**

- `AgentSmithPackage/Sources/AgentSmithKit/Agents/BrownBehavior.swift` — add
  the five new tools to `tools(...)`. *Reason:* per CLAUDE.md, `tools()` is
  the single point of access grant.
- `AgentSmith/AgentSmith/ViewModels/SharedAppState.swift` — add an
  `@MainActor @Observable AccessibilityPermissions` instance, mirroring the
  source repo's pattern.
- `AgentSmith/AgentSmith/Views/SettingsView.swift` — add a "Permissions"
  subsection with AX-trust status + Request / Open System Settings / Recheck
  buttons.
- `AgentSmith/AgentSmith/Views/Banners/ChannelBanners.swift` — add an
  `AXPermissionRequiredBanner` shown when a tool returns `permission_required`.
- `AgentSmith/AgentSmith/AgentSmithApp.swift` — kick off
  `AccessibilityPermissions.recheck()` on
  `NSApplication.didBecomeActiveNotification`. *Reason:* user grants trust in
  System Settings, alt-tabs back; refresh without forcing a relaunch.
- `AgentSmithPackage/Tests/AgentSmithTests/` — `AXSelectorTests.swift` and
  `AccessibilityToolArgsTests.swift`. We can't unit-test live AX without trust
  + a target, but selector resolution and arg parsing are isolatable.

## 4. Permissions UX

Three layers, mirroring the source repo's `Permissions/` and `Views/PermissionsBanner.swift`:

1. **Background trust check.** `SharedAppState` constructs
   `AccessibilityPermissions` at launch. `recheck()` runs on
   `NSApplication.didBecomeActiveNotification`.
2. **Settings panel.** Always-visible "Accessibility" subsection in
   `SettingsView` with status (Granted / Not Granted), `Request Permission`
   (calls `AXIsProcessTrustedWithOptions` with `"AXTrustedCheckOptionPrompt": true`
   — note the literal-string Swift 6 workaround), `Open System Settings`
   (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`),
   `Recheck`.
3. **Just-in-time channel banner.** When any AX tool returns
   `permission_required`, the tool's failure is a structured short string the
   channel log recognizes (e.g. `"AX permission required. Open Settings → Accessibility to grant."`),
   and the channel renders an `AXPermissionRequiredBanner` next to it with the
   same three buttons. The `tool_result` includes the same text so Brown can
   also `reply_to_user` with a plain explanation.

**Caveat to surface in the agent's prompt and Settings UI.** AX permission is
grant-once, system-wide, scoped to bundle ID + signature; if the signature
changes (e.g. a clean dev build re-signs), the user has to re-grant. This will
bite during dev builds.

## 5. Threading / concurrency — the real pitfalls

- **`AXObserver` run-loop source must run on the main thread.**
  `CFRunLoopAddSource(CFRunLoopGetMain(), ...)` is non-negotiable —
  `AXObserverGetRunLoopSource` delivers callbacks there. The C callback in
  `AXObserverWrapper.cCallback` already uses `MainActor.assumeIsolated`. When
  we move it into the package, the safest pattern is: *create / register the
  wrapper from `MainActor`, but funnel events into a non-isolated `AsyncStream`
  that an actor consumes.* Replace the `@MainActor EventHandler` typealias
  with `@Sendable (Event) -> Void` and let the caller do the actor hop.
- **Cross-process AX reads are synchronous and slow.**
  `AXUIElementCopyAttributeValue` blocks the calling thread waiting on the
  target app. The source repo's `actor ElementSnapshotBuilder` pattern keeps
  the SwiftUI layer responsive. We must do the same: never call AX from
  Brown's tool execution path on the main actor. `AccessibilityService` being
  a top-level `actor` handles this naturally.
- **`setMessagingTimeout(2.0)` on every app element.** Without this an
  unresponsive target hangs the actor, and because `AccessibilityService` is
  a single actor, a hung call serializes every other tool call. Apply on
  element creation. Consider 1.0s for `find` and `inspect`, 3-5s only for
  `perform`.
- **`AXUIElement` is a CF reference to a live remote object.** `AXElement` is
  `@unchecked Sendable` — that lie is acceptable because CF refs are
  thread-safe to retain/release/equate, and AX calls themselves are
  thread-safe (just slow). Don't cache `AXElement` values across long time
  horizons in the LLM-facing layer; resolve via `AXSelector` each call.
- **`AXObserverWrapper` deinit removes the run-loop source.** Capture in
  `Task` carefully. The `watch_ax_events` tool builds the wrapper, awaits the
  duration, then drops it — capture inside the function scope so deinit fires
  deterministically.
- **`AXIsProcessTrusted` is cheap and synchronous; safe to call per tool
  invocation.** No need to cache it. The `Observable` wrapper is for UI; the
  actor checks live.
- **Swift 6 strict-concurrency caveat.** `kAXTrustedCheckOptionPrompt` is a
  non-Sendable `Unmanaged<CFString>` — use the literal
  `"AXTrustedCheckOptionPrompt"` (the source repo already does). Verify other
  CF constants on copy.

## 6. Testing & smoke plan

**Unit tests** (`AgentSmithPackage/Tests/AgentSmithTests/`):

- `AXSelectorTests` — path resolution against a fake `AXNode` tree (use a
  protocol so the resolver works on a mock). Covers index-vs-title
  disambiguation, missing intermediate nodes, identifier match.
- `AXToolArgsTests` — round-trip parsing of `inspect_ax_element` args
  including `target` variants and `predicate` regex flag.

No live-AX tests — infeasible without trust + a target on the test runner;
CI machines don't grant AX.

**Manual smoke** (document in `Accessibility/README.md` inside the package):

1. Build via `mcp__drews-xcode-mcp__build_project` (per CLAUDE.md, never
   `xcodebuild`).
2. Launch via `run_project_with_user_interaction`. Grant AX in System
   Settings → Privacy & Security → Accessibility. Click "Recheck."
3. **Test 1 — list.** "What apps are running that I could automate?" → Brown
   calls `list_ax_apps`.
4. **Test 2 — inspect.** "Inspect Finder's frontmost window — what windows
   does it have?" → `inspect_ax_element({target:{kind:'app', bundleID:'com.apple.finder'}, maxDepth:2})`.
   Expect role=AXApplication with one or more child AXWindow nodes.
5. **Test 3 — find.** "Find any Finder button labeled 'New Folder.'" →
   `find_ax_elements({rootBundleID:'com.apple.finder', predicate:{role:'AXButton', title:'New Folder'}})`.
6. **Test 4 — perform.** "Open Finder's File menu, then click New Folder." →
   `perform_ax_action` with `menuWalk: true` against the leaf path. Verify a
   new untitled folder appears.
7. **Test 5 — watch.** "Watch Finder for 5 seconds and tell me what changes
   when I close this window." → `watch_ax_events({rootBundleID:'com.apple.finder', durationMS:5000})`.
   Expect `AXUIElementDestroyed` and `AXFocusedWindowChanged` events.
8. **Test 6 — permission denial.** Revoke AX in Settings, retry step 4.
   Expect `permission_required` failure, channel banner appears, Settings
   button works. Re-grant, click Recheck, retry succeeds.

Read-only AX calls (1–3) should pass `SafeBySheer` Security Agent evaluation. Test 4
(perform) is where Security Agent evaluation matters; verify the UNSAFE/WARN/SAFE path
lights up.

## 7. Risks / open questions

1. **Sandboxing posture.** Agent Smith currently has
   `com.apple.security.automation.apple-events` but no `app-sandbox`
   entitlement. AX trust works for non-sandboxed apps; if the user later
   sandboxes the app for distribution, AX continues to work but
   `setAttribute(kAXValueAttribute, ...)` on certain text fields can fail in
   sandboxed builds. **Decision needed:** confirm Agent Smith ships
   unsandboxed (likely yes — bash tool, process killer, AppleScript) or scope
   AX features that won't survive sandboxing.
2. **Security Agent evaluation policy for UI control.** `perform_ax_action` is
   destructive — can click buttons, including ones that delete things. Security Agent
   currently reviews tool *args*. A bare `{action:"press", path:[...]}`
   doesn't tell Security Agent whether the button says "Delete All." Either (a) have
   `perform_ax_action` first read the target's title/role into the args
   before submission, or (b) read-then-decide internally and put resolved
   target description into the tool result. Recommend (a): the resolver runs
   a read pass and rewrites the args with `_resolvedTitle`/`_resolvedRole`
   before Security Agent sees it. **Decision needed.**
3. **Streaming vs. windowed event capture.** v1 plan uses `watch_ax_events`
   as a fixed-duration capture. Real interactive use ("watch until you see
   X") needs streaming or polling. Per CLAUDE.md, tools are one-shot. Defer.
4. **Selector stability.** Two siblings with identical role+title+no-identifier
   need an `index`, but indices change as the app's UI mutates between calls.
   Mitigation: when `find_ax_elements` returns hits, include `index` and a
   unique `disambiguator` (e.g. position-in-frame fingerprint) the resolver
   can use as a tiebreaker. v1 ships with `index` only and documents the
   brittleness.
5. **Main-thread requirement on observer creation.** Source repo creates
   `AXObserverWrapper` on `@MainActor`. Our `AccessibilityService` is a
   non-main actor. Check whether `AXObserverCreateWithInfoCallback` itself
   requires the main thread (likely no — only `AXObserverGetRunLoopSource`
   registration adds to *some* run loop, and `CFRunLoopGetMain()` returns the
   same loop regardless of caller). Smoke-test 5 will validate; if it fails,
   hop to `MainActor` for create+register only.
6. **Source repo licensing / attribution.** File headers say "Written by
   Andrew Benson. Copyright (c) 2026 Nuclear Cyborg Corp." Same author —
   fine, but explicitly preserve attribution headers when copying.
7. **CLAUDE.md SwiftUI rules.** Tool plumbing is non-UI. The two UI surfaces
   we touch (Settings panel, channel banner) follow existing patterns:
   central colors via `AppColors`/`AppFonts`, no `LazyVStack`, `@Observable`
   for state.
8. **`@unchecked Sendable` on `AXElement`.** Already in the source.
   Acceptable but worth a code-review check on the package side — Swift 6
   strict mode in `AgentSmithKit` may surface concerns the original repo
   didn't hit. Mitigation: keep `AXElement` use confined to within
   `AccessibilityService` and the resolver; don't pass it across package/app
   boundary. The `Accessibility/` subdir is internal.
9. **No force unwraps, no `try?` without rationale.** Source repo's AX code
   uses `try?` *liberally* (e.g. `var role: String? { (try? attribute(kAXRoleAttribute)) as? String }`).
   The rationale is sound — these reads return `nil` for missing-attribute,
   which is a normal-case outcome, and propagating throws upward would force
   every accessor to be `throws`. Leave a comment on each `try?` site
   explaining "missing attribute is normal; surface as nil." Same for
   `unsafeDowncast` in `AXValueFormatter` — guarded by `CFGetTypeID` checks
   and worth keeping with a comment.

## Critical files for implementation

- `/Users/andrew/Documents/ncc_source/cursor/macos-accessibility-client/MacOSAccessibilityClient/MacOSAccessibilityClient/Core/AXElement.swift`
- `/Users/andrew/Documents/ncc_source/cursor/macos-accessibility-client/MacOSAccessibilityClient/MacOSAccessibilityClient/Core/AXObserverWrapper.swift`
- `/Users/andrew/Documents/ncc_source/cursor/macos-accessibility-client/MacOSAccessibilityClient/MacOSAccessibilityClient/Permissions/AccessibilityPermissions.swift`
- `/Users/andrew/cursor/macos-agent-smith/AgentSmithPackage/Sources/AgentSmithKit/Tools/AgentTool.swift`
- `/Users/andrew/cursor/macos-agent-smith/AgentSmithPackage/Sources/AgentSmithKit/Agents/BrownBehavior.swift`
