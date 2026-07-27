import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

@Suite("InlineDiff (word-level)")
struct InlineDiffTests {

    @Test("identical text is a single equal span")
    func identical() {
        let spans = InlineDiff.diff(old: "the quick brown fox", new: "the quick brown fox")
        #expect(spans.count == 1)
        #expect(spans.first?.kind == .equal)
    }

    @Test("empty old / empty new degrade to pure add / pure remove")
    func pureAddRemove() {
        #expect(InlineDiff.diff(old: "", new: "hello").allSatisfy { $0.kind == .added })
        #expect(InlineDiff.diff(old: "hello", new: "").allSatisfy { $0.kind == .removed })
    }

    @Test("a one-word edit highlights only that word, keeping the rest equal")
    func oneWordEdit() {
        let spans = InlineDiff.diff(old: "the quick brown fox", new: "the slow brown fox")
        // Reconstruct each side and confirm the unchanged words stay equal.
        let oldSide = spans.filter { $0.kind != .added }.map(\.text).joined()
        let newSide = spans.filter { $0.kind != .removed }.map(\.text).joined()
        #expect(oldSide == "the quick brown fox")
        #expect(newSide == "the slow brown fox")
        #expect(spans.contains { $0.kind == .removed && $0.text == "quick" })
        #expect(spans.contains { $0.kind == .added && $0.text == "slow" })
        // "brown fox" and "the " must survive as equal — not re-emitted as remove+add.
        #expect(spans.contains { $0.kind == .equal && $0.text.contains("brown fox") })
    }

    @Test("relatedness distinguishes an edit from two unrelated lines")
    func relatedness() {
        #expect(InlineDiff.areRelated(old: "the quick brown fox", new: "the slow brown fox"))
        #expect(!InlineDiff.areRelated(old: "apple banana cherry", new: "xylophone plugh zzz"))
    }
}

@Suite("ConversationDiff (message-aware)")
struct ConversationDiffTests {

    @Test("a compaction aligns kept messages and marks the removed span + injected summary")
    func compactionShape() {
        let before: [LLMMessage] = [
            .system("SYSTEM"),
            .user("do the thing"),
            .assistant(from: LLMResponse(text: "working on it")),
            .user("recent tail A"),
            .user("recent tail B")
        ]
        let after: [LLMMessage] = [
            .system("SYSTEM"),
            .user("[Context compacted. Summary: …]"),
            .user("recent tail A"),
            .user("recent tail B")
        ]
        let rows = ConversationDiff.build(before: before, after: after)

        // The system prompt and the two tail messages are unchanged and must align as equal.
        let equalTexts = rows.filter { $0.kind == .equal }.compactMap { $0.left?.text }
        #expect(equalTexts.contains("SYSTEM"))
        #expect(equalTexts.contains("recent tail A"))
        #expect(equalTexts.contains("recent tail B"))
        // The middle two messages are gone; the summary is new.
        #expect(rows.contains { $0.kind == .removed && $0.left?.text == "do the thing" })
        #expect(rows.contains { $0.kind == .removed && $0.left?.text == "working on it" })
        #expect(rows.contains { $0.kind == .added && ($0.right?.text.contains("Summary") ?? false) })
    }

    @Test("a related edit becomes a changed row with in-place word highlighting, not delete+add")
    func changedRowInlineHighlight() {
        let before: [LLMMessage] = [.system("S"), .user("please review the quick brown fox now")]
        let after: [LLMMessage] = [.system("S"), .user("please review the slow brown fox now")]
        let rows = ConversationDiff.build(before: before, after: after)

        let changed = rows.first { $0.kind == .changed }
        #expect(changed != nil, "a related single-message edit should be a .changed row")
        let lineRows = changed?.lineRows ?? []
        #expect(lineRows.contains { $0.kind == .changed })
        // The changed line must carry a removed 'quick' on the old side and an added 'slow' on the new.
        let changedLine = lineRows.first { $0.kind == .changed }
        #expect(changedLine?.oldSpans?.contains { $0.kind == .removed && $0.text == "quick" } ?? false)
        #expect(changedLine?.newSpans?.contains { $0.kind == .added && $0.text == "slow" } ?? false)
    }
}
