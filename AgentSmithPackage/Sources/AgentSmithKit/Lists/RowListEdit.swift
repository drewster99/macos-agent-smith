import Foundation

/// How to turn a table showing one list of rows into one showing the next, without reloading it.
///
/// Long lists in this app change almost only at their ends: rows append at the bottom, and a
/// capped list trims from the top. A row whose content changed but whose identity didn't (a tool
/// call whose output arrived) is redrawn in place. Anything else — a filter change, a row appearing
/// in the middle — is a full reload.
public enum RowListEdit: Equatable, Sendable {
    case none
    /// Remove the first `removedFromFront` rows, then append `appended` rows, then redraw the rows at
    /// `reloaded` — indexes into the NEW rows.
    case incremental(removedFromFront: Int, appended: Int, reloaded: IndexSet)
    case reload

    /// - Parameters:
    ///   - old: what the table shows now, one render key per row.
    ///   - new: what it should show.
    ///   - identity: a row's identity. Equal render keys must have equal identities; equal
    ///     identities with different render keys are the same row, redrawn.
    public static func plan<Key: Equatable, Identity: Equatable>(
        from old: [Key], to new: [Key], identity: (Key) -> Identity
    ) -> RowListEdit {
        if old == new { return .none }
        guard let firstNew = new.first, !old.isEmpty else { return .reload }
        let firstNewIdentity = identity(firstNew)
        guard let removedFromFront = old.firstIndex(where: { identity($0) == firstNewIdentity }) else {
            return .reload
        }
        let overlap = old.count - removedFromFront
        guard overlap <= new.count else { return .reload }
        var reloaded = IndexSet()
        for offset in 0..<overlap {
            let before = old[removedFromFront + offset]
            let after = new[offset]
            guard identity(before) == identity(after) else { return .reload }
            if before != after { reloaded.insert(offset) }
        }
        return .incremental(removedFromFront: removedFromFront, appended: new.count - overlap, reloaded: reloaded)
    }
}
