import SwiftUI
import SwiftLLMKit

/// The provenance inspector: every value the merged catalog holds for a model, WHERE it came
/// from (which of the five layers won), what the other layers claimed, and the raw probe
/// evidence — plus manual probing (single or multi-select). This window exists so "why does the
/// app believe X about this model" is answerable in one click instead of archaeology.
struct ModelMetadataInspectorWindow: View {
    let shared: SharedAppState

    @State private var selectedProviderID: String = ""
    @State private var selectedModelIDs: Set<String> = []
    @State private var searchText: String = ""
    @State private var probeRunner = ModelProbeRunner()

    private var kit: LLMKitManager { shared.llmKit }

    private var selectedProvider: ModelProvider? {
        kit.providers.first { $0.id == selectedProviderID }
    }

    var body: some View {
        HSplitView {
            modelListColumn
                .frame(minWidth: 300, idealWidth: 340)
            detailColumn
                .frame(minWidth: 420)
        }
        .onAppear {
            if selectedProviderID.isEmpty {
                selectedProviderID = kit.providers.first?.id ?? ""
            }
        }
        .onChange(of: selectedProviderID) {
            // Selections are bare model IDs; carrying them across a provider switch would let
            // "Probe Selected" spend calls asking the NEW provider for the OLD provider's models.
            DispatchQueue.main.async {
                selectedModelIDs.removeAll()
            }
        }
    }

    // MARK: - Left: provider + model list + probe controls

    private var modelListColumn: some View {
        VStack(spacing: 0) {
            Picker("Provider", selection: $selectedProviderID) {
                ForEach(kit.providers, id: \.id) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .padding(10)

            TextField("Filter models", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)

            let providerModels = kit.models
                .filter { $0.providerID == selectedProviderID }
                .filter { searchText.isEmpty || $0.modelID.localizedCaseInsensitiveContains(searchText) }
                .sorted { $0.modelID < $1.modelID }

            List(selection: $selectedModelIDs) {
                ForEach(providerModels, id: \.modelID) { model in
                    modelRow(model)
                        .tag(model.modelID)
                }
            }

            probeControls
        }
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName).lineLimit(1)
                if model.displayName != model.modelID {
                    Text(model.modelID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let provider = selectedProvider,
               kit.probeRecords(provider: provider, modelID: model.modelID).local != nil {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(.green)
                    .help("Probed — local evidence on record")
            }
            if model.isDeprecated {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .help("Provider marked this model deprecated")
            }
            if let state = probeRunner.states["\(selectedProviderID)/\(model.modelID)"] {
                probeStateBadge(state)
            }
        }
    }

    @ViewBuilder
    private func probeStateBadge(_ state: ModelProbeRunner.TargetState) -> some View {
        switch state {
        case .pending: Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .probing: ProgressView().controlSize(.small)
        case .stored: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(.red)
        }
    }

    private var probeControls: some View {
        HStack {
            Button {
                startProbe(modelIDs: Array(selectedModelIDs))
            } label: {
                Label("Probe Selected (\(selectedModelIDs.count))", systemImage: "bolt.badge.checkmark")
            }
            .disabled(selectedModelIDs.isEmpty || probeRunner.isRunning || selectedProvider == nil)

            if probeRunner.isRunning {
                ProgressView().controlSize(.small)
                Text("Probing…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
    }

    private func startProbe(modelIDs: [String]) {
        guard let provider = selectedProvider else { return }
        // Belt to the onChange suspenders: only IDs the selected provider actually catalogs can
        // be probed, so a stale selection can never spend calls against the wrong endpoint.
        let known = Set(kit.models.filter { $0.providerID == provider.id }.map(\.modelID))
        let targets = modelIDs.filter(known.contains).sorted().map { (provider: provider, modelID: $0) }
        guard !targets.isEmpty else { return }
        Task {
            await probeRunner.probe(targets: targets, kit: kit)
        }
    }

    // MARK: - Right: composition detail

    @ViewBuilder
    private var detailColumn: some View {
        if selectedModelIDs.count == 1, let modelID = selectedModelIDs.first {
            ModelCompositionDetailView(
                shared: shared,
                providerID: selectedProviderID,
                modelID: modelID,
                onProbe: { startProbe(modelIDs: [modelID]) },
                isProbing: probeRunner.isRunning
            )
        } else {
            ContentUnavailableView(
                selectedModelIDs.isEmpty ? "Select a Model" : "\(selectedModelIDs.count) Models Selected",
                systemImage: "square.stack.3d.up",
                description: Text(selectedModelIDs.isEmpty
                    ? "Pick a model to inspect where each of its values came from."
                    : "Composition detail shows for a single selection. Probe Selected works on all of them.")
            )
        }
    }
}

/// The per-model composition: merged value, winning layer, dissenting layers, and probe evidence.
struct ModelCompositionDetailView: View {
    let shared: SharedAppState
    let providerID: String
    let modelID: String
    let onProbe: () -> Void
    let isProbing: Bool

    private var kit: LLMKitManager { shared.llmKit }
    private var compositionKey: String { "\(providerID)/\(modelID)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                probeEvidenceSection
                if let composition = kit.metadataCompositions[compositionKey] {
                    disagreementsSection(composition)
                    fieldsSection(composition)
                } else {
                    ContentUnavailableView(
                        "Composition Not Computed",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Refresh this provider's models to compute the layered merge for this model.")
                    )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(modelID).font(.title3.bold()).textSelection(.enabled)
            Text(providerID).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Probe evidence (record-only facts live here, not in the merge)

    @ViewBuilder
    private var probeEvidenceSection: some View {
        let provider = kit.providers.first { $0.id == providerID }
        let records = provider.map { kit.probeRecords(provider: $0, modelID: modelID) }

        GroupBox("Probe Evidence") {
            VStack(alignment: .leading, spacing: 6) {
                if let local = records?.local {
                    probeRecordSummary(local, label: "Local")
                }
                if let downloaded = records?.downloaded {
                    probeRecordSummary(downloaded, label: "Downloaded")
                }
                if records?.local == nil && records?.downloaded == nil {
                    HStack {
                        Label("No probe information for this model", systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Probe Now", action: onProbe)
                            .disabled(isProbing || provider == nil)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Re-probe", action: onProbe)
                            .disabled(isProbing || provider == nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func probeRecordSummary(_ record: ProbeRecord, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption.bold())
                Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Text("prober v\(record.proberVersion)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            // The record-only findings (never merged) plus the run stats — the evidence the
            // merge deliberately keeps out of the catalog but the user deserves to see.
            probeFindingLine("Available", record.profile.isAvailable)
            probeFindingLine("Access denied", record.profile.isAccessDenied)
            probeFindingLine("Tool round-trip", record.profile.toolResultRoundTrip)
            probeFindingLine("Chat", record.profile.chat)
            probeFindingLine("Tool calling", record.profile.toolCalling)
            probeFindingLine("Vision", record.profile.vision)
            probeFindingLine("PDF input", record.profile.pdfInput)
            probeFindingLine("Accepts temperature", record.profile.acceptsTemperature)
            if record.profile.callCount > 0 {
                Text("\(record.profile.callCount) calls, \(String(format: "%.1fs", record.profile.duration))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func probeFindingLine(_ label: String, _ finding: ProbeFinding<Bool>) -> some View {
        if finding.status != .notAttempted {
            HStack(spacing: 6) {
                Text(label).font(.caption)
                switch finding.status {
                case .established:
                    Text(finding.value == true ? "yes" : "no")
                        .font(.caption.bold())
                        .foregroundStyle(finding.value == true ? .green : .red)
                case .inconclusive:
                    Text("inconclusive").font(.caption).foregroundStyle(.orange)
                case .notAttempted:
                    EmptyView()
                }
                if finding.source == .decoded {
                    Text("(decoded)").font(.caption2).foregroundStyle(.secondary)
                }
                if let evidence = finding.evidence {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(evidence)
                }
                Spacer()
            }
        }
    }

    // MARK: Disagreements

    @ViewBuilder
    private func disagreementsSection(_ composition: MergedModelComposition) -> some View {
        if !composition.disagreements.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(composition.disagreements.enumerated()), id: \.offset) { _, disagreement in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(disagreement.field).font(.caption.bold())
                            Text("\(disagreement.winningLayer.displayName): \(disagreement.winningValue)")
                                .font(.caption)
                            Text("vs \(disagreement.dissentingLayer.displayName): \(disagreement.dissentingValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                .padding(4)
            } label: {
                Label("Disagreements", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Fields

    private func fieldsSection(_ composition: MergedModelComposition) -> some View {
        GroupBox("Fields by Source") {
            VStack(alignment: .leading, spacing: 3) {
                let orderedLayers: [MetadataLayer] = [.authoritative, .empirical, .downloadedOverrides, .enrichment, .userOverrides]
                ForEach(ModelFactsFieldTable.fields, id: \.name) { field in
                    if let winner = composition.provenance[field.name],
                       let value = field.describe(composition.merged) {
                        let hasDisagreement = composition.disagreements.contains { $0.field == field.name }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(field.name)
                                .font(.caption)
                                .frame(width: 230, alignment: .leading)
                            Text(value)
                                .font(.caption.bold())
                                .lineLimit(1)
                                .help(value)
                            layerBadge(winner)
                            if hasDisagreement {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            Spacer()
                            // The other layers' statements, dimmed — the full picture per field.
                            ForEach(orderedLayers.filter { $0 != winner }, id: \.self) { layer in
                                if let layerFacts = composition.layers[layer],
                                   field.isSet(layerFacts),
                                   let layerValue = field.describe(layerFacts) {
                                    Text("\(layer.shortName): \(layerValue)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private func layerBadge(_ layer: MetadataLayer) -> some View {
        Text(layer.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(layer.badgeColor.opacity(0.18), in: Capsule())
            .foregroundStyle(layer.badgeColor)
    }
}

extension MetadataLayer {
    /// Human-readable layer name for badges.
    var displayName: String {
        switch self {
        case .authoritative: return "Provider"
        case .empirical: return "Probed"
        case .downloadedOverrides: return "Curated"
        case .enrichment: return "LiteLLM"
        case .userOverrides: return "You"
        }
    }

    var shortName: String {
        switch self {
        case .authoritative: return "prov"
        case .empirical: return "probe"
        case .downloadedOverrides: return "cur"
        case .enrichment: return "llm"
        case .userOverrides: return "you"
        }
    }

    var badgeColor: Color {
        switch self {
        case .authoritative: return .blue
        case .empirical: return .green
        case .downloadedOverrides: return .purple
        case .enrichment: return .gray
        case .userOverrides: return .orange
        }
    }
}
