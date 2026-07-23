import Foundation
import os
import SwiftLLMKit

private let logger = Logger(subsystem: "com.agentsmith", category: "Persistence")

/// Saves and loads channel logs, task lists, attachments, memories, summaries, and usage data.
///
/// There are two flavors:
/// * `init()` — base manager. Used for shared resources that are never session-scoped
///   (memories, task summaries, usage records, model overrides, session list).
/// * `init(sessionID:)` — session-scoped manager. Channel / task / state methods read and write
///   `AgentSmith/sessions/<id>/…`. Shared methods (memories, summaries, usage, model overrides,
///   session list, inactive tasks, AND attachments) always use the root `AgentSmith/` dir
///   regardless of which flavor was used. Attachments are global so an archived/deleted task (which
///   is global) resolves its files from any session's window.
///
/// The `preconditionFailure` in `appSupportURL()` guards against truly exceptional platform
/// breakage (e.g., a sandboxing misconfiguration) where no recovery is possible.
public actor PersistenceManager {
    private let baseDirectory: URL

    /// The user-owned evaluator registry directory (`AppSupport/AgentSmith/evaluators/`).
    /// Global, not per-session — definitions are shared configuration like memories.
    public nonisolated var evaluatorsDirectory: URL {
        baseDirectory.appendingPathComponent("evaluators", isDirectory: true)
    }
    private let sessionDirectory: URL

    /// The session directory, used by the runtime as the root for per-task persistent evidence
    /// directories (`<sessionDirectory>/tasks/<taskID>/evidence`). For the root-flavored manager
    /// this is the base `AgentSmith/` dir; task evidence is only meaningful under a session.
    public nonisolated var sessionWorkspaceDirectory: URL { sessionDirectory }
    private let attachmentsDirectory: URL

    /// Real-data init. Resolves to `~/Library/Application Support/AgentSmith/` —
    /// the user's actual data path. **Tests MUST NOT use this init**; use
    /// `init(testingRoot:)` instead. Any test that wires this manager into a
    /// `UsageStore` and calls `append(...)` will overwrite the user's real
    /// `usage_records.json` when `scheduleFlush`'s timer fires. A source-level
    /// guard in `PersistenceManagerTestUsageGuardTests` catches such regressions.
    public init() {
        let appSupport = Self.appSupportURL()
        baseDirectory = appSupport.appendingPathComponent("AgentSmith", isDirectory: true)
        sessionDirectory = baseDirectory
        attachmentsDirectory = baseDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    /// Real-data session-scoped init. Same data-loss caveat as `init()` — see
    /// that doc comment. Tests targeting per-session data should use
    /// `init(testingRoot:)` and operate inside that sandbox.
    public init(sessionID: UUID) {
        let appSupport = Self.appSupportURL()
        baseDirectory = appSupport.appendingPathComponent("AgentSmith", isDirectory: true)
        sessionDirectory = baseDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        // Attachments are GLOBAL (shared across sessions), like archived/deleted tasks — files are
        // UUID-named so pooling them can't collide. A task that's archived in one session and
        // viewed/restored in another must still resolve its attachments. (Was session-scoped; see
        // `migrateSessionAttachmentsToGlobalStore`.)
        attachmentsDirectory = baseDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    /// Test-only init that routes all reads/writes under a caller-supplied root URL,
    /// bypassing Application Support entirely. Exists specifically because the
    /// default `init()` resolves to `~/Library/Application Support/AgentSmith/`, and
    /// any test that constructs a `UsageStore` against that path and calls
    /// `append(...)` will eventually overwrite the user's real `usage_records.json`
    /// when `scheduleFlush`'s 5-second timer fires (the in-memory `records` array
    /// is whatever the test loaded into it, NOT what's on disk). Tests MUST use
    /// this init to point at a per-test temp directory.
    public init(testingRoot: URL) {
        baseDirectory = testingRoot.appendingPathComponent("AgentSmith", isDirectory: true)
        sessionDirectory = baseDirectory
        attachmentsDirectory = baseDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    private static func appSupportURL() -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure(
                "Application Support directory unavailable — "
                + "this directory is guaranteed on macOS; check sandbox entitlements"
            )
        }
        return appSupport
    }

    /// Ensures storage directories exist (both base and session, plus the session's attachments/).
    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: attachmentsDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Session List (shared)

    /// Loads the persistent session list. Returns [] if `sessions.json` is missing.
    public func loadSessionList() throws -> [Session] {
        let url = baseDirectory.appendingPathComponent("sessions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Session].self, from: data)
    }

    /// Saves the session list to disk.
    public func saveSessionList(_ sessions: [Session]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(sessions)
        let url = baseDirectory.appendingPathComponent("sessions.json")
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Inactive tasks (shared)

    /// Loads the global archived + recently-deleted task list. Returns nil when the file is
    /// absent — the caller uses that to detect "the one-time per-session → global migration
    /// hasn't run yet" (distinct from an empty-but-migrated `[]`).
    public func loadInactiveTasks() async throws -> [AgentTask]? {
        let url = baseDirectory.appendingPathComponent("inactive_tasks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try await FileIO.readJSON([AgentTask].self, from: url)
    }

    /// Saves the global archived + recently-deleted task list. Writing this file is what marks
    /// the one-time migration as complete, so callers must persist it before stripping inactive
    /// tasks from the per-session files.
    public func saveInactiveTasks(_ tasks: [AgentTask]) async throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory.appendingPathComponent("inactive_tasks.json")
        try await FileIO.writeJSON(tasks, to: url)
    }

    /// Moves an unreadable `inactive_tasks.json` aside to a timestamped `.corrupt-…` name so a fresh
    /// one can be written without destroying the original — the user can attempt manual recovery.
    /// Returns the destination URL, or nil if there was no file to move. Throws on filesystem failure
    /// (the caller then refuses to overwrite the original). Never deletes data.
    public func quarantineCorruptInactiveTasksFile() throws -> URL? {
        let url = baseDirectory.appendingPathComponent("inactive_tasks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = baseDirectory.appendingPathComponent("inactive_tasks.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    /// Deletes this session's subdirectory (channel_log, tasks, attachments, state).
    /// No-op if the directory doesn't exist. Only valid on a session-scoped manager.
    ///
    /// As of 2026-04 this method has NO callers in the app — the previous "Close Session…"
    /// menu was removed because window-close should never mutate session state. Kept in the
    /// API surface for a future "Manage Sessions" sheet that will bring deletion back as
    /// an explicit action with its own confirmation. See ROADMAP.md.
    public func deleteSessionData() throws {
        guard FileManager.default.fileExists(atPath: sessionDirectory.path) else { return }
        try FileManager.default.removeItem(at: sessionDirectory)
    }

    // MARK: - Session State (per-session)

    /// Saves per-session settings (assignments, tunings, tool flags, auto-run).
    public func saveSessionState(_ state: SessionState) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(state)
        let url = sessionDirectory.appendingPathComponent("state.json")
        try data.write(to: url, options: .atomic)
    }

    /// Loads per-session settings. Returns nil if the file doesn't exist yet.
    public func loadSessionState() throws -> SessionState? {
        let url = sessionDirectory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionState.self, from: data)
    }

    // MARK: - Channel Log (per-session)

    public func saveChannelLog(_ messages: [ChannelMessage]) async throws {
        try ensureDirectories()
        let url = sessionDirectory.appendingPathComponent("channel_log.json")
        try await FileIO.writeJSON(messages, to: url)
    }

    public func loadChannelLog() async throws -> [ChannelMessage] {
        let url = sessionDirectory.appendingPathComponent("channel_log.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try await FileIO.readJSON([ChannelMessage].self, from: url)
    }

    // MARK: - Channel Log — append-only JSONL (per-session)
    //
    // The transcript is stored as newline-delimited JSON (one compact `ChannelMessage` per
    // line) so live messages append in O(1) instead of rewriting the whole file on every save,
    // and the in-memory model only has to hold a bounded tail. The legacy `channel_log.json`
    // (a single JSON array) is migrated to `.jsonl` once and then LEFT IN PLACE as a backup —
    // it is never deleted or overwritten by this path. Splitting on 0x0A is safe because
    // compact JSON never emits a raw newline byte outside a string and always escapes newlines
    // inside strings as `\n`; multi-byte UTF-8 never contains a 0x0A byte.

    private var channelLogJSONLURL: URL {
        sessionDirectory.appendingPathComponent("channel_log.jsonl")
    }
    private var channelLogLegacyURL: URL {
        sessionDirectory.appendingPathComponent("channel_log.json")
    }

    /// Encodes messages as newline-delimited compact JSON (a trailing newline after each).
    private func encodeJSONL(_ messages: [ChannelMessage]) throws -> Data {
        let encoder = JSONEncoder()
        var blob = Data()
        for message in messages {
            blob.append(try encoder.encode(message))
            blob.append(0x0A)
        }
        return blob
    }

    /// Decodes a JSONL blob, tolerating blank lines and — critically — an undecodable line.
    /// A crash or `kill -9` mid-append can leave a partial final record; rather than let one
    /// truncated line fail the whole load (poisoning the transcript), such lines are skipped and
    /// counted. When the entire file is read the returned total is the decoded count; for a tail
    /// read older lines aren't inspected, so the raw line count is used (a stray partial record
    /// then only slightly over-counts a large history, affecting just the restore-button label).
    private func decodeJSONL(_ data: Data, limit: Int? = nil) -> (messages: [ChannelMessage], totalCount: Int) {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let lineCount = lines.count
        let decodingAll = (limit == nil) || (limit! >= lineCount)
        let slice = decodingAll ? lines[...] : lines.suffix(limit!)
        let decoder = JSONDecoder()
        var messages: [ChannelMessage] = []
        messages.reserveCapacity(slice.count)
        var skipped = 0
        for line in slice {
            if let message = try? decoder.decode(ChannelMessage.self, from: Data(line)) {
                messages.append(message)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            logger.error("channel_log.jsonl: skipped \(skipped, privacy: .public) undecodable line(s) — likely a partial record from an unclean shutdown")
        }
        return (messages, decodingAll ? messages.count : lineCount)
    }

    /// Seeds `channel_log.jsonl` from a legacy `channel_log.json` array on first use, stripping
    /// the stale `fileWrite*` diff metadata that used to bloat the log. The legacy file is
    /// preserved as a backup. Written via a temp file + atomic rename so a crash mid-migration
    /// can never leave a truncated `.jsonl`. No-op once the `.jsonl` exists.
    private func migrateLegacyChannelLogIfNeeded() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: channelLogJSONLURL.path) else { return }
        guard fm.fileExists(atPath: channelLogLegacyURL.path) else { return }
        try ensureDirectories()
        let data = try Data(contentsOf: channelLogLegacyURL)
        var legacy = try JSONDecoder().decode([ChannelMessage].self, from: data)
        for i in legacy.indices {
            guard var md = legacy[i].metadata else { continue }
            let removedOld = md.removeValue(forKey: "fileWriteOldContent") != nil
            let removedNew = md.removeValue(forKey: "fileWriteContent") != nil
            if removedOld || removedNew { legacy[i].metadata = md }
        }
        let tmp = sessionDirectory.appendingPathComponent("channel_log.jsonl.tmp")
        try encodeJSONL(legacy).write(to: tmp, options: .atomic)
        try fm.moveItem(at: tmp, to: channelLogJSONLURL)
    }

    /// Appends messages to the session's JSONL channel log (creating/migrating it first).
    /// A single `FileHandle` seek-to-end write; O(size of the appended batch).
    public func appendChannelMessages(_ messages: [ChannelMessage]) throws {
        guard !messages.isEmpty else { return }
        try ensureDirectories()
        try migrateLegacyChannelLogIfNeeded()
        let blob = try encodeJSONL(messages)
        if FileManager.default.fileExists(atPath: channelLogJSONLURL.path) {
            // `forUpdating` (read+write) so the boundary check below can read the last byte;
            // a write-only handle would fault on read.
            let handle = try FileHandle(forUpdating: channelLogJSONLURL)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            // Guard the line boundary: if a prior unclean shutdown left a partial final record
            // (no trailing newline), inject one so the partial stays on its own droppable line
            // and can't fuse with — and corrupt — the first record of this batch.
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let lastByte = try handle.read(upToCount: 1)
                try handle.seekToEnd()
                if lastByte != Data([0x0A]) {
                    try handle.write(contentsOf: Data([0x0A]))
                }
            }
            try handle.write(contentsOf: blob)
        } else {
            try blob.write(to: channelLogJSONLURL, options: .atomic)
        }
    }

    /// Loads the most-recent `limit` messages plus the total on-disk count. Reads the file once
    /// but only decodes the tail — decoding tens of thousands of objects is the expensive part,
    /// and the UI only needs the tail on launch.
    /// Offloaded read (reads the whole `.jsonl` to count lines, decodes only the tail). Runs at
    /// launch, before the session appends anything, so there is no concurrent writer here. Even the
    /// general case is safe: `appendChannelMessages` only GROWS the file (never truncates), so a
    /// concurrent read can't lose page backing (no SIGBUS), and the worst it sees is a half-written
    /// trailing line — which `decodeJSONL` skips by design (same as a partial record from `kill -9`).
    public func loadChannelLogTail(limit: Int) async throws -> (messages: [ChannelMessage], totalCount: Int) {
        try migrateLegacyChannelLogIfNeeded()
        guard FileManager.default.fileExists(atPath: channelLogJSONLURL.path) else { return ([], 0) }
        let data = try await FileIO.read(channelLogJSONLURL)
        return decodeJSONL(data, limit: limit)
    }

    /// Loads the entire channel log. Used only by the user-initiated "Restore full history"
    /// path — the common launch/append paths never materialize the whole transcript.
    /// Offloaded read. Unlike the launch-time tail read this CAN race a live `appendChannelMessages`
    /// (it's the user-initiated "restore full history"), but that's safe for the same reasons:
    /// append only grows the file (no truncation → no mmap SIGBUS), and a torn trailing line is
    /// skipped by `decodeJSONL`. The missed in-flight message is on disk and appears on the next load.
    public func loadFullChannelLog() async throws -> [ChannelMessage] {
        try migrateLegacyChannelLogIfNeeded()
        guard FileManager.default.fileExists(atPath: channelLogJSONLURL.path) else { return [] }
        let data = try await FileIO.read(channelLogJSONLURL)
        return decodeJSONL(data).messages
    }

    // MARK: - Tasks (per-session)

    public func saveTasks(_ tasks: [AgentTask]) async throws {
        try ensureDirectories()
        let url = sessionDirectory.appendingPathComponent("tasks.json")
        try await FileIO.writeJSON(tasks, to: url)
    }

    public func loadTasks() async throws -> [AgentTask] {
        let url = sessionDirectory.appendingPathComponent("tasks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try await FileIO.readJSON([AgentTask].self, from: url)
    }

    /// Moves an unreadable `tasks.json` aside to a timestamped `.corrupt-…` name so a fresh one can
    /// be written without destroying the original — the user can attempt manual recovery. Returns
    /// the destination URL, or nil if there was no file to move. Throws on filesystem failure. Never
    /// deletes data. Mirrors `quarantineCorruptInactiveTasksFile` for the per-session task file.
    public func quarantineCorruptTasksFile() throws -> URL? {
        let url = sessionDirectory.appendingPathComponent("tasks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = sessionDirectory.appendingPathComponent("tasks.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    // MARK: - Timer Events (per-session)

    public func saveTimerEvents(_ events: [TimerEvent]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(events)
        let url = sessionDirectory.appendingPathComponent("timer_events.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadTimerEvents() throws -> [TimerEvent] {
        let url = sessionDirectory.appendingPathComponent("timer_events.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TimerEvent].self, from: data)
    }

    // MARK: - Scheduled Wakes (per-session)

    /// Persists the active scheduled-wake list so reminders survive app restart. Saved on
    /// every wake-list mutation (schedule / cancel / fire-with-recurrence) by the app layer.
    public func saveScheduledWakes(_ wakes: [ScheduledWake]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(wakes)
        let url = sessionDirectory.appendingPathComponent("scheduled_wakes.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadScheduledWakes() throws -> [ScheduledWake] {
        let url = sessionDirectory.appendingPathComponent("scheduled_wakes.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ScheduledWake].self, from: data)
    }

    // MARK: - Pending scheduled-run queue (per-session)

    /// Persists the pending scheduled-run queue — the FIFO list of task IDs whose wakes
    /// fired while another task was in flight, plus paused tasks queued for resume after
    /// an interrupt. Saved on every mutation (enqueue / dequeue) so the queue survives
    /// app quit and crashes. Stored alongside the per-session wake snapshot.
    public func savePendingScheduledRunQueue(_ taskIDs: [UUID]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(taskIDs)
        let url = sessionDirectory.appendingPathComponent("pending_scheduled_run_queue.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadPendingScheduledRunQueue() throws -> [UUID] {
        let url = sessionDirectory.appendingPathComponent("pending_scheduled_run_queue.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([UUID].self, from: data)
    }

    // MARK: - Notification delivery ledger (per-session)

    /// Persists the notification broker's delivery ledger — the effectively-once floor that lets a
    /// wake (or, later, an inbound message) which already fired-and-delivered be recognized as a
    /// duplicate after an app restart instead of re-firing. Keyed on the deterministic notification
    /// id. The broker flushes this after every settle (single-flight coalesced), so a crash loses at
    /// most the last in-flight settle — the effectively-once residual window. Stored on disk as a
    /// plain `{ raw-id: status }` object; `NotificationID` is a single string, so the raw form keys
    /// a JSON object directly (no flat-array encoding).
    public func saveDeliveryLedger(_ ledger: [NotificationID: DeliveryStatus]) throws {
        try ensureDirectories()
        let keyed = Dictionary(uniqueKeysWithValues: ledger.map { ($0.key.raw, $0.value) })
        let data = try JSONEncoder().encode(keyed)
        let url = sessionDirectory.appendingPathComponent("notification_ledger.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadDeliveryLedger() throws -> [NotificationID: DeliveryStatus] {
        let url = sessionDirectory.appendingPathComponent("notification_ledger.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let keyed = try JSONDecoder().decode([String: DeliveryStatus].self, from: data)
        return Dictionary(uniqueKeysWithValues: keyed.map { (NotificationID(raw: $0.key), $0.value) })
    }

    /// Persists the broker's pending-delivery queue — notifications the notification manager is
    /// holding for a pull recipient (Smith) until it drains them. This is the durable outbox: an
    /// undelivered reminder/summary survives an app restart and is handed out on the next drain
    /// rather than lost. Written on every enqueue/drain (coalesced by the broker). Per-session.
    public func savePendingDelivery(_ items: [QueuedDelivery]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(items)
        let url = sessionDirectory.appendingPathComponent("notification_pending.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadPendingDelivery() throws -> [QueuedDelivery] {
        let url = sessionDirectory.appendingPathComponent("notification_pending.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([QueuedDelivery].self, from: data)
    }

    // MARK: - Pending user messages (per-session)

    /// Persists the pending inbound-user-message buffer — messages typed while Smith could not
    /// accept them (agents stopped / mid-startup). Saved on every mutation so a message typed
    /// during a slow startup survives app quit and crashes. Stored per-session, next to the
    /// channel log and scheduled-run queue.
    public func savePendingUserMessages(_ messages: [PendingUserMessage]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(messages)
        let url = sessionDirectory.appendingPathComponent("pending_user_messages.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadPendingUserMessages() throws -> [PendingUserMessage] {
        let url = sessionDirectory.appendingPathComponent("pending_user_messages.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PendingUserMessage].self, from: data)
    }

    // MARK: - Memories (shared)

    public func saveMemories(_ memories: [MemoryEntry]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(memories)
        let url = baseDirectory.appendingPathComponent("memories.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadMemories() throws -> [MemoryEntry] {
        let url = baseDirectory.appendingPathComponent("memories.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([MemoryEntry].self, from: data)
    }

    // MARK: - Task Summaries (shared)

    public func saveTaskSummaries(_ summaries: [TaskSummaryEntry]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(summaries)
        let url = baseDirectory.appendingPathComponent("task_summaries.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadTaskSummaries() throws -> [TaskSummaryEntry] {
        let url = baseDirectory.appendingPathComponent("task_summaries.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TaskSummaryEntry].self, from: data)
    }

    // MARK: - MCP Server Configs (shared)

    public func saveMCPServerConfigs(_ configs: [MCPServerConfig]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(configs)
        let url = baseDirectory.appendingPathComponent("mcp_servers.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadMCPServerConfigs() throws -> [MCPServerConfig] {
        let url = baseDirectory.appendingPathComponent("mcp_servers.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([MCPServerConfig].self, from: data)
    }

    // MARK: - Usage Records (shared)

    public func saveUsageRecords(_ records: [UsageRecord]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        let url = baseDirectory.appendingPathComponent("usage_records.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadUsageRecords() throws -> [UsageRecord] {
        let url = baseDirectory.appendingPathComponent("usage_records.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([UsageRecord].self, from: data)
    }

    // MARK: - User Model Overrides (shared)

    public func saveUserModelOverrides(_ overrides: [String: ModelMetadataOverride]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(overrides)
        let url = baseDirectory.appendingPathComponent("model_overrides.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadUserModelOverrides() throws -> [String: ModelMetadataOverride] {
        let url = baseDirectory.appendingPathComponent("model_overrides.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: ModelMetadataOverride].self, from: data)
    }

    // MARK: - Attachments (global)

    /// One-time migration: moves every session's attachment files into the global attachments dir.
    /// Attachment files are uniquely named (UUID prefix), so pooling them can't collide. Files are
    /// MOVED (never deleted); a file already at the destination is left as-is. Returns the counts of
    /// files moved and files that failed to move. Idempotent — after a clean run the session
    /// attachment dirs are empty, so re-running is a cheap no-op.
    public func migrateSessionAttachmentsToGlobalStore() throws -> (moved: Int, failed: Int) {
        let fm = FileManager.default
        let sessionsRoot = baseDirectory.appendingPathComponent("sessions", isDirectory: true)
        guard fm.fileExists(atPath: sessionsRoot.path) else { return (0, 0) }
        try fm.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        var moved = 0
        var failed = 0
        let sessionDirs = (try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)) ?? []
        for sessionDir in sessionDirs {
            let src = sessionDir.appendingPathComponent("attachments", isDirectory: true)
            guard fm.fileExists(atPath: src.path) else { continue }
            let files = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let dest = attachmentsDirectory.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { continue }
                do {
                    try fm.moveItem(at: file, to: dest)
                    moved += 1
                } catch {
                    failed += 1
                    logger.error("Failed to migrate attachment \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return (moved, failed)
    }

    public func saveAttachment(_ attachment: Attachment) throws {
        guard let fileData = attachment.data else { return }
        try ensureDirectories()
        let safeName = Self.sanitizeFilename(attachment.filename)
        let url = attachmentsDirectory.appendingPathComponent(
            "\(attachment.id.uuidString)_\(safeName)"
        )
        try fileData.write(to: url, options: .atomic)
    }

    public func loadAttachmentData(id: UUID, filename: String) -> Data? {
        let safeName = Self.sanitizeFilename(filename)
        let url = attachmentsDirectory.appendingPathComponent(
            "\(id.uuidString)_\(safeName)"
        )
        do {
            return try Data(contentsOf: url)
        } catch {
            logger.error("Failed to load attachment \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the on-disk URL where an attachment is (or would be) stored. Does NOT
    /// check that the file exists — the URL is computed deterministically from the
    /// global attachments directory and the sanitized filename. Callers that want
    /// to load bytes should use `loadAttachmentData(id:filename:)` and check for nil;
    /// callers that just want a stable `file://` reference for LLM-facing text (e.g.
    /// the briefing builder) can pass this URL straight into a markdown link.
    ///
    /// `nonisolated` because it does no I/O — pure path construction, suitable for
    /// synchronous code paths inside `AgentActor.drainPendingMessages` that need a
    /// `file://` URL without an actor hop.
    public nonisolated func attachmentURL(id: UUID, filename: String) -> URL {
        let safeName = Self.sanitizeFilename(filename)
        return attachmentsDirectory.appendingPathComponent(
            "\(id.uuidString)_\(safeName)"
        )
    }

    /// Strips path components from a filename to prevent directory traversal.
    static func sanitizeFilename(_ filename: String) -> String {
        let stripped = (filename as NSString).lastPathComponent
        return stripped.isEmpty ? "unnamed" : stripped
    }
}
