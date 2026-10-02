import Foundation

/// Builds and validates the LLM-facing names for MCP tools.
///
/// Providers constrain tool names to `[A-Za-z0-9_-]` with a length cap (Anthropic
/// and OpenAI both cap at 64). MCP servers, by contrast, may expose tools with
/// arbitrary names. This namespaces every MCP tool as `mcp__<server>__<tool>`,
/// sanitizing each component to the allowed charset and truncating to fit, so
/// that MCP tools never collide with built-ins or with each other across servers.
public enum MCPToolNaming {
    public static let prefix = "mcp__"
    /// Separates the server slug from the tool part. `sanitizeComponent` collapses runs of `_` and a
    /// truncated slug is re-trimmed, so the first `__` after `prefix` is always this separator.
    public static let serverToolSeparator = "__"
    /// Conservative cap honoured by both Anthropic and OpenAI tool-name validation.
    public static let maxNameLength = 64
    /// Fewest tool characters a long server name may leave. Without a floor, a long server name cut
    /// every one of its tools down to one character and they all collided.
    static let minimumToolPartLength = 8
    /// Longest server slug kept in a name. Leaves `minimumToolPartLength` for the tool, and is short
    /// enough that a tool's base name and every disambiguated form below a seven-digit ordinal carry
    /// the SAME slug, so `components(of:)` groups them under one server.
    static let maxServerSlugLength = maxNameLength - prefix.count - serverToolSeparator.count - minimumToolPartLength

    /// Replaces any character outside `[A-Za-z0-9_-]` with `_`, collapses runs of
    /// `_`, and trims leading/trailing separators. Returns `"x"` for an empty result
    /// so the component is never blank.
    public static func sanitizeComponent(_ raw: String) -> String {
        var out = ""
        var lastWasUnderscore = false
        for ch in raw {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-") {
                out.append(ch)
                lastWasUnderscore = false
            } else {
                if !lastWasUnderscore { out.append("_") }
                lastWasUnderscore = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return trimmed.isEmpty ? "x" : trimmed
    }

    /// Builds the prefixed, sanitized, length-capped LLM tool name for a server/tool pair. The server
    /// slug is capped first so the separator and part of the tool name always survive truncation.
    public static func prefixedName(server: String, tool: String) -> String {
        composeName(server: server, tool: tool, suffix: "")
    }

    /// The name for a tool whose base name is already taken. Composed from the raw parts rather than
    /// appended to the base name: the base can already be `maxNameLength` long, and appending `_2` to it
    /// produced a name providers reject on every request.
    static func prefixedName(server: String, tool: String, disambiguationOrdinal ordinal: Int) -> String {
        precondition(ordinal >= 2, "Disambiguation ordinals start at 2; the undecorated name is ordinal 1.")
        return composeName(server: server, tool: tool, suffix: "_\(ordinal)")
    }

    private static func composeName(server: String, tool: String, suffix: String) -> String {
        // The second bound keeps one tool character beside an extreme suffix; below a seven-digit
        // ordinal it is looser than `maxServerSlugLength`, so the slug does not move.
        let serverSlugLimit = min(
            maxServerSlugLength,
            maxNameLength - prefix.count - serverToolSeparator.count - 1 - suffix.count
        )
        let namespace = prefix + serverSlug(server, limit: serverSlugLimit) + serverToolSeparator
        let toolPartLimit = maxNameLength - namespace.count - suffix.count
        // The tool part is deliberately not re-trimmed: names that already fit stay byte-identical
        // (persisted tool policies are keyed by them), and a trailing `_` here cannot move the split,
        // because the separator precedes it.
        return namespace + String(sanitizeComponent(tool).prefix(toolPartLimit)) + suffix
    }

    private static func serverSlug(_ server: String, limit: Int) -> String {
        let slug = sanitizeComponent(server)
        guard slug.count > limit else { return slug }
        // A cut can end on `_`, which would fuse with the separator and move where `components(of:)`
        // splits. The sanitized slug starts with an alphanumeric, so the result is never empty.
        return String(slug.prefix(limit)).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }

    /// The inverse of `prefixedName`: the server slug and the tool part of a name this type built,
    /// or nil for anything else (a built-in, or any name not built here).
    ///
    /// Exact rather than heuristic because the format is ours: `sanitizeComponent` collapses every
    /// run of `_`, so a server slug can never contain `__`, and the FIRST `__` after the prefix is
    /// always the separator. The tool part keeps any disambiguation suffix (`_2`) — it is part of
    /// that tool's name.
    public static func components(of name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[..<separator.lowerBound])
        let tool = String(rest[separator.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }
}
