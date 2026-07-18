import Foundation

/// The graded success measure for a task, DERIVED from the validation ledger — never
/// stored, so it can never drift from the verdicts it summarizes (single source of truth).
///
/// Distinct from `AgentTask.Status`: the coarse lifecycle status only says the machine
/// finished judging (`.completed`) or gave up (`.failed`). This says HOW WELL it went —
/// the answer a "Completed" chip hides when, say, every criterion was actually waived or
/// a task limped to a stall. Only terminal / escalated tasks have an outcome; everything
/// else (`running`, `validating`, `pending`, …) stays represented by the lifecycle status.
public enum TaskOutcome: Sendable, Equatable {
    /// Every acceptance criterion was accepted outright — no waivers.
    case success(total: Int)
    /// Completed, but one or more criteria were WAIVED rather than accepted — met, with carve-outs.
    case pass(accepted: Int, waived: Int, total: Int)
    /// Validation gave up: rejections stopped making progress and the task `.failed`.
    case incomplete(accepted: Int, total: Int)
    /// A validator errored and the task escalated — the machine couldn't judge it.
    case needsReview(accepted: Int, total: Int)
}

public extension TaskOutcome {
    /// Short chip label ("Success" / "Pass" / "Incomplete" / "Review").
    var label: String {
        switch self {
        case .success: return "Success"
        case .pass: return "Pass"
        case .incomplete: return "Incomplete"
        case .needsReview: return "Review"
        }
    }

    /// "6/8"-style accepted-of-total fraction for the chip. `nil` for `.success` — an
    /// unqualified win needs no fraction.
    var fraction: String? {
        switch self {
        case .success:
            return nil
        case .pass(let accepted, _, let total),
             .incomplete(let accepted, let total),
             .needsReview(let accepted, let total):
            return "\(accepted)/\(total)"
        }
    }

    /// Longer one-line explanation for the detail screen's Result row.
    var detailText: String {
        switch self {
        case .success(let total):
            return "all \(total) criteria accepted"
        case .pass(let accepted, let waived, _):
            return "\(accepted) accepted · \(waived) waived"
        case .incomplete(let accepted, let total):
            return "\(accepted) of \(total) accepted — progress stalled"
        case .needsReview:
            return "validator error — needs your review"
        }
    }
}

public extension AgentTask {
    /// The task's graded success measure, or `nil` when there's nothing to grade — no
    /// acceptance contract, no validation ledger, or a status that isn't a judged endpoint
    /// (running / validating / pending / scheduled …). Callers fall back to the lifecycle
    /// status chip when this is `nil`.
    var outcome: TaskOutcome? {
        guard let validation, !acceptanceCriteria.isEmpty else { return nil }

        var accepted = 0
        var waived = 0
        var judged = 0
        for criterion in acceptanceCriteria {
            switch validation.latestVerdict(for: criterion.id)?.verdict {
            case .accepted: accepted += 1; judged += 1
            case .waived: waived += 1; judged += 1
            case .rejected, .error: judged += 1
            case .none: break
            }
        }
        let total = acceptanceCriteria.count

        switch status {
        case .completed:
            if accepted == total {
                return .success(total: total)
            }
            // A `.completed` task should have every criterion settled (accepted or waived).
            // If the ledger is inconsistent — a rejected/errored/unjudged criterion under a
            // completed status (legacy or partial data) — don't invent a passing grade; fall
            // back to the lifecycle status chip.
            if accepted + waived == total {
                return .pass(accepted: accepted, waived: waived, total: total)
            }
            return nil
        case .failed:
            // A task that reached `.failed` before any criterion was judged didn't stall on
            // its criteria — there's nothing to grade. Fall back to the "Failed" status chip
            // rather than a misleading "Incomplete 0/N — progress stalled".
            if judged == 0 {
                return nil
            }
            return .incomplete(accepted: accepted, total: total)
        case .awaitingReview:
            return .needsReview(accepted: accepted, total: total)
        default:
            return nil
        }
    }
}
