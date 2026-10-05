import Foundation

/// Who wrote the task text a tool scoping or a tool-call review is judged against. A child task's
/// text is written by the coordinating task's WORKER (`create_child_task`), which can be mistaken or
/// prompt-injected; the user's intent for that work is the ORIGINATING task — the first non-child
/// task up the coordinator chain.
public enum TaskIntentProvenance: Sendable, Equatable {
    /// Written by the user, or by Smith from the user's request.
    case requester
    /// A child task written by a coordinating worker. `originatingTask` is nil when the chain is
    /// broken (a coordinator was permanently deleted): no statement of the user's intent exists.
    case workerAuthored(originatingTask: OriginatingTask?)

    public struct OriginatingTask: Sendable, Equatable {
        public let id: UUID
        public let title: String
        /// `renderedDescriptionWithTemplateInputs()` of the originating task.
        public let description: String
    }
}
