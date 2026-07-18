import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Subtitle row beneath an `AgentCard` header showing the model name (with stats popover)
/// and either context-token usage or the model's max context label.
///
/// Also warns when this assigned model has no LiteLLM metadata. That gap is otherwise invisible
/// yet consequential: the context limit shown on this very row, the pricing behind cost
/// estimates, and the `vision` flag that decides whether images reach the model at all are only
/// as good as the match. Surfacing it here means it's noticed on a model actually in use, rather
/// than only by someone who thinks to open Settings.
struct AgentCardModelInfoLine: View {
    let modelConfig: ModelConfiguration
    let llmTurns: [LLMTurnRecord]
    let role: AgentRole
    var shared: SharedAppState?

    @Environment(\.openSettings) private var openSettings

    @State private var showingModelStats = false
    @State private var showingMetadataWarning = false
    @State private var resolution: ModelMetadataService.Resolution?

    var body: some View {
        let contextLabel = Self.formatTokenCount(modelConfig.maxContextTokens)
        let lastInputTokens = llmTurns.last?.usage?.inputTokens
        let contextPercent: Int? = {
            guard modelConfig.maxContextTokens > 0, let inputTokens = lastInputTokens else { return nil }
            return min(100, (inputTokens * 100) / modelConfig.maxContextTokens)
        }()

        HStack(spacing: 6) {
            Button(action: { showingModelStats = true }, label: {
                Text(modelConfig.modelID)
                    .lineLimit(1)
                    .truncationMode(.middle)
            })
            .buttonStyle(.plain)
            .popover(isPresented: $showingModelStats, arrowEdge: .bottom) {
                ModelStatsPopover(turns: llmTurns, modelID: modelConfig.modelID, role: role)
            }
            if let resolution, resolution != .resolved {
                Button(action: { showingMetadataWarning = true }, label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                })
                .buttonStyle(.plain)
                .help("Missing LiteLLM metadata")
                .popover(isPresented: $showingMetadataWarning, arrowEdge: .bottom) {
                    metadataWarningPopover(resolution)
                }
            }
            Spacer()
            if let pct = contextPercent, let tokens = lastInputTokens {
                Text("\(Self.formatTokenCount(tokens)) / \(contextLabel) (\(pct)%)")
            } else {
                Text("\(contextLabel) ctx")
            }
        }
        .font(AppFonts.inspectorLabel)
        .foregroundStyle(.tertiary)
        .task(id: modelConfig.id) {
            guard let shared else { return }
            resolution = await shared.llmKit.liteLLMResolution(
                providerID: modelConfig.providerID,
                modelID: modelConfig.modelID
            )
        }
    }

    @ViewBuilder
    private func metadataWarningPopover(_ resolution: ModelMetadataService.Resolution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.warningTitle(for: resolution))
                .font(.headline)
            Text(Self.warningDetail(for: resolution))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Resolve\u{2026}") {
                    showingMetadataWarning = false
                    shared?.settingsSelectedTab = .metadata
                    // Deep-link: land ON the entry, not just the tab.
                    shared?.metadataFocusProviderID = modelConfig.providerID
                    shared?.metadataFocusModelID = modelConfig.modelID
                    openSettings()
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    /// Names the level that failed, so the message points at the thing that can actually be fixed.
    private static func warningTitle(for resolution: ModelMetadataService.Resolution) -> String {
        switch resolution {
        case .resolved: return ""
        case .providerNotMapped, .providerNotFound: return "Missing metadata for this provider"
        case .modelNotFound: return "Missing metadata for this model"
        }
    }

    private static func warningDetail(for resolution: ModelMetadataService.Resolution) -> String {
        switch resolution {
        case .resolved:
            return ""
        case .providerNotMapped:
            return "This provider isn't mapped to a LiteLLM provider, so no context limit, pricing, or capability flags (including vision) were loaded for its models."
        case .providerNotFound:
            return "This provider is mapped to a LiteLLM provider that doesn't exist in LiteLLM's data, so no metadata was loaded."
        case .modelNotFound:
            return "LiteLLM has no entry for this model under this provider — it may be too new, or the provider mapping may be wrong. Its context limit, pricing, and capability flags fall back to whatever the provider's API reported."
        }
    }

    /// Formats a token count as a compact label (e.g. 128000 → "128K", 1048576 → "1.0M").
    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000.0
            let formatted = String(format: "%.1f", value)
            let label = formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
            return "\(label)M"
        } else if count >= 1_000 {
            return "\(count / 1_000)K"
        }
        return "\(count)"
    }
}
