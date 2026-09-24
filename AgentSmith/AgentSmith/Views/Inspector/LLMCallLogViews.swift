import SwiftUI
import AgentSmithKit

private let callTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SS"
    return formatter
}()

/// Heading wording for an `InspectorCallLog`. Never presents a truncated log as complete: once
/// anything has been evicted the heading says how many of how many are shown.
enum LLMCallLogHeading {
    static func title(for log: InspectorCallLog) -> String {
        let failed = log.lifetimeFailureCount
        let failureSuffix = failed > 0 ? " · \(failed) failed" : ""
        if log.evictedCount > 0 {
            return "LLM Turns — latest \(log.entries.count) of \(log.lifetimeCount)\(failureSuffix)"
        }
        return "LLM Turns (\(log.lifetimeCount)\(failureSuffix))"
    }
}

extension LLMCallAnnotation.Operation {
    /// Short label naming what issued the call.
    var displayLabel: String {
        switch self {
        case .securityToolReview(let toolName): return "Review \(toolName)"
        case .securityToolScoping: return "Tool scoping"
        case .taskSummary: return "Task summary"
        case .memoryReconciliation: return "Memory consolidation"
        case .webContentExtraction: return "Web extraction"
        }
    }
}

extension LLMCallFailureRecord.Disposition {
    var displayLabel: String {
        switch self {
        case .transient: return "transient"
        case .permanent: return "permanent"
        case .cancelled: return "cancelled"
        }
    }
}

/// The inspector's LLM-call list: honest retention heading plus one row per retained call,
/// numbered by lifetime ordinal.
struct LLMCallLogSection: View {
    let log: InspectorCallLog
    @Binding var expandedCallIDs: Set<UUID>
    /// Expands each newly arriving call. Off where a high-frequency subject (Security reviews)
    /// would make the list churn open.
    let expandsNewestCall: Bool

    var body: some View {
        InspectorSection(title: LLMCallLogHeading.title(for: log)) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(log.entries, id: \.id) { entry in
                    LLMCallLogEntryRow(
                        entry: entry,
                        snapshotWindow: log.snapshotWindow,
                        isExpanded: expandedCallIDs.contains(entry.id),
                        onExpandedChange: { expand in
                            if expand { expandedCallIDs.insert(entry.id) }
                            else { expandedCallIDs.remove(entry.id) }
                        }
                    )
                }
            }
        }
        .onAppear { expandNewestIfWanted() }
        .onChange(of: log.lifetimeCount) { expandNewestIfWanted() }
    }

    private func expandNewestIfWanted() {
        guard expandsNewestCall, let newest = log.entries.last?.id else { return }
        // Project rule: defer @State / @Binding mutations out of SwiftUI lifecycle closures.
        DispatchQueue.main.async { expandedCallIDs.insert(newest) }
    }
}

/// One retained call: a completed turn or a failed attempt.
struct LLMCallLogEntryRow: View {
    let entry: InspectorCallLog.Entry
    let snapshotWindow: Int
    let isExpanded: Bool
    let onExpandedChange: @MainActor (Bool) -> Void

    var body: some View {
        switch entry {
        case .completed(let ordinal, let turn, let snapshot):
            LLMTurnDisclosureRow(
                turn: turn,
                turnNumber: ordinal,
                snapshotRetention: snapshot,
                snapshotWindow: snapshotWindow,
                isExpanded: isExpanded,
                onExpandedChange: onExpandedChange
            )
            .equatable()
        case .failed(let ordinal, let failure):
            LLMCallFailureRow(failure: failure, callNumber: ordinal)
        }
    }
}

/// A provider call that ended without a response. Rendered as a failure, never as an empty turn.
struct LLMCallFailureRow: View {
    let failure: LLMCallFailureRecord
    let callNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LLMCallFailureHeader(failure: failure, callNumber: callNumber)
            if let annotation = failure.annotation {
                LLMCallAnnotationLine(annotation: annotation)
            }
            Text(failure.errorDescription)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(AppColors.inspectorCallFailedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Turn \(callNumber) failed without a response: \(failure.errorDescription)")
    }
}

private struct LLMCallFailureHeader: View {
    let failure: LLMCallFailureRecord
    let callNumber: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.octagon.fill")
                .font(AppFonts.metaIcon)
                .foregroundStyle(AppColors.inspectorCallFailed)
            Text("Turn \(callNumber) · failed")
                .font(AppFonts.inspectorBody.weight(.semibold))
                .foregroundStyle(AppColors.inspectorCallFailed)
            if !failure.modelID.isEmpty {
                Text(failure.modelID)
                    .font(AppFonts.microMonoBadge)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            LLMCallFailureTiming(failure: failure)
        }
    }
}

/// When the failed call happened, how long it ran, and how it bears on retrying.
private struct LLMCallFailureTiming: View {
    let failure: LLMCallFailureRecord

    var body: some View {
        HStack(spacing: 6) {
            Text(callTimestampFormatter.string(from: failure.timestamp))
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)
            Text(formatLatency(failure.latencyMs))
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Text(failure.disposition.displayLabel)
                .font(AppFonts.microMonoBadge)
                .foregroundStyle(AppColors.inspectorCallFailed)
        }
    }
}

/// Operation badge, attempt, and task association for an annotated call.
struct LLMCallAnnotationLine: View {
    let annotation: LLMCallAnnotation

    var body: some View {
        HStack(spacing: 6) {
            LLMCallOperationBadge(operation: annotation.operation)
            if let attempt = annotation.attempt, attempt > 1 {
                Text("attempt \(attempt)")
                    .font(AppFonts.microMonoBadge)
                    .foregroundStyle(.secondary)
            }
            if let title = annotation.taskTitle {
                Text(title)
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The typed operation that issued a call, as a compact badge.
struct LLMCallOperationBadge: View {
    let operation: LLMCallAnnotation.Operation

    var body: some View {
        Text(operation.displayLabel)
            .font(AppFonts.microMonoBadge)
            .foregroundStyle(AppColors.inspectorOperationBadge)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(AppColors.inspectorOperationBadge.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// States that a turn's full request is absent, and why.
struct LLMTurnSnapshotNotice: View {
    let retention: InspectorCallLog.SnapshotRetention
    let snapshotWindow: Int

    var body: some View {
        Label(message, systemImage: "doc.badge.ellipsis")
            .font(AppFonts.inspectorBody)
            .foregroundStyle(AppColors.inspectorRetentionNotice)
    }

    private var message: String {
        switch retention {
        case .retained:
            return ""
        case .discardedByRetention:
            return "Full context released — only the latest \(snapshotWindow) turns keep it"
        case .notCaptured:
            return "Full request was not captured for this call"
        }
    }
}
