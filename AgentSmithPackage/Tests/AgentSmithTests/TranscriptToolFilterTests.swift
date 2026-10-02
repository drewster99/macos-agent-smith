import Foundation
import Testing
@testable import AgentSmithKit

/// Per-tool transcript filtering.
///
/// The kind axis can only say "tool calls, all or none" — `.toolRequest` and `.toolOutput` are the
/// same two kinds whichever tool produced them. These pin the second axis that says WHICH tool, and
/// the two properties that make it safe to add: hiding is stored inverted (so a tool that does not
/// exist yet is visible in an already-saved config), and a hidden tool takes its OUTPUT row with it
/// (so the transcript never shows a result under a request that is no longer there).
@Suite("Transcript tool filter")
struct TranscriptToolFilterTests {

    private func toolMessage(_ kind: ChannelMessageKind, tool: String,
                             sender: ChannelMessage.Sender = .agent(.brown)) -> ChannelMessage {
        ChannelMessage(
            sender: sender,
            content: "x",
            metadata: ["messageKind": .kind(kind), "tool": .string(tool)]
        )
    }

    @Test("Hiding a tool hides its request AND its output")
    func hidingATooltakesItsOutputWithIt() {
        let filter = TranscriptFilter(hiddenToolNames: ["bash"])
        #expect(!filter.matches(toolMessage(.toolRequest, tool: "bash")))
        #expect(!filter.matches(toolMessage(.toolOutput, tool: "bash")))
        // An orphaned output under a hidden request is the failure this prevents.
        #expect(filter.matches(toolMessage(.toolRequest, tool: "file_read")))
        #expect(filter.matches(toolMessage(.toolOutput, tool: "file_read")))
    }

    @Test("A message with no tool is untouched by the tool axis")
    func nonToolMessagesArePassedThrough() {
        let filter = TranscriptFilter(hiddenToolNames: ["bash"])
        let chat = ChannelMessage(sender: .user, content: "hello")
        #expect(filter.matches(chat))
        let lifecycle = ChannelMessage(
            sender: .agent(.smith), content: "x",
            metadata: ["messageKind": .kind(.taskCreated)]
        )
        #expect(filter.matches(lifecycle))
    }

    @Test("Per-sender sets override the default, exactly as the kind axis does")
    func perSenderOverride() {
        let filter = TranscriptFilter(
            hiddenToolNames: ["bash"],
            hiddenToolNamesBySender: [.agent(.smith): []]
        )
        #expect(!filter.matches(toolMessage(.toolRequest, tool: "bash", sender: .agent(.brown))))
        // Smith's override is empty, so it does NOT inherit the default's hidden set.
        #expect(filter.matches(toolMessage(.toolRequest, tool: "bash", sender: .agent(.smith))))
    }

    @Test("An unknown tool — any MCP tool — is visible unless named")
    func unknownToolsAreVisible() {
        let filter = TranscriptFilter(hiddenToolNames: ["bash"])
        #expect(filter.matches(toolMessage(.toolRequest, tool: "some_mcp_server__do_thing")))
    }

    // MARK: - The selection model

    @Test("A tool family's checkbox covers exactly its own tools")
    func toolFamilyToggles() {
        let shell = BuiltInToolGroup.toolNames(in: .shell).map(TranscriptFilterTarget.tool)
        let filesystem = BuiltInToolGroup.toolNames(in: .filesystem).map(TranscriptFilterTarget.tool)
        let everyone = TranscriptViewConfig.participants
        var config = TranscriptViewConfig()
        #expect(config.visibility(of: shell, for: everyone) == .all)

        config.setVisible(false, targets: shell, for: everyone)
        #expect(config.visibility(of: shell, for: everyone) == .none)
        #expect(config.visibility(of: filesystem, for: everyone) == .all, "a family must not touch another's tools")
        #expect(!config.selection(for: .agent(.brown)).isVisible(.tool("bash")))

        config.setVisible(true, targets: [.tool("bash")], for: [.agent(.brown)])
        #expect(config.visibility(of: [.tool("bash")], for: everyone) == .mixed)
    }

    /// With both tool kinds off there are no tool rows left to narrow, so reporting a per-tool set
    /// would be noise — and would make the filter claim to hide things it is not deciding.
    @Test("The per-tool set is irrelevant while tool calls are hidden")
    func perToolSetIsEmptyWhenToolCallsAreHidden() {
        var selection = TranscriptKindSelection()
        selection.setVisible(false, .tool("bash"))
        #expect(selection.effectiveHiddenToolNames == ["bash"])

        for target in TranscriptKindGroup.toolCalls.targets { selection.setVisible(false, target) }
        #expect(selection.effectiveHiddenToolNames.isEmpty)
    }

    // MARK: - Compatibility

    @Test("Hidden tools survive a round trip through the persisted config")
    func configRoundTripKeepsHiddenTools() throws {
        var config = TranscriptViewConfig()
        config.setVisible(false, targets: [.tool("bash")], for: TranscriptViewConfig.participants)
        config.setVisible(false, targets: [.tool("file_read")], for: [.agent(.brown)])

        let decoded = try JSONDecoder().decode(TranscriptViewConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.selection(for: .agent(.smith)).hiddenToolNames == ["bash"])
        #expect(decoded.selection(for: .agent(.brown)).hiddenToolNames == ["bash", "file_read"])
        #expect(decoded == config)
    }

    /// A config written before per-tool filtering has no tool keys anywhere — neither on the default
    /// nor on an override row — and must migrate with every tool visible and every kind preserved.
    @Test("A persisted config from before per-tool filtering migrates with every tool visible")
    func legacyConfigMigratesWithToolsVisible() throws {
        let legacy = """
            {"hiddenKinds":["tool_output"],"showsChat":true,"visibility":"all",
             "hideTaskScoped":false,"showErrors":true,
             "senderKindOverrides":[{"sender":{"agent":{"_0":"brown"}},
                                     "hiddenKinds":["tool_request"],"showsChat":false}]}
            """
        let config = try JSONDecoder().decode(TranscriptViewConfig.self, from: Data(legacy.utf8))
        #expect(config.selection(for: .agent(.smith)) == TranscriptKindSelection(hiddenKinds: [.toolOutput]))
        #expect(config.selection(for: .agent(.brown)) == TranscriptKindSelection(hiddenKinds: [.toolRequest], showsChat: false))
    }

    /// Every stored property of `TranscriptKindSelection` must survive the PERSISTED encoding.
    ///
    /// Through `TranscriptViewConfig` rather than the selection itself, because the config flattens
    /// each selection into its own row type. A property added to the selection and forgotten there
    /// is silently dropped on every save — exactly how `hiddenToolNames` once shipped broken.
    @Test("Every selection property survives the persisted config encoding")
    func configRoundTripKeepsEverySelectionProperty() throws {
        // Every field non-default — a default value is indistinguishable from a dropped one.
        var selection = TranscriptKindSelection()
        selection.setVisible(false, .kind(.toolOutput))
        selection.setVisible(false, .chat)
        selection.setVisible(false, .tool("bash"))
        selection.setVisible(false, .securityVerdict(.warn))

        // The Security Agent: the one participant for whom every switch (including a verdict class)
        // applies, so nothing is stripped on the way in.
        var config = TranscriptViewConfig()
        config.setSelection(selection, for: .agent(.securityAgent))

        let decoded = try JSONDecoder().decode(TranscriptViewConfig.self, from: JSONEncoder().encode(config))
        let properties = Set(Mirror(reflecting: selection).children.compactMap(\.label))
        #expect(properties == ["hiddenKinds", "showsChat", "hiddenToolNames", "hiddenVerdictClasses"], """
            TranscriptKindSelection's stored properties changed (\(properties.sorted().joined(separator: ", "))). \
            Add the new one to ParticipantSelectionRow (encode and decode) in TranscriptViewConfig, then here.
            """)
        #expect(decoded.selection(for: .agent(.securityAgent)) == selection)
    }

    // MARK: - The roster the UI is built from

    /// A tool with no `BuiltInToolGroup` entry cannot be filtered — the checklist is built from that
    /// table, so an ungrouped tool is simply absent from the UI with nothing to report it.
    @Test("Every built-in tool is in a group, so every built-in tool is filterable")
    func everyBuiltInToolIsFilterable() {
        let grouped = BuiltInToolGroup.allToolNames
        #expect(!grouped.isEmpty)
        // Each group's tools are reachable from the ordered accessor the UI uses.
        var fromGroups = Set<String>()
        for group in BuiltInToolGroup.allCases {
            fromGroups.formUnion(BuiltInToolGroup.orderedToolNames(in: group))
        }
        #expect(fromGroups == grouped, "orderedToolNames must reach every tool in the table")
        // And every one resolves back to exactly the group it came from.
        for group in BuiltInToolGroup.allCases {
            for name in BuiltInToolGroup.orderedToolNames(in: group) {
                #expect(BuiltInToolGroup.group(forToolName: name) == group, "\(name)")
            }
        }
    }

    @Test("Tool lists are ordered, so the checklist does not reshuffle between launches")
    func orderingIsStable() {
        for group in BuiltInToolGroup.allCases {
            let names = BuiltInToolGroup.orderedToolNames(in: group)
            #expect(names == names.sorted(), "\(group) is unsorted")
        }
    }
}
