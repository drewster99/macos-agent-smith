import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// The run loop's post-call decisions — park after messaging, re-arm Brown's silence nudge, stop
/// for a runtime restart — used to be made by string-matching each tool's human-facing output:
///
/// ```swift
/// if call.name == "message_brown" && result == "Message sent to Brown." { sentMessage = true }
/// ```
///
/// Two of those comparisons were already dead when this suite was written (2026-07-27), and
/// nothing anywhere reported it:
///
/// - `message_brown` (since renamed `notify_brown`) had been reworded to name the task — "Message sent to the worker on \"…\"" —
///   so its comparison never matched and Smith never parked after messaging a worker.
/// - Every messaging tool returns a DIFFERENT sentence when attachments are included
///   ("Message sent to user with 2 attachment(s): …"), so any message carrying an attachment
///   also failed to park.
///
/// Effects are now declared on the tool. These tests pin the declarations and, more importantly,
/// pin the property that made the old approach fail: an effect must not depend on output wording.
@Suite("Tool effects")
struct ToolEffectTests {

    // MARK: The declarations themselves

    @Test("Messaging tools declare that they delivered a message")
    func messagingToolsDeliverMessages() {
        #expect(MessageUserTool().successEffects.contains(.deliveredMessage))
        #expect(NotifyBrownTool().successEffects.contains(.deliveredMessage))
        #expect(ReplyToUserTool().successEffects.contains(.deliveredMessage))
    }

    @Test("Task communication tools declare that they reported progress")
    func taskCommunicationToolsReportProgress() {
        #expect(TaskUpdateTool().successEffects.contains(.reportedTaskProgress))
        #expect(TaskCompleteTool().successEffects.contains(.reportedTaskProgress))
    }

    @Test("run_task declares that it restarts the runtime")
    func runTaskRestartsRuntime() {
        #expect(RunTaskTool().successEffects.contains(.triggeredRuntimeRestart))
    }

    @Test("create_task does NOT declare a runtime restart")
    func createTaskDoesNotRestart() {
        // The old code checked `result.contains("System is restarting")` for create_task, but no
        // CreateTaskTool success path has said that for some time — a dead condition. Creating a
        // task spawns a worker without restarting the calling agent, so the absence is correct
        // and is pinned here so nobody "fixes" it back.
        #expect(!CreateTaskTool().successEffects.contains(.triggeredRuntimeRestart))
    }

    @Test("Ordinary tools declare no effects")
    func ordinaryToolsHaveNoEffects() {
        #expect(FileReadTool().successEffects.isEmpty)
        #expect(GrepTool().successEffects.isEmpty)
        #expect(CurrentTimeTool().successEffects.isEmpty)
    }

    // MARK: The property the old approach violated

    @Test("Effects are independent of the tool's output wording")
    func effectsDoNotDependOnOutputText() {
        // The whole point. `successEffects` is a static property of the tool, so it cannot drift
        // when someone rewords a user-facing string — which is exactly how `message_brown` and
        // every attachment-carrying message silently stopped parking the agent.
        let tool = NotifyBrownTool()
        #expect(tool.successEffects == [.deliveredMessage])
        // Reading it twice, with no call and no output in the picture at all, is the assertion:
        // there is no output text for the answer to depend on.
        #expect(tool.successEffects == NotifyBrownTool().successEffects)
    }

    @Test("request_help hands off without reporting progress, matching the prior behaviour")
    func requestHelpDoesNotReportProgress() {
        // `request_help` parks the worker exactly as `task_complete` does, so it is tempting to
        // give it `.reportedTaskProgress` too. It deliberately does not have it: the code this
        // replaced only counted `task_update` and `task_complete` as task communications, and
        // this change is about removing the dependence on output wording, not about altering
        // which calls re-arm the silence nudge. It is moot in practice — the nudge is gated on
        // `!awaitingTaskReview` and request_help parks — but the equivalence is worth pinning so
        // the refactor can be shown to be behaviour-preserving.
        #expect(!RequestHelpTool().successEffects.contains(.reportedTaskProgress))
        #expect(AgentActor.handoffLifecycleTools.contains(RequestHelpTool().name))
    }
}

/// A tool's NAME is referenced by string in several rosters that decide how it is treated, and
/// none of them fail loudly when the name stops matching. Renaming `message_brown` → `notify_brown`
/// on 2026-07-27 had to update all of them at once:
///
/// - `AgentActor.taskLifecycleTools` — sequenced, pre-cleared execution. A missing name means the
///   call takes the ordinary path instead (safe, but different).
/// - `ToolSafetyClassification.knownBuiltInNames` — **fail-closed**: an unrecognized name is
///   classified destructive.
/// - `BuiltInToolGroup.messaging` — the grouping the scoping UI and per-task approvals use.
///
/// This pins the tool's registered name against those rosters, so the next rename fails here
/// rather than in behaviour nobody is watching.
@Suite("notify_brown name registration")
struct NotifyBrownNameRegistrationTests {

    private let toolName = NotifyBrownTool().name

    @Test("The tool is named notify_brown")
    func hasExpectedName() {
        #expect(toolName == "notify_brown")
    }

    @Test("It is a task lifecycle tool, so it stays sequenced and pre-cleared")
    func isLifecycleTool() {
        #expect(AgentActor.taskLifecycleTools.contains(toolName))
    }

    @Test("The safety classifier knows it — an unknown name would be treated as destructive")
    func isKnownToSafetyClassification() {
        #expect(ToolSafetyClassification.knownBuiltInNames.contains(toolName))
        #expect(!ToolSafetyClassification.isDestructive(toolName: toolName), "notifying a worker is not destructive")
    }

    @Test("Smith actually has it")
    func smithHasIt() {
        #expect(SmithBehavior.toolNames.contains(toolName))
    }

    @Test("Brown does NOT have it — it is Smith's channel to a worker, not the reverse")
    func brownDoesNotHaveIt() {
        #expect(!BrownBehavior.toolNames.contains(toolName))
    }
}
