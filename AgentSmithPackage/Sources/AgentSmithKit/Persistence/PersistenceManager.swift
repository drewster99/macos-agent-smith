import Foundation
import os
import SwiftLLMKit

private let logger = Logger(subsystem: "com.agentsmith", category: "Persistence")

/// Saves and loads channel logs, task lists, attachments, memories, summaries, and usage data.
///
/// There are two flavors:
/// * `init()` — base manager. Used for shared resources that are never session-scoped
///   (memories, task summaries, usage records, model overrides, session list).
/// * `init(sessionID:)` — session-scoped manager. Channel / task / attachment / state methods
///   read and write `AgentSmith/sessions/<id>/…`. Shared methods always use the root
///   `AgentSmith/` dir regardless of which flavor was used to construct the manager.
///
/// The `preconditionFailure` in `appSupportURL()` guards against truly exceptional platform
/// breakage (e.g., a sandboxing misconfiguration) where no recovery is possible.
public actor PersistenceManager {
    private let baseDirectory: URL
    private let sessionDirectory: URL
    private let attachmentsDirectory: URL

    public init() {
        let appSupport = Self.appSupportURL()
        baseDirectory = appSupport.appendingPathComponent("AgentSmith", isDirectory: true)
        sessionDirectory = baseDirectory
        attachmentsDirectory = baseDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    public init(sessionID: UUID) {
        let appSupport = Self.appSupportURL()
        baseDirectory = appSupport.appendingPathComponent("AgentSmith", isDirectory: true)
        sessionDirectory = baseDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        attachmentsDirectory = sessionDirectory.appendingPathComponent("attachments", isDirectory: true)
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

    public func saveChannelLog(_ messages: [ChannelMessage]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(messages)
        let url = sessionDirectory.appendingPathComponent("channel_log.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadChannelLog() throws -> [ChannelMessage] {
        let url = sessionDirectory.appendingPathComponent("channel_log.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ChannelMessage].self, from: data)
    }

    // MARK: - Tasks (per-session)

    public func saveTasks(_ tasks: [AgentTask]) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(tasks)
        let url = sessionDirectory.appendingPathComponent("tasks.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadTasks() throws -> [AgentTask] {
        let url = sessionDirectory.appendingPathComponent("tasks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([AgentTask].self, from: data)
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

    // MARK: - Attachments (per-session)

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
    /// per-session attachments directory and the sanitized filename. Callers that want
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
