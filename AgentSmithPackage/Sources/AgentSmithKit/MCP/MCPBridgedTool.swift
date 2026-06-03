import Foundation
import SwiftLLMKit

/// Adapts a single MCP server tool to the app's `AgentTool` protocol so Brown can
/// call it like any built-in tool. Snapshotted per turn by
/// ``MCPClientHost/currentBridgedTools()``; it captures the server origin and the
/// tool's advertised name/description/schema, and routes execution back through the
/// host actor.
struct MCPBridgedTool: AgentTool {
    let prefixedName: String
    let serverName: String
    let serverID: UUID
    let originalToolName: String
    let toolDescription: String
    let parameters: [String: AnyCodable]
    /// `readOnlyHint` from the server's tool annotations, surfaced to Jones. These are
    /// hints from a third party and are never trusted for access decisions.
    let isReadOnlyHint: Bool?
    /// `destructiveHint` / `openWorldHint` from the server's tool annotations. Like
    /// `isReadOnlyHint`, these are untrusted third-party claims — advisory context for Jones
    /// only, never a grant mechanism. Absent hint → fail-closed `true` via the computed
    /// `isDestructive` / `isOpenWorld` below.
    let destructiveHint: Bool?
    let openWorldHint: Bool?
    let host: MCPClientHost

    var name: String { prefixedName }

    /// MCP servers can run longer than in-process tools (network calls, spawned work),
    /// so allow more headroom than the 120 s default.
    var executionTimeout: Duration { .seconds(180) }

    /// Fail-closed: an MCP tool that doesn't declare `destructiveHint` is assumed destructive.
    /// Untrusted — surfaced to Jones as a server-claimed hint, never used to grant access.
    var isDestructive: Bool { destructiveHint ?? true }

    /// Fail-closed: an MCP tool that doesn't declare `openWorldHint` is assumed open-world.
    var isOpenWorld: Bool { openWorldHint ?? true }

    func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        let result: MCPToolCallResult
        do {
            result = try await host.callTool(serverID: serverID, toolName: originalToolName, arguments: arguments)
        } catch is CancellationError {
            return .failure("MCP tool \(originalToolName) was cancelled.")
        } catch {
            // A terminated/disabled server fails the in-flight request here; report it
            // as a tool failure so Brown can recover rather than hang.
            return .failure("MCP server \"\(serverName)\" error calling \(originalToolName): \(error.localizedDescription)")
        }

        if !result.images.isEmpty {
            await routeImages(result.images, context: context)
        }

        return ToolExecutionResult(output: result.text, succeeded: !result.isError)
    }

    /// Decodes returned image data, ingests it through the attachment pipeline, and
    /// stages it so the model sees it on the next turn — reusing Brown's
    /// `view_attachment` machinery.
    private func routeImages(_ images: [(data: Data, mimeType: String)], context: ToolContext) async {
        var staged: [Attachment] = []
        let tmpDir = FileManager.default.temporaryDirectory
        for (data, mimeType) in images {
            let ext = Self.fileExtension(forMimeType: mimeType)
            let url = tmpDir.appendingPathComponent("mcp-\(UUID().uuidString).\(ext)")
            do {
                try data.write(to: url)
            } catch {
                continue
            }
            let outcome = await context.ingestAttachmentFile(url.path)
            if let attachment = outcome.attachment {
                staged.append(attachment)
            }
            try? FileManager.default.removeItem(at: url)
        }
        if !staged.isEmpty {
            await context.stageAttachmentsForNextTurn(staged, "standard")
        }
    }

    private static func fileExtension(forMimeType mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/tiff": return "tiff"
        default: return "png"
        }
    }
}
