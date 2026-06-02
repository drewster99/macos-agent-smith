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
    /// Conservative cap honoured by both Anthropic and OpenAI tool-name validation.
    public static let maxNameLength = 64

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

    /// Builds the prefixed, sanitized, length-capped LLM tool name for a server/tool
    /// pair. When truncation is required, the tool component is trimmed first so the
    /// server namespace stays intact.
    public static func prefixedName(server: String, tool: String) -> String {
        let serverSlug = sanitizeComponent(server)
        let toolSlug = sanitizeComponent(tool)
        var name = "\(prefix)\(serverSlug)__\(toolSlug)"
        if name.count > maxNameLength {
            let overflow = name.count - maxNameLength
            let trimmedTool = String(toolSlug.dropLast(min(overflow, max(0, toolSlug.count - 1))))
            name = "\(prefix)\(serverSlug)__\(trimmedTool.isEmpty ? "x" : trimmedTool)"
            if name.count > maxNameLength {
                name = String(name.prefix(maxNameLength))
            }
        }
        return name
    }
}
