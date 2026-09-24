import Foundation

/// Why a provider call was made, for callers whose calls are not self-explanatory turns of a
/// resident agent's conversation (Security reviews, Summarizer operations).
///
/// Domain data only — display labels live in the app target, so the engine never depends on
/// UI wording.
public struct LLMCallAnnotation: Sendable, Equatable {
    /// The typed operation that issued the call.
    public enum Operation: Sendable, Equatable {
        /// A Security Agent verdict on one tool call.
        case securityToolReview(toolName: String)
        /// The task-start pass that scopes a worker's tool set.
        case securityToolScoping
        /// Summarizing a completed or failed task.
        case taskSummary
        /// Judging whether a new memory duplicates an existing one.
        case memoryReconciliation
        /// Extracting an answer from a fetched web page for a prompted `web_fetch`.
        case webContentExtraction
    }

    public let operation: Operation
    /// The task the call served, when one applies.
    public let taskID: UUID?
    /// The task's title at call time, captured so a later rename or deletion cannot rewrite it.
    public let taskTitle: String?
    /// Links calls that belong to one logical operation across surfaces (e.g. a memory
    /// consolidation's candidate search, reconciliation call, and resulting mutation).
    public let correlationID: UUID?
    /// 1-based attempt number within the operation's retry loop, when the caller retries.
    public let attempt: Int?

    public init(
        operation: Operation,
        taskID: UUID? = nil,
        taskTitle: String? = nil,
        correlationID: UUID? = nil,
        attempt: Int? = nil
    ) {
        self.operation = operation
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.correlationID = correlationID
        self.attempt = attempt
    }

    /// The same annotation for another attempt of the same operation.
    public func forAttempt(_ attempt: Int) -> LLMCallAnnotation {
        LLMCallAnnotation(
            operation: operation,
            taskID: taskID,
            taskTitle: taskTitle,
            correlationID: correlationID,
            attempt: attempt
        )
    }
}
