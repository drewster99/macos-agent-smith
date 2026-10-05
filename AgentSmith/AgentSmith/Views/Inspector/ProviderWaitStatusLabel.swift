import SwiftUI
import AgentSmithKit

/// "Waiting — usage limit reached · until 4:16 PM on Fri Oct 9": a caller sleeping on its provider
/// before a retry. Takes precedence over Thinking / Evaluating / Idle wherever an agent's status is
/// shown, because during the wait none of those is true.
struct ProviderWaitStatusLabel: View {
    /// The wait that resumes soonest — the one worth naming.
    let wait: ProviderWait
    /// How many of this role's callers are waiting (a pool of workers, concurrent reviews).
    let waitingCount: Int
    let font: Font

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hourglass")
            Text(label)
        }
        .font(font)
        .foregroundStyle(AppColors.providerWait)
        .lineLimit(1)
        .help(helpText)
    }

    private var label: String {
        let countPrefix = waitingCount > 1 ? "\(waitingCount) waiting" : "Waiting"
        return "\(countPrefix) — \(wait.reason.displayDescription) · until \(wait.resumeClockDescription)"
    }

    private var helpText: String {
        var lines = ["Waiting for \(wait.modelID ?? "its model") before retrying: \(wait.reason.displayDescription)."]
        lines.append("Next attempt: \(wait.resumeClockDescription) (attempt \(wait.attempt + 1)).")
        lines.append("Failing since \(wait.streakStartedAt.formatted(date: .abbreviated, time: .shortened)).")
        if waitingCount > 1 {
            lines.append("\(waitingCount) callers for this role are waiting; the soonest is shown.")
        }
        lines.append("Assigning this role a different model wakes it to retry on the new model at once.")
        return lines.joined(separator: "\n")
    }
}
