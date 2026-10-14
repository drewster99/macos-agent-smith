import Foundation
import Testing
@testable import AgentSmithKit

/// Which messages become transcript rows, and how a table moves from one set of rows to the next.
///
/// The row rules used to live inside the SwiftUI view, spread over a grouping index, a suppression
/// predicate and three `EmptyView` branches. These pin them now that they are one function, and
/// pin the edit planner the table relies on to avoid reloading 5,000 rows per appended message.
@Suite("Transcript rows")
struct TranscriptRowsTests {

    private static let showAll = TranscriptRows.Options(verdictFilter: .all, showsRestartChrome: true)

    private func message(_ kind: ChannelMessageKind?, _ extra: [String: AnyCodable] = [:],
                         sender: ChannelMessage.Sender = .agent(.brown)) -> ChannelMessage {
        var metadata = extra
        if let kind { metadata["messageKind"] = .kind(kind) }
        return ChannelMessage(sender: sender, content: "x", metadata: metadata.isEmpty ? nil : metadata)
    }

    private func toolCall(_ requestID: String) -> ChannelMessage {
        message(.toolRequest, ["requestID": .string(requestID), "tool": .string("bash")])
    }

    private func output(_ requestID: String) -> ChannelMessage {
        message(.toolOutput, ["requestID": .string(requestID), "tool": .string("bash")])
    }

    private func verdict(_ requestID: String, _ disposition: String = "approved") -> ChannelMessage {
        message(.securityReview, ["requestID": .string(requestID),
                                  "securityDisposition": .string(disposition)],
                sender: .agent(.securityAgent))
    }

    private func ids(_ rows: [TranscriptRow]) -> [UUID] { rows.map(\.id) }

    // MARK: - Which messages are rows

    @Test("A tool call's verdict and output fold into the call's row")
    func followUpsFoldIntoTheirCall() {
        let call = toolCall("r1"), review = verdict("r1"), result = output("r1")
        let rows = TranscriptRows.make(from: [call, review, result], options: Self.showAll)
        #expect(ids(rows) == [call.id])
        #expect(rows[0].securityReview?.id == review.id)
        #expect(rows[0].toolOutput?.id == result.id)
        #expect(rows[0].showsSecurityReviewText)
    }

    @Test("A follow-up whose call is not in the pane gets a row of its own")
    func orphanFollowUpsStandAlone() {
        let result = output("gone"), review = verdict("gone")
        let rows = TranscriptRows.make(from: [result, review], options: Self.showAll)
        #expect(ids(rows) == [result.id, review.id])
    }

    @Test("A verdict the pane hides never gets a row, but still reaches its call for the icon")
    func hiddenVerdictKeepsOnlyTheIcon() {
        let call = toolCall("r1"), review = verdict("r1"), orphanReview = verdict("gone")
        let hideVerdicts = TranscriptRows.Options(
            verdictFilter: TranscriptFilter(kinds: .allExcept([.securityReview])),
            showsRestartChrome: true
        )
        let rows = TranscriptRows.make(from: [call, review, orphanReview], options: hideVerdicts)
        #expect(ids(rows) == [call.id])
        #expect(rows[0].securityReview?.id == review.id)
        #expect(!rows[0].showsSecurityReviewText)
    }

    @Test("Internal Smith guidance is never a row")
    func guidanceIsNeverARow() {
        let rows = TranscriptRows.make(from: [message(.taskUpdateGuidance)], options: Self.showAll)
        #expect(rows.isEmpty)
    }

    @Test("Lifecycle chrome is a row only when the preference shows it")
    func restartChromeFollowsThePreference() {
        let chrome = message(.restartChrome, sender: .system)
        #expect(TranscriptRows.make(from: [chrome], options: Self.showAll).count == 1)
        let hidden = TranscriptRows.Options(verdictFilter: .all, showsRestartChrome: false)
        #expect(TranscriptRows.make(from: [chrome], options: hidden).isEmpty)
    }

    @Test("A scheduled-timer row is dropped only when its task has a scheduling banner")
    func scheduledTimerRowsDeduplicate() {
        let taskID = UUID().uuidString
        let timer = message(.timerActivity, ["timerEventKind": .string("scheduled"),
                                             "timerTaskID": .string(taskID)], sender: .system)
        let banner = message(.taskCreated, ["taskID": .string(taskID)], sender: .system)
        let fired = message(.timerActivity, ["timerEventKind": .string("fired"),
                                             "timerTaskID": .string(taskID)], sender: .system)

        #expect(ids(TranscriptRows.make(from: [timer], options: Self.showAll)) == [timer.id])
        // The banner arriving AFTER the timer row still removes it — the rule is over the pane.
        #expect(ids(TranscriptRows.make(from: [timer, banner], options: Self.showAll)) == [banner.id])
        // Only the "scheduled" event repeats the banner.
        #expect(ids(TranscriptRows.make(from: [fired, banner], options: Self.showAll)) == [fired.id, banner.id])
    }

    @Test("Ordinary messages keep their order")
    func ordinaryMessagesAreRowsInOrder() {
        let a = message(nil, sender: .user), b = message(nil, sender: .agent(.smith))
        #expect(ids(TranscriptRows.make(from: [a, b], options: Self.showAll)) == [a.id, b.id])
    }

    // MARK: - Edits

    private func keys(_ messages: [ChannelMessage], _ options: TranscriptRows.Options = showAll)
        -> [TranscriptRow.RenderKey] {
        TranscriptRows.make(from: messages, options: options).map(\.renderKey)
    }

    @Test("No change is no edit")
    func unchangedIsNone() {
        let all = [message(nil), toolCall("r1")]
        #expect(TranscriptRows.edit(from: keys(all), to: keys(all)) == .none)
        #expect(TranscriptRows.edit(from: [], to: []) == .none)
    }

    @Test("Appending messages appends rows")
    func appendIsIncremental() {
        let a = message(nil), b = message(nil), c = message(nil)
        #expect(TranscriptRows.edit(from: keys([a]), to: keys([a, b, c]))
                == .incremental(removedFromFront: 0, appended: 2, reloaded: []))
    }

    @Test("Trimming the front at the cap while appending is one incremental edit")
    func frontTrimIsIncremental() {
        let a = message(nil), b = message(nil), c = message(nil), d = message(nil)
        #expect(TranscriptRows.edit(from: keys([a, b, c]), to: keys([b, c, d]))
                == .incremental(removedFromFront: 1, appended: 1, reloaded: []))
    }

    @Test("A follow-up arriving redraws its call's row instead of adding one")
    func followUpReloadsItsParent() {
        let before = message(nil), call = toolCall("r1"), result = output("r1"), after = message(nil)
        #expect(TranscriptRows.edit(from: keys([before, call]), to: keys([before, call, result, after]))
                == .incremental(removedFromFront: 0, appended: 1, reloaded: [1]))
    }

    @Test("A filter change that alters verdict text redraws in place")
    func verdictVisibilityChangeReloads() {
        let call = toolCall("r1"), review = verdict("r1")
        let hidden = TranscriptRows.Options(
            verdictFilter: TranscriptFilter(kinds: .allExcept([.securityReview])),
            showsRestartChrome: true
        )
        #expect(TranscriptRows.edit(from: keys([call, review]), to: keys([call, review], hidden))
                == .incremental(removedFromFront: 0, appended: 0, reloaded: [0]))
    }

    @Test("Starting from nothing, or a first row that was never there, is a reload")
    func unrelatedIsReload() {
        let a = message(nil), b = message(nil)
        #expect(TranscriptRows.edit(from: [], to: keys([a])) == .reload)
        #expect(TranscriptRows.edit(from: keys([a]), to: keys([b])) == .reload)
        #expect(TranscriptRows.edit(from: keys([a]), to: []) == .reload)
    }

    @Test("A row appearing in the middle is a reload, not a misaligned append")
    func middleInsertIsReload() {
        let a = message(nil), b = message(nil), c = message(nil)
        #expect(TranscriptRows.edit(from: keys([a, c]), to: keys([a, b, c])) == .reload)
    }

    @Test("Rows removed from the end are a reload")
    func tailRemovalIsReload() {
        let a = message(nil), b = message(nil)
        #expect(TranscriptRows.edit(from: keys([a, b]), to: keys([a])) == .reload)
    }

    @Test("An orphaned follow-up whose call was trimmed away becomes its own row via reload")
    func trimmedParentExposesFollowUp() {
        let call = toolCall("r1"), result = output("r1"), next = message(nil)
        // The call is trimmed; its output now stands alone where it was folded before.
        #expect(TranscriptRows.edit(from: keys([call, result, next]), to: keys([result, next]))
                == .reload)
    }
}
