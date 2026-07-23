import Foundation

public enum TemplateStringRenderResult: Sendable, Equatable {
    /// The rendered template text.
    case success(String)
    /// A validation or rendering error explaining why the template could not be rendered.
    case failure(String)
}

/// Renders small user-facing templates with `{{input_name}}` placeholders.
public enum TemplateStringRenderer {
    /// Replaces each placeholder with its resolved input value.
    ///
    /// A placeholder naming a DEFINED input that simply wasn't supplied for this run renders as
    /// an empty string rather than failing. `validate` accepts any defined name — required or
    /// not — so failing here would let a purely cosmetic title veto the run it names: a template
    /// titled `Localize {{app}} ({{locale}})` with `locale` marked optional could never run
    /// without a locale. Only a placeholder naming an input that does not exist at all is an
    /// error, and `validate` should already have caught that at authoring time.
    ///
    /// Because empty substitution leaves gaps behind, runs of whitespace are collapsed and the
    /// result is trimmed. Literal punctuation around an omitted placeholder is left alone — it
    /// is the author's own text, and guessing at which brackets to elide would mangle titles
    /// that meant to keep them.
    public static func render(
        _ template: String,
        values: [String: String],
        definedNames: Set<String>
    ) -> TemplateStringRenderResult {
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
            guard definedNames.contains(name) else {
                return .failure("Unknown template placeholder '{{\(name)}}'. Valid inputs: \(definedNames.sorted().joined(separator: ", ")).")
            }
            output += values[name] ?? ""
            index = closeRange.upperBound
        }
        return .success(collapsingWhitespace(output))
    }

    /// Collapses runs of whitespace to a single space and trims, so an omitted optional input
    /// doesn't leave a double space or a trailing gap in the rendered title.
    private static func collapsingWhitespace(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
