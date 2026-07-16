import Foundation
import Testing
@testable import AgentSmithKit

/// Tests for `TaskCompleteTool.buildDeliverables` — the optional structured-deliverables →
/// `ResultItem` mapping (Phase B).
@Suite("task_complete deliverables")
struct TaskCompleteDeliverablesTests {

    @Test("omitted deliverables → no result items")
    func omitted() async {
        let items = await TaskCompleteTool.buildDeliverables(arguments: [:], context: TestToolContext.make())
        #expect(items.isEmpty)
    }

    @Test("text-only deliverable → tagged text item")
    func textItem() async {
        let args: [String: AnyCodable] = ["deliverables": .array([
            .dictionary(["ref": .string("email"), "text": .string("jeff@example.com")])
        ])]
        let items = await TaskCompleteTool.buildDeliverables(arguments: args, context: TestToolContext.make())
        #expect(items.count == 1)
        #expect(items.first?.refs == ["email"])
        guard case .text(let text) = items.first?.content else {
            Issue.record("expected a text item")
            return
        }
        #expect(text == "jeff@example.com")
    }

    @Test("attachment_ids deliverable → tagged single attachment item")
    func attachmentItem() async {
        let attach = Attachment(filename: "de.png", mimeType: "image/png", byteCount: 1, data: Data([0]))
        let context = TestToolContext.make(attachmentResolver: { _ in ([attach], []) })
        let args: [String: AnyCodable] = ["deliverables": .array([
            .dictionary(["ref": .string("screens"), "attachment_ids": .array([.string(attach.id.uuidString)])])
        ])]
        let items = await TaskCompleteTool.buildDeliverables(arguments: args, context: context)
        #expect(items.count == 1)
        #expect(items.first?.refs == ["screens"])
        guard case .attachment(let a) = items.first?.content else {
            Issue.record("expected a single attachment item")
            return
        }
        #expect(a.id == attach.id)
    }

    @Test("multiple attachments + description → group item")
    func groupItem() async {
        let a1 = Attachment(filename: "de.png", mimeType: "image/png", byteCount: 1, data: Data([0]))
        let a2 = Attachment(filename: "ar.png", mimeType: "image/png", byteCount: 1, data: Data([1]))
        let context = TestToolContext.make(attachmentResolver: { _ in ([a1, a2], []) })
        let args: [String: AnyCodable] = ["deliverables": .array([
            .dictionary([
                "ref": .string("screens"),
                "description": .string("locale screenshots"),
                "attachment_ids": .array([.string(a1.id.uuidString), .string(a2.id.uuidString)])
            ])
        ])]
        let items = await TaskCompleteTool.buildDeliverables(arguments: args, context: context)
        #expect(items.count == 1)
        guard case .attachmentGroup(let attachments, let description) = items.first?.content else {
            Issue.record("expected an attachment-group item")
            return
        }
        #expect(attachments.count == 2)
        #expect(description == "locale screenshots")
    }

    @Test("resultItems survive a JSON round-trip on the task")
    func roundTrip() throws {
        let attachment = Attachment(filename: "x.png", mimeType: "image/png", byteCount: 1)
        let items = [
            ResultItem(content: .text("answer"), refs: ["a"]),
            ResultItem(content: .attachmentGroup(attachments: [attachment], description: "grp"), refs: ["b", "c"])
        ]
        let task = AgentTask(title: "t", description: "d", resultItems: items)
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(AgentTask.self, from: data)
        #expect(decoded.resultItems == items)
    }
}
