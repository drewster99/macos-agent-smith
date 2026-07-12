import AVFoundation
import SwiftUI
import SwiftLLMKit
import AgentSmithKit

private let inspectorTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SS"
    return f
}()

/// A single LLM turn entry in the per-turn inspection log.
///
/// Shows a clear Outgoing (what was sent) / Response (what came back) structure
/// with latency timing.
struct LLMTurnDisclosureRow: View, Equatable {
    let turn: LLMTurnRecord
    let turnNumber: Int
    /// Plain Bool (not a `@Binding`) so the nonisolated `==` below can read it — a `@Binding`'s
    /// wrapped value is main-actor-isolated and can't be touched from a nonisolated comparison.
    let isExpanded: Bool
    /// Toggle handler, `@MainActor` so building the DisclosureGroup's `Binding` from it is clean
    /// (its `set` wants an isolated/Sendable closure). Excluded from `==` — closures can't be
    /// compared and this one's capture (the row's turn id) is stable.
    let onExpandedChange: @MainActor (Bool) -> Void

    @State private var showingFullContext = false

    /// Compares every input that affects rendering — the full `turn` (it's `Equatable`), the
    /// number, and the expansion state — so `.equatable()` skips re-evaluating unchanged rows
    /// when a new turn is appended (the streaming hot path) without missing a real change.
    ///
    /// We must NOT shortcut to `turn.id`: `LLMTurnRecord.contextSnapshot` is stripped on older
    /// turns (`stripContextSnapshot`), so the same id can render differently (the "Full Context"
    /// row appears/vanishes). The only excluded members are `onExpandedChange` (a closure — not
    /// `Equatable`, which is the sole reason this can't be a synthesized conformance; its capture
    /// is stable per row) and `showingFullContext` (`@State`, view-internal, never an input).
    nonisolated static func == (lhs: LLMTurnDisclosureRow, rhs: LLMTurnDisclosureRow) -> Bool {
        lhs.turn == rhs.turn
        && lhs.turnNumber == rhs.turnNumber
        && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isExpanded }, set: onExpandedChange)) {
            VStack(alignment: .leading, spacing: 8) {
                // --- Outgoing ---
                if !turn.inputDelta.isEmpty {
                    turnSectionHeader("Outgoing", icon: "arrow.up.circle.fill", color: AppColors.inspectorOutgoing)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(turn.inputDelta.indices, id: \.self) { i in
                            ContextMessageRow(message: turn.inputDelta[i])
                        }
                    }
                }

                // --- Response ---
                turnSectionHeader(
                    "Response",
                    icon: "arrow.down.circle.fill",
                    color: AppColors.inspectorResponse,
                    trailing: turn.latencyMs > 0 ? formatLatency(turn.latencyMs) : nil
                )

                // Reasoning (thinking)
                if let reasoning = turn.response.reasoning, !reasoning.isEmpty {
                    Text(reasoning)
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(AppColors.inspectorReasoning)
                        .italic()
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Tool calls
                if !turn.response.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(turn.response.toolCalls.enumerated()), id: \.offset) { _, call in
                            toolCallRow(call)
                        }
                    }
                }

                // Text response
                if let text = turn.response.text, !text.isEmpty {
                    Text(text)
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, 4)
                }

                // Full context link
                if !turn.contextSnapshot.isEmpty {
                    Button(action: { showingFullContext = true }) {
                        Label("Full Context (\(turn.contextSnapshot.count) messages)", systemImage: "doc.text.magnifyingglass")
                            .font(AppFonts.inspectorBody)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.disclosureToggle)
                    .padding(.top, 2)
                }
            }
            .padding(.top, 4)
            .padding(.leading, 4)
        } label: {
            turnHeaderLabel()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(AppColors.subtleRowBackgroundDim)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .sheet(isPresented: $showingFullContext) {
            FullContextSheet(turn: turn, turnNumber: turnNumber)
        }
    }

    // MARK: - Subviews

    @ViewBuilder

    private func turnHeaderLabel() -> some View {
        HStack(spacing: 6) {
            Text("Turn \(turnNumber)")
                .font(AppFonts.inspectorBody.weight(.semibold))
                .foregroundStyle(.primary)

            if !turn.modelID.isEmpty {
                Text(turn.modelID)
                    .font(AppFonts.microMonoBadge)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(inspectorTimestampFormatter.string(from: turn.timestamp))
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)

            Spacer()

            if turn.latencyMs > 0 {
                Text(formatLatency(turn.latencyMs))
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            responseTypeBadge()
        }
    }

    private func responseTypeBadge() -> some View {
        let r = turn.response
        let label: String
        let color: Color
        if !r.toolCalls.isEmpty, let text = r.text, !text.isEmpty {
            label = "text+\(r.toolCalls.count) calls"
            color = AppColors.inspectorToolCallArg
        } else if !r.toolCalls.isEmpty {
            label = "\(r.toolCalls.count) call\(r.toolCalls.count == 1 ? "" : "s")"
            color = AppColors.inspectorToolCallArg
        } else {
            label = "text"
            color = AppColors.inspectorResponse
        }
        return Text(label)
            .font(AppFonts.microMonoBadge)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func turnSectionHeader(_ title: String, icon: String, color: Color, trailing: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(AppFonts.metaIcon)
                .foregroundStyle(color)
            Text(title)
                .font(AppFonts.inspectorLabel.weight(.semibold))
                .foregroundStyle(color)
            if let trailing {
                Spacer()
                Text(trailing)
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private func toolCallRow(_ call: LLMToolCall) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(AppFonts.metaIcon)
                    .foregroundStyle(AppColors.inspectorToolCallArg)
                Text(call.name)
                    .font(AppFonts.inspectorBody.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(call.arguments)
                .font(AppFonts.microMonoCode)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(4)
        .background(AppColors.toolCallInspectorTint)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct FullContextSheet: View {
    let turn: LLMTurnRecord
    let turnNumber: Int

    @Environment(\.dismiss) private var dismiss
    @State private var allExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Context — Turn \(turnNumber)")
                        .font(.title3.bold())
                    Text("\(turn.contextSnapshot.count) messages · \(inspectorTimestampFormatter.string(from: turn.timestamp))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(allExpanded ? "Collapse All" : "Expand All") {
                    allExpanded.toggle()
                }
                .controlSize(.small)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            // Model / config info bar
            if !turn.modelID.isEmpty {
                modelInfoBar()
                Divider()
            }

            // Legend
            HStack(spacing: 16) {
                legendItem("S", color: .secondary, label: "System prompt")
                legendItem("U", color: AppColors.inspectorOutgoing, label: "User / orchestrator input")
                legendItem("A", color: AppColors.inspectorResponse, label: "Assistant (LLM response)")
                legendItem("T", color: AppColors.inspectorToolCallArg, label: "Tool result")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(turn.contextSnapshot.indices, id: \.self) { i in
                        ContextMessageRow(
                            message: turn.contextSnapshot[i],
                            index: i + 1,
                            initiallyExpanded: allExpanded
                        )
                        .id("\(i)-\(allExpanded)")
                    }

                    // Show the LLM response at the end of the context
                    if let responseMessage = responseAsMessage {
                        Divider()
                            .padding(.vertical, 4)

                        Text("Response")
                            .font(.caption.bold())
                            .foregroundStyle(AppColors.inspectorResponse)

                        ContextMessageRow(
                            message: responseMessage,
                            index: turn.contextSnapshot.count + 1,
                            initiallyExpanded: allExpanded
                        )
                        .id("response-\(allExpanded)")
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 700, idealWidth: 900, minHeight: 500, idealHeight: 700)
    }

    /// Converts the LLM response into an LLMMessage for display in the context view.
    private var responseAsMessage: LLMMessage? {
        let response = turn.response
        guard !response.toolCalls.isEmpty || !(response.text ?? "").isEmpty else { return nil }
        return .assistant(from: response)
    }

    @ViewBuilder
    private func modelInfoBar() -> some View {
        HStack(spacing: 12) {
            Label(turn.modelID, systemImage: "cpu")
                .font(AppFonts.modelIDLabel)
            Text(turn.providerType)
                .font(.caption)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("temp \(String(format: "%.1f", turn.temperature))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("max \(turn.maxOutputTokens) tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let thinking = turn.thinkingBudget, thinking > 0 {
                Text("thinking \(thinking)")
                    .font(.caption)
                    .foregroundStyle(AppColors.inspectorReasoning)
            }
            if turn.latencyMs > 0 {
                Text(formatLatency(turn.latencyMs))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func legendItem(_ tag: String, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(AppFonts.inspectorBody.weight(.bold))
                .foregroundStyle(color)
                .frame(minWidth: 14, alignment: .center)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

