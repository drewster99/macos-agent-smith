import Foundation
import SwiftLLMKit
import os

private let validationLogger = Logger(subsystem: "com.agentsmith", category: "TaskValidation")

/// The `.validating` state machine: judging a submitted task against its acceptance
/// criteria, replacing Smith's review entirely. Lives on the runtime actor (all task
/// and registry state is runtime-confined); the LLM legwork happens in
/// `EvaluationRunner`.
///
/// Flow per round: resolve unsettled criteria → run their validators (bounded
/// parallelism, ERROR retried once) → record verdicts on the task's append-only ledger →
/// aggregate: all settled → complete; rejections with rounds remaining → punch list back
/// to the worker; otherwise → escalate to `.awaitingReview` with Smith and the user
/// notified. Idempotent and restartable: everything lives on the task, partial rounds
/// are never persisted as conclusions, and sticky accepts are skipped on re-runs.
/// Shipped evaluator definitions and validator capability constants — a namespace, not
/// runtime state (actor extensions can't host stored statics referencing Self).
public enum EvaluatorDefaults {

    /// The shipped default validator — Smith's old review, distilled into a function.
    /// Criterion-less tasks get exactly one materialized criterion judged by this.
    /// Ships with the read-only evidence quartet and the Summarizer's model (a required
    /// role, so validation works out of the box; point it at a dedicated validator slot
    /// by editing the JSON once one is configured).
    public static let defaultAcceptanceDefinition = EvaluatorDefinition(
        name: "default-acceptance",
        description: "General-purpose acceptance check: is the task, as described, genuinely and completely satisfied by the submitted result? Used when a criterion doesn't name a more specific validator.",
        kind: .validator,
        systemPrompt: """
            You are an acceptance validator for completed work. You are given a task, the worker's \
            submitted result, the worker's step list (including skipped/removed steps and their \
            reasons), and ONE acceptance criterion. Judge ONLY that criterion, on evidence: if file \
            paths or artifacts are referenced, verify them with your tools rather than taking the \
            worker's word. Be strict about completeness, but judge what the criterion asks — not \
            what you would have asked. Respond with your verdict on the FIRST line:
            ACCEPT — the criterion is satisfied.
            REJECT: <specific reason and what is missing — the worker acts on this verbatim>
            WAIVE: <why this criterion does not apply to this task>
            """,
        inputTemplate: """
            ## Task: {{task_title}} (id: {{task_id}})
            {{task_description}}

            ## Worker's step list (statuses + tombstones)
            {{steps}}

            ## Recent progress updates
            {{recent_updates}}

            ## Submitted result
            {{result}}

            ## Worker commentary
            {{commentary}}

            ## Criterion to judge
            {{criterion}}

            ## Your previous verdict on this criterion (if any)
            {{previous_verdict}}
            """,
        requiredSlots: ["task_title", "task_id", "task_description", "steps", "recent_updates", "result", "commentary", "criterion", "previous_verdict"],
        outputGrammar: .verdictLine(allowed: [
            .init(token: "ACCEPT", requiresReason: false),
            .init(token: "REJECT", requiresReason: true),
            .init(token: "WAIVE", requiresReason: true)
        ]),
        modelSlot: .summarizer,
        toolNames: EvaluatorDefaults.validatorEvidenceToolNames,
        maxTurns: 10,
        timeoutSeconds: 300,
        maxOutputTokens: 2000
    )

    /// The read-only evidence quartet — the capability ceiling for inline/Smith-authored
    /// validators, and the default toolset for shipped ones.
    public static let validatorEvidenceToolNames = ["file_read", "directory_listing", "grep", "glob"]

    /// Seeds the shipped definitions into the user-owned registry directory if absent.
    /// Never overwrites: once seeded, the file is the user's to edit.
    public static func seed(into directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("default-acceptance.json")
        guard !fileManager.fileExists(atPath: target.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(defaultAcceptanceDefinition) {
            try? data.write(to: target, options: .atomic)
        }
    }
}

extension OrchestrationRuntime {

    // MARK: - Entry points

    /// Kicks validation for a task that just entered `.validating` (from
    /// `task_complete`), or re-enqueues one found in that state at cold boot. Detached
    /// from the caller; per-task reentrancy-guarded.
    public func startTaskValidation(taskID: UUID) {
        guard !tasksBeingValidated.contains(taskID) else { return }
        tasksBeingValidated.insert(taskID)
        Task { [weak self] in
            await self?.performTaskValidation(taskID: taskID)
            await self?.finishTaskValidation(taskID: taskID)
        }
    }

    private func finishTaskValidation(taskID: UUID) async {
        tasksBeingValidated.remove(taskID)
        // A resubmission landing while this run was finishing gets its start call
        // swallowed by the reentrancy guard — re-check on the way out so the task can't
        // strand in `.validating`. Abort/stop paths intentionally leave that status for
        // the cold-boot re-enqueue, so they must not respin here.
        guard !aborted, !stopRequested else { return }
        if let task = await taskStore.task(id: taskID), task.status == .validating {
            startTaskValidation(taskID: taskID)
        }
    }

    // MARK: - The round

    private func performTaskValidation(taskID: UUID) async {
        guard !aborted, !stopRequested else { return }
        guard var task = await taskStore.task(id: taskID), task.status == .validating else { return }

        guard let directory = evaluatorsDirectory else {
            await escalateValidation(taskID: taskID, reason: "Validation is not configured (no evaluator registry directory). The submitted result needs manual review.")
            return
        }
        let registry = EvaluatorRegistry.load(from: directory)

        // Criterion-less task: materialize the implicit default criterion so the
        // contract is visible like any other.
        if task.acceptanceCriteria.isEmpty {
            await taskStore.materializeImplicitCriterion(id: taskID, criterion: AcceptanceCriterion(
                text: "The task, as described, has been completed correctly and completely, and the submitted result actually delivers it.",
                origin: .system,
                validator: .registry(EvaluatorDefaults.defaultAcceptanceDefinition.name)
            ))
            task = await taskStore.task(id: taskID) ?? task
        }

        guard let round = await taskStore.beginValidationRound(id: taskID) else { return }
        guard round <= maxValidationRounds else {
            await escalateValidation(taskID: taskID, reason: "Validation did not converge after \(maxValidationRounds) rounds — rejected criteria remain.")
            return
        }

        let settled = task.validation?.settledCriterionIDs() ?? []
        let pending = task.acceptanceCriteria.filter { !settled.contains($0.id) }
        guard !pending.isEmpty else {
            await completeValidatedTask(taskID: taskID)
            return
        }

        await channel.post(ChannelMessage(
            sender: .system,
            content: "Validating \"\(task.title)\" — round \(round): \(pending.count) criterion(s) to judge, \(settled.count) already settled.",
            metadata: ["messageKind": .string("validation_report"), "taskID": .string(taskID.uuidString)]
        ))

        // Judge pending criteria in waves of `validationParallelism` (a wave barrier is
        // fine at criterion counts; a sliding window would need shared mutable capture
        // that Swift 6 region isolation rightly rejects). ERROR outcomes retry once
        // inside judgeCriterion.
        var records: [CriterionVerdictRecord] = []
        // Immutable snapshot for the sending closures — `task` is a mutated var in the
        // actor's region and can't cross the boundary.
        let taskSnapshot = task
        for waveStart in stride(from: 0, to: pending.count, by: validationParallelism) {
            let wave = pending[waveStart..<min(waveStart + validationParallelism, pending.count)]
            await withTaskGroup(of: CriterionVerdictRecord?.self) { group in
                for criterion in wave {
                    group.addTask { [weak self] in
                        await self?.judgeCriterion(criterion, task: taskSnapshot, registry: registry, round: round)
                    }
                }
                for await record in group {
                    if let record { records.append(record) }
                }
            }
        }

        await taskStore.recordCriterionVerdicts(id: taskID, records: records)
        await postRoundSummary(taskID: taskID, round: round, records: records)

        guard !aborted, !stopRequested else { return }
        guard let judged = await taskStore.task(id: taskID), judged.status == .validating else { return }
        let ledger = judged.validation ?? TaskValidationState()
        let latestByCriterion = judged.acceptanceCriteria.compactMap { ledger.latestVerdict(for: $0.id) }

        let unjudged = judged.acceptanceCriteria.count - latestByCriterion.count
        let errored = latestByCriterion.filter { if case .error = $0.verdict { return true }; return false }
        let rejected = latestByCriterion.filter { if case .rejected = $0.verdict { return true }; return false }

        if unjudged == 0 && errored.isEmpty && rejected.isEmpty {
            await completeValidatedTask(taskID: taskID)
        } else if !errored.isEmpty {
            let messages = errored.map { record -> String in
                if case .error(let message) = record.verdict { return message }
                return "unknown"
            }
            await escalateValidation(taskID: taskID, reason: "Validation could not be completed: \(errored.count) criterion(s) errored (\(messages.joined(separator: "; "))). The result needs manual review.")
        } else if unjudged > 0 && rejected.isEmpty {
            // Smith added criteria mid-round (set_acceptance_criteria) — never-judged
            // criteria aren't errors OR rejections; they just need the next round. The
            // round budget still bounds this (a spin hits the round-cap escalation).
            await performTaskValidation(taskID: taskID)
        } else if round >= maxValidationRounds {
            await escalateValidation(taskID: taskID, reason: "Validation did not converge after \(round) rounds — \(rejected.count) criterion(s) still rejected.")
        } else {
            await returnRejectionsToWorker(taskID: taskID, rejected: rejected, round: round)
        }
    }

    /// Judges one criterion, retrying a first ERROR once (transient backends, parse
    /// flukes). A WAIVE against a non-waivable criterion is an ERROR — an
    /// author/validator disagreement escalates rather than silently passing or failing.
    private func judgeCriterion(
        _ criterion: AcceptanceCriterion,
        task: AgentTask,
        registry: EvaluatorRegistry,
        round: Int
    ) async -> CriterionVerdictRecord {
        let resolution = await resolveValidator(for: criterion, taskID: task.id, registry: registry)
        let definition: EvaluatorDefinition
        switch resolution {
        case .success(let resolved):
            definition = resolved
        case .failure(let problem):
            return CriterionVerdictRecord(
                criterionID: criterion.id,
                verdict: .error(message: problem),
                validatorName: criterion.validatorDisplayName,
                validatorHash: "-",
                round: round
            )
        }

        var outcome = await runValidator(definition, criterion: criterion, task: task)
        if case .error = outcome {
            validationLogger.notice("Criterion \(criterion.id.uuidString.prefix(8), privacy: .public) errored — retrying once")
            outcome = await runValidator(definition, criterion: criterion, task: task)
        }

        let verdict: CriterionVerdictRecord.Verdict
        switch outcome {
        case .verdict("ACCEPT", _):
            verdict = .accepted
        case .verdict("REJECT", let reason):
            verdict = .rejected(reason: reason ?? "no reason given")
        case .verdict("WAIVE", let reason):
            if criterion.waivable {
                verdict = .waived(reason: reason ?? "no reason given")
            } else {
                verdict = .error(message: "validator attempted to WAIVE a non-waivable criterion: \(reason ?? "no reason given")")
            }
        case .verdict(let token, let reason):
            verdict = .error(message: "unexpected verdict token '\(token)' (\(reason ?? ""))")
        case .items:
            verdict = .error(message: "validator returned items where a verdict was required")
        case .error(let message):
            verdict = .error(message: message)
        }
        return CriterionVerdictRecord(
            criterionID: criterion.id,
            verdict: verdict,
            validatorName: definition.name,
            validatorHash: definition.contentHash,
            round: round
        )
    }

    private enum ValidatorResolution {
        case success(EvaluatorDefinition)
        case failure(String)
    }

    /// Resolves a criterion's validator: inline definitions are capability-capped to the
    /// evidence quartet; registry names resolve pinned-body-first (edits apply to future
    /// tasks); anything missing or invalid fails VISIBLY (no fallback chains).
    private func resolveValidator(
        for criterion: AcceptanceCriterion,
        taskID: UUID,
        registry: EvaluatorRegistry
    ) async -> ValidatorResolution {
        switch criterion.validator {
        case .inline(let definition):
            let problems = definition.validationProblems()
            guard problems.isEmpty else {
                return .failure("inline validator '\(definition.name)' is invalid: \(problems.joined(separator: "; "))")
            }
            let disallowed = Set(definition.toolNames).subtracting(EvaluatorDefaults.validatorEvidenceToolNames)
            guard disallowed.isEmpty else {
                return .failure("inline validator '\(definition.name)' requests tools beyond the read-only evidence set (\(disallowed.sorted().joined(separator: ", "))) — persist it to the registry with user approval instead")
            }
            return .success(definition)
        case .registry, .none:
            let effectiveName: String
            if case .registry(let named) = criterion.validator {
                effectiveName = named
            } else {
                effectiveName = EvaluatorDefaults.defaultAcceptanceDefinition.name
            }
            if let pinned = (await taskStore.task(id: taskID))?.validation?.pinnedDefinitions[effectiveName] {
                return .success(pinned)
            }
            guard let definition = registry.definition(named: effectiveName), definition.kind == .validator else {
                return .failure("validator '\(effectiveName)' not found in the registry (or is not kind=validator) — validation skipped, manual review needed")
            }
            await taskStore.pinValidatorDefinition(id: taskID, definition: definition)
            return .success(definition)
        }
    }

    private func runValidator(
        _ definition: EvaluatorDefinition,
        criterion: AcceptanceCriterion,
        task: AgentTask
    ) async -> EvaluationRunner.Outcome {
        guard let resolved = providerForModelSlot(definition.modelSlot) else {
            return .error("no model configured for slot '\(definition.modelSlot.rawValue)'")
        }
        let (provider, config, usageRole, providerTypeRawValue) = resolved
        let previousVerdict = (task.validation?.latestVerdict(for: criterion.id)).map(Self.describeVerdict) ?? "none"
        let slots: [String: String] = [
            "task_id": task.id.uuidString,
            "task_title": task.title,
            "task_description": task.description,
            "steps": Self.renderSteps(task.steps),
            "recent_updates": task.updates.suffix(10).map { "- \($0.message)" }.joined(separator: "\n"),
            "result": task.result ?? "(none submitted)",
            "commentary": task.commentary ?? "(none)",
            "criterion": criterion.text,
            "previous_verdict": previousVerdict
        ]
        let tools = Self.evidenceTools(named: definition.toolNames)
        let evaluationContext = makeToolContext(agentID: UUID(), role: .securityAgent)
        let sessionID = currentSessionID
        let usageStore = usageStore
        return await EvaluationRunner.run(
            definition: definition,
            slots: slots,
            provider: provider,
            tools: tools,
            toolContext: evaluationContext,
            onResponse: { response, latencyMs in
                await UsageRecorder.record(
                    response: response,
                    context: LLMCallContext(
                        agentRole: usageRole,
                        taskID: task.id,
                        modelID: config.model,
                        providerType: providerTypeRawValue,
                        providerID: config.providerID,
                        configuration: config,
                        sessionID: sessionID
                    ),
                    latencyMs: latencyMs,
                    to: usageStore
                )
            }
        )
    }

    /// V1 model references are role slots only. `.validator` resolves to a dedicated
    /// provider once the app configures one; unconfigured slots fail visibly.
    private func providerForModelSlot(_ slot: EvaluatorDefinition.ModelSlot) -> (any LLMProvider, ModelConfiguration, AgentRole, String)? {
        switch slot {
        case .smith:
            guard let provider = llmProviders[.smith], let config = llmConfigs[.smith] else { return nil }
            return (provider, config, .smith, providerAPITypes[.smith]?.rawValue ?? "")
        case .summarizer:
            guard let provider = llmProviders[.summarizer], let config = llmConfigs[.summarizer] else { return nil }
            return (provider, config, .summarizer, providerAPITypes[.summarizer]?.rawValue ?? "")
        case .validator:
            guard let provider = validatorProvider, let config = validatorConfiguration else { return nil }
            // Attributed to .summarizer until AgentRole gains a validator case (the
            // decode shims are in; the dictionary-key migration is deliberately staged).
            return (provider, config, .summarizer, "")
        }
    }

    static func evidenceTools(named names: [String]) -> [any AgentTool] {
        let catalog: [String: any AgentTool] = [
            "file_read": FileReadTool(),
            "directory_listing": DirectoryListingTool(),
            "grep": GrepTool(),
            "glob": GlobTool()
        ]
        return names.compactMap { catalog[$0] }
    }

    static func renderSteps(_ steps: [TaskStep]) -> String {
        guard !steps.isEmpty else { return "(no steps recorded)" }
        return steps.map { step in
            var line = "- [\(step.status.rawValue)] \(step.text)"
            if let note = step.note, !note.isEmpty { line += " — note: \(note)" }
            return line
        }.joined(separator: "\n")
    }

    static func describeVerdict(_ record: CriterionVerdictRecord) -> String {
        switch record.verdict {
        case .accepted: return "round \(record.round): ACCEPT"
        case .rejected(let reason): return "round \(record.round): REJECT — \(reason)"
        case .waived(let reason): return "round \(record.round): WAIVE — \(reason)"
        case .error(let message): return "round \(record.round): ERROR — \(message)"
        }
    }

    // MARK: - Outcomes

    private func postRoundSummary(taskID: UUID, round: Int, records: [CriterionVerdictRecord]) async {
        guard let task = await taskStore.task(id: taskID) else { return }
        let criteriaByID = Dictionary(task.acceptanceCriteria.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let lines = records.map { record -> String in
            let text = criteriaByID[record.criterionID]?.text ?? record.criterionID.uuidString
            return "- \(text): \(Self.describeVerdict(record))"
        }
        let summary = "Validation round \(round) for \"\(task.title)\":\n" + lines.joined(separator: "\n")
        await taskStore.addUpdate(id: taskID, message: summary)
        await channel.post(ChannelMessage(
            sender: .system,
            content: summary,
            metadata: ["messageKind": .string("validation_report"), "taskID": .string(taskID.uuidString)]
        ))
    }

    /// All criteria settled: complete the task — the machine analogue of review_work's
    /// accept path (status, worker teardown, completion banner, summarization). The
    /// terminated hook then drives auto-advance and Smith's context compaction.
    private func completeValidatedTask(taskID: UUID) async {
        await taskStore.updateStatus(id: taskID, status: .completed)
        guard let completed = await taskStore.task(id: taskID) else { return }
        for agentID in completed.assigneeIDs {
            _ = await terminateAgent(id: agentID)
        }
        var bannerMetadata: [String: AnyCodable] = [
            "messageKind": .string("task_completed"),
            "taskID": .string(taskID.uuidString)
        ]
        if let startedAt = completed.startedAt, let completedAt = completed.completedAt {
            bannerMetadata["durationSeconds"] = .double(completedAt.timeIntervalSince(startedAt))
        }
        if let result = completed.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            bannerMetadata["taskResult"] = .string(result)
        }
        await channel.post(ChannelMessage(sender: .system, content: completed.title, metadata: bannerMetadata))
        await summarizeAndEmbedTask(taskID: taskID)
        if let smithAgent = supervisor.firstHandle(role: .smith)?.agent {
            await smithAgent.appendUserMessage("""
                [System: Task "\(completed.title)" (ID: \(taskID.uuidString)) passed acceptance validation and is COMPLETE. \
                The result was already delivered to the user in the Task Completed banner — do not repeat it. \
                No action is needed from you.]
                """)
        }
    }

    /// Rejections with rounds remaining: the punch list goes DIRECTLY to the worker —
    /// Smith is not a relay. Mirrors review_work's reject path (status, clearResult,
    /// respawn fallback, private unparking message).
    private func returnRejectionsToWorker(taskID: UUID, rejected: [CriterionVerdictRecord], round: Int) async {
        guard let task = await taskStore.task(id: taskID) else { return }
        let criteriaByID = Dictionary(task.acceptanceCriteria.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let punchList = rejected.map { record -> String in
            let text = criteriaByID[record.criterionID]?.text ?? "criterion \(record.criterionID.uuidString)"
            if case .rejected(let reason) = record.verdict {
                return "- \(text)\n  REJECTED: \(reason)"
            }
            return "- \(text)"
        }.joined(separator: "\n")

        await taskStore.updateStatus(id: taskID, status: .running)
        await taskStore.clearResult(id: taskID)

        var brownID = task.assigneeIDs.first { supervisor.role(of: $0) == .brown }
        var brownWasSpawned = false
        if brownID == nil {
            if let spawned = await spawnBrown(for: task) {
                await taskStore.assignAgent(taskID: taskID, agentID: spawned)
                brownID = spawned
                brownWasSpawned = true
            }
        }
        guard let brownID else {
            await escalateValidation(taskID: taskID, reason: "Validation rejected \(rejected.count) criterion(s) but no worker could be spawned to fix them.")
            return
        }

        var parts: [String] = []
        if brownWasSpawned {
            parts.append("## Task: \(task.title)\n\n\(task.description)")
            if !task.updates.isEmpty {
                parts.append("## Prior Progress\n" + task.updates.map { "- \($0.message)" }.joined(separator: "\n"))
            }
        }
        parts.append("""
            ## Acceptance validation — round \(round): changes required
            The following acceptance criteria were REJECTED. Fix each, then resubmit with `task_complete`. \
            Criteria already accepted stay accepted — do not rework them.
            \(punchList)
            """)

        await channel.post(ChannelMessage(
            sender: .system,
            recipientID: brownID,
            recipient: .agent(.brown),
            content: parts.joined(separator: "\n\n"),
            metadata: [
                "messageKind": .string("changes_requested"),
                "taskTitle": .string(task.title),
                "taskID": .string(taskID.uuidString)
            ]
        ))
    }

    /// Escalation: the bounded loop failed to converge, a validator errored past retry,
    /// or validation isn't configured. The task parks in `.awaitingReview` — Smith's
    /// review_work becomes the resolution tool — and both Smith and the user are
    /// actively notified. Escalation must never be silent.
    private func escalateValidation(taskID: UUID, reason: String) async {
        await taskStore.updateStatus(id: taskID, status: .awaitingReview)
        guard let task = await taskStore.task(id: taskID) else { return }
        await channel.post(ChannelMessage(
            sender: .system,
            content: "Validation escalation for \"\(task.title)\": \(reason)",
            metadata: [
                "messageKind": .string("validation_escalation"),
                "taskID": .string(taskID.uuidString),
                "isWarning": .bool(true)
            ]
        ))
        if let smithAgent = supervisor.firstHandle(role: .smith)?.agent {
            await smithAgent.appendUserMessage("""
                [System: Task "\(task.title)" (ID: \(taskID.uuidString)) was submitted but acceptance validation \
                ESCALATED: \(reason) The task is awaiting your review — inspect the result and the validation \
                verdicts in the task's updates, then call `review_work` to accept it or send it back with \
                feedback. Tell the user briefly that this task needs attention.]
                """)
        }
    }
}

private extension AcceptanceCriterion {
    var validatorDisplayName: String {
        switch validator {
        case .registry(let name): return name
        case .inline(let definition): return definition.name
        case .none: return "default-acceptance"
        }
    }
}
