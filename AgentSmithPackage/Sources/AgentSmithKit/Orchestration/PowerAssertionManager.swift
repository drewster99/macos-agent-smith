import Foundation
@preconcurrency import IOKit.pwr_mgt

/// Manages a macOS power assertion to prevent system sleep while agents are working.
///
/// The assertion is acquired when activity occurs and released only when both:
/// 1. No active tasks exist in the task store
/// 2. No LLM calls or user messages have occurred for 15 minutes
actor PowerAssertionManager {
    private let taskStore: TaskStore
    private var assertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var isHoldingAssertion = false
    private var inactivityTimerTask: Task<Void, Never>?

    private static let inactivityTimeout: TimeInterval = 15 * 60  // 15 minutes
    private nonisolated(unsafe) static let assertionName = "Agent Smith — agents active" as CFString

    public init(taskStore: TaskStore) {
        self.taskStore = taskStore
    }

    /// Call after init to acquire the initial assertion and start the timer.
    /// Separate from init because actor-isolated methods cannot be called from init.
    public func start() {
        acquireAssertion()
        resetInactivityTimer()
    }

    /// Call when any meaningful activity occurs (LLM call, user message, etc.).
    public func activityOccurred() {
        if !isHoldingAssertion {
            acquireAssertion()
        }
        resetInactivityTimer()
    }

    /// Unconditionally releases the assertion (e.g. on stopAll).
    public func releaseImmediately() {
        inactivityTimerTask?.cancel()
        inactivityTimerTask = nil
        releaseAssertion()
    }

    /// Releases the assertion and tears down all state.
    public func shutdown() {
        releaseImmediately()
    }

    // MARK: - Private

    private func acquireAssertion() {
        guard !isHoldingAssertion else { return }
        var newID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName,
            &newID
        )
        if result == kIOReturnSuccess {
            assertionID = newID
            isHoldingAssertion = true
        }
    }

    private func releaseAssertion() {
        guard isHoldingAssertion else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        isHoldingAssertion = false
    }

    private func resetInactivityTimer() {
        inactivityTimerTask?.cancel()
        inactivityTimerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.inactivityTimeout))
            } catch {
                return  // cancelled
            }
            await self?.handleInactivityTimeout()
        }
    }

    private func handleInactivityTimeout() async {
        let activeStatuses: Set<AgentTask.Status> = [.pending, .running, .paused, .awaitingReview, .interrupted]
        let tasks = await taskStore.allTasks()
        let hasActive = tasks.contains { $0.disposition == .active && activeStatuses.contains($0.status) }

        if hasActive {
            // Tasks still running — restart timer and keep assertion
            resetInactivityTimer()
        } else {
            releaseAssertion()
        }
    }
}
