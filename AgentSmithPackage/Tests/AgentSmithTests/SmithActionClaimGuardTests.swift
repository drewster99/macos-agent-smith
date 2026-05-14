import Testing
import Foundation
@testable import AgentSmithKit

/// Regression coverage for the `[System]` correction Smith receives when his
/// text-only response asserts a completed action that was never actually
/// performed via a tool call.
///
/// The bug being guarded: in session BB94BA9C the user asked Smith "Can you
/// terminate him." Smith replied with plain text "Done. The task is now marked
/// failed. Brown has been effectively stopped." — and never invoked
/// `terminate_agent` or any task-disposition tool. Brown kept running for
/// another two minutes. The fix has two layers: a prompt rule (item 37 in
/// SmithBehavior's scoring section) and a runtime detector that injects a
/// `[System]` reminder into Smith's history when the pattern is detected.
///
/// This test exercises the runtime detector directly via the `nonisolated
/// static` helper `AgentActor.detectActionClaimWithoutToolCall(text:)`.
@Suite("Smith action-claim guard")
struct SmithActionClaimGuardTests {

    @Test("text claiming Brown was terminated is detected")
    func detectsBrownTerminated() {
        let text = "Done. The task is now marked failed. Brown has been effectively stopped since the changes were reverted."
        let phrase = AgentActor.detectActionClaimWithoutToolCall(text: text)
        #expect(phrase != nil, "expected a phrase match for the canonical hallucinated-termination message")
    }

    @Test("text claiming a task was marked failed is detected")
    func detectsTaskMarkedFailed() {
        let text = "I've marked the task as failed. Standing by for next steps."
        let phrase = AgentActor.detectActionClaimWithoutToolCall(text: text)
        #expect(phrase != nil)
    }

    @Test("Brown stopped phrasing is detected")
    func detectsBrownStopped() {
        let text = "Brown stopped — he can't proceed without your input."
        let phrase = AgentActor.detectActionClaimWithoutToolCall(text: text)
        #expect(phrase != nil)
    }

    @Test("paused-agent phrasing is detected")
    func detectsPaused() {
        let text = "I've paused him while we wait for confirmation."
        let phrase = AgentActor.detectActionClaimWithoutToolCall(text: text)
        #expect(phrase != nil)
    }

    @Test("benign 'Brown is on track' message does NOT trigger")
    func ignoresBrownOnTrack() {
        let text = "Brown is on track. The approach of examining the shared module plus UI files is sound."
        let phrase = AgentActor.detectActionClaimWithoutToolCall(text: text)
        #expect(phrase == nil)
    }

    @Test("benign 'task is on track' message does NOT trigger")
    func ignoresOnTrackTask() {
        let text = "Brown's plan is sound and conservative. The task is progressing well."
        let phrase = AgentActor.detectActionClaimWithoutToolCall(text: text)
        #expect(phrase == nil)
    }

    @Test("descriptive 'the script terminated' (not action claim) does NOT trigger")
    func ignoresUnrelatedTerminated() {
        // "terminated" appears but the subject is not Brown/agent/task — this is
        // describing tool output, not claiming Smith terminated something.
        let text = "The build script terminated with exit code 65. The error is in the workspace dependency."
        let phrase = AgentActor.detectActionClaimWithoutToolCall(text: text)
        #expect(phrase == nil)
    }

    @Test("acknowledgement of user-initiated revert does NOT trigger")
    func ignoresUserRevertAck() {
        let text = "Got it. You've reverted the changes — Brown will need a fresh briefing if we restart."
        let phrase = AgentActor.detectActionClaimWithoutToolCall(text: text)
        #expect(phrase == nil)
    }

    @Test("returned phrase is included for context in the [System] correction")
    func returnsMatchedPhrase() {
        let text = "I terminated Brown."
        let phrase = AgentActor.detectActionClaimWithoutToolCall(text: text)
        #expect(phrase != nil)
        if let phrase {
            // The phrase is a substring of the input — used as `<phrase>` in the
            // [System] correction template so Smith can see what tripped the guard.
            #expect(text.contains(phrase))
        }
    }
}
