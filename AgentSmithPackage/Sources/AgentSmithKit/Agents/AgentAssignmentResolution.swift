import Foundation

/// Decides what a session's agent assignments should be once its saved state has loaded.
///
/// Extracted from `AppViewModel.loadPersistedState` so the rule is testable and lives in one
/// place. The app target has no test bundle, and this rule had already destroyed real user
/// configuration once (2026-09-20) — a rule that can silently delete a preference is exactly the
/// kind that must be pinned by tests rather than re-derived inline in a view model.
///
/// ## The rule, in one line: loading never deletes.
///
/// The previous version pruned any assignment whose provider was not configured, guarded only by
/// "the provider list is not EMPTY". That guard is all-or-nothing and a PARTIALLY loaded list
/// passes it: providers that had arrived kept their roles while providers still loading had
/// theirs deleted — and the caller persists, so the deletion was immediate and permanent. The old
/// comment stated the assumption outright ("A genuinely removed single provider still prunes
/// normally below, since the list is then non-empty"), i.e. non-empty implies complete. It is not.
public enum AgentAssignmentResolution {

    /// What a load should apply, and what it should say about it.
    public struct Resolution: Equatable, Sendable {
        /// The assignments to apply. A superset of `saved` — never a subset.
        public var assignments: [AgentRole: ModelAssignment]
        /// Saved assignments whose provider is not currently configured. **Kept** in
        /// `assignments`, reported so the caller can log them and the UI can mark the role
        /// unusable. Empty when the provider list is empty — see `resolve`.
        public var unavailable: [AgentRole: ModelAssignment]
        /// Roles that had NO assignment and were filled from the defaults.
        public var healed: [AgentRole: ModelAssignment]
    }

    /// Resolves the assignments for a session.
    ///
    /// - Parameters:
    ///   - saved: what came off disk. Every entry survives into the result, untouched.
    ///   - configuredProviderIDs: providers currently known to the kit. **May be incomplete** —
    ///     that is the whole reason this function does not delete anything.
    ///   - defaults: the bundled per-role defaults used to fill EMPTY roles only.
    ///
    /// Two deliberate asymmetries:
    ///
    /// - **Healing fills; it never replaces.** Filling an empty slot cannot destroy a choice, so
    ///   it needs no equivalent of the guard the prune lacked. It covers every role in
    ///   `AgentRole.allCases`, not just `requiredRoles`: "blocks app launch" and "has a sensible
    ///   default" are different questions, and conflating them is why `.validator` — deliberately
    ///   outside `requiredRoles` so a missing one blocks VALIDATION rather than the app — was the
    ///   one role that never got healed, leaving submitted tasks parked unresolvably.
    ///
    /// - **An EMPTY provider list reports nothing unavailable.** With zero providers every
    ///   assignment would technically qualify, but that state almost always means the catalog has
    ///   not loaded rather than that the user deleted every provider — so flagging all of them
    ///   would be the same false signal in a louder voice. Nothing is healed then either, since
    ///   there is nothing to heal to.
    public static func resolve(
        saved: [AgentRole: ModelAssignment],
        configuredProviderIDs: Set<String>,
        defaults: [AgentRole: ModelAssignment]
    ) -> Resolution {
        var assignments = saved
        var unavailable: [AgentRole: ModelAssignment] = [:]
        var healed: [AgentRole: ModelAssignment] = [:]

        guard !configuredProviderIDs.isEmpty else {
            return Resolution(assignments: assignments, unavailable: [:], healed: [:])
        }

        for (role, assignment) in saved
        where assignment.modelID.isEmpty || !configuredProviderIDs.contains(assignment.providerID) {
            unavailable[role] = assignment
        }

        for role in AgentRole.allCases where assignments[role] == nil {
            guard let fallback = defaults[role],
                  !fallback.modelID.isEmpty,
                  configuredProviderIDs.contains(fallback.providerID) else { continue }
            assignments[role] = fallback
            healed[role] = fallback
        }

        return Resolution(assignments: assignments, unavailable: unavailable, healed: healed)
    }
}
