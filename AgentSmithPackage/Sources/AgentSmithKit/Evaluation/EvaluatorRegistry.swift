import Foundation
import os

/// Loads `EvaluatorDefinition`s from a directory of JSON files — the user-owned,
/// hot-loadable registry (`AppSupport/AgentSmith/evaluators/`). Malformed files become
/// visible error entries rather than being silently skipped: a definition must fail
/// when installed, not mid-task.
public struct EvaluatorRegistry: Sendable {

    /// A file that failed to load, kept for surfacing in Settings / error output.
    public struct LoadFailure: Sendable, Equatable {
        public let fileName: String
        public let problem: String
    }

    public let definitions: [String: EvaluatorDefinition]
    public let failures: [LoadFailure]

    private static let logger = Logger(subsystem: "com.agentsmith", category: "EvaluatorRegistry")

    /// Definitions of one kind, sorted by name — the selection surface for that kind
    /// (Smith only ever sees `.validator`).
    public func definitions(ofKind kind: EvaluatorDefinition.Kind) -> [EvaluatorDefinition] {
        definitions.values.filter { $0.kind == kind }.sorted { $0.name < $1.name }
    }

    public func definition(named name: String) -> EvaluatorDefinition? {
        definitions[name]
    }

    /// Loads every `*.json` in `directory`. Non-existent directory yields an empty
    /// registry (first launch before defaults are seeded). Duplicate names are a load
    /// failure for the later file (sorted order makes this deterministic).
    public static func load(from directory: URL) -> EvaluatorRegistry {
        var definitions: [String: EvaluatorDefinition] = [:]
        var failures: [LoadFailure] = []

        let files: [URL]
        do {
            files = try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return EvaluatorRegistry(definitions: [:], failures: [])
        }

        for file in files {
            let fileName = file.lastPathComponent
            do {
                let data = try Data(contentsOf: file)
                let definition = try JSONDecoder().decode(EvaluatorDefinition.self, from: data)
                let problems = definition.validationProblems()
                guard problems.isEmpty else {
                    failures.append(LoadFailure(fileName: fileName, problem: problems.joined(separator: "; ")))
                    continue
                }
                guard definitions[definition.name] == nil else {
                    failures.append(LoadFailure(fileName: fileName, problem: "duplicate definition name '\(definition.name)'"))
                    continue
                }
                definitions[definition.name] = definition
            } catch {
                failures.append(LoadFailure(fileName: fileName, problem: "decode failed: \(error.localizedDescription)"))
            }
        }

        for failure in failures {
            logger.error("Evaluator definition rejected: \(failure.fileName, privacy: .public) — \(failure.problem, privacy: .public)")
        }
        return EvaluatorRegistry(definitions: definitions, failures: failures)
    }
}
