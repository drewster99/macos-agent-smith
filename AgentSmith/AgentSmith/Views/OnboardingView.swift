import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// First-run setup: explains the app, takes a single provider + API key, validates it by
/// fetching the provider's models, then shows a tested per-role model profile the user can
/// confirm or adjust. On confirm it creates one configuration per role, assigns them, marks
/// onboarding complete, and starts the runtime. A "configure everything manually" path skips
/// straight to Settings for users who'd rather set things up by hand.
struct OnboardingView: View {
    @Bindable var viewModel: AppViewModel
    @Bindable var shared: SharedAppState
    /// Called once configs are created and assigned — the parent dismisses and starts the runtime.
    let onComplete: () -> Void
    /// Called when the user opts to configure manually — the parent dismisses and opens Settings.
    let onManualSetup: () -> Void

    private enum Step {
        case intro
        case provider
        case review
    }

    @State private var step: Step = .intro

    // Intro
    @State private var nameInput = ""

    // Provider
    @State private var selectedProviderID: String = ProviderProfile.anthropic.providerID
    @State private var apiKey = ""
    @State private var isValidating = false
    @State private var validationError: String?

    // Review
    @State private var fetchedModels: [ModelInfo] = []
    @State private var roleSelections: [OnboardingRole: String] = [:]

    private var selectedProfile: ProviderProfile {
        ProviderProfile.profile(forProviderID: selectedProviderID) ?? .anthropic
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .intro: introScreen()
            case .provider: providerScreen()
            case .review: reviewScreen()
            }
        }
        .frame(width: 750, height: 740)
    }

    // MARK: - Intro

    private func introScreen() -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 4)
            Image(systemName: "person.3.sequence.fill")
                .font(AppFonts.welcomeIcon)
                .foregroundStyle(.blue)
            Text("Welcome to Agent Smith")
                .font(.largeTitle.bold())
            VStack(spacing: 12) {
                Text("Agent Smith runs a small team of AI agents that work together on the tasks you give it.")
                Text("**Smith** plans the work and talks to you. **Brown** does the work — running commands, editing files, using tools. A **Security Agent** reviews each action before it runs, a **Validator** checks the finished result against your acceptance criteria, and a **Summarizer** records the outcome.")
                Text("You hand over the tasks; the team carries them out. Let's get you set up.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)

            VStack(spacing: 16) {
                Text("What should I call you?")
                    .font(.headline)
                TextField("Your name or nickname", text: $nameInput)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(AppFonts.onboardingNameField)
                    .frame(maxWidth: 320)
                    .onSubmit { continueFromIntro() }
            }
            .padding(.top, 10)

            Spacer(minLength: 4)
            Button("Continue") { continueFromIntro() }
                .keyboardShortcut(.defaultAction)
                .disabled(nameInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(32)
    }

    private func continueFromIntro() {
        // The nickname is intentionally NOT persisted here. The onboarding gate migrates a
        // pre-onboarding install by treating a non-empty nickname as "already onboarded"; if we
        // persisted it now, quitting mid-flow (before completing or skipping) would make the next
        // launch skip onboarding forever. `commitNickname()` runs only at the completion points.
        guard !nameInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        step = .provider
    }

    /// Persists the nickname the user typed on the intro screen. Called only once onboarding is
    /// actually finished — either confirmed or skipped via manual setup — so a partially-completed
    /// run leaves no nickname and the gate still shows onboarding next launch.
    private func commitNickname() {
        let trimmed = nameInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        shared.nickname = trimmed
        shared.persistNickname()
    }

    // MARK: - Provider

    private func providerScreen() -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(
                title: "Connect a provider",
                subtitle: "Pick an AI provider and paste one API key. You can change this — or add more providers — later in Settings."
            )

            Picker("Provider", selection: $selectedProviderID) {
                ForEach(ProviderProfile.all) { profile in
                    Text(profile.displayName).tag(profile.providerID)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isValidating)
            .onChange(of: selectedProviderID) { _, _ in
                DispatchQueue.main.async {
                    apiKey = ""
                    validationError = nil
                }
            }

            if selectedProfile.requiresAPIKey {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { validateAndContinue() }
                    if let url = selectedProfile.keyConsoleURL {
                        Link("Get an API key from \(selectedProfile.displayName) →", destination: url)
                            .font(.caption)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ollama runs locally, so there's no API key. Make sure the Ollama app is running and you've pulled at least one model.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = selectedProfile.keyConsoleURL {
                        Link("Browse Ollama models →", destination: url)
                            .font(.caption)
                    }
                }
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Configure everything manually") { chooseManualSetup() }
                    .disabled(isValidating)
                Spacer()
                Button("Back") { step = .intro }
                    .disabled(isValidating)
                Button(action: { validateAndContinue() }, label: {
                    if isValidating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Validate & Continue")
                    }
                })
                .keyboardShortcut(.defaultAction)
                .disabled(isValidating || (selectedProfile.requiresAPIKey && apiKey.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(28)
    }

    private func validateAndContinue() {
        guard !isValidating else { return }
        let profile = selectedProfile
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !profile.requiresAPIKey || !key.isEmpty else { return }

        validationError = nil
        isValidating = true
        Task {
            do {
                try shared.llmKit.setBuiltInProviderAPIKey(id: profile.providerID, apiKey: key)
            } catch {
                isValidating = false
                validationError = "Couldn't save the API key: \(error.localizedDescription)"
                return
            }
            await shared.llmKit.refreshModels(forProviderID: profile.providerID)
            let models = shared.llmKit.models(for: profile.providerID)
            isValidating = false
            // Belt-and-suspenders: the picker is disabled while validating, but if the selection
            // changed out from under this in-flight request, don't advance with stale results.
            guard profile.providerID == selectedProviderID else { return }
            guard !models.isEmpty else {
                validationError = profile.requiresAPIKey
                    ? "No models came back — double-check the API key and try again."
                    : "No local models found. Make sure Ollama is running and you've pulled at least one model."
                return
            }
            fetchedModels = models.sorted {
                $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending
            }
            initializeRoleSelections(from: profile, catalog: fetchedModels)
            step = .review
        }
    }

    // MARK: - Review

    private func reviewScreen() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(
                title: "Review your models",
                subtitle: "These are the recommended \(selectedProfile.displayName) models for each role. Green is ready to go; red needs a pick. Adjust any of them with the dropdown."
            )

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(OnboardingRole.allCases) { role in
                        roleRow(role)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 560)

            HStack {
                Button("Back") { step = .provider }
                Spacer()
                Button("Confirm & Start") { confirmAndFinish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allRolesResolved)
            }
        }
        .padding(24)
    }

    private func roleRow(_ role: OnboardingRole) -> some View {
        let selectedID = roleSelections[role]
        let resolved = selectedID.map { id in fetchedModels.contains { $0.modelID == id } } ?? false
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(role.accentColor)
                        .frame(width: 8, height: 8)
                    Text(role.title)
                        .font(.headline)
                    Spacer()
                    if resolved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Text(role.considerations)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                modelMenu(for: role, resolved: resolved)
                    .padding(.top, 8)
                if !resolved, let wanted = selectedProfile.recommendedModels[role] {
                    Text("Recommended model \"\(wanted)\" isn't in this account's catalog — pick one above.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
    }

    private func modelMenu(for role: OnboardingRole, resolved: Bool) -> some View {
        Menu(content: {
            ForEach(fetchedModels) { model in
                Button(modelLabel(model)) { roleSelections[role] = model.modelID }
            }
        }, label: {
            HStack {
                Text(currentSelectionLabel(for: role))
                    .foregroundStyle(resolved ? Color.primary : Color.red)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        })
        .menuStyle(.borderlessButton)
    }

    private func modelLabel(_ model: ModelInfo) -> String {
        model.displayName.isEmpty ? model.modelID : "\(model.displayName)  ·  \(model.modelID)"
    }

    private func currentSelectionLabel(for role: OnboardingRole) -> String {
        guard let id = roleSelections[role] else { return "Select a model" }
        if let model = fetchedModels.first(where: { $0.modelID == id }) {
            return modelLabel(model)
        }
        return id
    }

    private var allRolesResolved: Bool {
        OnboardingRole.allCases.allSatisfy { role in
            guard let id = roleSelections[role] else { return false }
            return fetchedModels.contains { $0.modelID == id }
        }
    }

    private func initializeRoleSelections(from profile: ProviderProfile, catalog: [ModelInfo]) {
        var selections: [OnboardingRole: String] = [:]
        for role in OnboardingRole.allCases {
            if let wanted = profile.recommendedModels[role],
               let resolved = ProviderProfile.resolveModelID(wanted, in: catalog) {
                selections[role] = resolved
            }
        }
        roleSelections = selections
    }

    private func confirmAndFinish() {
        guard allRolesResolved else { return }
        let profile = selectedProfile
        var newAssignments: [AgentRole: UUID] = [:]
        var validatorConfigID: UUID?

        for role in OnboardingRole.allCases {
            guard let modelID = roleSelections[role] else { continue }
            let config = ModelConfiguration(
                id: UUID(),
                name: "\(role.configNamePrefix) — \(profile.displayName)",
                providerID: profile.providerID,
                modelID: modelID,
                temperature: nil,
                maxOutputTokens: role.maxOutputTokens,
                maxContextTokens: role.maxContextTokens
            )
            shared.llmKit.addConfiguration(config)
            if let agentRole = role.agentRole {
                newAssignments[agentRole] = config.id
            } else {
                validatorConfigID = config.id
            }
        }

        commitNickname()
        viewModel.agentAssignments = newAssignments
        viewModel.validatorAssignment = validatorConfigID
        shared.markOnboardingComplete()
        onComplete()
    }

    // MARK: - Manual setup

    private func chooseManualSetup() {
        commitNickname()
        shared.markOnboardingComplete()
        onManualSetup()
    }

    // MARK: - Shared

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
