import Foundation

/// Global, user-set availability policy for a tool, overriding the security agent's automatic
/// scoping verdict. `default` defers to scoping; `always` offers the tool to every task unless that
/// task turns it off; `never` withholds it from every task, absolutely.
///
/// Resolution order, applied by `effectiveApprovedTools` (later steps win):
///   1. automatic verdict (Security Agent scoping, or "all candidates" when pre-flight scoping is off)
///   2. effective policy `.always` adds
///   3. per-task user override (`true` adds, `false` strips)
///   4. effective policy `.never` strips — LAST, so nothing below the forced lifecycle tools can
///      bring a `.never` tool back. A per-task "On" used to beat it, so "Never" meant "unless some
///      task says otherwise" (user decision 2026-10-05: "it needs to work like Never sounds").
///   ·  forced lifecycle tools (`task_update`, …) are always available, above all of the above.
///
/// Restrictions win in both directions: a per-task Off beats a global Always, and a global Never
/// beats a per-task On.
public enum ToolPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Defer to the automatic scoping verdict.
    case `default`
    /// Offer this tool regardless of the scoping verdict; a per-task Off still withholds it.
    case always
    /// Never offer this tool, regardless of the scoping verdict or any per-task override.
    case never

    /// Built-in safety defaults for tools that should not be enabled by automatic scoping alone.
    /// A user global policy entry for the same tool replaces the built-in default.
    public static let builtInDefaults: [String: ToolPolicy] = [
        ReportInboundUserMessageTool.toolName: .never
    ]

    /// The policy in force for `tool`: the user's global entry if there is one, else the built-in
    /// default, else `.default`. The one definition every reader (engine and UI) uses.
    public static func effective(for tool: String, globalPolicies: [String: ToolPolicy]) -> ToolPolicy {
        globalPolicies[tool] ?? builtInDefaults[tool] ?? .default
    }

    /// The tools a worker is offered: `base` (the automatic verdict) with the global policy and the
    /// task's own overrides applied in the order documented on this type. Only `candidates` are
    /// considered by the policy and overrides, so neither can add a tool the worker does not have.
    public static func effectiveApprovedTools(
        base: Set<String>,
        candidates: Set<String>,
        globalPolicies: [String: ToolPolicy],
        taskOverrides: [String: Bool]
    ) -> Set<String> {
        var result = base
        for name in candidates where effective(for: name, globalPolicies: globalPolicies) == .always {
            result.insert(name)
        }
        for (name, enabled) in taskOverrides where candidates.contains(name) {
            if enabled { result.insert(name) } else { result.remove(name) }
        }
        for name in candidates where effective(for: name, globalPolicies: globalPolicies) == .never {
            result.remove(name)
        }
        return result
    }
}
