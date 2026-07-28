import Foundation

public enum TemplateStringRenderResult: Sendable, Equatable {
    /// The rendered template text.
    case success(String)
    /// A validation or rendering error explaining why the template could not be rendered.
    case failure(String)
}

/// Renders small user-facing templates with `{{input_name}}` placeholders.
public enum TemplateStringRenderer {
    /// How a rendered string's whitespace is normalized.
    public enum Layout: Sendable, Equatable {
        /// Keep the author's line breaks and indentation byte-for-byte. Required for anything
        /// multi-line — a description, a step, or a validation prompt is markdown, and collapsing
        /// it would fuse the whole document onto a single line.
        case preserved
        /// Collapse runs of whitespace to a single space and trim. For titles, where an omitted
        /// optional input would otherwise leave a visible double space or a trailing gap.
        case singleLine
    }

    /// Substitutes ONLY the placeholders naming a defined input, and leaves every other `{{…}}`
    /// exactly as the author wrote it — unclosed braces, invalid names, and names that match no
    /// definition all pass through verbatim.
    ///
    /// This is the renderer for a template's authored BODY text (description, step text,
    /// acceptance-criterion fields), and its leniency is the point. That text is prose that may
    /// legitimately quote brace syntax — a task about a Handlebars partial, a JSON schema, a shell
    /// expansion — and failing the render would make such a template impossible to run at all.
    /// Passing the text through degrades to exactly the pre-substitution behavior, which is a
    /// worker reading a literal `{{foo}}`; failing would be a template that cannot execute.
    ///
    /// A placeholder naming a DEFINED input that simply wasn't supplied renders as an empty
    /// string, for the same reason `render` does it — an optional input left blank must not
    /// veto the run.
    ///
    /// Leniency here is paired with an authoring-time check, not a substitute for one:
    /// `TemplateInputValidation.placeholderProblem(in:field:definedNames:)` rejects an unknown
    /// placeholder when the text is WRITTEN, so a typo (`{{app_nmae}}`) surfaces against the
    /// author who can fix it rather than against the worker who can't.
    public static func renderSubstitutingDefinedPlaceholders(
        _ template: String,
        values: [String: String],
        definedNames: Set<String>,
        layout: Layout
    ) -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            guard let openRange = template[index...].range(of: "{{") else {
                output += template[index...]
                break
            }
            output += template[index..<openRange.lowerBound]
            guard let substitution = definedSubstitution(
                at: openRange.upperBound,
                in: template,
                values: values,
                definedNames: definedNames
            ) else {
                // Not a placeholder we own. Emit the braces literally and resume scanning from
                // just after them rather than from after the closing `}}` — the skipped span may
                // itself contain a placeholder that IS ours (`{{ {{app_name}} }}`), and consuming
                // it wholesale would swallow one.
                output += "{{"
                index = openRange.upperBound
                continue
            }
            output += substitution.value
            index = substitution.continuationIndex
        }
        switch layout {
        case .preserved: return output
        case .singleLine: return collapsingWhitespace(output)
        }
    }

    /// The resolved value for a placeholder starting just after an opening `{{`, or nil when the
    /// span is not a placeholder naming a defined input.
    private static func definedSubstitution(
        at nameStart: String.Index,
        in template: String,
        values: [String: String],
        definedNames: Set<String>
    ) -> (value: String, continuationIndex: String.Index)? {
        guard let closeRange = template[nameStart...].range(of: "}}") else { return nil }
        let rawName = String(template[nameStart..<closeRange.lowerBound])
        guard TemplateInputValidation.isValidName(rawName), definedNames.contains(rawName) else { return nil }
        return (values[rawName] ?? "", closeRange.upperBound)
    }

    /// Replaces each placeholder with its resolved input value, failing on anything that is not
    /// one.
    ///
    /// For `templateInstanceTitleTemplate` — a deliberate PATTERN string whose entire purpose is
    /// its placeholders, and which is validated against the input definitions at authoring time in
    /// every path that can write one. An unknown name there is an authoring mistake with no
    /// innocent reading, so it is an error rather than literal text. Authored body prose is the
    /// opposite case and uses `renderSubstitutingDefinedPlaceholders` instead.
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
