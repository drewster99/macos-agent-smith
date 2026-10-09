import Foundation

/// Something that must be true for a task to be worth running at all (#18; ROADMAP "First-class task
/// preconditions"). A task whose premise is false — the file to fix doesn't exist, the tool it needs
/// isn't installed, the worker's model can't see images — would otherwise run its whole worker loop
/// and spend validation rounds before failing for a reason nobody named. An unmet precondition ends
/// the task at once as BLOCKED (`AgentTask.preconditionFailure`), which is not a validation failure.
///
/// A precondition is never an acceptance criterion: a criterion judges the RESULT, a precondition
/// gates the START.
public struct TaskPrecondition: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var kind: Kind
    /// What the user should be told if it doesn't hold — why it matters, or what to do about it.
    /// Optional: the kind's own description says WHAT failed.
    public var failureMessage: String?
    /// Who set it. Only the user may remove or change a user-authored precondition.
    public var origin: TaskAuthorship

    public init(id: UUID = UUID(), kind: Kind, failureMessage: String? = nil, origin: TaskAuthorship) {
        self.id = id
        self.kind = kind
        self.failureMessage = failureMessage
        self.origin = origin
    }

    /// What must hold. The first three are checked by the runtime itself before a worker starts; a
    /// `workerAttested` one can only be judged by the worker, which reports it false with
    /// `report_precondition_unmet`.
    public enum Kind: Codable, Sendable, Equatable {
        /// The worker's model can take images or PDFs.
        case workerModelSupports(WorkerModelCapability)
        /// A file or directory exists at an absolute (or `~/`) path.
        case fileExists(path: String)
        /// A command can be found on the worker's login-shell PATH.
        case commandAvailable(name: String)
        /// A fact only the worker can check ("the staging database has the fixture loaded").
        case workerAttested(statement: String)
        /// A kind this build doesn't know (written by a newer one). Never silently passed: it reads
        /// as unmet, so a gate a newer build set can't be skipped by an older one. Its whole encoded
        /// form is kept and written back unchanged, so this build can't corrupt it.
        case unknown(type: String, encoded: [String: AnyCodable])

        /// Whether the runtime checks this before a worker starts.
        public var isCheckedAtStart: Bool {
            switch self {
            case .workerModelSupports, .fileExists, .commandAvailable, .unknown: return true
            case .workerAttested: return false
            }
        }

        /// One line saying what must hold.
        public var summary: String {
            switch self {
            case .workerModelSupports(let capability): return "the worker's model can read \(capability.displayName)"
            case .fileExists(let path): return "\(path) exists"
            case .commandAvailable(let name): return "the command `\(name)` is available"
            case .workerAttested(let statement): return statement
            case .unknown(let type, _): return "a precondition of a kind this version doesn't know (\(type))"
            }
        }

        private enum CodingKeys: String, CodingKey { case type, capability, path, name, statement }
        private enum TypeName: String { case workerModelSupports, fileExists, commandAvailable, workerAttested }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try c.decode(String.self, forKey: .type)
            func unknown() throws -> Kind {
                .unknown(type: raw, encoded: try decoder.singleValueContainer().decode([String: AnyCodable].self))
            }
            switch TypeName(rawValue: raw) {
            case .workerModelSupports:
                // A capability this build doesn't know is unknown, not a crash and not a pass.
                let capabilityRaw = try c.decode(String.self, forKey: .capability)
                guard let capability = WorkerModelCapability(rawValue: capabilityRaw) else {
                    self = try unknown()
                    return
                }
                self = .workerModelSupports(capability)
            case .fileExists: self = .fileExists(path: try c.decode(String.self, forKey: .path))
            case .commandAvailable: self = .commandAvailable(name: try c.decode(String.self, forKey: .name))
            case .workerAttested: self = .workerAttested(statement: try c.decode(String.self, forKey: .statement))
            case nil: self = try unknown()
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .workerModelSupports(let capability):
                try c.encode(TypeName.workerModelSupports.rawValue, forKey: .type)
                try c.encode(capability.rawValue, forKey: .capability)
            case .fileExists(let path):
                try c.encode(TypeName.fileExists.rawValue, forKey: .type)
                try c.encode(path, forKey: .path)
            case .commandAvailable(let name):
                try c.encode(TypeName.commandAvailable.rawValue, forKey: .type)
                try c.encode(name, forKey: .name)
            case .workerAttested(let statement):
                try c.encode(TypeName.workerAttested.rawValue, forKey: .type)
                try c.encode(statement, forKey: .statement)
            case .unknown(_, let encoded):
                // Written back exactly as it was read, so a round trip through this build loses nothing.
                var single = encoder.singleValueContainer()
                try single.encode(encoded)
            }
        }
    }

    public enum WorkerModelCapability: String, Codable, Sendable, CaseIterable {
        case vision
        case pdf

        public var displayName: String {
            switch self {
            case .vision: return "images"
            case .pdf: return "PDFs"
            }
        }
    }

    /// A copy for another task — a template's run, or a clone — with a fresh id (a block record names
    /// its own task's precondition) and every authored text passed through `transform` (a run fills
    /// in its template input values).
    public func copied(transformingText transform: (String) -> String = { $0 }) -> TaskPrecondition {
        let copiedKind: Kind
        switch kind {
        case .fileExists(let path): copiedKind = .fileExists(path: transform(path))
        case .commandAvailable(let name): copiedKind = .commandAvailable(name: transform(name))
        case .workerAttested(let statement): copiedKind = .workerAttested(statement: transform(statement))
        case .workerModelSupports, .unknown: copiedKind = kind
        }
        return TaskPrecondition(kind: copiedKind, failureMessage: failureMessage.map(transform), origin: origin)
    }

    /// Why an authored precondition can't be accepted, or nil when it can. A relative path or a
    /// `~user` path would resolve against whatever the process's directory happens to be; a command
    /// name must be a single word, since it is looked up, never run.
    public static func authoringProblem(in kind: Kind) -> String? {
        switch kind {
        case .fileExists(let path):
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else {
                return "a file precondition needs an absolute path (starting with / or ~/), not '\(path)'"
            }
            return nil
        case .commandAvailable(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !trimmed.contains("/") else {
                return "a command precondition names one command (like `ffmpeg`), not '\(name)'"
            }
            return nil
        case .workerAttested(let statement):
            return statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "a worker-checked precondition needs a statement" : nil
        case .workerModelSupports:
            return nil
        case .unknown(let type, _):
            return "unknown precondition kind '\(type)'"
        }
    }
}

/// Why a task is BLOCKED: which precondition failed, how, and who found it. Stored on the task with
/// its `.failed` status (`AgentTask.preconditionFailure`) and cleared when the task leaves `.failed`.
public struct PreconditionFailureRecord: Codable, Sendable, Equatable {
    public enum CheckedBy: String, Codable, Sendable {
        /// The runtime's own check before a worker started.
        case startCheck
        /// The worker reported it false (`report_precondition_unmet`).
        case worker
    }

    public let preconditionID: UUID
    /// The precondition as it stood when it failed, so a later edit can't rewrite what blocked it.
    public let kind: TaskPrecondition.Kind
    public let failureMessage: String?
    /// What was found: the check's result, or the worker's evidence.
    public let detail: String
    public let checkedBy: CheckedBy
    public let at: Date

    public init(precondition: TaskPrecondition, detail: String, checkedBy: CheckedBy, at: Date = Date()) {
        self.preconditionID = precondition.id
        self.kind = precondition.kind
        self.failureMessage = precondition.failureMessage
        self.detail = detail
        self.checkedBy = checkedBy
        self.at = at
    }

    /// One line for the user and Smith: what didn't hold, what was found, and what to do.
    public var reason: String {
        var text = "precondition not met — \(kind.summary): \(detail)"
        if let failureMessage, !failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += " (\(failureMessage))"
        }
        return text
    }
}

/// Why an authored precondition list was refused, in words for whoever wrote it.
public struct PreconditionAuthoringProblem: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
