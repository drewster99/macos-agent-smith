import Foundation
import Testing

@Suite("Standalone tool failure presentation")
struct ToolFailurePresentationSourceTests {
    @Test("A failed orphaned tool output is labeled as agent tool feedback")
    func failureLabelIsContextual() throws {
        let sourceURL = CodeStyleGuardTests.appTargetRoot
            .appendingPathComponent("Views", isDirectory: true)
            .appendingPathComponent("ChannelLogView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("if message.severity >= .error"))
        #expect(source.contains("tool failed: \\(toolName)"))
        #expect(source.contains("message.sender.displayName"))
        #expect(!source.contains("Text(\"Output: \\(toolName)\")"))
    }
}
