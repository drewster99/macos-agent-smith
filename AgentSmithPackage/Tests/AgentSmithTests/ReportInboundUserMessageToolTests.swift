import Foundation
import Testing
@testable import AgentSmithKit

@Suite("Report inbound user message tool")
struct ReportInboundUserMessageToolTests {
    @Test("Tool reports structured inbound message through context callback")
    func reportsThroughContextCallback() async throws {
        let recorder = ReportRecorder()
        let context = TestToolContext.make(reportInboundUserMessage: { report in
            await recorder.record(report)
            return .success("ok")
        })
        let result = try await ReportInboundUserMessageTool().execute(arguments: [
            "source": .string("Mail: VIP"),
            "sender": .string("drew@example.com"),
            "subject": .string("Status"),
            "received_at": .string("2026-07-21T16:00:00Z"),
            "message": .string(" Please check this. ")
        ], context: context)

        #expect(result.succeeded)
        let report = await recorder.report
        #expect(report?.source == "Mail: VIP")
        #expect(report?.sender == "drew@example.com")
        #expect(report?.subject == "Status")
        #expect(report?.receivedAt == "2026-07-21T16:00:00Z")
        #expect(report?.message == "Please check this.")
    }

    @Test("Inbound user message tool defaults to never globally")
    func defaultsToNever() {
        #expect(ToolPolicy.builtInDefaults[ReportInboundUserMessageTool.toolName] == .never)
    }
}

private actor ReportRecorder {
    private(set) var report: InboundUserMessageReport?

    func record(_ report: InboundUserMessageReport) {
        self.report = report
    }
}
