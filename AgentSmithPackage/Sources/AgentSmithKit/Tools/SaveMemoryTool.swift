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
        Tag with one of: `procedure`, `how-to`, `gotcha`, `user-config`, `identifier`, \
        `domain-fact` — tags drive consolidation. One concept per memory. \
        If a closely related memory already exists, it will be automatically consolidated.
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

    /// Minimum semantic cosine similarity for two memories to be considered consolidation
    /// candidates. Applied to `MemorySearchResult.similarity` (raw cosine from the Qwen3
    /// embedding) independently of the RRF ranking. With Qwen3, near-duplicate text sits
    /// at ≥0.85 — that's the floor we want for an automatic merge. Tag overlap is also
    /// required (see guard below) so even a high-cosine false positive needs an
    /// agent-supplied agreement before consolidating.
    private static let consolidationThreshold: Double = 0.85
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
        if case .array(let tagValues) = arguments["tags"] {
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
        let similarMemories: [MemorySearchResult]
        do {
            similarMemories = try await context.memoryStore.searchMemories(
                query: content,
                limit: Self.consolidationCandidateLimit,
                threshold: Self.consolidationCandidateFloor
            )
        } catch {
            // If search fails, proceed with normal save.
            similarMemories = []
        }

        let bestMatch = similarMemories
            .filter { $0.similarity >= Self.consolidationThreshold }
            .max(by: { $0.similarity < $1.similarity })

        if let match = bestMatch {
            // Require at least one shared tag before consolidating — high cosine alone is
            // not enough, and the agent-supplied tag agreement gives a second axis of
            // confirmation before two distinct memories get merged.
            let sharedTags = Set(match.memory.tags).intersection(tags)
            guard !tags.isEmpty, !match.memory.tags.isEmpty, !sharedTags.isEmpty else {
                return try await saveNew(
                    content: content, source: source, tags: tags,
                    sourceTaskID: sourceTaskID, consolidated: false, context: context
                )
            }

            // Attempt LLM-based merge of the existing and new content.
            if let merged = await context.mergeMemoryContent(match.memory.content, content) {
                let mergedTags = Array(Set(match.memory.tags + tags))
                do {
                    try await context.memoryStore.update(
                        id: match.memory.id,
                        content: merged,
                        tags: mergedTags,
                        updatedBy: .system
                    )
                } catch {
                    // If update fails, fall through to normal save.
                    return try await saveNew(
                        content: content, source: source, tags: tags,
                        sourceTaskID: sourceTaskID, consolidated: false, context: context
                    )
                }

                await postChannelMessage(
                    content: merged, tags: mergedTags, source: source,
                    consolidated: true, context: context
                )

                let tagText = mergedTags.isEmpty ? "" : " [tags: \(mergedTags.joined(separator: ", "))]"
                return .success("Consolidated into existing memory (ID: \(match.memory.id)).\(tagText)")
            }
        }

        // No match found or merge unavailable — save as new memory.
        return try await saveNew(
            content: content, source: source, tags: tags,
            sourceTaskID: sourceTaskID, consolidated: false, context: context
        )
    }

    // MARK: - Private

    private func saveNew(
        content: String,
        source: MemoryEntry.Source,
        tags: [String],
        sourceTaskID: UUID?,
        consolidated: Bool,
        context: ToolContext
    ) async throws -> ToolExecutionResult {
        let entry = try await context.memoryStore.save(
            content: content,
            source: source,
            tags: tags,
            sourceTaskID: sourceTaskID
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
                "messageKind": .string("memory_saved"),
                "memoryContent": .string(content),
                "memoryTags": .string(tags.joined(separator: ", ")),
                "memorySource": .string(source.rawValue),
                "consolidated": .bool(consolidated)
            ]
        ))
    }
}
