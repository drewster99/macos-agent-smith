import SwiftUI
import AgentSmithKit

/// The Orchestration settings tab: app-wide defaults for how the agents coordinate (summarizer,
/// memory/task retrieval, validator, security). Edits the sparse app-wide override layered over the
/// shipped/downloaded defaults; each row is a tri-state (Inherit / Force-on / Force-off), reusing the
/// same `OverrideTriStateRow` the per-model override sheets use. A session can override any of these
/// individually from the Session menu (see `SessionOrchestrationOverridesView`).

/// Writes one Bool axis of the app-wide orchestration override through the model's normalizing setter.
private func writeAppOverride(_ shared: SharedAppState,
                             _ keyPath: WritableKeyPath<OrchestrationSettingsOverride, Bool?>,
                             _ value: TriStateOverride) {
    var override = shared.orchestrationAppOverride
    override[keyPath: keyPath] = value.asOptional
    shared.setOrchestrationAppOverride(override)
}

struct OrchestrationSettingsView: View {
    @Bindable var shared: SharedAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OrchestrationOverrideHeader(shared: shared)
            Divider()
            SummarizerSettingsSection(shared: shared)
            Divider()
            RetrievalSettingsSection(shared: shared)
            Divider()
            ValidatorSettingsSection(shared: shared)
            Divider()
            SecuritySettingsSection(shared: shared)
        }
    }
}

// MARK: - Header

struct OrchestrationOverrideHeader: View {
    @Bindable var shared: SharedAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Orchestration").font(AppFonts.sectionHeader)
                Spacer()
                Button("Reset to defaults") { shared.resetOrchestrationAppOverride() }
                    .disabled(shared.orchestrationAppOverride.isEmpty)
            }
            Text("App-wide defaults for how the agents coordinate. Each setting inherits the shipped default unless you force it on or off. A session can override any of these from the Session menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Reusable Bool override row

/// One tri-state override row over a single Bool field of the app-wide orchestration override, with
/// the resolved effective value shown on the trailing edge.
struct BoolOverrideRow: View {
    @Bindable var shared: SharedAppState
    let title: String
    let description: String
    let overrideKeyPath: WritableKeyPath<OrchestrationSettingsOverride, Bool?>
    let resolvedKeyPath: KeyPath<OrchestrationSettings, Bool>

    var body: some View {
        let override = shared.orchestrationAppOverride
        let resolved = shared.effectiveOrchestrationDefault[keyPath: resolvedKeyPath]
        return OverrideTriStateRow(
            title: title,
            resolved: resolved,
            description: description,
            selection: Binding(
                get: { TriStateOverride(override[keyPath: overrideKeyPath]) },
                set: { writeAppOverride(shared, overrideKeyPath, $0) }
            )
        )
    }
}

// MARK: - Summarizer

struct SummarizerSettingsSection: View {
    @Bindable var shared: SharedAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summarizer").font(AppFonts.sectionHeader)
            BoolOverrideRow(shared: shared,
                title: "Summarize completed tasks",
                description: "Write a summary of each finished task (feeds prior-task search). Off completes tasks without summarizing.",
                overrideKeyPath: \.summarizeCompletedTasks,
                resolvedKeyPath: \.summarizeCompletedTasks)
            BoolOverrideRow(shared: shared,
                title: "Summarize for context compaction",
                description: "Use the summarizer to compact Smith's context at task boundaries. Off falls back to the deterministic sliding-window prune.",
                overrideKeyPath: \.summarizeForContextCompaction,
                resolvedKeyPath: \.summarizeForContextCompaction)
        }
    }
}

// MARK: - Memory & task search (grid)

struct RetrievalSettingsSection: View {
    @Bindable var shared: SharedAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Memory & Task Search").font(AppFonts.sectionHeader)
            Text("Which retrieval runs at each point. Memory injects relevant saved memories; Prior tasks injects summaries of similar past work. Each cell inherits the shipped default unless forced.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1).gridColumnAlignment(.leading)
                    Text("Memory").font(.caption.bold()).frame(width: 190)
                    Text("Prior tasks").font(.caption.bold()).frame(width: 190)
                }
                RetrievalGridRow(shared: shared, title: "New task",
                    memoryKeyPath: \.retrieval.newTask.memory, taskKeyPath: \.retrieval.newTask.task)
                RetrievalGridRow(shared: shared, title: "User message",
                    memoryKeyPath: \.retrieval.userMessage.memory, taskKeyPath: \.retrieval.userMessage.task)
                RetrievalGridRow(shared: shared, title: "Before validator review",
                    memoryKeyPath: \.retrieval.beforeValidatorReview.memory, taskKeyPath: \.retrieval.beforeValidatorReview.task)
                RetrievalGridRow(shared: shared, title: "Before security scoping",
                    memoryKeyPath: \.retrieval.beforeSecurityScoping.memory, taskKeyPath: \.retrieval.beforeSecurityScoping.task)
                RetrievalGridRow(shared: shared, title: "Before security tool review",
                    memoryKeyPath: \.retrieval.beforeSecurityToolReview.memory, taskKeyPath: \.retrieval.beforeSecurityToolReview.task)
            }
        }
    }
}

struct RetrievalGridRow: View {
    @Bindable var shared: SharedAppState
    let title: String
    let memoryKeyPath: WritableKeyPath<OrchestrationSettingsOverride, Bool?>
    let taskKeyPath: WritableKeyPath<OrchestrationSettingsOverride, Bool?>

    var body: some View {
        let override = shared.orchestrationAppOverride
        return GridRow {
            Text(title).gridColumnAlignment(.leading)
            TriStatePicker(selection: Binding(
                get: { TriStateOverride(override[keyPath: memoryKeyPath]) },
                set: { writeAppOverride(shared, memoryKeyPath, $0) }))
                .frame(width: 190)
            TriStatePicker(selection: Binding(
                get: { TriStateOverride(override[keyPath: taskKeyPath]) },
                set: { writeAppOverride(shared, taskKeyPath, $0) }))
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
    @Bindable var shared: SharedAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Validator").font(AppFonts.sectionHeader)
            BoolOverrideRow(shared: shared,
                title: "Enable task-completion validators",
                description: "Judge each task's acceptance criteria on completion. Off completes tasks without validation, marked as not validated.",
                overrideKeyPath: \.enableTaskCompletionValidators,
                resolvedKeyPath: \.enableTaskCompletionValidators)
        }
    }
}

// MARK: - Security

struct SecuritySettingsSection: View {
    @Bindable var shared: SharedAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Security Agent").font(AppFonts.sectionHeader)
            BoolOverrideRow(shared: shared,
                title: "Scope tool set on task start",
                description: "Let the Security Agent restrict a task's tools up front. Off gives the worker the full set (still recorded as the task's approved tools).",
                overrideKeyPath: \.scopeToolSetOnTaskStart,
                resolvedKeyPath: \.scopeToolSetOnTaskStart)
            Text("Review tool calls made by").font(.subheadline.bold())
            BoolOverrideRow(shared: shared,
                title: "Agent Smith",
                description: "Review Smith's tool calls (including its open-world / egress tools). Off auto-approves them, still recorded as review-disabled.",
                overrideKeyPath: \.reviewSmithToolCalls,
                resolvedKeyPath: \.reviewSmithToolCalls)
            BoolOverrideRow(shared: shared,
                title: "Agent Brown",
                description: "Review the worker's tool calls (bash, file, process). Off auto-approves them, still recorded as review-disabled.",
                overrideKeyPath: \.reviewBrownToolCalls,
                resolvedKeyPath: \.reviewBrownToolCalls)
            BoolOverrideRow(shared: shared,
                title: "Validators",
                description: "Review validator evidence reads (read-only). Off auto-approves them, still recorded as review-disabled.",
                overrideKeyPath: \.reviewValidatorToolCalls,
                resolvedKeyPath: \.reviewValidatorToolCalls)
        }
    }
}
