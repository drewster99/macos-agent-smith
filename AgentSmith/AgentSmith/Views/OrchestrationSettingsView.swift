import SwiftUI
import AgentSmithKit

/// The Orchestration override editor — shared by the app-wide Settings tab and the per-session
/// sheet. Each row is a tri-state (Inherit / Force-on / Force-off) over a sparse override, reusing
/// the same `OverrideTriStateRow` the per-model override sheets use, with the resolved effective
/// value shown on the trailing edge. The only thing that differs between the two contexts is WHERE
/// the override is read/written and what it resolves against — captured by `OrchestrationOverrideTarget`.

/// Which override the editor is bound to. Reading `override`/`resolved` from a view body registers
/// the underlying `@Observable` dependency, so edits re-render live in both contexts.
enum OrchestrationOverrideTarget {
    /// The app-wide override, resolved against the shipped/downloaded defaults.
    case appWide(SharedAppState)
    /// One session's override, resolved against the app-wide effective default.
    case session(AppViewModel)

    var override: OrchestrationSettingsOverride {
        switch self {
        case .appWide(let shared): return shared.orchestrationAppOverride
        case .session(let vm): return vm.orchestrationOverride ?? OrchestrationSettingsOverride()
        }
    }

    /// The value this layer actually resolves to (baseline + this override), shown as "Resolved".
    var resolved: OrchestrationSettings {
        switch self {
        case .appWide(let shared): return shared.effectiveOrchestrationDefault
        case .session(let vm): return vm.resolvedOrchestrationSettings
        }
    }

    var isEmpty: Bool {
        switch self {
        case .appWide(let shared): return shared.orchestrationAppOverride.isEmpty
        case .session(let vm): return vm.orchestrationOverride?.isEmpty ?? true
        }
    }

    func write(_ keyPath: WritableKeyPath<OrchestrationSettingsOverride, Bool?>, _ value: TriStateOverride) {
        switch self {
        case .appWide(let shared):
            var o = shared.orchestrationAppOverride
            o[keyPath: keyPath] = value.asOptional
            shared.setOrchestrationAppOverride(o)
        case .session(let vm):
            var o = vm.orchestrationOverride ?? OrchestrationSettingsOverride()
            o[keyPath: keyPath] = value.asOptional
            vm.orchestrationOverride = o.isEmpty ? nil : o   // empty normalizes back to "inherit"
        }
    }

    func reset() {
        switch self {
        case .appWide(let shared): shared.resetOrchestrationAppOverride()
        case .session(let vm): vm.orchestrationOverride = nil
        }
    }
}

// MARK: - App-wide Settings tab

struct OrchestrationSettingsView: View {
    @Bindable var shared: SharedAppState

    var body: some View {
        let target = OrchestrationOverrideTarget.appWide(shared)
        return VStack(alignment: .leading, spacing: 16) {
            OrchestrationOverrideHeader(
                title: "Orchestration",
                explanation: "App-wide defaults for how the agents coordinate. Each setting inherits the shipped default unless you force it on or off. A session can override any of these from the Session menu.",
                target: target)
            Divider()
            OrchestrationOverrideForm(target: target)
        }
    }
}

// MARK: - The shared form

struct OrchestrationOverrideForm: View {
    let target: OrchestrationOverrideTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SummarizerSettingsSection(target: target)
            Divider()
            RetrievalSettingsSection(target: target)
            Divider()
            ValidatorSettingsSection(target: target)
            Divider()
            SecuritySettingsSection(target: target)
        }
    }
}

// MARK: - Header

struct OrchestrationOverrideHeader: View {
    let title: String
    let explanation: String
    let target: OrchestrationOverrideTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(AppFonts.sectionHeader)
                Spacer()
                Button("Reset to defaults") { target.reset() }
                    .disabled(target.isEmpty)
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Reusable Bool override row

/// One tri-state override row over a single Bool field, with the resolved effective value shown.
struct BoolOverrideRow: View {
    let target: OrchestrationOverrideTarget
    let title: String
    let description: String
    let overrideKeyPath: WritableKeyPath<OrchestrationSettingsOverride, Bool?>
    let resolvedKeyPath: KeyPath<OrchestrationSettings, Bool>

    var body: some View {
        OverrideTriStateRow(
            title: title,
            resolved: target.resolved[keyPath: resolvedKeyPath],
            description: description,
            selection: Binding(
                get: { TriStateOverride(target.override[keyPath: overrideKeyPath]) },
                set: { target.write(overrideKeyPath, $0) }
            )
        )
    }
}

// MARK: - Summarizer

struct SummarizerSettingsSection: View {
    let target: OrchestrationOverrideTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summarizer").font(AppFonts.sectionHeader)
            BoolOverrideRow(target: target,
                title: "Summarize completed tasks",
                description: "Write a summary of each finished task (feeds prior-task search). Off completes tasks without summarizing.",
                overrideKeyPath: \.summarizeCompletedTasks,
                resolvedKeyPath: \.summarizeCompletedTasks)
            BoolOverrideRow(target: target,
                title: "Summarize for context compaction",
                description: "Use the summarizer to compact Smith's context at task boundaries. Off falls back to the deterministic sliding-window prune.",
                overrideKeyPath: \.summarizeForContextCompaction,
                resolvedKeyPath: \.summarizeForContextCompaction)
        }
    }
}

// MARK: - Memory & task search (grid)

struct RetrievalSettingsSection: View {
    let target: OrchestrationOverrideTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Memory & Task Search").font(AppFonts.sectionHeader)
            Text("Which retrieval runs at each point. Memory injects relevant saved memories; Prior tasks injects summaries of similar past work. Each cell inherits the baseline unless forced.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1).gridColumnAlignment(.leading)
                    Text("Memory").font(.caption.bold()).frame(width: 190)
                    Text("Prior tasks").font(.caption.bold()).frame(width: 190)
                }
                RetrievalGridRow(target: target, title: "New task",
                    memoryKeyPath: \.retrieval.newTask.memory, taskKeyPath: \.retrieval.newTask.task)
                RetrievalGridRow(target: target, title: "User message",
                    memoryKeyPath: \.retrieval.userMessage.memory, taskKeyPath: \.retrieval.userMessage.task)
                RetrievalGridRow(target: target, title: "Before validator review",
                    memoryKeyPath: \.retrieval.beforeValidatorReview.memory, taskKeyPath: \.retrieval.beforeValidatorReview.task)
                RetrievalGridRow(target: target, title: "Before security scoping",
                    memoryKeyPath: \.retrieval.beforeSecurityScoping.memory, taskKeyPath: \.retrieval.beforeSecurityScoping.task)
                RetrievalGridRow(target: target, title: "Before security tool review",
                    memoryKeyPath: \.retrieval.beforeSecurityToolReview.memory, taskKeyPath: \.retrieval.beforeSecurityToolReview.task)
            }
        }
    }
}

struct RetrievalGridRow: View {
    let target: OrchestrationOverrideTarget
    let title: String
    let memoryKeyPath: WritableKeyPath<OrchestrationSettingsOverride, Bool?>
    let taskKeyPath: WritableKeyPath<OrchestrationSettingsOverride, Bool?>

    var body: some View {
        GridRow {
            Text(title).gridColumnAlignment(.leading)
            TriStatePicker(selection: Binding(
                get: { TriStateOverride(target.override[keyPath: memoryKeyPath]) },
                set: { target.write(memoryKeyPath, $0) }))
                .frame(width: 190)
            TriStatePicker(selection: Binding(
                get: { TriStateOverride(target.override[keyPath: taskKeyPath]) },
                set: { target.write(taskKeyPath, $0) }))
                .frame(width: 190)
        }
    }
}

/// A compact segmented Inherit / On / Off picker — the grid-cell control for the retrieval matrix.
struct TriStatePicker: View {
    @Binding var selection: TriStateOverride

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(TriStateOverride.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - Validator

struct ValidatorSettingsSection: View {
    let target: OrchestrationOverrideTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Validator").font(AppFonts.sectionHeader)
            BoolOverrideRow(target: target,
                title: "Enable task-completion validators",
                description: "Judge each task's acceptance criteria on completion. Off completes tasks without validation, marked as not validated.",
                overrideKeyPath: \.enableTaskCompletionValidators,
                resolvedKeyPath: \.enableTaskCompletionValidators)
        }
    }
}

// MARK: - Security

struct SecuritySettingsSection: View {
    let target: OrchestrationOverrideTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Security Agent").font(AppFonts.sectionHeader)
            BoolOverrideRow(target: target,
                title: "Scope tool set on task start",
                description: "Let the Security Agent restrict a task's tools up front. Off gives the worker the full set (still recorded as the task's approved tools).",
                overrideKeyPath: \.scopeToolSetOnTaskStart,
                resolvedKeyPath: \.scopeToolSetOnTaskStart)
            Text("Review tool calls made by").font(.subheadline.bold())
            BoolOverrideRow(target: target,
                title: "Agent Smith",
                description: "Review Smith's tool calls (including its open-world / egress tools). Off auto-approves them, still recorded as review-disabled.",
                overrideKeyPath: \.reviewSmithToolCalls,
                resolvedKeyPath: \.reviewSmithToolCalls)
            BoolOverrideRow(target: target,
                title: "Agent Brown",
                description: "Review the worker's tool calls (bash, file, process). Off auto-approves them, still recorded as review-disabled.",
                overrideKeyPath: \.reviewBrownToolCalls,
                resolvedKeyPath: \.reviewBrownToolCalls)
            BoolOverrideRow(target: target,
                title: "Validators",
                description: "Review validator evidence reads (read-only). Off auto-approves them, still recorded as review-disabled.",
                overrideKeyPath: \.reviewValidatorToolCalls,
                resolvedKeyPath: \.reviewValidatorToolCalls)
        }
    }
}
