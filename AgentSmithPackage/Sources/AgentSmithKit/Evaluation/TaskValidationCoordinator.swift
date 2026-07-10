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
            reasons), the worker's tool list, and ONE acceptance criterion. Judge ONLY that \
            criterion, on evidence.

            Your toolset is NOT the worker's. You hold only read-only evidence tools; the worker \
            typically has shell access, web access, and more — its actual tool list is in the \
            input. NEVER conclude that a tool "is not available" or that work was infeasible \
            because YOU lack the tool. For claims you can check yourself (files, directories, \
            file contents), verify with your tools rather than taking the worker's word. For \
            actions you cannot reproduce (shell commands, web fetches, sent messages), judge on \
            the evidence trail — the SYSTEM-OBSERVED tool activity log in the input (this is \
            recorded by the runtime, not self-reported; trust it over narrative claims), the \
            step list, progress updates, and the specificity of the result — not on whether \
            you could perform them.

            Be strict about completeness, but judge what the criterion asks — not what you would \
            have asked. Respond with your verdict on the FIRST line:
            ACCEPT — the criterion is satisfied.
            REJECT: <specific reason and what is missing — the worker acts on this verbatim>
            WAIVE: <why this criterion does not apply to this task>
            """,
        inputTemplate: """
            ## Task: {{task_title}} (id: {{task_id}})
            {{task_description}}

            ## Worker's tools (its capabilities differ from yours)
            {{worker_tools}}

            ## Worker's tool activity (system-observed — trust this over narrative claims)
            {{worker_activity}}

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
        requiredSlots: ["task_title", "task_id", "task_description", "worker_tools", "worker_activity", "steps", "recent_updates", "result", "commentary", "criterion", "previous_verdict"],
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

    /// The definitions the app itself provides. NOT stored in the user's registry
    /// directory and NOT editable — the app always supplies the current version. To
    /// customize one, duplicate its JSON (from the pinned body on any task, or
    /// `list_validators`) under a NEW name in the evaluators directory and edit that.
    public static var builtInDefinitions: [EvaluatorDefinition] {
        [defaultAcceptanceDefinition]
    }

    /// Names reserved by built-ins — user registry files with these names are load
    /// failures (they would shadow an always-current definition).
    public static var builtInNames: Set<String> {
        Set(builtInDefinitions.map(\.name))
    }

    /// Content hashes of every revision the OLD disk-seeding mechanism ever wrote.
    /// Used solely to migrate legacy registries: a file matching one of these is a
    /// pristine shipped copy (delete it — the built-in supplies it now); anything else
    /// under a built-in name is a user edit (preserved by renaming to `<name>-custom`).
    public static let legacyShippedContentHashes: Set<String> = [
        "f3fbf8a16403fce2",  // 2026-07-09 initial revision (pre worker_tools)
        "800f30b972f29840"   // 2026-07-09 worker_tools revision (pre worker_activity, pre built-in model)
    ]

    /// One-time migration of registries written by the old seed-to-disk mechanism.
    /// Pristine shipped copies are deleted (the built-in supplies them, always
    /// current); user-EDITED copies are preserved as `<name>-custom` so nothing the
    /// user wrote is ever lost — they just stop shadowing the built-in. Undecodable
    /// files are left alone; the registry surfaces those as visible load failures.
    public static func migrateLegacySeededBuiltIns(in directory: URL, legacyHashes: Set<String> = legacyShippedContentHashes) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for builtIn in builtInDefinitions {
            let legacyFile = directory.appendingPathComponent("\(builtIn.name).json")
            guard fileManager.fileExists(atPath: legacyFile.path),
                  let data = try? Data(contentsOf: legacyFile),
                  let existing = try? JSONDecoder().decode(EvaluatorDefinition.self, from: data) else { continue }
            if legacyHashes.contains(existing.contentHash) || existing.contentHash == builtIn.contentHash {
                try? fileManager.removeItem(at: legacyFile)
                continue
            }
            // User-edited: preserve under a non-shadowing name.
            let customized = existing.renamed(to: "\(builtIn.name)-custom")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let customizedData = try? encoder.encode(customized) {
                let customFile = directory.appendingPathComponent("\(customized.name).json")
                guard !fileManager.fileExists(atPath: customFile.path) else { continue }
                try? customizedData.write(to: customFile, options: .atomic)
                try? fileManager.removeItem(at: legacyFile)
            }
        }
    }
}

extension OrchestrationRuntime {

    // MARK: - Entry points

    /// One-line-per-validator summary baked into `set_acceptance_criteria`'s description
    /// at Smith's spawn, or nil when no registry is configured. A snapshot by design —
    /// `list_validators` is the live view.
    func validatorCatalogSummary() -> String? {
        guard let directory = evaluatorsDirectory else { return nil }
        let validators = EvaluatorRegistry.load(from: directory).definitions(ofKind: .validator)
        guard !validators.isEmpty else { return nil }
        return validators.map { "- `\($0.name)`: \($0.description)" }.joined(separator: "\n")
    }

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

        let settled = task.validation?.settledCriterionIDs() ?? []
        let pending = task.acceptanceCriteria.filter { !settled.contains($0.id) }
        guard !pending.isEmpty else {
            await completeValidatedTask(taskID: taskID)
            return
        }

        // Count settled AGAINST the current criteria — the raw ledger can hold records
        // for criteria that were since edited/removed ("4 of 3 settled").
        let settledOnTask = task.acceptanceCriteria.count - pending.count
        await channel.post(ChannelMessage(
            sender: .system,
            content: "Validating \"\(task.title)\" — round \(round): \(pending.count) criterion(s) to judge, \(settledOnTask) already settled.",
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
            // criteria aren't errors OR rejections; they just need the next round.
            // Bounded: the stall rule below terminates any non-progressing spin.
            await performTaskValidation(taskID: taskID)
        } else {
            // Rejections. Convergence is judged by PROGRESS, not an absolute round cap:
            // a 50-criterion task may take many rounds while settling more each time,
            // but consecutive rounds with nothing newly settled mean the worker and
            // validator disagree irreconcilably — the task FAILS. Exhaustion is never
            // Smith's judgment call.
            let progressed = records.contains { $0.verdict.isFinal }
            let stallRounds = await taskStore.updateValidationStall(id: taskID, progressed: progressed)
            if stallRounds >= maxValidationStallRounds {
                await failValidation(
                    taskID: taskID,
                    reason: "validation did not converge: \(stallRounds) consecutive round(s) with no newly accepted criterion — \(rejected.count) criterion(s) still rejected"
                )
            } else {
                await returnRejectionsToWorker(taskID: taskID, rejected: rejected, round: round)
            }
        }
    }

    /// Non-convergence outcome: the task FAILS — the result is not delivered, the
    /// worker is torn down, and Smith/user are informed. `run_task` retries reset the
    /// counters (sticky accepts survive), and Smith may fix the criteria first with
    /// `set_acceptance_criteria` if they were the problem.
    private func failValidation(taskID: UUID, reason: String) async {
        await taskStore.updateStatus(id: taskID, status: .failed)
        guard let task = await taskStore.task(id: taskID) else { return }
        await taskStore.addUpdate(id: taskID, message: "Task FAILED: \(reason).")
        for agentID in task.assigneeIDs {
            _ = await terminateAgent(id: agentID)
        }
        await channel.post(ChannelMessage(
            sender: .system,
            content: "Task \"\(task.title)\" FAILED acceptance validation: \(reason).",
            metadata: [
                "messageKind": .string("validation_failed"),
                "taskID": .string(taskID.uuidString),
                "isWarning": .bool(true)
            ]
        ))
        if let smithAgent = supervisor.firstHandle(role: .smith)?.agent {
            await smithAgent.appendUserMessage("""
                [System: Task "\(task.title)" (ID: \(taskID.uuidString)) FAILED acceptance validation — \(reason). \
                The result was NOT delivered. Tell the user briefly. If the acceptance criteria themselves were \
                too strict or ambiguous (read the rejection reasons in the task updates), fix them with \
                `set_acceptance_criteria`; a `run_task` retry resets the validation counters.]
                """)
        }
    }

    /// Hard ceiling on items a prepare function may emit for one criterion. Exceeding it
    /// is an ERROR, not a truncation — silently validating a subset could pass work that
    /// fails in the unexamined tail, which is the one thing a validator must never do.
    static let maxPrepareItems = 50

    /// Judges one criterion, retrying a first ERROR once (transient backends, parse
    /// flukes). A WAIVE against a non-waivable criterion is an ERROR — an
    /// author/validator disagreement escalates rather than silently passing or failing.
    private func judgeCriterion(
        _ criterion: AcceptanceCriterion,
        task: AgentTask,
        registry: EvaluatorRegistry,
        round: Int
    ) async -> CriterionVerdictRecord {
        if criterion.prepare != nil {
            return await judgeDynamicCriterion(criterion, task: task, registry: registry, round: round)
        }
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

        var (outcome, transcript) = await runValidator(definition, criterion: criterion, task: task)
        if case .error = outcome {
            validationLogger.notice("Criterion \(criterion.id.uuidString.prefix(8), privacy: .public) errored — retrying once")
            (outcome, transcript) = await runValidator(definition, criterion: criterion, task: task)
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
            round: round,
            renderedInput: Self.capDebugText(transcript.renderedInput, limit: Self.maxPersistedInputChars),
            responseLog: Self.capDebugText(transcript.turnLog.joined(separator: "\n---\n"), limit: Self.maxPersistedLogChars)
        )
    }

    /// Dynamic (prepare/map) judging: the prepare function emits a JSON array of items,
    /// each judged by the criterion's per-item validator with `{{item}}` bound. The
    /// criterion passes only when EVERY item passes; an empty item list is an automatic
    /// ACCEPT (the prepare determined nothing applies — the dynamic analogue of WAIVE).
    /// One `CriterionVerdictRecord` summarizes the whole map so the ledger shape is
    /// unchanged.
    private func judgeDynamicCriterion(
        _ criterion: AcceptanceCriterion,
        task: AgentTask,
        registry: EvaluatorRegistry,
        round: Int
    ) async -> CriterionVerdictRecord {
        // The accumulated debug log: the prepare exchange, then each item's exchange,
        // each under a labeled header. Persisted (capped) with the verdict record.
        var debugLog: [String] = []
        var prepareRenderedInput = ""

        func record(_ verdict: CriterionVerdictRecord.Verdict, validator: EvaluatorDefinition? = nil) -> CriterionVerdictRecord {
            CriterionVerdictRecord(
                criterionID: criterion.id,
                verdict: verdict,
                validatorName: validator?.name ?? (criterion.prepare ?? "-"),
                validatorHash: validator?.contentHash ?? "-",
                round: round,
                renderedInput: Self.capDebugText(prepareRenderedInput, limit: Self.maxPersistedInputChars),
                responseLog: Self.capDebugText(debugLog.joined(separator: "\n"), limit: Self.maxPersistedLogChars)
            )
        }

        // Resolve the prepare definition (pinned-body-first, like validators).
        guard let prepareName = criterion.prepare else {
            return record(.error(message: "judgeDynamicCriterion called without a prepare name"))
        }
        let prepareDefinition: EvaluatorDefinition
        if let pinned = (await taskStore.task(id: task.id))?.validation?.pinnedDefinitions[prepareName] {
            prepareDefinition = pinned
        } else if let loaded = registry.definition(named: prepareName), loaded.kind == .prepare {
            await taskStore.pinValidatorDefinition(id: task.id, definition: loaded)
            prepareDefinition = loaded
        } else {
            return record(.error(message: "prepare function '\(prepareName)' not found in the registry (or is not kind=prepare)"))
        }

        var (prepareOutcome, prepareTranscript) = await runValidator(prepareDefinition, criterion: criterion, task: task)
        if case .error = prepareOutcome {
            (prepareOutcome, prepareTranscript) = await runValidator(prepareDefinition, criterion: criterion, task: task)
        }
        prepareRenderedInput = prepareTranscript.renderedInput
        debugLog.append("## prepare: \(prepareName)\n" + prepareTranscript.turnLog.joined(separator: "\n---\n"))

        let items: [String]
        switch prepareOutcome {
        case .items(let raw):
            // Already rendered by the runner: string elements unwrapped, objects as
            // compact JSON fragments — bound to {{item}} verbatim.
            items = raw
        case .verdict(let token, _):
            return record(.error(message: "prepare '\(prepareName)' returned verdict '\(token)' where a JSON array was required"), validator: prepareDefinition)
        case .error(let message):
            return record(.error(message: "prepare '\(prepareName)' failed: \(message)"), validator: prepareDefinition)
        }

        guard items.count <= Self.maxPrepareItems else {
            return record(.error(message: "prepare '\(prepareName)' emitted \(items.count) items (cap \(Self.maxPrepareItems)) — narrow the prepare or split the criterion"), validator: prepareDefinition)
        }
        guard !items.isEmpty else {
            return record(.accepted, validator: prepareDefinition)
        }

        let resolution = await resolveValidator(for: criterion, taskID: task.id, registry: registry)
        let perItemDefinition: EvaluatorDefinition
        switch resolution {
        case .success(let resolved):
            perItemDefinition = resolved
        case .failure(let problem):
            return record(.error(message: problem))
        }

        // Items run sequentially: this criterion is already inside the round's parallel
        // wave, and nesting another fan-out would multiply concurrent LLM calls past
        // what providers tolerate.
        var rejections: [String] = []
        var waives: [String] = []
        for (index, item) in items.enumerated() {
            var (outcome, transcript) = await runValidator(perItemDefinition, criterion: criterion, task: task, extraSlots: ["item": item])
            if case .error = outcome {
                (outcome, transcript) = await runValidator(perItemDefinition, criterion: criterion, task: task, extraSlots: ["item": item])
            }
            debugLog.append("## item \(index + 1): \(item.prefix(120))\n" + transcript.turnLog.joined(separator: "\n---\n"))
            switch outcome {
            case .verdict("ACCEPT", _):
                continue
            case .verdict("REJECT", let reason):
                rejections.append("item \(index + 1) (\(item)): \(reason ?? "no reason given")")
            case .verdict("WAIVE", let reason):
                if criterion.waivable {
                    waives.append("item \(index + 1) (\(item)): \(reason ?? "")")
                } else {
                    return record(.error(message: "validator attempted to WAIVE item \(index + 1) (\(item)) of a non-waivable criterion"), validator: perItemDefinition)
                }
            case .verdict(let token, let reason):
                return record(.error(message: "unexpected verdict token '\(token)' on item \(index + 1) (\(reason ?? ""))"), validator: perItemDefinition)
            case .items:
                return record(.error(message: "per-item validator returned items where a verdict was required"), validator: perItemDefinition)
            case .error(let message):
                return record(.error(message: "item \(index + 1) (\(item)): \(message)"), validator: perItemDefinition)
            }
        }

        if !rejections.isEmpty {
            return record(.rejected(reason: "\(rejections.count) of \(items.count) item(s) failed:\n" + rejections.joined(separator: "\n")), validator: perItemDefinition)
        }
        if waives.count == items.count {
            return record(.waived(reason: "all \(items.count) item(s) waived:\n" + waives.joined(separator: "\n")), validator: perItemDefinition)
        }
        return record(.accepted, validator: perItemDefinition)
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

    /// Caps for the debugging fields persisted on each verdict record — big enough to
    /// diagnose any verdict, small enough that tasks.json doesn't balloon.
    static let maxPersistedInputChars = 20_000
    static let maxPersistedLogChars = 12_000

    static func capDebugText(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : text.prefix(limit) + "\n…[truncated \(text.count - limit) chars]"
    }

    private func runValidator(
        _ definition: EvaluatorDefinition,
        criterion: AcceptanceCriterion,
        task: AgentTask,
        extraSlots: [String: String] = [:]
    ) async -> (outcome: EvaluationRunner.Outcome, transcript: EvaluationRunner.Transcript) {
        guard let resolved = providerForModelSlot(definition.modelSlot) else {
            return (.error("no model configured for slot '\(definition.modelSlot.rawValue)'"), EvaluationRunner.Transcript())
        }
        let (provider, config, usageRole, providerTypeRawValue) = resolved
        let previousVerdict = (task.validation?.latestVerdict(for: criterion.id)).map(Self.describeVerdict) ?? "none"
        var slots: [String: String] = [
            "task_id": task.id.uuidString,
            "task_title": task.title,
            "task_description": task.description,
            "worker_tools": workerToolsDescription(for: task),
            "worker_activity": await workerActivityDigest(for: task),
            "steps": Self.renderSteps(task.steps),
            "recent_updates": task.updates.suffix(10).map { "- \($0.message)" }.joined(separator: "\n"),
            "result": task.result ?? "(none submitted)",
            "commentary": task.commentary ?? "(none)",
            "criterion": criterion.text,
            "previous_verdict": previousVerdict
        ]
        slots.merge(extraSlots) { _, extra in extra }
        let tools = Self.evidenceTools(named: definition.toolNames)
        let evaluationContext = makeToolContext(agentID: UUID(), role: .securityAgent)
        let sessionID = currentSessionID
        let usageStore = usageStore
        return await EvaluationRunner.runCapturing(
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

    /// The worker's tool names for the validator's context — the LIVE worker's actual
    /// (scoped) set when one exists, else the standard worker toolset. Validators never
    /// share the worker's tools; without this list they misjudge feasibility by their
    /// own read-only kit ("the gh CLI is not available in this environment").
    private func workerToolsDescription(for task: AgentTask) -> String {
        if let liveWorker = liveWorkerHandle(for: task) {
            return liveWorker.agent.toolNames.joined(separator: ", ")
        }
        return BrownBehavior.toolNames.joined(separator: ", ")
            + " (standard worker toolset; the worker may also have had MCP-provided tools)"
    }

    /// A bounded, SYSTEM-OBSERVED digest of the worker's tool calls and results, from
    /// the live worker's LLM turn records. This is the validator's ground truth for
    /// "did the worker actually run what it claims" — without it, validators reject
    /// legitimate work as unverifiable ("no gh tool calls are present in the evidence",
    /// observed 2026-07-09). Most recent activity wins the size cap.
    private func workerActivityDigest(for task: AgentTask) async -> String {
        guard let worker = liveWorkerHandle(for: task) else {
            return "(worker no longer running — tool activity log unavailable)"
        }
        let turns = await worker.agent.turnsSnapshot()
        var lines: [String] = []
        for turn in turns {
            // Tool RESULTS arrive in the next turn's input delta; rendering both sides
            // in turn order keeps call → result adjacency close enough for judging.
            for message in turn.inputDelta {
                if case .toolResult(_, let content) = message.content {
                    lines.append("   ↳ \(content.prefix(220))")
                }
            }
            for call in turn.response.toolCalls {
                lines.append("→ \(call.name)(\(call.arguments.prefix(220)))")
            }
        }
        guard !lines.isEmpty else { return "(no tool calls recorded this session)" }
        // Keep the most recent activity when capped.
        var digest = ""
        for line in lines.reversed() {
            let candidate = line + "\n" + digest
            if candidate.count > 8_000 { break }
            digest = candidate
        }
        return digest.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Secure the worker BEFORE mutating the task. The old order (set .running,
        // clear result, THEN spawn) crashed live 2026-07-09: the spawn was refused at
        // worker capacity, the fallback escalated to .awaitingReview with the result
        // already cleared, and TaskStore's awaitingReview-requires-result invariant
        // (correctly) refused the transition with a fatal assertion.
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
            // No worker and no free slot: re-queue as pending — the auto-run drain
            // restarts it when a slot frees, and the fresh worker's briefing carries
            // the punch list via the task updates recorded below.
            await taskStore.addUpdate(id: taskID, message: "Validation rejected \(rejected.count) criterion(s); no worker slot was free for the rework, so the task is re-queued:\n\(punchList)")
            // Status first, then clear: a `.pending` task with a stale result is
            // consistent; a `.validating` task with no result is the invariant-violating
            // shape observers must never see (agy review finding).
            await taskStore.updateStatus(id: taskID, status: .pending)
            await taskStore.clearResult(id: taskID)
            await channel.post(ChannelMessage(
                sender: .system,
                content: "Task \"\(task.title)\" needs rework (validation rejected \(rejected.count) criterion(s)) but all worker slots are busy — re-queued; it will restart when a slot frees.",
                metadata: [
                    "messageKind": .string("task_queued_at_capacity"),
                    "taskID": .string(taskID.uuidString)
                ]
            ))
            return
        }

        await taskStore.updateStatus(id: taskID, status: .running)
        await taskStore.clearResult(id: taskID)

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
        // Tell the WORKER too — without this it never learns the last round's outcome
        // (punch lists stop at escalation) and flails: re-reasoning about old
        // rejections, calling request_help into an already-parked task. A distinct
        // messageKind — the worker's filter drops "validation_escalation" (the public
        // banner), and this private notice must get through.
        if let workerID = task.assigneeIDs.first(where: { supervisor.role(of: $0) == .brown }) {
            await channel.post(ChannelMessage(
                sender: .system,
                recipientID: workerID,
                recipient: .agent(.brown),
                content: """
                    [Acceptance validation has ESCALATED your task to Smith: \(reason)] \
                    Do NOT resubmit, rework anything, or call request_help — the task is already \
                    in Smith's hands. STOP and wait: Smith will either accept the work as-is or \
                    send you specific changes.
                    """,
                metadata: [
                    "messageKind": .string("validation_wait_notice"),
                    "taskID": .string(taskID.uuidString)
                ]
            ))
        }
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
