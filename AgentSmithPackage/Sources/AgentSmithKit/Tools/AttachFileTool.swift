import Foundation

/// Pulls a file into the caller's next user turn so the model can perceive it.
///
/// Path-based: give it an absolute file path. Images are staged as inline image content (the
/// model *sees* them); non-image files are staged as a `file://` reference line the model can
/// then pass to `file_read`. The file is durably ingested into the attachment store (so the
/// resulting `id` always resolves later — in a verdict, a result, or a follow-up load).
///
/// The tool returns a confirmation string synchronously; the actual bytes/content arrive on the
/// caller's NEXT user turn, injected by each loop's drain (`AgentActor`, `SecurityEvaluator`,
/// `EvaluationRunner`). Resolution is fixed at the standard tier — no knob to tune.
///
/// Supersedes the old id-only `view_attachment`: it takes a path (which validators and workers
/// actually have) rather than an attachment id, and it works for any file type.
public struct AttachFileTool: AgentTool {
    public let name = "attach_file"
    public let toolDescription = """
        Attach a file at an absolute path into your NEXT user turn so you can perceive it. \
        IMAGES are shown to you as inline image content — this is the ONLY way to actually see \
        an image (file_read returns only metadata for images). NON-IMAGE files are attached as a \
        `file://` reference you can then pass to `file_read`; for plain text or code, calling \
        `file_read` directly is simpler and returns the content immediately. The tool returns a \
        brief confirmation; the file's content arrives with your next user message.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute path to the file to attach (e.g. /Users/you/evidence/screenshot.png).")
            ])
        ]),
        "required": .array([.string("path")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        // Brown and Smith attach on demand in the main loop; the Security Agent and acceptance
        // validators get it through their own tool lists (they don't run the main agent loop).
        context.agentRole == .brown || context.agentRole == .smith || context.agentRole == .securityAgent
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let rawPath) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }
        let path = PathNormalization.normalize(rawPath)
        guard path.hasPrefix("/") else {
            return .failure("attach_file: path must be absolute (start with /). Got: \(path)")
        }
        if let rejection = FileReadTool.checkPathRestriction(path) {
            return .failure(rejection)
        }

        let (attachment, error) = await context.ingestAttachmentFile(path)
        guard let attachment else {
            return .failure("attach_file: couldn't attach \(path): \(error ?? "unknown error").")
        }

        // "standard" resolution tier — the drain maps this to the 1024px downscale.
        await context.stageAttachmentsForNextTurn([attachment], "standard")

        let kind = attachment.isImage ? "image (shown inline)" : "file (as a file:// reference)"
        return .success("Attached \(attachment.filename) as \(kind) for your next turn. It will appear with the next user message.")
    }
}
