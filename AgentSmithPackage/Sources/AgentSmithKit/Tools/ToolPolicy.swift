import Foundation

/// Global, user-set availability policy for a tool, overriding the security agent's automatic
/// scoping verdict. `default` defers to scoping; `always`/`never` force the tool on/off for every
/// task. A per-task user override (`AgentTask.userToolOverrides`) takes precedence over this.
///
/// Resolution order (low → high precedence), applied in `AgentActor`:
///   1. automatic verdict (Jones scoping, or "all candidates" when pre-flight scoping is off)
///   2. global `ToolPolicy` (`.never` strips, `.always` adds)
///   3. per-task user override (`true` adds, `false` strips)
///   ·  forced lifecycle tools (`task_update`, …) are always available, above all of the above.
public enum ToolPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Defer to the automatic scoping verdict.
    case `default`
    /// Always offer this tool, regardless of the scoping verdict.
    case always
    /// Never offer this tool, regardless of the scoping verdict.
    case never
}
