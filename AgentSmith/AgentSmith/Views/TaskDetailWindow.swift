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
    @Bindable var viewModel: AppViewModel
    /// Used to resolve the owning session for a prior-task link so the new detail
    /// window opens scoped to that task's actual session, not this window's session.
    var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var isEditingDescription = false
    @State private var editedDescription = ""
    @State private var recentlyCopiedSection: String?

    /// Drives the "Save as PDF…" element-picker sheet and the field selection it edits.
    @State private var isShowingPDFSheet = false
    @State private var pdfOptions = TaskPDFFieldOptions.full

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
    /// Verdict records whose debug transcript (rendered input + response log) is open.
    @State private var expandedDebugRecordIDs: Set<UUID> = []
    /// Criteria whose pinned validator definition (system prompt + input template) is open.
    @State private var expandedValidatorPromptIDs: Set<UUID> = []
    @State private var isEditingAcceptance = false
    @State private var editedCriteria: [EditableCriterion] = []
    @State private var isEditingSteps = false
    @State private var editedSteps: [EditableStep] = []
    @State private var templateRunInputTask: AgentTask?
    @State private var taskEditorTask: AgentTask?

    /// Editing model for one acceptance criterion. Criterion identity is preserved
    /// through edits; the store resets sticky verdicts only when the validation contract changes.
    /// Legacy validator/prepare fields are preserved unless the prompt fields are edited.
    private struct EditableCriterion: Identifiable {
        let id: UUID
        var name: String
        var validationPrompt: String
        var inputEnumeratorPrompt: String
        var waivable: Bool
        let origin: TaskAuthorship
        let originalValidator: AcceptanceCriterion.Validator?
        let originalPrepare: String?
        let originalValidationPrompt: String
        let originalInputEnumeratorPrompt: String

        init(criterion: AcceptanceCriterion) {
            id = criterion.id
            name = criterion.name
            validationPrompt = criterion.validationPrompt
            inputEnumeratorPrompt = criterion.inputEnumeratorPrompt ?? ""
            waivable = criterion.waivable
            origin = criterion.origin
            originalValidator = criterion.validator
            originalPrepare = criterion.prepare
            originalValidationPrompt = criterion.validationPrompt
            originalInputEnumeratorPrompt = criterion.inputEnumeratorPrompt ?? ""
        }

        init() {
            id = UUID()
            name = ""
            validationPrompt = ""
            inputEnumeratorPrompt = ""
            waivable = false
            origin = .user
            originalValidator = nil
            originalPrepare = nil
            originalValidationPrompt = ""
            originalInputEnumeratorPrompt = ""
        }

        func built() -> AcceptanceCriterion? {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValidationPrompt = validationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, !trimmedValidationPrompt.isEmpty else { return nil }
            let trimmedEnumeratorPrompt = inputEnumeratorPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let preservesLegacyDefinition = trimmedValidationPrompt == originalValidationPrompt
                && trimmedEnumeratorPrompt == originalInputEnumeratorPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return AcceptanceCriterion(
                id: id,
                name: trimmedName,
                validationPrompt: trimmedValidationPrompt,
                inputEnumeratorPrompt: trimmedEnumeratorPrompt.isEmpty ? nil : trimmedEnumeratorPrompt,
                waivable: waivable,
                origin: origin,
                validator: preservesLegacyDefinition ? originalValidator : nil,
                prepare: preservesLegacyDefinition ? originalPrepare : nil
            )
        }
    }

    /// Editing model for one step. The user holds full authority over the plan, so
    /// rows can be deleted outright (no tombstone requirement, unlike the worker).
    private struct EditableStep: Identifiable {
        let id: UUID
        var text: String
        var status: TaskStep.Status
        var note: String
        let origin: TaskAuthorship

        init(step: TaskStep) {
            id = step.id
            text = step.text
            status = step.status
            note = step.note ?? ""
            origin = step.origin
        }

        init() {
            id = UUID()
            text = ""
            status = .pending
            note = ""
            origin = .user
        }

        func built() -> TaskStep? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return TaskStep(
                id: id,
                text: trimmed,
                status: status,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                origin: origin
            )
        }
    }

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
        // Resolve across active + global archived/deleted: a detail window can be opened from any
        // bucket, and a task may move buckets while its window is open.
        let next = viewModel.anyTask(id: taskID)
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
        // The archived/deleted buckets are global; re-resolve when they change so a task that
        // moves into (or within) them while this window is open keeps rendering.
        .onChange(of: viewModel.archivedTaskList) { _, _ in
            DispatchQueue.main.async { syncTask() }
        }
        .onChange(of: viewModel.recentlyDeletedTaskList) { _, _ in
            DispatchQueue.main.async { syncTask() }
        }
        .alert(
            "Cannot Run Task",
            isPresented: $viewModel.hasTaskActionError,
            actions: { Button("OK") { viewModel.taskActionError = nil } },
            message: { Text(viewModel.taskActionError ?? "") }
        )
        .sheet(isPresented: $isShowingPDFSheet) {
            TaskPDFSaveSheet(
                options: $pdfOptions,
                onSave: {
                    isShowingPDFSheet = false
                    guard let task else { return }
                    Task { await viewModel.saveTaskPDF(task, options: pdfOptions) }
                },
                onCancel: { isShowingPDFSheet = false }
            )
        }
        .sheet(item: $templateRunInputTask) { task in
            TemplateRunInputSheet(
                task: task,
                onRun: { values in
                    templateRunInputTask = nil
                    Task { await viewModel.startTask(task, templateInputValues: values) }
                },
                onCancel: { templateRunInputTask = nil }
            )
        }
        .sheet(item: $taskEditorTask) { task in
            TaskEditorSheet(mode: .edit(task), viewModel: viewModel) {
                taskEditorTask = nil
            }
        }
    }

    // MARK: - Body

    /// A pinned bar of section chips at the top of the window: always visible, highlights the
    /// section currently under the viewport top, and jumps to a section on tap. Addresses "the
    /// detail view is long and I can't tell what section I'm in."
    @ViewBuilder
    private func sectionJumpBar(sections: [SectionKind], proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sections, id: \.self) { kind in
                    let isCurrent = kind == currentSection
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(SectionAnchorID(kind: kind), anchor: .top)
                        }
                        currentSection = kind
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: kind.icon)
                                .font(.caption2)
                            Text(kind.label)
                                .font(.caption.weight(isCurrent ? .semibold : .regular))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isCurrent ? AppColors.disclosureToggle.opacity(0.18) : Color.secondary.opacity(0.08))
                        )
                        .foregroundStyle(isCurrent ? AppColors.disclosureToggle : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    /// Sections that actually have content to show (or are editable), in canonical order — the set
    /// the jump bar offers.
    private func presentSections(_ task: AgentTask) -> [SectionKind] {
        orderedSections(for: task.status).filter { kind in
            switch kind {
            case .description:    return true
            case .error:          return task.status == .failed && !(task.result ?? "").isEmpty
            case .summary:        return !(task.summary ?? "").isEmpty
            case .result:         return !(task.result ?? "").isEmpty
            case .acceptance:     return !task.acceptanceCriteria.isEmpty || task.status.isValidationContractEditable
            case .steps:          return !task.steps.isEmpty || task.status.isValidationContractEditable
            case .updates:        return !task.updates.isEmpty
            case .relatedContext: return (task.relevantMemories?.isEmpty == false) || (task.relevantPriorTasks?.isEmpty == false)
            }
        }
    }

    private func taskContent(_ task: AgentTask) -> some View {
        let sections = presentSections(task)
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                sectionJumpBar(sections: sections, proxy: proxy)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerRow(task)
                        metadataSection(for: task)
                        Divider()
                        ForEach(orderedSections(for: task.status), id: \.self) { kind in
                            sectionView(kind, task: task)
                                .id(SectionAnchorID(kind: kind))
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: SectionOffsetKey.self,
                                            value: [SectionOffset(kind: kind, minY: geo.frame(in: .named("taskScroll")).minY)]
                                        )
                                    }
                                )
                        }
                        Divider()
                        Text("ID: \(task.id.uuidString)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    .padding(24)
                }
                .coordinateSpace(name: "taskScroll")
                .onPreferenceChange(SectionOffsetKey.self) { offsets in
                    // The current section is the last one whose top has crossed above a small band
                    // below the viewport top (so it counts as "current" just before it reaches the
                    // top). Falls back to the first present section.
                    let threshold: CGFloat = 80
                    let crossed = offsets.filter { $0.minY <= threshold }.max { $0.minY < $1.minY }
                    let next = crossed?.kind ?? sections.first ?? .description
                    if next != currentSection { currentSection = next }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle(task.title)
        // Lazy-load this task's cost + token totals. The id includes whether
        // the task is in a terminal status so the loader re-fires when a task
        // we're watching reaches `.completed` or `.failed`. `force: true`
        // evicts the in-progress partial values cached on first appear so the
        // final values replace them.
        .task(id: TaskCostLoaderKey(taskID: task.id, isTerminal: task.status.isTerminal)) {
            await viewModel.loadTaskCost(task.id, force: true)
            await viewModel.loadTaskTokens(task.id, force: true)
        }
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
            if task.status.isDescriptionEditable {
                Button {
                    taskEditorTask = task
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .help("Edit this task")
            }
            if task.status.isRunnable {
                Button {
                    startRunnableTask(task)
                } label: {
                    Label(runActionTitle(for: task.status), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Start this task now")
            }
            Button {
                isShowingPDFSheet = true
            } label: {
                Label("Save as PDF…", systemImage: "doc.richtext")
            }
            .help("Save this task as a PDF")
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func startRunnableTask(_ task: AgentTask) {
        if task.shouldPromptForTemplateRunInputs {
            templateRunInputTask = task
            return
        }
        Task { await viewModel.startTask(task) }
    }

    // MARK: - Section dispatch

    /// All sections that could ever render in this window, in the canonical order
    /// `orderedSections(for:)` filters from based on status.
    /// Distinct scroll-anchor identity for a content section. Kept separate from `SectionKind`
    /// (which the jump-bar chips already use as their `ForEach` id) so `scrollTo` resolves only
    /// to the section in the vertical scroll view, not the same-id chip in the jump bar.
    private struct SectionAnchorID: Hashable {
        let kind: SectionKind
    }

    private enum SectionKind: Hashable {
        case error
        case summary
        case result
        case acceptance
        case steps
        case updates
        case description
        case relatedContext

        var label: String {
            switch self {
            case .error:          return "Error"
            case .summary:        return "Summary"
            case .result:         return "Result"
            case .acceptance:     return "Acceptance"
            case .steps:          return "Steps"
            case .updates:        return "Updates"
            case .description:    return "Description"
            case .relatedContext: return "Context"
            }
        }

        var icon: String {
            switch self {
            case .error:          return "exclamationmark.triangle.fill"
            case .summary:        return "text.quote"
            case .result:         return "checkmark.seal.fill"
            case .acceptance:     return "checklist"
            case .steps:          return "list.bullet"
            case .updates:        return "clock.arrow.circlepath"
            case .description:    return "doc.text"
            case .relatedContext: return "link"
            }
        }
    }

    /// The section whose top is currently nearest the scroll viewport top — highlighted in the jump
    /// bar so the user always knows where they are. Updated from scroll-offset preferences.
    @State private var currentSection: SectionKind = .description

    /// Reports each section's top offset within the scroll coordinate space so `currentSection`
    /// can be derived on scroll.
    private struct SectionOffsetKey: PreferenceKey {
        static let defaultValue: [SectionOffset] = []
        static func reduce(value: inout [SectionOffset], nextValue: () -> [SectionOffset]) {
            value.append(contentsOf: nextValue())
        }
    }
    private struct SectionOffset: Equatable {
        let kind: SectionKind
        let minY: CGFloat
    }

    private enum SectionMode {
        case hidden
        case preview
        case expanded
    }

    private func orderedSections(for status: AgentTask.Status) -> [SectionKind] {
        // `.acceptance` and `.steps` render nothing when the task has no criteria/steps,
        // so they can be listed unconditionally.
        switch status {
        case .pending, .scheduled:
            return [.description, .acceptance, .steps, .relatedContext]
        case .starting, .running, .paused, .interrupted, .awaitingReview, .validating:
            return [.updates, .acceptance, .steps, .description, .relatedContext]
        case .completed:
            return [.summary, .result, .acceptance, .steps, .updates, .description, .relatedContext]
        case .failed:
            return [.error, .summary, .result, .acceptance, .steps, .updates, .description, .relatedContext]
        }
    }

    /// True while the task is in an active validation loop. During that loop the status
    /// OSCILLATES between `.validating` (judging) and `.running` (worker reworking a rejection)
    /// once per round. If the acceptance section's default expansion keyed on the raw status it
    /// would expand and collapse on every round, yanking the scroll position out from under the
    /// user — so the sections key on this stable flag instead.
    private func validationActive(_ task: AgentTask) -> Bool {
        guard !task.acceptanceCriteria.isEmpty else { return false }
        switch task.status {
        case .validating, .awaitingReview:
            return true
        case .running, .paused, .interrupted:
            // Mid-rework between rejection and resubmission still counts as "in the loop"
            // once at least one validation round has run.
            return (task.validation?.round ?? 0) > 0
        default:
            return false
        }
    }

    /// Default mode for a section, driven by task status EXCEPT for acceptance, which keys on the
    /// stable `validationActive` flag so it doesn't oscillate. The user can override to/from
    /// `.preview` and `.expanded` via the header chevron; `.hidden` is not user-toggleable.
    private func defaultMode(_ kind: SectionKind, for task: AgentTask) -> SectionMode {
        let status = task.status
        switch (kind, status) {
        case (.error, .failed):                       return .expanded
        case (.error, _):                             return .hidden

        case (.description, .pending), (.description, .scheduled):
            return .expanded
        case (.description, _):                       return .preview

        case (.relatedContext, _):                    return .preview

        // Front-and-center throughout the validation loop; compact otherwise. Keyed on the
        // stable flag, not the raw status, so the validating↔running oscillation doesn't flip it.
        case (.acceptance, _):
            return validationActive(task) ? .expanded : .preview

        case (.steps, _):                             return .preview

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

    private func currentMode(_ kind: SectionKind, for task: AgentTask) -> SectionMode {
        if let overridden = modeOverrides[kind] { return overridden }
        return defaultMode(kind, for: task)
    }

    private func toggleSection(_ kind: SectionKind, for task: AgentTask) {
        let next: SectionMode
        switch currentMode(kind, for: task) {
        case .preview, .hidden:  next = .expanded
        case .expanded:          next = .preview
        }
        modeOverrides[kind] = next
    }

    @ViewBuilder
    private func sectionView(_ kind: SectionKind, task: AgentTask) -> some View {
        let mode = currentMode(kind, for: task)
        if mode != .hidden {
            switch kind {
            case .error:           errorSection(task)
            case .summary:         summarySection(task, mode: mode)
            case .result:          resultSection(task)
            case .acceptance:      acceptanceSection(task, mode: mode)
            case .steps:           stepsSection(task, mode: mode)
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
                        toggleSection(.summary, for: task)
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

        // Structured deliverables (when the worker submitted them): the tagged text/attachment
        // items. Files are shown by name here (the clickable cards live in Result Attachments
        // below); the value of this section is the inline text answers and the per-requirement
        // tags. Skipped for tasks that never produced structured items.
        if !task.resultItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Deliverables", copyText: DeliverablesView.plainText(task.resultItems))
                DeliverablesView(items: task.resultItems, urlResolver: attachmentURLResolver)
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

    // MARK: - Acceptance criteria + validation

    @ViewBuilder
    private func acceptanceSection(_ task: AgentTask, mode: SectionMode) -> some View {
        // Shown when the task has criteria OR when the user could author some
        // (an editable empty state offers the pencil).
        if !task.acceptanceCriteria.isEmpty || task.status.isValidationContractEditable {
            let ledger = task.validation
            // Intersect with the CURRENT criteria — the ledger can hold records for
            // criteria that were since edited/removed ("4 of 3 settled").
            let settledIDs = ledger?.settledCriterionIDs() ?? []
            let settled = Set(task.acceptanceCriteria.map(\.id).filter { settledIDs.contains($0) })
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Acceptance")
                        .font(.title3.bold())
                    if !task.acceptanceCriteria.isEmpty {
                        Text(acceptanceSubtitle(task: task, settledCount: settled.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !task.acceptanceCriteria.isEmpty {
                        copyButton(text: Self.formattedAcceptance(task), id: "Acceptance")
                    }
                    if task.status.isValidationContractEditable && !isEditingAcceptance {
                        Button {
                            beginEditingAcceptance(task)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Edit acceptance criteria")
                    }
                }

                if isEditingAcceptance {
                    acceptanceEditor(task)
                } else if task.acceptanceCriteria.isEmpty {
                    Text("No acceptance criteria — validation will run the default whole-task check.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: mode == .expanded ? 12 : 6) {
                        ForEach(Array(task.acceptanceCriteria.enumerated()), id: \.element.id) { index, criterion in
                            criterionRow(criterion, number: index + 1, task: task, expanded: mode == .expanded)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DisclosureMoreLessLink(isExpanded: mode == .expanded) {
                        toggleSection(.acceptance, for: task)
                    }
                }
            }
            Divider()
        }
    }

    private func beginEditingAcceptance(_ task: AgentTask) {
        editedCriteria = task.acceptanceCriteria.map(EditableCriterion.init)
        if editedCriteria.isEmpty { editedCriteria = [EditableCriterion()] }
        isEditingAcceptance = true
    }

    @ViewBuilder
    private func acceptanceEditor(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($editedCriteria) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("Display name", text: $row.name)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            editedCriteria.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove criterion")
                    }
                    TextField("Validation prompt — required LLM instructions", text: $row.validationPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    TextField("Input enumerator prompt (optional; must return an array of strings)", text: $row.inputEnumeratorPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 12) {
                        Toggle("Waivable", isOn: $row.waivable)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        Spacer()
                    }
                }
            }
            Button {
                editedCriteria.append(EditableCriterion())
            } label: {
                Label("Add criterion", systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.disclosureToggle)

            HStack {
                Text("Removing all criteria reverts to the default whole-task check. Edited criteria are re-judged; unchanged ones keep their verdicts.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    isEditingAcceptance = false
                }
                Button("Save") {
                    let criteria = editedCriteria.compactMap { $0.built() }
                    Task {
                        await viewModel.setTaskAcceptanceCriteria(id: task.id, criteria: criteria)
                    }
                    isEditingAcceptance = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func acceptanceSubtitle(task: AgentTask, settledCount: Int) -> String {
        "\(settledCount) of \(task.acceptanceCriteria.count) settled"
    }

    @ViewBuilder
    private func criterionRow(_ criterion: AcceptanceCriterion, number: Int, task: AgentTask, expanded: Bool) -> some View {
        let latest = task.validation?.latestVerdict(for: criterion.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Stable criterion number — matches the number in Brown's briefing, in
                // get_task_details, and in the validator's rejection punch list ("Criterion 5").
                Text("\(number).")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    // Verdict as a LABELED chip on its own line above the body — icon + the
                    // verdict WORD, always shown (an accepted criterion previously showed only a
                    // bare icon). Separating it from the body means the criterion's own in-text
                    // "…this criterion FAILS" can never be read as the verdict.
                    Label(latest?.verdict.displayLabel ?? "Pending", systemImage: Self.verdictSymbol(latest?.verdict))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.verdictColor(latest?.verdict))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Self.verdictColor(latest?.verdict).opacity(0.15)))
                    Text(criterion.name)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let qualifiers = Self.criterionQualifiers(criterion) {
                        Text(qualifiers)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let latest, let detail = latest.verdict.detailText {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(Self.verdictColor(latest.verdict))
                            .lineLimit(expanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if expanded {
                criterionExpandedDetail(criterion, task: task)
                    .padding(.leading, 24)
            }
        }
    }

    /// Expanded per-criterion detail: the pinned validator prompt and the full verdict
    /// history with per-record debug transcripts — the assessment-debugging surface.
    @ViewBuilder
    private func criterionExpandedDetail(_ criterion: AcceptanceCriterion, task: AgentTask) -> some View {
        let records = (task.validation?.verdictRecords ?? []).filter { $0.criterionID == criterion.id }
        VStack(alignment: .leading, spacing: 6) {
            debugTextBox(title: "Validation prompt", text: criterion.validationPrompt)
            if let inputEnumeratorPrompt = criterion.inputEnumeratorPrompt {
                debugTextBox(title: "Input enumerator prompt", text: inputEnumeratorPrompt)
            }
            if let pinned = Self.pinnedDefinition(for: criterion, in: task) {
                Button {
                    if expandedValidatorPromptIDs.contains(criterion.id) {
                        expandedValidatorPromptIDs.remove(criterion.id)
                    } else {
                        expandedValidatorPromptIDs.insert(criterion.id)
                    }
                } label: {
                    Label(
                        expandedValidatorPromptIDs.contains(criterion.id)
                            ? "Hide validator prompt (\(pinned.name))"
                            : "Validator prompt (\(pinned.name))",
                        systemImage: "text.alignleft"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.disclosureToggle)
                if expandedValidatorPromptIDs.contains(criterion.id) {
                    debugTextBox(title: "Validator definition — base prompt (the criterion & response format are appended at judge time; see a round's debug for the full sent prompt)", text: pinned.systemPrompt)
                }
            }
            ForEach(records.reversed()) { record in
                verdictRecordRow(record)
            }
        }
    }

    @ViewBuilder
    private func verdictRecordRow(_ record: CriterionVerdictRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: Self.verdictSymbol(record.verdict))
                    .foregroundStyle(Self.verdictColor(record.verdict))
                    .font(.caption)
                Text("Round \(record.round) · \(record.verdict.displayLabel) · \(record.validatorName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.recordedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if record.renderedInput != nil || record.responseLog != nil {
                    Button {
                        if expandedDebugRecordIDs.contains(record.id) {
                            expandedDebugRecordIDs.remove(record.id)
                        } else {
                            expandedDebugRecordIDs.insert(record.id)
                        }
                    } label: {
                        Text(expandedDebugRecordIDs.contains(record.id) ? "hide debug" : "debug")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.disclosureToggle)
                }
            }
            if let detail = record.verdict.detailText {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 18)
            }
            if expandedDebugRecordIDs.contains(record.id) {
                VStack(alignment: .leading, spacing: 6) {
                    if let sys = record.renderedSystemPrompt, !sys.isEmpty {
                        debugTextBox(title: "System prompt (exactly as sent — includes the criterion & response format)", text: sys)
                    }
                    if let input = record.renderedInput, !input.isEmpty {
                        debugTextBox(title: "User message (the results/evidence the validator judged)", text: input)
                    }
                    if let log = record.responseLog, !log.isEmpty {
                        debugTextBox(title: "Validator output (turn by turn)", text: log)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private func debugTextBox(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                copyButton(text: text, id: title + String(text.prefix(24)))
            }
            ScrollView(.vertical) {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 220)
            .background(AppColors.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private static func verdictSymbol(_ verdict: CriterionVerdictRecord.Verdict?) -> String {
        switch verdict {
        case .accepted: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .waived: return "minus.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case nil: return "circle"
        }
    }

    private static func verdictColor(_ verdict: CriterionVerdictRecord.Verdict?) -> Color {
        switch verdict {
        case .accepted: return AppColors.verdictAccepted
        case .rejected: return AppColors.verdictRejected
        case .waived: return AppColors.verdictWaived
        case .error: return AppColors.verdictError
        case nil: return AppColors.verdictPending
        }
    }

    private static func criterionQualifiers(_ criterion: AcceptanceCriterion) -> String? {
        var parts: [String] = []
        if criterion.waivable { parts.append("waivable") }
        if criterion.inputEnumeratorPrompt != nil { parts.append("enumerated inputs") }
        // Legacy persisted tasks may still show their historical registry qualifier.
        switch criterion.validator {
        case .registry(let name): parts.append("validator: \(name)")
        case .inline(let definition): parts.append("validator: \(definition.name) (inline)")
        case nil: break
        }
        if let prepare = criterion.prepare { parts.append("legacy prepare: \(prepare)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func pinnedDefinition(for criterion: AcceptanceCriterion, in task: AgentTask) -> EvaluatorDefinition? {
        switch criterion.validator {
        case .inline(let definition):
            return definition
        case .registry(let name):
            return task.validation?.pinnedDefinitions[name]
        case nil:
            return task.validation?.pinnedDefinitions[EvaluatorDefaults.defaultDefinition.name]
        }
    }

    private static func formattedAcceptance(_ task: AgentTask) -> String {
        task.acceptanceCriteria.map { criterion in
            var line = "- \(criterion.name)"
            if let qualifiers = criterionQualifiers(criterion) { line += " (\(qualifiers))" }
            if let latest = task.validation?.latestVerdict(for: criterion.id) {
                line += "\n  \(latest.verdict.displayLabel)"
                if let detail = latest.verdict.detailText { line += ": \(detail)" }
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Worker steps

    @ViewBuilder
    private func stepsSection(_ task: AgentTask, mode: SectionMode) -> some View {
        if !task.steps.isEmpty || task.status.isValidationContractEditable {
            let visible = mode == .expanded ? task.steps : task.steps.filter(\.isActive)
            let completedCount = task.steps.filter { $0.status == .completed }.count
            let activeCount = task.steps.filter(\.isActive).count
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Steps")
                        .font(.title3.bold())
                    if !task.steps.isEmpty {
                        Text("\(completedCount) of \(activeCount) completed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !task.steps.isEmpty {
                        copyButton(text: Self.formattedSteps(task.steps), id: "Steps")
                    }
                    if task.status.isValidationContractEditable && !isEditingSteps {
                        Button {
                            beginEditingSteps(task)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Edit steps")
                    }
                }

                if isEditingSteps {
                    stepsEditor(task)
                } else if task.steps.isEmpty {
                    Text("No steps yet — the worker plans its own; seed some here if you want to steer it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(visible) { step in
                            stepRow(step)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if task.steps.contains(where: { !$0.isActive }) || mode == .expanded {
                        DisclosureMoreLessLink(isExpanded: mode == .expanded) {
                            toggleSection(.steps, for: task)
                        }
                    }
                }
            }
            Divider()
        }
    }

    private func beginEditingSteps(_ task: AgentTask) {
        editedSteps = task.steps.map(EditableStep.init)
        if editedSteps.isEmpty { editedSteps = [EditableStep()] }
        isEditingSteps = true
    }

    /// Skipped/removed steps must say why — validators read the notes, and the rule
    /// applies to the user's editor the same as the worker's tool.
    private var stepsMissingRequiredNotes: Bool {
        editedSteps.contains { row in
            (row.status == .skipped || row.status == .removed)
                && !row.text.trimmingCharacters(in: .whitespaces).isEmpty
                && row.note.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    @ViewBuilder
    private func stepsEditor(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($editedSteps) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Picker("", selection: $row.status) {
                            Text("Pending").tag(TaskStep.Status.pending)
                            Text("In progress").tag(TaskStep.Status.inProgress)
                            Text("Completed").tag(TaskStep.Status.completed)
                            Text("Skipped").tag(TaskStep.Status.skipped)
                            Text("Removed").tag(TaskStep.Status.removed)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        TextField("Step", text: $row.text, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            editedSteps.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Delete step")
                    }
                    if row.status == .skipped || row.status == .removed || !row.note.isEmpty {
                        TextField("Note — why was this skipped/removed?", text: $row.note)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .padding(.leading, 118)
                    }
                }
            }
            Button {
                editedSteps.append(EditableStep())
            } label: {
                Label("Add step", systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.disclosureToggle)

            if stepsMissingRequiredNotes {
                Text("Skipped and removed steps need a note — validators read it.")
                    .font(.caption)
                    .foregroundStyle(AppColors.verdictError)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isEditingSteps = false
                }
                Button("Save") {
                    let steps = editedSteps.compactMap { $0.built() }
                    Task {
                        await viewModel.setTaskSteps(id: task.id, steps: steps)
                    }
                    isEditingSteps = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(stepsMissingRequiredNotes)
            }
        }
    }

    private func stepRow(_ step: TaskStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.stepSymbol(step.status))
                .foregroundStyle(Self.stepColor(step.status))
                .font(.callout)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.text)
                    .font(.body)
                    .strikethrough(step.status == .removed)
                    .foregroundStyle(step.status == .removed ? .secondary : .primary)
                    .textSelection(.enabled)
                if let note = step.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private static func stepSymbol(_ status: TaskStep.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle"
        case .removed: return "trash.circle"
        }
    }

    private static func stepColor(_ status: TaskStep.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return AppColors.stepInProgress
        case .completed: return AppColors.stepCompleted
        case .skipped: return AppColors.stepSkipped
        case .removed: return AppColors.stepRemoved
        }
    }

    private static func formattedSteps(_ steps: [TaskStep]) -> String {
        steps.map { step in
            var line = "- [\(step.status.rawValue)] \(step.text)"
            if let note = step.note, !note.isEmpty { line += " — \(note)" }
            return line
        }.joined(separator: "\n")
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
                        toggleSection(.updates, for: task)
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
                    toggleSection(.description, for: task)
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

            if let outcome = task.outcome {
                GridRow(alignment: .firstTextBaseline) {
                    metadataLabel("Result")
                    HStack(spacing: 8) {
                        TaskOutcomeChip(outcome: outcome)
                        Text(outcome.detailText)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GridRow {
                metadataLabel("Template")
                templateLine(for: task)
            }

            if let parentTaskID = task.parentTaskID {
                GridRow {
                    metadataLabel("Parent")
                    copyablePath(parentTaskID.uuidString, compact: true)
                }
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

            if let elapsed = task.elapsedDisplayString {
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

            let wakes = viewModel.scheduledWakes(for: task.id)
            if !wakes.isEmpty {
                GridRow(alignment: .top) {
                    metadataLabel(wakes.count == 1 ? "Next Run" : "Next Runs")
                    scheduledWakesLine(wakes)
                }
            }

            if let tokens = viewModel.cachedTaskTokens(task.id), tokens.total > 0 {
                GridRow {
                    metadataLabel("Tokens")
                    Text(tokens.formattedLine())
                        .monospacedDigit()
                }
            }

            if let cost = viewModel.cachedTaskCost(task.id), cost > 0 {
                GridRow {
                    metadataLabel("Cost")
                    HStack(spacing: 6) {
                        Text(String(format: "$%.2f", cost))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                        if let ratePerHour = task.costPerHourString(cost: cost) {
                            Text("(\(ratePerHour))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if task.approvedTools != nil || task.status.isRunnable || task.status == .scheduled || task.isTemplate {
                GridRow(alignment: .top) {
                    metadataLabel("Tools")
                    TaskToolOverrideEditor(task: task, viewModel: viewModel)
                }
            }

            let workspaceRows = viewModel.workspaceReferences(for: task)
            if !workspaceRows.isEmpty {
                GridRow(alignment: .top) {
                    metadataLabel("Folders")
                    workspaceLines(workspaceRows)
                }
            }
        }
        .font(.callout)
    }

    private func templateLine(for task: AgentTask) -> some View {
        HStack(spacing: 8) {
            if task.isTemplate {
                Label("Template", systemImage: "doc.on.doc")
                    .foregroundStyle(AppColors.scheduledFutureAccent)
            } else if task.parentTaskID != nil {
                Label("Template instance", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
            } else {
                Text("No")
                    .foregroundStyle(.secondary)
            }
            if task.isTemplate && task.shouldPromptForTemplateRunInputs {
                Text("\(task.templateInputDefinitions.count) input\(task.templateInputDefinitions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scheduledWakesLine(_ wakes: [ScheduledWake]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(wakes, id: \.id) { wake in
                HStack(spacing: 6) {
                    Image(systemName: wake.recurrence == nil ? "clock" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(TaskStatusBadge.color(for: .scheduled))
                    scheduledLine(for: wake.wakeAt)
                    if let recurrence = wake.recurrence {
                        Text(recurrence.displayDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func workspaceLines(_ rows: [(label: String, path: String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    copyablePath(row.path, compact: false)
                }
            }
        }
    }

    private func copyablePath(_ text: String, compact: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(compact ? .caption.monospaced() : .caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            copyButton(text: text, id: text)
        }
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
