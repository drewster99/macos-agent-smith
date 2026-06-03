import Foundation

/// Central, authoritative safety classification for our **built-in** tools, used to provide
/// the default `AgentTool.isDestructive` / `AgentTool.isOpenWorld` values that the security
/// agent (Jones) sees when scoping a task's tool set.
///
/// Design notes:
/// - **Fail-closed.** Any tool name not recognized here is treated as both destructive and
///   open-world (the most cautious classification). New built-in tools therefore default to
///   "risky" until explicitly classified, and MCP tools — which are never in this table — fall
///   back to their (untrusted) server-supplied hints via `MCPBridgedTool`.
/// - These are *facts* about tools we author, not hints. Unlike MCP annotations, the security
///   agent may rely on them as accurate.
/// - Only `destructive` / `openWorld` are surfaced to Jones (per design); `readOnly` and
///   `idempotent` are deliberately not modeled here.
enum ToolSafetyClassification {
    /// Every built-in tool name we recognize. A name absent from this set is unknown
    /// (e.g. an MCP tool or a newly-added built-in that forgot to register) and is treated
    /// fail-closed.
    static let knownBuiltInNames: Set<String> = [
        // Read-only
        "file_read", "view_attachment", "glob", "directory_tree", "directory_listing",
        "grep", "search_memory", "get_task_details", "list_scriptable_apps",
        "get_app_scripting_schema", "get_current_time", "list_tasks", "list_scheduled_wakes",
        // Low-risk side-effecting (lifecycle / orchestration)
        "task_acknowledged", "task_update", "task_complete", "reply_to_user",
        "message_user", "message_brown", "review_work", "create_task", "run_task",
        "update_task", "amend_task", "schedule_task_action", "reschedule_wake", "cancel_wake",
        // Destructive
        "file_write", "file_edit", "save_memory", "manage_task_disposition",
        "terminate_agent", "abort", "bash", "gh", "run_applescript"
    ]

    /// Built-in tools whose effects can be destructive or hard to reverse (data loss,
    /// irreversible state change). `save_memory` is here because memory writes run
    /// auto-consolidation that can rewrite/merge existing memories with no clean undo.
    private static let destructiveNames: Set<String> = [
        "file_write", "file_edit", "save_memory", "manage_task_disposition",
        "terminate_agent", "abort", "bash", "gh", "run_applescript"
    ]

    /// Built-in tools that reach an open/external world beyond a closed local system
    /// (arbitrary network access, external app control, the internet).
    private static let openWorldNames: Set<String> = [
        "bash", "gh", "run_applescript"
    ]

    /// Built-in tools that are read-only — they inspect state but don't modify anything, so
    /// they have no side effects.
    private static let readOnlyNames: Set<String> = [
        "file_read", "view_attachment", "glob", "directory_tree", "directory_listing",
        "grep", "search_memory", "get_task_details", "list_scriptable_apps",
        "get_app_scripting_schema", "get_current_time", "list_tasks", "list_scheduled_wakes"
    ]

    /// Whether a built-in tool has side effects (mutates state / acts). Read-only tools don't;
    /// everything else does. Fail-closed: unknown name → `true`.
    static func hasSideEffects(toolName: String) -> Bool {
        !readOnlyNames.contains(toolName)
    }

    /// Fail-closed: unknown name → `true`.
    static func isDestructive(toolName: String) -> Bool {
        if destructiveNames.contains(toolName) { return true }
        return !knownBuiltInNames.contains(toolName)
    }

    /// Fail-closed: unknown name → `true`.
    static func isOpenWorld(toolName: String) -> Bool {
        if openWorldNames.contains(toolName) { return true }
        return !knownBuiltInNames.contains(toolName)
    }
}
