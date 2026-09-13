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

    @Test("Group toggles cover exactly their own tools")
    func toolGroupToggles() {
        var selection = TranscriptKindSelection()
        #expect(selection.toolGroupVisibility(of: .shell) == .all)

        selection.setToolGroup(.shell, visible: false)
        #expect(selection.toolGroupVisibility(of: .shell) == .none)
        #expect(selection.toolGroupVisibility(of: .filesystem) == .all, "a group must not touch another's tools")
        #expect(!selection.isToolVisible("bash"))
        #expect(selection.isToolVisible("file_read"))

        selection.setTool("bash", visible: true)
        #expect(selection.toolGroupVisibility(of: .shell) == .mixed)
    }

    /// With the whole group off there are no tool rows left to narrow, so reporting a per-tool set
    /// would be noise — and would make the filter claim to hide things it is not deciding.
    @Test("The per-tool set is irrelevant while the Tool calls group is off")
    func perToolSetIsEmptyWhenTheGroupIsOff() {
        var selection = TranscriptKindSelection()
        selection.setTool("bash", visible: false)
        #expect(selection.effectiveHiddenToolNames == ["bash"])

        selection.setGroup(.toolCalls, visible: false)
        #expect(selection.effectiveHiddenToolNames.isEmpty)
    }

    // MARK: - Compatibility




    /// Round-trips the WHOLE config, not just the selection.
    ///
    /// `TranscriptViewConfig` hand-writes its Codable and FLATTENS each `TranscriptKindSelection`
    /// into its own keys, so a selection is never persisted via its own encoder. A round-trip test
    /// on the selection alone therefore passes while the feature is dropped on every save — which
    /// is exactly what happened: this test is the one that could fail, and did.
    @Test("Hidden tools survive a round trip through the persisted config")
    func configRoundTripKeepsHiddenTools() throws {
        var config = TranscriptViewConfig()
        config.defaultKinds.setTool("bash", visible: false)
        var brown = config.defaultKinds
        brown.setTool("file_read", visible: false)
        config.setKindSelection(brown, forSender: .agent(.brown))

        let decoded = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: JSONEncoder().encode(config)
        )
        #expect(decoded.defaultKinds.hiddenToolNames == ["bash"],
                "the default scope's hidden tools were dropped by the persisted encoding")
        #expect(decoded.senderKindOverrides[.agent(.brown)]?.hiddenToolNames == ["bash", "file_read"],
                "a per-sender override's hidden tools were dropped by the persisted encoding")
        #expect(decoded == config)
    }

    /// A config written before per-tool filtering has no tool keys anywhere — neither on the
    /// default scope nor on an override row — and must decode with every tool visible.
    @Test("A persisted config from before this feature decodes with every tool visible")
    func legacyConfigRoundTrip() throws {
        let legacy = """
            {"hiddenKinds":["tool_output"],"showsChat":true,"visibility":"all",
             "hideTaskScoped":false,"showErrors":true,
             "senderKindOverrides":[{"sender":{"agent":{"_0":"brown"}},
                                     "hiddenKinds":["tool_request"],"showsChat":false}]}
            """
        let config = try JSONDecoder().decode(TranscriptViewConfig.self, from: Data(legacy.utf8))
        #expect(config.defaultKinds.hiddenToolNames.isEmpty)
        #expect(config.defaultKinds.hiddenKinds == [.toolOutput])
        #expect(config.senderKindOverrides[.agent(.brown)]?.hiddenToolNames.isEmpty == true)
        #expect(config.senderKindOverrides[.agent(.brown)]?.hiddenKinds == [.toolRequest])
    }

    /// Every stored property of `TranscriptKindSelection` must survive the PERSISTED encoding.
    ///
    /// Reflection, and through `TranscriptViewConfig` rather than the selection's own Codable,
    /// because the selection is never encoded by its own encoder — the config flattens it into its
    /// own keys and into `SenderKindOverrideRow`. A property added to the selection and forgotten
    /// there is silently dropped on every save, and a round trip of the SELECTION stays green while
    /// it happens. That is not hypothetical: it is exactly how `hiddenToolNames` shipped broken.
    @Test("Every selection property survives the persisted config encoding")
    func configRoundTripKeepsEverySelectionProperty() throws {
        // Every field non-default, on BOTH scopes — a default value is indistinguishable from a
        // dropped one, and the default scope and an override row are encoded by different code.
        var selection = TranscriptKindSelection()
        selection.setKind(.toolOutput, visible: false)
        selection.showsChat = false
        selection.setTool("bash", visible: false)

        var config = TranscriptViewConfig()
        config.defaultKinds = selection
        config.setKindSelection(selection, forSender: .agent(.brown))

        let decoded = try JSONDecoder().decode(
            TranscriptViewConfig.self, from: JSONEncoder().encode(config)
        )
        let properties = Set(Mirror(reflecting: selection).children.compactMap(\.label))
        #expect(!properties.isEmpty)
        #expect(decoded.defaultKinds == selection, """
            a stored property of TranscriptKindSelection (\(properties.sorted().joined(separator: ", "))) \
            did not survive TranscriptViewConfig's encoder. Add it to CodingKeys, encode(to:) and \
            init(from:) there.
            """)
        #expect(decoded.senderKindOverrides[.agent(.brown)] == selection, """
            a stored property did not survive SenderKindOverrideRow. Add it to that struct, to the \
            row it encodes, and to the row it decodes.
            """)
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
