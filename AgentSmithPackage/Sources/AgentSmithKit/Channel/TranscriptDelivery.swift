import Foundation

/// What a pane RECEIVES: every message its filter shows, plus the Security Agent verdict on each tool
/// call it shows — even when its settings hide verdicts.
///
/// That verdict is part of its call's row (the status icon and the popover behind it), so withholding
/// it stripped the icon from every tool call the moment "Security reviews" was unchecked. The view
/// still asks the filter whether the verdict's TEXT shows.
///
/// Stateful, because a verdict does not say which tool it judged, so one message alone cannot answer
/// "is my call in this pane?". The request is always posted before its review begins, so a single
/// forward pass answers it: remember each delivered request until its verdict arrives. A hidden
/// verdict whose call ISN'T delivered is withheld — the default Conversation pane hides tool calls,
/// and delivering their verdicts anyway would fill its bounded render window with rows that never
/// draw.
public struct TranscriptDelivery: Sendable {
    public let filter: TranscriptFilter
    /// Delivered tool requests still waiting for their verdict. Each entry leaves when its verdict
    /// arrives, so this holds only calls under review rather than growing with the session.
    private var callsAwaitingVerdict: Set<CallKey> = []

    /// A call id is provider data that can repeat across agents, so a call is identified by the
    /// pair — the request and its verdict both carry the calling instance's `agentID`.
    private struct CallKey: Hashable {
        let agentID: String?
        let callID: String

        init?(_ message: ChannelMessage) {
            guard let callID = message.toolRequestID else { return nil }
            self.callID = callID
            if case .string(let agentID)? = message.metadata?["agentID"] {
                self.agentID = agentID
            } else {
                self.agentID = nil
            }
        }
    }

    public init(filter: TranscriptFilter) {
        self.filter = filter
    }

    /// Whether the pane receives `message`. Must see the pane's messages in transcript order.
    public mutating func admits(_ message: ChannelMessage) -> Bool {
        let verdictCall = message.kind == .securityReview ? CallKey(message) : nil
        if filter.matches(message) {
            if message.kind == .toolRequest, let call = CallKey(message) {
                callsAwaitingVerdict.insert(call)
            }
            if let verdictCall { callsAwaitingVerdict.remove(verdictCall) }
            return true
        }
        guard let verdictCall else { return false }
        return callsAwaitingVerdict.remove(verdictCall) != nil
    }

    /// The subset of `messages` the pane receives, in order.
    public mutating func admitted(from messages: some Sequence<ChannelMessage>) -> [ChannelMessage] {
        messages.filter { admits($0) }
    }
}
