import Foundation
import SwiftLLMKit

/// The outcome of reconciling a new memory against a similar existing one.
///
/// Only `merged` changes the existing memory; every other case saves the new memory separately.
/// They are kept distinct because only `different` is an affirmative judgment — a failed or
/// garbled judge must never be reported as one.
public enum MemoryReconciliation: Sendable, Equatable {
    /// The new memory duplicates or supersedes the existing one; here is the single
    /// reconciled text (newer info preferred on any conflict).
    case merged(String)
    /// The reconciler judged them distinct facts.
    case different
    /// The reconciler answered, but not with SAME or DIFFERENT first.
    case malformed(response: String)
    /// The reconciler answered SAME with no merged text.
    case emptyMerge
    /// The reconciler could not be consulted, or its call failed.
    case unavailable(errorDescription: String)
    /// The reconciliation was cancelled.
    case cancelled
}

/// One consolidation decision to put to the reconciler.
public struct MemoryReconciliationRequest: Sendable, Equatable {
    /// The existing memory's full content.
    public let existing: String
    /// The new memory's full content, as the agent proposed it.
    public let proposed: String
    /// Shared by every record of this consolidation attempt (candidate search, reconciler call,
    /// resulting mutation) so the inspector can link them.
    public let correlationID: UUID

    public init(existing: String, proposed: String, correlationID: UUID) {
        self.existing = existing
        self.proposed = proposed
        self.correlationID = correlationID
    }
}

/// Generates concise summaries of completed or failed tasks using a dedicated LLM call.
///
/// Follows the `SecurityEvaluator` pattern: standalone actor with its own `LLMProvider`,
/// focused prompt, and no tools. Each summary captures the problem, outcome, and approach
/// for semantic search retrieval.
actor TaskSummarizer {
    private let provider: any LLMProvider
    private let memoryStore: MemoryStore
    private let channel: MessageChannel
    private let contextWindowSize: Int
    private let maxOutputTokens: Int
    private let usageStore: UsageStore?
    /// Full snapshot of the ModelConfiguration used for summarization LLM calls.
    private let configuration: ModelConfiguration?
    /// Provider API type (e.g. "anthropic", "openAICompatible") — not on ModelConfiguration.
    private let providerType: String
    /// Session ID for the current orchestration run — stamped on every UsageRecord.
    private let sessionID: UUID?
    /// Bumps the live-activity counter while a summarization run is in flight (inspector strip).
    private let activityTracker: LiveActivityTracker?
    /// Fires after every provider call — task summary, memory reconciliation, or web extraction —
    /// with the exact request, so the inspector shows the same calls the Summarizer's session
    /// cost is made of.
    private var onLLMCallRecorded: (@Sendable (LLMCallEvent) -> Void)?

    private static let systemPrompt = """
        You are a task summarizer for an AI agent system. Given a completed or failed task's \
        details, produce a concise 2–4 sentence summary covering:

        1. The stated problem or goal
        2. What was accomplished (or why it failed)
        3. How it was accomplished (key approach, tools used, decisions made)
        4. A numbered list of steps of what happened

        Write in past tense. Be specific and factual. Include file names, tool names, or \
        technical details when relevant — these help with future search retrieval.

        Respond with ONLY the summary text. No headings or bullet points. Use numbered lists only for the step-by-step sequence.
        """

    public init(
        provider: any LLMProvider,
        memoryStore: MemoryStore,
        channel: MessageChannel,
        contextWindowSize: Int,
        maxOutputTokens: Int,
        usageStore: UsageStore? = nil,
        configuration: ModelConfiguration? = nil,
        providerType: String = "",
        sessionID: UUID? = nil,
        activityTracker: LiveActivityTracker? = nil
    ) {
        self.provider = provider
        self.memoryStore = memoryStore
        self.channel = channel
        self.contextWindowSize = contextWindowSize
        self.maxOutputTokens = maxOutputTokens
        self.usageStore = usageStore
        self.configuration = configuration
        self.providerType = providerType
        self.sessionID = sessionID
        self.activityTracker = activityTracker
    }

    /// Registers (or, with nil, clears) the provider-call observer.
    func setOnLLMCallRecorded(_ handler: (@Sendable (LLMCallEvent) -> Void)?) {
        onLLMCallRecorded = handler
    }

    /// The one path every Summarizer provider call takes: sends `messages`, records usage, and
    /// reports the call to the inspector — a turn carrying the exact request, or a failure record
    /// when the provider throws. `messages` is an immutable local, so the recorded request is the
    /// one sent even though this actor is re-entrant.
    private func sendRecorded(
        _ messages: [LLMMessage],
        annotation: LLMCallAnnotation
    ) async throws -> LLMResponse {
        let callStart = Date()
        let response: LLMResponse
        do {
            response = try await provider.send(messages: messages, tools: [])
        } catch {
            onLLMCallRecorded?(.failed(LLMCallFailureRecord(
                error: error,
                startedAt: callStart,
                modelID: configuration?.model ?? "",
                providerID: configuration?.providerID,
                annotation: annotation
            )))
            throw error
        }
        let callLatencyMs = Int(Date().timeIntervalSince(callStart) * 1000)

        if let usageStore {
            await UsageRecorder.record(
                response: response,
                context: LLMCallContext(
                    agentRole: .summarizer,
                    taskID: annotation.taskID,
                    modelID: configuration?.model ?? "",
                    providerType: providerType,
                    providerID: configuration?.providerID,
                    configuration: configuration,
                    sessionID: sessionID
                ),
                latencyMs: callLatencyMs,
                to: usageStore
            )
        }

        onLLMCallRecorded?(.completed(LLMTurnRecord(
            inputDelta: [],
            response: response,
            totalMessageCount: messages.count,
            contextSnapshot: messages,
            latencyMs: callLatencyMs,
            modelID: configuration?.model ?? "",
            providerType: providerType,
            providerID: configuration?.providerID,
            temperature: configuration?.temperature ?? 0,
            maxOutputTokens: configuration?.maxTokens ?? 0,
            thinkingBudget: configuration?.thinkingBudget,
            usage: response.usage,
            annotation: annotation,
            isSelfContainedRequest: true
        )))
        return response
    }

    /// Posts a channel message stamped with the summarizer's provider/model/config
    /// context. `taskID` can be passed for messages tied to a specific task.
    private func postToChannel(_ message: ChannelMessage, taskID: UUID? = nil) async {
        var stamped = message
        if stamped.taskID == nil { stamped.taskID = taskID }
        if stamped.providerID == nil { stamped.providerID = configuration?.providerID }
        if stamped.modelID == nil { stamped.modelID = configuration?.model }
        if stamped.configuration == nil { stamped.configuration = configuration }
        await channel.post(stamped)
    }

    /// Summarizes a task and saves the embedded summary to the memory store.
    ///
    /// Retries transient failures per `LLMRetryPolicy`, shared with every other LLM caller.
    /// Returns the generated summary text on success, or `nil` if summarization failed.
    /// Errors are posted to the channel rather than thrown, since this runs
    /// as a fire-and-forget background operation.
    @discardableResult
    public func summarizeAndEmbed(task: AgentTask) async -> String? {
        activityTracker?.begin(.summarizerRun)
        defer { activityTracker?.end(.summarizerRun) }
        let startTime = Date()
        var lastError: Error?
        let annotation = LLMCallAnnotation(operation: .taskSummary, taskID: task.id, taskTitle: task.title)

        var attempt = 0
        while true {
            if Task.isCancelled { return nil }
            attempt += 1

            do {
                let summary = try await generateSummary(for: task, annotation: annotation.forCall(attempt))
                let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
                try await memoryStore.saveTaskSummary(
                    task: task,
                    summary: summary,
                    status: task.status
                )
                await postToChannel(ChannelMessage(
                    sender: .agent(.summarizer),
                    content: summary,
                    metadata: [
                        "messageKind": .kind(.taskSummarized),
                        "taskID": .string(task.id.uuidString),
                        "taskTitle": .string(task.title),
                        "latencyMs": .int(latencyMs)
                    ]
                ))
                return summary
            } catch {
                lastError = error
                guard case .transient(let retryAfter, _) = LLMRetryPolicy.classify(error),
                      attempt < LLMRetryPolicy.maxAttempts else { break }
                let delay = LLMRetryPolicy.delay(attempt: attempt, retryAfter: retryAfter)
                await postToChannel(ChannelMessage(
                    sender: .agent(.summarizer),
                    content: "Summarization retry \(attempt)/\(LLMRetryPolicy.maxAttempts) for '\(task.title)' in \(LLMRetryPolicy.formatDelay(delay))",
                    metadata: ["severity": .severity(.warning)]
                ))
                guard await LLMRetryPolicy.sleep(attempt: attempt, retryAfter: retryAfter) else { break }
            }
        }

        if Task.isCancelled { return nil }   // cancelled mid-call: don't post a spurious failure
        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        await postToChannel(ChannelMessage(
            sender: .agent(.summarizer),
            content: "Task summarization failed for '\(task.title)': \(lastError?.localizedDescription ?? "unknown error")",
            metadata: [
                "severity": .severity(.error),
                "latencyMs": .int(latencyMs)
            ]
        ))
        return nil
    }

    // MARK: - Memory Consolidation

    /// Decides whether a new memory should merge into a similar existing one, and if so
    /// produces the reconciled text. The LLM is the decider — cosine only chose the
    /// candidate — so distinct facts that merely phrase alike stay separate, and a
    /// changed fact supersedes the old value instead of piling up a contradictory
    /// duplicate. Retries transient HTTP errors. Any outcome other than `.merged` saves the new
    /// memory separately (the safe default: never clobber an existing memory on an unreliable
    /// call), but each failure mode is reported as itself.
    public func reconcileMemoryTexts(
        existing: String,
        new: String,
        correlationID: UUID,
        taskID: UUID?,
        taskTitle: String?
    ) async -> MemoryReconciliation {
        let annotation = LLMCallAnnotation(
            operation: .memoryReconciliation,
            taskID: taskID,
            taskTitle: taskTitle,
            correlationID: correlationID
        )
        let systemPrompt = """
            You decide whether two memories should be ONE memory or kept SEPARATE.

            They are the SAME memory if the new one states the same specific fact as the \
            existing one, OR directly updates/supersedes it (a changed phone number, a moved \
            file path, a revised preference, a renamed account).

            They are DIFFERENT if they are distinct facts — even within the same category. A \
            GitHub username and a GitLab username are different. Two different people's phone \
            numbers are different. A file path for project A and one for project B are different. \
            When in doubt, answer DIFFERENT.

            Respond with exactly SAME or DIFFERENT on the FIRST line.
            - If DIFFERENT: output nothing else.
            - If SAME: on the following lines output the single reconciled memory text — retain \
            every still-current detail from both, and on ANY conflict prefer the NEWER memory \
            (it supersedes the old). No headings, bullets, or commentary.
            """

        // No length cap: the merge decision must see the FULL text of both memories — a
        // distinguishing detail past a cut could flip the verdict, and on SAME the reconciled
        // text would be rebuilt from clipped inputs. Oversized-context handling is deferred to a
        // holistic solution (see ROADMAP).
        let userPrompt = "Existing memory:\n\(existing)\n\nNew memory:\n\(new)"

        let messages: [LLMMessage] = [
            .system(systemPrompt),
            .user(userPrompt)
        ]

        var lastError: Error?
        var attempt = 0
        while true {
            if Task.isCancelled { return .cancelled }
            attempt += 1

            do {
                let response = try await sendRecorded(messages, annotation: annotation.forCall(attempt))

                let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Self.parseReconciliation(text)
            } catch {
                lastError = error
                guard case .transient(let retryAfter, _) = LLMRetryPolicy.classify(error),
                      attempt < LLMRetryPolicy.maxAttempts,
                      await LLMRetryPolicy.sleep(attempt: attempt, retryAfter: retryAfter) else { break }
            }
        }

        if Task.isCancelled { return .cancelled }   // cancelled mid-call: don't post a spurious failure
        let errorDescription = lastError?.localizedDescription ?? "unknown error"
        await postToChannel(ChannelMessage(
            sender: .agent(.summarizer),
            content: "Memory reconciliation failed: \(errorDescription)",
            metadata: ["severity": .severity(.error)]
        ))
        return .unavailable(errorDescription: errorDescription)
    }

    /// Parses a reconciliation response: first line SAME/DIFFERENT (case-insensitive,
    /// punctuation-tolerant), remaining lines the merged text on SAME. A SAME verdict with no
    /// body is `.emptyMerge` and anything else unrecognized is `.malformed` — both save
    /// separately (never destroy the existing memory on a bad response; a rare extra
    /// near-duplicate is the lesser harm), but neither is reported as a DIFFERENT judgment.
    static func parseReconciliation(_ text: String) -> MemoryReconciliation {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstRaw = lines.first else { return .malformed(response: text) }
        let firstWord = firstRaw
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1).first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: ":.,!*#`"))
            .uppercased() ?? ""
        if firstWord == "DIFFERENT" { return .different }
        guard firstWord == "SAME" else { return .malformed(response: text) }
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? .emptyMerge : .merged(body)
    }

    /// Runs `prompt` against fetched web-page `content` and returns the extracted answer, or
    /// `nil` if the model returns nothing or the call fails. Backs the `web_fetch` tool's hybrid
    /// extraction mode (reuses the summarizer's provider so no separate LLM agent is needed).
    /// No length cap: the extractor sees the FULL page — an answer near the end of a long page
    /// must stay reachable. Oversized-context handling is deferred to a holistic solution
    /// (see ROADMAP).
    public func extractWebContent(content: String, prompt: String, taskID: UUID?, taskTitle: String?) async -> String? {
        let annotation = LLMCallAnnotation(operation: .webContentExtraction, taskID: taskID, taskTitle: taskTitle)
        let systemPrompt = """
            You extract information from web page content. Given a page's text and a user's \
            request, answer the request using ONLY information present in the content. Be concise \
            and factual; cite specifics (names, numbers, dates, URLs) when relevant. If the \
            content does not contain what was asked, say so plainly. Output ONLY the answer — no \
            preamble or commentary.
            """
        let userPrompt = "Request:\n\(prompt)\n\nWeb page content:\n\(content)"
        let messages: [LLMMessage] = [
            .system(systemPrompt),
            .user(userPrompt)
        ]

        var lastError: Error?
        var attempt = 0
        while true {
            if Task.isCancelled { return nil }
            attempt += 1

            do {
                let response = try await sendRecorded(messages, annotation: annotation.forCall(attempt))

                guard let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                lastError = error
                guard case .transient(let retryAfter, _) = LLMRetryPolicy.classify(error),
                      attempt < LLMRetryPolicy.maxAttempts,
                      await LLMRetryPolicy.sleep(attempt: attempt, retryAfter: retryAfter) else { break }
            }
        }

        if Task.isCancelled { return nil }   // cancelled mid-call: don't post a spurious failure
        await postToChannel(ChannelMessage(
            sender: .agent(.summarizer),
            content: "Web content extraction failed: \(lastError?.localizedDescription ?? "unknown error")",
            metadata: ["severity": .severity(.error)]
        ))
        return nil
    }

    // MARK: - Private

    /// Makes the one provider call that summarizes `task`. Internal rather than private so tests
    /// can drive it without the embedding model `summarizeAndEmbed`'s save step needs.
    func generateSummary(for task: AgentTask, annotation: LLMCallAnnotation) async throws -> String {
        let userPrompt = buildUserPrompt(for: task)

        let messages: [LLMMessage] = [
            .system(Self.systemPrompt),
            .user(userPrompt)
        ]

        let response = try await sendRecorded(messages, annotation: annotation)

        guard let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizerError.emptyResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Computes the maximum character budget for the result field.
    /// Uses 80% of the context window (in tokens, converted to chars) minus overhead
    /// for the system prompt and other prompt sections. This gives the summarizer as
    /// much detail as the model can handle.
    ///
    /// We intentionally ignore `maxOutputTokens` here: the summarizer produces only a
    /// few sentences, so the configured max output (often 4K–8K) far exceeds actual
    /// usage. Subtracting it from the input budget would needlessly shrink the result
    /// text we can feed in. The 20% headroom is more than sufficient.
    private var resultCharBudget: Int {
        let inputTokenBudget = contextWindowSize * 4 / 5  // 80% of full context window
        // Conservative estimate: ~3 characters per token
        let totalInputChars = inputTokenBudget * 3
        // Reserve space for system prompt (~300 chars) + other fields (~2000 chars generous)
        let overhead = 2300
        return max(1000, totalInputChars - overhead)
    }

    private static let completedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter
    }()

    private static let updateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func buildUserPrompt(for task: AgentTask) -> String {
        var sections: [String] = []

        sections.append("Task ID: \(task.id.uuidString)")
        sections.append("Title: \(task.title)")
        sections.append("Description: \(task.description)")
        sections.append("Status: \(task.status.rawValue)")

        if let completedAt = task.completedAt {
            sections.append("Completed: \(Self.completedDateFormatter.string(from: completedAt))")
        }

        if let result = task.result, !result.isEmpty {
            let budget = resultCharBudget
            let cappedResult = result.count > budget
                ? String(result.prefix(budget)) + "\n[truncated at \(budget) of \(result.count) chars]"
                : result
            sections.append("Result:\n\(cappedResult)")
        }

        if let commentary = task.commentary, !commentary.isEmpty {
            sections.append("Commentary: \(commentary)")
        }

        if !task.updates.isEmpty {
            let updateLines = task.updates.map { update in
                "[\(Self.updateTimeFormatter.string(from: update.date))] \(update.message)"
            }
            sections.append("Progress updates:\n\(updateLines.joined(separator: "\n"))")
        }

        return sections.joined(separator: "\n\n")
    }

    public enum SummarizerError: Error, LocalizedError {
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "LLM returned an empty summary"
            }
        }
    }
}
