import AppKit
import AVFoundation
import SwiftUI
import AgentSmithKit
import SwiftLLMKit

/// Settings window: app-global preferences only. Per-session agent assignments are
/// now edited in each session window's Inspector, not here.
struct SettingsView: View {
    @Bindable var shared: SharedAppState
    @Bindable var sessionManager: SessionManager

    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @State private var exportError: String?

    var body: some View {
        TabView(selection: $shared.settingsSelectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                ScrollView {
                    generalTab()
                        .padding()
                }
            }

            Tab("Providers", systemImage: "server.rack", value: SettingsTab.providers) {
                ScrollView {
                    ProviderManagementView(llmKit: shared.llmKit)
                        .padding()
                }
            }

            Tab("Models", systemImage: "slider.horizontal.3", value: SettingsTab.models) {
                ScrollView {
                    modelsTab()
                        .padding()
                }
            }

            Tab("Metadata", systemImage: "checklist", value: SettingsTab.metadata) {
                ScrollViewReader { proxy in
                    ScrollView {
                        MetadataCoverageView(shared: shared, scrollProxy: proxy)
                            .padding()
                    }
                }
            }

            Tab("Audio", systemImage: "speaker.wave.2", value: SettingsTab.audio) {
                ScrollView {
                    audioSettingsSection()
                        .padding()
                }
            }

            Tab("MCP Servers", systemImage: "network", value: SettingsTab.mcp) {
                ScrollView {
                    MCPServerManagementView(shared: shared)
                        .padding()
                }
            }

            Tab("Tools", systemImage: "wrench.and.screwdriver", value: SettingsTab.tools) {
                ScrollView {
                    ToolsSettingsView(shared: shared)
                        .padding()
                }
            }
        }
        .frame(minWidth: 550, minHeight: 600)
        .onAppear {
            availableVoices = AVSpeechSynthesisVoice.speechVoices()
                .sorted { $0.name < $1.name }
        }
    }

    // MARK: - General Tab

    @ViewBuilder

    private func generalTab() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account")
                .font(AppFonts.sectionHeader)

            LabeledContent("What should I call you?") {
                TextField("Your name or nickname", text: $shared.nickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)
                    .onSubmit { shared.persistNickname() }
            }

            Text("This name is shown in the channel log and included in agent system prompts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Launch Behavior")
                .font(AppFonts.sectionHeader)

            Toggle("Auto-start sessions on launch", isOn: $shared.autoStartEnabled)

            Text("When enabled, sessions with valid configuration automatically start their agents on launch.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Per-session options (auto-run next task, agent assignments, tunings) are configured in each window's Inspector.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Tasks")
                .font(AppFonts.sectionHeader)

            Stepper(value: $shared.maxSimultaneousTasks, in: 1...10) {
                Text("Max simultaneous tasks: \(shared.maxSimultaneousTasks)")
            }

            Text("How many tasks may run at the same time, each with its own worker agent. Starting beyond this limit never interrupts a running task — extra tasks queue as pending and auto-run starts them as slots free. Applies immediately to active sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Auto-archive completed tasks", isOn: $shared.autoArchiveCompletedEnabled)

            Stepper(value: $shared.autoArchiveCutoffHours, in: 1...168) {
                Text("Archive completed tasks after: \(shared.autoArchiveCutoffHours) \(shared.autoArchiveCutoffHours == 1 ? "hour" : "hours")")
            }
            .disabled(!shared.autoArchiveCompletedEnabled)

            Text("When enabled, completed tasks older than this are moved to the Archived bucket automatically. The sweep runs at launch and whenever a new task is created — not on a background timer. Failed tasks are never auto-archived. Off by default; applies immediately to active sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(value: $shared.taskOverlayColumns, in: 1...8) {
                Text("Task overlay columns: \(shared.taskOverlayColumns)")
            }

            Text("How many task panels the top-of-window overlay bar shows side by side. Additional tasks collect in the bar's overflow menu.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Security")
                .font(AppFonts.sectionHeader)

            Toggle("Pre-flight tool scoping (Security Agent picks each task's tools)", isOn: $shared.enablePreflightScoping)

            Text("Pre-flight scoping has the security agent choose which tools the worker may use for a task before it starts. The per-call check reviews each individual tool call (SAFE/WARN/UNSAFE/ABORT). Turning either off reduces oversight. Per-tool Always/Never overrides live in the Tools tab. Changes apply immediately to active sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Display")
                .font(AppFonts.sectionHeader)

            Toggle("Show timestamps on task state changes", isOn: $shared.showTimestampsOnTaskBanners)
            Toggle("Show timestamps on tool calls", isOn: $shared.showTimestampsOnToolCalls)
            Toggle("Show timestamps on messaging", isOn: $shared.showTimestampsOnMessaging)
            Toggle("Show timestamps on system messages", isOn: $shared.showTimestampsOnSystemMessages)
            Toggle("Show elapsed time on tool calls", isOn: $shared.showElapsedTimeOnToolCalls)
            Toggle("Show agent restart chrome", isOn: $shared.showRestartChrome)

            Text("Timestamps and elapsed time are display-only — they don't change what gets sent to agents. \"Restart chrome\" controls whether transient lifecycle rows (agents stopping / coming online) appear in the transcript. Apply across all sessions and windows.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Attachments")
                .font(AppFonts.sectionHeader)

            attachmentSizeRow(
                label: "Max size per attachment",
                bytesBinding: $shared.maxAttachmentBytesPerFile,
                helpText: "Files larger than this are rejected at ingestion. Phone-camera photos are typically 3–8 MB; PDFs vary widely."
            )

            attachmentSizeRow(
                label: "Max total per message",
                bytesBinding: $shared.maxAttachmentBytesPerMessage,
                helpText: "Aggregate cap for all attachments on a single message or tool call. Protects context cost from unbounded fan-out."
            )

            Text("Caps apply when a session starts. Changing them mid-session takes effect after the next agent restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Slider + label row for an attachment-size setting (megabytes-resolution).
    @ViewBuilder
    private func attachmentSizeRow(label: String, bytesBinding: Binding<Int>, helpText: String) -> some View {
        let mb = Binding<Double>(
            get: { Double(bytesBinding.wrappedValue) / 1_048_576.0 },
            set: { bytesBinding.wrappedValue = Int($0 * 1_048_576) }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.0f MB", mb.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: mb, in: 1...500, step: 1)
                .frame(maxWidth: 400)
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Models Tab

    @State private var modelFilterText = ""
    @State private var modelSortOrder: ModelSortOrder = .provider

    /// Display order for the models list.
    private enum ModelSortOrder: String, CaseIterable, Identifiable {
        case provider = "Provider"
        case model = "Model"
        var id: String { rawValue }
    }

    /// One (provider, model) pair — the unit the Models tab lists and edits. The config pool was
    /// retired 2026-07-31, so this tab edits per-model metadata (flags / capabilities / pricing)
    /// keyed on `(providerID, modelID)`, not `ModelConfiguration` objects.
    private struct ProviderModel: Identifiable {
        let provider: ModelProvider
        let model: ModelInfo
        var id: String { "\(provider.id)/\(model.modelID)" }
    }

    /// (providerID, modelID) of the model whose per-model flags / capabilities / pricing are being
    /// edited. Drives the corresponding editor-sheet presentations.
    @State private var editingFlagsFor: FlagsEditTarget?
    @State private var editingCapabilitiesFor: FlagsEditTarget?
    @State private var editingPricingFor: FlagsEditTarget?

    private struct FlagsEditTarget: Identifiable {
        let providerID: String
        let modelID: String
        var id: String { "\(providerID)/\(modelID)" }
    }

    @ViewBuilder

    private func modelsTab() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Models")
                    .font(AppFonts.sectionHeader)
                Spacer()
            }

            if shared.llmKit.providers.isEmpty {
                Text("No providers configured. Add one in Settings → Providers.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                HStack(spacing: 8) {
                    TextField("Filter by provider or model", text: $modelFilterText)
                        .textFieldStyle(.roundedBorder)
                    Picker("Sort", selection: $modelSortOrder) {
                        ForEach(ModelSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .fixedSize()
                }
                let displayed = displayedModels()
                if displayed.isEmpty {
                    Text(modelFilterText.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "No models cached. Use Refresh Models below."
                         : "No models match \u{201C}\(modelFilterText)\u{201D}.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ForEach(displayed) { pair in
                        modelRow(provider: pair.provider, model: pair.model)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            HStack {
                Button("Refresh Models") {
                    Task { await shared.llmKit.forceRefresh() }
                }
                .disabled(shared.llmKit.isRefreshing)
                if shared.llmKit.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Export Current Settings as Defaults JSON\u{2026}") {
                    exportDefaults()
                }
            }

            if !shared.llmKit.refreshErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shared.llmKit.refreshErrors.sorted(by: { $0.key < $1.key }), id: \.key) { provider, error in
                        Label("\(provider): \(error)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .sheet(item: $editingFlagsFor) { target in
            BehaviorFlagsEditorSheet(
                shared: shared,
                providerID: target.providerID,
                modelID: target.modelID
            )
        }
        .sheet(item: $editingCapabilitiesFor) { target in
            CapabilitiesEditorSheet(
                shared: shared,
                providerID: target.providerID,
                modelID: target.modelID
            )
        }
        .sheet(item: $editingPricingFor) { target in
            PricingEditorSheet(
                shared: shared,
                providerID: target.providerID,
                modelID: target.modelID
            )
        }
        .alert("Export Error", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        ), actions: {
            Button("OK") { exportError = nil }
        }, message: {
            Text(exportError ?? "")
        })
    }

    /// Every cached (provider, model) pair, filtered and ordered by the tab's controls. Filtering
    /// matches the provider's display name, the model ID, and the model's display name,
    /// case-insensitively.
    private func displayedModels() -> [ProviderModel] {
        var pairs: [ProviderModel] = []
        for provider in shared.llmKit.providers {
            for model in shared.llmKit.models(for: provider.id) {
                pairs.append(ProviderModel(provider: provider, model: model))
            }
        }
        let query = modelFilterText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            pairs = pairs.filter { pair in
                pair.provider.name.localizedCaseInsensitiveContains(query)
                    || pair.model.modelID.localizedCaseInsensitiveContains(query)
                    || pair.model.displayName.localizedCaseInsensitiveContains(query)
            }
        }
        switch modelSortOrder {
        case .provider:
            return pairs.sorted { lhs, rhs in
                if lhs.provider.name.localizedCaseInsensitiveCompare(rhs.provider.name) != .orderedSame {
                    return lhs.provider.name.localizedCaseInsensitiveCompare(rhs.provider.name) == .orderedAscending
                }
                return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName) == .orderedAscending
            }
        case .model:
            return pairs.sorted { $0.model.displayName.localizedCaseInsensitiveCompare($1.model.displayName) == .orderedAscending }
        }
    }

    private func modelRow(provider: ModelProvider, model: ModelInfo) -> some View {
        let behaviorFlags = shared.llmKit.behaviorFlags(forProviderID: provider.id, modelID: model.modelID)
        return GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.headline)
                        if model.isNew {
                            Text("New")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(provider.name)
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(model.modelID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let maxOut = model.maxOutputTokens {
                            Text("max \(formatTokenCount(maxOut))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let maxIn = model.maxInputTokens {
                            Text("ctx \(formatTokenCount(maxIn))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        pricingLabel(for: model)
                    }
                    if !model.capabilities.enabledLabels.isEmpty {
                        Text(model.capabilities.enabledLabels.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !behaviorFlags.isAllDefault {
                        behaviorFlagRow(behaviorFlags)
                    }
                }
                Spacer()
                Button("Flags") {
                    editingFlagsFor = FlagsEditTarget(providerID: provider.id, modelID: model.modelID)
                }
                .buttonStyle(.borderless)
                .help("Edit per-model behavior flags (GLM salvage, max_completion_tokens, parallel tools)")
                Button("Caps") {
                    editingCapabilitiesFor = FlagsEditTarget(providerID: provider.id, modelID: model.modelID)
                }
                .buttonStyle(.borderless)
                .help("Override per-model capability flags (vision, tool use, …) when the catalog is wrong")
                Button("Pricing") {
                    editingPricingFor = FlagsEditTarget(providerID: provider.id, modelID: model.modelID)
                }
                .buttonStyle(.borderless)
                .help("View resolved pricing and override input/output rates (USD per 1M tokens)")
            }
            .padding(4)
        }
    }

    // MARK: - (Agent Assignments moved to InspectorView)

    /// Read-only display of resolved behavior flags for this model.
    /// Resolved by `LLMKitManager.behaviorFlags(forProviderID:modelID:)` —
    /// merged from bundled provider-defaults, bundled per-model entries,
    /// LiteLLM (where applicable), and user overrides. Editing flows through
    /// the user-overrides JSON file, not this row.
    private func behaviorFlagRow(_ flags: BehaviorFlags) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(flags.displayLabels, id: \.self) { label in
                Text(label)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(AppColors.flagChipBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(AppColors.flagChipForeground)
            }
        }
        .help("Per-model behavior flags resolved from bundled defaults + user overrides. Edit via the user model overrides JSON.")
    }

    /// Compact pricing label showing input/output cost per million tokens.
    @ViewBuilder
    private func pricingLabel(for info: ModelInfo) -> some View {
        if let pricing = info.pricing, pricing.base.hasAnyRate {
            Text(PricingFormatter.summary(pricing))
                .font(.caption)
                .foregroundStyle(.green)
        }
    }


    // MARK: - Audio settings

    @ViewBuilder

    private func audioSettingsSection() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Settings")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            // User
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label(shared.nickname.isEmpty ? "User" : shared.nickname, systemImage: "person.circle")
                        .font(AppFonts.sectionHeader)
                        .foregroundStyle(.blue)

                    VoicePickerRow(
                        voiceIdentifier: Binding(
                            get: { shared.speechController.userVoiceIdentifier },
                            set: { shared.speechController.setUserVoice($0) }
                        ),
                        availableVoices: availableVoices,
                        onTest: { shared.speechController.previewUserSpeech() }
                    )

                    SoundPickerRow(
                        label: "Message sound",
                        soundName: Binding(
                            get: { shared.speechController.userSound.soundName },
                            set: {
                                var config = shared.speechController.userSound
                                config.soundName = $0
                                shared.speechController.setUserSound(config)
                            }
                        ),
                        onPreview: { shared.speechController.previewSound(named: $0) }
                    )

                    Toggle("Speak user messages", isOn: Binding(
                        get: { shared.speechController.userSound.speakEnabled },
                        set: {
                            var config = shared.speechController.userSound
                            config.speakEnabled = $0
                            shared.speechController.setUserSound(config)
                        }
                    ))
                    .font(AppFonts.inspectorBody)
                }
                .padding(8)
            }

            // Narrator
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Narrator", systemImage: "text.bubble")
                        .font(AppFonts.sectionHeader)
                        .foregroundStyle(.purple)

                    Toggle("Enabled", isOn: Binding(
                        get: { shared.speechController.narratorEnabled },
                        set: { shared.speechController.setNarratorEnabled($0) }
                    ))

                    VoicePickerRow(
                        voiceIdentifier: Binding(
                            get: { shared.speechController.narratorVoiceIdentifier },
                            set: { shared.speechController.setNarratorVoice($0) }
                        ),
                        availableVoices: availableVoices,
                        onTest: { shared.speechController.previewNarratorSpeech() }
                    )
                }
                .padding(8)
            }

            // Security sounds
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Security Review Sounds", systemImage: "shield.lefthalf.filled")
                        .font(AppFonts.sectionHeader)
                        .foregroundStyle(.orange)

                    SoundPickerRow(
                        label: "Approved",
                        soundName: Binding(
                            get: { shared.speechController.securitySafeSoundName },
                            set: { shared.speechController.setSecuritySafeSound($0) }
                        ),
                        onPreview: { shared.speechController.previewSound(named: $0) }
                    )

                    SoundPickerRow(
                        label: "Warning",
                        soundName: Binding(
                            get: { shared.speechController.securityWarnSoundName },
                            set: { shared.speechController.setSecurityWarnSound($0) }
                        ),
                        onPreview: { shared.speechController.previewSound(named: $0) }
                    )

                    SoundPickerRow(
                        label: "Denied",
                        soundName: Binding(
                            get: { shared.speechController.securityDenySoundName },
                            set: { shared.speechController.setSecurityDenySound($0) }
                        ),
                        onPreview: { shared.speechController.previewSound(named: $0) }
                    )

                    SoundPickerRow(
                        label: "Abort",
                        soundName: Binding(
                            get: { shared.speechController.securityAbortSoundName },
                            set: { shared.speechController.setSecurityAbortSound($0) }
                        ),
                        onPreview: { shared.speechController.previewSound(named: $0) }
                    )
                }
                .padding(8)
            }
        }
    }

    private func exportDefaults() {
        // Per-session assignments/tunings are exported from the first session in the list
        // (or fall back to shared defaults if no session exists yet). The resulting
        // defaults.json is still a single flat blob — it doesn't capture per-session divergence.
        let firstVM = sessionManager.sessions.first.flatMap { sessionManager.viewModel(for: $0.id) }
        let assignments = firstVM?.agentAssignments ?? shared.defaultAgentAssignments
        let pollIntervals = firstVM?.agentPollIntervals ?? shared.defaultAgentPollIntervals
        let maxToolCalls = firstVM?.agentMaxToolCalls ?? shared.defaultAgentMaxToolCalls
        let debounceIntervals = firstVM?.agentMessageDebounceIntervals ?? shared.defaultAgentMessageDebounceIntervals

        let data: Data
        do {
            data = try DefaultsExporter.exportCurrentSettings(
                llmKit: shared.llmKit,
                agentAssignments: assignments,
                pollIntervals: pollIntervals,
                maxToolCalls: maxToolCalls,
                messageDebounceIntervals: debounceIntervals,
                speechController: shared.speechController
            )
        } catch {
            exportError = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "defaults.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            exportError = "Failed to write file: \(error.localizedDescription)"
        }
    }
}
