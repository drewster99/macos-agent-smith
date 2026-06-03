import SwiftUI
import AgentSmithKit

/// Settings tab for configuring local (stdio) MCP servers. Mirrors the structure of
/// `ProviderManagementView`: a list of servers with enable toggles, connection status,
/// and add/edit/delete plus a "Paste JSON" import path. Secret env/arg values are
/// written to the Keychain via `SharedAppState.mcpSecretStore`; only non-secret
/// metadata is persisted to `mcp_servers.json`.
struct MCPServerManagementView: View {
    @Bindable var shared: SharedAppState

    @State private var editorTarget: EditorTarget?
    @State private var isPasting = false
    @State private var importError: String?

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let existing: MCPServerConfig?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MCP Servers")
                    .font(AppFonts.sectionHeader)
                Spacer()
                Button(action: { isPasting = true }, label: {
                    Label("Paste JSON\u{2026}", systemImage: "doc.on.clipboard")
                })
                Button(action: { editorTarget = EditorTarget(existing: nil) }, label: {
                    Label("Add Server", systemImage: "plus")
                })
            }

            Text("Brown can call tools exposed by these local MCP servers. Every call is gated by Jones, the security reviewer. Servers run per session and start when a session starts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if shared.mcpServers.isEmpty {
                Text("No MCP servers configured. Add one, or paste a standard mcpServers JSON block.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(shared.mcpServers) { server in
                    MCPServerRow(
                        server: server,
                        status: shared.mcpServerStatuses[server.id],
                        onToggleEnabled: { setEnabled($0, for: server) },
                        onToggleTool: { toolName, enabled in setTool(toolName, enabled: enabled, for: server) },
                        onEdit: { editorTarget = EditorTarget(existing: server) },
                        onDelete: { deleteServer(server) }
                    )
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            MCPServerEditorSheet(shared: shared, existing: target.existing) {
                editorTarget = nil
            }
        }
        .sheet(isPresented: $isPasting) {
            MCPPasteJSONSheet(shared: shared, onError: { importError = $0 }) {
                isPasting = false
            }
        }
        .alert("Import Error", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        ), actions: {
            Button("OK") { importError = nil }
        }, message: {
            Text(importError ?? "")
        })
    }

    // MARK: - Mutations

    private func setEnabled(_ enabled: Bool, for server: MCPServerConfig) {
        var servers = shared.mcpServers
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx].enabled = enabled
        shared.updateMCPServers(servers)
    }

    private func setTool(_ toolName: String, enabled: Bool, for server: MCPServerConfig) {
        var servers = shared.mcpServers
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        if enabled {
            servers[idx].disabledTools.remove(toolName)
        } else {
            servers[idx].disabledTools.insert(toolName)
        }
        shared.updateMCPServers(servers)
    }

    private func deleteServer(_ server: MCPServerConfig) {
        shared.mcpSecretStore.deleteAll(
            serverID: server.id,
            envVarNames: server.envVarNames,
            secretArgIndices: server.secretArgIndices
        )
        shared.updateMCPServers(shared.mcpServers.filter { $0.id != server.id })
    }
}

// MARK: - Row

private struct MCPServerRow: View {
    let server: MCPServerConfig
    let status: MCPServerStatus?
    let onToggleEnabled: (Bool) -> Void
    let onToggleTool: (String, Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var expanded = false
    @State private var errorExpanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Toggle("", isOn: Binding(get: { server.enabled }, set: { onToggleEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(server.name).font(.headline)
                            statusBadge()
                        }
                        Text(commandSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let instructions = status?.serverInstructions, !instructions.isEmpty {
                            Text(instructions)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 1)
                        }
                    }
                    Spacer()
                    Button("Edit", action: onEdit).buttonStyle(.borderless)
                    Button(role: .destructive, action: onDelete, label: {
                        Image(systemName: "trash")
                    })
                    .buttonStyle(.borderless)
                }

                if let error = status?.error, !error.isEmpty {
                    DisclosureGroup(isExpanded: $errorExpanded) {
                        ScrollView {
                            Text(fullErrorText(error: error, stderr: status?.stderrTail))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                        }
                        .frame(maxHeight: 220)
                    } label: {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    .font(.caption)
                }

                if let tools = status?.advertisedToolNames, !tools.isEmpty {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(tools.sorted(), id: \.self) { tool in
                                VStack(alignment: .leading, spacing: 1) {
                                    Toggle(tool, isOn: Binding(
                                        get: { !server.disabledTools.contains(tool) },
                                        set: { onToggleTool(tool, $0) }
                                    ))
                                    .font(.caption)
                                    .toggleStyle(.checkbox)
                                    if let desc = status?.toolDescriptions[tool], !desc.isEmpty {
                                        Text(desc)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.leading, 20)
                                    }
                                }
                            }
                        }
                        .padding(.leading, 8)
                        .padding(.top, 4)
                    } label: {
                        Text("\(tools.count) tool\(tools.count == 1 ? "" : "s") — \(status?.toolCount ?? 0) enabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if status?.error == nil, let stderr = status?.stderrTail, !stderr.isEmpty {
                    DisclosureGroup("Server log (stderr)") {
                        Text(stderr)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
            .padding(4)
        }
    }

    private var commandSummary: String {
        ([server.command] + server.args).joined(separator: " ")
    }

    /// The full, untruncated failure detail: the one-line reason plus the complete
    /// server stderr, shown when the user expands the error row.
    private func fullErrorText(error: String, stderr: String?) -> String {
        if let stderr, !stderr.isEmpty {
            return "\(error)\n\n— server log (stderr) —\n\(stderr)"
        }
        return error
    }

    @ViewBuilder
    private func statusBadge() -> some View {
        let state = server.enabled ? (status?.state ?? .connecting) : .disabled
        let (text, color): (String, Color) = {
            switch state {
            case .connecting: return ("connecting", .orange)
            case .connected: return ("connected", .green)
            case .failed: return ("failed", .red)
            case .disabled: return ("disabled", .secondary)
            }
        }()
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
