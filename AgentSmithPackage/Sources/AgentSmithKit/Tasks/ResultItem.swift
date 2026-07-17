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
        /// A kind this build doesn't recognize (written by a NEWER build). The original JSON node's
        /// VALUE is preserved in `raw` (semantically, not byte-for-byte — key order/whitespace are
        /// re-normalized by the encoder) so a downgrade→resave keeps the payload instead of
        /// discarding it; the UI renders it as `[unsupported result item: …]`.
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
        // Decode the whole node ONCE as a generic JSON value, then branch on `kind`. This avoids
        // requesting two different containers from the same decoder (a Codable-contract violation
        // that only happens to work with JSONDecoder), and it lets an unrecognized future `kind` be
        // preserved verbatim. Forward-compatible: an unknown kind must NEVER throw — an array decode
        // is all-or-nothing, so one bad item would take down (and quarantine) the whole task file.
        let raw = try AnyCodable(from: decoder)
        guard case .dictionary(let object) = raw, case .string(let kindRaw)? = object["kind"] else {
            // Not the expected object-with-string-kind shape — preserve it rather than throw.
            Self.logger.error("ResultItem.Content decode: unexpected shape; preserving verbatim.")
            self = .unknown(kind: "", raw: raw)
            return
        }
        switch Kind(rawValue: kindRaw) {
        case .text:
            guard case .string(let text)? = object["text"] else {
                self = .unknown(kind: kindRaw, raw: raw)
                return
            }
            self = .text(text)
        case .attachment:
            self = .attachment(try Self.bridgeDecode(Attachment.self, from: object["attachment"]))
        case .attachmentGroup:
            var description: String?
            if case .string(let value)? = object["description"] { description = value }
            self = .attachmentGroup(
                attachments: try Self.bridgeDecode([Attachment].self, from: object["attachments"]),
                description: description
            )
        case nil:
            // An unrecognized kind can only come from a NEWER build (or a removed case). Preserve the
            // ORIGINAL node so a downgrade→resave round-trips it losslessly; the UI shows a
            // placeholder. NOT an assertionFailure — this runs during boot-time task decode, where a
            // trap would crash the app on launch for anyone whose on-disk data hit it.
            Self.logger.error("Unknown ResultItem.Content kind '\(kindRaw, privacy: .public)' during decode — written by a newer build; preserving it behind a placeholder.")
            self = .unknown(kind: kindRaw, raw: raw)
        }
    }

    /// Decodes a typed payload out of an already-parsed `AnyCodable` sub-value by round-tripping it
    /// through JSON. Keeps `init(from:)` to a single container while still decoding `Attachment`
    /// et al. with their own `Codable`. Cost is negligible — result items are few and small.
    private static func bridgeDecode<T: Decodable>(_ type: T.Type, from value: AnyCodable?) throws -> T {
        guard let value else {
            throw DecodingError.valueNotFound(T.self, .init(codingPath: [], debugDescription: "missing payload for result item"))
        }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    public func encode(to encoder: Encoder) throws {
        // Branch `.unknown` BEFORE creating any container: it writes the preserved node directly
        // (a single container on this encoder). Creating a keyed container here and then also calling
        // `raw.encode(to:)` would request two containers on one encoder — a contract violation.
        if case .unknown(_, let raw) = self {
            try raw.encode(to: encoder)
            return
        }
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
        case .unknown:
            break  // handled above
        }
    }

    private static let logger = Logger(subsystem: "AgentSmithKit", category: "ResultItem")
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
