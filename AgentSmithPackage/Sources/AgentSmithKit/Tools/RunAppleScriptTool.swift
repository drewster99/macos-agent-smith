import Foundation

/// Executes an AppleScript via NSAppleScript and returns a structured result.
/// On success, both a recursively-coerced JSON value and a plain-text coercion
/// are returned. On failure, a structured error tagged as compile / runtime /
/// targetApp / unknown — with line, column, and source snippet when available.
struct RunAppleScriptTool: AgentTool {
    let name = "run_applescript"

    let toolDescription = """
        Control apps on this device by running an AppleScript via NSAppleScript and return its result as structured JSON. \
        Use this to drive other Mac apps that support scripting (Mail, Messages (iMessage), Calendar, Music, Finder, Xcode, \
        Safari, Photos, etc.). For any non-trivial app, call `get_app_scripting_schema` first to confirm \
        the commands and properties you reference actually exist — guessing AppleScript syntax is the \
        single most common cause of runtime errors.

        Returns a JSON object:
        - On success: `{ "success": true, "result": <coerced>, "resultText": "...", "descriptorType": "<4cc>" }`. \
          `result` is the script's return value, recursively coerced to JSON. Primitives become bare JSON; \
          types with no JSON equivalent are tagged as `{"$type": "...", ...}` — date as ISO string, alias as \
          path/url, type names and enum values as four-char codes. Object specifiers (references like \
          `chat 1` or `participant id "..."`) are returned as `{"$type":"objectSpecifier", "text":"...", \
          "properties": {...}}` — the `properties` record is auto-fetched from the target app and contains \
          every readable property keyed by its four-char code (e.g. `pnam` = name, `ID  ` = id). Nested \
          object specifiers inside that record are returned as references only (no further expansion), so \
          if you need a chat's participants' properties, write the script to extract them explicitly \
          (`name of every participant of chat 1`) rather than expecting recursive expansion. \
          `resultText` is the script's text coercion (always a string), useful for display or as a fallback \
          when the structured form isn't what you expected. `descriptorType` is the underlying four-char \
          AppleEvent type code.
        - On failure: `{ "success": false, "error": { "kind", "number", "message", "appName", "location" } }`. \
          `kind` is `"compile"` (syntax/parse — fix the script and retry), `"runtime"` (script ran but failed \
          mid-execution — usually a missing object or wrong property), `"targetApp"` (a `tell application` \
          target doesn't exist or refused), or `"unknown"`. `location` gives `line`, `column`, and a `snippet` \
          of the source the range covers.

        First-time-target prompts: macOS will prompt the user once per scripting target (Mail, Finder, ...) \
        for permission. If the user declines, you'll see a `targetApp` error.

        Common pitfall — concatenating object references with `&`: AppleScript's `&` operator forces each \
        operand to Unicode text, but most object references (e.g. `service of chat 1` returns an `account`, \
        `sender of message 1` returns a `buddy` or `participant`, `application file of process 1` returns a \
        `file`) have no app-defined coercion to text and will fail with `-1700` ("Can't make X into type \
        Unicode text"). The reference syntax you see in error messages (`account id "DAB78B1A-..."`) is a \
        debug rendering, not a usable string. Always extract a textual property first: \
        `name of (service of chat 1)`, `id of (service of chat 1) as text`, `handle of (sender of message 1)`. \
        Properties typed as `text`, `unicode text`, or `string` in the scripting dictionary concatenate cleanly; \
        properties typed as another class (account, buddy, file, etc.) do not. If you actually want the \
        reference itself in the result, just `return service of chat 1` directly — the tool will expand it \
        into `{$type: "objectSpecifier", text, properties}` for you.

        Argument:
        - `script` (required): the AppleScript source. Multi-line is fine. Wrap with `with timeout of N seconds ... \
          end timeout` if you need a wall-clock cap — there is no separate timeout argument.
        """

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                BrownBehavior.approvalGateNote(outcome: "the structured AppleScript result JSON") +
                BrownBehavior.terminationWarning
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "script": .dictionary([
                "type": .string("string"),
                "description": .string("AppleScript source to compile and execute. Use 'tell application \"X\" to ...' for inter-app calls.")
            ])
        ]),
        "required": .array([.string("script")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let source) = arguments["script"], !source.isEmpty else {
            throw ToolCallError.missingRequiredArgument("script")
        }

        let result = await AppleScriptRunner.shared.run(source)
        let json = encodeResult(result)

        if result.success {
            return .success(json)
        } else {
            return .failure(json)
        }
    }

    private func encodeResult(_ result: AppleScriptResult) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"success\": \(result.success), \"error\": \"failed to encode result\"}"
    }
}
