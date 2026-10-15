import SwiftUI
import AgentSmithKit

/// Standalone window for browsing, editing, and deleting stored memories and task summaries.
/// Memories are shared across all sessions, so this view binds to `SharedAppState`.
struct MemoryEditorView: View {
    @Bindable var shared: SharedAppState

    @State private var searchText = ""
    @State private var filterSource: MemoryEntry.Source?
    /// The memory being edited inline, if any.
    @State private var memoryEdit: MemoryEdit?
    @State private var showTaskSummaries = false
    @State private var editError: String?
    /// The new memory being composed above the list, if any.
    @State private var newMemoryDraft: MemoryDraft?
    @State private var memoryPendingDeletionID: UUID?
    @State private var memorySimilarities: [UUID: Double] = [:]
    @State private var taskSummarySimilarities: [UUID: Double] = [:]
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    /// Set when the most recent search threw — surfaced as an inline empty-state.
    /// Cleared on a successful search or when the query is cleared.
    @State private var searchErrorMessage: String?
    /// Stats from the most recent successful search, displayed in the footer.
    @State private var searchStats: SearchStats?
    /// Bumped whenever the search's results are replaced — new results, a failure, a cleared
    /// query — so the lists scroll back to the top of what they now show.
    @State private var searchGeneration = 0

    private var isAddingMemory: Bool { newMemoryDraft != nil }

    /// What the memory list's scroll position belongs to: a new one starts at the top.
    private struct MemoryListScrollScope: Hashable {
        let source: MemoryEntry.Source?
        let searchGeneration: Int
    }

    /// Per-search performance breakdown for the editor footer.
    private struct SearchStats: Equatable {
        let memoryDocCount: Int
        let memoryVectorCount: Int
        let taskDocCount: Int
        let taskVectorCount: Int
        let elapsedSeconds: Double

        var totalVectorCount: Int { memoryVectorCount + taskVectorCount }
        var totalDocCount: Int { memoryDocCount + taskDocCount }

        var elapsedMs: Double { elapsedSeconds * 1000 }

        var avgMsPerVector: Double {
            totalVectorCount == 0 ? 0 : elapsedMs / Double(totalVectorCount)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar()
            Divider()
            if showTaskSummaries {
                taskSummaryList()
            } else {
                memoryList()
            }
            statsFooter()
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await shared.refreshMemories()
        }
        .onChange(of: searchText) { handleSearchTextChanged() }
        .onDisappear {
            searchTask?.cancel()
        }
        .alert("Error", isPresented: Binding(
            get: { editError != nil },
            set: { if !$0 { editError = nil } }
        ), actions: {
            Button("OK") { editError = nil }
        }, message: {
            Text(editError ?? "")
        })
        .confirmationDialog(
            "Delete this memory?",
            isPresented: Binding(
                get: { memoryPendingDeletionID != nil },
                set: { if !$0 { memoryPendingDeletionID = nil } }
            ),
            titleVisibility: .visible, actions: {
            Button("Delete", role: .destructive) {
                if let id = memoryPendingDeletionID {
                    Task {
                        do {
                            try await shared.deleteMemory(id: id)
                        } catch {
                            editError = "Failed to delete memory: \(error.localizedDescription)"
                        }
                    }
                }
                memoryPendingDeletionID = nil
            }
            Button("Cancel", role: .cancel) {
                memoryPendingDeletionID = nil
            }
        }, message: {
            Text("This cannot be undone.")
        })
    }

    // MARK: - Search debounce

    /// Cancels any in-flight search task, snapshots corpus stats, and kicks off a fresh
    /// debounced search after 300ms. Empty queries clear all similarity scores instead.
    /// Extracted from the `.onChange(of: searchText)` body so the view's `body` stays
    /// readable; the synchronous-assignment ordering of `searchTask` is preserved (see
    /// the inline note below).
    private func handleSearchTextChanged() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            // Project rule: defer @State mutations out of .onChange so they don't
            // race the @Observable change that fired this closure.
            DispatchQueue.main.async {
                self.memorySimilarities.removeAll()
                self.taskSummarySimilarities.removeAll()
                self.isSearching = false
                self.searchErrorMessage = nil
                self.searchStats = nil
                self.searchGeneration += 1
            }
            return
        }
        DispatchQueue.main.async {
            self.isSearching = true
            self.searchErrorMessage = nil
        }
        // Note: `searchTask = Task { … }` is intentionally synchronous here, not wrapped
        // in DispatchQueue.main.async. The cancel-then-replace pattern at the top of
        // this method (`searchTask?.cancel()`) relies on the assignment landing before
        // the next keystroke's onChange runs; deferring would let two tasks race past
        // their cancellation guards on rapid typing.
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            // Snapshot the corpus shape BEFORE the search so the stats reflect what
            // was actually searched (the corpus could change between snapshot and
            // display, e.g. if a memory is saved during the await).
            let memDocs = shared.storedMemories.count
            let memVectors = shared.storedMemories.reduce(0) { $0 + ($1.embedding.isEmpty ? 0 : 1) }
            let taskDocs = shared.storedTaskSummaries.count
            let taskVectors = shared.storedTaskSummaries.reduce(0) { $0 + ($1.embedding.isEmpty ? 0 : 1) }

            let started = Date()
            do {
                let memResults = try await shared.searchMemories(query: query)
                let taskResults = try await shared.searchTaskSummaries(query: query)
                let elapsed = Date().timeIntervalSince(started)
                guard !Task.isCancelled else { return }

                var memScores: [UUID: Double] = [:]
                for r in memResults { memScores[r.memory.id] = r.similarity }
                memorySimilarities = memScores

                var taskScores: [UUID: Double] = [:]
                for r in taskResults { taskScores[r.summary.id] = r.similarity }
                taskSummarySimilarities = taskScores
                searchErrorMessage = nil
                searchStats = SearchStats(
                    memoryDocCount: memDocs,
                    memoryVectorCount: memVectors,
                    taskDocCount: taskDocs,
                    taskVectorCount: taskVectors,
                    elapsedSeconds: elapsed
                )
                searchGeneration += 1
            } catch {
                guard !Task.isCancelled else { return }
                memorySimilarities.removeAll()
                taskSummarySimilarities.removeAll()
                searchErrorMessage = error.localizedDescription
                searchStats = nil
                searchGeneration += 1
            }
            isSearching = false
        }
    }

    // MARK: - Footer

    /// Compact status row at the bottom of the editor:
    /// - shows "Searching…" with a spinner while a search is in flight (results above
    ///   may be stale during this time)
    /// - shows the most recent search's stats once it completes
    /// - hides itself entirely when no search has been run
    /// Always-visible status row at the bottom of the editor. Three states:
    /// 1. `isSearching` → spinner + "Searching…" (with optional parenthetical when the
    ///    list above is showing stale results from a previous query)
    /// 2. `searchStats != nil` → most recent search's docs/vectors/time breakdown
    /// 3. otherwise → corpus stats (memory + task summary counts and total vectors)
    @ViewBuilder
    private func statsFooter() -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                    Text(searchingFooterText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let stats = searchStats {
                    Image(systemName: "stopwatch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatStats(stats))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Image(systemName: "tray.full")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatCorpusStats())
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))
        }
    }

    /// Footer text shown next to the spinner. The wording differs depending on whether
    /// the visible list is "previous results, slightly stale" or "the full list because
    /// no search has run yet."
    private var searchingFooterText: String {
        let activeMap = showTaskSummaries ? taskSummarySimilarities : memorySimilarities
        if activeMap.isEmpty {
            return "Searching…"
        } else {
            return "Searching… (results below are from previous query)"
        }
    }

    /// Idle-state footer text — describes the loaded corpus when no search is active.
    /// `embedded` is the count of entries whose stored vector is non-empty (i.e.
    /// searchable). Stale entries waiting for the migration pass to re-embed them
    /// have an empty `embedding` and won't contribute to semantic search hits.
    private func formatCorpusStats() -> String {
        let memCount = shared.storedMemories.count
        let memEmbedded = shared.storedMemories.reduce(0) { $0 + ($1.embedding.isEmpty ? 0 : 1) }
        let taskCount = shared.storedTaskSummaries.count
        let taskEmbedded = shared.storedTaskSummaries.reduce(0) { $0 + ($1.embedding.isEmpty ? 0 : 1) }
        let memLabel = memCount == 1 ? "memory" : "memories"
        let taskLabel = taskCount == 1 ? "task summary" : "task summaries"
        return "\(memCount) \(memLabel) (\(memEmbedded) embedded)  •  \(taskCount) \(taskLabel) (\(taskEmbedded) embedded)"
    }

    private func formatStats(_ stats: SearchStats) -> String {
        // Example: "59 docs / 231 vectors • 32ms total • 0.14ms/vector"
        let docsLabel = stats.totalDocCount == 1 ? "doc" : "docs"
        let vecLabel = stats.totalVectorCount == 1 ? "vector" : "vectors"
        let totalMs = String(format: "%.0f", stats.elapsedMs)
        let avgMs: String
        if stats.totalVectorCount == 0 {
            avgMs = "—"
        } else {
            avgMs = String(format: "%.2f", stats.avgMsPerVector)
        }
        return "\(stats.totalDocCount) \(docsLabel) / \(stats.totalVectorCount) \(vecLabel)  •  \(totalMs)ms total  •  \(avgMs)ms/vector"
    }

    // MARK: - Header

    @ViewBuilder

    private func headerBar() -> some View {
        HStack(spacing: 12) {
            Picker("", selection: $showTaskSummaries) {
                Text("Memories (\(shared.storedMemories.count))").tag(false)
                Text("Tasks (\(shared.storedTaskSummaries.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Picker("Source", selection: $filterSource) {
                Text("All Sources").tag(Optional<MemoryEntry.Source>.none)
                Text("User").tag(Optional<MemoryEntry.Source>.some(.user))
                Text("Smith").tag(Optional<MemoryEntry.Source>.some(.smith))
                Text("Brown").tag(Optional<MemoryEntry.Source>.some(.brown))
            }
            .frame(width: 160)
            .opacity(showTaskSummaries ? 0 : 1)
            .disabled(showTaskSummaries)

            if !showTaskSummaries {
                Button(action: {
                    beginAddingMemory()
                }, label: {
                    Label("Add Memory", systemImage: "plus")
                })
                .controlSize(.small)
                .disabled(isAddingMemory || shared.memoryStore == nil)
            }

            Spacer()

            TextField("Semantic search…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 250)
        }
        .padding(12)
    }

    private func beginAddingMemory() {
        newMemoryDraft = MemoryDraft()
        memoryEdit = nil
    }

    private func cancelAddingMemory() {
        newMemoryDraft = nil
    }

    private func saveNewMemory(_ draft: MemoryDraft) {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = draft.tagList
        Task {
            do {
                _ = try await shared.saveMemory(content: content, tags: tags)
                // Only this draft: a composer reopened while the save was in flight stays open.
                if newMemoryDraft === draft { newMemoryDraft = nil }
            } catch {
                editError = "Failed to save memory: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Memory List

    private var filteredMemories: [MemoryEntry] {
        var result = shared.storedMemories
        if let source = filterSource {
            result = result.filter { $0.source == source }
        }
        if !searchText.isEmpty {
            if memorySimilarities.isEmpty {
                // Empty similarities map has two meanings: "first search hasn't run yet"
                // (show the full list as a placeholder so the UI doesn't blank out) vs.
                // "search completed and matched nothing" (return empty so the 'no matches'
                // empty-state can fire). `isSearching` distinguishes them.
                return isSearching ? result : []
            }
            let scored = result.filter { memorySimilarities[$0.id] != nil }
            return scored.sorted { (memorySimilarities[$0.id] ?? 0) > (memorySimilarities[$1.id] ?? 0) }
        }
        return result
    }

    @ViewBuilder

    private func memoryList() -> some View {
        let filtered = filteredMemories
        if let error = searchErrorMessage {
            ContentUnavailableView(
                "Search Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if !searchText.isEmpty && !isSearching && filtered.isEmpty && !isAddingMemory {
            // Only show "no matches" when the search has actually completed. While typing,
            // we keep showing stale results (or the full list on first search) so the UI
            // doesn't blank out between keystrokes. Suppress while the composer is open
            // so the user can see/save the new entry without dismissing the search first.
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("No memories matched “\(searchText)”. Try different keywords or a longer phrase.")
            )
        } else if shared.storedMemories.isEmpty && shared.memoryStore == nil {
            ContentUnavailableView(
                "Memory Store Not Loaded",
                systemImage: "play.circle",
                description: Text("Start a session from any window's toolbar to load memories from disk.")
            )
        } else if shared.storedMemories.isEmpty && !isAddingMemory {
            ContentUnavailableView(
                "No Memories Saved",
                systemImage: "brain",
                description: Text("Memories will appear here as they're saved by you or the agents.")
            )
        } else if filterSource != nil && searchText.isEmpty && filtered.isEmpty && !isAddingMemory {
            ContentUnavailableView(
                "No Matching Memories",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No memories from this source. Change the Source filter to see other memories.")
            )
        } else {
            VStack(spacing: 0) {
                if let newMemoryDraft {
                    MemoryDraftForm(
                        title: "New Memory", draft: newMemoryDraft, background: MemoryBrowserStyle.newMemoryBackground,
                        onCancel: cancelAddingMemory, onSave: { saveNewMemory(newMemoryDraft) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }
                MemoryListTable(
                    rows: memoryRows(filtered),
                    scrollScope: MemoryListScrollScope(source: filterSource, searchGeneration: searchGeneration),
                    edit: memoryEdit,
                    actions: memoryRowActions
                )
            }
        }
    }

    private func memoryRows(_ memories: [MemoryEntry]) -> [MemoryListRow] {
        let editedID = memoryEdit?.memoryID
        return memories.enumerated().map { index, memory in
            MemoryListRow(memory: memory, similarity: memorySimilarities[memory.id],
                          isAlternate: !index.isMultiple(of: 2), isEditing: memory.id == editedID)
        }
    }

    private var memoryRowActions: MemoryListRowActions {
        MemoryListRowActions(
            beginEditing: { memory in memoryEdit = MemoryEdit(memory: memory) },
            cancelEditing: { edit in
                if edit.isSameEdit(as: memoryEdit) { memoryEdit = nil }
            },
            saveEdit: saveMemoryEdit,
            requestDeletion: { id in memoryPendingDeletionID = id }
        )
    }

    private func saveMemoryEdit(_ edit: MemoryEdit) {
        let content = edit.draft.content
        let tags = edit.draft.tagList
        Task {
            do {
                try await shared.updateMemory(id: edit.memoryID, content: content, tags: tags)
                // Only this edit: one the user started while the save was in flight stays open.
                if edit.isSameEdit(as: memoryEdit) { memoryEdit = nil }
            } catch {
                editError = "Failed to update memory: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Task Summary List

    private var filteredTaskSummaries: [TaskSummaryEntry] {
        if !searchText.isEmpty {
            if taskSummarySimilarities.isEmpty {
                // Same logic as `filteredMemories`: distinguish "first search not yet
                // complete" (show the full list as a placeholder) from "search completed
                // with zero results" (return empty to surface the 'no matches' state).
                return isSearching ? shared.storedTaskSummaries : []
            }
            let scored = shared.storedTaskSummaries.filter { taskSummarySimilarities[$0.id] != nil }
            return scored.sorted { (taskSummarySimilarities[$0.id] ?? 0) > (taskSummarySimilarities[$1.id] ?? 0) }
        }
        return shared.storedTaskSummaries
    }

    @ViewBuilder

    private func taskSummaryList() -> some View {
        let filtered = filteredTaskSummaries
        if let error = searchErrorMessage {
            ContentUnavailableView(
                "Search Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if !searchText.isEmpty && !isSearching && filtered.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("No tasks matched “\(searchText)”. Try different keywords or a longer phrase.")
            )
        } else if shared.storedTaskSummaries.isEmpty && shared.memoryStore == nil {
            ContentUnavailableView(
                "Memory Store Not Loaded",
                systemImage: "play.circle",
                description: Text("Start a session from any window's toolbar to load task summaries from disk.")
            )
        } else if shared.storedTaskSummaries.isEmpty {
            ContentUnavailableView(
                "No Tasks Indexed",
                systemImage: "doc.text",
                description: Text("Tasks become searchable after they complete or fail and a summary is generated.")
            )
        } else {
            TaskSummaryListTable(rows: taskSummaryRows(filtered), scrollScope: searchGeneration)
        }
    }

    private func taskSummaryRows(_ summaries: [TaskSummaryEntry]) -> [TaskSummaryListRow] {
        summaries.enumerated().map { index, summary in
            TaskSummaryListRow(summary: summary, similarity: taskSummarySimilarities[summary.id],
                               isAlternate: !index.isMultiple(of: 2))
        }
    }
}
