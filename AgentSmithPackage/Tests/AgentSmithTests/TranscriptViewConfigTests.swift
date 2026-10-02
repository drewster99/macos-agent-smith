import Testing
import Foundation
@testable import AgentSmithKit

/// The transcript filter model: every kind is grouped exactly once (so a new kind can't vanish from
/// the filter), a config renders to the filter it claims, every legacy generation migrates to
/// exactly what it showed, and the persisted form is diff-stable and fails open.
@Suite struct TranscriptViewConfigTests {

    private static let everyone = TranscriptViewConfig.participants

    private static func message(
        _ kind: ChannelMessageKind? = nil,
        from sender: ChannelMessage.Sender = .agent(.smith),
        to recipient: MessageRecipient? = nil,
        severity: MessageSeverity? = nil,
        tool: String? = nil
    ) -> ChannelMessage {
        var metadata: [String: AnyCodable] = [:]
        if let kind { metadata["messageKind"] = .kind(kind) }
        if let severity { metadata["severity"] = .severity(severity) }
        if let tool { metadata["tool"] = .string(tool) }
        return ChannelMessage(
            sender: sender,
            recipientID: recipient == nil ? nil : UUID(),
            recipient: recipient,
            content: "x",
            metadata: metadata.isEmpty ? nil : metadata)
    }

    private static func decode(_ json: String) throws -> TranscriptViewConfig {
        try JSONDecoder().decode(TranscriptViewConfig.self, from: Data(json.utf8))
    }

    // MARK: - Grouping

    /// COMPLETENESS GUARD. Every `ChannelMessageKind` must belong to exactly one non-chat group, or
    /// it would be silently untoggleable in the filter.
    @Test func everyKindBelongsToExactlyOneGroup() {
        var seen: [ChannelMessageKind: [TranscriptKindGroup]] = [:]
        for group in TranscriptKindGroup.allCases {
            for kind in group.kinds {
                seen[kind, default: []].append(group)
            }
        }
        let doubled = seen.filter { $0.value.count > 1 }
        #expect(doubled.isEmpty, "Kinds in more than one group: \(doubled)")
        let covered = Set(seen.keys)
        let all = Set(ChannelMessageKind.allCases)
        #expect(covered == all, "Ungrouped kinds: \(all.subtracting(covered))")
        #expect(TranscriptKindGroup.chat.kinds.isEmpty)
        #expect(TranscriptKindGroup.chat.targets == [.chat])
    }

    // MARK: - Presets render to the filter they claim

    @Test func everythingConfigIsTheFirehose() {
        #expect(TranscriptViewConfig.everything.makeFilter() == TranscriptFilter.all)
    }

    @Test func conversationIsOrchestrationWithoutBrownOrPlumbing() {
        let filter = TranscriptViewConfig.conversation.makeFilter()
        // Tool calls and security reviews are off (2026-09-20 audit) — safe only because the
        // problem policy still surfaces failures.
        for kind in TranscriptKindGroup.toolCalls.kinds.union(TranscriptKindGroup.securityReviews.kinds) {
            #expect(!filter.matches(Self.message(kind)), "\(kind.rawValue) should be hidden" as Comment)
        }
        #expect(filter.matches(Self.message(.toolOutput, severity: .error)))
        #expect(filter.alwaysShowAtOrAbove == .warning)
        #expect(filter.hideErrors == false)
        #expect(filter.matches(Self.message()))
        #expect(filter.taskScope == .orchestration)
        // Nothing from Brown, and nothing addressed to Brown.
        #expect(!filter.matches(Self.message(from: .agent(.brown))))
        #expect(!filter.matches(Self.message(from: .agent(.smith), to: .agent(.brown))))
        #expect(filter.matches(Self.message(from: .agent(.smith), to: .user)))
    }

    /// A real security review of a Brown call is posted `.system`, public, stamped with the worker's
    /// task — so in the conversation view it's the TASK SCOPE that drops it.
    @Test func conversationDropsRealSecurityReviewViaTaskScope() {
        let filter = TranscriptViewConfig.conversation.makeFilter()
        #expect(!filter.matches(ChannelMessage(sender: .system, content: "Security Agent → Brown: SAFE", taskID: UUID())))
        #expect(filter.matches(ChannelMessage(sender: .system, content: "Security Agent → Brown: SAFE")))
    }

    @Test func condensedKeepsRequestsButHidesOutputAndReviews() {
        let filter = TranscriptViewConfig.condensed.makeFilter()
        #expect(filter.matches(Self.message(.toolRequest, from: .agent(.brown))))
        #expect(!filter.matches(Self.message(.toolOutput, from: .agent(.brown))))
        #expect(!filter.matches(Self.message(.securityReview, from: .system)))
        #expect(filter.matches(Self.message(.taskUpdate, from: .agent(.brown))))
    }

    @Test func explicitTaskScopeOverridesTheConfigsOwn() {
        let id = UUID()
        #expect(TranscriptViewConfig.conversation.makeFilter(taskScope: .task(id)).taskScope == .task(id))
    }

    // MARK: - Participant axis

    /// Hiding a participant hides what they send AND private messages addressed to them — the one
    /// meaning "hide Brown" has — while public messages from others still show.
    @Test func hiddenParticipantDropsMessagesFromAndToThem() {
        var config = TranscriptViewConfig.everything
        config.setParticipant(.agent(.brown), shown: false)
        let filter = config.makeFilter()
        #expect(!filter.matches(Self.message(from: .agent(.brown))))
        #expect(!filter.matches(Self.message(from: .agent(.securityAgent), to: .agent(.brown))))
        #expect(filter.matches(Self.message(from: .agent(.securityAgent))))
        #expect(filter.matches(Self.message(from: .user, to: .agent(.smith))))
        config.setParticipant(.agent(.brown), shown: true)
        #expect(config == .everything)
    }

    /// The problem floor outranks the participant axis, like every noise axis.
    @Test func hiddenParticipantsProblemsStillShowUnderTheFloor() {
        var config = TranscriptViewConfig.everything
        config.setParticipant(.agent(.brown), shown: false)
        #expect(config.makeFilter().matches(Self.message(from: .agent(.brown), severity: .error)))
        config.problems = .filterNormally
        #expect(!config.makeFilter().matches(Self.message(from: .agent(.brown), severity: .error)))
    }

    // MARK: - Authorship of system-posted verdicts

    /// A Security Agent verdict exactly as `AgentActor` persists it (2026-10-02 channel log): posted
    /// by the SYSTEM, kind `security_review`, stamped with the reviewed agent's role, public.
    private static func verdict(about role: AgentRole = .brown, severity: MessageSeverity = .info,
                                legacyKindless: Bool = false) -> ChannelMessage {
        var metadata: [String: AnyCodable] = [
            "securityDisposition": .string(severity == .warning ? "warning" : "approved"),
            "agentRole": .string(role.rawValue),
            "severity": .severity(severity)
        ]
        if !legacyKindless { metadata["messageKind"] = .kind(.securityReview) }
        return ChannelMessage(sender: .system, content: "Security Agent → Brown: SAFE", metadata: metadata)
    }

    @Test func aVerdictIsAuthoredByTheSecurityAgentAndAddressedToTheReviewedAgent() {
        #expect(Self.verdict().author == .agent(.securityAgent))
        #expect(Self.verdict().addressee == .agent(.brown))
        #expect(Self.verdict(legacyKindless: true).author == .agent(.securityAgent))
        // An ordinary system notice is still the system's, and an unstamped one is to nobody.
        #expect(Self.message(from: .system).author == .system)
        #expect(Self.message(from: .system).addressee == nil)
        #expect(Self.message(from: .agent(.smith), to: .user).addressee == .user)
    }

    /// The user-visible bug: verdicts filtered as "System". Hiding System must not touch them;
    /// hiding the Security Agent, or the agent they are addressed to, must.
    @Test func participantFilteringFollowsTheAuthorNotThePoster() {
        var config = TranscriptViewConfig.everything
        config.problems = .filterNormally
        config.setParticipant(.system, shown: false)
        #expect(config.makeFilter().matches(Self.verdict()))
        config.setParticipant(.system, shown: true)
        config.setParticipant(.agent(.securityAgent), shown: false)
        #expect(!config.makeFilter().matches(Self.verdict()))
        config.setParticipant(.agent(.securityAgent), shown: true)
        config.setParticipant(.agent(.brown), shown: false)
        #expect(!config.makeFilter().matches(Self.verdict()))
    }

    /// The per-participant activity selection that governs a verdict is the Security Agent's.
    @Test func perParticipantActivityFollowsTheAuthor() {
        var config = TranscriptViewConfig.everything
        config.problems = .filterNormally
        config.setVisible(false, targets: [.kind(.securityReview)], for: [.system])
        #expect(config.makeFilter().matches(Self.verdict()))
        config.setVisible(false, targets: [.kind(.securityReview)], for: [.agent(.securityAgent)])
        #expect(!config.makeFilter().matches(Self.verdict()))
    }

    /// A WARN verdict with everything hidden still shows under the default policy — by design —
    /// and the counts now say that it is shown ONLY for that reason, per row and in total.
    @Test func statsReportWhatIsShownOnlyAsAProblem() {
        var config = TranscriptViewConfig.everything
        for participant in Self.everyone { config.setParticipant(participant, shown: false) }
        let messages = [Self.verdict(severity: .warning), Self.verdict(), Self.message(from: .user)]
        #expect(config.makeFilter().matches(Self.verdict(severity: .warning)))
        let stats = TranscriptFilterStats.compute(messages: messages, config: config, universe: .any, scope: .any)
        #expect(stats.shown == 1)
        #expect(stats.shownOnlyAsProblems == 1)
        #expect(stats.problemCount(of: TranscriptKindGroup.securityReviews.targets, for: Self.everyone) == 1)
        #expect(stats.count(of: TranscriptKindGroup.securityReviews.targets, for: [.agent(.securityAgent)]) == 2)
        #expect(stats.count(of: TranscriptKindGroup.securityReviews.targets, for: [.system]) == 0)
        #expect(stats.involving[.agent(.brown)] == 2)

        config.problems = .filterNormally
        let strict = TranscriptFilterStats.compute(messages: messages, config: config, universe: .any, scope: .any)
        #expect(strict.shown == 0)
        #expect(strict.shownOnlyAsProblems == 0)
    }

    // MARK: - Verdict classes, delivery, tool scope

    /// The class mapping must agree with what actually gated the call: a class that says "accepted"
    /// for a call that never ran would hide exactly the verdict a reader needs.
    @Test func verdictClassesAgreeWithWhetherTheCallRan() {
        let outcomes: [SecurityDisposition.Outcome] = [
            .approved, .autoApproved, .approvedWithoutReview, .warned, .refused(.unsafe), .refused(.abort),
            .reviewerUnavailable(.noEvaluatorConfigured), .reviewCancelled
        ]
        for outcome in outcomes {
            let disposition = SecurityDisposition(outcome: outcome)
            let verdictClass = SecurityVerdictClass.forDispositionTag(disposition.channelTag)
            let expected: SecurityVerdictClass = disposition.approved ? .accept : (outcome == .warned ? .warn : .block)
            #expect(verdictClass == expected, "\(disposition.channelTag)" as Comment)
        }
        #expect(SecurityVerdictClass.forDispositionTag("someFutureTag") == .block)
    }

    private static func verdict(tag: String, requestID: String? = "call_1", taskID: UUID? = nil) -> ChannelMessage {
        var metadata: [String: AnyCodable] = [
            "messageKind": .kind(.securityReview), "securityDisposition": .string(tag), "agentRole": .string("brown")
        ]
        if let requestID { metadata["requestID"] = .string(requestID) }
        return ChannelMessage(sender: .system, content: "Security Agent → Brown", metadata: metadata, taskID: taskID)
    }

    @Test func eachVerdictClassFiltersIndependently() {
        var config = TranscriptViewConfig.everything
        config.problems = .filterNormally
        config.setVisible(false, targets: [.securityVerdict(.warn)], for: Self.everyone)
        let filter = config.makeFilter()
        #expect(filter.matches(Self.verdict(tag: "approved")))
        #expect(!filter.matches(Self.verdict(tag: "warning")))
        #expect(filter.matches(Self.verdict(tag: "denied")))
        #expect(config.visibility(of: TranscriptKindGroup.securityReviews.targets, for: Self.everyone) == .mixed)
    }

    private static func toolRequest(_ requestID: String, taskID: UUID? = nil) -> ChannelMessage {
        ChannelMessage(sender: .agent(.brown), content: "bash",
                       metadata: ["messageKind": .kind(.toolRequest), "requestID": .string(requestID),
                                  "tool": .string("bash")],
                       taskID: taskID)
    }

    /// The reported bug: hiding verdicts stripped every tool call's status icon. A hidden verdict
    /// on a DELIVERED tool call is still delivered (for its call's row) but not shown.
    @Test func hiddenVerdictIsDeliveredWithItsToolCall() {
        var config = TranscriptViewConfig.everything
        config.problems = .filterNormally
        config.setVisible(false, targets: TranscriptKindGroup.securityReviews.targets, for: Self.everyone)
        let task = UUID()
        var delivery = TranscriptDelivery(filter: config.makeFilter(taskScope: .task(task)))
        let verdict = Self.verdict(tag: "approved", requestID: "call_1", taskID: task)
        #expect(!delivery.filter.matches(verdict))
        let delivered = delivery.admitted(from: [Self.toolRequest("call_1", taskID: task), verdict])
        #expect(delivered.count == 2)
        // One verdict per call: the call's entry is spent, so a stray repeat is withheld.
        let repeatAdmitted = delivery.admits(verdict)
        #expect(!repeatAdmitted)
    }

    /// A hidden verdict whose call the pane does NOT show is withheld: it would never draw, and the
    /// default Conversation pane (tool calls hidden) would otherwise fill its render window with
    /// such rows.
    @Test func hiddenVerdictIsWithheldWhenItsCallIsNotShown() {
        var config = TranscriptViewConfig.everything
        config.problems = .filterNormally
        config.setVisible(false, targets: TranscriptKindGroup.securityReviews.targets, for: Self.everyone)
        config.setVisible(false, targets: TranscriptKindGroup.toolCalls.targets, for: Self.everyone)
        var delivery = TranscriptDelivery(filter: config.makeFilter())
        let withheld = delivery.admitted(from: [Self.toolRequest("call_1"), Self.verdict(tag: "approved")])
        #expect(withheld.isEmpty)
        // A verdict for some OTHER call, or for none, is withheld even with tool calls shown.
        config.setVisible(true, targets: TranscriptKindGroup.toolCalls.targets, for: Self.everyone)
        delivery = TranscriptDelivery(filter: config.makeFilter())
        let requestAdmitted = delivery.admits(Self.toolRequest("call_1"))
        let otherCallAdmitted = delivery.admits(Self.verdict(tag: "approved", requestID: "call_2"))
        let noCallAdmitted = delivery.admits(Self.verdict(tag: "approved", requestID: nil))
        #expect(requestAdmitted)
        #expect(!otherCallAdmitted)
        #expect(!noCallAdmitted)
        // Anything else hidden stays undelivered.
        config.setVisible(false, targets: [.chat], for: Self.everyone)
        delivery = TranscriptDelivery(filter: config.makeFilter())
        let chatAdmitted = delivery.admits(Self.message(from: .user))
        #expect(!chatAdmitted)
    }

    /// A SHOWN verdict is delivered whether or not its call is — it then renders as its own row.
    @Test func shownVerdictIsDeliveredWithoutItsCall() {
        var config = TranscriptViewConfig.everything
        config.problems = .filterNormally
        config.setVisible(false, targets: TranscriptKindGroup.toolCalls.targets, for: Self.everyone)
        var delivery = TranscriptDelivery(filter: config.makeFilter())
        let admitted = delivery.admits(Self.verdict(tag: "approved"))
        #expect(admitted)
    }

    @Test func toolScopeIsTheSecurityAgentsAndHasItsOwnSwitch() {
        let scope = ChannelMessage(sender: .system, content: "Security Agent → Brown: tool scope",
                                   metadata: ["messageKind": .kind(.toolScopeReview), "agentRole": .string("brown")])
        #expect(scope.author == .agent(.securityAgent))
        #expect(scope.addressee == .agent(.brown))
        #expect(scope.securityVerdictClass == nil)
        var config = TranscriptViewConfig.everything
        config.setVisible(false, targets: [.kind(.toolScopeReview)], for: [.agent(.securityAgent)])
        #expect(!config.makeFilter().matches(scope))
        #expect(config.makeFilter().matches(Self.verdict(tag: "approved")))
    }

    /// A call id is provider data that repeats across agents: another agent's verdict on the same id
    /// must not ride in on this pane's call.
    @Test func hiddenVerdictJoinsItsCallByAgentAndCallID() {
        var config = TranscriptViewConfig.everything
        config.problems = .filterNormally
        config.setVisible(false, targets: TranscriptKindGroup.securityReviews.targets, for: Self.everyone)
        var delivery = TranscriptDelivery(filter: config.makeFilter())
        func stamped(_ message: ChannelMessage, agent: String) -> ChannelMessage {
            var copy = message
            copy.metadata?["agentID"] = .string(agent)
            return copy
        }
        let request = stamped(Self.toolRequest("call_1"), agent: "A")
        let otherAgentsVerdict = stamped(Self.verdict(tag: "approved"), agent: "B")
        let ownVerdict = stamped(Self.verdict(tag: "approved"), agent: "A")
        let delivered = delivery.admitted(from: [request, otherAgentsVerdict, ownVerdict])
        #expect(delivered.map(\.id) == [request.id, ownVerdict.id])
    }

    // MARK: - The validator as a participant

    private actor CapturedMessage {
        private(set) var value: ChannelMessage?
        func set(_ message: ChannelMessage) { value = message }
    }

    /// COMPLETENESS GUARD. Every role is offered under the spelling messages key on, and the
    /// validator is never offered as `.agent(.validator)`.
    @Test func everyRoleIsAnOfferedParticipant() {
        for role in AgentRole.allCases {
            #expect(Self.everyone.contains(.participant(for: role)), "\(role) is not an offered participant")
        }
        #expect(!Self.everyone.contains(.agent(.validator)))
        // Display order is a user-visible contract; deriving the list must not change it.
        #expect(Self.everyone == [.user, .agent(.smith), .agent(.brown), .agent(.securityAgent),
                                  .agent(.summarizer), .validator, .system])
    }

    /// Every role stamp — a recipient, an `agentRole` on a system notice, a sender — resolves to the
    /// participant the filter offers.
    @Test func validatorRoleStampsResolveToTheValidatorParticipant() {
        #expect(ChannelMessage.Sender.participant(for: .validator) == .validator)
        #expect(MessageRecipient.agent(.validator).participant == .validator)
        #expect(Self.verdict(about: .validator).addressee == .validator)
        #expect(Self.message(from: .agent(.validator)).author == .validator)
        #expect(Self.message(from: .user, to: .agent(.validator)).addressee == .validator)
        #expect(Self.verdict(about: .brown).addressee == .agent(.brown))
    }

    /// The reported bug: hiding Validator left the Security Agent's verdicts on its evidence calls
    /// visible, while hiding Brown hid Brown's.
    @Test func hidingTheValidatorHidesVerdictsOnItsCalls() {
        var config = TranscriptViewConfig.everything
        config.problems = .filterNormally
        config.setParticipant(.validator, shown: false)
        let filter = config.makeFilter()
        #expect(!filter.matches(Self.verdict(about: .validator)))
        #expect(!filter.matches(Self.message(.toolRequest, from: .validator)))
        #expect(filter.matches(Self.verdict(about: .brown)))
    }

    /// The verdict exactly as the validator's security gate posts it: addressed to the validator,
    /// and scoped to the task — so it lands in that task's pane with its request.
    @Test func validatorVerdictIsAddressedToTheValidatorAndScopedToItsTask() async throws {
        let captured = CapturedMessage()
        let task = UUID()
        await AgentActor.postSecurityReviewToChannel(
            disposition: SecurityDisposition(outcome: .approved),
            callID: "call_1", agentInstanceID: UUID(), reviewedRole: .validator, taskID: task,
            post: { await captured.set($0) })
        let posted = await captured.value
        let verdict = try #require(posted)
        #expect(verdict.author == .agent(.securityAgent))
        #expect(verdict.addressee == .validator)
        #expect(verdict.attributedRole == .validator)
        #expect(verdict.taskID == task)
        #expect(verdict.content.contains("Validator"))

        var shown = TranscriptViewConfig.everything
        shown.problems = .filterNormally
        #expect(shown.makeFilter(taskScope: .task(task)).matches(verdict))
        #expect(!shown.makeFilter(taskScope: .orchestration).matches(verdict))
    }

    /// `.securityReview` among hidden kinds is the saved form of "every verdict hidden"; it never
    /// survives construction, so the class set is the single representation.
    @Test func hiddenSecurityReviewKindNormalizesToClasses() {
        let selection = TranscriptKindSelection(hiddenKinds: [.securityReview, .memorySaved])
        #expect(selection.hiddenKinds == [.memorySaved, .toolScopeReview])
        #expect(selection.hiddenVerdictClasses == Set(SecurityVerdictClass.allCases))
        #expect(!selection.isVisible(.kind(.securityReview)))
        var partial = TranscriptKindSelection()
        partial.setVisible(false, .securityVerdict(.accept))
        #expect(partial.isVisible(.kind(.securityReview)))
    }

    // MARK: - Participant × activity

    @Test func hidingOneKindForEveryoneHidesJustThatKind() {
        var config = TranscriptViewConfig.everything
        config.setVisible(false, targets: [.kind(.toolOutput)], for: Self.everyone)
        let filter = config.makeFilter()
        #expect(!filter.matches(Self.message(.toolOutput, from: .agent(.brown))))
        #expect(filter.matches(Self.message(.toolRequest, from: .agent(.brown))))
        #expect(filter.matches(Self.message(from: .user)))
    }

    /// One participant's selection governs only that participant.
    @Test func perParticipantSelectionGovernsOnlyThatParticipant() {
        var config = TranscriptViewConfig.everything
        config.setVisible(false, targets: [.kind(.toolOutput)], for: [.agent(.brown)])
        config.setVisible(false, targets: [.kind(.memorySaved)], for: [.agent(.smith)])
        let filter = config.makeFilter()
        #expect(!filter.matches(Self.message(.toolOutput, from: .agent(.brown))))
        #expect(filter.matches(Self.message(.toolOutput, from: .agent(.smith))))
        #expect(filter.matches(Self.message(.memorySaved, from: .agent(.brown))))
        #expect(!filter.matches(Self.message(.memorySaved, from: .agent(.smith))))
    }

    @Test func perParticipantChatGovernsTheirKindlessMessages() {
        var config = TranscriptViewConfig.everything
        config.setVisible(false, targets: [.chat], for: [.system])
        let filter = config.makeFilter()
        #expect(!filter.matches(Self.message(from: .system)))
        #expect(filter.matches(Self.message(from: .user)))
    }

    @Test func perParticipantToolHidingHidesBothRowsOfTheExchange() {
        var config = TranscriptViewConfig.everything
        config.setVisible(false, targets: [.tool("bash")], for: [.agent(.brown)])
        let filter = config.makeFilter()
        #expect(!filter.matches(Self.message(.toolRequest, from: .agent(.brown), tool: "bash")))
        #expect(!filter.matches(Self.message(.toolOutput, from: .agent(.brown), tool: "bash")))
        #expect(filter.matches(Self.message(.toolRequest, from: .agent(.brown), tool: "grep")))
        #expect(filter.matches(Self.message(.toolRequest, from: .agent(.smith), tool: "bash")))
    }

    /// The one aggregate behind every checkbox: all / mixed / none over targets × participants.
    @Test func visibilityAggregatesOverTargetsAndParticipants() {
        var config = TranscriptViewConfig.everything
        let tools = TranscriptKindGroup.toolCalls.targets
        #expect(config.visibility(of: tools, for: Self.everyone) == .all)
        config.setVisible(false, targets: [.kind(.toolOutput)], for: [.agent(.brown)])
        #expect(config.visibility(of: tools, for: Self.everyone) == .mixed)
        #expect(config.visibility(of: tools, for: [.agent(.smith)]) == .all)
        #expect(config.visibility(of: [.kind(.toolOutput)], for: [.agent(.brown)]) == .none)
        config.setVisible(false, targets: tools, for: Self.everyone)
        #expect(config.visibility(of: tools, for: Self.everyone) == .none)
        #expect(config.visibility(of: [], for: Self.everyone) == .all)
    }

    /// Selections are sparse: a participant returned to everything-visible has no entry, so two
    /// configs that show the same thing are equal — which preset matching depends on.
    @Test func selectionsStaySparseSoEquivalentConfigsAreEqual() {
        var config = TranscriptViewConfig.everything
        config.setVisible(false, targets: [.kind(.advisory)], for: [.agent(.brown)])
        #expect(config.selections.count == 1)
        config.setVisible(true, targets: [.kind(.advisory)], for: [.agent(.brown)])
        #expect(config.selections.isEmpty)
        #expect(config == .everything)
    }

    @Test func uniformityDetectsParticipantsThatDisagree() {
        var config = TranscriptViewConfig.conversation
        #expect(config.isUniformAcrossParticipants)
        config.setVisible(true, targets: [.kind(.toolRequest)], for: [.agent(.smith)])
        #expect(!config.isUniformAcrossParticipants)
    }

    /// With both tool kinds hidden there are no tool rows to narrow, so per-tool hiding is moot.
    @Test func toolHidingIsDroppedWhileToolCallsAreHidden() {
        var selection = TranscriptKindSelection(hiddenToolNames: ["bash"])
        #expect(selection.effectiveHiddenToolNames == ["bash"])
        selection.hiddenKinds = TranscriptKindGroup.toolCalls.kinds
        #expect(selection.effectiveHiddenToolNames.isEmpty)
    }

    // MARK: - Problem policy

    @Test func problemPolicyMapsToFloorAndErrorHiding() {
        #expect(TranscriptProblemPolicy.alwaysShowWarningsAndErrors.floor == .warning)
        #expect(TranscriptProblemPolicy.alwaysShowErrors.floor == .error)
        #expect(TranscriptProblemPolicy.filterNormally.floor == nil)
        #expect(TranscriptProblemPolicy.hideErrors.floor == nil)
        #expect(TranscriptProblemPolicy.allCases.filter(\.hidesErrors) == [.hideErrors])
        var config = TranscriptViewConfig.everything
        config.problems = .hideErrors
        #expect(!config.makeFilter().matches(Self.message(severity: .error)))
        #expect(config.makeFilter().matches(Self.message(severity: .warning)))
    }

    // MARK: - Panes and presets

    @Test func panesHaveTheirOwnDefaultsAndPresets() {
        #expect(TranscriptPane.session.defaultConfig == .conversation)
        #expect(TranscriptPane.task.defaultConfig == .everything)
        #expect(TranscriptPane.session.preset(matching: .conversation)?.id == "conversation")
        #expect(TranscriptPane.task.preset(matching: .condensed)?.id == "condensed")
        #expect(TranscriptPane.session.offersTaskScopeControl)
        #expect(!TranscriptPane.task.offersTaskScopeControl)
        // Every preset is reachable from its own pane, and distinct.
        for pane in [TranscriptPane.session, .task] {
            for (index, preset) in pane.presets.enumerated() {
                #expect(!pane.presets[(index + 1)...].contains { $0.config == preset.config },
                        "\(preset.id) duplicates another preset in its pane" as Comment)
            }
            #expect(pane.presets.contains { $0.config == pane.defaultConfig })
        }
    }

    @Test func anEditedConfigIsCustomAndMatchesNoPreset() {
        var config = TranscriptViewConfig.conversation
        config.setParticipant(.agent(.summarizer), shown: false)
        #expect(TranscriptPane.session.preset(matching: config) == nil)
        #expect(TranscriptPane.session.isCustomized(config))
        #expect(!TranscriptPane.session.isCustomized(.conversation))
    }

    /// The task pane is always scoped to its task, so the scope switch is not something it honors —
    /// a stray value must not turn a preset into "Custom" there.
    @Test func taskPaneIgnoresTheScopeSwitchWhenMatching() {
        var config = TranscriptViewConfig.everything
        config.hideTaskScoped = true
        #expect(TranscriptPane.task.preset(matching: config)?.id == "everything")
        #expect(!TranscriptPane.task.isCustomized(config))
        #expect(TranscriptPane.session.preset(matching: config) == nil)
    }

    // MARK: - Persistence (current generation)

    @Test func configRoundTripsThroughJSON() throws {
        var config = TranscriptViewConfig(hiddenParticipants: [.agent(.brown), .validator],
                                          hideTaskScoped: true, problems: .alwaysShowErrors)
        config.setVisible(false, targets: [.chat, .kind(.memorySaved), .tool("bash")], for: [.system])
        config.setVisible(false, targets: [.kind(.statusUpdate)], for: [.agent(.smith), .user])
        let back = try JSONDecoder().decode(TranscriptViewConfig.self, from: JSONEncoder().encode(config))
        #expect(back == config)
        for config in [TranscriptViewConfig.everything, .conversation, .condensed] {
            #expect(try JSONDecoder().decode(TranscriptViewConfig.self, from: JSONEncoder().encode(config)) == config)
        }
    }

    /// Wire shape: only current-generation keys, the hidden sets sorted, rows sorted, so the JSON
    /// is diff-stable across saves.
    @Test func persistedFormIsCurrentGenerationAndDiffStable() throws {
        var config = TranscriptViewConfig.everything
        config.setVisible(false, targets: [.kind(.securityReview), .kind(.memorySaved)], for: [.system, .agent(.brown)])
        let data = try JSONEncoder().encode(config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["hiddenParticipants", "participantSelections", "hideTaskScoped", "problems"])
        let rows = try #require(json["participantSelections"] as? [[String: Any]])
        #expect(rows.count == 2)
        // The verdict kind is stored as its classes, never as a hidden kind.
        #expect(rows.allSatisfy { ($0["hiddenKinds"] as? [String]) == ["memory_saved"] })
        #expect(rows.allSatisfy { ($0["hiddenVerdictClasses"] as? [String]) == ["accept", "block", "warn"] })
        let stable = JSONEncoder()
        stable.outputFormatting = .sortedKeys
        let back = try JSONDecoder().decode(TranscriptViewConfig.self, from: data)
        #expect(try stable.encode(back) == (try stable.encode(config)))
    }

    /// Values written by a NEWER build degrade, never fail the decode — a throw here destroys the
    /// whole `SessionState`, and the next save overwrites it with defaults.
    @Test func unknownForwardValuesFailOpen() throws {
        let config = try Self.decode("""
        {"hiddenParticipants":[{"agent":{"_0":"brown"}},{"someFutureSender":{}}],
         "participantSelections":[
            {"participant":{"someFutureSender":{}},"hiddenKinds":["tool_output"],"showsChat":true},
            {"participant":{"system":{}},"hiddenKinds":["memory_saved","some_future_kind"],"showsChat":false}
         ],
         "hideTaskScoped":false,"problems":"someFuturePolicy"}
        """)
        #expect(config.hiddenParticipants == [.agent(.brown)])
        #expect(config.selections.count == 1)
        #expect(config.selection(for: .system) == TranscriptKindSelection(hiddenKinds: [.memorySaved], showsChat: false))
        #expect(config.problems == .alwaysShowWarningsAndErrors)

        let allUnknown = try Self.decode("""
        {"hiddenParticipants":[{"someFutureSender":{}}],"participantSelections":[],"hideTaskScoped":false,"problems":"filterNormally"}
        """)
        #expect(allUnknown.hiddenParticipants.isEmpty)
        #expect(allUnknown.problems == .filterNormally)
    }

    // MARK: - Migration of earlier generations

    /// The session pane's config exactly as persisted by the previous generation on this machine
    /// (2026-10-01) — migrates to the Conversation preset, so the user sees no change.
    @Test func persistedLegacySessionConfigMigratesToConversation() throws {
        let config = try Self.decode("""
        {"visibility": "all", "showErrors": true,
         "allowedSenders": [{"agent": {"_0": "securityAgent"}}, {"user": {}}, {"validator": {}},
                            {"agent": {"_0": "summarizer"}}, {"system": {}}, {"agent": {"_0": "smith"}}],
         "hideTaskScoped": true, "showsChat": true,
         "hiddenKinds": ["security_review", "tool_output", "tool_request"],
         "allowedRecipients": [{"type": "user"}, {"type": "agent", "role": "securityAgent"},
                               {"type": "agent", "role": "smith"}, {"type": "agent", "role": "summarizer"}],
         "alwaysShowAtOrAbove": "warning"}
        """)
        #expect(config == .conversation)
        #expect(TranscriptPane.session.preset(matching: config)?.id == "conversation")
    }

    /// The task pane's config exactly as persisted (2026-10-01): security reviews hidden for
    /// everyone, and a Brown override that ALSO hides tool output. Each participant must end up
    /// with precisely what the old default/override gave it.
    @Test func persistedLegacyTaskConfigMigratesPerParticipant() throws {
        let config = try Self.decode("""
        {"visibility": "all", "showErrors": true,
         "senderKindOverrides": [{"sender": {"agent": {"_0": "brown"}},
                                  "hiddenKinds": ["security_review", "tool_output"], "showsChat": true}],
         "hideTaskScoped": false, "showsChat": true, "hiddenKinds": ["security_review"],
         "alwaysShowAtOrAbove": "warning"}
        """)
        // "security_review" hidden is the old spelling of every Security Agent verdict hidden: all
        // three classes, plus tool scope (a verdict that did not exist when the choice was made).
        let allClasses = Set(SecurityVerdictClass.allCases)
        #expect(config.selection(for: .agent(.brown)).hiddenKinds == [.toolScopeReview, .toolOutput])
        for participant in Self.everyone {
            #expect(config.selection(for: participant).hiddenVerdictClasses == allClasses)
            if participant != .agent(.brown) {
                #expect(config.selection(for: participant).hiddenKinds == [.toolScopeReview])
            }
        }
        #expect(config.hiddenParticipants.isEmpty)
        #expect(config.problems == .alwaysShowWarningsAndErrors)
        #expect(!config.isUniformAcrossParticipants)
        #expect(TranscriptPane.task.preset(matching: config) == nil)
        // Behaviour, not just shape: Brown's requests still show, its output doesn't.
        let filter = config.makeFilter(taskScope: .any)
        #expect(filter.matches(Self.message(.toolRequest, from: .agent(.brown))))
        #expect(!filter.matches(Self.message(.toolOutput, from: .agent(.brown))))
        #expect(filter.matches(Self.message(.toolOutput, from: .validator)))
    }

    /// The VISIBLE-group generation predates `securityReviews`; those rows were kindless, so they
    /// inherit Chat's state.
    @Test func visibleGroupsGenerationMigrates() throws {
        let chatOn = try Self.decode(#"{"visibleGroups":["chat","system"],"visibility":"all"}"#)
        #expect(chatOn.hideTaskScoped == false)
        #expect(chatOn.problems == .alwaysShowWarningsAndErrors)
        #expect(chatOn.visibility(of: TranscriptKindGroup.securityReviews.targets, for: Self.everyone) == .all)
        #expect(chatOn.visibility(of: TranscriptKindGroup.system.targets, for: Self.everyone) == .all)
        #expect(chatOn.visibility(of: TranscriptKindGroup.toolCalls.targets, for: Self.everyone) == .none)

        let chatOff = try Self.decode(#"{"visibleGroups":["toolCalls","system","someFutureGroup"],"visibility":"all"}"#)
        #expect(chatOff.visibility(of: [.chat], for: Self.everyone) == .none)
        #expect(chatOff.visibility(of: TranscriptKindGroup.securityReviews.targets, for: Self.everyone) == .none)
        #expect(chatOff.visibility(of: TranscriptKindGroup.toolCalls.targets, for: Self.everyone) == .all)
    }

    @Test func hiddenGroupsGenerationMigrates() throws {
        let config = try Self.decode(#"{"hiddenGroups":["memory","chat"],"visibility":"all","showErrors":true}"#)
        #expect(config.selection(for: .user).hiddenKinds == TranscriptKindGroup.memory.kinds)
        #expect(!config.selection(for: .user).showsChat)
    }

    /// The old sender allow-list becomes hidden participants; members a newer build wrote are
    /// dropped, and a list with no surviving member fails open (nobody hidden).
    @Test func legacySenderAllowListBecomesHiddenParticipants() throws {
        let partial = try Self.decode(#"{"hiddenKinds":[],"allowedSenders":[{"user":{}},{"someFutureSender":{}}]}"#)
        #expect(partial.hiddenParticipants == Set(Self.everyone).subtracting([.user]))

        let unknownOnly = try Self.decode(#"{"hiddenKinds":[],"allowedSenders":[{"someFutureSender":{}}]}"#)
        #expect(unknownOnly.hiddenParticipants.isEmpty)

        let unknownKind = try Self.decode(#"{"hiddenKinds":["memory_saved","some_future_kind"],"showsChat":true}"#)
        #expect(unknownKind.selection(for: .agent(.smith)).hiddenKinds == [.memorySaved])
    }

    /// An ABSENT floor (written before the floor existed) adopts the default; an explicit NULL was
    /// the user turning it off; `showErrors: false` was an explicit request to hide errors.
    @Test func legacyErrorSettingsMigrateToOneProblemPolicy() throws {
        #expect(try Self.decode(#"{"hiddenKinds":[]}"#).problems == .alwaysShowWarningsAndErrors)
        #expect(try Self.decode(#"{"hiddenKinds":[],"alwaysShowAtOrAbove":null}"#).problems == .filterNormally)
        #expect(try Self.decode(#"{"hiddenKinds":[],"alwaysShowAtOrAbove":"error"}"#).problems == .alwaysShowErrors)
        #expect(try Self.decode(#"{"hiddenKinds":[],"showErrors":false,"alwaysShowAtOrAbove":"warning"}"#).problems == .hideErrors)
    }

    // MARK: - Statistics

    @Test func statsCountWhatThePaneWouldShow() {
        let task = UUID()
        let messages = [
            Self.message(from: .user, to: .agent(.smith)),
            Self.message(.toolRequest, from: .agent(.smith), tool: "list_tasks"),
            Self.message(.toolOutput, from: .agent(.smith), tool: "list_tasks"),
            Self.message(.toolRequest, from: .agent(.smith), tool: "mcp__server__thing"),
            ChannelMessage(sender: .agent(.brown), content: "working", taskID: task)
        ]
        let config = TranscriptViewConfig.conversation
        let stats = TranscriptFilterStats.compute(messages: messages, config: config,
                                                  universe: .any, scope: .orchestration)
        #expect(stats.total == 5)
        #expect(stats.inScope == 4)
        #expect(stats.scopeExcluded == 1)
        #expect(stats.shown == 1)   // only the user's message: tool calls are hidden
        #expect(stats.count(of: TranscriptKindGroup.toolCalls.targets, for: Self.everyone) == 3)
        #expect(stats.count(of: [.tool("list_tasks")], for: [.agent(.smith)]) == 2)
        #expect(stats.involving[.agent(.smith)] == 4)   // three sent, one addressed to them
        #expect(stats.involving[.agent(.brown)] == nil) // out of scope
        #expect(stats.observedToolNames == ["list_tasks", "mcp__server__thing"])
    }
}
