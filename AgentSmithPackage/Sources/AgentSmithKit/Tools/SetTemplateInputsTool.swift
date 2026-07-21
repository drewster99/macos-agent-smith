import Foundation

/// Smith's authoring surface for a template task's required and optional string inputs.
public struct SetTemplateInputsTool: AgentTool {
    public let name = "set_template_inputs"
    public let toolDescription = """
        Replace a TEMPLATE task's string-only input definitions. Template inputs are named values \
        supplied when `run_task` instantiates a template. Ordinary non-template tasks cannot define \
        inputs. Each input is `{name, description, required?}`; names must match \
        ^[a-z][a-z0-9_]*$ and be unique. This replaces the complete input definition list.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the template task whose inputs should be replaced.")
            ]),
            "template_inputs": .dictionary([
                "type": .string("array"),
                "items": .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "name": .dictionary([
                            "type": .string("string"),
                            "description": .string("Stable machine-readable key. Must match ^[a-z][a-z0-9_]*$ and be unique within the template.")
                        ]),
                        "description": .dictionary([
                            "type": .string("string"),
                            "description": .string("User/agent-facing help text explaining what value to provide.")
                        ]),
                        "required": .dictionary([
                            "type": .string("boolean"),
                            "description": .string("true if this input must be provided before the template can run. Default false.")
                        ])
                    ]),
                    "required": .array([.string("name"), .string("description")])
                ]),
                "description": .string("The COMPLETE replacement list of template inputs. Pass [] to clear all inputs.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("template_inputs")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"], let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Missing or invalid 'task_id' — pass the template task's UUID.")
        }
        guard let task = await context.taskStore.task(id: taskID) else {
            return .failure("No task with id \(taskID.uuidString). Use list_tasks to find the right id.")
        }
        guard task.isTemplate else {
            return .failure("Task '\(task.title)' is not a template. Only template tasks can define template inputs.")
        }
        guard case .array(let rawInputs) = arguments["template_inputs"] else {
            return .failure("'template_inputs' must be an array of {name, description, required?} objects.")
        }

        let definitions: [TemplateInputDefinition]
        switch Self.parseTemplateInputDefinitions(rawInputs) {
        case .success(let parsed):
            definitions = parsed
        case .failure(let message):
            return .failure(message)
        }

        if let problem = await context.taskStore.setTemplateInputDefinitions(id: taskID, definitions: definitions) {
            return .failure(problem)
        }
        let requiredCount = definitions.filter(\.required).count
        return .success("Template '\(task.title)' now has \(definitions.count) input definition(s), \(requiredCount) required.")
    }

    private enum TemplateInputParseResult {
        case success([TemplateInputDefinition])
        case failure(String)
    }

    private static func parseTemplateInputDefinitions(_ rawInputs: [AnyCodable]) -> TemplateInputParseResult {
        var definitions: [TemplateInputDefinition] = []
        for raw in rawInputs {
            guard case .dictionary(let fields) = raw else {
                return .failure("Every template input must be an object with required 'name' and 'description' fields.")
            }
            guard case .string(let rawName) = fields["name"] else {
                return .failure("Every template input requires a string 'name'.")
            }
            guard case .string(let rawDescription) = fields["description"] else {
                return .failure("Template input '\(rawName)' requires a string 'description'.")
            }
            let required: Bool
            if case .bool(let value) = fields["required"] {
                required = value
            } else {
                required = false
            }
            definitions.append(TemplateInputDefinition(name: rawName, description: rawDescription, required: required))
        }
        if let problem = TemplateInputValidation.validateDefinitions(definitions) {
            return .failure(problem)
        }
        return .success(definitions)
    }
}
