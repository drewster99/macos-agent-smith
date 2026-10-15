import Foundation
import Testing
@testable import AgentSmithKit

/// The edit planner every `HostedRowsTable` runs on each update. An incremental edit keeps the
/// row views on screen — and whatever is typed or focused in them — where a reload re-parents
/// every one. These pin which list changes stay incremental, and that everything else reloads
/// rather than leaving the table showing rows out of step with its data.
@Suite("Row list edits")
struct RowListEditTests {

    /// A row: `id` is its identity, `text` what it draws.
    private struct Key: Equatable {
        let id: String
        var text = ""
    }

    private func rows(_ ids: String) -> [Key] { ids.map { Key(id: String($0)) } }

    private func plan(_ old: [Key], _ new: [Key]) -> RowListEdit {
        RowListEdit.plan(from: old, to: new, identity: \.id)
    }

    // MARK: - Nothing to do

    @Test("The same rows are no edit, including no rows at all")
    func unchangedIsNone() {
        #expect(plan(rows("abc"), rows("abc")) == .none)
        #expect(plan([], []) == .none)
    }

    // MARK: - Rows arriving at the front (newest-first lists)

    @Test("Rows arriving at the front are inserted there")
    func prependIsIncremental() {
        #expect(plan(rows("bc"), rows("abc"))
                == .incremental(removedFromFront: 0, insertedAtFront: 1, appended: 0, reloaded: []))
        #expect(plan(rows("cd"), rows("abcd"))
                == .incremental(removedFromFront: 0, insertedAtFront: 2, appended: 0, reloaded: []))
    }

    @Test("Rows arriving at both ends are one edit")
    func prependAndAppendIsIncremental() {
        #expect(plan(rows("bc"), rows("abcd"))
                == .incremental(removedFromFront: 0, insertedAtFront: 1, appended: 1, reloaded: []))
    }

    @Test("A kept row that changed is redrawn at its NEW index after a prepend")
    func prependRedrawIndexesNewRows() {
        var new = rows("abc")
        new[2].text = "edited"
        #expect(plan(rows("bc"), new)
                == .incremental(removedFromFront: 0, insertedAtFront: 1, appended: 0, reloaded: [2]))
    }

    @Test("A prepend that also drops rows from the end is a reload")
    func prependWithTailRemovalIsReload() {
        #expect(plan(rows("bc"), rows("ab")) == .reload)
    }

    @Test("A prepend that reorders the kept rows is a reload")
    func prependWithReorderIsReload() {
        #expect(plan(rows("bc"), rows("acb")) == .reload)
        #expect(plan(rows("bc"), rows("axc")) == .reload)
    }

    // MARK: - Rows leaving the front (capped lists)

    @Test("Trimming the front still removes rows there, with appends and redraws")
    func frontTrimIsIncremental() {
        #expect(plan(rows("abc"), rows("bcd"))
                == .incremental(removedFromFront: 1, appended: 1, reloaded: []))
        var new = rows("cd")
        new[0].text = "edited"
        #expect(plan(rows("abc"), new)
                == .incremental(removedFromFront: 2, appended: 1, reloaded: [0]))
    }

    @Test("A front row replaced by a different one is a reload, not a remove-and-insert")
    func frontReplacementIsReload() {
        #expect(plan(rows("abc"), rows("xbc")) == .reload)
    }

    @Test("A row moved between the ends is a reload, never removed and appended under one identity")
    func movedRowIsReload() {
        #expect(plan(rows("abc"), rows("bca")) == .reload)
        #expect(plan(rows("abc"), rows("cab")) == .reload)
    }

    // MARK: - Everything else

    @Test("Starting from nothing, or ending with nothing, is a reload")
    func emptyEndsAreReload() {
        #expect(plan([], rows("a")) == .reload)
        #expect(plan(rows("a"), []) == .reload)
    }

    @Test("A row appearing or vanishing in the middle is a reload")
    func middleChangeIsReload() {
        #expect(plan(rows("ac"), rows("abc")) == .reload)
        #expect(plan(rows("abc"), rows("ac")) == .reload)
    }
}
