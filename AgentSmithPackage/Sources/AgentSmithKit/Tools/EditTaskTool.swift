import Foundation

public struct EditTaskTool: AgentTool {
    /// Tool-call name advertised to Smith.
    public let name = "edit_task"
    /// Human-readable description included in the model tool schema.
    public let toolDescription = """
        Edit a pending, paused, interrupted, failed, scheduled, or template task's definition. \
        Use this for title, full description replacement, template toggle, template input \
        definitions, template instance title template, and per-task worker tool overrides. \
        Do not use while a worker is running the task.
        """

    /// JSON-schema-compatible parameter description for editing a task definition.
    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary(["type": .string("string"), "description": .string("UUID of the task to edit.")]),
            "title": .dictionary(["type": .string("string"), "description": .string("Optional replacement title.")]),
            "description": .dictionary(["type": .string("string"), "description": .string("Optional full replacement description.")]),
            "is_template": .dictionary(["type": .string("boolean"), "description": .string("Optional template toggle.")]),
            "template_instance_title_template": .dictionary(["type": .string("string"), "description": .string("Optional instance title template using {{input_name}} placeholders. Empty clears it.")]),
            "template_inputs": .dictionary([
                "type": .string("array"),
                "items": .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "name": .dictionary(["type": .string("string")]),
                        "description": .dictionary(["type": .string("string")]),
                        "required": .dictionary(["type": .string("boolean")])
                    ]),
                    "required": .array([.string("name"), .string("description")])
                ]),
                "description": .string("Optional COMPLETE replacement input definition list.")
            ]),
            "tool_overrides": .dictionary([
                "type": .string("object"),
                "description": .string("Optional per-task worker tool overrides. Keys are tool names; values are 'auto', 'on', or 'off'.")
            ])
        ]),
        "required": .array([.string("task_id")])
    ]

    /// Creates the Smith-only edit task tool.
    public init() {}

    /// Returns true only for Smith; workers must not rewrite task definitions through this tool.
    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    /// Applies supported task definition and per-task tool override edits.
    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"], let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Missing or invalid 'task_id'.")
        }
        guard let task = await context.taskStore.task(id: taskID) else {
            return .failure("No task with id \(taskID.uuidString).")
        }

        let title = Self.optionalString(arguments["title"]) ?? task.title
        let description = Self.optionalString(arguments["description"]) ?? task.description
        let isTemplate: Bool
        if case .bool(let value) = arguments["is_template"] {
            isTemplate = value
        } else {
            isTemplate = task.isTemplate
        }
        let definitions: [TemplateInputDefinition]
        if case .array(let rawInputs) = arguments["template_inputs"] {
            // Refuse rather than silently drop them — a caller that thinks it just defined
            // inputs would otherwise go on to call run_task with input_values that reject.
            guard isTemplate else {
                return .failure("template_inputs are valid only on template tasks. Pass is_template: true in the same call, or use a template task id.")
            }
            switch Self.parseInputs(rawInputs) {
            case .success(let parsed): definitions = parsed
            case .failure(let message): return .failure(message)
            }
        } else {
            definitions = isTemplate ? task.templateInputDefinitions : []
        }
        let titleTemplate = arguments.keys.contains("template_instance_title_template")
            ? Self.optionalString(arguments["template_instance_title_template"])
            : task.templateInstanceTitleTemplate
        let parsedOverrides: [(tool: String, enabled: Bool?)]
        switch Self.parseToolOverrides(arguments["tool_overrides"]) {
        case .success(let overrides):
            parsedOverrides = overrides
        case .failure(let message):
            return .failure(message)
        }

        if let problem = await context.taskStore.updateDefinition(
            id: taskID,
            title: title,
            description: description,
            isTemplate: isTemplate,
            templateInputDefinitions: definitions,
            templateInstanceTitleTemplate: titleTemplate
        ) {
            return .failure(problem)
        }

        for override in parsedOverrides {
            await context.taskStore.setUserToolOverride(id: taskID, tool: override.tool, enabled: override.enabled)
        }

        return .success("Task '\(title)' updated.")
    }

    private enum ParseResult {
        case success([TemplateInputDefinition])
        case failure(String)
    }

    private enum ToolOverrideParseResult {
        case success([(tool: String, enabled: Bool?)])
        case failure(String)
    }

    private static func parseInputs(_ rawInputs: [AnyCodable]) -> ParseResult {
        var definitions: [TemplateInputDefinition] = []
        for raw in rawInputs {
            guard case .dictionary(let fields) = raw,
                  case .string(let name) = fields["name"],
                  case .string(let description) = fields["description"] else {
                return .failure("Every template input must be an object with string 'name' and 'description'.")
            }
            let required: Bool
            if case .bool(let value) = fields["required"] {
                required = value
            } else {
                required = false
            }
            definitions.append(TemplateInputDefinition(name: name, description: description, required: required))
        }
        if let problem = TemplateInputValidation.validateDefinitions(definitions) {
            return .failure(problem)
        }
        return .success(definitions)
    }

    private static func parseToolOverrides(_ rawValue: AnyCodable?) -> ToolOverrideParseResult {
        guard let rawValue else { return .success([]) }
        guard case .dictionary(let overrides) = rawValue else {
            return .failure("tool_overrides must be an object whose values are 'auto', 'on', or 'off'.")
        }
        var parsed: [(tool: String, enabled: Bool?)] = []
        for (tool, rawState) in overrides {
            guard case .string(let state) = rawState else {
                return .failure("tool_overrides values must be 'auto', 'on', or 'off'.")
            }
            switch state {
            case "auto":
                parsed.append((tool: tool, enabled: nil))
            case "on":
                parsed.append((tool: tool, enabled: true))
            case "off":
                parsed.append((tool: tool, enabled: false))
            default:
                return .failure("Invalid tool override state '\(state)' for \(tool). Use 'auto', 'on', or 'off'.")
            }
        }
        return .success(parsed)
    }

    private static func optionalString(_ value: AnyCodable?) -> String? {
        guard case .string(let raw) = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
