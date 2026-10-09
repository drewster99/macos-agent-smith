import Foundation

/// The wire shape of a task's preconditions (#18), shared by `create_task` and `set_preconditions` so
/// the two can't drift: an array of `{kind, value, failure_message?, id?}`.
enum PreconditionArguments {
    /// The authored kinds, as the tools name them.
    enum KindName: String, CaseIterable {
        case fileExists = "file_exists"
        case commandAvailable = "command_available"
        case workerModelSupports = "worker_model_supports"
        case workerChecked = "worker_checked"
    }

    static let arraySchema: AnyCodable = .dictionary([
        "type": .string("array"),
        "items": .dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "kind": .dictionary([
                    "type": .string("string"),
                    "enum": .array(KindName.allCases.map { .string($0.rawValue) }),
                    "description": .string("""
                        What must hold before the task is worth running. file_exists: `value` is an absolute \
                        (or ~/) path. command_available: `value` is one command name, looked up on the \
                        worker's PATH. worker_model_supports: `value` is vision or pdf. worker_checked: \
                        `value` is a statement only the worker can verify — it reports it false with \
                        report_precondition_unmet.
                        """)
                ]),
                "value": .dictionary([
                    "type": .string("string"),
                    "description": .string("The path, command, capability (vision / pdf), or statement.")
                ]),
                "failure_message": .dictionary([
                    "type": .string("string"),
                    "description": .string("Optional: what the user should know or do if it doesn't hold.")
                ]),
                "id": .dictionary([
                    "type": .string("string"),
                    "description": .string("set_preconditions only: the id of an EXISTING precondition to keep (from get_task_details). Omit for a new one.")
                ])
            ]),
            "required": .array([.string("kind"), .string("value")])
        ])
    ])

    /// Parses an authored list. An item naming an `id` keeps that existing precondition's identity and
    /// author (so a user's precondition stays the user's); an item without one is new, authored by
    /// `origin`. Checking what each one says is the store's job (`TaskStore.setPreconditions`).
    static func parse(_ value: AnyCodable, origin: TaskAuthorship, existing: [TaskPrecondition]) -> Result<[TaskPrecondition], PreconditionAuthoringProblem> {
        guard case .array(let items) = value else {
            return .failure(PreconditionAuthoringProblem("preconditions must be an array of {kind, value} objects."))
        }
        var parsed: [TaskPrecondition] = []
        for (index, item) in items.enumerated() {
            let position = index + 1
            guard case .dictionary(let fields) = item else {
                return .failure(PreconditionAuthoringProblem("Precondition \(position) must be an object with `kind` and `value`."))
            }
            guard case .string(let rawKind)? = fields["kind"], let kindName = KindName(rawValue: rawKind) else {
                return .failure(PreconditionAuthoringProblem("Precondition \(position): `kind` must be one of \(KindName.allCases.map(\.rawValue).joined(separator: ", "))."))
            }
            guard case .string(let rawValue)? = fields["value"],
                  !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(PreconditionAuthoringProblem("Precondition \(position): `value` is required."))
            }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: TaskPrecondition.Kind
            switch kindName {
            case .fileExists: kind = .fileExists(path: value)
            case .commandAvailable: kind = .commandAvailable(name: value)
            case .workerChecked: kind = .workerAttested(statement: value)
            case .workerModelSupports:
                guard let capability = TaskPrecondition.WorkerModelCapability(rawValue: value.lowercased()) else {
                    return .failure(PreconditionAuthoringProblem("Precondition \(position): worker_model_supports takes vision or pdf, not '\(value)'."))
                }
                kind = .workerModelSupports(capability)
            }
            let failureMessage = ToolArguments.optionalString(fields, "failure_message")
            switch ToolArguments.optionalUUID(fields, "id") {
            case .absent:
                parsed.append(TaskPrecondition(kind: kind, failureMessage: failureMessage, origin: origin))
            case .value(let id):
                guard !parsed.contains(where: { $0.id == id }) else {
                    return .failure(PreconditionAuthoringProblem("Precondition \(position): id \(id.uuidString) is listed twice."))
                }
                guard let kept = existing.first(where: { $0.id == id }) else {
                    return .failure(PreconditionAuthoringProblem("Precondition \(position): no existing precondition has id \(id.uuidString)."))
                }
                parsed.append(TaskPrecondition(id: id, kind: kind, failureMessage: failureMessage, origin: kept.origin))
            case .malformed(let raw):
                return .failure(PreconditionAuthoringProblem("Precondition \(position): '\(raw)' is not a precondition id."))
            }
        }
        return .success(parsed)
    }
}
