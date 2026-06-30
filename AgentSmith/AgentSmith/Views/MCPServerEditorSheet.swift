import SwiftUI
import AgentSmithKit
import os

private let mcpEditorLogger = Logger(subsystem: "com.agentsmith", category: "MCPEditor")

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
    /// Stable id for a not-yet-persisted server. Generated once per sheet presentation so
    /// Keychain accounts stay consistent across multiple Save attempts (a partial write
    /// followed by a retry reuses the same accounts instead of orphaning the first try's
    /// secrets). Unused when editing an existing server (`serverID` returns `existing.id`).
    @State private var draftID = UUID()

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
            Text("Passed to the command in order. Flag any argument that holds a secret (API key, token) — its value moves to the Keychain on Save.")
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

    /// Stable server id used for Keychain accounts: the existing server's id when editing,
    /// otherwise the per-presentation `draftID`. Always returns the same value for a given
    /// sheet, so the accounts written under it stay in sync with the saved config.
    private var serverID: UUID {
        existing?.id ?? draftID
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let id = serverID

        // Reject a name that collides with a different server (it's the tool-name prefix).
        if shared.mcpServers.contains(where: { $0.name == trimmedName && $0.id != id }) {
            validationError = "Another server already uses the name \"\(trimmedName)\"."
            return
        }

        // Validate up front: every secret-flagged arg must have a value. We deliberately
        // check this BEFORE touching the Keychain so a partial-write failure can't leave
        // the store in a state inconsistent with the config.
        for (index, row) in argRows.enumerated() where row.isSecret && row.value.isEmpty {
            validationError = "Argument #\(index + 1) is marked Secret but has no value."
            return
        }

        // Compute the final arg layout and the new set of secret indices from the
        // current form state. Values for secret rows stay in `row.value` (we do NOT
        // migrate to the Keychain on toggle) and ride along to the final index, so
        // reordering or removing a row above a secret row can never strand a value
        // at the wrong Keychain account.
        var finalArgs: [String] = []
        var newSecretIndices: Set<Int> = []
        for (index, row) in argRows.enumerated() {
            if row.isSecret {
                newSecretIndices.insert(index)
                finalArgs.append("")  // placeholder; real value lives in the Keychain
            } else {
                finalArgs.append(row.value)
            }
        }

        // Two-phase commit so a failure on row N can't leave rows < N already wiped:
        // 1. compute the set of Keychain accounts to delete (existing indices that
        //    are no longer flagged secret, plus env vars that were renamed/removed);
        // 2. compute the set to write (current secret args and env vars);
        // 3. perform all writes/deletes; if any one fails, abort BEFORE updating
        //    the config and surface a clear error pointing at the failed account.
        let previousSecretIndices = existing?.secretArgIndices ?? []
        let indicesToDelete = previousSecretIndices.subtracting(newSecretIndices)
        let previousEnvNames = Set(existing?.envVarNames ?? [])
        // Preserve the order the user entered env vars in, deduping by name; a Set is
        // derived alongside for the rename/removal diff.
        var newEnvNamesOrdered: [String] = []
        var newEnvNames: Set<String> = []
        for row in envRows {
            let trimmed = row.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, newEnvNames.insert(trimmed).inserted else { continue }
            newEnvNamesOrdered.append(trimmed)
        }
        let envNamesToDelete = previousEnvNames.subtracting(newEnvNames)

        var keychainFailures: [String] = []

        // Phase 1: write new/updated secret args.
        for index in newSecretIndices.sorted() {
            let row = argRows[index]
            let account = MCPSecretStore.argAccount(serverID: id, index: index)
            do {
                try shared.mcpSecretStore.save(row.value, account: account)
            } catch {
                keychainFailures.append("argument #\(index + 1)")
            }
        }

        // Phase 2: write new/updated env vars.
        for row in envRows {
            let envName = row.name.trimmingCharacters(in: .whitespaces)
            guard !envName.isEmpty else { continue }
            do {
                try shared.mcpSecretStore.save(row.value, account: MCPSecretStore.envAccount(serverID: id, name: envName))
            } catch {
                keychainFailures.append("environment variable \"\(envName)\"")
            }
        }

        // Phase 3: delete Keychain accounts that are no longer referenced (renamed/removed args or
        // env vars). Only run this if all writes succeeded — otherwise we'd lose old secrets we can no
        // longer reconstruct. A cleanup delete that fails leaves a harmless *orphaned* secret; it must
        // NOT block the save: the new secrets are already written (Phases 1–2), so failing here would
        // strand the Keychain and the on-disk config in inconsistent states. Collect cleanup failures
        // separately, log them, and let the save proceed.
        var cleanupFailures: [String] = []
        if keychainFailures.isEmpty {
            for index in indicesToDelete.sorted() {
                let account = MCPSecretStore.argAccount(serverID: id, index: index)
                do {
                    try shared.mcpSecretStore.delete(account: account)
                } catch {
                    cleanupFailures.append("argument #\(index + 1)")
                }
            }
            for envName in envNamesToDelete.sorted() {
                let account = MCPSecretStore.envAccount(serverID: id, name: envName)
                do {
                    try shared.mcpSecretStore.delete(account: account)
                } catch {
                    cleanupFailures.append("environment variable \"\(envName)\"")
                }
            }
        }

        if !keychainFailures.isEmpty {
            validationError = "Failed to save secret(s) to the Keychain: \(keychainFailures.joined(separator: ", ")). The configuration was not updated; please retry."
            return
        }
        if !cleanupFailures.isEmpty {
            mcpEditorLogger.warning("Failed to remove orphaned Keychain secret(s): \(cleanupFailures.joined(separator: ", "), privacy: .public). Saved the configuration anyway; the orphaned secret(s) are unused.")
        }

        let config = MCPServerConfig(
            id: id,
            name: trimmedName,
            enabled: existing?.enabled ?? true,
            command: command.trimmingCharacters(in: .whitespaces),
            args: finalArgs,
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            envVarNames: newEnvNamesOrdered,
            secretArgIndices: newSecretIndices,
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
