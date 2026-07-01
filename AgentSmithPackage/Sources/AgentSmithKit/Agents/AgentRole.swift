import Foundation
import Synchronization

/// The role an agent plays in the system.
public enum AgentRole: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case smith
    case brown
    case securityAgent
    case summarizer

    /// Thread-safe storage for the user's preferred nickname.
    private static let _userNickname = Mutex("")

    /// The user's preferred nickname, used in system prompts and display labels.
    public static var userNickname: String {
        get { _userNickname.withLock { $0 } }
        set { _userNickname.withLock { $0 = newValue } }
    }

    /// Roles that must be configured for the system to start.
    public static let requiredRoles: [AgentRole] = [.smith, .brown, .securityAgent, .summarizer]

    /// Human-readable name for display.
    public var displayName: String {
        switch self {
        case .smith: return "Smith"
        case .brown: return "Brown"
        case .securityAgent: return "Security Agent"
        case .summarizer: return "Summarizer"
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
