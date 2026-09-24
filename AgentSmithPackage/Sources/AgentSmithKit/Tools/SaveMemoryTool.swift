import Foundation

/// Allows agents to save a piece of knowledge to the semantic memory store.
///
/// Available to both Smith and Brown. The calling agent's role determines the memory source.
/// Automatically checks for semantically similar existing memories and consolidates
/// via LLM merge when a close match is found.
struct SaveMemoryTool: AgentTool {
    let name = "save_memory"
    let toolDescription = """
        Save a piece of information to long-term memory for future retrieval. \
        Saved memories are surfaced automatically by semantic search on future tasks, \
        so future agents avoid redoing the discovery you just did. \
        PRIMARY use case — procedural recipes you had to figure out: \
        "How to <do the thing>" with concrete step-by-step instructions, exact tool, \
        exact commands or AppleScript, exact file paths, exact API endpoints, exact \
        parameter names. Future-Brown should be able to execute the recipe with no \
        further discovery. \
        Also save: gotchas / workarounds / undocumented limits, user-specific \
        identifiers (file paths, contacts, account names, project roots), and stated \
        user preferences. \
        Lead with a search-friendly title sentence so the memory is findable later. \
        Tag with EXACTLY ONE of: `preference`, `identifier`, `procedure`, `gotcha`, \
        `domain-fact`. One concept per memory. \
        If a closely related memory already exists, it is automatically consolidated — a \
        changed value supersedes the old one.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "content": .dictionary([
                "type": .string("string"),
                "description": .string(
                    "The information to remember. Write clearly and specifically — " +
                    "this text will be used for semantic search matching in the future."
                )
            ]),
            "tags": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional categorization tags (e.g. 'debugging', 'user-preference', 'architecture').")
            ])
        ]),
        "required": .array([.string("content")])
    ]

    /// Cosine floor for handing a candidate to the LLM reconciler. NOT a merge decision —
    /// just "similar enough to be worth asking about." Deliberately BELOW near-duplicate
    /// territory (≈0.85) so a SUPERSEDING memory (a changed value phrased differently, e.g.
    /// a new phone number) still surfaces for the reconciler to update the old one; a high
    /// gate here structurally excluded exactly that case. The LLM — not this number — makes
    /// the same/different call, so distinct-but-similar facts don't wrongly merge.
    /// Tunable via `RetrievalEvalRunner` if the embedding model changes.
    private static let consolidationThreshold: Double = 0.70
    /// Loose noise floor for the candidate fetch — anything moderately related is OK
    /// because the strict semantic gate above is what actually decides consolidation.
    private static let consolidationCandidateFloor: Double = 0.5
    /// How many candidates to pull from `searchMemories` before picking the best raw-cosine
    /// match. Larger than the user-facing search limit because `searchMemories` orders by
    /// RRF — the actual highest-cosine candidate can sit outside the first few RRF slots,
    /// so we need a wider window to find it.
    private static let consolidationCandidateLimit: Int = 20

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let content) = arguments["content"],
              !content.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolCallError.missingRequiredArgument("content")
        }

        var tags: [String] = []
        if let tagValues = ToolArguments.optionalArray(arguments, "tags") {
            for tagValue in tagValues {
                if case .string(let tag) = tagValue {
                    tags.append(tag)
                }
            }
        }

        let source: MemoryEntry.Source = switch context.agentRole {
        case .smith: .smith
        case .brown: .brown
        default: .user
        }

        // Determine the active task ID for context, if Brown is working on one.
        var sourceTaskID: UUID?
        if context.agentRole == .brown {
            if let task = await context.taskStore.taskForAgent(agentID: context.agentID) {
                sourceTaskID = task.id
            }
        }

        // Fetch a wide candidate pool with a permissive noise floor, then pick the
        // candidate with the *highest raw cosine* over `consolidationThreshold`.
        // `searchMemories` orders by RRF (which mixes lexical overlap), so taking the
        // first match would miss higher-cosine candidates buried deeper in RRF order.
        // One id for this whole consolidation attempt — candidate search, reconciler call, and the
        // resulting mutation — so the inspector can show them as one operation.
        let consolidationID = UUID()
        let similarMemories: [MemorySearchResult]
        var candidateSearchError: String?
        do {
            similarMemories = try await context.memoryStore.searchMemories(
                query: content,
                limit: Self.consolidationCandidateLimit,
                threshold: Self.consolidationCandidateFloor,
                origin: .memoryConsolidationCandidateSearch,
                correlationID: consolidationID
            )
        } catch {
            // If search fails, proceed with normal save — and say why no candidate was considered.
            similarMemories = []
            candidateSearchError = error.localizedDescription
        }

        let bestMatch = similarMemories
            .filter { $0.similarity >= Self.consolidationThreshold }
            .max(by: { $0.similarity < $1.similarity })

        guard let match = bestMatch else {
            let reason: MemoryConsolidationSeparateReason = candidateSearchError
                .map { .candidateSearchFailed(errorDescription: $0) } ?? .noQualifyingCandidate
            return try await saveNew(
                content: content, source: source, tags: tags, sourceTaskID: sourceTaskID,
                consolidation: MemoryConsolidationContext(
                    correlationID: consolidationID, candidateMemoryID: nil, candidateSimilarity: nil,
                    outcome: .keptSeparate(reason)),
                context: context
            )
        }

        // The LLM reconciler is the decider — cosine only picked the candidate. It returns
        // `.merged` for a duplicate OR an update/supersession (newer info wins), and `.different`
        // for two different facts that merely phrase alike. No hard tag requirement: tags were an
        // unreliable second axis (agents tag the same fact inconsistently), and the LLM is a
        // better one.
        let reconciliationRequest = MemoryReconciliationRequest(
            existing: match.memory.content, proposed: content, correlationID: consolidationID)
        let reconciliation = await context.reconcileMemory(reconciliationRequest)
        func keptSeparate(_ reason: MemoryConsolidationSeparateReason) -> MemoryConsolidationContext {
            MemoryConsolidationContext(
                correlationID: consolidationID, candidateMemoryID: match.memory.id,
                candidateSimilarity: match.similarity, outcome: .keptSeparate(reason))
        }

        let separateReason: MemoryConsolidationSeparateReason
        switch reconciliation {
        case .merged(let merged):
            // Ordered union — existing tags first, then new ones not already present. A Set would
            // scramble the order, which the store compares (and embeds) order-sensitively.
            var mergedTags = match.memory.tags
            for tag in tags where !mergedTags.contains(tag) { mergedTags.append(tag) }
            let mergedEntry: MemoryEntry?
            do {
                mergedEntry = try await context.memoryStore.update(
                    id: match.memory.id,
                    content: merged,
                    tags: mergedTags,
                    updatedBy: .system,
                    origin: .memoryConsolidation(requestedBy: context.agentRole),
                    consolidation: MemoryConsolidationContext(
                        correlationID: consolidationID, candidateMemoryID: match.memory.id,
                        candidateSimilarity: match.similarity, outcome: .merged),
                    proposed: MemoryContentSnapshot(text: content, tags: tags),
                    onlyIfUnchangedFrom: MemoryContentSnapshot(text: match.memory.content, tags: match.memory.tags)
                )
            } catch {
                // If update fails, fall through to normal save.
                return try await saveNew(
                    content: content, source: source, tags: tags, sourceTaskID: sourceTaskID,
                    consolidation: keptSeparate(.mergeUpdateFailed(errorDescription: error.localizedDescription)),
                    context: context
                )
            }
            // The candidate was edited or deleted while the reconciler ran: the merge was computed
            // from text that no longer exists, so nothing was written. The proposed memory must
            // still be saved rather than reported as consolidated.
            guard mergedEntry != nil else {
                return try await saveNew(
                    content: content, source: source, tags: tags, sourceTaskID: sourceTaskID,
                    consolidation: keptSeparate(.mergeTargetChanged),
                    context: context
                )
            }

            await postChannelMessage(
                content: merged, tags: mergedTags, source: source,
                consolidated: true, context: context
            )

            let tagText = mergedTags.isEmpty ? "" : " [tags: \(mergedTags.joined(separator: ", "))]"
            return .success("Consolidated into existing memory (ID: \(match.memory.id)).\(tagText)")
        case .different: separateReason = .reconcilerJudgedDifferent
        case .malformed(let response): separateReason = .reconcilerResponseMalformed(response: response)
        case .emptyMerge: separateReason = .reconcilerMergeWasEmpty
        case .unavailable(let errorDescription): separateReason = .reconcilerUnavailable(errorDescription: errorDescription)
        case .cancelled: separateReason = .reconcilerCancelled
        }

        return try await saveNew(
            content: content, source: source, tags: tags, sourceTaskID: sourceTaskID,
            consolidation: keptSeparate(separateReason), context: context
        )
    }

    // MARK: - Private

    /// Saves the proposed memory as a new entry; `consolidation` records why it was not merged.
    private func saveNew(
        content: String,
        source: MemoryEntry.Source,
        tags: [String],
        sourceTaskID: UUID?,
        consolidation: MemoryConsolidationContext,
        context: ToolContext
    ) async throws -> ToolExecutionResult {
        let entry = try await context.memoryStore.save(
            content: content,
            source: source,
            tags: tags,
            sourceTaskID: sourceTaskID,
            origin: .agentSaveMemory(context.agentRole),
            consolidation: consolidation
        )

        await postChannelMessage(
            content: content, tags: tags, source: source,
            consolidated: false, context: context
        )

        let tagText = tags.isEmpty ? "" : " [tags: \(tags.joined(separator: ", "))]"
        return .success("Memory saved (ID: \(entry.id)).\(tagText)")
    }

    private func postChannelMessage(
        content: String,
        tags: [String],
        source: MemoryEntry.Source,
        consolidated: Bool,
        context: ToolContext
    ) async {
        await context.post(ChannelMessage(
            sender: .system,
            content: String(content.prefix(120)),
            metadata: [
                "messageKind": .kind(.memorySaved),
                "memoryContent": .string(content),
                "memoryTags": .string(tags.joined(separator: ", ")),
                "memorySource": .string(source.rawValue),
                "consolidated": .bool(consolidated)
            ]
        ))
    }
}
