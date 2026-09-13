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

    /// A config written before per-tool filtering existed has no such key. Decoding must treat that
    /// as "nothing hidden" rather than throwing, which would lose the user's whole filter config.
    @Test("A config saved before this feature decodes with every tool visible")
    func legacyConfigDecodes() throws {
        let legacy = #"{"hiddenKinds":["tool_output"],"showsChat":true}"#
        let selection = try JSONDecoder().decode(TranscriptKindSelection.self, from: Data(legacy.utf8))
        #expect(selection.hiddenToolNames.isEmpty)
        #expect(selection.hiddenKinds == [.toolOutput])
        #expect(selection.showsChat)
    }

    @Test("Hidden tools survive a round trip")
    func roundTrip() throws {
        var selection = TranscriptKindSelection()
        selection.setToolGroup(.web, visible: false)
        selection.setTool("bash", visible: false)
        let decoded = try JSONDecoder().decode(
            TranscriptKindSelection.self, from: JSONEncoder().encode(selection)
        )
        #expect(decoded == selection)
        #expect(decoded.hiddenToolNames.contains("bash"))
    }

    /// Every stored property of `TranscriptKindSelection` must be written AND read back.
    ///
    /// It has a hand-written `init(from:)` for the lenient decode above, which costs the type its
    /// synthesized decoder — so a property added later is silently never restored, and a round-trip
    /// test comparing two defaulted values stays green. Reflection is what catches that.
    @Test("Every TranscriptKindSelection property is encoded and decoded")
    func codingCoverage() throws {
        // Every field non-default, or an absent key is indistinguishable from an unread one.
        var selection = TranscriptKindSelection()
        selection.setKind(.toolOutput, visible: false)
        selection.showsChat = false
        selection.setTool("bash", visible: false)

        let encoded = try JSONEncoder().encode(selection)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let expected = Set(Mirror(reflecting: selection).children.compactMap(\.label))
        let missing = expected.subtracting(object.keys).sorted()
        #expect(missing.isEmpty, """
            \(missing.joined(separator: ", ")) is a stored property with no encoded key, so it is \
            never persisted. Add it to CodingKeys AND to init(from:).
            """)
        #expect(try JSONDecoder().decode(TranscriptKindSelection.self, from: encoded) == selection,
                "a property is encoded but not read back by the hand-written init(from:)")
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
