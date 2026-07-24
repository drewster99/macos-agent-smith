import Foundation
import Synchronization

/// The role an agent plays in the system.
public enum AgentRole: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case smith
    case brown
    case securityAgent
    case summarizer
    /// The acceptance-validation judge. Unlike the four above it is not a long-lived
    /// `AgentActor` — a validator exists only for the duration of one criterion's evaluation
    /// — but it is an ordinary configurable slot in every other respect: its own model
    /// assignment, its own usage attribution, its own channel provenance, and its own
    /// `ToolContext` for the read-only evidence tools. There is NO fallback to another
    /// role's model; an unassigned validator blocks validation rather than quietly running
    /// on someone else's model.
    case validator

    /// Forward-compatibility fallback: a role rawValue this build doesn't know (written by
    /// a NEWER build) must degrade to a harmless attribution rather than failing the decode
    /// of an entire persisted array (usage_records.json holds tens of thousands of records;
    /// one unknown role must not brick them all on downgrade). `.summarizer` is the
    /// least-harmful bucket: it is never interactive and never drives orchestration
    /// decisions. Note this covers role-as-VALUE only; see the dictionary-KEY note below.
    public static let decodingFallback: AgentRole = .summarizer

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentRole(rawValue: raw) ?? Self.decodingFallback
    }

    // NOTE: dictionary-KEY decoding (`[AgentRole: V]`) bypasses `init(from:)` via
    // CodingKeyRepresentable and deliberately gets NO fallback: remapping an unknown key
    // would land it on an existing case and OVERWRITE that case's value. So a role-keyed
    // blob written by a build that knows a role is not decodable by one that doesn't.
    // That's accepted — this app has no shipped older builds to stay compatible with — but
    // it does mean adding a case is a one-way door for on-disk `[AgentRole: V]` state.
    // `SessionState.init(from:)` carries the one migration this has needed so far.

    /// Thread-safe storage for the user's preferred nickname.
    private static let _userNickname = Mutex("")

    /// The user's preferred nickname, used in system prompts and display labels.
    public static var userNickname: String {
        get { _userNickname.withLock { $0 } }
        set { _userNickname.withLock { $0 = newValue } }
    }

    /// Roles that must be configured for the system to START. `.validator` is deliberately
    /// absent — not because it's optional, but because its absence should block the thing it
    /// is responsible for rather than the whole app. An unassigned validator parks each
    /// submitted task in `.awaitingReview` with `AgentTask.validationBlockedReason` set, where
    /// not even Smith can resolve it; assigning a validator model unblocks them. Failing that
    /// way keeps a misconfiguration from silently approving work.
    public static let requiredRoles: [AgentRole] = [.smith, .brown, .securityAgent, .summarizer]

    /// Human-readable name for display.
    public var displayName: String {
        switch self {
        case .smith: return "Smith"
        case .brown: return "Brown"
        case .securityAgent: return "Security Agent"
        case .summarizer: return "Summarizer"
        case .validator: return "Validator"
        }
    }

    private var baseSystemPromptSuffix: String {
        var results: [String] = []
        results.append("This device is running MacOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let nickname = Self.userNickname
        if !nickname.isEmpty {
            results.append("The user prefers to be called: \(nickname)")
        }
        results.append("The current user's username is: \(NSUserName())")
        results.append("The user's home directory is: \(FileManager.default.homeDirectoryForCurrentUser.path)")
        results.append("The current working directory is: \(URL.currentDirectory().path)")
        results.append(Self.currentLocaleAndTimeBlock())
        return results.joined(separator: "\n")
    }

    /// Builds a static block describing the user's locale and timezone. Cache-stable across
    /// the session: contains NO current-time component, since rendering "now" into the system
    /// prompt would invalidate the prompt cache on every send. Injected into every agent's
    /// system prompt so the LLM resolves user-supplied times ("4:45pm", "tomorrow morning") in
    /// the user's actual timezone instead of defaulting to whatever the model was trained
    /// with (Gemini → PDT, etc.). Concrete "now" reference comes from per-message timestamps
    /// elsewhere in the conversation, not this block.
    static func currentLocaleAndTimeBlock() -> String {
        let tz = TimeZone.current
        let locale = Locale.current
        let now = Date()

        let offsetSeconds = tz.secondsFromGMT(for: now)
        let offsetSign = offsetSeconds >= 0 ? "+" : "-"
        let absOffset = abs(offsetSeconds)
        let offsetHours = absOffset / 3600
        let offsetMinutes = (absOffset % 3600) / 60
        let offsetString = String(format: "%@%02d:%02d", offsetSign, offsetHours, offsetMinutes)
        let abbreviation = tz.abbreviation(for: now) ?? offsetString

        var lines: [String] = []
        lines.append("The user's locale is: \(locale.identifier)")
        lines.append("The user's timezone is: \(tz.identifier) (\(abbreviation), UTC\(offsetString))")
        lines.append("When the user mentions a time without specifying a timezone (e.g. \"4:45pm\", \"tomorrow morning\"), interpret it in the user's local timezone above. Pass absolute timestamps to scheduling tools as ISO-8601 with the user's UTC offset (e.g. \"2026-04-26T16:45:00\(offsetString)\").")
        return lines.joined(separator: "\n")
    }
    /// Default system prompt for this role, used as the base before behavior-specific additions.
    public var baseSystemPrompt: String {
        return baseSystemPromptSuffix
    }
}
