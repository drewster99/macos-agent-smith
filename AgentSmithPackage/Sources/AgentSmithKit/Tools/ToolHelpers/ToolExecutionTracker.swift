import Foundation

/// Tracks the execution status of tool calls for security agent inspection.
///
/// Thread-safe storage for recording whether tool calls succeeded or failed
/// after being approved by the security agent. Bounded by a small ring-buffer
/// cap so Smith's tracker (which nobody currently reads) can't grow unbounded
/// across a long session, and so Brown's `maxRecentToolRequests = 10`
/// consultation window always finds the entries it needs.
actor ToolExecutionTracker: Sendable {
    /// Maximum number of `(toolCallID, succeeded)` entries kept. Once exceeded, the
    /// oldest entry is evicted on each new write. 20 comfortably exceeds the security
    /// evaluator's lookback (`SecurityEvaluator.maxRecentToolRequests = 10`) so a
    /// hot-cache miss can't happen on an in-flight evaluation.
    private static let maxEntries = 20

    /// Insertion-ordered list of recorded statuses. Used as a FIFO ring; the
    /// dictionary is regenerated on each lookup from this list so cap enforcement
    /// has a single source of truth.
    private var recentEntries: [(toolCallID: String, succeeded: Bool)] = []

    public init() {}

    /// Records the execution status of a tool call.
    /// - Parameters:
    ///   - toolCallID: The ID of the tool call
    ///   - succeeded: Whether the tool execution succeeded
    public func recordExecutionStatus(toolCallID: String, succeeded: Bool) {
        // If this id was already recorded, drop the prior entry so the new status wins
        // and the ring stays a true sliding window of distinct calls.
        recentEntries.removeAll { $0.toolCallID == toolCallID }
        recentEntries.append((toolCallID, succeeded))
        if recentEntries.count > Self.maxEntries {
            recentEntries.removeFirst(recentEntries.count - Self.maxEntries)
        }
    }

    /// Gets the execution status of a tool call.
    /// - Parameter toolCallID: The ID of the tool call
    /// - Returns: true if succeeded, false if failed, nil if not recorded
    public func getExecutionStatus(toolCallID: String) -> Bool? {
        recentEntries.last(where: { $0.toolCallID == toolCallID })?.succeeded
    }

    /// Checks if a tool call has already succeeded.
    /// - Parameter toolCallID: The ID of the tool call
    /// - Returns: true if the tool call has already succeeded
    public func hasSucceeded(toolCallID: String) -> Bool {
        getExecutionStatus(toolCallID: toolCallID) == true
    }

    /// Checks if a tool call has already failed after being approved.
    /// - Parameter toolCallID: The ID of the tool call
    /// - Returns: true if the tool call has already failed
    public func hasFailed(toolCallID: String) -> Bool {
        getExecutionStatus(toolCallID: toolCallID) == false
    }
}
