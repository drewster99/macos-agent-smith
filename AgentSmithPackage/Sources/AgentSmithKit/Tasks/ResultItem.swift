import Foundation

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
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .attachment:
            self = .attachment(try c.decode(Attachment.self, forKey: .attachment))
        case .attachmentGroup:
            self = .attachmentGroup(
                attachments: try c.decode([Attachment].self, forKey: .attachments),
                description: try c.decodeIfPresent(String.self, forKey: .description)
            )
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
        }
    }
}
