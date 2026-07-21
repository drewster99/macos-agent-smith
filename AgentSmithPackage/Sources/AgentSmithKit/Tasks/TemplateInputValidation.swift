import Foundation

public enum TemplateInputValidation {
    public struct ResolvedInputs: Sendable, Equatable {
        /// Resolved, trimmed input values keyed by template input name.
        public var values: [String: String]
        /// Required input names that were not provided with non-empty values.
        public var missingRequiredNames: [String]
    }

    public enum ResolutionResult: Sendable, Equatable {
        /// Resolved input values and any missing required input names.
        case success(ResolvedInputs)
        /// A validation problem that prevents using the provided input values.
        case failure(String)
    }

    /// Validates template input definitions before they are stored on a task.
    public static func validateDefinitions(_ definitions: [TemplateInputDefinition]) -> String? {
        var seen = Set<String>()
        for definition in definitions {
            let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == definition.name, isValidName(name) else {
                return "Invalid template input name '\(definition.name)'. Names must match ^[a-z][a-z0-9_]*$."
            }
            guard seen.insert(name).inserted else {
                return "Duplicate template input name '\(name)'."
            }
            guard !definition.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Template input '\(name)' requires a non-empty description."
            }
        }
        return nil
    }

    /// Resolves raw user-provided values against the template input definitions.
    public static func resolveValues(
        definitions: [TemplateInputDefinition],
        rawValues: [String: String]
    ) -> ResolutionResult {
        let knownNames = Set(definitions.map(\.name))
        let unknownNames = rawValues.keys.filter { !knownNames.contains($0) }.sorted()
        guard unknownNames.isEmpty else {
            return .failure("Unknown template input(s): \(unknownNames.joined(separator: ", ")). Valid inputs: \(definitions.map(\.name).sorted().joined(separator: ", ")).")
        }

        var normalizedValues: [String: String] = [:]
        for (name, value) in rawValues {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                normalizedValues[name] = trimmed
            }
        }

        let missing = definitions
            .filter { $0.required && normalizedValues[$0.name] == nil }
            .map(\.name)
            .sorted()

        return .success(ResolvedInputs(values: normalizedValues, missingRequiredNames: missing))
    }

    /// Returns whether a template input or placeholder name uses the supported identifier format.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isLowercaseLetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            isLowercaseLetter(scalar) || isDigit(scalar) || scalar == "_"
        }
    }

    private static func isLowercaseLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= Unicode.Scalar("a").value && scalar.value <= Unicode.Scalar("z").value
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= Unicode.Scalar("0").value && scalar.value <= Unicode.Scalar("9").value
    }
}
