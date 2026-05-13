import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `ViewAttachmentTool`. Verifies argument validation, the resolver →
/// stage round-trip, and the `detail` parameter dispatch.
@Suite("ViewAttachmentTool")
struct ViewAttachmentToolTests {

    @Test("missing ids argument throws missing-argument")
    func missingIDs() async {
        let tool = ViewAttachmentTool()
        let recorder = TestToolContext.StagedAttachmentRecorder()
        let ctx = TestToolContext.make(stagedAttachmentRecorder: recorder)
        do {
            _ = try await tool.execute(arguments: [:], context: ctx)
            Issue.record("expected throw on missing ids")
        } catch ToolCallError.missingRequiredArgument(let name) {
            #expect(name == "ids")
        } catch {
            Issue.record("expected ToolCallError.missingRequiredArgument, got \(error)")
        }
    }

    @Test("empty ids array fails with a clear message")
    func emptyIDs() async throws {
        let tool = ViewAttachmentTool()
        let recorder = TestToolContext.StagedAttachmentRecorder()
        let ctx = TestToolContext.make(stagedAttachmentRecorder: recorder)
        let result = try await tool.execute(
            arguments: ["ids": .array([])],
            context: ctx
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("non-empty"))
        #expect(recorder.all().isEmpty)
    }

    @Test("rejected ids fail without staging")
    func rejectedIDs() async throws {
        let tool = ViewAttachmentTool()
        let recorder = TestToolContext.StagedAttachmentRecorder()
        let ctx = TestToolContext.make(
            attachmentResolver: { ids in ([], ids) },  // reject all
            stagedAttachmentRecorder: recorder
        )
        let result = try await tool.execute(
            arguments: ["ids": .array([.string("bad-id-1"), .string("bad-id-2")])],
            context: ctx
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("unknown"))
        #expect(recorder.all().isEmpty)
    }

    @Test("resolved ids stage with default detail=standard")
    func defaultDetail() async throws {
        let tool = ViewAttachmentTool()
        let recorder = TestToolContext.StagedAttachmentRecorder()
        let attachment = Attachment(filename: "x.png", mimeType: "image/png", byteCount: 100)
        let ctx = TestToolContext.make(
            attachmentResolver: { _ in ([attachment], []) },
            stagedAttachmentRecorder: recorder
        )
        let result = try await tool.execute(
            arguments: ["ids": .array([.string(attachment.id.uuidString)])],
            context: ctx
        )
        #expect(result.succeeded)
        let entries = recorder.all()
        #expect(entries.count == 1)
        #expect(entries.first?.attachments.count == 1)
        #expect(entries.first?.detail == "standard")
    }

    @Test("explicit detail flows through to staging")
    func explicitDetail() async throws {
        let tool = ViewAttachmentTool()
        let recorder = TestToolContext.StagedAttachmentRecorder()
        let attachment = Attachment(filename: "x.png", mimeType: "image/png", byteCount: 100)
        let ctx = TestToolContext.make(
            attachmentResolver: { _ in ([attachment], []) },
            stagedAttachmentRecorder: recorder
        )
        let result = try await tool.execute(
            arguments: [
                "ids": .array([.string(attachment.id.uuidString)]),
                "detail": .string("thumbnail")
            ],
            context: ctx
        )
        #expect(result.succeeded)
        #expect(recorder.all().first?.detail == "thumbnail")
    }
}
