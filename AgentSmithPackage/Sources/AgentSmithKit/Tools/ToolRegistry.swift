import Foundation
import CryptoKit

/// Per-agent tool registry and availability gate.
///
/// Owned and mutated only inside an `AgentActor`'s isolation (held as a value-typed actor
/// field). It holds the agent's *candidate* tools — built-ins plus any dynamic MCP tools —
/// each tagged with three orthogonal availability flags, and is the single source of truth
/// for which tools are available this turn.
///
/// Availability is:
/// ```
/// isAvailable = isForcedAvailableBySystem || (isApproved && !isUnavailableDueToContext)
/// ```
/// - `isApproved` — security permission. Set *only* from the security agent's (Jones) scoping
///   verdict. For Smith/Jones and for the interim "reproduce today's behavior" wiring, tools
///   are seeded approved.
/// - `isUnavailableDueToContext` — transient orchestration context (e.g. a tool that's off
///   until the user has messaged, or while a worker is awaiting review). Set by orchestration
///   code, never by the security agent.
/// - `isForcedAvailableBySystem` — system override / security bypass. Short-circuits the
///   formula so the loop can expose a small set of trusted built-in lifecycle tools exactly
///   when it needs them (e.g. `task_acknowledged` before the first turn). This is a deliberate
///   security bypass: it may only ever be set by our own code on trusted built-in tools, never
///   derived from an MCP tool or any external input.
///
/// `AgentActor` filters `activeTools` through `availableTools()` each turn, so a tool that is
/// not available is simply absent — it is neither offered to the LLM nor found at dispatch,
/// where the existing lookup falls through to the "Unknown tool" path. A blocked tool is thus
/// indistinguishable from a nonexistent one, by design.
struct ToolRegistry: Sendable {
    struct Entry: Sendable {
        let tool: any AgentTool
        var isApproved: Bool
        var isUnavailableDueToContext: Bool
        var isForcedAvailableBySystem: Bool

        var name: String { tool.name }

        var isAvailable: Bool {
            isForcedAvailableBySystem || (isApproved && !isUnavailableDueToContext)
        }
    }

    /// Candidate entries in stable order (built-ins first, then dynamic tools in the order the
    /// provider returned them). Order is preserved so the LLM tool list stays deterministic.
    private(set) var entries: [Entry] = []

    // MARK: - Rebuild

    /// Replaces the candidate set with `candidates`, **preserving the flag state** of any tool
    /// whose name survives the rebuild. New tools are seeded with `defaultApproved` and otherwise
    /// not-forced / not-context-suppressed. Dropped tools (no longer in `candidates`) are removed.
    ///
    /// Per-turn rebuilds use this so MCP add/remove/toggle is reflected while existing approvals
    /// persist between turns (the security re-evaluation, when it runs, overwrites approvals via
    /// `applyApproval(approvedNames:)`).
    mutating func rebuild(candidates: [any AgentTool], defaultApproved: Bool) {
        var previousByName: [String: Entry] = [:]
        for entry in entries { previousByName[entry.name] = entry }

        entries = candidates.map { tool in
            if var existing = previousByName[tool.name] {
                // Preserve flags but refresh the tool reference (its description/schema may have
                // changed) so dispatch and definitions use the current candidate.
                return Entry(
                    tool: tool,
                    isApproved: existing.isApproved,
                    isUnavailableDueToContext: existing.isUnavailableDueToContext,
                    isForcedAvailableBySystem: existing.isForcedAvailableBySystem
                )
            }
            return Entry(
                tool: tool,
                isApproved: defaultApproved,
                isUnavailableDueToContext: false,
                isForcedAvailableBySystem: false
            )
        }
    }

    // MARK: - Security verdict application

    /// Applies a security scoping verdict: every candidate whose name is in `approvedNames` is
    /// marked `isApproved = true`; **all others** are set `isApproved = false`. Names in
    /// `approvedNames` that aren't real candidates are ignored (defense against a hallucinated
    /// allow). Forced and context flags are untouched.
    mutating func applyApproval(approvedNames: Set<String>) {
        for index in entries.indices {
            entries[index].isApproved = approvedNames.contains(entries[index].name)
        }
    }

    // MARK: - Flag setters

    /// Sets `isForcedAvailableBySystem` for a single built-in tool. Caller is responsible for
    /// the invariant that only trusted built-in tools are ever forced.
    mutating func setForcedAvailable(_ name: String, _ value: Bool) {
        for index in entries.indices where entries[index].name == name {
            entries[index].isForcedAvailableBySystem = value
        }
    }

    /// Sets `isUnavailableDueToContext` for a single tool.
    mutating func setContextUnavailable(_ name: String, _ value: Bool) {
        for index in entries.indices where entries[index].name == name {
            entries[index].isUnavailableDueToContext = value
        }
    }

    // MARK: - Queries

    /// All candidate tools (regardless of availability), in registration order.
    var candidateTools: [any AgentTool] { entries.map(\.tool) }

    /// Tools that are currently available (`isAvailable == true`), in registration order.
    func availableTools() -> [any AgentTool] {
        entries.filter(\.isAvailable).map(\.tool)
    }

    /// The set of currently-approved tool names (security-approved, ignoring context/forced).
    /// Persisted on the task as the record of what the security agent allowed.
    var approvedNames: [String] {
        entries.filter(\.isApproved).map(\.name)
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    // MARK: - Candidate fingerprint (per-turn change detection)

    /// A content fingerprint over the *candidate* set used to decide whether a security
    /// re-evaluation is needed. Keyed on **name + description + parameter shape** — not name
    /// alone — so a server that silently redefines a tool under the same name (a rug-pull)
    /// produces a different fingerprint and forces re-evaluation rather than riding a stale
    /// approval.
    var candidateFingerprint: String {
        var hasher = SHA256()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            hasher.update(data: Data(entry.tool.name.utf8))
            hasher.update(data: Data("\u{1F}".utf8))
            hasher.update(data: Data(entry.tool.toolDescription.utf8))
            hasher.update(data: Data("\u{1F}".utf8))
            // Identity salt (e.g. an MCP server's install UUID) so a tool whose provenance
            // changes forces a re-scope even when its name/description/schema are byte-identical
            // (a reinstalled same-named server). Built-ins contribute nothing here.
            hasher.update(data: Data((entry.tool.identityToken ?? "").utf8))
            hasher.update(data: Data("\u{1F}".utf8))
            // Deterministic full schema serialization (sorted keys) so any change to the
            // parameter shape — including nested properties — alters the fingerprint. If a
            // schema somehow fails to encode, the name+description still contribute.
            if let schema = try? encoder.encode(entry.tool.parameters) {
                hasher.update(data: schema)
            }
            hasher.update(data: Data("\u{1E}".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
