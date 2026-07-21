import Foundation

public enum TemplateStringRenderResult: Sendable, Equatable {
    /// The rendered template text.
    case success(String)
    /// A validation or rendering error explaining why the template could not be rendered.
    case failure(String)
}

/// Renders small user-facing templates with `{{input_name}}` placeholders.
public enum TemplateStringRenderer {
    /// Replaces each placeholder with the corresponding resolved input value.
    public static func render(_ template: String, values: [String: String]) -> TemplateStringRenderResult {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            guard let openRange = template[index...].range(of: "{{") else {
                output += template[index...]
                break
            }
            output += template[index..<openRange.lowerBound]
            guard let closeRange = template[openRange.upperBound...].range(of: "}}") else {
                return .failure("Unclosed template placeholder in '\(template)'.")
            }
            let rawName = String(template[openRange.upperBound..<closeRange.lowerBound])
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, rawName == name, TemplateInputValidation.isValidName(name) else {
                return .failure("Invalid template placeholder '{{\(rawName)}}'. Names must match ^[a-z][a-z0-9_]*$.")
            }
            guard let value = values[name] else {
                return .failure("Unknown template placeholder '{{\(name)}}'.")
            }
            output += value
            index = closeRange.upperBound
        }
        return .success(output)
    }

    /// Returns a validation problem when the template references invalid or unknown placeholders.
    public static func validate(_ template: String, allowedNames: Set<String>) -> String? {
        var index = template.startIndex
        while index < template.endIndex {
            guard let openRange = template[index...].range(of: "{{") else { return nil }
            guard let closeRange = template[openRange.upperBound...].range(of: "}}") else {
                return "Unclosed template placeholder in '\(template)'."
            }
            let rawName = String(template[openRange.upperBound..<closeRange.lowerBound])
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, rawName == name, TemplateInputValidation.isValidName(name) else {
                return "Invalid template placeholder '{{\(rawName)}}'. Names must match ^[a-z][a-z0-9_]*$."
            }
            guard allowedNames.contains(name) else {
                return "Unknown template placeholder '{{\(name)}}'. Valid inputs: \(allowedNames.sorted().joined(separator: ", "))."
            }
            index = closeRange.upperBound
        }
        return nil
    }
}
