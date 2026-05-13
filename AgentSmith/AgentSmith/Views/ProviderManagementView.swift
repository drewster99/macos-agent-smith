import SwiftUI
import SwiftLLMKit
import os

nonisolated private let providerMgmtLogger = Logger(subsystem: "com.agentsmith", category: "ProviderManagement")

/// Settings tab listing built-in providers (top, fixed) and custom providers (below).
///
/// Built-in providers come from `BuiltInProviders.all` and have stable IDs, fixed
/// names/types/endpoints, and only an editable API key. Custom providers retain the
/// existing add/edit/delete behavior.
struct ProviderManagementView: View {
    @Bindable var llmKit: LLMKitManager
    @State private var editingProvider: ProviderEditorState?
    @State private var deleteError: String?
    @State private var showAllBuiltIns = false

    /// Built-in presets shown by default: those flagged `popular` plus any whose API key
    /// has already been entered. Sorted alphabetically by `displayName`.
    private var defaultVisibleBuiltIns: [BuiltInProviderPreset] {
        let popular = Set(BuiltInProviders.popular.map(\.id))
        let visible = BuiltInProviders.all.filter { preset in
            popular.contains(preset.id) || hasAPIKey(preset.id)
        }
        return visible.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Every built-in preset, sorted alphabetically. Used when "Show all" is on.
    private var allBuiltInsAlphabetical: [BuiltInProviderPreset] {
        BuiltInProviders.all.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Providers that aren't in `BuiltInProviders.allIDs` — i.e. user-added.
    private var customProviders: [ModelProvider] {
        llmKit.providers.filter { !BuiltInProviders.isBuiltIn(id: $0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            builtInSection()
            customSection()
        }
        .sheet(item: $editingProvider) { state in
            ProviderEditorSheet(
                llmKit: llmKit,
                state: state,
                onDismiss: { editingProvider = nil }
            )
        }
        .alert("Delete Error", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        ), actions: {
            Button("OK") { deleteError = nil }
        }, message: {
            Text(deleteError ?? "")
        })
    }

    // MARK: - Built-in section

    private func builtInSection() -> some View {
        let visible = showAllBuiltIns ? allBuiltInsAlphabetical : defaultVisibleBuiltIns
        let canShowMore = !showAllBuiltIns && visible.count < BuiltInProviders.all.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Providers")
                    .font(AppFonts.sectionHeader)
                Spacer()
                if showAllBuiltIns {
                    Button("Show popular only") { showAllBuiltIns = false }
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else if canShowMore {
                    Button("Show all (\(BuiltInProviders.all.count))") { showAllBuiltIns = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            ForEach(visible, id: \.id) { preset in
                BuiltInProviderRow(llmKit: llmKit, preset: preset)
            }
        }
    }

    // MARK: - Custom section

    @ViewBuilder

    private func customSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Custom Providers")
                    .font(AppFonts.sectionHeader)
                Spacer()
                Button(action: { addCustomProvider() }, label: {
                    Label("Add Provider", systemImage: "plus")
                })
            }

            if customProviders.isEmpty {
                Text("No custom providers. Add one for self-hosted endpoints or providers not in the built-in list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(customProviders) { provider in
                    customProviderRow(provider)
                }
            }
        }
    }

    private func customProviderRow(_ provider: ModelProvider) -> some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text(provider.apiType.displayName)
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(provider.endpoint.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("Edit") {
                    let apiKey = llmKit.apiKey(for: provider.id) ?? ""
                    editingProvider = ProviderEditorState(
                        mode: .edit,
                        id: provider.id,
                        name: provider.name,
                        apiType: provider.apiType,
                        endpointString: provider.endpoint.absoluteString,
                        apiKey: apiKey
                    )
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: {
                    deleteProvider(id: provider.id)
                }, label: {
                    Image(systemName: "trash")
                })
                .buttonStyle(.borderless)
            }
            .padding(4)
        }
    }

    private func addCustomProvider() {
        let defaultType = ProviderAPIType.openAICompatible
        editingProvider = ProviderEditorState(
            mode: .add,
            id: "provider-\(UUID().uuidString.prefix(8))",
            name: "Custom Provider",
            apiType: defaultType,
            endpointString: defaultType.defaultEndpoint.absoluteString,
            apiKey: ""
        )
    }

    private func deleteProvider(id: String) {
        do {
            try llmKit.deleteProvider(id: id)
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func hasAPIKey(_ providerID: String) -> Bool {
        if let key = llmKit.apiKey(for: providerID), !key.isEmpty { return true }
        return false
    }
}

// MARK: - Built-in row

/// One row in the built-in providers list. Shows the fixed name/type/endpoint and a
/// SecureField for the API key with an inline Save action. Built-in providers cannot
/// be deleted; clearing a key is done by emptying the field and saving.
///
/// Save side-effects:
/// - Stores the new key in Keychain via `LLMKitManager.setBuiltInProviderAPIKey`.
/// - Triggers a per-provider model refresh in the background so the model dropdown
///   for agents populates without the user needing to visit the Configurations tab.
/// - Registers an undo action that restores the previous key (and re-refreshes).
private struct BuiltInProviderRow: View {
    @Bindable var llmKit: LLMKitManager
    let preset: BuiltInProviderPreset

    @Environment(\.undoManager) private var undoManager

    @State private var draftKey: String = ""
    @State private var saveError: String?
    @State private var justSaved = false
    @State private var isRefreshing = false
    @State private var hasLoaded = false

    /// The currently-persisted API key, read reactively from `llmKit`. Observation
    /// of `llmKit.apiKeyChangeCounter` re-renders the body whenever any key is
    /// written through the manager (add/update/remove/built-in/undo), so
    /// external mutations are reflected immediately.
    private var savedKey: String {
        _ = llmKit.apiKeyChangeCounter  // register observation dependency
        return llmKit.apiKey(for: preset.id) ?? ""
    }

    private var hasUnsavedChanges: Bool {
        draftKey != savedKey
    }

    private var hasAPIKey: Bool {
        !savedKey.isEmpty
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(preset.displayName)
                        .font(.headline)
                    if hasAPIKey {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help("API key set")
                    }
                    Spacer()
                    Text(preset.endpoint.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    SecureField(hasAPIKey ? "••••••••" : "Paste API key", text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save() }

                    Button("Save") { save() }
                        .disabled(!hasUnsavedChanges)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else if justSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }

                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(4)
        }
        .onAppear {
            // Seed draftKey once from the currently-persisted value. Subsequent
            // external changes are picked up via the onChange below so we don't
            // clobber in-flight user edits.
            if !hasLoaded {
                draftKey = savedKey
                hasLoaded = true
            }
        }
        .onChange(of: llmKit.apiKeyChangeCounter) { _, _ in
            // Re-sync the draft to the new saved value only when the user isn't
            // mid-edit. This catches undo/redo from another window or any other
            // external mutation without dropping what the user is currently typing.
            // Project rule: defer the @State mutation out of .onChange.
            if !hasUnsavedChanges {
                DispatchQueue.main.async { self.draftKey = self.savedKey }
            }
        }
    }

    private func save() {
        let oldKey = savedKey
        let newKey = draftKey
        applyKey(newKey, registerUndoForOldKey: oldKey)
    }

    /// Applies a new key, persists it to Keychain, kicks off a per-provider model
    /// refresh, and registers an undo action that re-applies the previous value.
    /// Used by both the user-driven save path and the undo/redo handlers.
    private func applyKey(_ newKey: String, registerUndoForOldKey oldKey: String) {
        do {
            try llmKit.setBuiltInProviderAPIKey(id: preset.id, apiKey: newKey)
            // savedKey is computed from llmKit.apiKeyChangeCounter and will update
            // automatically on the next render. Sync draftKey so the SecureField
            // reflects the persisted value (and onChange doesn't treat the just-
            // persisted value as "unsaved changes" on its counter notification).
            draftKey = newKey
            saveError = nil
            withAnimation { justSaved = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { justSaved = false }
            }

            // Refresh this provider's models so the agent model dropdowns populate.
            // Skip when clearing a key — there's nothing to fetch without auth (for cloud
            // providers) and a refresh would fail noisily.
            if !newKey.isEmpty {
                isRefreshing = true
                let kit = llmKit
                let providerID = preset.id
                Task { @MainActor in
                    await kit.refreshModels(forProviderID: providerID)
                    isRefreshing = false
                }
            }

            // Register undo. The undo handler is captured with the same llmKit and
            // preset; on undo it re-runs applyKey with the values flipped, which itself
            // registers a redo entry — giving us free redo support.
            if let undoManager, oldKey != newKey {
                let kit = llmKit
                let presetCopy = preset
                undoManager.registerUndo(withTarget: kit) { _ in
                    Task { @MainActor in
                        do {
                            try kit.setBuiltInProviderAPIKey(id: presetCopy.id, apiKey: oldKey)
                            if !oldKey.isEmpty {
                                await kit.refreshModels(forProviderID: presetCopy.id)
                            }
                        } catch {
                            // Best-effort undo — log only.
                            providerMgmtLogger.error("undo failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
                undoManager.setActionName(oldKey.isEmpty
                    ? "Set \(preset.displayName) API Key"
                    : (newKey.isEmpty ? "Remove \(preset.displayName) API Key" : "Change \(preset.displayName) API Key"))
            }
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Editor State (for custom providers)

private struct ProviderEditorState: Identifiable {
    enum Mode { case add, edit }
    let mode: Mode
    var id: String
    var name: String
    var apiType: ProviderAPIType
    var endpointString: String
    var apiKey: String
}

// MARK: - Editor Sheet (for custom providers)

private struct ProviderEditorSheet: View {
    let llmKit: LLMKitManager
    @State var state: ProviderEditorState
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.mode == .add ? "Add Custom Provider" : "Edit Custom Provider")
                .font(.title2.bold())

            LabeledContent("Name") {
                TextField("e.g. My Local Server", text: $state.name)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("API Type") {
                Picker("", selection: $state.apiType) {
                    ForEach(ProviderAPIType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
            }

            LabeledContent("Endpoint") {
                HStack(spacing: 4) {
                    TextField("https://...", text: $state.endpointString)
                        .textFieldStyle(.roundedBorder)
                    endpointPresetMenu()
                }
            }

            LabeledContent("API Key") {
                SecureField("Optional", text: $state.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(state.mode == .add ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.name.isEmpty || URL(string: state.endpointString) == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 450)
        .onChange(of: state.apiType) { _, newType in
            applyDefaultEndpoint(for: newType)
        }
        .alert("Save Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        ), actions: {
            Button("OK") { saveError = nil }
        }, message: {
            Text(saveError ?? "")
        })
    }

    private func endpointPresetMenu() -> some View {
        let allPresets = ProviderAPIType.allEndpointPresets
        let cloudPresets = allPresets.filter { $0.preset.url.scheme == "https" }
        let localPresets = allPresets.filter { $0.preset.url.scheme != "https" }

        return Menu(
            content: {
                if !cloudPresets.isEmpty {
                    Section("Cloud APIs") {
                        ForEach(cloudPresets, id: \.preset.label) { entry in
                            Button(entry.preset.label) {
                                state.endpointString = entry.preset.url.absoluteString
                                state.apiType = entry.apiType
                            }
                        }
                    }
                }
                if !localPresets.isEmpty {
                    Section("Local") {
                        ForEach(localPresets, id: \.preset.label) { entry in
                            Button(entry.preset.label) {
                                state.endpointString = entry.preset.url.absoluteString
                                state.apiType = entry.apiType
                            }
                        }
                    }
                }
            },
            label: {
                Image(systemName: "chevron.down.circle")
                    .foregroundStyle(.secondary)
            }
        )
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .help("Choose a common endpoint")
    }

    private func applyDefaultEndpoint(for type: ProviderAPIType) {
        state.endpointString = type.defaultEndpoint.absoluteString
        if state.mode == .add {
            let autoFilledNames = Set(ProviderAPIType.allCases.map(\.displayName))
            if state.name.isEmpty || autoFilledNames.contains(state.name) {
                state.name = type.displayName
            }
        }
    }

    @State private var saveError: String?

    private func save() {
        guard let endpoint = URL(string: state.endpointString) else { return }
        let provider = ModelProvider(
            id: state.id,
            name: state.name,
            apiType: state.apiType,
            endpoint: endpoint
        )
        do {
            switch state.mode {
            case .add:
                try llmKit.addProvider(provider, apiKey: state.apiKey)
            case .edit:
                try llmKit.updateProvider(provider, apiKey: state.apiKey)
            }
            onDismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
