import Foundation
import os
import SwiftLLMKit

/// One element of a task's structured result.
///
/// A structured result is an ORDERED list of these — inline text, a single attachment, or a
/// named group of attachments — each optionally tagged with routing `refs` (criterion IDs) so a
/// validator knows which items are the evidence for its criterion. `refs` are tags, NOT a filter:
/// a validator receives the whole result and uses them to decide what to focus on / pull.
///
/// ADDITIVE: this lives ALONGSIDE the legacy `AgentTask.result: String?` and `resultAttachments`,
/// which remain canonical. Existing tasks decode with an empty `resultItems` and readers fall
/// back to the flat fields; new tasks populate both. Nothing about the old fields changes, so
/// there is no migration of on-disk task data.
public struct ResultItem: Codable, Sendable, Equatable {
    /// The payload of a single result item.
    public enum Content: Sendable, Equatable {
        /// Inline text (an answer, a note, a section of the write-up).
        case text(String)
        /// A single produced/referenced file.
        case attachment(Attachment)
        /// A named bundle of files (e.g. "the de/ screenshots"), with an optional description.
        case attachmentGroup(attachments: [Attachment], description: String?)
        /// A kind this build doesn't recognize (written by a NEWER build). The original JSON node is
        /// preserved verbatim in `raw` so a downgrade→resave round-trips it losslessly instead of
        /// rewriting it as a lossy placeholder; the UI renders it as `[unsupported result item: …]`.
        case unknown(kind: String, raw: AnyCodable)
    }

    public var content: Content
    /// Routing tags — criterion IDs (as UUID strings). Optional; empty means untagged (available
    /// as global context to every criterion). Many-to-many: an item may carry several refs, and
    /// several items may share one. A ref matching no criterion is a harmless unused label.
    public var refs: [String]

    public init(content: Content, refs: [String] = []) {
        self.content = content
        self.refs = refs
    }
}

extension ResultItem.Content: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, attachment, attachments, description
    }
    private enum Kind: String, Codable {
        case text, attachment, attachmentGroup
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Forward-compatible: a `kind` this build doesn't recognize (written by a NEWER build)
        // must NOT throw — an array decode is all-or-nothing, so a single unknown item would take
        // down the whole task list (and the app would quarantine the file). Degrade to a text
        // placeholder instead, matching the codebase's `AgentRole` / `Status` decoding fallbacks.
        let kindRaw = try c.decode(String.self, forKey: .kind)
        switch Kind(rawValue: kindRaw) {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .attachment:
            self = .attachment(try c.decode(Attachment.self, forKey: .attachment))
        case .attachmentGroup:
            self = .attachmentGroup(
                attachments: try c.decode([Attachment].self, forKey: .attachments),
                description: try c.decodeIfPresent(String.self, forKey: .description)
            )
        case nil:
            // An unrecognized kind can only come from a NEWER build (or a removed case) — never
            // legitimate input. We must NOT throw (that would fail the whole task file and it'd be
            // quarantined = data loss). Instead preserve the ORIGINAL JSON node verbatim so a
            // downgrade→resave round-trips it losslessly; the UI renders a placeholder. NOT an
            // assertionFailure — this runs during boot-time task decode, where a trap would crash
            // the app on launch for anyone whose on-disk data hit it.
            Logger(subsystem: "AgentSmithKit", category: "ResultItem")
                .error("Unknown ResultItem.Content kind '\(kindRaw, privacy: .public)' during decode — task data written by a newer build; preserving it verbatim behind a placeholder.")
            self = .unknown(kind: kindRaw, raw: try AnyCodable(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(text, forKey: .text)
        case .attachment(let attachment):
            try c.encode(Kind.attachment, forKey: .kind)
            try c.encode(attachment, forKey: .attachment)
        case .attachmentGroup(let attachments, let description):
            try c.encode(Kind.attachmentGroup, forKey: .kind)
            try c.encode(attachments, forKey: .attachments)
            try c.encodeIfPresent(description, forKey: .description)
        case .unknown(_, let raw):
            // Write the preserved node verbatim (it already carries its own `kind` + payload).
            try raw.encode(to: encoder)
        }
    }
}

public extension ResultItem {
    /// Every attachment carried by this item (empty for a text item). Convenience for readers
    /// that need to resolve/inject bytes regardless of the item's shape.
    var attachments: [Attachment] {
        switch content {
        case .text: return []
        case .attachment(let attachment): return [attachment]
        case .attachmentGroup(let attachments, _): return attachments
        case .unknown: return []
        }
    }
}
