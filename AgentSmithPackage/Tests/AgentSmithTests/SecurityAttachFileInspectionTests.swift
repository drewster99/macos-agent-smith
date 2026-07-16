import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftLLMKit
@testable import AgentSmithKit

@Suite("Security Agent attach_file content inspection")
struct SecurityAttachFileInspectionTests {

    private func writePNG(to dir: URL) throws -> String {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 6, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 6, height: 6))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
        let url = dir.appendingPathComponent("evidence.png")
        try (out as Data).write(to: url)
        return url.path
    }

    private func makeEvaluator(supportsVision: Bool, provider: MockLLMProvider) -> SecurityEvaluator {
        SecurityEvaluator(
            provider: provider,
            systemPrompt: "test",
            channel: MessageChannel(),
            abort: { _, _ in },
            supportsVision: supportsVision,
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
    }

    private func evaluateAttachFile(_ evaluator: SecurityEvaluator, path: String) async {
        _ = await evaluator.evaluate(
            toolName: "attach_file",
            toolParams: "{\"path\":\"\(path)\"}",
            toolDescription: "Attach a file",
            toolParameterDefs: "",
            taskTitle: "t",
            taskID: UUID().uuidString,
            taskDescription: "d",
            siblingCalls: nil,
            agentRoleName: "Brown",
            toolCallID: nil
        )
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A vision-capable Security model is shown the image it's about to approve")
    func visionModelSeesImage() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writePNG(to: dir)

        let provider = MockLLMProvider(responses: [LLMResponse(text: "SAFE looks fine", toolCalls: [])])
        let evaluator = makeEvaluator(supportsVision: true, provider: provider)
        await evaluateAttachFile(evaluator, path: path)

        let firstCall = try #require(provider.receivedMessages.first)
        let images = firstCall.compactMap { $0.images }.flatMap { $0 }
        #expect(!images.isEmpty)  // the pixels actually reached the Security model
    }

    @Test("A non-vision Security model gets no image block (rules on the path only)")
    func nonVisionModelGetsNoImage() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try writePNG(to: dir)

        let provider = MockLLMProvider(responses: [LLMResponse(text: "SAFE", toolCalls: [])])
        let evaluator = makeEvaluator(supportsVision: false, provider: provider)
        await evaluateAttachFile(evaluator, path: path)

        let firstCall = try #require(provider.receivedMessages.first)
        let images = firstCall.compactMap { $0.images }.flatMap { $0 }
        #expect(images.isEmpty)
    }

    @Test("A non-image/PDF path adds no inline content (path-only eval)")
    func textFileGetsNoInlineContent() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("notes.txt").path
        try "just some text".write(toFile: path, atomically: true, encoding: .utf8)

        let provider = MockLLMProvider(responses: [LLMResponse(text: "SAFE", toolCalls: [])])
        let evaluator = makeEvaluator(supportsVision: true, provider: provider)
        await evaluateAttachFile(evaluator, path: path)

        let firstCall = try #require(provider.receivedMessages.first)
        let images = firstCall.compactMap { $0.images }.flatMap { $0 }
        #expect(images.isEmpty)
    }
}
