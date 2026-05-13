import Foundation

/// Returns the current date/time formatted in the user's locale and timezone. Available to
/// both Smith and Brown — neither agent has a fresh "now" reference baked into the system
/// prompt (the prompt only carries static locale/timezone info to keep the prompt cache
/// stable). Call this whenever you need to resolve the user's local "now" for relative-time
/// math like "in 30 minutes" or "before tonight".
struct CurrentTimeTool: AgentTool {
    let name = "get_current_time"
    let toolDescription = """
        Get the current date and time in the user's local timezone. Returns ISO-8601 with the \
        user's UTC offset, the timezone identifier and abbreviation, the user's locale, and a \
        human-readable form. \
        \
        Use this when you need a fresh "now" reference (resolving "in 30 minutes", deciding \
        whether a user-named time is later today or tomorrow, computing elapsed time since \
        something happened, stamping a result with the time it was produced). \
        \
        No arguments.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([:])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith || context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
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

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        isoFormatter.timeZone = tz
        let localISO = isoFormatter.string(from: now)

        let utcFormatter = ISO8601DateFormatter()
        utcFormatter.formatOptions = [.withInternetDateTime]
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let utcISO = utcFormatter.string(from: now)

        let humanFormatter = DateFormatter()
        humanFormatter.locale = locale
        humanFormatter.timeZone = tz
        humanFormatter.dateStyle = .full
        humanFormatter.timeStyle = .long
        let humanReadable = humanFormatter.string(from: now)

        let unixEpoch = Int(now.timeIntervalSince1970)

        let lines = [
            "local: \(localISO)",
            "utc: \(utcISO)",
            "timezone: \(tz.identifier) (\(abbreviation), UTC\(offsetString))",
            "locale: \(locale.identifier)",
            "human: \(humanReadable)",
            "unix_epoch_seconds: \(unixEpoch)"
        ]
        return .success(lines.joined(separator: "\n"))
    }
}
