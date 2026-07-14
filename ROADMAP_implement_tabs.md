# Plan: Multiple Tabs with Independent Agent Pairs

## Context

The app currently has a single conversation: one `AppViewModel` owns one `OrchestrationRuntime`, which manages one Smith + Brown agent pair, one `MessageChannel`, and one `TaskStore`. Everything flows through this single pipeline. The user wants multiple independent tabs, each running its own Smith+Brown agent pair with its own message history and task list.

The key insight is that `OrchestrationRuntime`, `MessageChannel`, `TaskStore`, and `AgentActor` are already instance-based (not singletons), so the kit layer needs **zero changes**. We just need to instantiate multiple `AppViewModel`s and wire them into a tabbed UI.

## Approach

### 1. Session Model (new file in AgentSmithKit)

**`AgentSmithPackage/Sources/AgentSmithKit/Persistence/Session.swift`**

```swift
public struct Session: Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
}
```

Lightweight metadata. Each session maps 1:1 to a tab and an `AppViewModel` instance.

### 2. PersistenceManager — Session-Scoped Storage

**Modify: `AgentSmithPackage/Sources/AgentSmithKit/Persistence/PersistenceManager.swift`**

- Add `public init(sessionID: UUID)` — stores data under `AgentSmith/sessions/<sessionID>/` instead of `AgentSmith/`
- Keep the existing `public init()` working for backward compatibility / migration of existing data
- Add `public static func loadSessionList() throws -> [Session]` and `saveSessionList(_:)` — stored at `AgentSmith/sessions.json`
- Add `public func deleteSessionData() throws` — removes the session's subdirectory

Directory layout:
```
~/Library/Application Support/AgentSmith/
├── sessions.json                          # list of Session metadata
├── sessions/
│   ├── <uuid-1>/
│   │   ├── channel_log.json
│   │   ├── tasks.json
│   │   └── attachments/
│   ├── <uuid-2>/
│   │   ├── channel_log.json
│   │   ├── tasks.json
│   │   └── attachments/
│   ...
├── channel_log.json                       # legacy (migrated on first launch)
├── tasks.json                             # legacy (migrated on first launch)
└── attachments/                           # legacy
```

### 3. AppViewModel — Minor Adjustments

**Modify: `AgentSmith/AgentSmith/ViewModels/AppViewModel.swift`**

- Add `let session: Session` property, passed at init
- Init creates `PersistenceManager(sessionID: session.id)` instead of `PersistenceManager()`
- Extract shared state (nickname, llmKit, speechController, agentAssignments, agent tuning) out of AppViewModel into a new shared object (see step 4) — these are app-global, not per-session
- Per-session state stays in AppViewModel: messages, tasks, runtime, isRunning, isAborted, inputText, etc.

### 4. SharedAppState — App-Global State (new file)

**`AgentSmith/AgentSmith/ViewModels/SharedAppState.swift`**

Holds state that's shared across all tabs:
- `llmKit: LLMKitManager`
- `nickname: String`
- `agentAssignments: [AgentRole: UUID]`
- `agentPollIntervals`, `agentMaxToolCalls`, `agentMessageDebounceIntervals`
- `speechController: SpeechController`
- `autoStartEnabled: Bool`
- `resolvedLLMConfigs() -> [AgentRole: LLMConfiguration]`
- `persistAgentAssignments()`, `persistNickname()`
- `loadPersistedState()` — loads nickname, llmKit, assignments, bundled defaults

This is `@Observable @MainActor`, created once in the app, passed to all AppViewModels and SettingsView.

### 5. SessionManager — Tab Lifecycle (new file)

**`AgentSmith/AgentSmith/ViewModels/SessionManager.swift`**

`@Observable @MainActor` class managing the tab list:
- `sessions: [Session]`
- `activeSessionID: UUID`
- `viewModels: [UUID: AppViewModel]` — lazily created per session
- `createSession(name:)` — adds session, creates AppViewModel, persists session list
- `closeSession(id:)` — stops runtime, removes from list, deletes session data from disk (ephemeral)
- `renameSession(id:, name:)`
- `persistSessionList()`
- `loadSessions()` — loads from `sessions.json`, handles migration of legacy single-session data

Migration: On first launch with no `sessions.json`, create a "Default" session and move existing `channel_log.json` / `tasks.json` / `attachments/` into `sessions/<new-uuid>/`.

**Tab behavior:**
- **Ephemeral** — closing a tab stops its agents and deletes its data from disk. No "reopen closed tab" concept.
- **Auto-start** — new tabs immediately start their agent pair using current LLM config (if configs are valid).

### 6. AgentSmithApp — Tabbed Window

**Modify: `AgentSmith/AgentSmith/AgentSmithApp.swift`**

```swift
@main
struct AgentSmithApp: App {
    @State private var sharedState = SharedAppState()
    @State private var sessionManager = SessionManager()

    var body: some Scene {
        WindowGroup {
            TabContainerView(sharedState: sharedState, sessionManager: sessionManager)
                .task { await sharedState.loadPersistedState(); await sessionManager.loadSessions(sharedState: sharedState) }
        }
        .commands { ... }

        Settings { SettingsView(sharedState: sharedState) }
    }
}
```

### 7. TabContainerView — Tab Bar UI (new file)

**`AgentSmith/AgentSmith/Views/TabContainerView.swift`**

Custom tab bar at the top of the window (like Safari/Terminal tabs):
- Horizontal row of tab buttons showing session name + close button
- "+" button to create new tab
- Double-click tab name to rename
- Each tab renders `MainView(viewModel: sessionManager.viewModel(for: session), sharedState: sharedState)`
- Only the active tab's MainView is rendered (others are preserved in memory but not in the view hierarchy, to avoid multiple heavy views)
- Context menu on tabs: Rename, Close, Close Others

### 8. MainView — Minor Changes

**Modify: `AgentSmith/AgentSmith/Views/MainView.swift`**

- Accept `sharedState: SharedAppState` for config validation / start logic
- Remove welcome sheet / config validation (move to TabContainerView or SharedAppState level since they're app-global)
- Keep everything else as-is — it already works with a single AppViewModel

### 9. SettingsView — Use SharedAppState

**Modify: `AgentSmith/AgentSmith/Views/SettingsView.swift`**

- Change from `viewModel: AppViewModel` to `sharedState: SharedAppState`
- Settings are app-global, not per-tab

### 10. Emergency Stop — All Tabs

**Modify: Command group in AgentSmithApp**

- Emergency Stop (Cmd+Shift+K) stops all sessions: `sessionManager.stopAll()`
- Per-tab stop remains in the toolbar

## Files to Create
- `AgentSmithPackage/Sources/AgentSmithKit/Persistence/Session.swift`
- `AgentSmith/AgentSmith/ViewModels/SharedAppState.swift`
- `AgentSmith/AgentSmith/ViewModels/SessionManager.swift`
- `AgentSmith/AgentSmith/Views/TabContainerView.swift`

## Files to Modify
- `AgentSmithPackage/Sources/AgentSmithKit/Persistence/PersistenceManager.swift` — session-scoped init
- `AgentSmith/AgentSmith/ViewModels/AppViewModel.swift` — take Session + SharedAppState, extract shared state
- `AgentSmith/AgentSmith/AgentSmithApp.swift` — SessionManager + SharedAppState + TabContainerView
- `AgentSmith/AgentSmith/Views/MainView.swift` — accept SharedAppState, remove app-level sheets
- `AgentSmith/AgentSmith/Views/SettingsView.swift` — use SharedAppState
- `AgentSmith/AgentSmith/Views/InspectorView.swift` — no changes expected (already takes data as params)

## Files NOT Modified (Kit Layer)
- OrchestrationRuntime — already instance-based
- MessageChannel — already instance-based
- TaskStore — already instance-based
- AgentActor — already instance-based
- All tool implementations — unchanged

## Verification
1. Build with drews-xcode-mcp after each major step
2. Launch app — should auto-migrate legacy data into a "Default" session tab
3. Create a second tab — should get independent message log, task list, and agent pair
4. Start agents in both tabs — both should run independently
5. Close and reopen app — both sessions should restore with their messages and tasks
6. Emergency Stop should halt all sessions
7. Settings changes should apply to newly started runtimes in any tab
