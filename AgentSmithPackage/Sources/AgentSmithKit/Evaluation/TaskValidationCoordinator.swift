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
    /// by editing the JSON once one is configured). The system prompt here is the JUDGING
    /// stance only — the input-format description, the criterion, and the response-format
    /// contract are supplied by `composeValidatorSystemPrompt` at judge time.
    public static let defaultDefinition = EvaluatorDefinition(
        name: "default",
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
            have asked.
            """,
        outputGrammar: .verdictLine(allowed: [
            .init(token: "ACCEPT", requiresReason: false),
            .init(token: "REJECT", requiresReason: true),
            .init(token: "WAIVE", requiresReason: true)
        ]),
        modelSlot: .validator,
        toolNames: EvaluatorDefaults.validatorEvidenceToolNames,
        maxTurns: 10,
        timeoutSeconds: 300,
        maxOutputTokens: 2000
    )

    /// The read-only evidence quartet — the capability ceiling for inline/Smith-authored
    /// validators, and the default toolset for shipped ones.
    public static let validatorEvidenceToolNames = ["file_read", "directory_listing", "grep", "glob", "attach_file"]

    /// A human-readable authoring refusal, surfaced verbatim to the authoring tool.
    public struct AuthoringError: Error, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Builds a Smith-authored definition from just a name, description, kind, and the
    /// authored prompt. The SYSTEM supplies the contract — output grammar (verdict line
    /// for validators, JSON array for prepare), the JSON input format, the criterion
    /// placement, the read-only evidence toolset, and conservative limits (all applied by
    /// `composeValidatorSystemPrompt` at judge time) — so an authored evaluator can judge
    /// however it likes but cannot grant itself capabilities or break the parse loop. The
    /// authored prompt is stored RAW: the judging stance only, no output-format text.
    public static func makeCustomDefinition(
        name: String,
        description: String,
        kind: EvaluatorDefinition.Kind,
        authoredPrompt: String
    ) -> Result<EvaluatorDefinition, AuthoringError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else {
            return .failure(AuthoringError("name must be non-empty kebab-case (lowercase letters, digits, hyphens), e.g. 'accessibility-check'"))
        }
        guard kind == .validator || kind == .prepare else {
            return .failure(AuthoringError("only 'validator' and 'prepare' definitions can be authored — approver/scoper are system-reserved"))
        }
        let trimmedPrompt = authoredPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return .failure(AuthoringError("the authored prompt must be non-empty"))
        }
        let grammar: EvaluatorDefinition.OutputGrammar = kind == .validator
            ? .verdictLine(allowed: [
                .init(token: "ACCEPT", requiresReason: false),
                .init(token: "REJECT", requiresReason: true),
                .init(token: "WAIVE", requiresReason: true)
              ])
            : .jsonArray

        return .success(EvaluatorDefinition(
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            systemPrompt: trimmedPrompt,
            outputGrammar: grammar,
            modelSlot: .validator,
            toolNames: validatorEvidenceToolNames,
            maxTurns: 10,
            timeoutSeconds: 300,
            maxOutputTokens: 2000
        ))
    }

    /// The definitions the app itself provides. NOT stored in the user's registry
    /// directory and NOT editable — the app always supplies the current version. To
    /// customize one, duplicate its JSON (from the pinned body on any task, or
    /// `list_validators`) under a NEW name in the evaluators directory and edit that.
    public static var builtInDefinitions: [EvaluatorDefinition] {
        [defaultDefinition]
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

    /// Persists a Smith-authored definition into the session's registry directory.
    /// Returns nil on success, or a human-readable refusal: built-in names are
    /// reserved, invalid definitions never land on disk, and an existing name is only
    /// replaced when `overwrite` says so (protects user-authored files from silent
    /// clobbering).
    func saveEvaluatorDefinition(_ definition: EvaluatorDefinition, overwrite: Bool) -> String? {
        guard let directory = evaluatorsDirectory else {
            return "no evaluator registry is configured for this session"
        }
        guard !EvaluatorDefaults.builtInNames.contains(definition.name) else {
            return "'\(definition.name)' is a built-in definition name — pick a different name"
        }
        let problems = definition.validationProblems()
        guard problems.isEmpty else {
            return "definition is invalid: \(problems.joined(separator: "; "))"
        }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("\(definition.name).json")
        if fileManager.fileExists(atPath: target.path) && !overwrite {
            return "a definition named '\(definition.name)' already exists — pass overwrite: true to replace it, or pick a new name"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(definition)
            try data.write(to: target, options: .atomic)
            return nil
        } catch {
            return "could not write the definition: \(error.localizedDescription)"
        }
    }

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
        validationTasks[taskID] = Task { [weak self] in
            await self?.performTaskValidation(taskID: taskID)
            await self?.finishTaskValidation(taskID: taskID)
        }
    }

    /// Cancels an in-flight validation for a task (pause/stop path). The run bails at the
    /// EvaluationRunner's cancellation check; its transitions are CAS-guarded, so it can't
    /// clobber the new status even if it's mid-flight.
    func cancelTaskValidation(taskID: UUID) {
        validationTasks[taskID]?.cancel()
    }

    private func finishTaskValidation(taskID: UUID) async {
        tasksBeingValidated.remove(taskID)
        validationTasks[taskID] = nil
        // A resubmission landing while this run was finishing gets its start call
        // swallowed by the reentrancy guard — re-check on the way out so the task can't
        // strand in `.validating`. Abort/stop paths intentionally leave that status for
        // the cold-boot re-enqueue, so they must not respin here.
        guard !aborted, !stopRequested, !Task.isCancelled else { return }
        if let task = await taskStore.task(id: taskID), task.status == .validating {
            startTaskValidation(taskID: taskID)
        }
    }

    // MARK: - The round

    private func performTaskValidation(taskID: UUID) async {
        guard !aborted, !stopRequested, !Task.isCancelled else { return }
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
                validator: .registry(EvaluatorDefaults.defaultDefinition.name)
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
            content: "Validating \"\(task.title)\": \(pending.count) criterion(s) to judge, \(settledOnTask) already settled.",
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

        // Record against the snapshot we judged; any criterion whose contract changed mid-round is
        // dropped atomically inside the store, so `recorded` is what actually landed in the ledger.
        let recorded = await taskStore.recordCriterionVerdicts(id: taskID, records: records, judgedAgainst: taskSnapshot.acceptanceCriteria)
        await postRoundSummary(taskID: taskID, records: recorded)

        guard !aborted, !stopRequested, !Task.isCancelled else { return }
        guard let judged = await taskStore.task(id: taskID), judged.status == .validating else { return }
        // If a `set_acceptance_criteria` edit landed at a suspension point in this round, it reset
        // the round counter to 0 and granted the edited contract a fresh convergence budget. Acting
        // on this now-stale outcome would consume a round of that fresh budget against a contract we
        // didn't judge. Bail; the next round judges the new contract cleanly.
        guard (judged.validation?.round ?? 0) == round else { return }
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
            // Measure progress by what actually LANDED in the ledger (`recorded`), not the raw
            // `records` we produced — a verdict dropped by the store's contract-match filter (its
            // criterion was edited mid-round) didn't settle anything, so counting it would wrongly
            // reset the stall counter and let a non-converging task spin.
            let progressed = recorded.contains { $0.verdict.isFinal }
            let stallRounds = await taskStore.updateValidationStall(id: taskID, progressed: progressed)
            if stallRounds >= maxConsecutiveValidationRoundsWithoutProgress {
                await failValidation(
                    taskID: taskID,
                    stallRounds: stallRounds,
                    stillRejected: rejected.count
                )
            } else {
                await returnRejectionsToWorker(taskID: taskID, rejected: rejected)
            }
        }
    }

    /// Non-convergence outcome: the task FAILS — the result is not delivered, the
    /// worker is torn down, and Smith/user are informed. `run_task` retries reset the
    /// counters (sticky accepts survive), and Smith may fix the criteria first with
    /// `set_acceptance_criteria` if they were the problem.
    private func failValidation(taskID: UUID, stallRounds: Int, stillRejected: Int) async {
        // CAS: only fail if still validating — never overwrite a pause/stop that landed
        // after the coordinator's status snapshot.
        guard await taskStore.updateStatus(id: taskID, to: .failed, ifCurrentlyIn: [.validating]) else { return }
        guard let task = await taskStore.task(id: taskID) else { return }
        let reason = "No progress was made toward clearing any acceptance criterion for \(stallRounds) rounds in a row — \(stillRejected) criterion(s) still rejected."
        await taskStore.addUpdate(id: taskID, message: "Task FAILED validation: \(reason)")
        for agentID in task.assigneeIDs {
            _ = await terminateAgent(id: agentID)
        }
        // Reclaim the ephemeral scratch dir; the persistent evidence dir stays for review/retry.
        taskWorkspace(for: taskID).cleanupTemporary()
        await channel.post(ChannelMessage(
            sender: .system,
            content: "Task \"\(task.title)\" FAILED acceptance validation. \(reason)",
            metadata: [
                "messageKind": .string("validation_failed"),
                "taskID": .string(taskID.uuidString),
                "isWarning": .bool(true)
            ]
        ))
        if let smithAgent = supervisor.firstHandle(role: .smith)?.agent {
            await smithAgent.appendUserMessage("""
                [System: Task "\(task.title)" (ID: \(taskID.uuidString)) FAILED acceptance validation. \(reason) \
                The result was NOT delivered. Tell the user briefly. Then decide WHY it stalled by reading the \
                rejection reasons in the task updates: if the criteria themselves were too strict, ambiguous, or \
                demanded evidence the worker's tools cannot produce, fix them with `set_acceptance_criteria` before \
                retrying; if the worker simply kept resubmitting incomplete work, a `run_task` retry (which resets \
                the validation counters) with clearer instructions may be enough. Do NOT re-run it unchanged and \
                expect a different outcome.]
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
            renderedSystemPrompt: Self.capDebugText(transcript.renderedSystemPrompt, limit: Self.maxPersistedInputChars),
            responseLog: Self.capDebugText(transcript.turnLog.joined(separator: "\n---\n"), limit: Self.maxPersistedLogChars)
        )
    }

    /// Dynamic (prepare/map) judging: the prepare function emits a JSON array of items,
    /// each judged by the criterion's per-item validator with `{{item}}` bound. The
    /// criterion passes only when EVERY item passes; an empty item list is the dynamic
    /// analogue of WAIVE — honored as a pass ONLY when the criterion is waivable, and
    /// otherwise escalated as an ERROR (an over-narrow / hallucinated-empty prepare must
    /// not silently pass an unexamined requirement). One `CriterionVerdictRecord`
    /// summarizes the whole map so the ledger shape is unchanged.
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
            // An empty enumeration is the dynamic analogue of "nothing to check". Honor it as a pass
            // only when the criterion is WAIVABLE (mirroring the static WAIVE gate ~line 445);
            // otherwise a misfiring / over-narrow / hallucinated-empty prepare would silently pass an
            // unexamined requirement, so escalate as an ERROR rather than auto-accepting.
            if criterion.waivable {
                return record(.waived(reason: "prepare '\(prepareName)' enumerated no items"), validator: prepareDefinition)
            }
            return record(.error(message: "prepare '\(prepareName)' enumerated no items for a non-waivable criterion — cannot confirm the requirement"), validator: prepareDefinition)
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
                effectiveName = EvaluatorDefaults.defaultDefinition.name
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
        let provider = resolved.provider
        let config = resolved.config
        let usageRole = resolved.usageRole
        let providerTypeRawValue = resolved.providerTypeRaw
        let validatorSupportsVision = resolved.supportsVision
        let validatorSupportsDocuments = resolved.supportsDocuments

        // The evidence is delivered as a labeled JSON object and the criterion lives in the
        // system prompt. Keeping the two apart is deliberate: when both shared one undelimited
        // markdown blob, weak judge models confused the worker's result with the rubric — a
        // task whose result format was itself verdict-like got rejected for "not beginning with
        // ACCEPT/REJECT/WAIVE" (the validator's OWN output rule bleeding onto the worker).
        // No prior verdict is included on purpose: showing the validator its last answer
        // anchors it to that answer instead of re-judging the (changed) evidence fresh.
        var fields: [String: String] = [
            "resultsToEvaluate": task.result ?? "(none submitted)",
            "taskTitle": task.title,
            "taskDescription": task.description,
            "taskUpdateHistory": task.updates.suffix(10).map { "- \($0.message)" }.joined(separator: "\n"),
            "commentary": task.commentary ?? "(none)",
            "workerTools": workerToolsDescription(for: task),
            "workerActivity": await workerActivityDigest(for: task),
            "workerSteps": Self.renderSteps(task.steps)
        ]
        // The worker's evidence directory: a criterion may reference an evidence file by name, and
        // the validator resolves it here with `file_read`/`directory_listing`.
        if let evidenceDir = taskWorkspace(for: task.id).evidenceDirectory {
            fields["evidenceDirectory"] = evidenceDir.path
        }
        // Structured deliverables (Phase B): the worker's tagged text/attachment items. Rendered
        // with each item's routing tags and, for attachments, a file:// path the validator can
        // pass to `attach_file` to actually SEE an image or read a file. Tags are hints — the
        // validator still judges the whole result — but they say which items are for which
        // requirement.
        let deliverables = Self.renderDeliverables(task.resultItems, urlProvider: attachmentURLProviderClosure)
        if !deliverables.isEmpty {
            fields["structuredDeliverables"] = deliverables
        }
        if let item = extraSlots["item"] {
            fields["itemToEvaluate"] = item
        }
        let userMessage = Self.validatorPayloadJSON(fields)
        let systemPrompt = Self.composeValidatorSystemPrompt(
            definition: definition,
            criterion: criterion,
            hasItem: extraSlots["item"] != nil
        )
        let tools = Self.evidenceTools(named: definition.toolNames)
        // Own the attach_file staging buffer so the validator can pull an evidence image into its
        // own context; the runner drains it into a user turn after each tool round.
        let stagingBuffer = StagedAttachmentBuffer()
        let evaluationContext = makeToolContext(
            agentID: UUID(),
            role: .securityAgent,
            attachmentStageOverride: { attachments, _ in await stagingBuffer.stage(attachments) }
        )
        let sessionID = currentSessionID
        let usageStore = usageStore
        // Route each validator tool call through the shared Security Agent evaluator (auto-approved
        // for read-only evidence tools — no LLM). A central choke point, tightenable later, so these
        // reads are never off the security path. Nil when no Security Agent provider is configured;
        // then reads execute directly, exactly as before.
        let securityGate: (@Sendable (LLMToolCall, any AgentTool) async -> Bool)?
        if let evaluator = validationSecurityEvaluator {
            let gateTaskTitle = task.title
            let gateTaskID = task.id.uuidString
            let gateTaskDescription = task.description
            let gateChannel = channel
            securityGate = { (call: LLMToolCall, tool: any AgentTool) async -> Bool in
                // Surface the validator's tool call in the transcript before it runs, so acceptance
                // validators' evidence reads aren't invisible.
                await gateChannel.post(ChannelMessage(
                    sender: .validator,
                    content: "\(call.name): \(call.arguments.prefix(160))",
                    metadata: [
                        "messageKind": .string("tool_request"),
                        "requestID": .string(call.id),
                        "tool": .string(call.name),
                        "params": .string(call.arguments)
                    ]
                ))
                let disposition = await evaluator.evaluate(
                    toolName: call.name,
                    toolParams: call.arguments,
                    toolDescription: tool.definition(for: .securityAgent).description,
                    toolParameterDefs: "",
                    taskTitle: gateTaskTitle,
                    taskID: gateTaskID,
                    taskDescription: gateTaskDescription,
                    siblingCalls: nil,
                    agentRoleName: "Acceptance validator",
                    readOnlyAutoApproveEligible: true,
                    toolCallID: call.id
                )
                // Surface the verdict on the SAME path as an agent's tool call — the shared
                // review poster — so a validator's auto-approved evidence read gets the same
                // ✅/verdict treatment (collapsed into its tool_request chip by requestID).
                await AgentActor.postSecurityReviewToChannel(
                    disposition: disposition,
                    callID: call.id,
                    roleName: "Validator",
                    agentRoleValue: nil,
                    post: { await gateChannel.post($0) }
                )
                return disposition.approved
            }
        } else {
            securityGate = nil
        }
        return await EvaluationRunner.runMessages(
            definition: definition,
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            provider: provider,
            tools: tools,
            toolContext: evaluationContext,
            temperature: 0,
            modelSupportsVision: validatorSupportsVision,
            modelSupportsDocuments: validatorSupportsDocuments,
            drainStagedAttachments: { await stagingBuffer.drain() },
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
            },
            securityGate: securityGate
        )
    }

    /// Serializes the evidence fields as a pretty-printed JSON object. Sorted keys keep the
    /// payload deterministic (stable across runs, diffable in the persisted transcript);
    /// the system prompt names `resultsToEvaluate` as the focus, so field order carries no
    /// meaning. JSON encoding is what makes the delivery robust: a result containing quotes,
    /// braces, or newlines can't leak out of its field and be mistaken for structure.
    static func validatorPayloadJSON(_ fields: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Builds the validator's system prompt: the definition's judging stance, a description
    /// of the JSON input's fields, the ONE criterion, and the response contract. The criterion
    /// lives here (not in the user message) so it reads as an instruction, and the SYSTEM —
    /// not the authored/default prompt — owns the output format: for validators that means an
    /// explicit firewall (ACCEPT/REJECT/WAIVE is the VALIDATOR's format, never a requirement
    /// on the worker's result) and offering WAIVE only when the criterion is `waivable`; for
    /// prepare functions it means the JSON-array enumeration contract.
    static func composeValidatorSystemPrompt(
        definition: EvaluatorDefinition,
        criterion: AcceptanceCriterion,
        hasItem: Bool
    ) -> String {
        var prompt = definition.systemPrompt
        prompt += """


            ## Input format
            The user message is a single JSON object whose values are all strings:
            - `resultsToEvaluate` — the worker's submitted result. THIS is the primary thing you evaluate.
            - `taskTitle`, `taskDescription` — what the task asked for (context).
            - `taskUpdateHistory` — the worker's own progress notes (context).
            - `commentary` — the worker's closing notes on the result (context).
            - `workerTools` — the worker's capabilities, which differ from yours (context).
            - `workerActivity` — the SYSTEM-OBSERVED tool-call log; trust it over narrative claims.
            - `workerSteps` — the worker's plan with statuses and tombstones.
            - `evidenceDirectory` — (when present) the folder the worker was told to place evidence \
            artifacts in. If a criterion names an evidence file, read it from here with `file_read`, or \
            list the folder with `directory_listing`.
            - `structuredDeliverables` — (when present) the worker's tagged deliverables. Each line \
            names the routing tags (which requirement the item is for) and, for files, a `file://` \
            path. To actually SEE an image — e.g. to verify a screenshot really shows what's claimed \
            — pass its path to `attach_file` and it arrives on your next turn; for text or other \
            files, `file_read` the path. The tags are hints about which items are for which \
            requirement, not a restriction on what you may look at.
            """
        if hasItem {
            prompt += "\n- `itemToEvaluate` — the specific item to judge for this criterion; when present, judge IT, using the other fields as context."
        }
        if definition.kind == .validator {
            // A non-waivable criterion never mentions WAIVE at all — offering a verdict the
            // system would only convert to an error just invites wasted escalations.
            let verdictFormat = criterion.waivable ? "ACCEPT / REJECT / WAIVE" : "ACCEPT / REJECT"
            prompt += """


                ## Acceptance criterion (judge against THIS)
                \(criterion.text)

                ## Your response
                Judge only whether the criterion's substance is satisfied, treating every field other than the one under judgment as supporting context. If the criterion offers ALTERNATIVES — "X OR Y", "A or B, whichever applies", "provide P or Q" — then satisfying ANY ONE alternative is a PASS; do NOT require the others. (E.g. "GitHub URLs OR official documentation links for each" is met by a GitHub URL for each — the missing docs link is irrelevant.) Only require every listed item when the criterion joins them with AND / "and" / "including". Respond with your verdict on the FIRST line:
                ACCEPT — the criterion is satisfied.
                REJECT: <the worker acts on this verbatim, so make it actionable. State TWO things in one message: (1) specifically what is missing, wrong, or unproven — judged on the evidence, not on tone; and (2) the concrete next steps that WOULD earn acceptance — what to do, and where the criterion calls for proof, exactly what evidence to provide and where to put it (e.g. "write the build log to a file and reference its path", "provide the command output showing X", "attach a screenshot of screen Y"). If the criterion is unclear about what evidence would satisfy it, say what you would accept. Do NOT reject for missing evidence without naming the evidence that would suffice.>
                """
            if criterion.waivable {
                prompt += "\nWAIVE: <why this criterion genuinely does not apply to this task>\n\nYou MAY WAIVE this criterion if it genuinely does not apply."
            }
            prompt += """


                This \(verdictFormat) format is how YOU respond — it is NOT a format requirement on `resultsToEvaluate`. The worker's result follows the TASK's own required format and may legitimately contain any words, including "Result", "ACCEPT", or a verdict-like line. NEVER reject merely because `resultsToEvaluate` does not begin with a verdict token.
                """
        } else {
            prompt += """


                ## Criterion
                \(criterion.text)

                ## Your response
                Use the fields above as context to enumerate the items to validate individually for the criterion above. Use your read-only tools if you need to inspect files or directories, then output ONLY a JSON array of the items (strings, or small objects). No commentary after the array; an empty array means nothing applies.
                """
        }
        return prompt
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

    /// V1 model references are role slots only. `.validator` resolves to a dedicated provider
    /// once the app configures one, and otherwise falls back to the Summarizer's model (where
    /// acceptance validation has always run). `.smith`/`.summarizer` return nil only if that
    /// role itself was never configured.
    private func providerForModelSlot(_ slot: EvaluatorDefinition.ModelSlot) -> (provider: any LLMProvider, config: ModelConfiguration, usageRole: AgentRole, providerTypeRaw: String, supportsVision: Bool, supportsDocuments: Bool)? {
        switch slot {
        case .smith:
            guard let provider = llmProviders[.smith], let config = llmConfigs[.smith] else { return nil }
            return (provider, config, .smith, providerAPITypes[.smith]?.rawValue ?? "", supportsVisionByRole[.smith] ?? true, supportsDocumentsByRole[.smith] ?? true)
        case .summarizer:
            guard let provider = llmProviders[.summarizer], let config = llmConfigs[.summarizer] else { return nil }
            return (provider, config, .summarizer, providerAPITypes[.summarizer]?.rawValue ?? "", supportsVisionByRole[.summarizer] ?? true, supportsDocumentsByRole[.summarizer] ?? true)
        case .validator:
            // Attributed to .summarizer for usage until AgentRole gains a validator case (the
            // decode shims are in; the dictionary-key migration is deliberately staged).
            if let provider = validatorProvider, let config = validatorConfiguration {
                return (provider, config, .summarizer, validatorProviderAPIType?.rawValue ?? "", validatorSupportsVision ?? (supportsVisionByRole[.summarizer] ?? true), validatorSupportsDocuments ?? (supportsDocumentsByRole[.summarizer] ?? true))
            }
            // No dedicated validator model configured: fall back to the Summarizer's model,
            // which is where acceptance validation has always run.
            guard let provider = llmProviders[.summarizer], let config = llmConfigs[.summarizer] else { return nil }
            return (provider, config, .summarizer, providerAPITypes[.summarizer]?.rawValue ?? "", supportsVisionByRole[.summarizer] ?? true, supportsDocumentsByRole[.summarizer] ?? true)
        }
    }

    static func evidenceTools(named names: [String]) -> [any AgentTool] {
        let catalog: [String: any AgentTool] = [
            "file_read": FileReadTool(),
            "directory_listing": DirectoryListingTool(),
            "grep": GrepTool(),
            "glob": GlobTool(),
            "attach_file": AttachFileTool()
        ]
        return names.compactMap { catalog[$0] }
    }

    /// Renders a task's structured `resultItems` for the validator payload: one line per
    /// deliverable with its routing tags, inline text, and — for attachments — a `file://` path
    /// the validator can pass to `attach_file` to view an image or read a file.
    static func renderDeliverables(_ items: [ResultItem], urlProvider: (@Sendable (UUID, String) -> URL?)?) -> String {
        guard !items.isEmpty else { return "" }
        func ref(_ attachment: Attachment) -> String {
            let path = urlProvider?(attachment.id, attachment.filename).map { "file://" + $0.path(percentEncoded: false) } ?? "(no path)"
            return "\(attachment.filename) (\(attachment.mimeType), \(path), id=\(attachment.id.uuidString))"
        }
        var lines: [String] = []
        for (index, item) in items.enumerated() {
            let tags = item.refs.isEmpty ? "" : " [for: \(item.refs.joined(separator: ", "))]"
            switch item.content {
            case .text(let text):
                lines.append("- Deliverable \(index + 1)\(tags): \(text)")
            case .attachment(let attachment):
                lines.append("- Deliverable \(index + 1)\(tags): \(ref(attachment))")
            case .attachmentGroup(let attachments, let description):
                let header = description.map { " — \($0)" } ?? ""
                lines.append("- Deliverable \(index + 1)\(tags): \(attachments.count) file(s)\(header):")
                for attachment in attachments {
                    lines.append("    • \(ref(attachment))")
                }
            }
        }
        return lines.joined(separator: "\n")
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
        case .accepted: return "ACCEPT"
        case .rejected(let reason): return "REJECT — \(reason)"
        case .waived(let reason): return "WAIVE — \(reason)"
        case .error(let message): return "ERROR — \(message)"
        }
    }

    // MARK: - Outcomes

    private func postRoundSummary(taskID: UUID, records: [CriterionVerdictRecord]) async {
        guard let task = await taskStore.task(id: taskID) else { return }
        let criteriaByID = Dictionary(task.acceptanceCriteria.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let lines = records.map { record -> String in
            let text = criteriaByID[record.criterionID]?.text ?? record.criterionID.uuidString
            return "- \(text): \(Self.describeVerdict(record))"
        }
        let summary = "Validation results for \"\(task.title)\":\n" + lines.joined(separator: "\n")
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
        // CAS: only complete if still validating — a pause/stop that landed after the
        // coordinator's status snapshot must not be overwritten by this completion.
        guard await taskStore.updateStatus(id: taskID, to: .completed, ifCurrentlyIn: [.validating]) else { return }
        guard let completed = await taskStore.task(id: taskID) else { return }
        for agentID in completed.assigneeIDs {
            _ = await terminateAgent(id: agentID)
        }
        // Reclaim the ephemeral scratch dir; the persistent evidence dir stays.
        taskWorkspace(for: taskID).cleanupTemporary()
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
    private func returnRejectionsToWorker(taskID: UUID, rejected: [CriterionVerdictRecord]) async {
        guard let task = await taskStore.task(id: taskID) else { return }
        // Criterion NUMBER is its 1-based position in the acceptance list — the same number
        // the briefing and get_task_details use, so "Criterion 5" means the same thing everywhere.
        let numberByID = Dictionary(uniqueKeysWithValues: task.acceptanceCriteria.enumerated().map { ($0.element.id, $0.offset + 1) })
        let punchList = Self.formatRejectionPunchList(rejected: rejected, task: task, numberByID: numberByID)

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
            // CAS: a pause/stop that landed after our snapshot must not be re-queued.
            // Status first, then clear: a `.pending` task with a stale result is
            // consistent; a `.validating` task with no result is the invariant-violating
            // shape observers must never see (agy review finding).
            guard await taskStore.updateStatus(id: taskID, to: .pending, ifCurrentlyIn: [.validating]) else { return }
            await taskStore.clearResult(id: taskID)
            await taskStore.addUpdate(id: taskID, message: "Validation rejected \(rejected.count) criterion(s); no worker slot was free for the rework, so the task is re-queued:\n\(punchList)")
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

        // CAS: if a pause/stop landed after our snapshot, don't flip to .running — and if we
        // just spawned a worker for the rework, tear it back down so it doesn't orphan.
        guard await taskStore.updateStatus(id: taskID, to: .running, ifCurrentlyIn: [.validating]) else {
            if brownWasSpawned { _ = await terminateAgent(id: brownID) }
            return
        }
        await taskStore.clearResult(id: taskID)

        var parts: [String] = []
        if brownWasSpawned {
            parts.append("## Task: \(task.title)\n\n\(task.description)")
            if !task.updates.isEmpty {
                parts.append("## Prior Progress\n" + task.updates.map { "- \($0.message)" }.joined(separator: "\n"))
            }
        }
        let count = rejected.count
        let plural = count == 1 ? "criterion was" : "criteria were"
        parts.append("""
            ## Acceptance validation — changes required
            \(count) acceptance \(plural) rejected. Read each rejection below carefully — every one includes \
            what was missing and concrete next steps toward acceptance. For efficiency, address ALL of them \
            before you resubmit with `task_complete`; you MAY instead fix and resubmit one at a time if you \
            prefer. Criteria that already passed stay accepted — do not rework them. \
            **Do not resubmit unchanged: the same result gets the same rejection.** If a criterion demands \
            evidence you genuinely cannot produce with your tools, say so through `request_help` rather than \
            silently resubmitting.

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

    /// Renders the rejected criteria as a numbered punch list: one block per rejection,
    /// each carrying the criterion's stable number, its full text, and the validator's
    /// reason (which — per the validator prompt — states both what is missing and the
    /// concrete next steps toward acceptance). Ordered by criterion number so the list
    /// reads the same every round.
    static func formatRejectionPunchList(
        rejected: [CriterionVerdictRecord],
        task: AgentTask,
        numberByID: [UUID: Int]
    ) -> String {
        let criteriaByID = Dictionary(task.acceptanceCriteria.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = rejected.sorted { (numberByID[$0.criterionID] ?? .max) < (numberByID[$1.criterionID] ?? .max) }
        return ordered.enumerated().map { index, record -> String in
            let number = numberByID[record.criterionID]
            let label = number.map { "Criterion \($0)" } ?? "Criterion"
            let text = criteriaByID[record.criterionID]?.text ?? "(criterion no longer in the list)"
            var block = "### Rejection \(index + 1) — \(label)\n**Criterion:**\n\(text)"
            if case .rejected(let reason) = record.verdict {
                block += "\n\n**What's missing and how to satisfy it:**\n\(reason)"
            }
            return block
        }.joined(separator: "\n\n")
    }

    /// Escalation: the bounded loop failed to converge, a validator errored past retry,
    /// or validation isn't configured. The task parks in `.awaitingReview` — Smith's
    /// review_work becomes the resolution tool — and both Smith and the user are
    /// actively notified. Escalation must never be silent.
    private func escalateValidation(taskID: UUID, reason: String) async {
        // CAS: only escalate if still validating — never overwrite a pause/stop that landed
        // after the coordinator's status snapshot.
        guard await taskStore.updateStatus(id: taskID, to: .awaitingReview, ifCurrentlyIn: [.validating]) else { return }
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
        case .none: return EvaluatorDefaults.defaultDefinition.name
        }
    }
}
