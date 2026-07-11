import Foundation

/// Smith's authoring surface for persistent custom evaluators: acceptance validators
/// (judge one criterion) and prepare functions (enumerate the items a dynamic criterion
/// judges one by one). Smith writes only the JUDGMENT or ENUMERATION prompt; the system
/// supplies the contract — output grammar, standard input slots, the read-only evidence
/// toolset, and limits — so an authored evaluator cannot grant itself capabilities.
/// Definitions land in the session's registry and are referenced by name from
/// `set_acceptance_criteria` / `create_task`.
public struct DefineValidatorTool: AgentTool {
    public let name = "define_validator"
    public let toolDescription = """
        Define a reusable custom evaluator in the registry, then reference it by name in \
        acceptance criteria. Two kinds: \
        `validator` — judges ONE criterion against the submitted work (your prompt states what \
        to check and how strictly; the ACCEPT/REJECT/WAIVE response format is appended \
        automatically). A validator referenced by a criterion's `prepare` automatically \
        receives each enumerated item to judge — no flag needed. \
        `prepare` — enumerates the ITEMS a dynamic criterion should judge one by one (e.g. \
        every file in a folder, every step in the plan; your prompt states what to enumerate; \
        the JSON-array response format is appended automatically). \
        \
        Both receive the task's standard context (description, steps, worker activity, result, \
        criterion text) and hold read-only evidence tools (file_read, directory_listing, grep, \
        glob) — nothing more. Use with `set_acceptance_criteria`: `validator_name: "<name>"` \
        and/or `prepare: "<name>"` on a criterion. For a one-off check that doesn't deserve a \
        registry entry, use `inline_validator` on the criterion instead.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "name": .dictionary([
                "type": .string("string"),
                "description": .string("Registry name, kebab-case (lowercase letters, digits, hyphens), e.g. 'swift-file-header-check'. Referenced from criteria by this name.")
            ]),
            "kind": .dictionary([
                "type": .string("string"),
                "enum": .array([.string("validator"), .string("prepare")]),
                "description": .string("`validator` judges one criterion; `prepare` enumerates items for a dynamic criterion.")
            ]),
            "description": .dictionary([
                "type": .string("string"),
                "description": .string("When to use this evaluator — shown in list_validators and used to pick validators for future tasks.")
            ]),
            "system_prompt": .dictionary([
                "type": .string("string"),
                "description": .string("The judgment (or enumeration) instructions: what to check, how strictly, what evidence to gather. Do NOT restate the output format — the system appends the exact response contract, the JSON input description, and the criterion automatically.")
            ]),
            "overwrite": .dictionary([
                "type": .string("boolean"),
                "description": .string("Replace an existing definition with this name. Default false — existing definitions (including user-authored ones) are never silently replaced.")
            ])
        ]),
        "required": .array([.string("name"), .string("kind"), .string("description"), .string("system_prompt")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let name) = arguments["name"] else {
            return .failure("Missing required argument 'name' (kebab-case registry name).")
        }
        guard case .string(let kindRaw) = arguments["kind"], let kind = Self.kind(from: kindRaw) else {
            return .failure("Missing or invalid 'kind' — must be 'validator' or 'prepare'.")
        }
        guard case .string(let description) = arguments["description"], !description.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure("Missing required argument 'description' — say when this evaluator should be used.")
        }
        guard case .string(let systemPrompt) = arguments["system_prompt"] else {
            return .failure("Missing required argument 'system_prompt' — the judgment/enumeration instructions.")
        }
        var overwrite = false
        if case .bool(let flag) = arguments["overwrite"] { overwrite = flag }

        let definition: EvaluatorDefinition
        switch EvaluatorDefaults.makeCustomDefinition(
            name: name,
            description: description,
            kind: kind,
            authoredPrompt: systemPrompt
        ) {
        case .success(let built):
            definition = built
        case .failure(let problem):
            return .failure("Cannot define '\(name)': \(problem.message)")
        }

        if let refusal = await context.saveEvaluatorDefinition(definition, overwrite) {
            return .failure("Cannot define '\(name)': \(refusal)")
        }

        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            content: "Defined \(kindRaw) \"\(definition.name)\": \(definition.description)",
            metadata: ["messageKind": .string("validator_defined")]
        ))

        let usage = kind == .validator
            ? "Reference it from a criterion: `validator_name: \"\(definition.name)\"` (optionally alongside a `prepare` function, which feeds it each enumerated item)."
            : "Reference it from a criterion: `prepare: \"\(definition.name)\"` (pair with a `validator_name`, or the default)."
        return .success("Defined \(kindRaw) '\(definition.name)' in the registry. \(usage)")
    }

    private static func kind(from raw: String) -> EvaluatorDefinition.Kind? {
        switch raw {
        case "validator": return .validator
        case "prepare": return .prepare
        default: return nil
        }
    }
}
