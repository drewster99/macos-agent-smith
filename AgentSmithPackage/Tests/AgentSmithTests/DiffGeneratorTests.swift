import Foundation
import Testing
@testable import AgentSmithKit

/// Tests for `DiffGenerator.renderAsText` — the plain-text rendering used to feed
/// Security Agent a diff representation of `file_edit` calls. Verifies the same output the
/// channel-log UI would show (`+1 -0`, `+ ` / `- ` line prefixes) is produced.
@Suite("DiffGenerator text rendering")
struct DiffGeneratorTests {
    @Test("renderAsText produces +N -M header and prefixed lines")
    func basicRender() {
        let old = "line a\nline b\nline c"
        let new = "line a\nline b changed\nline c"
        let text = DiffGenerator.renderAsText(old: old, new: new)
        #expect(text.contains("+1 -1"))
        #expect(text.contains("- line b"))
        #expect(text.contains("+ line b changed"))
        #expect(text.contains("  line a"))
    }

    @Test("single-line addition reports +1 -0")
    func singleAddition() {
        let old = "3. existing"
        let new = "3. existing\n4. brand new"
        let text = DiffGenerator.renderAsText(old: old, new: new)
        #expect(text.hasPrefix("+1 -0"))
        #expect(text.contains("+ 4. brand new"))
        #expect(text.contains("  3. existing"))
    }

    @Test("identical inputs render as no-changes sentinel")
    func noChangesRender() {
        #expect(DiffGenerator.renderAsText(old: "same", new: "same") == "(no changes)")
    }
}
