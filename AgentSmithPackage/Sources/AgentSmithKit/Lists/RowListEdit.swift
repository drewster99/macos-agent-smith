import Foundation

/// How to turn a table showing one list of rows into one showing the next, without reloading it.
///
/// Long lists in this app change almost only at their ends: rows append at the bottom, a capped
/// list trims from the top, and a newest-first list (the Memory Browser) gains rows at the top. A
/// row whose content changed but whose identity didn't (a tool call whose output arrived) is redrawn
/// in place. Anything else — a filter change, a re-ranking, a row appearing or vanishing in the
/// middle — is a full reload.
public enum RowListEdit: Equatable, Sendable {
    case none
    /// Remove the first `removedFromFront` rows, insert `insertedAtFront` rows before what is left,
    /// append `appended` rows, then redraw the rows at `reloaded` — indexes into the NEW rows.
    ///
    /// A plan never both removes and inserts at the front (that is a replacement, which reloads),
    /// and never appends a row it removed (a moved row, which reloads).
    case incremental(removedFromFront: Int, insertedAtFront: Int = 0, appended: Int, reloaded: IndexSet)
    case reload

    /// - Parameters:
    ///   - old: what the table shows now, one render key per row.
    ///   - new: what it should show.
    ///   - identity: a row's identity. Equal render keys must have equal identities; equal
    ///     identities with different render keys are the same row, redrawn.
    public static func plan<Key: Equatable, Identity: Hashable>(
        from old: [Key], to new: [Key], identity: (Key) -> Identity
    ) -> RowListEdit {
        if old == new { return .none }
        guard let firstNew = new.first, let firstOld = old.first else { return .reload }
        let firstNewIdentity = identity(firstNew)
        if let removedFromFront = old.firstIndex(where: { identity($0) == firstNewIdentity }) {
            return keeping(old, from: removedFromFront, in: new, at: 0, identity: identity)
        }
        // The new first row was never shown: rows arrived at the front, if the old first row is
        // still here further down.
        let firstOldIdentity = identity(firstOld)
        guard let insertedAtFront = new.firstIndex(where: { identity($0) == firstOldIdentity }) else {
            return .reload
        }
        return keeping(old, from: 0, in: new, at: insertedAtFront, identity: identity)
    }

    /// The edit that turns `old[oldStart...]` into `new[newStart..<newStart + kept]`, with every
    /// other new row inserted before or appended after them — or a reload when those are not the
    /// same rows in the same order.
    private static func keeping<Key: Equatable, Identity: Hashable>(
        _ old: [Key], from oldStart: Int, in new: [Key], at newStart: Int, identity: (Key) -> Identity
    ) -> RowListEdit {
        let kept = old.count - oldStart
        guard newStart + kept <= new.count else { return .reload }
        var reloaded = IndexSet()
        for offset in 0..<kept {
            let before = old[oldStart + offset]
            let after = new[newStart + offset]
            guard identity(before) == identity(after) else { return .reload }
            if before != after { reloaded.insert(newStart + offset) }
        }
        let appendedStart = newStart + kept
        // A row trimmed from the front and appended again is a move. The table keeps one view
        // per identity; removing the row would discard the view the appended row is showing.
        if oldStart > 0, appendedStart < new.count {
            let removedIdentities = Set(old[..<oldStart].map(identity))
            if new[appendedStart...].contains(where: { removedIdentities.contains(identity($0)) }) {
                return .reload
            }
        }
        return .incremental(removedFromFront: oldStart, insertedAtFront: newStart,
                            appended: new.count - appendedStart, reloaded: reloaded)
    }
}
