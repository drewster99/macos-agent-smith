import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

@Suite("Task complete control flow")
struct TaskCompleteControlFlowTests {
    @Test("A successful task completion parks the worker without inspecting response text")
    func successfulTaskCompletion() {
        #expect(AgentActor.shouldParkAfterLifecycleTool(named: "task_complete", succeeded: true))
    }

    @Test("A rejected task completion remains actionable")
    func rejectedTaskCompletion() {
        #expect(!AgentActor.shouldParkAfterLifecycleTool(named: "task_complete", succeeded: false))
    }

    @Test("Only handoff lifecycle tools park the worker")
    func otherToolCalls() {
        #expect(AgentActor.shouldParkAfterLifecycleTool(named: "request_help", succeeded: true))
        #expect(!AgentActor.shouldParkAfterLifecycleTool(named: "task_update", succeeded: true))
    }

    @Test("Every parking tool is a lifecycle tool, so the run loop actually breaks on it")
    func parkingToolsAreLifecycleTools() {
        // Only the lifecycle branch of the segment loop knows how to stop the remaining
        // segments after a handoff. A parking tool that fell out of `taskLifecycleTools` would
        // set the flag from a branch that keeps going — the worker would carry on working on a
        // task it had already submitted, with nothing failing to say so.
        #expect(
            AgentActor.handoffLifecycleTools.isSubset(of: AgentActor.taskLifecycleTools),
            "handoff tools missing from taskLifecycleTools: \(AgentActor.handoffLifecycleTools.subtracting(AgentActor.taskLifecycleTools).sorted())"
        )
    }
}

/// Regression coverage for the 2026-07-27 parked-worker spin.
///
/// A worker ran its task correctly in 16 seconds, called `task_complete`, and parked. In the SAME
/// millisecond `TaskValidationCoordinator` posted it `validation_blocked_worker_notice` — the
/// notice that exists to say "your submission is PARKED … Do NOT resubmit, rework anything, or
/// call request_help — STOP and wait." It is addressed privately to the worker so the worker can
/// learn why it went quiet.
///
/// The un-park gate tested `recipientID == id` and nothing else, so that notice was read as
/// revision feedback: it un-parked the very agent it was sent to quiet. The notice had also just
/// forbidden the only two tools that re-park (`task_complete`, `request_help`), so the worker had
/// no route back to idle. It narrated for 19 minutes — 58 text-only turns interleaved with 23
/// byte-identical `get_task_details` calls, an alternation that resets all three existing
/// circuit breakers — until a clean run of six text-only turns finally terminated it.
@Suite("Parked worker resume gating")
struct ParkedWorkerResumeTests {

    private static func message(
        recipientID: UUID?,
        kind: String?
    ) -> ChannelMessage {
        ChannelMessage(
            sender: .system,
            recipientID: recipientID,
            recipient: recipientID == nil ? nil : .agent(.brown),
            content: "test",
            metadata: kind.map { ["messageKind": .string($0)] }
        )
    }

    @Test("The park notice does NOT resume the worker it just told to stop")
    func parkNoticeDoesNotResume() {
        let agentID = UUID()
        let notice = Self.message(
            recipientID: agentID,
            kind: ChannelMessage.Kind.validationBlockedWorkerNotice
        )
        #expect(!AgentActor.resumesParkedWorker(notice, agentID: agentID))
    }

    @Test("A validator punch list resumes the worker")
    func changesRequestedResumes() {
        let agentID = UUID()
        let punchList = Self.message(recipientID: agentID, kind: "changes_requested")
        #expect(AgentActor.resumesParkedWorker(punchList, agentID: agentID))
    }

    @Test("A private message with no messageKind resumes the worker")
    func unlabelledPrivateMessageResumes() {
        // `message_brown`, `provide_help`, and `amend_task` all reach a parked worker as private
        // messages. The default must stay "resume": a missed exemption costs one wasted turn,
        // while a missed ALLOWLIST entry would strand the worker parked forever.
        let agentID = UUID()
        let direct = Self.message(recipientID: agentID, kind: nil)
        #expect(AgentActor.resumesParkedWorker(direct, agentID: agentID))
    }

    @Test("A message addressed to a different agent never resumes this one")
    func otherRecipientDoesNotResume() {
        let agentID = UUID()
        let forSomeoneElse = Self.message(recipientID: UUID(), kind: "changes_requested")
        #expect(!AgentActor.resumesParkedWorker(forSomeoneElse, agentID: agentID))
    }

    @Test("A public broadcast never resumes a parked worker")
    func publicMessageDoesNotResume() {
        let agentID = UUID()
        let banner = Self.message(recipientID: nil, kind: "validation_blocked")
        #expect(!AgentActor.resumesParkedWorker(banner, agentID: agentID))
    }

    @Test("Every exempted kind is a real string the exemption reader can match")
    func exemptionsAreNonEmpty() {
        // The exemption set is a contract between the poster (TaskValidationCoordinator) and this
        // reader, carried by a metadata string. An empty or whitespace entry would match nothing
        // and silently restore the bug.
        #expect(!AgentActor.parkedWorkerInformationalMessageKinds.isEmpty)
        for kind in AgentActor.parkedWorkerInformationalMessageKinds {
            #expect(!kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// The continuation-nudge bound: the backstop for a worker that has genuinely run out of work.
///
/// A text-only Brown turn does not go idle — it gets a synthetic "Continue. Use your tools" user
/// turn and the run loop immediately spins again. That is right mid-task and wrong when there is
/// nothing left to do, because narrating is the one thing a worker can do forever.
@Suite("Continuation nudge bound")
struct ContinuationNudgeBoundTests {

    @Test("The nudge cap sits above the text-only termination limit")
    func capIsAboveTextOnlyLimit() {
        // These two breakers cover different shapes and must not race. The text-only limit ends
        // UNRELIEVED narration by terminating; the nudge cap ends narration INTERLEAVED with
        // repeated no-op tool calls by idling. If the cap dropped to or below the text-only
        // limit it would fire first in both cases, quietly converting a termination into an idle.
        #expect(
            AgentActor.maxContinuationNudgesSinceProgress > AgentActor.textOnlyResponseLimit(for: .brown)
        )
    }

    @Test("Smith tolerates far more text-only turns than a worker")
    func smithLimitIsLooser() {
        // Smith answers many turns with prose alone (digest ticks, "no action needed"), so its
        // limit is deliberately loose. Brown is tool-heavy, so unrelieved narration is diagnostic.
        #expect(
            AgentActor.textOnlyResponseLimit(for: .smith) > AgentActor.textOnlyResponseLimit(for: .brown)
        )
    }
}
