import Foundation

/// Lists installed `.app` bundles, optionally filtering by query and/or
/// only-AppleScript-scriptable apps. Returns a compact summary per app
/// (name, bundle ID, version, suite names) — NOT the full schema. Use
/// `get_app_scripting_schema` to fetch a single app's schema before
/// trying to script it.
struct ListScriptableAppsTool: AgentTool {
    let name = "list_scriptable_apps"

    let toolDescription = """
        List applications installed on this Mac. Returns a compact summary per app: \
        name, bundle ID, version, and (if the app supports AppleScript) the names of its scripting suites. \
        Does NOT return the full scripting schema — call `get_app_scripting_schema` for that, once you've \
        identified an app you want to script.

        Arguments:
        - `query` (optional): substring filter, matched case-insensitively against app name and bundle ID. \
          Omit to see everything.
        - `scriptable_only` (default true): when true, hides apps that aren't AppleScript-scriptable at all.
        - `non_standard_only` (default true): when true, additionally hides scriptable apps that only expose \
          the Standard Suite (open/close/quit/count/etc.) — those are technically scriptable but rarely worth \
          targeting. Set false to include them.

        Use this tool BEFORE `get_app_scripting_schema` whenever you don't already know an app's bundle ID. \
        Bundle IDs are the most reliable identifier — prefer them over names when calling other tools.
        """

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                BrownBehavior.approvalGateNote(outcome: "the app list")
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "query": .dictionary([
                "type": .string("string"),
                "description": .string("Optional case-insensitive substring filter against app name and bundle ID.")
            ]),
            "scriptable_only": .dictionary([
                "type": .string("boolean"),
                "description": .string("When true (default), hide non-scriptable apps.")
            ]),
            "non_standard_only": .dictionary([
                "type": .string("boolean"),
                "description": .string("When true (default), hide apps that only expose the Standard Suite.")
            ])
        ]),
        "required": .array([])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        let query: String? = {
            if case .string(let q) = arguments["query"], !q.isEmpty { return q }
            return nil
        }()
        let scriptableOnly = boolArg(arguments["scriptable_only"], default: true)
        let nonStandardOnly = boolArg(arguments["non_standard_only"], default: true)

        let registry = InstalledApplicationsRegistry.shared
        let apps: [InstalledApplication]
        if let query {
            apps = await registry.find(matching: query)
        } else {
            apps = await registry.all()
        }

        let filtered = apps.filter { app in
            if scriptableOnly && app.scripting == nil { return false }
            if nonStandardOnly && app.scripting?.exposesNonStandardSuite != true { return false }
            return true
        }

        if filtered.isEmpty {
            return .success("No matching applications found.")
        }

        var lines: [String] = ["Found \(filtered.count) application(s):"]
        for app in filtered {
            let name = app.url.deletingPathExtension().lastPathComponent
            let bid = app.bundleIdentifier ?? "(no bundle id)"
            let ver = app.version ?? "?"
            var line = "- \(name) [\(bid)] v\(ver)"
            if let s = app.scripting {
                line += "  scriptable=yes; suites: \(s.suiteNames.joined(separator: ", "))"
            } else {
                line += "  scriptable=no"
            }
            lines.append(line)
        }
        return .success(lines.joined(separator: "\n"))
    }

    private func boolArg(_ value: AnyCodable?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        if case .bool(let b) = value { return b }
        return defaultValue
    }
}
