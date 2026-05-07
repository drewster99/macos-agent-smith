import SwiftUI
import AgentSmithKit

/// Standalone window showing full task detail. Sections are reordered and pre-expanded
/// based on the task's `Status` so the most relevant data is at the top:
/// - `pending` / `scheduled`: full description on top.
/// - `running` / `paused` / `interrupted` / `awaitingReview`: latest updates first.
/// - `completed`: summary preview, then the full result with AI Commentary inset.
/// - `failed`: the error first, then optional summary, then result/commentary.
struct TaskDetailWindow: View {
    let taskID: UUID
    var viewModel: AppViewModel
    /// Used to resolve the owning session for a prior-task link so the new detail
    /// window opens scoped to that task's actual session, not this window's session.
    var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var isEditingDescription = false
    @State private var editedDescription = ""
    @State private var recentlyCopiedSection: String?

    /// Per-section toggle state. Empty on first render — `currentMode(_:for:)` falls back
    /// to status-driven defaults until the user interacts. Resets on each window open
    /// because @State is reinitialized when SwiftUI recreates this view per `WindowGroup`
    /// instance.
    @State private var modeOverrides: [SectionKind: SectionMode] = [:]
    /// Identity-keyed expansion state for related-context rows. Survives memory-array
    /// re-orderings and avoids the `id: \.offset` aliasing bug where per-index state
    /// would silently bind to a different memory if the array ever changed shape.
    @State private var expandedMemoryContents: Set<String> = []
    @State private var expandedPriorTaskIDs: Set<UUID> = []

    /// Local copy of the current task. Sync'd from `viewModel.tasks` via `.onChange` so
    /// the body reads only @State and SwiftUI can short-circuit re-renders when this
    /// specific task didn't change. `AgentTask` is `Equatable`, so the diff is cheap.
    @State private var task: AgentTask?

    /// Whether the current task's description can be edited. Mirrors
    /// `AgentTask.Status.isDescriptionEditable` so completed/failed/scheduled tasks accept
    /// late corrections; only `running` and `awaitingReview` are read-only.
    private var isDescriptionEditable: Bool {
        guard let task else { return false }
        return task.status.isDescriptionEditable
    }

    /// Pulls the matching task out of `viewModel.tasks` and writes it to local @State.
    /// Called from `.onAppear` and from `.onChange(of: viewModel.tasks)` — body reads
    /// only the @State copy, so unrelated task mutations don't force this window to
    /// re-render.
    private func syncTask() {
        let next = viewModel.tasks.first { $0.id == taskID }
        if next != task {
            task = next
        }
    }

    /// Resolves an attachment's on-disk URL through this window's session-scoped
    /// `PersistenceManager`. Captured by `TaskAttachmentList` rows so they can build a
    /// Reveal-in-Finder action.
    private func attachmentURLResolver(_ attachment: Attachment) -> URL? {
        viewModel.persistenceManager.attachmentURL(id: attachment.id, filename: attachment.filename)
    }

    var body: some View {
        Group {
            if let task {
                taskContent(task)
            } else {
                ContentUnavailableView(
                    "Task Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("This task may have been deleted.")
                )
                .frame(minWidth: 600, minHeight: 400)
            }
        }
        .onAppear { syncTask() }
        .onChange(of: viewModel.tasks) { _, _ in
            // Per project rule: @State writes inside `.onChange` must be deferred to the
            // next runloop tick to avoid "Modifying state during view update" warnings.
            DispatchQueue.main.async { syncTask() }
        }
    }

    // MARK: - Body

    private func taskContent(_ task: AgentTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerRow(task)
                metadataSection(for: task)
                Divider()
                ForEach(orderedSections(for: task.status), id: \.self) { kind in
                    sectionView(kind, task: task)
                }
                Divider()
                Text("ID: \(task.id.uuidString)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle(task.title)
    }

    private func headerRow(_ task: AgentTask) -> some View {
        HStack(alignment: .top) {
            Image(systemName: TaskStatusBadge.icon(for: task.status))
                .font(.title2)
                .foregroundStyle(TaskStatusBadge.color(for: task.status))
            Text(task.title)
                .font(.title.bold())
                .textSelection(.enabled)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Section dispatch

    /// All sections that could ever render in this window, in the canonical order
    /// `orderedSections(for:)` filters from based on status.
    private enum SectionKind: Hashable {
        case error
        case summary
        case result
        case updates
        case description
        case relatedContext
    }

    private enum SectionMode {
        case hidden
        case preview
        case expanded
    }

    private func orderedSections(for status: AgentTask.Status) -> [SectionKind] {
        switch status {
        case .pending, .scheduled:
            return [.description, .relatedContext]
        case .running, .paused, .interrupted, .awaitingReview:
            return [.updates, .description, .relatedContext]
        case .completed:
            return [.summary, .result, .updates, .description, .relatedContext]
        case .failed:
            return [.error, .summary, .result, .updates, .description, .relatedContext]
        }
    }

    /// Status-driven default mode for a section. The user can override to/from `.preview`
    /// and `.expanded` via the header chevron; `.hidden` is not user-toggleable.
    private func defaultMode(_ kind: SectionKind, for status: AgentTask.Status) -> SectionMode {
        switch (kind, status) {
        case (.error, .failed):                       return .expanded
        case (.error, _):                             return .hidden

        case (.description, .pending), (.description, .scheduled):
            return .expanded
        case (.description, _):                       return .preview

        case (.relatedContext, _):                    return .preview

        case (.updates, .pending), (.updates, .scheduled):
            return .hidden
        case (.updates, _):                           return .preview

        case (.result, .completed):                   return .expanded
        case (.result, .failed):                      return .expanded
        case (.result, _):                            return .hidden

        case (.summary, .completed), (.summary, .failed):
            return .preview
        case (.summary, _):                           return .hidden
        }
    }

    private func currentMode(_ kind: SectionKind, for status: AgentTask.Status) -> SectionMode {
        if let overridden = modeOverrides[kind] { return overridden }
        return defaultMode(kind, for: status)
    }

    private func toggleSection(_ kind: SectionKind, for status: AgentTask.Status) {
        let next: SectionMode
        switch currentMode(kind, for: status) {
        case .preview, .hidden:  next = .expanded
        case .expanded:          next = .preview
        }
        modeOverrides[kind] = next
    }

    @ViewBuilder
    private func sectionView(_ kind: SectionKind, task: AgentTask) -> some View {
        let mode = currentMode(kind, for: task.status)
        if mode != .hidden {
            switch kind {
            case .error:           errorSection(task)
            case .summary:         summarySection(task, mode: mode)
            case .result:          resultSection(task)
            case .updates:         updatesSection(task, mode: mode)
            case .description:     descriptionSection(task, mode: mode)
            case .relatedContext:  relatedContextSection(task)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func errorSection(_ task: AgentTask) -> some View {
        // Failures land in `task.result` today; surface that as the Error body.
        let errorText = task.result ?? ""
        if !errorText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitleRow(
                    title: "Error",
                    titleColor: AppColors.errorSectionAccent,
                    copyText: errorText
                )
                MarkdownText(content: errorText, baseFont: .body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(AppColors.errorBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Divider()
        }
    }

    @ViewBuilder
    private func summarySection(_ task: AgentTask, mode: SectionMode) -> some View {
        if let summary = task.summary, !summary.isEmpty {
            let isExpandable = (linePrefix(summary, lines: 4) != summary)
            VStack(alignment: .leading, spacing: 8) {
                sectionTitleRow(title: "Summary", copyText: summary)
                let body = (mode == .expanded || !isExpandable) ? summary : linePrefix(summary, lines: 4)
                MarkdownText(content: body, baseFont: .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(AppColors.summarySectionBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if isExpandable {
                    DisclosureMoreLessLink(isExpanded: mode == .expanded) {
                        toggleSection(.summary, for: task.status)
                    }
                }
            }
            Divider()
        }
    }

    @ViewBuilder
    private func resultSection(_ task: AgentTask) -> some View {
        let result = task.result ?? ""
        let commentary = task.commentary ?? ""
        let hasResult = !result.isEmpty
        let hasCommentary = !commentary.isEmpty

        // For failed tasks the error section already surfaced `result` — skip the duplicate.
        let suppressDueToError = (task.status == .failed)

        if (hasResult && !suppressDueToError) || hasCommentary {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitleRow(
                    title: "Result",
                    copyText: result.isEmpty ? commentary : result
                )

                if hasCommentary {
                    aiCommentaryInset(commentary)
                }

                if hasResult && !suppressDueToError {
                    MarkdownText(content: result, baseFont: .body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
        }

        // Render result attachments whenever they exist on a completed/failed task,
        // even when the Result section was suppressed (e.g. failed task with attachments
        // but no commentary). The status check is implicit — this function is only
        // reached for statuses that include `.result` in `orderedSections`.
        if !task.resultAttachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Result Attachments", copyText: Self.formattedAttachments(task.resultAttachments))
                TaskAttachmentList(
                    attachments: task.resultAttachments,
                    urlResolver: attachmentURLResolver
                )
            }
            Divider()
        }
    }

    private func aiCommentaryInset(_ commentary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("AI commentary")
                    .font(AppFonts.aiCommentaryTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                copyButton(text: commentary, id: "ai-commentary")
            }
            MarkdownText(content: commentary, baseFont: AppFonts.aiCommentaryBody)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColors.aiCommentaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(AppColors.aiCommentaryBorder, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func updatesSection(_ task: AgentTask, mode: SectionMode) -> some View {
        if !task.updates.isEmpty {
            // Newest at top. When the total count fits in the 5-item preview the section
            // is treated as fully expanded — no `(more)`/`(less)` link, since toggling
            // would not change what's visible.
            let reversed = Array(task.updates.reversed())
            let isExpandable = reversed.count > 5
            let effectiveExpanded = mode == .expanded || !isExpandable
            let visible = effectiveExpanded ? reversed : Array(reversed.prefix(5))
            VStack(alignment: .leading, spacing: 8) {
                sectionTitleRow(
                    title: "Updates",
                    subtitle: (!effectiveExpanded && isExpandable) ? "showing 5 of \(reversed.count)" : nil,
                    copyText: Self.formattedUpdates(task.updates)
                )
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, update in
                        TaskUpdateRow(update: update, attachmentURLResolver: attachmentURLResolver)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isExpandable {
                    DisclosureMoreLessLink(isExpanded: mode == .expanded) {
                        toggleSection(.updates, for: task.status)
                    }
                }
            }
            Divider()
        }
    }

    @ViewBuilder
    private func descriptionSection(_ task: AgentTask, mode: SectionMode) -> some View {
        let isExpandable = (linePrefix(task.description, lines: 3) != task.description)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Description")
                    .font(.title3.bold())
                if let editedAt = task.lastEditedAt {
                    EditedBadge(editedAt: editedAt)
                }
                Spacer()
                copyButton(text: task.description, id: "description")
                if isDescriptionEditable && !isEditingDescription {
                    Button {
                        editedDescription = task.description
                        isEditingDescription = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Edit description")
                }
            }

            if isEditingDescription {
                TextEditor(text: $editedDescription)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button("Cancel") {
                        isEditingDescription = false
                    }
                    Button("Save") {
                        Task {
                            await viewModel.updateTaskDescription(
                                id: task.id,
                                description: editedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        }
                        isEditingDescription = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDescriptionEditable || editedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                let body = (mode == .expanded || !isExpandable)
                    ? task.description
                    : linePrefix(task.description, lines: 3)
                MarkdownText(content: body, baseFont: .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !task.descriptionAttachments.isEmpty && mode == .expanded {
                sectionHeader("Attachments", copyText: Self.formattedAttachments(task.descriptionAttachments))
                TaskAttachmentList(
                    attachments: task.descriptionAttachments,
                    urlResolver: attachmentURLResolver
                )
            }

            if isExpandable && !isEditingDescription {
                DisclosureMoreLessLink(isExpanded: mode == .expanded) {
                    toggleSection(.description, for: task.status)
                }
            }
        }
        Divider()
    }

    @ViewBuilder
    private func relatedContextSection(_ task: AgentTask) -> some View {
        if Self.hasRelevantContext(task) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitleRow(
                    title: "Related context",
                    copyText: Self.formattedContext(task)
                )

                if let memories = task.relevantMemories, !memories.isEmpty {
                    Text("Memories")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        // `id: \.content` keeps expansion state pinned to the memory itself
                        // even if the array is re-ordered. Two memories with identical content
                        // would tie arbitrarily; in practice memories are unique by content.
                        ForEach(memories, id: \.content) { memory in
                            TaskRelevantMemoryRow(
                                memory: memory,
                                isExpanded: memoryExpansionBinding(content: memory.content)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let priorTasks = task.relevantPriorTasks, !priorTasks.isEmpty {
                    Text("Prior Tasks")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(priorTasks, id: \.taskID) { prior in
                            TaskRelevantPriorTaskRow(
                                priorTask: prior,
                                isExpanded: priorTaskExpansionBinding(taskID: prior.taskID),
                                onOpenTask: openPriorTask
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
        }
    }

    /// Resolves the session that owns `priorTaskID` (typically a different tab), then
    /// opens its detail window. Falls back to this window's session if no loaded session
    /// has the task — in which case the new window will show the standard "Task Not
    /// Found" placeholder, same as opening any deleted task.
    private func openPriorTask(_ priorTaskID: UUID) {
        let resolved = sessionManager.resolveSessionID(forTaskID: priorTaskID) ?? viewModel.session.id
        AgentSmithApp.showOrOpenTaskDetail(
            target: TaskDetailTarget(sessionID: resolved, taskID: priorTaskID),
            openWindow: openWindow
        )
    }

    private func memoryExpansionBinding(content: String) -> Binding<Bool> {
        Binding(
            get: { expandedMemoryContents.contains(content) },
            set: { newValue in
                if newValue { expandedMemoryContents.insert(content) }
                else { expandedMemoryContents.remove(content) }
            }
        )
    }

    private func priorTaskExpansionBinding(taskID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedPriorTaskIDs.contains(taskID) },
            set: { newValue in
                if newValue { expandedPriorTaskIDs.insert(taskID) }
                else { expandedPriorTaskIDs.remove(taskID) }
            }
        )
    }

    // MARK: - Headers

    /// Section header with the title on the leading edge plus the section's copy
    /// button on the trailing edge. The header is no longer click-to-toggle — the
    /// `(more)`/`(less)` disclosure link in the section body handles expansion.
    private func sectionTitleRow(
        title: String,
        subtitle: String? = nil,
        titleColor: Color? = nil,
        copyText: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(titleColor ?? .primary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let copyText, !copyText.isEmpty {
                copyButton(text: copyText, id: title)
            }
        }
    }

    // MARK: - Metadata grid

    private func metadataSection(for task: AgentTask) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                metadataLabel("Status")
                Text(task.status.rawValue.capitalized)
                    .foregroundStyle(TaskStatusBadge.color(for: task.status))
                    .fontWeight(.medium)
            }

            GridRow {
                metadataLabel("Created")
                Text(task.createdAt.formatted(date: .abbreviated, time: .standard))
            }

            if let startedAt = task.startedAt {
                GridRow {
                    metadataLabel("Started")
                    Text(startedAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            if let completedAt = task.completedAt {
                GridRow {
                    metadataLabel(task.status == .failed ? "Failed" : "Completed")
                    Text(completedAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            if let elapsed = Self.elapsedTime(for: task) {
                GridRow {
                    metadataLabel("Elapsed")
                    Text(elapsed)
                }
            }

            if let scheduled = task.scheduledRunAt {
                GridRow {
                    metadataLabel("Scheduled")
                    scheduledLine(for: scheduled)
                }
            }
        }
        .font(.callout)
    }

    private func scheduledLine(for date: Date) -> some View {
        let now = Date()
        let pastDue = date < now
        let isToday = Calendar.current.isDateInToday(date)
        let dateString = date.formatted(.dateTime.year().month(.abbreviated).day())
        let timeString = date.formatted(date: .omitted, time: .standard)

        let dateColor: Color = pastDue
            ? AppColors.scheduledPastDueAccent
            : (isToday ? .primary : AppColors.scheduledFutureAccent)
        let timeColor: Color = pastDue
            ? AppColors.scheduledPastDueAccent
            : AppColors.scheduledFutureAccent

        return HStack(spacing: 4) {
            Text(dateString).foregroundStyle(dateColor)
            Text("at").foregroundStyle(.secondary)
            Text(timeString).foregroundStyle(timeColor)
            if pastDue {
                Text("(past due)")
                    .foregroundStyle(AppColors.scheduledPastDueAccent)
                    .fontWeight(.medium)
            }
        }
    }

    private func metadataLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// Plain (non-collapsible) section header used by sub-sections like Result Attachments
    /// and Description Attachments that nest inside a parent collapsible section.
    private func sectionHeader(_ title: String, copyText: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.title3.bold())
            Spacer()
            if let copyText, !copyText.isEmpty {
                copyButton(text: copyText, id: title)
            }
        }
    }

    private func copyButton(text: String, id: String? = nil) -> some View {
        let sectionID = id ?? text
        let isCopied = recentlyCopiedSection == sectionID
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation {
                recentlyCopiedSection = sectionID
            }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if recentlyCopiedSection == sectionID {
                    withAnimation {
                        recentlyCopiedSection = nil
                    }
                }
            }
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.callout)
                .foregroundStyle(isCopied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    /// Whether the task has any relevant memories or prior task summaries attached.
    private static func hasRelevantContext(_ task: AgentTask) -> Bool {
        let hasMemories = task.relevantMemories.map { !$0.isEmpty } ?? false
        let hasPriorTasks = task.relevantPriorTasks.map { !$0.isEmpty } ?? false
        return hasMemories || hasPriorTasks
    }

    // MARK: - Copy text formatters

    private static func formattedUpdates(_ updates: [AgentTask.TaskUpdate]) -> String {
        updates.map { update in
            var line = "[\(update.date.formatted(date: .omitted, time: .standard))] \(update.message)"
            if !update.attachments.isEmpty {
                let names = update.attachments.map { $0.filename }.joined(separator: ", ")
                line += " (attachments: \(names))"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Builds a copy-friendly text rendering of an attachment list for the section's
    /// copy button. Each line: `filename (mime, size) — id=<UUID>`.
    private static func formattedAttachments(_ attachments: [Attachment]) -> String {
        attachments.map { a in
            "\(a.filename) (\(a.mimeType), \(a.formattedSize)) — id=\(a.id.uuidString)"
        }.joined(separator: "\n")
    }

    private static func formattedContext(_ task: AgentTask) -> String {
        var parts: [String] = []
        if let memories = task.relevantMemories, !memories.isEmpty {
            parts.append("Memories:")
            for memory in memories {
                parts.append("  \(String(format: "%.0f%%", memory.similarity * 100)) — \(memory.content)")
            }
        }
        if let priorTasks = task.relevantPriorTasks, !priorTasks.isEmpty {
            if !parts.isEmpty { parts.append("") }
            parts.append("Prior Tasks:")
            for prior in priorTasks {
                parts.append("  \(prior.title) (\(String(format: "%.0f%%", prior.similarity * 100)))")
                parts.append("  \(prior.summary)")
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Elapsed time

    /// Computes a human-readable elapsed duration from `startedAt` to `completedAt`.
    private static func elapsedTime(for task: AgentTask) -> String? {
        guard let start = task.startedAt else { return nil }
        let end = task.completedAt ?? Date()
        let interval = end.timeIntervalSince(start)
        guard interval >= 0 else { return nil }

        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    /// Returns the first `lines` newline-separated lines of `text`, joined back. Used to
    /// build a preview for sections that wrap MarkdownText — `.lineLimit(N)` does not
    /// clip cleanly across MarkdownText's multi-block VStack, so we trim the source instead.
    /// If the trimmed prefix opens a fenced code block but doesn't close it, a closing
    /// fence is appended so the renderer doesn't bleed code styling into the rest of the
    /// section.
    private func linePrefix(_ text: String, lines: Int) -> String {
        let prefix = text.components(separatedBy: "\n").prefix(lines).joined(separator: "\n")
        return Self.balancingCodeFences(prefix)
    }

    /// Appends a closing ``` ``` ``` or `~~~` fence when `text` contains an odd number
    /// of fence markers, so a preview cut mid-code-block doesn't leave the markdown
    /// renderer in code mode.
    private static func balancingCodeFences(_ text: String) -> String {
        let backticks = text.components(separatedBy: "```").count - 1
        if backticks % 2 == 1 { return text + "\n```" }
        let tildes = text.components(separatedBy: "~~~").count - 1
        if tildes % 2 == 1 { return text + "\n~~~" }
        return text
    }
}

/// Small "edited" pill shown next to the Description heading when the task's
/// `lastEditedAt` is non-nil. Hover tooltip shows the absolute edit time.
private struct EditedBadge: View {
    let editedAt: Date

    private static let tooltipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "pencil")
                .font(.caption2)
            Text("edited")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AppColors.subtleRowBackgroundLift)
        .clipShape(Capsule())
        .help("Edited \(Self.tooltipFormatter.string(from: editedAt))")
    }
}
