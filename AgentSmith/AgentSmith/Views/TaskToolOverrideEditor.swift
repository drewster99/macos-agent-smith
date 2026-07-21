import SwiftUI
import AgentSmithKit

/// Per-task tool override editor shown in a task's detail window. Lets the user force individual
/// tools on/off for this task, overriding the security agent's automatic scoping verdict. "Auto"
/// clears the override (defer to scoping + global policy). Overrides persist and survive any
/// re-evaluation. Forced lifecycle tools are always available and not listed.
///
/// MCP tools are grouped under their server, and each server gets an Auto/On/Off shortcut that sets
/// *every* tool the server advertises at once (a fast way to grant or deny a whole server, including
/// tools the security agent didn't scope into this task).
struct TaskToolOverrideEditor: View {
    let task: AgentTask
    @Bindable var viewModel: AppViewModel
    @State private var expanded = false

    private static let forcedLifecycle: Set<String> = [
        "task_acknowledged", "task_update", "task_complete", "request_help", "reply_to_user"
    ]

    private enum OverrideState { case auto, on, off }

    /// A section of the tool list: built-in tools (no header), one connected MCP server (header +
    /// aggregate control), or leftover MCP tools from a disconnected server (header, no aggregate).
    private struct ToolGroup: Identifiable {
        let id: String
        /// Section header text; `nil` renders no header (the built-in section).
        let title: String?
        /// Set only for a connected MCP server — enables the per-server Auto/On/Off shortcut.
        let serverID: UUID?
        /// Prefixed tool names in this section, sorted.
        let tools: [String]
    }

    private var approved: Set<String> { Set(task.approvedTools ?? []) }

    /// Builds the grouped tool list: built-in worker tools, then one section per connected MCP
    /// server (listing every tool it advertises), then a catch-all for any approved/overridden tool
    /// not covered (e.g. an MCP tool whose server is currently disconnected). Lifecycle tools excluded.
    private var groups: [ToolGroup] {
        let lifecycle = Self.forcedLifecycle
        let builtIns = BrownBehavior.toolNames.filter { !lifecycle.contains($0) }.sorted()

        var result: [ToolGroup] = [
            ToolGroup(id: "__builtin", title: nil, serverID: nil, tools: builtIns)
        ]
        var accounted = Set(BrownBehavior.toolNames)

        for server in viewModel.shared.mcpServers {
            // Match the worker-facing names the engine resolves against: skip per-server
            // disabled tools (never bridged) and prefix the rest. NOTE: this recompute does not
            // reproduce the cross-server collision disambiguation the bridge applies
            // (`MCPClientHost.currentBridgedTools` suffixes a colliding name); for the rare
            // colliding tool the override is simply inert (it matches no live candidate) — never
            // the wrong tool. Common case (no collision) maps exactly.
            let advertised = (viewModel.shared.mcpServerStatuses[server.id]?.advertisedToolNames ?? [])
                .filter { !server.disabledTools.contains($0) }
            let prefixed = advertised
                .map { MCPToolNaming.prefixedName(server: server.name, tool: $0) }
                .filter { !lifecycle.contains($0) }
            guard !prefixed.isEmpty else { continue }
            accounted.formUnion(prefixed)
            result.append(ToolGroup(
                id: "mcp:\(server.id.uuidString)",
                title: server.name,
                serverID: server.id,
                tools: prefixed.sorted()
            ))
        }

        var leftover = approved
        if let overrides = task.userToolOverrides { leftover.formUnion(overrides.keys) }
        leftover.subtract(accounted)
        leftover.subtract(lifecycle)
        if !leftover.isEmpty {
            result.append(ToolGroup(id: "__other", title: "Other (disconnected MCP)", serverID: nil, tools: leftover.sorted()))
        }
        return result
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(groups) { group in
                    if let title = group.title {
                        Divider().padding(.vertical, 2)
                        groupHeader(title: title, group: group)
                        ForEach(group.tools, id: \.self) { tool in
                            row(tool).padding(.leading, 12)
                        }
                    } else {
                        ForEach(group.tools, id: \.self) { row($0) }
                    }
                }
                Text("“Auto” follows the security agent. “On”/“Off” are your overrides — they persist and won't be undone by re-evaluation. A server's control sets every tool it advertises at once.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.top, 4)
        } label: {
            // Count only tools that actually appear as rows. Forced lifecycle tools are approved
            // by scoping but deliberately not listed, so counting raw `approvedTools` made the
            // header disagree with the visible list.
            let n = groups.flatMap(\.tools).filter { effectiveEnabled($0) }.count
            let o = task.userToolOverrides?.count ?? 0
            let approvalText = task.approvedTools == nil ? "Not scoped yet" : "\(n) approved"
            Text(o > 0 ? "\(approvalText) · \(o) override\(o == 1 ? "" : "s")" : approvalText)
                .foregroundStyle(.secondary)
        }
    }

    private func groupHeader(title: String, group: ToolGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text("(\(group.tools.count))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            if group.serverID != nil {
                Picker("", selection: serverStateBinding(group.tools)) {
                    Text("Auto").tag(Optional(OverrideState.auto))
                    Text("On").tag(Optional(OverrideState.on))
                    Text("Off").tag(Optional(OverrideState.off))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("Set all of \(title)'s tools to this state at once")
            }
        }
    }

    private func row(_ tool: String) -> some View {
        let override = task.userToolOverrides?[tool]
        let effective = effectiveEnabled(tool)
        return HStack(spacing: 8) {
            Image(systemName: effective ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(effective ? Color.green : Color.secondary)
            Text(tool)
                .font(.body.monospaced())
                .fontWeight(override != nil ? .bold : .regular)
            Spacer(minLength: 12)
            Picker("", selection: stateBinding(tool)) {
                Text("Auto").tag(OverrideState.auto)
                Text("On").tag(OverrideState.on)
                Text("Off").tag(OverrideState.off)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
    }

    private func effectiveEnabled(_ tool: String) -> Bool {
        if let override = task.userToolOverrides?[tool] { return override }
        switch viewModel.shared.globalToolPolicies[tool] ?? ToolPolicy.builtInDefaults[tool] ?? .default {
        case .always:
            return true
        case .never:
            return false
        case .default:
            return approved.contains(tool)
        }
    }

    private func stateBinding(_ tool: String) -> Binding<OverrideState> {
        Binding(
            get: {
                guard let o = task.userToolOverrides?[tool] else { return .auto }
                return o ? .on : .off
            },
            set: { newState in
                viewModel.setTaskToolOverride(taskID: task.id, tool: tool, enabled: Self.enabled(for: newState))
            }
        )
    }

    /// Aggregate binding for a server's tools. The getter returns the common state, or `nil` when
    /// the tools disagree (segmented control shows no selection). Selecting a value applies it to
    /// every tool in the group in one write.
    private func serverStateBinding(_ tools: [String]) -> Binding<OverrideState?> {
        Binding(
            get: {
                let states = tools.map { tool -> OverrideState in
                    guard let o = task.userToolOverrides?[tool] else { return .auto }
                    return o ? .on : .off
                }
                guard let first = states.first, states.allSatisfy({ $0 == first }) else { return nil }
                return first
            },
            set: { newState in
                guard let newState else { return }
                viewModel.setTaskToolOverrides(taskID: task.id, tools: tools, enabled: Self.enabled(for: newState))
            }
        )
    }

    private static func enabled(for state: OverrideState) -> Bool? {
        switch state {
        case .auto: return nil
        case .on: return true
        case .off: return false
        }
    }
}
