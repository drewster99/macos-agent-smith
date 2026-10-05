import Foundation

public struct EditTaskTool: AgentTool {
    /// Tool-call name advertised to Smith.
    public let name = "edit_task"
    /// Human-readable description included in the model tool schema.
    public let toolDescription = """
        Edit a pending, paused, interrupted, failed, scheduled, or template task's definition. \
        Use this for title, full description replacement, template toggle, template input \
        definitions (or `clear_template_inputs: true` to remove them), template instance title \
        template. It cannot change which tools a task's worker gets — the Security Agent scopes \
        those and only the user can override them. \
        Do not use while a worker is running the task. On a TEMPLATE, title and description may \
        use `{{input_name}}` placeholders; one naming no defined input is refused. Renaming an \
        input and the text that references it in a SINGLE call is accepted — the two are checked \
        together, so neither half has to be valid against the other's old version.
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
                "description": .string("Optional COMPLETE replacement input definition list. An empty array is treated as an omitted placeholder; use clear_template_inputs to remove every input.")
            ]),
            "clear_template_inputs": .dictionary([
                "type": .string("boolean"),
                "description": .string("Set true to remove every template input definition. This explicit flag avoids mistaking a model-emitted empty placeholder array for destructive intent.")
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

    /// Applies supported task definition edits.
    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"], let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Missing or invalid 'task_id'.")
        }
        guard let task = await context.taskStore.taskOrLibraryTemplate(id: taskID) else {
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
        let clearsTemplateInputs = ToolArguments.optionalBool(arguments, "clear_template_inputs") == true
        // An empty array is still an absent placeholder — some models emit it on every call. A
        // destructive clear therefore has its own boolean, while a populated array remains the
        // complete replacement surface.
        if clearsTemplateInputs,
           ToolArguments.optionalArray(arguments, "template_inputs") != nil {
            return .failure("Pass template_inputs OR clear_template_inputs: true, not both.")
        } else if clearsTemplateInputs {
            definitions = []
        } else if let rawInputs = ToolArguments.optionalArray(arguments, "template_inputs") {
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
        // Removed from the schema 2026-10-05: Smith granting tools bypassed both the Security
        // Agent's scoping and the user's policy. A history that still shows the parameter could
        // make Smith pass it again, and an ignored key would report a grant that never happened.
        // An empty placeholder (null, "", [], {}) is a model emitting an absent optional, not a grant.
        if ToolArguments.isSupplied(arguments, "tool_overrides") {
            return .failure("edit_task no longer changes a task's tools: the Security Agent scopes them and only the user can override them. Nothing was changed.")
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

        return .success("Task '\(title)' updated.")
    }

    private enum ParseResult {
        case success([TemplateInputDefinition])
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

    private static func optionalString(_ value: AnyCodable?) -> String? {
        guard case .string(let raw) = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
