import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// Tests for the `web_fetch` tool: the pure HTML→markdown conversion + output formatting, the
/// `execute()` paths (markdown mode, extraction mode, fallbacks, errors) over a stubbed network,
/// classification/wiring, and a real Brown agent-loop invocation.
@Suite("Web fetch")
struct WebFetchTests {

    // MARK: - HTML → markdown (pure)

    private static let sampleHTML = """
    <html><head><title>T</title><style>.a{color:red}</style></head>
    <body>
      <h1>Hello &amp; Welcome</h1>
      <p>World <a class="x" href="https://example.com/p">the link</a> here.</p>
      <ul><li>one</li><li>two</li></ul>
      <script>doEvil()</script>
    </body></html>
    """

    @Test("converts headings, links, and lists; drops scripts/styles; decodes entities")
    func htmlToMarkdown() {
        let md = WebFetchTool.htmlToMarkdown(Self.sampleHTML)
        #expect(md.contains("# Hello & Welcome"))
        #expect(md.contains("[the link](https://example.com/p)"))
        #expect(md.contains("- one"))
        #expect(md.contains("- two"))
        #expect(!md.contains("doEvil"))      // script content removed
        #expect(!md.contains("color:red"))   // style content removed
        #expect(!md.contains("<"))           // no residual tags
    }

    @Test("empty markup yields empty string")
    func emptyMarkup() {
        #expect(WebFetchTool.htmlToMarkdown("<html><head></head><body></body></html>").isEmpty)
    }

    @Test("formatMarkdown truncates very long content and notes it")
    func truncation() {
        let huge = String(repeating: "x", count: 80_000)
        let out = WebFetchTool.formatMarkdown(huge, url: "https://a.com", note: nil)
        #expect(out.contains("truncated"))
        #expect(out.count < 60_000)
        #expect(out.contains("https://a.com"))
    }

    // MARK: - Classification & wiring

    @Test("web_fetch is open-world, non-destructive, read-only, and wired into Brown")
    func classificationAndWiring() {
        let tool = WebFetchTool()
        #expect(tool.isOpenWorld)
        #expect(!tool.isDestructive)
        #expect(!ToolSafetyClassification.hasSideEffects(toolName: "web_fetch"))
        #expect(ToolSafetyClassification.knownBuiltInNames.contains("web_fetch"))
        #expect(BrownBehavior.toolNames.contains("web_fetch"))
        #expect(BrownBehavior.smithFacingToolManifest().contains("web_fetch"))
    }

    @Test("missing url throws; non-http and empty url are refused")
    func urlValidation() async {
        let tool = WebFetchTool()
        let ctx = TestToolContext.make()
        await #expect(throws: ToolCallError.self) {
            _ = try await tool.execute(arguments: [:], context: ctx)
        }
        let ftp = try? await tool.execute(arguments: ["url": .string("ftp://x.com/a")], context: ctx)
        #expect(ftp?.succeeded == false)
        let empty = try? await tool.execute(arguments: ["url": .string("   ")], context: ctx)
        #expect(empty?.succeeded == false)
    }

    // MARK: - Content classification (pure)

    @Test("classifyContent: magic numbers win over the declared type")
    func classifyMagic() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(WebFetchTool.classifyContent(data: png, declaredMimeType: "text/html") == .image(mimeType: "image/png"))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        #expect(WebFetchTool.classifyContent(data: jpeg, declaredMimeType: nil) == .image(mimeType: "image/jpeg"))
        let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        #expect(WebFetchTool.classifyContent(data: gif, declaredMimeType: nil) == .image(mimeType: "image/gif"))
        let webp = Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])
        #expect(WebFetchTool.classifyContent(data: webp, declaredMimeType: nil) == .image(mimeType: "image/webp"))
        let pdf = Data("%PDF-1.4".utf8)
        #expect(WebFetchTool.classifyContent(data: pdf, declaredMimeType: nil) == .pdf)
    }

    @Test("classifyContent: declared-type routing — SVG is text, HEIC is image, params stripped")
    func classifyDeclared() {
        let opaque = Data([0x01, 0x02, 0x03, 0x04])
        #expect(WebFetchTool.classifyContent(data: opaque, declaredMimeType: "image/svg+xml") == .text)
        #expect(WebFetchTool.classifyContent(data: opaque, declaredMimeType: "image/heic") == .image(mimeType: "image/heic"))
        #expect(WebFetchTool.classifyContent(data: opaque, declaredMimeType: "text/html; charset=utf-8") == .text)
        #expect(WebFetchTool.classifyContent(data: opaque, declaredMimeType: "application/json") == .text)
        // An image format we can't inject and can't re-encode is refused, not staged.
        #expect(WebFetchTool.classifyContent(data: opaque, declaredMimeType: "image/avif") == .binary(mimeType: "image/avif"))
    }

    @Test("classifyContent: NUL byte ⇒ binary; clean bytes with no declared type ⇒ text")
    func classifyHeuristic() {
        let nul = Data([0x41, 0x00, 0x42])
        #expect(WebFetchTool.classifyContent(data: nul, declaredMimeType: nil) == .binary(mimeType: "application/octet-stream"))
        #expect(WebFetchTool.classifyContent(data: nul, declaredMimeType: "application/octet-stream") == .binary(mimeType: "application/octet-stream"))
        let text = Data("<html>hi</html>".utf8)
        #expect(WebFetchTool.classifyContent(data: text, declaredMimeType: nil) == .text)
    }

    @Test("deriveFilename: keeps a URL filename with an extension; synthesizes otherwise")
    func filenames() throws {
        let named = try #require(URL(string: "https://a.com/pics/cat.png"))
        #expect(WebFetchTool.deriveFilename(from: named, mimeType: "image/png", kind: .image) == "cat.png")
        let noExt = try #require(URL(string: "https://a.com/download"))
        #expect(WebFetchTool.deriveFilename(from: noExt, mimeType: "image/jpeg", kind: .image) == "fetched-image.jpg")
        let root = try #require(URL(string: "https://a.com/"))
        #expect(WebFetchTool.deriveFilename(from: root, mimeType: "application/pdf", kind: .pdf) == "fetched-document.pdf")
    }
}

/// Network-backed `web_fetch` tests. Each test uses its own `URLProtocolStub` session (the canned
/// response is keyed per session), so they're safe to run alongside other suites.
@Suite("Web fetch network")
struct WebFetchNetworkTests {

    private static let pageHTML = """
    <html><head><title>Doc</title></head><body><h1>Title</h1><p>Body text here.</p></body></html>
    """

    private static func pageSession() -> URLSession {
        URLProtocolStub.makeSession(statusCode: 200, body: Data(pageHTML.utf8))
    }

    @Test("no prompt: returns page markdown with an untrusted-content header")
    func returnsMarkdown() async throws {
        let tool = WebFetchTool(session: Self.pageSession())
        let result = try await tool.execute(arguments: ["url": .string("https://a.com")], context: TestToolContext.make())
        #expect(result.succeeded)
        #expect(result.output.contains("# Title"))
        #expect(result.output.contains("Body text here."))
        #expect(result.output.lowercased().contains("untrusted"))
    }

    @Test("with prompt: returns the extraction from the wired extractor")
    func returnsExtraction() async throws {
        let context = TestToolContext.make(extractWebContent: { content, prompt in
            "ANSWER(\(prompt)): \(content.contains("Body text") ? "found" : "missing")"
        })
        let tool = WebFetchTool(session: Self.pageSession())
        let result = try await tool.execute(
            arguments: ["url": .string("https://a.com"), "prompt": .string("what is the body?")],
            context: context
        )
        #expect(result.succeeded)
        #expect(result.output.contains("ANSWER(what is the body?): found"))
        // Extraction mode should NOT dump the raw markdown header.
        #expect(!result.output.lowercased().contains("untrusted"))
    }

    @Test("with prompt but no extractor wired: falls back to markdown with a note")
    func extractionFallback() async throws {
        // Default TestToolContext has extractWebContent returning nil.
        let tool = WebFetchTool(session: Self.pageSession())
        let result = try await tool.execute(
            arguments: ["url": .string("https://a.com"), "prompt": .string("anything")],
            context: TestToolContext.make()
        )
        #expect(result.succeeded)
        #expect(result.output.contains("extraction was unavailable"))
        #expect(result.output.contains("# Title"))
    }

    @Test("non-2xx status is a failure")
    func httpError() async throws {
        let tool = WebFetchTool(session: URLProtocolStub.makeSession(statusCode: 404, body: Data()))
        let result = try await tool.execute(arguments: ["url": .string("https://a.com")], context: TestToolContext.make())
        #expect(!result.succeeded)
        #expect(result.output.contains("404"))
    }

    @Test("image URL: sniffed from bytes, ingested, and staged for the next turn")
    func imageFetchStages() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02])
        let recorder = TestToolContext.StagedAttachmentRecorder()
        let ctx = TestToolContext.make(stagedAttachmentRecorder: recorder)
        let tool = WebFetchTool(session: URLProtocolStub.makeSession(statusCode: 200, body: png))
        let result = try await tool.execute(arguments: ["url": .string("https://a.com/pic.png")], context: ctx)
        #expect(result.succeeded)
        #expect(result.output.lowercased().contains("image"))
        #expect(result.output.contains("id="))
        let staged = recorder.all()
        #expect(staged.count == 1)
        #expect(staged.first?.attachments.first?.mimeType == "image/png")
        #expect(staged.first?.attachments.first?.filename == "pic.png")
        #expect(staged.first?.detail == "standard")
    }

    @Test("image via declared Content-Type when the bytes carry no known signature")
    func imageFetchByContentType() async throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let session = URLProtocolStub.makeSession(statusCode: 200, body: bytes, headerFields: ["Content-Type": "image/webp"])
        let tool = WebFetchTool(session: session)
        let result = try await tool.execute(arguments: ["url": .string("https://a.com/x")], context: TestToolContext.make())
        #expect(result.succeeded)
        #expect(result.output.contains("image/webp"))
    }

    @Test("PDF URL: saved as an attachment and pointed at file_read")
    func pdfFetch() async throws {
        let pdf = Data("%PDF-1.7\nfake pdf body".utf8)
        let recorder = TestToolContext.StagedAttachmentRecorder()
        let ctx = TestToolContext.make(stagedAttachmentRecorder: recorder)
        let tool = WebFetchTool(session: URLProtocolStub.makeSession(statusCode: 200, body: pdf))
        let result = try await tool.execute(arguments: ["url": .string("https://a.com/doc.pdf")], context: ctx)
        #expect(result.succeeded)
        #expect(result.output.lowercased().contains("pdf"))
        #expect(result.output.contains("file_read"))
        #expect(recorder.all().first?.attachments.first?.mimeType == "application/pdf")
    }

    @Test("image fetch with a prompt: stages the image and tells Brown to answer from it")
    func imageFetchWithPrompt() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let tool = WebFetchTool(session: URLProtocolStub.makeSession(statusCode: 200, body: png))
        let result = try await tool.execute(
            arguments: ["url": .string("https://a.com/p.png"), "prompt": .string("what color is the logo?")],
            context: TestToolContext.make()
        )
        #expect(result.succeeded)
        #expect(result.output.contains("what color is the logo?"))
    }

    @Test("other binary content is refused with its content-type, not lossy-decoded")
    func binaryRefused() async throws {
        let bytes = Data([0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x00])
        let session = URLProtocolStub.makeSession(statusCode: 200, body: bytes, headerFields: ["Content-Type": "application/zip"])
        let tool = WebFetchTool(session: session)
        let result = try await tool.execute(arguments: ["url": .string("https://a.com/a.zip")], context: TestToolContext.make())
        #expect(!result.succeeded)
        #expect(result.output.contains("application/zip"))
        #expect(result.output.lowercased().contains("refused"))
    }

    @Test("Brown's live agent loop invokes web_fetch and receives content")
    func brownInvokesWebFetch() async {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let agentID = UUID()
        let context = TestToolContext.make(agentID: agentID, agentRole: .brown, channel: channel, taskStore: taskStore)

        let call = LLMToolCall(id: "wf-1", name: "web_fetch", arguments: #"{"url":"https://a.com"}"#)
        let provider = MockLLMProvider(responses: [
            LLMResponse(toolCalls: [call]),
            LLMResponse(text: ""), LLMResponse(text: ""), LLMResponse(text: ""), LLMResponse(text: "")
        ])
        let agent = AgentActor(
            id: agentID,
            configuration: AgentConfiguration(
                role: .brown,
                llmConfig: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model", maxOutputTokens: 1024, maxContextTokens: 100_000),
                systemPrompt: "test"
            ),
            provider: provider,
            tools: [WebFetchTool(session: Self.pageSession())],
            toolContext: context
        )

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock(); private var latest: [LLMMessage] = []
            func update(_ messages: [LLMMessage]) { lock.lock(); defer { lock.unlock() }; latest = messages }
            var snapshot: [LLMMessage] { lock.lock(); defer { lock.unlock() }; return latest }
        }
        let recorder = Recorder()
        await agent.setOnContextChanged { recorder.update($0) }

        let task = await taskStore.addTask(title: "web_fetch loop", description: "drive web_fetch")
        await taskStore.updateStatus(id: task.id, status: .running)
        await taskStore.assignAgent(taskID: task.id, agentID: agentID)
        await agent.start(initialInstruction: "go")

        let deadline = Date().addingTimeInterval(3.0)
        while await agent.running, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        await agent.stop()

        let toolResult = recorder.snapshot.first { msg in
            if case .toolResult(let id, let content) = msg.content { return id == "wf-1" && content.contains("Title") }
            return false
        }
        #expect(toolResult != nil, "web_fetch did not execute through Brown's agent loop")
    }
}

/// Live network test for `web_fetch` — gated behind `WEB_SEARCH_LIVE=1` (same flag as the other
/// live web suites) so the default `swift test` pass stays offline.
@Suite("Web fetch live", .enabled(if: ProcessInfo.processInfo.environment["WEB_SEARCH_LIVE"] == "1"))
struct WebFetchLiveTests {

    @Test("fetches a real page and converts it to markdown")
    func liveFetch() async throws {
        let tool = WebFetchTool()
        let result = try await tool.execute(
            arguments: ["url": .string("https://example.com")],
            context: TestToolContext.make()
        )
        #expect(result.succeeded)
        #expect(result.output.contains("Example Domain"))
    }
}
