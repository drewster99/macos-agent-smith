import Foundation
import SwiftLLMKit

/// The wire vocabulary shared by `watch_task` and `list_task_watches`: one table per enum, so the
/// schema, the parser and the listing can never disagree about a name.
enum TaskWatchToolVocabulary {
    static let triggerNames: [(wire: String, trigger: TaskWatchTrigger)] = [
        ("started", .started),
        ("completed", .completed),
        ("failed", .failed),
        ("needs_help", .needsHelp),
        ("needs_review", .needsReview),
        ("interrupted", .interrupted)
    ]

    enum ActionName: String, CaseIterable {
        case startTask = "start_task"
        case macOSNotification = "macos_notification"
        case summarizeToUser = "summarize_to_user"
        case instructSmith = "instruct_smith"
    }

    static let lifetimeNames: [(wire: String, lifetime: TaskWatchLifetime)] = [
        ("once", .once),
        ("every_time", .everyTime)
    ]

    static func wireName(_ trigger: TaskWatchTrigger) -> String {
        triggerNames.first { $0.trigger == trigger }?.wire ?? trigger.rawValue
    }

    static func wireName(_ lifetime: TaskWatchLifetime) -> String {
        lifetimeNames.first { $0.lifetime == lifetime }?.wire ?? lifetime.rawValue
    }

    /// One line describing a watch, for Smith and for `get_task_details`.
    static func describe(_ watch: TaskWatch, targetTitle: (UUID) -> String?) -> String {
        let when = watch.triggers.sorted { $0.rawValue < $1.rawValue }.map(wireName).joined(separator: ", ")
        let action: String
        switch watch.action {
        case .startTask(let targetID):
            action = targetTitle(targetID).map { "start task \"\($0)\" (\(targetID.uuidString))" } ?? "start task \(targetID.uuidString)"
        case .macOSNotification:
            action = "macOS notification"
        case .summarizeToUser:
            action = "Smith summarizes to the user"
        case .instructSmith(let text):
            action = "instructions for Smith: \(text)"
        }
        let state: String
        switch watch.state {
        case .active: state = "active"
        case .cancelled: state = "cancelled"
        case .consumed: state = "fired (once)"
        }
        var line = "watch \(watch.id.uuidString) [\(state), \(wireName(watch.lifetime)), by \(watch.createdBy.rawValue)]: when \(when) → \(action)"
        if let last = watch.recentFirings.last {
            line += "; last firing #\(last.occurrence) \(describe(last.state))"
        }
        return line
    }

    static func describe(_ state: TaskWatchFiring.State) -> String {
        switch state {
        case .pending: return "pending"
        case .inFlight: return "in flight"
        case .delivered: return "delivered"
        case .refused(let reason): return "refused (\(reason))"
        case .cancelled: return "cancelled"
        }
    }
}

/// Smith tool: create or cancel a task watch — "when this task reaches a state, do something".
struct WatchTaskTool: AgentTool {
    let name = "watch_task"
    let toolDescription = """
        Create or cancel a WATCH on a task: when the task reaches one of the given states, something \
        happens automatically — start another task (a chain), post a macOS notification, have you \
        summarize the outcome to the user, or deliver instructions to you. Use it when the user asks \
        for something to happen "when X finishes/fails/needs help". A watch on a template is copied \
        into every run (start_task is not allowed on a template). A start_task watch HOLDS its target: \
        nothing starts that task automatically (not auto-advance, not run_task, not a schedule) until \
        the watch fires — only the user's Play overrides it. A watch never reopens or resets a task.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "action": .dictionary([
                "type": .string("string"),
                "enum": .array([.string("create"), .string("cancel")]),
                "description": .string("create a new watch, or cancel an existing one.")
            ]),
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the task to watch (create), or the task the watch is on (cancel).")
            ]),
            "when": .dictionary([
                "type": .string("array"),
                "items": .dictionary([
                    "type": .string("string"),
                    "enum": .array(TaskWatchToolVocabulary.triggerNames.map { .string($0.wire) })
                ]),
                "description": .string("create: the states that fire the watch. `started` is a worker actually starting the task.")
            ]),
            "do": .dictionary([
                "type": .string("string"),
                "enum": .array(TaskWatchToolVocabulary.ActionName.allCases.map { .string($0.rawValue) }),
                "description": .string("create: what happens when it fires.")
            ]),
            "target_task_id": .dictionary([
                "type": .string("string"),
                "description": .string("do=start_task: UUID of the task to start. Must be a pending, paused or interrupted task in this session.")
            ]),
            "instructions": .dictionary([
                "type": .string("string"),
                "description": .string("do=instruct_smith: what you should do when it fires.")
            ]),
            "lifetime": .dictionary([
                "type": .string("string"),
                "enum": .array(TaskWatchToolVocabulary.lifetimeNames.map { .string($0.wire) }),
                "description": .string("create, optional: `once` or `every_time`. Defaults: start_task → once; the others → every_time.")
            ]),
            "watch_id": .dictionary([
                "type": .string("string"),
                "description": .string("cancel: UUID of the watch (from list_task_watches or get_task_details).")
            ])
        ]),
        "required": .array([.string("action"), .string("task_id")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let actionName) = arguments["action"] else {
            throw ToolCallError.missingRequiredArgument("action")
        }
        guard let action = Operation(rawValue: actionName) else {
            return .failure("Invalid action '\(actionName)'. Use `create` or `cancel`.")
        }
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Invalid task_id: '\(taskIDString)' is not a valid UUID.")
        }
        switch action {
        case .create:
            return await create(on: taskID, arguments: arguments, context: context)
        case .cancel:
            return await cancel(on: taskID, arguments: arguments, context: context)
        }
    }

    private enum Operation: String {
        case create
        case cancel
    }

    private func create(on taskID: UUID, arguments: [String: AnyCodable], context: ToolContext) async -> ToolExecutionResult {
        guard let rawTriggers = ToolArguments.optionalArray(arguments, "when") else {
            return .failure("`when` is required to create a watch: one or more of \(TaskWatchToolVocabulary.triggerNames.map(\.wire).joined(separator: ", ")).")
        }
        var triggers: Set<TaskWatchTrigger> = []
        for raw in rawTriggers {
            guard case .string(let name) = raw,
                  let trigger = TaskWatchToolVocabulary.triggerNames.first(where: { $0.wire == name })?.trigger else {
                return .failure("Unknown state in `when`: \(raw). Use \(TaskWatchToolVocabulary.triggerNames.map(\.wire).joined(separator: ", ")).")
            }
            triggers.insert(trigger)
        }
        guard let doName = ToolArguments.optionalString(arguments, "do"),
              let actionName = TaskWatchToolVocabulary.ActionName(rawValue: doName) else {
            return .failure("`do` is required: one of \(TaskWatchToolVocabulary.ActionName.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let watchAction: TaskWatchAction
        switch actionName {
        case .startTask:
            switch ToolArguments.optionalUUID(arguments, "target_task_id") {
            case .absent:
                return .failure("`target_task_id` is required for do=start_task.")
            case .malformed(let raw):
                return .failure("Invalid target_task_id: '\(raw)' is not a valid UUID.")
            case .value(let targetID):
                watchAction = .startTask(taskID: targetID)
            }
        case .macOSNotification:
            watchAction = .macOSNotification
        case .summarizeToUser:
            watchAction = .summarizeToUser
        case .instructSmith:
            guard let instructions = ToolArguments.optionalString(arguments, "instructions") else {
                return .failure("`instructions` is required for do=instruct_smith.")
            }
            watchAction = .instructSmith(instructions)
        }
        var lifetime: TaskWatchLifetime?
        if let lifetimeName = ToolArguments.optionalString(arguments, "lifetime") {
            guard let parsed = TaskWatchToolVocabulary.lifetimeNames.first(where: { $0.wire == lifetimeName })?.lifetime else {
                return .failure("Invalid lifetime '\(lifetimeName)'. Use `once` or `every_time`.")
            }
            lifetime = parsed
        }
        let watch = TaskWatch(triggers: triggers, action: watchAction, lifetime: lifetime, createdBy: .smith)
        if let refusal = await context.taskStore.addWatch(watch, to: taskID) {
            return .failure(refusal)
        }
        let taskTitle = await context.taskStore.taskOrLibraryTemplate(id: taskID)?.title ?? taskID.uuidString
        let description = await Self.describe(watch, context: context)
        return .success("Watch created on \"\(taskTitle)\": \(description)")
    }

    private func cancel(on taskID: UUID, arguments: [String: AnyCodable], context: ToolContext) async -> ToolExecutionResult {
        let watchID: UUID
        switch ToolArguments.optionalUUID(arguments, "watch_id") {
        case .absent:
            return .failure("`watch_id` is required to cancel a watch. Use list_task_watches to find it.")
        case .malformed(let raw):
            return .failure("Invalid watch_id: '\(raw)' is not a valid UUID.")
        case .value(let id):
            watchID = id
        }
        if let refusal = await context.taskStore.cancelWatch(watchID, on: taskID) {
            return .failure(refusal)
        }
        return .success("Watch \(watchID.uuidString) cancelled.")
    }

    static func describe(_ watch: TaskWatch, context: ToolContext) async -> String {
        var titles: [UUID: String] = [:]
        if case .startTask(let targetID) = watch.action {
            titles[targetID] = await context.taskStore.task(id: targetID)?.title
        }
        return TaskWatchToolVocabulary.describe(watch) { titles[$0] }
    }
}

/// Smith tool: list the watches in this session (read-only).
struct ListTaskWatchesTool: AgentTool {
    let name = "list_task_watches"
    let toolDescription = """
        List the watches on this session's tasks (or on one task): what each reacts to, what it does, \
        whether it is still active, and how its latest firing went. Also lists tasks held waiting for \
        a watch to start them.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("Optional: only this task's watches.")
            ])
        ]),
        "required": .array([])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        let filter: UUID?
        switch ToolArguments.optionalUUID(arguments, "task_id") {
        case .absent: filter = nil
        case .malformed(let raw): return .failure("Invalid task_id: '\(raw)' is not a valid UUID.")
        case .value(let id): filter = id
        }
        // Library templates too: a notifying watch on a template lives there, and Smith needs its id
        // to cancel it.
        let everything = await context.taskStore.allTasks() + context.taskStore.allLibraryTemplates()
        var seen: Set<UUID> = []
        let unique = everything.filter { seen.insert($0.id).inserted }
        let tasks = unique.filter { filter == nil || $0.id == filter }
        let titles = Dictionary(unique.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        for task in tasks {
            for watch in task.watches {
                lines.append("- \"\(task.title)\" (\(task.id.uuidString)): \(TaskWatchToolVocabulary.describe(watch) { titles[$0] })")
            }
            for hold in task.startHolds {
                lines.append("- \"\(task.title)\" (\(task.id.uuidString)) is WAITING on \"\(titles[hold.watchedTaskID] ?? hold.watchedTaskID.uuidString)\" (watch \(hold.watchID.uuidString))")
            }
        }
        if lines.isEmpty {
            return .success(filter == nil ? "No task in this session has a watch." : "That task has no watches.")
        }
        return .success(lines.joined(separator: "\n"))
    }
}
