import Foundation

/// What a start-time precondition check can see. Injected so the checks are testable without the
/// real file system, shell, or a model.
public struct PreconditionEnvironment: Sendable {
    /// Whether the worker's model can read `capability`: nil when the worker role has no model.
    public let workerModelSupports: @Sendable (TaskPrecondition.WorkerModelCapability) -> Bool?
    public let pathExists: @Sendable (String) -> Bool
    public let lookUpCommand: @Sendable (String) async -> CommandLookup

    public init(
        workerModelSupports: @escaping @Sendable (TaskPrecondition.WorkerModelCapability) -> Bool?,
        pathExists: @escaping @Sendable (String) -> Bool,
        lookUpCommand: @escaping @Sendable (String) async -> CommandLookup
    ) {
        self.workerModelSupports = workerModelSupports
        self.pathExists = pathExists
        self.lookUpCommand = lookUpCommand
    }

    public enum CommandLookup: Sendable, Equatable {
        case found(path: String)
        case notFound
        /// The lookup itself failed (timed out, couldn't run): the command's presence is unknown.
        case failed(String)
    }

    /// The real environment: the file system, and the worker's own login shell for commands —
    /// the PATH `bash` gets, which differs from the app's.
    public static func live(workerModelSupports: @escaping @Sendable (TaskPrecondition.WorkerModelCapability) -> Bool?) -> PreconditionEnvironment {
        PreconditionEnvironment(
            workerModelSupports: workerModelSupports,
            pathExists: { path in
                FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
            },
            lookUpCommand: { name in await lookUpInLoginShell(name) }
        )
    }

    /// Seconds a command lookup may take before its precondition counts as unmet.
    static let commandLookupTimeout: TimeInterval = 10

    /// `command -v` in a login shell, with the name passed as `$1` — never spliced into the script, so
    /// an authored name can't run anything.
    static func lookUpInLoginShell(_ name: String) async -> CommandLookup {
        do {
            let result = try await ProcessRunner.run(
                executable: "/bin/bash",
                arguments: ["-l", "-c", #"command -v -- "$1""#, "agent-smith-precondition", name],
                workingDirectory: nil,
                timeout: commandLookupTimeout
            )
            if result.timedOut { return .failed("the lookup timed out after \(Int(commandLookupTimeout))s") }
            let found = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.exitCode == 0 && !found.isEmpty ? .found(path: found) : .notFound
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// The ONE check of a task's preconditions, run before every worker start (#18). Every spawn site
/// reaches it through `OrchestrationRuntime.performSpawnBrown`, so no start can skip it.
public enum PreconditionEvaluator {
    /// The first start-checked precondition that doesn't hold, as the record that blocks the task;
    /// nil when every one holds. A `workerAttested` precondition is the worker's to judge and is
    /// skipped here. Fails closed: a kind this build doesn't know, a worker role with no model, and a
    /// command lookup that couldn't finish all count as unmet.
    public static func firstUnmet(_ preconditions: [TaskPrecondition], in environment: PreconditionEnvironment) async -> PreconditionFailureRecord? {
        for precondition in preconditions {
            if let detail = await unmetDetail(precondition.kind, in: environment) {
                return PreconditionFailureRecord(precondition: precondition, detail: detail, checkedBy: .startCheck)
            }
        }
        return nil
    }

    /// Why `kind` doesn't hold, or nil when it does (or isn't checked at start).
    public static func unmetDetail(_ kind: TaskPrecondition.Kind, in environment: PreconditionEnvironment) async -> String? {
        switch kind {
        case .workerModelSupports(let capability):
            switch environment.workerModelSupports(capability) {
            case true?: return nil
            case false?: return "the worker's model can't read \(capability.displayName)"
            case nil: return "no model is assigned to the worker role"
            }
        case .fileExists(let path):
            return environment.pathExists(path) ? nil : "nothing exists at \(path)"
        case .commandAvailable(let name):
            switch await environment.lookUpCommand(name) {
            case .found: return nil
            case .notFound: return "`\(name)` was not found on the worker's PATH"
            case .failed(let why): return "couldn't check for `\(name)`: \(why)"
            }
        case .workerAttested:
            return nil
        case .unknown(let type, _):
            return "this version can't check a precondition of kind '\(type)'"
        }
    }
}

/// What the runtime did with a worker's precondition report.
public enum PreconditionReportOutcome: Sendable, Equatable {
    /// The task is blocked; the worker stops.
    case blocked(reason: String)
    /// Not accepted; the text says why and what to do instead.
    case refused(String)
}
