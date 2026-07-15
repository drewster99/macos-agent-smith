import Foundation
import Testing
@testable import AgentSmithKit

/// The evaluator framework: definitions (data), the runner (the generalized
/// evaluate-with-tools loop), and the registry (hot-loaded user-owned JSON).

private func makeDefinition(
    systemPrompt: String = "You judge things.",
    grammar: EvaluatorDefinition.OutputGrammar = .verdictLine(allowed: [
        .init(token: "ACCEPT", requiresReason: false),
        .init(token: "REJECT", requiresReason: true),
        .init(token: "WAIVE", requiresReason: true)
    ]),
    tools: [String] = [],
    maxTurns: Int = 8
) -> EvaluatorDefinition {
    EvaluatorDefinition(
        name: "test-validator",
        description: "test",
        kind: .validator,
        systemPrompt: systemPrompt,
        outputGrammar: grammar,
        modelSlot: .smith,
        toolNames: tools,
        maxTurns: maxTurns
    )
}

// MARK: - Definition

@Suite("EvaluatorDefinition")
struct EvaluatorDefinitionTests {

    @Test("JSON round-trip preserves the definition")
    func jsonRoundTrip() throws {
        let original = makeDefinition()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EvaluatorDefinition.self, from: data)
        #expect(decoded == original)
    }

    @Test("Load-time validation catches an empty prompt and grammar problems")
    func definitionValidation() {
        #expect(makeDefinition(systemPrompt: "   ").validationProblems().contains { $0.contains("systemPrompt") })
        let dupTokens = makeDefinition(grammar: .verdictLine(allowed: [
            .init(token: "ACCEPT", requiresReason: false),
            .init(token: "ACCEPT", requiresReason: false)
        ]))
        #expect(dupTokens.validationProblems().contains { $0.contains("unique") })
        #expect(makeDefinition().validationProblems().isEmpty)
    }

    @Test("Content hash is stable and edit-sensitive")
    func contentHash() {
        let a = makeDefinition()
        let b = makeDefinition()
        #expect(a.contentHash == b.contentHash)
        let edited = makeDefinition(systemPrompt: "You judge things. CHANGED")
        #expect(edited.contentHash != a.contentHash)
    }
}

// MARK: - Runner parsing

@Suite("EvaluationRunner grammar parsing")
struct EvaluationRunnerParsingTests {

    private let verdicts: [EvaluatorDefinition.VerdictSpec] = [
        .init(token: "ACCEPT", requiresReason: false),
        .init(token: "REJECT", requiresReason: true)
    ]

    @Test("Verdict line parses token, punctuation, and multi-line reason")
    func verdictParsing() {
        guard case .success(.verdict(let token, let reason)) =
                EvaluationRunner.parseVerdictLine("REJECT: missing tests\nAlso no docs.", allowed: verdicts) else {
            Issue.record("expected success")
            return
        }
        #expect(token == "REJECT")
        #expect(reason == "missing tests\nAlso no docs.")
    }

    @Test("A required reason must be present")
    func requiredReasonEnforced() {
        guard case .failure(let why) = EvaluationRunner.parseVerdictLine("REJECT", allowed: verdicts) else {
            Issue.record("expected failure")
            return
        }
        #expect(why.contains("requires a reason"))
    }

    @Test("Unknown first word fails with the allowed menu")
    func unknownTokenFails() {
        guard case .failure = EvaluationRunner.parseVerdictLine("MAYBE it's fine", allowed: verdicts) else {
            Issue.record("expected failure")
            return
        }
    }

    @Test("A mis-cased token is a verdict, not an escalation, and returns the canonical token")
    func caseInsensitiveToken() {
        guard case .success(.verdict(let token, let reason)) =
                EvaluationRunner.parseVerdictLine("Reject: not done", allowed: verdicts) else {
            Issue.record("expected a rejection, not a parse failure that would escalate")
            return
        }
        #expect(token == "REJECT")   // canonical spec token, regardless of input case
        #expect(reason == "not done")
    }

    @Test("A tab between token and reason still isolates the verdict")
    func tabSeparatedToken() {
        guard case .success(.verdict(let token, let reason)) =
                EvaluationRunner.parseVerdictLine("REJECT\tmissing tests", allowed: verdicts) else {
            Issue.record("expected success on a tab-separated verdict")
            return
        }
        #expect(token == "REJECT")
        #expect(reason == "missing tests")
    }

    @Test("JSON array parses through prose wrapping, mixed element types")
    func jsonArrayParsing() {
        let text = """
        Here are the items you asked for:
        [{"path": "/a.txt"}, "bare-string", 42, null]
        Hope that helps!
        """
        guard case .success(.items(let items)) = EvaluationRunner.parseJSONArray(text) else {
            Issue.record("expected success")
            return
        }
        #expect(items.count == 4)
        #expect(items[0].contains("\"path\""))
        #expect(items[1] == "bare-string")
        #expect(items[2] == "42")
        #expect(items[3] == "null")
    }

    @Test("Missing array is a parse failure, not a crash")
    func missingArrayFails() {
        guard case .failure = EvaluationRunner.parseJSONArray("no array here") else {
            Issue.record("expected failure")
            return
        }
    }
}

// MARK: - Runner loop

@Suite("EvaluationRunner loop")
struct EvaluationRunnerLoopTests {

    private func runOutcome(
        _ definition: EvaluatorDefinition,
        userMessage: String = "Task: t\nCriterion: c",
        provider: MockLLMProvider,
        tools: [any AgentTool] = []
    ) async -> EvaluationRunner.Outcome {
        await EvaluationRunner.runMessages(
            definition: definition,
            systemPrompt: definition.systemPrompt,
            userMessage: userMessage,
            provider: provider,
            tools: tools,
            toolContext: TestToolContext.make()
        ).outcome
    }

    @Test("Happy path: one call, verdict returned, user message delivered")
    func happyPath() async {
        let provider = MockLLMProvider(responses: [LLMResponse(text: "ACCEPT")])
        let outcome = await runOutcome(makeDefinition(), userMessage: "Task: Fix the bug\nCriterion: Tests pass", provider: provider)
        #expect(outcome == .verdict(token: "ACCEPT", reason: nil))
        #expect(provider.receivedMessages.first?.last?.content.textValue?.contains("Fix the bug") == true)
    }

    @Test("Tool round: evaluator reads evidence, then issues its verdict")
    func toolRoundThenVerdict() async throws {
        let tempDir = TempDir()
        defer { tempDir.cleanup() }
        let evidencePath = try tempDir.write("all tests green", to: "evidence.txt")

        let readCall = LLMToolCall(id: "call-1", name: "file_read", arguments: "{\"path\": \"\(evidencePath)\"}")
        let provider = MockLLMProvider(responses: [
            LLMResponse(toolCalls: [readCall]),
            LLMResponse(text: "ACCEPT: evidence confirms tests are green")
        ])
        let outcome = await runOutcome(makeDefinition(tools: ["file_read"]), provider: provider, tools: [FileReadTool()])
        guard case .verdict(let token, _) = outcome else {
            Issue.record("expected verdict, got \(outcome)")
            return
        }
        #expect(token == "ACCEPT")
        #expect(provider.callCount == 2)
        // The evidence must have reached the second call as a tool result.
        let secondCallMessages = provider.receivedMessages.last ?? []
        let evidenceDelivered = secondCallMessages.contains {
            if case .toolResult(_, let content) = $0.content { return content.contains("all tests green") }
            return false
        }
        #expect(evidenceDelivered)
    }

    @Test("A non-allowlisted tool call is refused but the loop continues")
    func nonAllowlistedToolRefused() async {
        let sneaky = LLMToolCall(id: "call-1", name: "bash", arguments: "{\"command\": \"echo hi\"}")
        let provider = MockLLMProvider(responses: [
            LLMResponse(toolCalls: [sneaky]),
            LLMResponse(text: "ACCEPT")
        ])
        let outcome = await runOutcome(makeDefinition(), provider: provider)
        #expect(outcome == .verdict(token: "ACCEPT", reason: nil))
        let secondCallMessages = provider.receivedMessages.last ?? []
        let refusalDelivered = secondCallMessages.contains {
            if case .toolResult(_, let content) = $0.content { return content.contains("not permitted") }
            return false
        }
        #expect(refusalDelivered)
    }

    @Test("Persistent grammar violations end in ERROR, never a fake verdict")
    func persistentParseFailureErrors() async {
        let provider = MockLLMProvider(responses: [LLMResponse(text: "I feel good about this one!")])
        let outcome = await runOutcome(makeDefinition(), provider: provider)
        guard case .error(let why) = outcome else {
            Issue.record("expected error, got \(outcome)")
            return
        }
        #expect(why.contains("unparseable"))
    }

    @Test("Turn exhaustion ends in ERROR")
    func turnExhaustionErrors() async {
        let loopingCall = LLMToolCall(id: "c", name: "nope", arguments: "{}")
        let provider = MockLLMProvider(responses: [LLMResponse(toolCalls: [loopingCall])])
        let outcome = await runOutcome(makeDefinition(maxTurns: 3), provider: provider)
        guard case .error(let why) = outcome else {
            Issue.record("expected error, got \(outcome)")
            return
        }
        #expect(why.contains("turns"))
    }
}

// MARK: - Registry

@Suite("EvaluatorRegistry")
struct EvaluatorRegistryTests {

    @Test("Loads valid definitions, surfaces malformed ones as failures")
    func loadsAndSurfacesFailures() throws {
        let dir = TempDir()
        defer { dir.cleanup() }

        let valid = makeDefinition()
        try JSONEncoder().encode(valid).write(to: URL(fileURLWithPath: dir.path).appendingPathComponent("valid.json"))
        try dir.write("{ not json", to: "broken.json")
        try dir.write("ignored", to: "notes.txt")

        let registry = EvaluatorRegistry.load(from: URL(fileURLWithPath: dir.path))
        #expect(registry.definition(named: "test-validator") != nil)
        #expect(registry.failures.count == 1)
        #expect(registry.failures.first?.fileName == "broken.json")
        // Built-ins (the default validator) load alongside user files.
        let userValidators = registry.definitions(ofKind: .validator).filter { !EvaluatorDefaults.builtInNames.contains($0.name) }
        #expect(userValidators.count == 1)
        #expect(registry.definitions(ofKind: .scoper).isEmpty)
    }

    @Test("Duplicate names are rejected deterministically")
    func duplicateNamesRejected() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let definition = makeDefinition()
        let data = try JSONEncoder().encode(definition)
        try data.write(to: URL(fileURLWithPath: dir.path).appendingPathComponent("a.json"))
        try data.write(to: URL(fileURLWithPath: dir.path).appendingPathComponent("b.json"))

        let registry = EvaluatorRegistry.load(from: URL(fileURLWithPath: dir.path))
        #expect(registry.definitions.count == 1 + EvaluatorDefaults.builtInDefinitions.count)
        #expect(registry.failures.first?.fileName == "b.json")
        #expect(registry.failures.first?.problem.contains("duplicate") == true)
    }

    @Test("A missing directory yields just the built-ins, not an error")
    func missingDirectoryIsEmpty() {
        let registry = EvaluatorRegistry.load(from: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID())"))
        #expect(registry.definitions.count == EvaluatorDefaults.builtInDefinitions.count)
        #expect(registry.definition(named: "default") != nil)
        #expect(registry.failures.isEmpty)
    }
}
