import SwiftUI
import AgentSmithKit

/// Heading wording for a Security evaluation list. Says "newest N of M" whenever fewer than
/// every evaluation this run are listed, so a short list is never read as the whole history.
enum SecurityEvaluationsHeading {
    static func title(shown: Int, lifetime: Int) -> String {
        if shown >= lifetime {
            return "Security Evaluations (\(lifetime))"
        }
        return "Security Evaluations — newest \(shown) of \(lifetime)"
    }
}

/// Security evaluations, newest first. The sidebar shows the newest few compactly; the inspector
/// window shows every retained record with its full stored prompt and response.
struct SecurityEvaluationsSection: View {
    /// Retained records, oldest first (the store's order).
    let records: [EvaluationRecord]
    let lifetimeCount: Int
    /// Maximum rows shown; nil shows every retained record.
    let limit: Int?
    let detail: EvaluationRecordDetail

    var body: some View {
        let shown = Array(records.suffix(limit ?? records.count).reversed())
        InspectorSection(title: SecurityEvaluationsHeading.title(shown: shown.count, lifetime: lifetimeCount)) {
            ForEach(shown) { record in
                EvaluationRecordRow(record: record, detail: detail)
            }
        }
    }
}
