import SwiftUI
import AgentSmithKit

/// One line in the filter's activity list or grid: a category, a single message type, a tool
/// family, or a single tool. Every one of them is just a set of `TranscriptFilterTarget`s, which is
/// what lets both layouts share one aggregate (`TranscriptViewConfig.visibility`) and one mutation
/// (`setVisible`) at every level.
struct ActivityRowNode: Identifiable, Equatable {
    enum Style: Equatable {
        case category, kind, toolFamily, tool
    }

    let id: String
    let title: String
    let detail: String?
    let style: Style
    let targets: [TranscriptFilterTarget]
    let children: [ActivityRowNode]
    /// Hover text: the full name where `title` is shortened (an MCP tool shown without its
    /// `mcp__<server>__` prefix), otherwise the title itself, for when it truncates.
    var tooltip: String? = nil

    var isExpandable: Bool { !children.isEmpty }

    /// Tool rows only take effect while tool-call messages are shown at all.
    var dependsOnToolCalls: Bool { style == .toolFamily || style == .tool }
}

/// A node placed in the flattened, expansion-aware sequence both layouts render — flat so the
/// grid's rows are direct `GridRow`s and neither layout needs a recursive view.
struct FlatActivityRow: Identifiable, Equatable {
    let node: ActivityRowNode
    let depth: Int
    let isExpanded: Bool

    var id: String { node.id }
}

/// Builds the activity tree from the authoritative groupings — `TranscriptKindGroup` for message
/// types and `BuiltInToolGroup` for tools — so a newly grouped kind or tool appears here with no
/// second list to update.
enum ActivityRowTree {
    /// The tree before any transcript has been counted: no "Other tools" family yet.
    static let initial = make(observedToolNames: [])

    static func make(observedToolNames: Set<String>) -> [ActivityRowNode] {
        TranscriptKindGroup.allCases.map { group in
            ActivityRowNode(
                id: "group.\(group.rawValue)",
                title: group.displayName,
                detail: group.detail,
                style: .category,
                targets: group.targets,
                children: children(of: group, observedToolNames: observedToolNames))
        }
    }

    static func flatten(_ nodes: [ActivityRowNode], expanded: Set<String>, depth: Int = 0) -> [FlatActivityRow] {
        nodes.flatMap { node -> [FlatActivityRow] in
            let isExpanded = node.isExpandable && expanded.contains(node.id)
            let row = FlatActivityRow(node: node, depth: depth, isExpanded: isExpanded)
            guard isExpanded else { return [row] }
            return [row] + flatten(node.children, expanded: expanded, depth: depth + 1)
        }
    }

    private static func children(of group: TranscriptKindGroup, observedToolNames: Set<String>) -> [ActivityRowNode] {
        // A one-type category has nothing to break down.
        guard group.targets.count > 1 else { return [] }
        let kindRows = group.targets.compactMap(kindRow)
        guard group == .toolCalls else { return kindRows }
        return kindRows + toolFamilyRows(observedToolNames: observedToolNames)
    }

    private static func kindRow(_ target: TranscriptFilterTarget) -> ActivityRowNode? {
        guard case .kind(let kind) = target else { return nil }
        return ActivityRowNode(id: "kind.\(kind.rawValue)", title: kind.transcriptFilterLabel,
                               detail: nil, style: .kind, targets: [target], children: [])
    }

    /// One row per built-in tool family, one per MCP server seen in the transcript, and "Other
    /// tools" for any remaining name. MCP tools exist only in the transcript (their names come
    /// from whichever servers are configured), and grouping them by server lets each row show the
    /// tool's own name — the shared `mcp__<server>__` prefix otherwise ate the visible width.
    private static func toolFamilyRows(observedToolNames: Set<String>) -> [ActivityRowNode] {
        var families = BuiltInToolGroup.allCases.map { group in
            toolFamily(id: group.rawValue, title: group.displayName, detailPrefix: nil,
                       tools: BuiltInToolGroup.orderedToolNames(in: group).map { ($0, $0) })
        }
        var byServer: [String: [(name: String, title: String)]] = [:]
        var other: [String] = []
        for name in observedToolNames.subtracting(BuiltInToolGroup.allToolNames).sorted() {
            if let parts = MCPToolNaming.components(of: name) {
                byServer[parts.server, default: []].append((name, parts.tool))
            } else {
                other.append(name)
            }
        }
        for server in byServer.keys.sorted() {
            families.append(toolFamily(id: "mcp.\(server)", title: server, detailPrefix: "MCP server",
                                       tools: byServer[server] ?? []))
        }
        if !other.isEmpty {
            families.append(toolFamily(id: "other", title: "Other tools", detailPrefix: nil, tools: other.map { ($0, $0) }))
        }
        return families.filter { !$0.children.isEmpty }
    }

    private static func toolFamily(id: String, title: String, detailPrefix: String?,
                                   tools: [(name: String, title: String)]) -> ActivityRowNode {
        let count = tools.count == 1 ? "1 tool" : "\(tools.count) tools"
        return ActivityRowNode(
            id: "family.\(id)",
            title: title,
            detail: detailPrefix.map { "\($0) · \(count)" } ?? count,
            style: .toolFamily,
            targets: tools.map { TranscriptFilterTarget.tool($0.name) },
            children: tools.map { tool in
                ActivityRowNode(id: "tool.\(tool.name)", title: tool.title, detail: nil, style: .tool,
                                targets: [.tool(tool.name)], children: [], tooltip: tool.name)
            })
    }
}

extension ChannelMessageKind {
    /// Reader-facing label for a single-type row, derived from the wire string so a newly added kind
    /// gets a label with no table to update. Only labels that would read badly derived — the two
    /// tool rows (which sit under "Tool calls"), look-alike pairs, the acronym — are spelled out.
    var transcriptFilterLabel: String {
        switch self {
        case .toolRequest: return "Requests"
        case .toolOutput: return "Output"
        case .taskComplete: return "Task complete (worker submission)"
        case .taskCompleted: return "Task completed (final state)"
        case .taskLifecycle: return "Task lifecycle (informational)"
        case .mcpStatus: return "MCP status"
        default:
            let words = rawValue.split(separator: "_").joined(separator: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}

extension ChannelMessage.Sender {
    /// How the filter names a participant — "You" for the user, the role's short name otherwise.
    var filterName: String {
        switch self {
        case .user: return "You"
        case .system: return "System"
        case .validator, .agent(.validator): return "Validator"
        case .agent(.smith): return "Smith"
        case .agent(.brown): return "Brown"
        case .agent(.securityAgent): return "Security"
        case .agent(.summarizer): return "Summarizer"
        }
    }

    /// The grid's column-header form; only names too wide for a column are shortened.
    var filterShortName: String {
        self == .agent(.summarizer) ? "Summ." : filterName
    }
}
