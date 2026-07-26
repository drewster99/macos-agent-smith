import Foundation

/// The functional family a **built-in** tool belongs to, surfaced to the Security Agent both when
/// it scopes a task's toolset and when it evaluates an individual call.
///
/// Why groups exist: a tool's own description says what that tool does. The group says what KIND
/// of capability it is — whether it leaves the machine, whether it can destroy something, whether
/// it only reads. The evaluator judges a call against the task it is supposed to serve, and
/// "this is a shell command" is a different starting posture from "this is a task-status update"
/// even before the parameters are read.
///
/// MCP tools are deliberately NOT modeled here. Their group is their server, and its description
/// is whatever that server claims about itself — untrusted text, handled separately in
/// `SecurityEvaluator.toolGroupDescription(for:)`. Everything in this file is a fact about tools
/// we author.
///
/// A tool with no entry here has NO group, which is a valid answer rather than an error — the
/// evaluator simply gets the tool's own description. Grouping is orthogonal to safety
/// classification: `ToolSafetyClassification` remains the authority on destructive/open-world,
/// and a group never softens it.
public enum BuiltInToolGroup: String, CaseIterable, Sendable {
    case taskManagement = "builtin.task-management"
    case messaging = "builtin.messaging"
    case scheduling = "builtin.scheduling"
    case filesystem = "builtin.filesystem"
    case memory = "builtin.memory"
    case web = "builtin.web"
    case shell = "builtin.shell"
    case macOSAutomation = "builtin.macos-automation"
    case attachments = "builtin.attachments"
    case agentControl = "builtin.agent-control"
    case time = "builtin.time"

    /// Short human-readable name, shown alongside the ID in the scoping payload.
    public var displayName: String {
        switch self {
        case .taskManagement: return "Task management"
        case .messaging: return "Messaging"
        case .scheduling: return "Scheduling"
        case .filesystem: return "Local filesystem"
        case .memory: return "Long-term memory"
        case .web: return "Web / network"
        case .shell: return "Shell execution"
        case .macOSAutomation: return "macOS app automation"
        case .attachments: return "Attachments"
        case .agentControl: return "Agent control"
        case .time: return "Clock"
        }
    }

    /// What this family of capability means for a security judgment. Written for the Security
    /// Agent, so each says where the blast radius is rather than restating the tool list.
    public var groupDescription: String {
        switch self {
        case .taskManagement:
            return "Creates and mutates tasks in this app's own task store: descriptions, step plans, "
                + "acceptance criteria, status. Effects are internal to Agent Smith and touch nothing "
                + "outside it, though they can redirect what a worker does next."
        case .messaging:
            return "Moves text between the user and the agents, or between agents. Nothing leaves the "
                + "machine, but content reaches a human, so judge it for what it DISCLOSES — a message "
                + "can carry secrets a file read only touched."
        case .scheduling:
            return "Schedules, reschedules and cancels future task runs and reminders. No immediate "
                + "effect; the risk is a durable one that fires later, unattended."
        case .filesystem:
            return "Reads and writes the user's local filesystem. Reads inspect and are recoverable; "
                + "writes and edits change real files and are NOT automatically reversible. Judge the "
                + "path as much as the operation — location determines whether a write is routine or "
                + "destructive."
        case .memory:
            return "Reads and writes the assistant's long-term memory corpus, which is injected into "
                + "future prompts. A write here persists across sessions and shapes later behavior, so "
                + "it outlives the task that made it."
        case .web:
            return "Reaches the public internet. Anything placed in a query, URL or request body has "
                + "LEFT the machine and cannot be recalled. This is the primary exfiltration surface: "
                + "weigh what the call sends at least as heavily as what it fetches."
        case .shell:
            return "Executes arbitrary commands on the user's machine with the user's privileges. "
                + "Effectively unbounded: a single call can read, write, delete, install or transmit. "
                + "The command text is the whole of the security question."
        case .macOSAutomation:
            return "Inspects and drives other macOS applications via AppleScript. Discovery calls only "
                + "read an app's scripting vocabulary; execution can act inside other apps — sending "
                + "mail, altering documents — with effects outside this app entirely."
        case .attachments:
            return "Ingests file bytes into the conversation, including images sent to the model "
                + "provider. Content crosses from disk into the prompt and out to a third party, so an "
                + "attachment is an egress decision, not merely a read."
        case .agentControl:
            return "Stops agents or aborts the run. Not destructive to user data, but it can halt work "
                + "in progress and is how a compromised agent would silence its supervision."
        case .time:
            return "Reads the current date and time. No side effects and no data leaves the machine."
        }
    }

    /// The group a built-in tool belongs to, or `nil` when it has none.
    ///
    /// Fail-safe by omission rather than fail-closed by default: an unrecognized name simply has no
    /// group, so the evaluator falls back to the tool's own description. Nothing here grants
    /// anything, so a missing entry cannot widen a permission — unlike
    /// `ToolSafetyClassification`, where an unknown name must be assumed dangerous.
    public static func group(forToolName name: String) -> BuiltInToolGroup? {
        toolsByGroup.first { $0.value.contains(name) }?.key
    }

    /// The membership table. Kept as one literal so a tool's group is greppable from its name.
    private static let toolsByGroup: [BuiltInToolGroup: Set<String>] = [
        .taskManagement: [
            "create_task", "run_task", "update_task", "edit_task", "amend_task",
            "get_task_details", "list_tasks", "set_template_inputs", "manage_task_disposition",
            "manage_steps", "set_acceptance_criteria", "task_update", "task_complete"
        ],
        .messaging: [
            "message_user", "message_brown", "reply_to_user",
            "report_inbound_user_message", "request_help", "provide_help"
        ],
        .scheduling: [
            "schedule_task_action", "schedule_reminder",
            "reschedule_wake", "cancel_wake", "list_scheduled_wakes"
        ],
        .filesystem: [
            "file_read", "file_write", "file_edit",
            "directory_listing", "directory_tree", "glob", "grep"
        ],
        .memory: ["save_memory", "search_memory"],
        .web: ["web_search", "web_fetch", "instant_answer"],
        .shell: ["bash", "gh"],
        .macOSAutomation: ["run_applescript", "list_scriptable_apps", "get_app_scripting_schema"],
        .attachments: ["attach_file"],
        .agentControl: ["terminate_agent", "abort"],
        .time: ["get_current_time"]
    ]
}
