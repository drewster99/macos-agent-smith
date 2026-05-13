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
@Observable
@MainActor
final class SharedAppState {
    /// The user's preferred nickname, shown in the UI and injected into system prompts.
    var nickname: String = ""
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
    /// "Smith agent <id> is online", "Jones security evaluator online") are rendered. Off
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

    /// Reads an Int from UserDefaults, defaulting when the key has never been set.
    /// Used by the attachment-cap settings so a "first time launch" picks up the
    /// documented default rather than zero.
    private static func intDefault(key: String, default fallback: Int) -> Int {
        if UserDefaults.standard.object(forKey: key) == nil { return fallback }
        return UserDefaults.standard.integer(forKey: key)
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

    /// Default agent assignments (from bundled defaults) — used when creating a new session.
    private(set) var defaultAgentAssignments: [AgentRole: UUID] = [:]
    /// Default agent tunings (from bundled defaults) — used when creating a new session.
    private(set) var defaultAgentPollIntervals: [AgentRole: TimeInterval] = [
        .smith: 20, .brown: 25, .jones: 13
    ]
    private(set) var defaultAgentMaxToolCalls: [AgentRole: Int] = [
        .smith: 100, .brown: 100, .jones: 100
    ]
    private(set) var defaultAgentMessageDebounceIntervals: [AgentRole: TimeInterval] = [
        .smith: 1, .brown: 1, .jones: 1
    ]

    /// Base-path persistence manager for shared files (memories, usage, overrides, sessions list).
    let basePersistence: PersistenceManager

    private let logger = Logger(subsystem: "com.agentsmith", category: "SharedAppState")

    /// Coalescing serial writers for shared files. Replaces the prior per-call
    /// `Task.detached { try await basePersistence.saveX(snapshot) }` pattern,
    /// which let snapshots reach the persistence actor out of order. With these
    /// writers a burst of mutations collapses to at most a couple of writes,
    /// and the latest snapshot always wins.
    private let userModelOverridesWriter: SerialPersistenceWriter<[String: ModelMetadataOverride]>
    private let memoriesWriter: SerialPersistenceWriter<[MemoryEntry]>
    private let taskSummariesWriter: SerialPersistenceWriter<[TaskSummaryEntry]>

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
        // Load nickname early so display names and prompts pick it up.
        nickname = UserDefaults.standard.string(forKey: "userNickname") ?? ""
        AgentRole.userNickname = nickname

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

        // Load persisted usage records into the shared store.
        await usageStore.load()

        // Diagnostic: warn if a cache-supporting provider has 0% hit rate.
        await runUsageHealthCheck()

        // Refresh model catalog (YYYYMMDD-gated).
        await llmKit.refreshIfNeeded()
        llmKit.validateConfigurations()

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
            }
        } catch {
            logger.error("Failed to load memories: \(error.localizedDescription, privacy: .public)")
        }

        memoryStore = store
        await refreshMemories(from: store)
        return store
    }

    // MARK: - Nickname

    func persistNickname() {
        UserDefaults.standard.set(nickname, forKey: "userNickname")
        AgentRole.userNickname = nickname
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

    /// Returns true when every field on the override is at its no-op value. Used by
    /// `setUserModelOverride` to remove rather than persist an empty patch — keeps the
    /// on-disk JSON tidy and means "revert to bundled" is a single-call operation.
    private func overrideIsEmpty(_ override: ModelMetadataOverride) -> Bool {
        if override.displayName != nil { return false }
        if override.maxInputTokens != nil { return false }
        if override.maxOutputTokens != nil { return false }
        if override.pricing != nil { return false }
        if override.supportsChatCompletions != nil { return false }
        if let cap = override.capabilities, capabilitiesOverrideHasContent(cap) { return false }
        if let flags = override.behaviorFlags, !flags.isEmpty { return false }
        return true
    }

    private func capabilitiesOverrideHasContent(_ cap: ModelCapabilitiesOverride) -> Bool {
        cap.toolUse != nil || cap.vision != nil || cap.reasoning != nil
            || cap.codeExecution != nil || cap.promptCaching != nil || cap.computerUse != nil
            || cap.audioInput != nil || cap.audioOutput != nil || cap.videoInput != nil
            || cap.responseSchema != nil || cap.parallelToolCalls != nil || cap.pdfInput != nil
            || cap.webSearch != nil || cap.systemMessages != nil || cap.assistantPrefill != nil
            || cap.toolChoice != nil
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
            "xAI", "zAI", "metaLlama", "alibabaCloud", "openRouter"
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
