import Foundation

// MARK: - Retrieval toggle (one memory/prior-task switch pair)

/// The memory + prior-task retrieval switch pair for a single retrieval point. The two corpora are
/// gated independently because they carry different cost and different value: a prior-task search
/// needs its own query embedding *and* a second corpus scan, so it is affordable to leave off at a
/// point where a memory-only lookup is still worthwhile.
public struct RetrievalToggle: Codable, Sendable, Equatable {
    /// Whether to inject relevant semantic memories at this point.
    public var memory: Bool
    /// Whether to inject relevant prior-task summaries at this point.
    public var task: Bool

    public init(memory: Bool, task: Bool) {
        self.memory = memory
        self.task = task
    }
}

/// The sparse override of a ``RetrievalToggle``. `nil` on either axis means "inherit whatever the
/// lower layer resolved for that axis."
public struct RetrievalToggleOverride: Codable, Sendable, Equatable {
    public var memory: Bool?
    public var task: Bool?

    public init(memory: Bool? = nil, task: Bool? = nil) {
        self.memory = memory
        self.task = task
    }

    /// Whether nothing is overridden — both axes inherit. An empty override should not be persisted.
    public var isEmpty: Bool { memory == nil && task == nil }
}

extension RetrievalToggle {
    /// The effective toggle = this resolved pair with `override`'s set axes overlaid.
    public func applying(_ override: RetrievalToggleOverride) -> RetrievalToggle {
        RetrievalToggle(memory: override.memory ?? memory, task: override.task ?? task)
    }
}

// MARK: - Retrieval settings (all five points)

/// Memory / prior-task retrieval, per point in the orchestration where a lookup can run. Each point
/// is its own ``RetrievalToggle``; the injection SITE and cost differ per point (see the individual
/// doc comments) but the switch shape is uniform so the UI can render them as one grid.
public struct RetrievalSettings: Codable, Sendable, Equatable {
    /// When a new task is created or started (memory + prior-task briefing context).
    public var newTask: RetrievalToggle
    /// On every user message to Smith.
    public var userMessage: RetrievalToggle
    /// Before a validator judges a criterion. Injecting memories here makes a verdict depend on the
    /// live memory corpus, which the validator audit hash does NOT cover — hence the conservative
    /// default (see ``OrchestrationSettings/builtIn``).
    public var beforeValidatorReview: RetrievalToggle
    /// Before the Security Agent scopes the tool set on task start.
    public var beforeSecurityScoping: RetrievalToggle
    /// Before the Security Agent reviews an individual tool call. This point runs on EVERY tool call
    /// in the system, so its cost is the highest of the five — a query embedding + corpus scan per call.
    public var beforeSecurityToolReview: RetrievalToggle

    public init(
        newTask: RetrievalToggle,
        userMessage: RetrievalToggle,
        beforeValidatorReview: RetrievalToggle,
        beforeSecurityScoping: RetrievalToggle,
        beforeSecurityToolReview: RetrievalToggle
    ) {
        self.newTask = newTask
        self.userMessage = userMessage
        self.beforeValidatorReview = beforeValidatorReview
        self.beforeSecurityScoping = beforeSecurityScoping
        self.beforeSecurityToolReview = beforeSecurityToolReview
    }
}

/// The sparse override of ``RetrievalSettings``. A `nil` point (or a point whose override is empty)
/// inherits the lower layer entirely.
public struct RetrievalSettingsOverride: Codable, Sendable, Equatable {
    public var newTask: RetrievalToggleOverride
    public var userMessage: RetrievalToggleOverride
    public var beforeValidatorReview: RetrievalToggleOverride
    public var beforeSecurityScoping: RetrievalToggleOverride
    public var beforeSecurityToolReview: RetrievalToggleOverride

    public init(
        newTask: RetrievalToggleOverride = .init(),
        userMessage: RetrievalToggleOverride = .init(),
        beforeValidatorReview: RetrievalToggleOverride = .init(),
        beforeSecurityScoping: RetrievalToggleOverride = .init(),
        beforeSecurityToolReview: RetrievalToggleOverride = .init()
    ) {
        self.newTask = newTask
        self.userMessage = userMessage
        self.beforeValidatorReview = beforeValidatorReview
        self.beforeSecurityScoping = beforeSecurityScoping
        self.beforeSecurityToolReview = beforeSecurityToolReview
    }

    public var isEmpty: Bool {
        newTask.isEmpty && userMessage.isEmpty && beforeValidatorReview.isEmpty
            && beforeSecurityScoping.isEmpty && beforeSecurityToolReview.isEmpty
    }
}

extension RetrievalSettings {
    public func applying(_ override: RetrievalSettingsOverride) -> RetrievalSettings {
        RetrievalSettings(
            newTask: newTask.applying(override.newTask),
            userMessage: userMessage.applying(override.userMessage),
            beforeValidatorReview: beforeValidatorReview.applying(override.beforeValidatorReview),
            beforeSecurityScoping: beforeSecurityScoping.applying(override.beforeSecurityScoping),
            beforeSecurityToolReview: beforeSecurityToolReview.applying(override.beforeSecurityToolReview)
        )
    }

    /// The toggle governing retrieval at `source`.
    public func toggle(for source: RetrievalSource) -> RetrievalToggle {
        switch source {
        case .newTask: return newTask
        case .smithUserMessage: return userMessage
        case .validatorReview: return beforeValidatorReview
        case .securityScoping: return beforeSecurityScoping
        case .securityToolReview: return beforeSecurityToolReview
        }
    }
}

/// The point in orchestration at which a retrieval runs. The `rawValue` is the provenance string
/// recorded on the memory query (kept identical to the pre-unification `source:` strings so query
/// logs stay continuous), and it selects the per-point ``RetrievalToggle``. One call shape at every
/// point — only the source (and thus the resolved limits) differs.
public enum RetrievalSource: String, Sendable, CaseIterable {
    case newTask = "task-context"
    case smithUserMessage = "auto-context"
    case validatorReview = "validator-review"
    case securityScoping = "security-scoping"
    case securityToolReview = "security-tool-review"
}

// MARK: - Orchestration settings (the resolved value)

/// The complete, resolved set of orchestration behavior switches — the sibling of a resolved
/// ``ModelConfiguration``. This is BOTH the shape of the shipped/downloaded defaults and the shape
/// the engine reads at each chokepoint. It is never persisted as a user override directly; the user
/// layers (app-wide, per-session) are sparse ``OrchestrationSettingsOverride`` deltas resolved onto
/// a baseline via ``applying(_:)``.
///
/// Every switch defaults ON in ``builtIn`` (retrieval points carry their per-point historical
/// defaults). "OFF" never removes a call from the system — the subsystem is still invoked and reads
/// its resolved switch, then takes its disabled branch and reports that it did so. See the per-field
/// doc comments and the OFF-behavior chokepoints for what each disabled branch does.
public struct OrchestrationSettings: Codable, Sendable, Equatable {

    // Summarizer

    /// Summarize completed/failed tasks (feeds prior-task semantic search). OFF → the summarizer
    /// returns nothing and no summary entry is written.
    public var summarizeCompletedTasks: Bool
    /// Use the summarizer to compact Smith's context at task boundaries. OFF → the LLM compaction is
    /// skipped; the deterministic run-loop prune remains the reduction mechanism.
    public var summarizeForContextCompaction: Bool

    // Memory & task search

    public var retrieval: RetrievalSettings

    // Validator

    /// Run acceptance-validation on task completion. OFF → the task completes WITHOUT its criteria
    /// being judged, flagged as completed-without-validation.
    public var enableTaskCompletionValidators: Bool

    // Security Agent

    /// Scope the worker's tool set on task start. OFF → the worker gets the full candidate tool set
    /// (the full set is still persisted as the task's approved tools).
    public var scopeToolSetOnTaskStart: Bool
    /// Review Smith's tool calls. OFF → Smith's calls auto-approve, still recorded/posted as
    /// review-disabled rather than as a genuine verdict.
    public var reviewSmithToolCalls: Bool
    /// Review Brown's tool calls. OFF → as above, for the worker's calls.
    public var reviewBrownToolCalls: Bool
    /// Review validator evidence-tool calls. OFF → as above, for the read-only evidence reads.
    public var reviewValidatorToolCalls: Bool

    public init(
        summarizeCompletedTasks: Bool,
        summarizeForContextCompaction: Bool,
        retrieval: RetrievalSettings,
        enableTaskCompletionValidators: Bool,
        scopeToolSetOnTaskStart: Bool,
        reviewSmithToolCalls: Bool,
        reviewBrownToolCalls: Bool,
        reviewValidatorToolCalls: Bool
    ) {
        self.summarizeCompletedTasks = summarizeCompletedTasks
        self.summarizeForContextCompaction = summarizeForContextCompaction
        self.retrieval = retrieval
        self.enableTaskCompletionValidators = enableTaskCompletionValidators
        self.scopeToolSetOnTaskStart = scopeToolSetOnTaskStart
        self.reviewSmithToolCalls = reviewSmithToolCalls
        self.reviewBrownToolCalls = reviewBrownToolCalls
        self.reviewValidatorToolCalls = reviewValidatorToolCalls
    }

    /// Whether the Security Agent reviews tool calls from `role`. Fail-closed: any role not carrying
    /// its own switch (the Security Agent's own inline evidence tools, the Summarizer, which makes no
    /// tool calls) reviews by default, so a new emitter is reviewed until someone deliberately clears it.
    public func reviewsToolCalls(by role: AgentRole) -> Bool {
        switch role {
        case .smith: return reviewSmithToolCalls
        case .brown: return reviewBrownToolCalls
        case .validator: return reviewValidatorToolCalls
        case .securityAgent, .summarizer: return true
        }
    }

    /// The compile-time shipped defaults. Everything ON except the retrieval points, which carry
    /// their per-point historical defaults: new-task memory+task ON; user-message memory ON / task
    /// OFF; validator-review both OFF (memory OFF preserves validator determinism — its audit hash
    /// does not cover injected memories); security-scoping both OFF; security-tool-review memory ON /
    /// task OFF. This is the ultimate fallback when no shipped/downloaded defaults file loads.
    public static let builtIn = OrchestrationSettings(
        summarizeCompletedTasks: true,
        summarizeForContextCompaction: true,
        retrieval: RetrievalSettings(
            newTask: RetrievalToggle(memory: true, task: true),
            userMessage: RetrievalToggle(memory: true, task: false),
            beforeValidatorReview: RetrievalToggle(memory: false, task: false),
            beforeSecurityScoping: RetrievalToggle(memory: false, task: false),
            beforeSecurityToolReview: RetrievalToggle(memory: true, task: false)
        ),
        enableTaskCompletionValidators: true,
        scopeToolSetOnTaskStart: true,
        reviewSmithToolCalls: true,
        reviewBrownToolCalls: true,
        reviewValidatorToolCalls: true
    )
}

// MARK: - Orchestration settings override (a sparse user delta)

/// A sparse per-layer override of ``OrchestrationSettings`` — the app-wide user layer and the
/// per-session layer are both this type. Every field is optional: `nil` means "inherit the resolved
/// value from the layer below." Empty overrides are not persisted (indistinguishable from absent).
public struct OrchestrationSettingsOverride: Codable, Sendable, Equatable {
    public var summarizeCompletedTasks: Bool?
    public var summarizeForContextCompaction: Bool?
    public var retrieval: RetrievalSettingsOverride
    public var enableTaskCompletionValidators: Bool?
    public var scopeToolSetOnTaskStart: Bool?
    public var reviewSmithToolCalls: Bool?
    public var reviewBrownToolCalls: Bool?
    public var reviewValidatorToolCalls: Bool?

    public init(
        summarizeCompletedTasks: Bool? = nil,
        summarizeForContextCompaction: Bool? = nil,
        retrieval: RetrievalSettingsOverride = .init(),
        enableTaskCompletionValidators: Bool? = nil,
        scopeToolSetOnTaskStart: Bool? = nil,
        reviewSmithToolCalls: Bool? = nil,
        reviewBrownToolCalls: Bool? = nil,
        reviewValidatorToolCalls: Bool? = nil
    ) {
        self.summarizeCompletedTasks = summarizeCompletedTasks
        self.summarizeForContextCompaction = summarizeForContextCompaction
        self.retrieval = retrieval
        self.enableTaskCompletionValidators = enableTaskCompletionValidators
        self.scopeToolSetOnTaskStart = scopeToolSetOnTaskStart
        self.reviewSmithToolCalls = reviewSmithToolCalls
        self.reviewBrownToolCalls = reviewBrownToolCalls
        self.reviewValidatorToolCalls = reviewValidatorToolCalls
    }

    /// Whether nothing is overridden — every field inherits. An empty override should not be persisted.
    public var isEmpty: Bool {
        summarizeCompletedTasks == nil && summarizeForContextCompaction == nil
            && retrieval.isEmpty && enableTaskCompletionValidators == nil
            && scopeToolSetOnTaskStart == nil && reviewSmithToolCalls == nil
            && reviewBrownToolCalls == nil && reviewValidatorToolCalls == nil
    }
}

extension OrchestrationSettings {
    /// The effective settings = this resolved baseline with `override`'s set fields overlaid. Pure and
    /// cheap — the four-layer chain is `shipped`→`downloaded`→`appWide`→`session`, each step a call to
    /// this on the layer below's result.
    public func applying(_ override: OrchestrationSettingsOverride) -> OrchestrationSettings {
        OrchestrationSettings(
            summarizeCompletedTasks: override.summarizeCompletedTasks ?? summarizeCompletedTasks,
            summarizeForContextCompaction: override.summarizeForContextCompaction ?? summarizeForContextCompaction,
            retrieval: retrieval.applying(override.retrieval),
            enableTaskCompletionValidators: override.enableTaskCompletionValidators ?? enableTaskCompletionValidators,
            scopeToolSetOnTaskStart: override.scopeToolSetOnTaskStart ?? scopeToolSetOnTaskStart,
            reviewSmithToolCalls: override.reviewSmithToolCalls ?? reviewSmithToolCalls,
            reviewBrownToolCalls: override.reviewBrownToolCalls ?? reviewBrownToolCalls,
            reviewValidatorToolCalls: override.reviewValidatorToolCalls ?? reviewValidatorToolCalls
        )
    }
}
