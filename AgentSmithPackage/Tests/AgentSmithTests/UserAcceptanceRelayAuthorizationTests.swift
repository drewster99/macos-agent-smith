import Foundation
import Testing
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

/// What authorizes Smith to relay the user's sign-off (`respond_to_user_acceptance`): a park waiting
/// only on that sign-off, with a recorded start, and a message the user typed into the app AFTER that
/// start which Smith has read in its current stretch of activity. Covers the park stamp the status
/// writer owns, the authorization truth table, the store CAS against a stale park, the per-agent
/// ledger, the actor wiring that feeds it, and the tool's availability.
@Suite("User-acceptance relay authorization", .serialized)
struct UserAcceptanceRelayAuthorizationTests {

    private static let sharedEngine = SemanticSearchEngine()

    /// A task parked for the user's sign-off with validation switched off — the simplest park that
    /// waits on nothing but the user (no ledger needed).
    private func signOffPark(_ store: TaskStore) async throws -> AgentTask {
        let task = await store.addTask(title: "Gated", description: "d", requiresUserAcceptance: true)
        await store.setResult(id: task.id, result: "done", commentary: nil, attachments: [])
        #expect(await store.driveStatus(id: task.id, to: .validating))
        #expect(await store.updateStatus(id: task.id, to: .awaitingReview, ifCurrentlyIn: [.validating],
                                         cause: .userAcceptanceRequested(validationWasRun: false)))
        return try #require(await store.task(id: task.id))
    }

    private func record(at date: Date, _ text: String = "looks good") -> InAppUserMessageRecord {
        InAppUserMessageRecord(messageID: UUID(), authoredAt: date, excerpt: text)
    }

    // MARK: - The park stamp

    @Test("Entering a park stamps its start in the same write; leaving clears it; re-parking is a new park")
    func parkStampLifecycle() async throws {
        let store = TaskStore()
        let parked = try await signOffPark(store)
        let firstStart = try #require(parked.awaitingReviewParkedAt)
        let firstPark = try #require(parked.relayableSignOffPark)
        #expect(firstPark == AgentTask.SignOffPark(statusRevision: parked.statusRevision, parkedAt: firstStart))

        #expect(await store.updateStatus(id: parked.id, status: .validating, cause: .userRevalidated))
        #expect(await store.task(id: parked.id)?.awaitingReviewParkedAt == nil)

        #expect(await store.updateStatus(id: parked.id, to: .awaitingReview, ifCurrentlyIn: [.validating],
                                         cause: .userAcceptanceRequested(validationWasRun: false)))
        let reparked = try #require(await store.task(id: parked.id))
        let secondPark = try #require(reparked.relayableSignOffPark)
        #expect(secondPark != firstPark)
        #expect(secondPark.parkedAt >= firstStart)
        #expect(!reparked.admitsEscalationResolution(by: .smithRelayingUser(park: firstPark)),
                "a reply authorized for the first park does not resolve the second")
        #expect(reparked.admitsEscalationResolution(by: .smithRelayingUser(park: secondPark)))
    }

    @Test("The store's CAS refuses a relay naming a park that has since ended and re-entered")
    func staleParkRefusedInsideCAS() async throws {
        let store = TaskStore()
        let parked = try await signOffPark(store)
        let stalePark = try #require(parked.relayableSignOffPark)
        #expect(await store.updateStatus(id: parked.id, status: .validating, cause: .userRevalidated))
        #expect(await store.updateStatus(id: parked.id, to: .awaitingReview, ifCurrentlyIn: [.validating],
                                         cause: .userAcceptanceRequested(validationWasRun: false)))

        #expect(await store.acceptAwaitingReviewHoldingEffects(id: parked.id, resolvedBy: .smithRelayingUser(park: stalePark)) == nil)
        #expect(await store.updateStatus(id: parked.id, to: .running, ifCurrentlyIn: [.awaitingReview],
                                         ifResolvableBy: .smithRelayingUser(park: stalePark), cause: .userSentBack) == false)
        #expect(await store.task(id: parked.id)?.status == .awaitingReview)

        let currentPark = try #require(await store.task(id: parked.id)?.relayableSignOffPark)
        let accepted = await store.acceptAwaitingReviewHoldingEffects(id: parked.id, resolvedBy: .smithRelayingUser(park: currentPark))
        #expect(accepted?.cause == .userAcceptanceGranted(validationWasRun: false))
    }

    @Test("Restore clears a park start on a task that is not parked, including a migrated help park")
    func restoreScrubsParkStart() async {
        var pending = AgentTask(title: "p", description: "d")
        pending.status = .pending
        pending.awaitingReviewParkedAt = Date()
        var oldHelpPark = AgentTask(title: "h", description: "d", helpRequest: "stuck")
        oldHelpPark.status = .awaitingReview
        oldHelpPark.awaitingReviewParkedAt = Date()
        var signOff = AgentTask(title: "s", description: "d", requiresUserAcceptance: true)
        signOff.status = .awaitingReview
        signOff.awaitingReviewReason = .userAcceptanceRequestedValidationSkipped
        let start = Date(timeIntervalSince1970: 1_000)
        signOff.awaitingReviewParkedAt = start

        let store = TaskStore()
        await store.restore([pending, oldHelpPark, signOff])
        #expect(await store.task(id: pending.id)?.awaitingReviewParkedAt == nil)
        #expect(await store.task(id: oldHelpPark.id)?.status == .awaitingHelp)
        #expect(await store.task(id: oldHelpPark.id)?.awaitingReviewParkedAt == nil)
        #expect(await store.task(id: signOff.id)?.awaitingReviewParkedAt == start, "a live park keeps its start")
    }

    @Test("The park start round-trips through JSON, and a task written before it existed decodes without one")
    func parkStartCodable() throws {
        var task = AgentTask(title: "t", description: "d")
        task.status = .awaitingReview
        task.awaitingReviewParkedAt = Date(timeIntervalSince1970: 1_234_567)
        let data = try JSONEncoder().encode(task)
        #expect(try JSONDecoder().decode(AgentTask.self, from: data).awaitingReviewParkedAt == task.awaitingReviewParkedAt)

        task.awaitingReviewParkedAt = nil
        let legacy = try JSONEncoder().encode(task)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("awaitingReviewParkedAt"))
        #expect(try JSONDecoder().decode(AgentTask.self, from: legacy).awaitingReviewParkedAt == nil)
    }

    // MARK: - The authorization truth table

    @Test("Authorization: needs a sign-off park, a known start, and a message written after it")
    func authorizationTruthTable() async throws {
        let store = TaskStore()
        let parked = try await signOffPark(store)
        let start = try #require(parked.awaitingReviewParkedAt)
        let park = try #require(parked.relayableSignOffPark)

        #expect(parked.userAcceptanceRelayAuthorization(by: nil) == .failure(.noInAppUserMessageThisStretch))
        let before = record(at: start.addingTimeInterval(-1))
        #expect(parked.userAcceptanceRelayAuthorization(by: before) == .failure(.messagePredatesPark(message: before, parkedAt: start)))
        let simultaneous = record(at: start)
        #expect(parked.userAcceptanceRelayAuthorization(by: simultaneous) == .failure(.messagePredatesPark(message: simultaneous, parkedAt: start)),
                "only a message strictly after the park can be about it")
        let after = record(at: start.addingTimeInterval(1))
        #expect(parked.userAcceptanceRelayAuthorization(by: after) == .success(AgentTask.UserAcceptanceRelayGrant(park: park, message: after)))

        var unstamped = parked
        unstamped.awaitingReviewParkedAt = nil
        #expect(unstamped.relayableSignOffPark == nil)
        #expect(unstamped.userAcceptanceRelayAuthorization(by: after) == .failure(.parkStartUnknown))

        var validatorError = parked
        validatorError.awaitingReviewReason = .validatorError
        #expect(validatorError.userAcceptanceRelayAuthorization(by: after) == .failure(.notAwaitingUserSignOff))

        var running = parked
        running.status = .running
        #expect(running.userAcceptanceRelayAuthorization(by: after) == .failure(.notAwaitingUserSignOff))
    }

    // MARK: - The ledger

    @Test("Ledger: a delivery counts only once incorporated, and only buffer deliveries count")
    func ledgerCountsOnlyIncorporatedDeliveries() {
        var ledger = InAppUserMessageLedger()
        let message = ChannelMessage(sender: .user, recipientID: UUID(), recipient: .agent(.smith), content: "ship it")
        ledger.recordBufferDelivery(message)
        #expect(ledger.latestIncorporated == nil, "delivered but not yet read is not seen")
        ledger.markIncorporated([UUID()])
        #expect(ledger.latestIncorporated == nil, "an id that was never a buffer delivery promotes nothing")
        ledger.markIncorporated([message.id])
        #expect(ledger.latestIncorporated == InAppUserMessageRecord(messageID: message.id, authoredAt: message.timestamp, excerpt: "ship it"))
    }

    @Test("Ledger: the latest is the latest WRITTEN, whatever order they were read in")
    func ledgerLatestIsByAuthorship() {
        var ledger = InAppUserMessageLedger()
        let older = ChannelMessage(timestamp: Date(timeIntervalSince1970: 100), sender: .user, content: "older")
        let newer = ChannelMessage(timestamp: Date(timeIntervalSince1970: 200), sender: .user, content: "newer")
        ledger.recordBufferDelivery(newer)
        ledger.recordBufferDelivery(older)
        ledger.markIncorporated([newer.id])
        ledger.markIncorporated([older.id])
        #expect(ledger.latestIncorporated?.messageID == newer.id)
    }

    @Test("Ledger: ending a stretch forgets what was read but keeps what is still unread")
    func ledgerStretchEnd() {
        var ledger = InAppUserMessageLedger()
        let read = ChannelMessage(sender: .user, content: "read")
        let unread = ChannelMessage(sender: .user, content: "unread")
        ledger.recordBufferDelivery(read)
        ledger.recordBufferDelivery(unread)
        ledger.markIncorporated([read.id])
        ledger.endStretch()
        #expect(ledger.latestIncorporated == nil)
        ledger.markIncorporated([unread.id])
        #expect(ledger.latestIncorporated?.messageID == unread.id)
    }

    @Test("Ledger: the excerpt is trimmed and bounded")
    func ledgerExcerpt() {
        #expect(InAppUserMessageLedger.excerpt(of: "  hi \n") == "hi")
        let limit = InAppUserMessageLedger.excerptCharacterLimit
        #expect(InAppUserMessageLedger.excerpt(of: String(repeating: "a", count: limit)) == String(repeating: "a", count: limit))
        #expect(InAppUserMessageLedger.excerpt(of: String(repeating: "a", count: limit + 1)) == String(repeating: "a", count: limit) + "…")
    }

    // MARK: - The actor feeds the ledger

    /// Holds every LLM call until the test releases it, so the test can look at the agent mid-turn —
    /// after the run loop has drained its input, before the turn ends and the agent goes idle.
    private final class GatedLLMProvider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var entered = 0
        private var released = 0

        var enteredCount: Int { lock.withLock { entered } }
        func releaseAll() { lock.withLock { released = Int.max } }

        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            let call = lock.withLock { entered += 1; return entered }
            while lock.withLock({ released < call }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            return LLMResponse(text: "ok")
        }
    }

    private func makeSmith() -> (AgentActor, UUID, GatedLLMProvider) {
        let agentID = UUID()
        let provider = GatedLLMProvider()
        let context = ToolContext(
            agentID: agentID,
            agentRole: .smith,
            channel: MessageChannel(),
            taskStore: TaskStore(),
            spawnBrown: { _ in nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .smith },
            memoryStore: MemoryStore(engine: Self.sharedEngine),
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        let agent = AgentActor(
            id: agentID,
            configuration: AgentConfiguration(
                role: .smith,
                llmConfig: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model",
                                              maxOutputTokens: 1024, maxContextTokens: 100_000),
                systemPrompt: "test-system"
            ),
            provider: provider,
            tools: [],
            toolContext: context
        )
        return (agent, agentID, provider)
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("A user message delivered through the buffer authorizes for the rest of the stretch; going idle ends it")
    func bufferDeliveryAuthorizesUntilIdle() async {
        let (agent, agentID, provider) = makeSmith()
        await agent.start()
        let message = ChannelMessage(sender: .user, recipientID: agentID, recipient: .agent(.smith), content: "ship it")
        #expect(await agent.acceptChannelMessage(message))
        #expect(await waitUntil { provider.enteredCount >= 1 })
        #expect(await agent.latestInAppUserMessageThisStretch()?.messageID == message.id)
        #expect(await agent.latestInAppUserMessageThisStretch()?.authoredAt == message.timestamp)

        provider.releaseAll()
        #expect(await waitUntil { await agent.latestInAppUserMessageThisStretch() == nil },
                "the agent went idle; the reply must not carry into a later stretch")
        await agent.stop()
    }

    @Test("A user message on the live subscription — an inspector direct message — authorizes nothing")
    func liveSubscriptionDoesNotAuthorize() async {
        let (agent, agentID, provider) = makeSmith()
        await agent.start()
        await agent.receiveChannelMessage(ChannelMessage(sender: .user, recipientID: agentID, recipient: .agent(.smith), content: "ship it"))
        #expect(await waitUntil { provider.enteredCount >= 1 })
        #expect(await agent.latestInAppUserMessageThisStretch() == nil)
        provider.releaseAll()
        await agent.stop()
    }

    @Test("A public user message accepted through the buffer path is not one addressed to Smith, and authorizes nothing")
    func unaddressedUserMessageDoesNotAuthorize() async {
        let (agent, _, provider) = makeSmith()
        await agent.start()
        #expect(await agent.acceptChannelMessage(ChannelMessage(sender: .user, content: "ship it")))
        #expect(await waitUntil { provider.enteredCount >= 1 })
        #expect(await agent.latestInAppUserMessageThisStretch() == nil)
        provider.releaseAll()
        await agent.stop()
    }

    @Test("Clearing the conversation forgets the reply it held")
    func clearEndsStretch() async {
        let (agent, agentID, provider) = makeSmith()
        await agent.start()
        let message = ChannelMessage(sender: .user, recipientID: agentID, recipient: .agent(.smith), content: "ship it")
        #expect(await agent.acceptChannelMessage(message))
        #expect(await waitUntil { provider.enteredCount >= 1 })
        #expect(await agent.latestInAppUserMessageThisStretch() != nil)
        await agent.resetConversationHistory(orientation: nil)
        #expect(await agent.latestInAppUserMessageThisStretch() == nil)
        provider.releaseAll()
        await agent.stop()
    }

    // MARK: - The tool

    @Test("respond_to_user_acceptance is offered to Smith only while a relayable sign-off park exists")
    func toolAvailability() {
        let tool = RespondToUserAcceptanceTool()
        #expect(tool.isAvailable(in: ToolAvailabilityContext(agentRole: .smith, hasTasksAwaitingUserSignOff: true)))
        #expect(!tool.isAvailable(in: ToolAvailabilityContext(agentRole: .smith, hasTasksAwaitingUserSignOff: false)))
        #expect(!tool.isAvailable(in: ToolAvailabilityContext(agentRole: .brown, hasTasksAwaitingUserSignOff: true)))
    }
}
