import SwiftUI
import AgentSmithKit

/// Add/edit form for a single MCP server. Secret env values and secret-flagged args
/// are stored in the Keychain; the rest is persisted via `SharedAppState`.
struct MCPServerEditorSheet: View {
    @Bindable var shared: SharedAppState
    let existing: MCPServerConfig?
    let onDone: () -> Void

    @State private var name = ""
    @State private var command = ""
    @State private var workingDirectory = ""
    @State private var argRows: [ArgRow] = []
    @State private var envRows: [EnvRow] = []
    @State private var validationError: String?
    @State private var loaded = false

    private struct ArgRow: Identifiable {
        let id = UUID()
        var value: String
        var isSecret: Bool
    }
    private struct EnvRow: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "Add MCP Server" : "Edit MCP Server")
                .font(.title2.bold())
                .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Name", text: $name, placeholder: "e.g. filesystem")
                    field("Command", text: $command, placeholder: "e.g. npx")
                    field("Working directory (optional)", text: $workingDirectory, placeholder: "/path/to/dir")

                    argsSection()
                    envSection()

                    if let validationError {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onAppear(perform: loadIfNeeded)
    }

    // MARK: - Sections

    @ViewBuilder
    private func argsSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Arguments").font(AppFonts.sectionHeader)
                Spacer()
                Button(action: { argRows.append(ArgRow(value: "", isSecret: false)) }, label: {
                    Image(systemName: "plus")
                })
                .buttonStyle(.borderless)
            }
            Text("Passed to the command in order. Flag any argument that holds a secret (API key, token) — its value moves to the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($argRows) { $row in
                HStack {
                    if row.isSecret {
                        SecureField("value", text: $row.value).textFieldStyle(.roundedBorder)
                    } else {
                        TextField("value", text: $row.value).textFieldStyle(.roundedBorder)
                    }
                    Toggle("Secret", isOn: $row.isSecret).toggleStyle(.checkbox).font(.caption)
                    Button(action: { argRows.removeAll { $0.id == row.id } }, label: {
                        Image(systemName: "minus.circle")
                    })
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private func envSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Environment Variables").font(AppFonts.sectionHeader)
                Spacer()
                Button(action: { envRows.append(EnvRow(name: "", value: "")) }, label: {
                    Image(systemName: "plus")
                })
                .buttonStyle(.borderless)
            }
            Text("Values are stored in the Keychain and injected into the server process at launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($envRows) { $row in
                HStack {
                    TextField("NAME", text: $row.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    SecureField("value", text: $row.value).textFieldStyle(.roundedBorder)
                    Button(action: { envRows.removeAll { $0.id == row.id } }, label: {
                        Image(systemName: "minus.circle")
                    })
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Load / Save

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let existing else { return }
        name = existing.name
        command = existing.command
        workingDirectory = existing.workingDirectory ?? ""
        argRows = existing.args.enumerated().map { index, value in
            if existing.secretArgIndices.contains(index) {
                let secret = shared.mcpSecretStore.secret(account: MCPSecretStore.argAccount(serverID: existing.id, index: index)) ?? ""
                return ArgRow(value: secret, isSecret: true)
            }
            return ArgRow(value: value, isSecret: false)
        }
        envRows = existing.envVarNames.map { envName in
            let value = shared.mcpSecretStore.secret(account: MCPSecretStore.envAccount(serverID: existing.id, name: envName)) ?? ""
            return EnvRow(name: envName, value: value)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let id = existing?.id ?? UUID()

        // Reject a name that collides with a different server (it's the tool-name prefix).
        if shared.mcpServers.contains(where: { $0.name == trimmedName && $0.id != id }) {
            validationError = "Another server already uses the name \"\(trimmedName)\"."
            return
        }

        // Clear any prior secrets for this server, then re-write the current set so stale
        // entries (renamed env vars, re-flagged args) never linger in the Keychain.
        shared.mcpSecretStore.deleteAll(
            serverID: id,
            envVarNames: existing?.envVarNames ?? [],
            secretArgIndices: existing?.secretArgIndices ?? []
        )

        var finalArgs: [String] = []
        var secretIndices: Set<Int> = []
        for (index, row) in argRows.enumerated() {
            if row.isSecret {
                secretIndices.insert(index)
                try? shared.mcpSecretStore.save(row.value, account: MCPSecretStore.argAccount(serverID: id, index: index))
                finalArgs.append("")
            } else {
                finalArgs.append(row.value)
            }
        }

        var envNames: [String] = []
        for row in envRows where !row.name.trimmingCharacters(in: .whitespaces).isEmpty {
            let envName = row.name.trimmingCharacters(in: .whitespaces)
            try? shared.mcpSecretStore.save(row.value, account: MCPSecretStore.envAccount(serverID: id, name: envName))
            envNames.append(envName)
        }

        let config = MCPServerConfig(
            id: id,
            name: trimmedName,
            enabled: existing?.enabled ?? true,
            command: command.trimmingCharacters(in: .whitespaces),
            args: finalArgs,
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            envVarNames: envNames,
            secretArgIndices: secretIndices,
            disabledTools: existing?.disabledTools ?? []
        )

        var servers = shared.mcpServers
        if let idx = servers.firstIndex(where: { $0.id == id }) {
            servers[idx] = config
        } else {
            servers.append(config)
        }
        shared.updateMCPServers(servers)
        onDone()
    }
}

/// Sheet for pasting a standard `{ "mcpServers": { … } }` JSON blob.
struct MCPPasteJSONSheet: View {
    @Bindable var shared: SharedAppState
    let onError: (String) -> Void
    let onDone: () -> Void

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Paste MCP Server JSON")
                .font(.title2.bold())
                .padding()
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste a configuration block in the standard format. Every \"env\" value is stored in the Keychain on import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            .padding()
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                Button("Import", action: importJSON)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 540, height: 420)
    }

    private func importJSON() {
        let existingNames = Set(shared.mcpServers.map(\.name))
        do {
            let outcome = try MCPConfigImport.parse(json: text, existingNames: existingNames, secretStore: shared.mcpSecretStore)
            shared.updateMCPServers(shared.mcpServers + outcome.configs)
            if !outcome.warnings.isEmpty {
                onError(outcome.warnings.joined(separator: "\n"))
            }
            onDone()
        } catch {
            onError(String(describing: error))
        }
    }
}
