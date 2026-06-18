import SwiftUI
import AgentSmithKit

/// Settings tab listing every tool the worker (Brown) can be granted — built-in plus MCP — with a
/// global Default / Always / Never policy each. `Always` forces a tool available regardless of the
/// security agent's per-task scoping; `Never` removes it; `Default` defers to scoping. A per-task
/// override (in a task's detail window) takes precedence over these. Forced lifecycle tools
/// (`task_update`, …) are always available and intentionally not listed.
struct ToolsSettingsView: View {
    @Bindable var shared: SharedAppState

    /// Lifecycle tools that are always available and not user-controllable.
    private static let forcedLifecycle: Set<String> = [
        "task_acknowledged", "task_update", "task_complete", "request_help", "reply_to_user"
    ]

    private var builtInTools: [String] {
        BrownBehavior.toolNames.filter { !Self.forcedLifecycle.contains($0) }.sorted()
    }

    /// MCP tools advertised by each configured server, grouped by server name (empty servers skipped).
    private var mcpToolsByServer: [(server: String, tools: [String])] {
        shared.mcpServers.compactMap { server in
            let names = (shared.mcpServerStatuses[server.id]?.advertisedToolNames ?? []).sorted()
            return names.isEmpty ? nil : (server.name, names)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tool Availability")
                .font(AppFonts.sectionHeader)
            Text("Override the security agent's automatic decision for the worker. “Always” forces a tool available, “Never” removes it, “Default” defers to per-task scoping. A per-task override (in a task's detail window) beats these. Changes apply immediately. Lifecycle tools are always available and not shown.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("Built-in")
                .font(AppFonts.sectionHeader)
            ForEach(builtInTools, id: \.self) { toolRow($0) }

            ForEach(mcpToolsByServer, id: \.server) { group in
                Divider()
                Text("MCP — \(group.server)")
                    .font(AppFonts.sectionHeader)
                ForEach(group.tools, id: \.self) { toolRow($0) }
            }

            if mcpToolsByServer.isEmpty {
                Text("No connected MCP servers. Add servers in the MCP Servers tab to manage their tools here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func toolRow(_ tool: String) -> some View {
        HStack {
            Text(tool)
                .font(.body.monospaced())
            Spacer(minLength: 16)
            Picker("", selection: policyBinding(tool)) {
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
            get: { shared.globalToolPolicies[tool] ?? .default },
            set: { newValue in
                if newValue == .default {
                    shared.globalToolPolicies.removeValue(forKey: tool)
                } else {
                    shared.globalToolPolicies[tool] = newValue
                }
            }
        )
    }
}
