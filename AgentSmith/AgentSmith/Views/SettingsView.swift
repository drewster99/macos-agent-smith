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

    var body: some View {
        TabView(selection: $shared.settingsSelectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                ScrollView {
                    generalTab()
                        .padding()
                }
            }

            Tab("Orchestration", systemImage: "point.3.connected.trianglepath.dotted", value: SettingsTab.orchestration) {
                ScrollView {
                    OrchestrationSettingsView(shared: shared)
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
                    ModelsSettingsTab(shared: shared, sessionManager: sessionManager)
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

}
