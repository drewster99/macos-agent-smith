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
        TabView {
            Tab("General", systemImage: "gearshape") {
                ScrollView {
                    generalTab()
                        .padding()
                }
            }

            Tab("Providers", systemImage: "server.rack") {
                ScrollView {
                    ProviderManagementView(llmKit: shared.llmKit)
                        .padding()
                }
            }

            Tab("Configurations", systemImage: "slider.horizontal.3") {
                ScrollView {
                    configurationsTab()
                        .padding()
                }
            }

            Tab("Audio", systemImage: "speaker.wave.2") {
                ScrollView {
                    audioSettingsSection()
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

            Text("Scheduling")
                .font(AppFonts.sectionHeader)

            Toggle("Scheduled tasks interrupt the running task", isOn: $shared.scheduledWakesInterruptRunning)

            Text("When ON: a scheduled task's wake pauses any currently running task, runs the scheduled task to completion, then resumes the paused task. When OFF (default): the running task finishes first, then the scheduled task runs. Either way, scheduled tasks ALWAYS run when their wake fires — independent of \"Auto-run next task\".")
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

    // MARK: - Configurations Tab

    @State private var editingConfig: ModelConfiguration?
    @State private var isCreatingConfig = false
    /// (providerID, modelID) of the model whose behavior flags are being edited.
    /// Drives the `BehaviorFlagsEditorSheet` presentation.
    @State private var editingFlagsFor: FlagsEditTarget?

    private struct FlagsEditTarget: Identifiable {
        let providerID: String
        let modelID: String
        var id: String { "\(providerID)/\(modelID)" }
    }

    @ViewBuilder

    private func configurationsTab() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model Configurations")
                    .font(AppFonts.sectionHeader)
                Spacer()
                Button(action: { isCreatingConfig = true }, label: {
                    Label("New Configuration", systemImage: "plus")
                })
            }

            if shared.llmKit.configurations.isEmpty {
                Text("No configurations yet. Create one to assign to agents.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(shared.llmKit.configurations) { config in
                    configRow(config)
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
        .sheet(isPresented: $isCreatingConfig) {
            ModelConfigurationEditorView(
                llmKit: shared.llmKit,
                existingConfig: nil,
                onSave: { config in
                    shared.llmKit.addConfiguration(config)
                },
                onDismiss: { isCreatingConfig = false }
            )
        }
        .sheet(item: $editingConfig) { config in
            ModelConfigurationEditorView(
                llmKit: shared.llmKit,
                existingConfig: config,
                onSave: { updated in
                    shared.llmKit.updateConfiguration(updated)
                },
                onDismiss: { editingConfig = nil }
            )
        }
        .sheet(item: $editingFlagsFor) { target in
            BehaviorFlagsEditorSheet(
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

    private func configRow(_ config: ModelConfiguration) -> some View {
        let provider = shared.llmKit.providers.first { $0.id == config.providerID }
        let modelInfo = shared.llmKit.modelInfo(providerID: config.providerID, modelID: config.modelID)
        let behaviorFlags = shared.llmKit.behaviorFlags(forProviderID: config.providerID, modelID: config.modelID)
        return GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(config.name)
                            .font(.headline)
                        if !config.isValid {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(config.validationError ?? "Invalid configuration")
                        }
                    }
                    HStack(spacing: 8) {
                        if let provider {
                            Text(provider.name)
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(config.modelID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("temp \(String(format: "%.1f", config.temperature))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("max \(formatTokenCount(config.maxOutputTokens))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let budget = config.thinkingBudget, budget > 0 {
                            Text("think \(formatTokenCount(budget))")
                                .font(.caption)
                                .foregroundStyle(.purple)
                        }
                        if let info = modelInfo {
                            pricingLabel(for: info)
                        }
                    }
                    if !behaviorFlags.isAllDefault {
                        behaviorFlagRow(behaviorFlags)
                    }
                }
                Spacer()
                Button("Duplicate") {
                    shared.llmKit.duplicateConfiguration(id: config.id)
                }
                .buttonStyle(.borderless)
                Button("Flags") {
                    editingFlagsFor = FlagsEditTarget(
                        providerID: config.providerID,
                        modelID: config.modelID
                    )
                }
                .buttonStyle(.borderless)
                .help("Edit per-model behavior flags (GLM salvage, max_completion_tokens, parallel tools)")
                Button("Edit") {
                    editingConfig = config
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: {
                    sessionManager.deleteConfiguration(id: config.id)
                }, label: {
                    Image(systemName: "trash")
                })
                .buttonStyle(.borderless)
            }
            .padding(4)
        }
    }

    // MARK: - (Agent Assignments moved to InspectorView)

    /// Read-only display of resolved behavior flags for this config's model.
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
