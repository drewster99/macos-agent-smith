import SwiftUI
import AgentSmithKit

// MARK: - Text

/// Plain-language text for task watches, shared by Task Detail and the Timers window.
enum TaskWatchText {
    /// "completes", "completes or fails", "starts, completes or fails".
    static func triggers(_ triggers: Set<TaskWatchTrigger>) -> String {
        let ordered = TaskWatchTrigger.allCases.filter { triggers.contains($0) }.map(\.displayName)
        guard let last = ordered.last else { return "" }
        let leading = ordered.dropLast()
        return leading.isEmpty ? last : "\(leading.joined(separator: ", ")) or \(last)"
    }

    static func action(_ action: TaskWatchAction, targetTitle: String?) -> String {
        switch action {
        case .startTask(let targetID):
            return "start \u{201C}\(targetTitle ?? targetID.uuidString)\u{201D}"
        case .macOSNotification:
            return "post a macOS notification"
        case .summarizeToUser:
            return "Smith sends you a summary"
        case .instructSmith(let text):
            return "Smith: \(text)"
        }
    }

    static func summary(_ watch: TaskWatch, targetTitle: String?) -> String {
        "When this task \(triggers(watch.triggers)) → \(action(watch.action, targetTitle: targetTitle))"
    }

    static func state(_ watch: TaskWatch) -> String {
        let lifetime = watch.lifetime == .once ? "once" : "every time"
        switch watch.state {
        case .active: return "Active · \(lifetime)"
        case .cancelled: return "Cancelled"
        case .consumed: return "Fired (once)"
        }
    }

    static func lastFiring(_ watch: TaskWatch) -> String? {
        guard let firing = watch.recentFirings.last else { return nil }
        switch firing.state {
        case .pending, .inFlight: return "Firing #\(firing.occurrence) in progress"
        case .delivered(let at): return "Last fired \(at.formatted(date: .abbreviated, time: .shortened))"
        case .refused(let reason): return "Last firing could not be carried out: \(reason)"
        case .cancelled: return "Last firing cancelled"
        }
    }

    static func lastFiringFailed(_ watch: TaskWatch) -> Bool {
        if case .refused = watch.recentFirings.last?.state { return true }
        return false
    }
}

// MARK: - Task Detail section

/// Task Detail's "When this task…" section: the task's watches, the watches holding it, and an
/// editor for adding one.
struct TaskWatchesSection: View {
    let task: AgentTask
    let viewModel: AppViewModel

    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaskWatchesHeader(onAdd: { showEditor = true })
            TaskHoldList(holds: task.startHolds, viewModel: viewModel)
            TaskWatchList(task: task, viewModel: viewModel)
        }
        .sheet(isPresented: $showEditor) {
            TaskWatchEditorSheet(task: task, viewModel: viewModel, onDismiss: { showEditor = false })
        }
        Divider()
    }
}

private struct TaskWatchesHeader: View {
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("When this task\u{2026}")
                .font(.title3.bold())
            Spacer()
            Button(action: onAdd, label: {
                Label("Add Watch", systemImage: "plus")
            })
            .buttonStyle(.borderless)
            .help("React when this task starts, finishes, fails, or needs attention")
        }
    }
}

private struct TaskHoldList: View {
    let holds: [TaskStartHold]
    let viewModel: AppViewModel

    var body: some View {
        ForEach(holds, id: \.watchID) { hold in
            Label(
                "Waiting on \u{201C}\(viewModel.anyTask(id: hold.watchedTaskID)?.title ?? hold.watchedTaskID.uuidString)\u{201D} — a watch starts this task. Press Play to start it now.",
                systemImage: "hourglass"
            )
            .font(.callout)
            .foregroundStyle(AppColors.watchHold)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.watchHoldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct TaskWatchList: View {
    let task: AgentTask
    let viewModel: AppViewModel

    var body: some View {
        ForEach(task.watches, id: \.id) { watch in
            TaskWatchRow(
                watch: watch,
                targetTitle: TaskWatchTargetTitle.resolve(watch, viewModel: viewModel),
                onCancel: { Task { await viewModel.cancelTaskWatch(watch.id, on: task.id) } }
            )
        }
        if task.watches.isEmpty && task.startHolds.isEmpty {
            Text("No watches. Add one to start another task, notify you, or brief Smith when this task changes state.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// The title of a startTask watch's target, when it has one.
enum TaskWatchTargetTitle {
    @MainActor
    static func resolve(_ watch: TaskWatch, viewModel: AppViewModel) -> String? {
        guard case .startTask(let targetID) = watch.action else { return nil }
        return viewModel.anyTask(id: targetID)?.title
    }
}

/// One watch: what it does, whether it is live, how its last firing went, and a cancel button.
struct TaskWatchRow: View {
    let watch: TaskWatch
    let targetTitle: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bell.badge")
                .foregroundStyle(watch.isActive ? AppColors.watchActive : AppColors.watchInactive)
            VStack(alignment: .leading, spacing: 2) {
                Text(TaskWatchText.summary(watch, targetTitle: targetTitle))
                    .font(.body)
                Text([TaskWatchText.state(watch), TaskWatchText.lastFiring(watch)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(TaskWatchText.lastFiringFailed(watch) ? AppColors.watchRefused : .secondary)
            }
            Spacer()
            Button("Cancel", role: .destructive, action: onCancel)
                .buttonStyle(.borderless)
                .opacity(watch.isActive ? 1 : 0)
                .disabled(!watch.isActive)
                .help("Stop this watch. Its history is kept.")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor

/// The watch editor: which states, what to do, and how often.
struct TaskWatchEditorSheet: View {
    let task: AgentTask
    let viewModel: AppViewModel
    let onDismiss: () -> Void

    @State private var draft = TaskWatchDraft()
    @State private var targetCandidates: [AgentTask] = []
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("When \u{201C}\(task.title)\u{201D}\u{2026}")
                .font(.title3.bold())
            TaskWatchTriggerPicker(triggers: $draft.triggers)
            TaskWatchActionFields(draft: $draft, targetCandidates: targetCandidates, allowsStartTask: !task.isTemplate)
            TaskWatchLifetimePicker(draft: $draft)
            TaskWatchEditorFooter(errorMessage: errorMessage, canSave: draft.isComplete && !isSaving, onCancel: onDismiss, onSave: save)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: loadCandidates)
    }

    private func loadCandidates() {
        targetCandidates = viewModel.tasks
            .filter { $0.id != task.id && !$0.isTemplate && $0.disposition == .active && $0.status.isRunnable }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func save() {
        guard let watch = draft.makeWatch() else { return }
        isSaving = true
        Task {
            let refusal = await viewModel.addTaskWatch(watch, to: task.id)
            isSaving = false
            if let refusal {
                errorMessage = refusal
            } else {
                onDismiss()
            }
        }
    }
}

/// What the user has filled in so far.
struct TaskWatchDraft {
    enum Action: String, CaseIterable, Identifiable {
        case startTask
        case macOSNotification
        case summarizeToUser
        case instructSmith

        var id: String { rawValue }

        var label: String {
            switch self {
            case .startTask: return "Start another task"
            case .macOSNotification: return "Post a macOS notification"
            case .summarizeToUser: return "Have Smith send me a summary"
            case .instructSmith: return "Give Smith instructions"
            }
        }
    }

    var triggers: Set<TaskWatchTrigger> = [.completed]
    var action: Action = .macOSNotification
    var targetTaskID: UUID?
    var instructions = ""
    /// Nil keeps the action's default (start another task → once; the rest → every time).
    var lifetime: TaskWatchLifetime?

    var isComplete: Bool {
        guard !triggers.isEmpty else { return false }
        switch action {
        case .startTask: return targetTaskID != nil
        case .instructSmith: return !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .macOSNotification, .summarizeToUser: return true
        }
    }

    func makeWatch() -> TaskWatch? {
        let watchAction: TaskWatchAction
        switch action {
        case .startTask:
            guard let targetTaskID else { return nil }
            watchAction = .startTask(taskID: targetTaskID)
        case .macOSNotification:
            watchAction = .macOSNotification
        case .summarizeToUser:
            watchAction = .summarizeToUser
        case .instructSmith:
            watchAction = .instructSmith(instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return TaskWatch(triggers: triggers, action: watchAction, lifetime: lifetime, createdBy: .user)
    }
}

private struct TaskWatchTriggerPicker: View {
    @Binding var triggers: Set<TaskWatchTrigger>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("reaches any of these states:")
                .foregroundStyle(.secondary)
            ForEach(TaskWatchTrigger.allCases, id: \.self) { trigger in
                Toggle(trigger.displayName.capitalizedFirstLetter, isOn: Binding(
                    get: { triggers.contains(trigger) },
                    set: { isOn in
                        if isOn { triggers.insert(trigger) } else { triggers.remove(trigger) }
                    }
                ))
            }
        }
    }
}

private struct TaskWatchActionFields: View {
    @Binding var draft: TaskWatchDraft
    let targetCandidates: [AgentTask]
    let allowsStartTask: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Then", selection: $draft.action) {
                ForEach(TaskWatchDraft.Action.allCases.filter { allowsStartTask || $0 != .startTask }) { action in
                    Text(action.label).tag(action)
                }
            }
            if draft.action == .startTask {
                TaskWatchTargetPicker(targetTaskID: $draft.targetTaskID, candidates: targetCandidates)
            }
            if draft.action == .instructSmith {
                TextField("What Smith should do", text: $draft.instructions, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
    }
}

private struct TaskWatchTargetPicker: View {
    @Binding var targetTaskID: UUID?
    let candidates: [AgentTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Task", selection: $targetTaskID) {
                Text("Choose a task").tag(UUID?.none)
                ForEach(candidates, id: \.id) { candidate in
                    Text(candidate.title).tag(UUID?.some(candidate.id))
                }
            }
            Text("It waits until then: nothing starts it automatically, and only Play starts it early.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TaskWatchLifetimePicker: View {
    @Binding var draft: TaskWatchDraft

    var body: some View {
        Picker("Fire", selection: $draft.lifetime) {
            Text("Default (\(draft.action == .startTask ? "once" : "every time"))").tag(TaskWatchLifetime?.none)
            Text("Once").tag(TaskWatchLifetime?.some(.once))
            Text("Every time").tag(TaskWatchLifetime?.some(.everyTime))
        }
    }
}

private struct TaskWatchEditorFooter: View {
    let errorMessage: String?
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(errorMessage ?? "")
                .font(.callout)
                .foregroundStyle(AppColors.watchRefused)
                .opacity(errorMessage == nil ? 0 : 1)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Watch", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}

// MARK: - Timers window

/// Every watch in the session, for the Timers window's Watches tab.
struct SessionWatchesList: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        let rows = viewModel.tasks.flatMap { task in task.watches.map { SessionWatchEntry(task: task, watch: $0) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    SessionWatchRow(entry: row, viewModel: viewModel)
                }
            }
        }
        .overlay {
            ContentUnavailableView(
                "No watches",
                systemImage: "bell.badge",
                description: Text("Add one from a task's detail window, or ask Smith (\u{201C}when this finishes, start that\u{201D}).")
            )
            .opacity(rows.isEmpty ? 1 : 0)
        }
    }
}

private struct SessionWatchEntry: Identifiable {
    let task: AgentTask
    let watch: TaskWatch
    var id: UUID { watch.id }
}

private struct SessionWatchRow: View {
    let entry: SessionWatchEntry
    let viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(entry.task.title, systemImage: "rectangle.stack")
                .font(.caption)
                .foregroundStyle(.secondary)
            TaskWatchRow(
                watch: entry.watch,
                targetTitle: TaskWatchTargetTitle.resolve(entry.watch, viewModel: viewModel),
                onCancel: { Task { await viewModel.cancelTaskWatch(entry.watch.id, on: entry.task.id) } }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
