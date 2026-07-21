import SwiftUI
import AgentSmithKit
import SwiftLLMKit
import SemanticSearch
import os

/// App-global state shared by every session / tab.
///
/// Holds the LLM configuration catalog, speech, billing, the embedding engine, and the
/// shared memory corpus. Created once at app launch and passed to every `AppViewModel`.
///
/// Memories and task summaries are shared across all sessions — they represent facts
/// Smith has learned about the user and the world. Per-session `OrchestrationRuntime`
/// instances receive `sharedMemoryStore` so each Smith reads and writes the same pool.
/// Identifies a tab in the Settings window, for selection binding and deep-linking.
enum SettingsTab: Hashable {
    case general, providers, configurations, metadata, audio, mcp, tools
}

@Observable
@MainActor
final class SharedAppState {
    /// The user's preferred nickname, shown in the UI and injected into system prompts.
    var nickname: String = ""
    /// Whether the first-run setup flow has been completed (or skipped via "configure
    /// manually"). Gates the onboarding sheet. Loaded — with a migration for pre-onboarding
    /// installs — in `performLoadPersistedState`; persist changes via `persistOnboardingComplete()`.
    var didCompleteOnboarding: Bool = true
    /// Whether to auto-start sessions when all their agent configs are valid on launch.
    var autoStartEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "autoStartEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "autoStartEnabled")
    }() {
        didSet { UserDefaults.standard.set(autoStartEnabled, forKey: "autoStartEnabled") }
    }

    /// Debug toggle: when true, every timer scheduled/fired/cancelled event is mirrored to
    /// the channel transcript as a `[Timer] …` system message so the user can see timer
    /// activity inline. Defaults to false. Persisted via UserDefaults so the choice survives
    /// app restart.
    var showTimerActivityInTranscript: Bool = {
        UserDefaults.standard.bool(forKey: "debugShowTimerActivityInTranscript")
    }() {
        didSet { UserDefaults.standard.set(showTimerActivityInTranscript, forKey: "debugShowTimerActivityInTranscript") }
    }

    /// When true, task lifecycle banners (created / acknowledged / ready for review /
    /// completed / etc.) show their inline timestamp. Default true.
    var showTimestampsOnTaskBanners: Bool = SharedAppState.boolDefault(key: "showTimestampsOnTaskBanners", default: true) {
        didSet { UserDefaults.standard.set(showTimestampsOnTaskBanners, forKey: "showTimestampsOnTaskBanners") }
    }

    /// When true, tool-call rows show their timestamp. Default true.
    var showTimestampsOnToolCalls: Bool = SharedAppState.boolDefault(key: "showTimestampsOnToolCalls", default: true) {
        didSet { UserDefaults.standard.set(showTimestampsOnToolCalls, forKey: "showTimestampsOnToolCalls") }
    }

    /// When true, agent↔agent and agent↔user message rows show their timestamp. Default true.
    var showTimestampsOnMessaging: Bool = SharedAppState.boolDefault(key: "showTimestampsOnMessaging", default: true) {
        didSet { UserDefaults.standard.set(showTimestampsOnMessaging, forKey: "showTimestampsOnMessaging") }
    }

    /// When true, system-sender rows and system-feedback banners (memory saved/searched,
    /// timer activity) show their timestamp. Default true.
    var showTimestampsOnSystemMessages: Bool = SharedAppState.boolDefault(key: "showTimestampsOnSystemMessages", default: true) {
        didSet { UserDefaults.standard.set(showTimestampsOnSystemMessages, forKey: "showTimestampsOnSystemMessages") }
    }

    /// When true, completed tool calls show the elapsed time between the request and its
    /// output. Default false (off until the user opts in).
    var showElapsedTimeOnToolCalls: Bool = SharedAppState.boolDefault(key: "showElapsedTimeOnToolCalls", default: false) {
        didSet { UserDefaults.standard.set(showElapsedTimeOnToolCalls, forKey: "showElapsedTimeOnToolCalls") }
    }

    /// When true, transient lifecycle rows from agent restarts ("All agents stopped",
    /// "Smith agent <id> is online", "Security Agent online") are rendered. Off
    /// by default — these are mostly noise inside an active session and only useful when
    /// debugging spawn/stop flow. The runtime always emits the messages; this flag only
    /// gates whether the channel log surfaces them.
    var showRestartChrome: Bool = SharedAppState.boolDefault(key: "showRestartChrome", default: false) {
        didSet { UserDefaults.standard.set(showRestartChrome, forKey: "showRestartChrome") }
    }

    /// Controls what happens when a scheduled task's wake fires while another task is
    /// currently `.running` or `.awaitingReview`. Independent of `autoRunNextTask` —
    /// scheduled wakes ALWAYS run when their time comes, regardless of that flag.
    /// - `true`: pause the running task, run the scheduled task to completion, then
    ///   resume the paused task. Disrupts in-flight work but honours the schedule
    ///   precisely.
    /// - `false` (default): let the running task finish, then run the scheduled task.
    ///   Preserves in-flight work; the schedule slips by the running task's tail.
    var scheduledWakesInterruptRunning: Bool = SharedAppState.boolDefault(key: "scheduledWakesInterruptRunning", default: false) {
        didSet { UserDefaults.standard.set(scheduledWakesInterruptRunning, forKey: "scheduledWakesInterruptRunning") }
    }

    /// How many tasks may run concurrently, each with its own worker (Brown). 1–10;
    /// default 4. Starting beyond this never evicts a running task: run_task and the
    /// play button refuse, create_task queues, auto-run fills slots as they free.
    /// Applied to each session's runtime at start and pushed live on change.
    var maxSimultaneousTasks: Int = SharedAppState.intDefault(key: "maxSimultaneousTasks", default: 4) {
        didSet {
            UserDefaults.standard.set(maxSimultaneousTasks, forKey: "maxSimultaneousTasks")
            notifyWorkerCapacityChanged()
        }
    }

    /// Per-session observers for worker-capacity changes (same shape as the
    /// tool-security observers): each session's view model pushes the new value to its
    /// runtime so Settings changes apply without a restart.
    private var workerCapacityObservers: [UUID: @MainActor () -> Void] = [:]
    func registerWorkerCapacityObserver(_ id: UUID, _ observer: @escaping @MainActor () -> Void) {
        workerCapacityObservers[id] = observer
    }
    func unregisterWorkerCapacityObserver(_ id: UUID) {
        workerCapacityObservers.removeValue(forKey: id)
    }
    private func notifyWorkerCapacityChanged() {
        for observer in workerCapacityObservers.values { observer() }
    }

    /// How many task columns the top-of-window overlay bar shows before overflowing
    /// into the junk drawer (1–8; default 4).
    var taskOverlayColumns: Int = SharedAppState.intDefault(key: "taskOverlayColumns", default: 4) {
        didSet { UserDefaults.standard.set(taskOverlayColumns, forKey: "taskOverlayColumns") }
    }

    /// Whether the task overlay bar is shown at all (toolbar toggle).
    var taskOverlayVisible: Bool = SharedAppState.boolDefault(key: "taskOverlayVisible", default: true) {
        didSet { UserDefaults.standard.set(taskOverlayVisible, forKey: "taskOverlayVisible") }
    }

    /// Whether the overlay bar is collapsed to the one-line strip.
    var taskOverlayCollapsed: Bool = SharedAppState.boolDefault(key: "taskOverlayCollapsed", default: false) {
        didSet { UserDefaults.standard.set(taskOverlayCollapsed, forKey: "taskOverlayCollapsed") }
    }

    /// User-dragged height of the expanded overlay bar, clamped in the view.
    var taskOverlayHeight: Double = SharedAppState.doubleDefault(key: "taskOverlayHeight", default: 170) {
        didSet { UserDefaults.standard.set(taskOverlayHeight, forKey: "taskOverlayHeight") }
    }

    /// Maximum bytes accepted for any single attachment. Files larger than this are
    /// rejected at ingestion time. Default 25 MB — large enough to cover phone-camera
    /// photos and small PDFs, small enough that one bad file can't blow the LLM context.
    /// Persisted via UserDefaults; settable in Settings.
    var maxAttachmentBytesPerFile: Int = SharedAppState.intDefault(key: "maxAttachmentBytesPerFile", default: 25 * 1024 * 1024) {
        didSet { UserDefaults.standard.set(maxAttachmentBytesPerFile, forKey: "maxAttachmentBytesPerFile") }
    }

    /// Maximum aggregate bytes across all attachments on a single tool call (e.g. a
    /// `task_complete(attachment_paths: [...])` with five files). Default 50 MB. The cap
    /// is enforced at the tool-resolver layer so the LLM gets a clean error rather than
    /// the runtime silently truncating.
    var maxAttachmentBytesPerMessage: Int = SharedAppState.intDefault(key: "maxAttachmentBytesPerMessage", default: 50 * 1024 * 1024) {
        didSet { UserDefaults.standard.set(maxAttachmentBytesPerMessage, forKey: "maxAttachmentBytesPerMessage") }
    }

    /// True while the one-time embedding re-embed migration runs AND it's large enough to warrant a
    /// blocking overlay (≈10s+, see `migrationOverlayThreshold`). Transient — not persisted.
    var migrationInProgress: Bool = false
    /// Number of entries the in-progress migration is re-embedding (for the overlay's copy).
    var migrationEntryCount: Int = 0
    /// Below this many stale entries the migration is fast enough (≈10s at the measured ~1.3 s/doc)
    /// that no overlay is shown — it just blocks briefly during startup.
    static let migrationOverlayThreshold = 8

    /// Security: whether Security Agent runs the per-task pre-flight tool-scoping pass. Off ⇒ Brown starts
    /// with all candidate tools (subject to global policy + per-task overrides). Takes effect on the
    /// next session start. Persisted.
    var enablePreflightScoping: Bool = SharedAppState.boolDefault(key: "enablePreflightScoping", default: true) {
        didSet { UserDefaults.standard.set(enablePreflightScoping, forKey: "enablePreflightScoping"); notifyToolSecurityChanged() }
    }
    /// Security: whether Security Agent evaluates each individual Brown tool call (SAFE/WARN/UNSAFE/ABORT).
    /// Off ⇒ Brown's approved tools run without per-call review. Applied immediately to active sessions.
    var enablePerToolCheck: Bool = SharedAppState.boolDefault(key: "enablePerToolCheck", default: true) {
        didSet { UserDefaults.standard.set(enablePerToolCheck, forKey: "enablePerToolCheck"); notifyToolSecurityChanged() }
    }
    /// Global per-tool availability policy (Default/Always/Never), keyed by tool name. Overrides the
    /// automatic scoping verdict for Brown. Persisted as JSON; applied immediately to active sessions.
    var globalToolPolicies: [String: ToolPolicy] = SharedAppState.loadToolPolicies() {
        didSet { SharedAppState.saveToolPolicies(globalToolPolicies); notifyToolSecurityChanged() }
    }
    /// Observers (one per active session) that push the current tool-security settings down to their
    /// runtime when any setting changes — so global Settings apply immediately, with no restart.
    private var toolSecurityObservers: [UUID: @MainActor () -> Void] = [:]
    func registerToolSecurityObserver(_ id: UUID, _ observer: @escaping @MainActor () -> Void) {
        toolSecurityObservers[id] = observer
    }
    func removeToolSecurityObserver(_ id: UUID) {
        toolSecurityObservers.removeValue(forKey: id)
    }
    private func notifyToolSecurityChanged() {
        for observer in toolSecurityObservers.values { observer() }
    }

    /// Observers (one per active session) that rebuild and push per-role LLM providers down to their
    /// runtime when an assigned model configuration changes — so swapping an agent's model in Settings
    /// takes effect on the next task with no session restart.
    private var modelAssignmentObservers: [UUID: @MainActor () -> Void] = [:]
    func registerModelAssignmentObserver(_ id: UUID, _ observer: @escaping @MainActor () -> Void) {
        modelAssignmentObservers[id] = observer
    }
    func removeModelAssignmentObserver(_ id: UUID) {
        modelAssignmentObservers.removeValue(forKey: id)
    }
    private func notifyModelAssignmentsChanged() {
        for observer in modelAssignmentObservers.values { observer() }
    }
    private static func loadToolPolicies() -> [String: ToolPolicy] {
        guard let data = UserDefaults.standard.data(forKey: "globalToolPolicies"),
              let decoded = try? JSONDecoder().decode([String: ToolPolicy].self, from: data) else { return [:] }
        return decoded
    }
    private static func saveToolPolicies(_ policies: [String: ToolPolicy]) {
        if let data = try? JSONEncoder().encode(policies) {
            UserDefaults.standard.set(data, forKey: "globalToolPolicies")
        }
    }

    /// Reads an Int from UserDefaults, defaulting when the key has never been set.
    /// Used by the attachment-cap settings so a "first time launch" picks up the
    /// documented default rather than zero.
    private static func intDefault(key: String, default fallback: Int) -> Int {
        if UserDefaults.standard.object(forKey: key) == nil { return fallback }
        return UserDefaults.standard.integer(forKey: key)
    }

    private static func doubleDefault(key: String, default fallback: Double) -> Double {
        if UserDefaults.standard.object(forKey: key) == nil { return fallback }
        return UserDefaults.standard.double(forKey: key)
    }

    /// Reads a Bool from UserDefaults, defaulting to `default` when the key has never been set.
    /// Used by the timestamp-display toggles so the documented "default true" survives the
    /// classic `bool(forKey:)` returning false for missing keys.
    private static func boolDefault(key: String, default fallback: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// SwiftLLMKit instance managing providers, models, and configurations (shared catalog).
    let llmKit = LLMKitManager(
        appIdentifier: Bundle.main.bundleIdentifier ?? "com.agentsmith",
        keychainServicePrefix: "com.agentsmith.SwiftLLMKit"
    )

    let speechController = SpeechController()

    /// Persistent token usage analytics store (app-global billing rollup).
    private(set) var usageStore: UsageStore

    /// Cached, incrementally-updated cost rollup over today / this week / this
    /// month / this year + the matching prior periods. Drives the inspector's
    /// Cost Estimate panel. Built once per app launch in `performLoadPersistedState`.
    private(set) var costBoard: CostBoard?

    /// Mirror of `costBoard.snapshot` republished to the main thread via the
    /// `setOnUpdate` callback. SwiftUI views observe this property and never
    /// touch the actor directly.
    private(set) var costBoardSnapshot: CostBoard.Snapshot = .empty

    /// Snapshot of LiteLLM pricing keyed by `"providerID/modelID"`. Built once
    /// after the model catalog refresh completes. Handed to `CostBoard` and to
    /// any per-session cost helpers via the `pricingLookup` closure.
    private(set) var pricingSnapshot: [String: ModelPricing] = [:]

    /// `(providerID, modelID) -> ModelPricing?` resolver derived from
    /// `pricingSnapshot`. Stable closure suitable for handing to `UsageAggregator`
    /// without crossing the main-actor boundary on the hot path.
    var pricingLookup: @Sendable (String?, String) -> ModelPricing? {
        let snapshot = pricingSnapshot
        return { providerID, modelID in
            guard let providerID else { return nil }
            return snapshot["\(providerID)/\(modelID)"]
        }
    }

    /// Semantic search engine, lazily created on first `start()` by any session and reused
    /// thereafter so the MLX model isn't reloaded on every Run/Stop cycle or per-session.
    private(set) var semanticSearchEngine: SemanticSearchEngine?

    /// Most recent progress event from `SemanticSearchEngine.prepare()`.
    private var embeddingPrepareProgress: PrepareProgress?

    /// Shared memory store — all session runtimes write to and read from the same corpus.
    /// Created lazily in `ensureMemoryStore()` once the semantic engine is prepared.
    private(set) var memoryStore: MemoryStore?

    /// All stored memories, refreshed when the memory store changes (backs MemoryEditorView).
    var storedMemories: [MemoryEntry] = []
    /// All stored task summaries, refreshed when the memory store changes.
    var storedTaskSummaries: [TaskSummaryEntry] = []

    /// Global archived tasks (across all sessions), newest first. Mirrors `inactiveTaskStore`'s
    /// `.archived` bucket so every window's sidebar updates live. Active tasks stay per-session
    /// on each `AppViewModel`; only archived/deleted are global.
    private(set) var archivedTasks: [AgentTask] = []
    /// Global deleted ("Recently Deleted") tasks (across all sessions), newest first. Mirrors
    /// `inactiveTaskStore`'s `.recentlyDeleted` bucket.
    private(set) var deletedTasks: [AgentTask] = []

    /// User-edited model overrides cache, keyed by `"providerID/modelID"`. Mirrors what
    /// `llmKit` was last `setUserOverrides`'d with so the Settings UI can read individual
    /// entries without going through `LLMKitManager`'s private state. Writes flow through
    /// `setUserModelOverride(...)` which also persists and re-pushes to `llmKit`.
    private(set) var userModelOverrides: [String: ModelMetadataOverride] = [:]

    /// Set when a load/decode operation fails during startup; drives the error alert.
    var startupError: String?
    /// ID of the session whose window is currently key (frontmost). Updated by
    /// `SessionScene` via `NSWindow.didBecomeKeyNotification`. Used by commands like
    /// Cmd+N and Close Session so they target the focused tab, not an arbitrary one.
    var focusedSessionID: UUID?
    /// Signal from the File menu → the focused `SessionScene` that it should show a
    /// rename sheet for this session ID. Cleared by the scene after handling. Only the
    /// scene whose session matches acts on it, so the menu command correctly routes to
    /// the frontmost tab.
    var renameSessionRequestID: UUID?
    /// Signal from the File menu to the focused `MainView` that it should show the
    /// manual task creation sheet for this session ID.
    var createTaskRequestID: UUID?
    /// Set to true after `loadPersistedState()` finishes.
    var hasLoadedPersistedState = false
    /// Whether the launch splash should currently render. Starts true at process start and
    /// is flipped to false once the first window's splash animation completes. Multiple
    /// windows opening at launch share this flag so they dismiss together.
    var launchSplashVisible: Bool = true
    /// Tracks the in-flight `loadPersistedState()` call so concurrent windows that all
    /// trigger bootstrap on first appear share a single run rather than double-executing
    /// the migrations and model refresh.
    private var loadTask: Task<Void, Never>?
    /// Tracks the in-flight `ensureSemanticEngine()` call so concurrent session starts
    /// share a single MLX model load. Without this, two tabs auto-starting on launch
    /// would each allocate a fresh `SemanticSearchEngine` and prepare independently.
    private var semanticEngineTask: Task<SemanticSearchEngine, Error>?
    /// Tracks the in-flight `ensureMemoryStore()` call so concurrent session starts
    /// share a single `MemoryStore` instance — critical for the "shared corpus"
    /// invariant. Without this, each tab would get a different store, writes would
    /// diverge, and `memories.json` persistence would be last-writer-wins.
    private var memoryStoreTask: Task<MemoryStore, Error>?

    /// Shared global store of archived + recently-deleted tasks — one instance per process,
    /// injected into every session's runtime. Created lazily in `ensureInactiveTaskStore()`,
    /// which also runs the one-time per-session → global migration.
    private(set) var inactiveTaskStore: InactiveTaskStore?
    /// Tracks the in-flight `ensureInactiveTaskStore()` call so concurrent windows share a
    /// single creation (and a single migration run), mirroring `memoryStoreTask`.
    private var inactiveTaskStoreTask: Task<InactiveTaskStore, Error>?
    /// Set false when the global inactive store must NOT be persisted this launch — a corrupt
    /// `inactive_tasks.json` we refuse to overwrite, or a migration save that failed. While false,
    /// mutations aren't written and per-session files aren't stripped, so no archived/deleted task
    /// is ever lost by clobbering a recoverable file or stripping before a durable global save.
    private var inactiveTasksPersistable = true

    /// Tracks the in-flight one-time attachment migration so concurrent windows run it once.
    private var attachmentsMigrationTask: Task<Void, Never>?
    /// True once attachments have been migrated to the global store (or were already).
    private var hasMigratedAttachments = false
    private static let attachmentsMigratedKey = "didMigrateAttachmentsToGlobalStore"

    /// Default agent assignments (from bundled defaults) — used when creating a new session.
    private(set) var defaultAgentAssignments: [AgentRole: UUID] = [:]
    /// Default agent tunings (from bundled defaults) — used when creating a new session.
    private(set) var defaultAgentPollIntervals: [AgentRole: TimeInterval] = [
        .smith: 20, .brown: 25, .securityAgent: 13
    ]
    private(set) var defaultAgentMaxToolCalls: [AgentRole: Int] = [
        .smith: 100, .brown: 100, .securityAgent: 100
    ]
    private(set) var defaultAgentMessageDebounceIntervals: [AgentRole: TimeInterval] = [
        .smith: 1, .brown: 1, .securityAgent: 1
    ]

    /// Base-path persistence manager for shared files (memories, usage, overrides, sessions list).
    let basePersistence: PersistenceManager

    /// Globally-configured MCP servers (shared across all sessions). Loaded from
    /// `mcp_servers.json` at launch; edited via the MCP settings tab. Secret env/arg
    /// values live in `mcpSecretStore` (Keychain), never in this list.
    var mcpServers: [MCPServerConfig] = []

    /// Keychain-backed store for MCP server secrets.
    let mcpSecretStore = MCPSecretStore()

    /// Latest per-server connection status reported by any live session host, keyed by
    /// server ID. Drives the MCP settings tab's status/stderr display. Latest report wins.
    var mcpServerStatuses: [UUID: MCPServerStatus] = [:]

    /// Which Settings tab is selected. Bound by `SettingsView`'s `TabView` and set
    /// programmatically to deep-link (e.g. an MCP failure banner opens the MCP tab).
    var settingsSelectedTab: SettingsTab = .general

    /// One-shot deep-link into the Metadata tab: the provider (and optionally model) the coverage
    /// view should expand, scroll to, and highlight on next appearance. Set by "Resolve…" in the
    /// inspector's missing-metadata popover; cleared by the coverage view after honoring it.
    var metadataFocusProviderID: String?
    var metadataFocusModelID: String?

    /// Live MCP client hosts (one per active session), weakly held so closing a tab
    /// lets its host deallocate. Used to push config changes to running sessions.
    private var mcpHostBoxes: [WeakMCPHostBox] = []

    private final class WeakMCPHostBox {
        weak var host: MCPClientHost?
        init(_ host: MCPClientHost) { self.host = host }
    }

    private let logger = Logger(subsystem: "com.agentsmith", category: "SharedAppState")

    /// Coalescing serial writers for shared files. Replaces the prior per-call
    /// `Task.detached { try await basePersistence.saveX(snapshot) }` pattern,
    /// which let snapshots reach the persistence actor out of order. With these
    /// writers a burst of mutations collapses to at most a couple of writes,
    /// and the latest snapshot always wins.
    private let userModelOverridesWriter: SerialPersistenceWriter<[String: ModelMetadataOverride]>
    private let memoriesWriter: SerialPersistenceWriter<[MemoryEntry]>
    private let taskSummariesWriter: SerialPersistenceWriter<[TaskSummaryEntry]>
    private let mcpServersWriter: SerialPersistenceWriter<[MCPServerConfig]>
    private let inactiveTasksWriter: SerialPersistenceWriter<[AgentTask]>

    init() {
        let pm = PersistenceManager()
        self.basePersistence = pm
        self.usageStore = UsageStore(persistence: pm)
        self.userModelOverridesWriter = SerialPersistenceWriter(label: "userModelOverrides") { snapshot in
            try await pm.saveUserModelOverrides(snapshot)
        }
        self.memoriesWriter = SerialPersistenceWriter(label: "memories") { snapshot in
            try await pm.saveMemories(snapshot)
        }
        self.taskSummariesWriter = SerialPersistenceWriter(label: "taskSummaries") { snapshot in
            try await pm.saveTaskSummaries(snapshot)
        }
        self.mcpServersWriter = SerialPersistenceWriter(label: "mcpServers") { snapshot in
            try await pm.saveMCPServerConfigs(snapshot)
        }
        self.inactiveTasksWriter = SerialPersistenceWriter(label: "inactiveTasks") { snapshot in
            try await pm.saveInactiveTasks(snapshot)
        }
    }

    // MARK: - MCP Servers

    /// Registers a session's MCP host so future config changes are pushed to it.
    /// Prunes any hosts that have since deallocated.
    func registerMCPHost(_ host: MCPClientHost) {
        mcpHostBoxes.removeAll { $0.host == nil }
        mcpHostBoxes.append(WeakMCPHostBox(host))
    }

    /// Records the latest per-server connection status from a session host (latest wins).
    func reportMCPStatuses(_ statuses: [UUID: MCPServerStatus]) {
        for (id, status) in statuses { mcpServerStatuses[id] = status }
    }

    /// Replaces the global MCP server list, persists it, and propagates the change to
    /// every live session host so running servers reconcile (launch/terminate/refilter)
    /// without an app restart.
    func updateMCPServers(_ servers: [MCPServerConfig]) {
        mcpServers = servers
        let writer = mcpServersWriter
        Task { await writer.enqueue(servers) }
        mcpHostBoxes.removeAll { $0.host == nil }
        for box in mcpHostBoxes {
            guard let host = box.host else { continue }
            Task { await host.applyConfigChange(configs: servers) }
        }
    }

    // MARK: - Bootstrap

    /// Loads shared persisted state: nickname, LLM providers/configs/models, bundled defaults,
    /// memories, task summaries, usage records, and model overrides.
    /// Per-session state is loaded by each session's `AppViewModel` separately.
    /// Safe to call from multiple windows concurrently — the first call does the work,
    /// subsequent callers await the same Task.
    func loadPersistedState() async {
        if hasLoadedPersistedState { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadPersistedState()
        }
        loadTask = task
        defer { loadTask = nil }
        await task.value
    }

    private func performLoadPersistedState() async {
        // A capability-eval launch runs headless against its OWN LLMKitManager and never touches
        // this shared state — so don't boot it. Chiefly this skips preparing the semantic-search
        // embedding engine (a multi-second model load, and a first-run model download), which the
        // probe has no use for and which was needlessly delaying `--list-models`.
        if CapabilityEvalRunner.isRequested {
            hasLoadedPersistedState = true
            return
        }

        // Load nickname early so display names and prompts pick it up.
        nickname = UserDefaults.standard.string(forKey: "userNickname") ?? ""
        AgentRole.userNickname = nickname

        // Onboarding gate. Migration: an install that predates the onboarding flow has no key
        // stored — treat a user who already picked a nickname as already onboarded so existing
        // users never see the first-run setup, while a truly fresh install (no nickname) does.
        if UserDefaults.standard.object(forKey: Self.didCompleteOnboardingKey) != nil {
            didCompleteOnboarding = UserDefaults.standard.bool(forKey: Self.didCompleteOnboardingKey)
        } else {
            didCompleteOnboarding = !nickname.isEmpty
        }

        #if DEBUG
        // Debug-only override: pass `--force-onboarding` as a launch argument to force the
        // first-run setup to appear regardless of stored state, without touching the persisted
        // flag or nickname. Nothing is written unless you actually complete or skip the flow,
        // so it's safe to launch against real data just to look.
        if CommandLine.arguments.contains("--force-onboarding") {
            didCompleteOnboarding = false
            logger.notice("DEBUG: --force-onboarding launch argument present — forcing onboarding to show")
        }
        #endif

        // Configure verbose logging for SwiftLLMKit services and providers.
        // Release builds default OFF — verbose logging dumps full request/response
        // bodies (user messages, file contents, tool I/O, possibly pasted secrets)
        // to $TMPDIR. Acceptable for local Debug only until the Settings-controlled
        // logging-levels UI lands. Tracked in RECOMMENDATIONS.md #1.
        LLMRequestLogger.logDirectoryName = "AgentSmith-LLM-Logs"
        #if DEBUG
        llmKit.verboseLogging = true
        ModelFetchService.verboseLogging = true
        ModelMetadataService.verboseLogging = true
        #else
        llmKit.verboseLogging = false
        ModelFetchService.verboseLogging = false
        ModelMetadataService.verboseLogging = false
        #endif

        // Load SwiftLLMKit state (providers, configs, cached models).
        llmKit.load()

        // Load bundled defaults — these provide baseline values for tunings, speech,
        // and (on first install) providers, configurations, and agent assignments.
        do {
            let bundled = try DefaultsLoader.loadBundledDefaults()
            for (role, tuning) in bundled.agentTuning {
                defaultAgentPollIntervals[role] = tuning.pollInterval
                defaultAgentMaxToolCalls[role] = tuning.maxToolCalls
                defaultAgentMessageDebounceIntervals[role] = tuning.messageDebounceInterval
            }
            speechController.applyBundledDefaults(bundled.speech)

            let didBootstrapKey = "didBootstrapBundledDefaults"
            if !UserDefaults.standard.bool(forKey: didBootstrapKey) {
                for provider in bundled.providers {
                    let apiKey = bundled.providerAPIKeys[provider.id] ?? ""
                    try llmKit.addProvider(provider, apiKey: apiKey)
                }
                for config in bundled.modelConfigurations {
                    llmKit.addConfiguration(config)
                }
                defaultAgentAssignments = bundled.agentAssignments
                UserDefaults.standard.set(true, forKey: didBootstrapKey)
            } else {
                defaultAgentAssignments = bundled.agentAssignments
            }
        } catch {
            let msg = "No bundled defaults (using hardcoded): \(error)"
            logger.error("\(msg, privacy: .public)")
            startupError = msg
        }

        // Load user model metadata overrides and inject into LLMKitManager.
        // Keep a local copy (`userModelOverrides`) so the Settings UI can edit
        // individual entries without re-loading from disk every read.
        do {
            let overrides = try await basePersistence.loadUserModelOverrides()
            userModelOverrides = overrides
            if !overrides.isEmpty {
                llmKit.setUserOverrides(overrides)
            }
        } catch {
            logger.error("Failed to load user model overrides: \(error.localizedDescription)")
        }

        do {
            mcpServers = try await basePersistence.loadMCPServerConfigs()
        } catch {
            logger.error("Failed to load MCP server configs: \(error.localizedDescription)")
        }

        // Load persisted usage records into the shared store.
        await usageStore.load()

        // Diagnostic: warn if a cache-supporting provider has 0% hit rate.
        await runUsageHealthCheck()

        // Refresh model catalog. Gated (once/day) by default; --force-fetch-models /
        // --no-fetch-models override, so those flags work on a normal GUI launch too.
        await LaunchFetchPolicy.fromArguments.apply(to: llmKit)
        llmKit.validateConfigurations()

        // Build the LiteLLM pricing snapshot once the catalog is current. Keyed by
        // "providerID/modelID" — same shape `UsageAggregator` expects. Models whose
        // id has an empty providerID or modelID component are skipped so we never
        // emit lookup keys like "providerID/" or "/modelID".
        var pricing: [String: ModelPricing] = [:]
        for model in llmKit.models {
            guard let p = model.pricing else { continue }
            guard !model.id.hasSuffix("/"), !model.id.hasPrefix("/") else { continue }
            pricing[model.id] = p
        }
        pricingSnapshot = pricing

        // Bootstrap the cost rollup actor. `pricingLookup` captures the just-built
        // snapshot — stable for the life of this `CostBoard` instance.
        let board = CostBoard(usageStore: usageStore, pricingLookup: pricingLookup)
        await board.setOnUpdate { [weak self] snapshot in
            await MainActor.run { self?.costBoardSnapshot = snapshot }
        }
        await board.bootstrap()
        costBoard = board

        hasLoadedPersistedState = true
    }

    /// Creates the shared semantic search engine on demand, preparing the MLX model.
    /// Subsequent calls return the existing engine without re-preparation.
    /// Concurrent callers (multiple windows auto-starting at launch) share a single
    /// in-flight `prepare()` run via `semanticEngineTask`.
    func ensureSemanticEngine() async throws -> SemanticSearchEngine {
        if let engine = semanticSearchEngine { return engine }
        if let existing = semanticEngineTask {
            return try await existing.value
        }
        let task = Task { @MainActor [weak self] () -> SemanticSearchEngine in
            guard let self else { throw CancellationError() }
            return try await self.performEnsureSemanticEngine()
        }
        semanticEngineTask = task
        defer { semanticEngineTask = nil }
        return try await task.value
    }

    private func performEnsureSemanticEngine() async throws -> SemanticSearchEngine {
        if let engine = semanticSearchEngine { return engine }
        let engine = SemanticSearchEngine()
        for try await progress in engine.prepare() {
            embeddingPrepareProgress = progress
            let pct = Int(progress.fractionCompleted * 100)
            logger.notice("Embedding model: \(String(describing: progress.phase), privacy: .public) \(pct, privacy: .public)%")
        }
        embeddingPrepareProgress = nil
        semanticSearchEngine = engine
        return engine
    }

    /// Creates the shared memory store on demand (after the semantic engine is ready) and
    /// restores memories + task summaries from disk. Wires persistence + UI refresh once.
    /// Concurrent callers share a single in-flight creation via `memoryStoreTask`, so
    /// every session's runtime ends up with the same `MemoryStore` instance.
    func ensureMemoryStore() async throws -> MemoryStore {
        if let store = memoryStore { return store }
        if let existing = memoryStoreTask {
            return try await existing.value
        }
        let task = Task { @MainActor [weak self] () -> MemoryStore in
            guard let self else { throw CancellationError() }
            return try await self.performEnsureMemoryStore()
        }
        memoryStoreTask = task
        defer { memoryStoreTask = nil }
        return try await task.value
    }

    private func performEnsureMemoryStore() async throws -> MemoryStore {
        if let store = memoryStore { return store }
        let engine = try await ensureSemanticEngine()
        let store = MemoryStore(engine: engine)

        await store.setOnChange { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.persistMemories(memoryStore: store)
                await self.refreshMemories(from: store)
            }
        }

        do {
            let savedMemories = try await basePersistence.loadMemories()
            let savedTaskSummaries = try await basePersistence.loadTaskSummaries()
            if !savedMemories.isEmpty || !savedTaskSummaries.isEmpty {
                await store.restore(memories: savedMemories, taskSummaries: savedTaskSummaries)
                // One-time re-embed if the embedding model/scheme changed (e.g. mean → last-token
                // pooling). The vector dimension is unchanged, so this signature check is the only
                // thing that detects it. Fires the store's onChange, which persists the refreshed
                // corpus. NOTE: blocks first launch after such a change while it re-embeds; a large
                // migration shows a blocking overlay (the await below lets the UI render it first).
                let staleCount = await store.staleEntryCount()
                if staleCount >= SharedAppState.migrationOverlayThreshold {
                    migrationEntryCount = staleCount
                    migrationInProgress = true
                }
                let migrated = await store.reembedStaleEntries()
                // Durably flush the re-embedded vectors before clearing the migration flag, so an
                // interrupted next launch doesn't re-run a migration that already completed (the
                // store's onChange persist is a detached Task whose completion we can't otherwise
                // await; flushMemories drains the writers). Pass `store` explicitly — `memoryStore`
                // isn't assigned until after this block, so the no-arg flush would be a no-op here.
                await flushMemories(store)
                migrationInProgress = false
                if migrated.memories > 0 || migrated.taskSummaries > 0 || migrated.failed > 0 {
                    let failedNote = migrated.failed > 0 ? ", \(migrated.failed) failed (will retry next launch)" : ""
                    logger.notice("Re-embed migration: \(migrated.memories) memories + \(migrated.taskSummaries) task summaries re-embedded\(failedNote) after embedding-model change")
                }
            }
        } catch {
            logger.error("Failed to load memories: \(error.localizedDescription, privacy: .public)")
        }

        memoryStore = store
        // Seed the deleted-task exclusion set if the global inactive store already exists (it's
        // created at session load, usually before this). If it doesn't yet, the inactive store
        // seeds the memory store itself when it's created.
        await syncDeletedTaskIDsToMemory()
        await refreshMemories(from: store)
        return store
    }

    // MARK: - Inactive task store (global archived + deleted)

    /// Returns the shared global store of archived + recently-deleted tasks, creating it (and
    /// running the one-time per-session → global migration) on first call. Concurrent windows
    /// share a single in-flight creation via `inactiveTaskStoreTask`, so every session's runtime
    /// is injected with the same instance.
    func ensureInactiveTaskStore() async throws -> InactiveTaskStore {
        if let store = inactiveTaskStore { return store }
        if let existing = inactiveTaskStoreTask {
            return try await existing.value
        }
        let task = Task { @MainActor [weak self] () -> InactiveTaskStore in
            guard let self else { throw CancellationError() }
            return try await self.performEnsureInactiveTaskStore()
        }
        inactiveTaskStoreTask = task
        defer { inactiveTaskStoreTask = nil }
        return try await task.value
    }

    private func performEnsureInactiveTaskStore() async throws -> InactiveTaskStore {
        if let store = inactiveTaskStore { return store }
        let store = InactiveTaskStore()

        // `loadInactiveTasks()` returns nil only when `inactive_tasks.json` is absent → the
        // one-time per-session → global migration hasn't run. It *throws* when the file exists
        // but can't be decoded (corrupt): in that case we must NOT migrate, because migration
        // would overwrite the (recoverable) file with a fresh union built from session files that
        // a prior migration already stripped — i.e. it would wipe all archived/deleted tasks. So
        // we leave the file untouched and start empty for this launch.
        do {
            if let loaded = try await basePersistence.loadInactiveTasks() {
                await store.restore(loaded)
            } else {
                // File absent → run migration. Persist the union and ONLY strip the per-session
                // files once that save has durably succeeded — otherwise a failed save followed by
                // a strip would lose the inactive tasks on the next launch. On save failure we keep
                // the per-session copies (the AppViewModel load split is the backstop) and retry the
                // whole migration next launch. Either way the tasks are live in memory this launch.
                let migrated = await collectInactiveFromSessions()
                await store.restore(migrated)
                do {
                    try await basePersistence.saveInactiveTasks(migrated)
                    await stripInactiveFromSessionFiles()
                    if !migrated.isEmpty {
                        logger.notice("Migrated \(migrated.count) archived/deleted tasks from per-session files into the global store")
                    }
                } catch {
                    // Couldn't durably persist the global file — disable persistence so the
                    // per-session copies are kept (not stripped) and the corrupt/failed file isn't
                    // overwritten. Migration retries next launch. Tasks stay live in memory now.
                    inactiveTasksPersistable = false
                    logger.error("Failed to persist migrated inactive_tasks.json (\(error.localizedDescription, privacy: .public)) — keeping per-session copies; migration retries next launch")
                }
            }
        } catch {
            // The file exists but couldn't be decoded. Move it aside (never deleted — preserved for
            // manual recovery) and start a fresh, healthy store, so the app keeps working and a task
            // archived this session still persists. If it can't be moved aside, disable persistence
            // so we never overwrite the recoverable-but-corrupt file.
            do {
                let quarantined = try await basePersistence.quarantineCorruptInactiveTasksFile()
                logger.error("inactive_tasks.json was unreadable (\(error.localizedDescription, privacy: .public)); moved aside to \(quarantined?.lastPathComponent ?? "n/a", privacy: .public) and started a fresh archive")
            } catch {
                inactiveTasksPersistable = false
                logger.error("inactive_tasks.json unreadable and could not be quarantined (\(error.localizedDescription, privacy: .public)) — not overwriting it; archived/deleted tasks unavailable this launch")
            }
        }

        // Wire persistence + UI mirror AFTER the initial restore so loading doesn't trigger a
        // redundant write. The writer enqueue is gated on `inactiveTasksPersistable` so a corrupt
        // or unwritable file is never clobbered by an in-session mutation.
        let writer = inactiveTasksWriter
        await store.setOnChange { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let snapshot = await store.snapshot()
                self.refreshInactiveTaskBuckets(from: snapshot)
                await self.syncDeletedTaskIDsToMemory(snapshot: snapshot)
                if self.inactiveTasksPersistable {
                    await writer.enqueue(snapshot)
                }
            }
        }

        inactiveTaskStore = store
        let snapshot = await store.snapshot()
        refreshInactiveTaskBuckets(from: snapshot)
        await syncDeletedTaskIDsToMemory(snapshot: snapshot)
        return store
    }

    /// Splits the inactive snapshot into the two published, sorted buckets the sidebars observe.
    private func refreshInactiveTaskBuckets(from snapshot: [AgentTask]) {
        archivedTasks = snapshot
            .filter { $0.disposition == .archived }
            .sorted { $0.createdAt > $1.createdAt }
        deletedTasks = snapshot
            .filter { $0.disposition == .recentlyDeleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Pushes the current recently-deleted task IDs into the memory store so semantic search
    /// excludes deleted tasks. No-op until the memory store exists. Pass a snapshot to avoid
    /// re-reading the inactive actor when one is already in hand.
    private func syncDeletedTaskIDsToMemory(snapshot: [AgentTask]? = nil) async {
        guard let mem = memoryStore else { return }
        let deletedIDs: Set<UUID>
        if let snapshot {
            deletedIDs = Set(snapshot.lazy.filter { $0.disposition == .recentlyDeleted }.map(\.id))
        } else if let store = inactiveTaskStore {
            deletedIDs = await store.deletedIDs()
        } else {
            return
        }
        await mem.setExcludedTaskSummaryIDs(deletedIDs)
    }

    /// Reads every session's `tasks.json` and returns the union of their non-active tasks, keeping
    /// the newer copy on id collisions. Read-only — does not modify any session file.
    private func collectInactiveFromSessions() async -> [AgentTask] {
        let sessions = (try? await basePersistence.loadSessionList()) ?? []
        var union: [UUID: AgentTask] = [:]
        for session in sessions {
            let pm = PersistenceManager(sessionID: session.id)
            let tasks: [AgentTask]
            do {
                tasks = try await pm.loadTasks()
            } catch {
                logger.error("Inactive-task migration: could not read session \(session.id.uuidString, privacy: .public)'s tasks (\(error.localizedDescription, privacy: .public)) — skipping it")
                continue
            }
            for task in tasks where task.disposition != .active {
                if let existing = union[task.id], existing.updatedAt >= task.updatedAt { continue }
                union[task.id] = task
            }
        }
        return Array(union.values)
    }

    /// Rewrites every session's `tasks.json` to contain only its active tasks. Run only after the
    /// global inactive file is durably saved, so inactive tasks are never removed before being
    /// preserved globally.
    private func stripInactiveFromSessionFiles() async {
        let sessions = (try? await basePersistence.loadSessionList()) ?? []
        for session in sessions {
            let pm = PersistenceManager(sessionID: session.id)
            let tasks: [AgentTask]
            do {
                tasks = try await pm.loadTasks()
            } catch {
                logger.error("Inactive-task strip: could not read session \(session.id.uuidString, privacy: .public)'s tasks (\(error.localizedDescription, privacy: .public)) — skipping it")
                continue
            }
            let active = tasks.filter { $0.disposition == .active }
            if active.count != tasks.count {
                do {
                    try await pm.saveTasks(active)
                } catch {
                    // Non-fatal: the global file was already durably saved before this strip runs, so
                    // nothing is lost — the stray inactive copies just get re-migrated next launch.
                    logger.error("Inactive-task strip: could not rewrite session \(session.id.uuidString, privacy: .public)'s tasks (\(error.localizedDescription, privacy: .public)) — will re-migrate next launch")
                }
            }
        }
    }

    /// Runs the one-time migration of per-session attachment files into the global attachments
    /// store. Deduped so concurrent windows trigger it once; guarded by a UserDefaults marker set
    /// only after a clean run, so a partial failure retries next launch. Idempotent regardless.
    func ensureAttachmentsMigrated() async {
        if hasMigratedAttachments { return }
        if let existing = attachmentsMigrationTask { await existing.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if UserDefaults.standard.bool(forKey: SharedAppState.attachmentsMigratedKey) {
                self.hasMigratedAttachments = true
                return
            }
            do {
                let result = try await self.basePersistence.migrateSessionAttachmentsToGlobalStore()
                if result.failed == 0 {
                    UserDefaults.standard.set(true, forKey: SharedAppState.attachmentsMigratedKey)
                    self.hasMigratedAttachments = true
                }
                if result.moved > 0 {
                    let note = result.failed > 0 ? "; \(result.failed) failed (will retry next launch)" : ""
                    logger.notice("Migrated \(result.moved) attachment file(s) to the global store\(note)")
                }
            } catch {
                logger.error("Attachment migration failed (\(error.localizedDescription, privacy: .public)) — will retry next launch")
            }
        }
        attachmentsMigrationTask = task
        await task.value
        attachmentsMigrationTask = nil
    }

    /// Permanently removes a task's summary from the semantic corpus — called when a task is
    /// permanently deleted, so it never resurfaces in search. Recently-deleted tasks only *hide*
    /// their summary (via the excluded-ID set); permanent delete erases it.
    func purgeTaskSummary(id: UUID) async {
        await memoryStore?.removeTaskSummary(id: id)
    }

    /// Flushes the global inactive-task store to disk on app termination. No-op when persistence is
    /// disabled (corrupt/unwritable file) so termination never overwrites a recoverable file.
    public func flushInactiveTasks() async {
        guard inactiveTasksPersistable, let store = inactiveTaskStore else { return }
        let snapshot = await store.snapshot()
        await inactiveTasksWriter.enqueue(snapshot)
        await inactiveTasksWriter.flush()
    }

    /// Durably writes the global inactive store to disk right now (bypassing the coalescing writer),
    /// returning whether the write succeeded. Callers use this to guarantee an archived/deleted task
    /// is durably in the global file BEFORE they strip it from a per-session file — so a crash can
    /// never leave a task removed from the session file but absent from the global file. Returns
    /// false (without writing) when persistence is disabled, so callers keep the per-session copies.
    func persistInactiveTasksNow() async -> Bool {
        guard inactiveTasksPersistable, let store = inactiveTaskStore else { return false }
        let snapshot = await store.snapshot()
        do {
            try await basePersistence.saveInactiveTasks(snapshot)
            return true
        } catch {
            logger.error("Failed to durably persist inactive_tasks.json: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Nickname

    func persistNickname() {
        UserDefaults.standard.set(nickname, forKey: "userNickname")
        AgentRole.userNickname = nickname
    }

    // MARK: - Onboarding

    fileprivate static let didCompleteOnboardingKey = "didCompleteOnboarding"

    /// Marks first-run setup as done and persists it, so onboarding never shows again.
    func markOnboardingComplete() {
        didCompleteOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.didCompleteOnboardingKey)
    }

    // MARK: - Model Configuration (shared catalog)

    /// Deletes a model configuration from the shared catalog. Callers should iterate the
    /// session list (via `SessionManager`) and clear per-session assignments that point at
    /// the deleted ID — `SessionManager.deleteConfiguration(id:)` does both.
    func deleteConfiguration(id: UUID) {
        llmKit.deleteConfiguration(id: id)
    }

    /// Updates a model configuration in place. Supports undo through the supplied UndoManager.
    func updateAgentConfig(_ config: ModelConfiguration, undoManager: UndoManager? = nil) {
        let previous = llmKit.configurations.first { $0.id == config.id }
        llmKit.updateConfiguration(config)
        // Push the edited config to any running session that uses it (debounced on the VM side), so a
        // model/provider change reaches the live runtime instead of stranding it on the prior provider.
        if previous != config { notifyModelAssignmentsChanged() }
        guard let previous, let undoManager, previous != config else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.updateAgentConfig(previous, undoManager: undoManager)
        }
        undoManager.setActionName("Change \(config.name)")
    }

    /// Updates a single per-(providerID, modelID) user override entry. Pushes the merged
    /// dictionary to `llmKit` so it takes effect immediately, then persists to disk so
    /// the change survives restart. Pass `nil` to remove the entry entirely (revert to
    /// bundled defaults). The `llmKit` model catalog is re-validated implicitly on the
    /// next refresh cycle; live `OpenAICompatibleProvider` / `OllamaProvider` instances
    /// already constructed for the prior flag state will keep using their snapshot until
    /// rebuilt at next agent spawn.
    func setUserModelOverride(
        providerID: String,
        modelID: String,
        override: ModelMetadataOverride?
    ) {
        let key = "\(providerID)/\(modelID)"
        if let override, !overrideIsEmpty(override) {
            userModelOverrides[key] = override
        } else {
            userModelOverrides.removeValue(forKey: key)
        }
        llmKit.setUserOverrides(userModelOverrides)
        let snapshot = userModelOverrides
        let writer = userModelOverridesWriter
        Task { await writer.enqueue(snapshot) }
    }

    /// Records a model's true maximum output-token limit — learned at runtime when a backend
    /// rejects a request whose output cap exceeds what the model allows — as a catalog
    /// override. Merges into any existing override for the model so unrelated fields (e.g.
    /// behavior flags) are preserved. Once stored, `LLMKitManager.makeProvider` clamps every
    /// future provider for this model to the limit and the Settings UI shows the corrected
    /// value. NOTE: this is the model's *last reported* ceiling — if the provider later raises
    /// it, clear the override (or bump it) to re-probe; we can't auto-detect an increase.
    func learnModelOutputLimit(providerID: String, modelID: String, limit: Int) {
        let key = "\(providerID)/\(modelID)"
        var override = userModelOverrides[key] ?? ModelMetadataOverride()
        guard override.maxOutputTokens != limit else { return }
        override.maxOutputTokens = limit
        setUserModelOverride(providerID: providerID, modelID: modelID, override: override)
    }

    /// True when the override carries no information, meaning the entry should be removed
    /// rather than stored — keeps the on-disk JSON tidy and means "revert to bundled" is a
    /// single-call operation. Compares against blank values instead of enumerating fields:
    /// per-field enumeration silently judged overrides "empty" whenever a newer field
    /// (hidden, isAvailable, isAccessDenied, capabilities.toolResultRoundTrip) was the only
    /// one set, discarding the user's edit on save.
    private func overrideIsEmpty(_ override: ModelMetadataOverride) -> Bool {
        var normalized = override
        if normalized.capabilities == ModelCapabilitiesOverride() { normalized.capabilities = nil }
        if let flags = normalized.behaviorFlags, flags.isEmpty { normalized.behaviorFlags = nil }
        return normalized == ModelMetadataOverride()
    }

    // MARK: - Memory

    /// Refreshes `storedMemories` and `storedTaskSummaries` from the shared memory store.
    func refreshMemories() async {
        guard let store = memoryStore else { return }
        await refreshMemories(from: store)
    }

    private func refreshMemories(from store: MemoryStore) async {
        storedMemories = await store.allMemories()
        storedTaskSummaries = await store.allTaskSummaries()
    }

    /// Flushes the shared memory store to disk on app termination. First persists any pending
    /// retrieval-stat bumps (which are deliberately decoupled from the corpus-change `onChange`
    /// path to avoid re-serializing the full embedding corpus on every read), then enqueues a
    /// final snapshot and drains both memory writers so no buffered writes are lost on quit.
    public func flushMemories() async {
        guard let store = memoryStore else { return }
        await flushMemories(store)
    }

    /// Flushes a specific store's pending writes and drains both writers. Takes the store explicitly
    /// so it also works during initial store creation — before `memoryStore` is assigned — e.g. the
    /// re-embed migration flushes the freshly-built store before it's installed.
    private func flushMemories(_ store: MemoryStore) async {
        // Persist any read-stat bumps that were withheld from the hot path. This fires
        // onChange?(), routing through the normal persist path (which enqueues a snapshot).
        await store.persistRetrievalStatsIfNeeded()
        // Enqueue a final authoritative snapshot inline (awaited) so it is ordered before the
        // flush below; the onChange-driven persist uses a detached Task whose completion we
        // cannot await here.
        let memories = await store.allMemories()
        let taskSummaries = await store.allTaskSummaries()
        await memoriesWriter.enqueue(memories)
        await taskSummariesWriter.enqueue(taskSummaries)
        await memoriesWriter.flush()
        await taskSummariesWriter.flush()
    }

    private func persistMemories(memoryStore: MemoryStore) {
        let memoriesWriter = memoriesWriter
        let summariesWriter = taskSummariesWriter
        Task {
            let memories = await memoryStore.allMemories()
            let taskSummaries = await memoryStore.allTaskSummaries()
            await memoriesWriter.enqueue(memories)
            await summariesWriter.enqueue(taskSummaries)
        }
    }

    /// Deletes a memory by ID.
    func deleteMemory(id: UUID) async {
        guard let store = memoryStore else { return }
        await store.delete(id: id)
    }

    /// Errors thrown by the memory editor's search helpers, surfaced to the UI.
    enum MemorySearchUIError: LocalizedError {
        case storeUnavailable
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .storeUnavailable:
                return "Memory store is unavailable. Start a session from the toolbar to load and search memories."
            case .underlying(let error):
                return "Search failed: \(error.localizedDescription)"
            }
        }
    }

    func searchMemories(query: String, limit: Int = 20) async throws -> [MemorySearchResult] {
        guard let store = memoryStore else { throw MemorySearchUIError.storeUnavailable }
        do {
            return try await store.searchMemories(query: query, limit: limit, threshold: 0.0)
        } catch {
            logger.error("Memory search failed: \(error.localizedDescription, privacy: .public)")
            throw MemorySearchUIError.underlying(error)
        }
    }

    func searchTaskSummaries(query: String, limit: Int = 20) async throws -> [TaskSummarySearchResult] {
        guard let store = memoryStore else { throw MemorySearchUIError.storeUnavailable }
        do {
            return try await store.searchTaskSummaries(query: query, limit: limit, threshold: 0.0)
        } catch {
            logger.error("Task summary search failed: \(error.localizedDescription, privacy: .public)")
            throw MemorySearchUIError.underlying(error)
        }
    }

    /// Updates a memory's content and/or tags. Marked as a `.user` edit so the entry's
    /// `lastUpdatedBy` reflects who made the change.
    func updateMemory(id: UUID, content: String? = nil, tags: [String]? = nil) async throws {
        guard let store = memoryStore else { return }
        try await store.update(id: id, content: content, tags: tags, updatedBy: .user)
    }

    /// Saves a brand-new memory authored by the user from the Memory Browser. Source is
    /// always `.user`; the memory store auto-embeds and triggers the on-change refresh.
    @discardableResult
    func saveMemory(content: String, tags: [String]) async throws -> MemoryEntry? {
        guard let store = memoryStore else { return nil }
        return try await store.save(content: content, source: .user, tags: tags)
    }

    private func runUsageHealthCheck() async {
        let allRecords = await usageStore.allRecords()
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let recent = allRecords.filter { $0.timestamp >= cutoff }
        guard recent.count >= 20 else { return }

        let cacheCapableProviders: Set<String> = [
            "anthropic", "gemini",
            "openAICompatible", "lmStudio", "mistral", "huggingFace",
            "xAI", "zAI", "metaModel", "alibabaCloud", "openRouter"
        ]

        var byProvider: [String: (calls: Int, totalInput: Int, totalCacheRead: Int, withRawUsage: Int)] = [:]
        for record in recent where cacheCapableProviders.contains(record.providerType) {
            guard record.inputTokens >= 5000 else { continue }
            var entry = byProvider[record.providerType] ?? (0, 0, 0, 0)
            entry.calls += 1
            entry.totalInput += record.inputTokens
            entry.totalCacheRead += record.cacheReadTokens
            if record.rawUsage != nil { entry.withRawUsage += 1 }
            byProvider[record.providerType] = entry
        }

        for (provider, stats) in byProvider where stats.calls >= 20 {
            let hitRate = Double(stats.totalCacheRead) / Double(stats.totalInput)
            let rawUsageCoverage = Double(stats.withRawUsage) / Double(stats.calls)
            if hitRate == 0 {
                logger.warning("Usage health: provider \(provider) shows 0% cache hit rate across \(stats.calls) recent large calls (\(stats.totalInput) input tokens). Possible parser regression — verify the provider layer still extracts cache token fields. rawUsage coverage: \(Int(rawUsageCoverage * 100))%")
            } else {
                logger.info("Usage health: provider \(provider) cache hit rate \(String(format: "%.1f%%", hitRate * 100)) across \(stats.calls) recent calls. rawUsage coverage: \(Int(rawUsageCoverage * 100))%")
            }
        }
    }
}
