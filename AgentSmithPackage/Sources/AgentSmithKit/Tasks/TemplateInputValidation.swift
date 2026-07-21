import Foundation

enum TemplateInputValidation {
    struct ResolvedInputs: Sendable, Equatable {
        var values: [String: String]
        var missingRequiredNames: [String]
    }

    enum ResolutionResult: Sendable, Equatable {
        case success(ResolvedInputs)
        case failure(String)
    }

    static func validateDefinitions(_ definitions: [TemplateInputDefinition]) -> String? {
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

    static func resolveValues(
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

    private static func isValidName(_ name: String) -> Bool {
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
