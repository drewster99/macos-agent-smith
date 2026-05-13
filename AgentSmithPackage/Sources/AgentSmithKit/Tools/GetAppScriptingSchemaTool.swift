import Foundation

/// Returns the AppleScript scripting schema for one installed app, rendered
/// as compact, parseable text. Read this BEFORE writing any AppleScript for
/// the app — it lists every command, class, property, element, parameter, and
/// enumerator the app exposes.
struct GetAppScriptingSchemaTool: AgentTool {
    let name = "get_app_scripting_schema"

    let toolDescription = """
        Return the AppleScript scripting schema for one installed app, rendered as compact text. \
        Always read this BEFORE writing AppleScript for an app you haven't scripted before — it tells \
        you exactly which commands, classes, properties, elements, and enumerators the app exposes, \
        and the types of their parameters and return values.

        Identify the app by `bundle_id` (preferred — unambiguous, e.g. `com.apple.dt.Xcode`) or `app_name` \
        (fuzzy match, used only if bundle_id is omitted). Use `list_scriptable_apps` first if you don't \
        already have a bundle ID.

        The returned text begins with a one-line legend documenting the format. Briefly:
        - `SUITE name` — a group of related scripting features
        - `ENUM name` then indented `value — description` lines
        - `CLASS name [(extends X)]` followed by indented `PROP`, `ELEM`, and `RESPONDS` lines
          - `PROP name : type [access] — description` (access of `r` = read-only)
          - `ELEM type` — kinds of child elements addressable on this class
          - `RESPONDS cmd1, cmd2, ...` — the commands this class accepts
        - `CMD name(direct_param) → result` followed by indented `param[?][:type]` lines
          - `?` after a parameter name indicates it is optional
        """

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                BrownBehavior.approvalGateNote(outcome: "the app's scripting schema as text")
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "bundle_id": .dictionary([
                "type": .string("string"),
                "description": .string("Bundle identifier of the app (preferred). Example: com.apple.dt.Xcode.")
            ]),
            "app_name": .dictionary([
                "type": .string("string"),
                "description": .string("App name fallback when bundle_id is unknown (fuzzy match, case-insensitive).")
            ])
        ]),
        "required": .array([])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        let bundleID: String? = {
            if case .string(let s) = arguments["bundle_id"], !s.isEmpty { return s }
            return nil
        }()
        let appName: String? = {
            if case .string(let s) = arguments["app_name"], !s.isEmpty { return s }
            return nil
        }()

        guard bundleID != nil || appName != nil else {
            return .failure("Provide either bundle_id (preferred) or app_name.")
        }

        let registry = InstalledApplicationsRegistry.shared
        let app: InstalledApplication?
        if let bundleID {
            app = await registry.find(bundleID: bundleID)
        } else if let appName {
            app = await registry.find(matching: appName).first
        } else {
            app = nil
        }

        guard let app else {
            return .failure("No installed app matched bundle_id=\(bundleID ?? "nil") app_name=\(appName ?? "nil"). Use list_scriptable_apps to see available apps.")
        }

        guard let scripting = app.scripting else {
            return .failure("\(app.url.lastPathComponent) [\(app.bundleIdentifier ?? "?")] does not provide an AppleScript .sdef and is not scriptable via this tool.")
        }

        let header = """
            # \(app.url.lastPathComponent) [\(app.bundleIdentifier ?? "?")] v\(app.version ?? "?")
            # sdef: \(scripting.url.path)
            # Format: SUITE name | CLASS name [(extends X)] | PROP name:type [access] — desc | ELEM type | RESPONDS cmd, ... | CMD name(direct) → result | param[?][:type]
            # Standard Suite contains generic open/close/quit/count/exists/make/delete/move and is included for completeness.

            """
        return .success(header + scripting.renderedSchema)
    }
}
