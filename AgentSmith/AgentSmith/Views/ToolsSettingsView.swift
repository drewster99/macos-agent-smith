import SwiftUI
import AgentSmithKit

/// Settings tab listing every tool the worker (Brown) can be granted — built-in plus MCP — with a
/// global Default / Always / Never policy each. `Always` forces a tool available regardless of the
/// security agent's per-task scoping; `Never` removes it; `Default` defers to scoping. A per-task
/// override (in a task's detail window) takes precedence over these. Forced lifecycle tools
/// (`task_update`, …) are always available and intentionally not listed.
///
/// Each MCP server's header carries a Default/Always/Never shortcut that sets all of its tools at
/// once. Policies are keyed by the worker-facing **prefixed** tool name (`mcp__server__tool`) so
/// they match what the engine resolves against.
struct ToolsSettingsView: View {
    @Bindable var shared: SharedAppState

    /// Lifecycle tools that are always available and not user-controllable.
    private static let forcedLifecycle: Set<String> = [
        "task_acknowledged", "task_update", "task_complete", "request_help", "reply_to_user"
    ]

    private var builtInTools: [String] {
        BrownBehavior.toolNames.filter { !Self.forcedLifecycle.contains($0) }.sorted()
    }

    /// One MCP server's tools: `display` is the server-advertised (unprefixed) name shown to the
    /// user; `key` is the prefixed name used as the policy key and matched by the engine.
    private struct MCPGroup: Identifiable {
        let id: UUID
        let serverName: String
        let tools: [(display: String, key: String)]
    }

    /// MCP tools advertised by each configured server, grouped by server (empty servers skipped).
    /// Per-server disabled tools are skipped (they're never bridged, so a policy on them is inert).
    /// The `key` mirrors the worker-facing prefixed name the engine resolves against. NOTE: this does
    /// not reproduce the bridge's cross-server collision disambiguation; for a rare colliding tool the
    /// policy is inert rather than wrong. The common (no-collision) case maps exactly.
    private var mcpGroups: [MCPGroup] {
        shared.mcpServers.compactMap { server in
            let advertised = (shared.mcpServerStatuses[server.id]?.advertisedToolNames ?? [])
                .filter { !server.disabledTools.contains($0) }
                .sorted()
            guard !advertised.isEmpty else { return nil }
            let tools = advertised.map { (display: $0, key: MCPToolNaming.prefixedName(server: server.name, tool: $0)) }
            return MCPGroup(id: server.id, serverName: server.name, tools: tools)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tool Availability")
                .font(AppFonts.sectionHeader)
            Text("Override the security agent's automatic decision for the worker. “Always” forces a tool available, “Never” removes it, “Default” defers to per-task scoping. A per-task override (in a task's detail window) beats these. A server's control sets all of its tools at once. Changes apply immediately. Lifecycle tools are always available and not shown.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("Built-in")
                .font(AppFonts.sectionHeader)
            ForEach(builtInTools, id: \.self) { toolRow(display: $0, key: $0) }

            ForEach(mcpGroups) { group in
                Divider()
                serverHeader(group)
                ForEach(group.tools, id: \.key) { toolRow(display: $0.display, key: $0.key) }
            }

            if mcpGroups.isEmpty {
                Text("No connected MCP servers. Add servers in the MCP Servers tab to manage their tools here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func serverHeader(_ group: MCPGroup) -> some View {
        HStack(spacing: 8) {
            Text("MCP — \(group.serverName)")
                .font(AppFonts.sectionHeader)
            Spacer(minLength: 16)
            Picker("", selection: serverPolicyBinding(group.tools.map(\.key))) {
                Text("Default").tag(Optional(ToolPolicy.default))
                Text("Always").tag(Optional(ToolPolicy.always))
                Text("Never").tag(Optional(ToolPolicy.never))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("Set all of \(group.serverName)'s tools to this policy at once")
        }
    }

    private func toolRow(display: String, key: String) -> some View {
        HStack {
            Text(display)
                .font(.body.monospaced())
            Spacer(minLength: 16)
            Picker("", selection: policyBinding(key)) {
                Text("Default").tag(ToolPolicy.default)
                Text("Always").tag(ToolPolicy.always)
                Text("Never").tag(ToolPolicy.never)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func policyBinding(_ tool: String) -> Binding<ToolPolicy> {
        Binding(
            get: { shared.globalToolPolicies[tool] ?? ToolPolicy.builtInDefaults[tool] ?? .default },
            set: { newValue in
                if newValue == .default {
                    shared.globalToolPolicies.removeValue(forKey: tool)
                } else {
                    shared.globalToolPolicies[tool] = newValue
                }
            }
        )
    }

    /// Aggregate policy binding for a server's tools. The getter returns the common policy, or `nil`
    /// when the tools disagree (segmented control shows no selection). Selecting a value applies it
    /// to every tool key in one assignment (a single persist + observer notification).
    private func serverPolicyBinding(_ keys: [String]) -> Binding<ToolPolicy?> {
        Binding(
            get: {
                let states = keys.map { shared.globalToolPolicies[$0] ?? .default }
                guard let first = states.first, states.allSatisfy({ $0 == first }) else { return nil }
                return first
            },
            set: { newValue in
                guard let newValue else { return }
                var policies = shared.globalToolPolicies
                for key in keys {
                    if newValue == .default {
                        policies.removeValue(forKey: key)
                    } else {
                        policies[key] = newValue
                    }
                }
                shared.globalToolPolicies = policies
            }
        )
    }
}
