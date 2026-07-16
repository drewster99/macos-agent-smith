import Foundation
import Testing
@testable import AgentSmithKit

/// Tests for `AttachFileTool`. Verifies argument/path validation and the ingest → stage flow.
@Suite("AttachFileTool")
struct AttachFileToolTests {

    @Test("missing path argument throws missing-argument")
    func missingPath() async {
        let tool = AttachFileTool()
        let context = TestToolContext.make()
        await #expect(throws: ToolCallError.self) {
            _ = try await tool.execute(arguments: [:], context: context)
        }
    }

    @Test("non-absolute path fails with a clear message")
    func relativePath() async throws {
        let tool = AttachFileTool()
        let context = TestToolContext.make()
        let result = try await tool.execute(
            arguments: ["path": .string("relative/thing.png")],
            context: context
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("absolute"))
    }

    @Test("ingest failure surfaces without staging")
    func ingestFailure() async throws {
        let tool = AttachFileTool()
        let recorder = TestToolContext.StagedAttachmentRecorder()
        let context = TestToolContext.make(
            attachmentIngestor: { _ in (nil, "no such file") },
            stagedAttachmentRecorder: recorder
        )
        let result = try await tool.execute(
            arguments: ["path": .string("/tmp/agent-smith-tests/does-not-exist.png")],
            context: context
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("no such file"))
        #expect(recorder.all().isEmpty)
    }

    @Test("successful ingest stages the attachment for the next turn")
    func successStages() async throws {
        let tool = AttachFileTool()
        let recorder = TestToolContext.StagedAttachmentRecorder()
        let attachment = Attachment(
            filename: "screenshot.png",
            mimeType: "image/png",
            byteCount: 3,
            data: Data([0, 1, 2])
        )
        let context = TestToolContext.make(
            attachmentIngestor: { _ in (attachment, nil) },
            stagedAttachmentRecorder: recorder
        )
        let result = try await tool.execute(
            arguments: ["path": .string("/tmp/agent-smith-tests/screenshot.png")],
            context: context
        )
        #expect(result.succeeded)
        #expect(result.output.contains("screenshot.png"))
        let staged = recorder.all()
        #expect(staged.count == 1)
        #expect(staged.first?.attachments.first?.id == attachment.id)
        #expect(staged.first?.detail == "standard")
    }
}
