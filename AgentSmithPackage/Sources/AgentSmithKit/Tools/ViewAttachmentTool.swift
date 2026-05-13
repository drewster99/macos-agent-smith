import Foundation

/// Universal "stage these attachments into my next user turn" tool. Available to Brown
/// (and Smith) so an agent can pull a previously-known attachment into its visual
/// context on demand. Works across every vision-capable provider because it leans on
/// the user-message image-block path that every provider already supports — no
/// provider-specific tool-result content-block plumbing needed.
///
/// The tool itself returns a confirmation string synchronously; the actual content
/// blocks are injected on the *next* outbound user message by `AgentActor`'s drain
/// path, so the LLM sees the staged attachments alongside whatever else triggers the
/// next turn.
///
/// `detail` controls the resolution tier the runtime stages:
/// - `thumbnail` (512px long edge): cheap, good for "is this the right image" checks.
/// - `standard` (1024px long edge): default; matches Anthropic / OpenAI sweet spots.
/// - `full`: original bytes, no resize. Use when standard fails to answer the question
///   (fine print, OCR, dense diagrams).
public struct ViewAttachmentTool: AgentTool {
    public let name = "view_attachment"
    public let toolDescription = """
        Stage one or more previously-known attachments into your next user turn so you can \
        see (image), read (PDF/text), or reason about their contents. Use the IDs surfaced \
        in earlier `[filename](file://…) … id=<UUID>` lines from the task briefing, prior \
        turns, or other tools' outputs. Image attachments become inline image content; \
        non-image attachments become a markdown reference plus a `file://` path you can pass \
        to `file_read` if needed. The tool itself returns a brief confirmation; the actual \
        bytes/content arrive on your NEXT user turn.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Attachment UUIDs to stage. Forward EXACT id values from earlier `[…](file://…) … id=<UUID>` references — do not invent IDs.")
            ]),
            "detail": .dictionary([
                "type": .string("string"),
                "description": .string("Resolution tier for image attachments: \"thumbnail\" (~512px), \"standard\" (~1024px, default), or \"full\" (original). Has no effect on non-image attachments.")
            ])
        ]),
        "required": .array([.string("ids")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        // Brown is the primary consumer; Smith may also occasionally need to view an
        // attachment to advise the user (e.g. when reviewing Brown's task_complete).
        context.agentRole == .brown || context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .array(let raw) = arguments["ids"] else {
            throw ToolCallError.missingRequiredArgument("ids")
        }
        let idStrings: [String] = raw.compactMap {
            if case .string(let s) = $0 { return s }
            return nil
        }
        guard !idStrings.isEmpty else {
            return .failure("view_attachment: `ids` must be a non-empty array of attachment UUID strings.")
        }

        let detail: String
        if case .string(let d) = arguments["detail"] {
            detail = d
        } else {
            detail = "standard"
        }

        let outcome = await context.resolveAttachments(idStrings)
        if !outcome.rejected.isEmpty {
            return .failure("view_attachment: unknown attachment_ids: \(outcome.rejected.joined(separator: ", ")). Use the EXACT id values from `[…](file://…) … id=<UUID>` references the system has shown you.")
        }
        guard !outcome.resolved.isEmpty else {
            return .failure("view_attachment: no attachments resolved.")
        }

        await context.stageAttachmentsForNextTurn(outcome.resolved, detail)

        let names = outcome.resolved.map { $0.filename }.joined(separator: ", ")
        return .success("Staged \(outcome.resolved.count) attachment(s) at detail=\(detail) for your next turn: \(names). The contents will appear with the next user message.")
    }
}
