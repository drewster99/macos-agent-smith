import Foundation
import os

/// A tiny actor-safe buffer for attachments staged during a bounded evaluation loop
/// (acceptance validators, the Security Agent) that own their own stage→drain instead of
/// routing to a live `AgentActor`. `attach_file`'s stage closure appends here; the loop drains
/// it after each tool round and injects the bytes into the next user turn.
actor StagedAttachmentBuffer {
    private var pending: [Attachment] = []
    func stage(_ attachments: [Attachment]) { pending.append(contentsOf: attachments) }
    func drain() -> [Attachment] {
        let out = pending
        pending.removeAll()
        return out
    }
}

/// Shared assembly of attachment content for an LLM user turn.
///
/// Image bytes — when the target model is vision-capable AND the format is provider-injectable —
/// become downscaled `LLMImageContent` blocks. Every other attachment (non-image, a
/// non-injectable image format, or any image when the model can't see) becomes a `file://`
/// markdown reference line the agent can pass to `file_read`.
///
/// Centralized so the three things that used to be reimplemented per call site — the downscale,
/// the provider-format gate (`ImageDownscaler.isProviderInjectable`), and the model
/// vision-capability gate — live in exactly one place. Used by `AgentActor`, `SecurityEvaluator`,
/// and `EvaluationRunner` so all three loops treat images identically.
enum AttachmentInjection {
    private static let logger = Logger(subsystem: "AgentSmithKit", category: "AttachmentInjection")

    /// Raw-byte ceiling for native document injection. A PDF larger than this is NOT sent as a
    /// document block (base64 expansion + provider size limits would risk a hard API 400 / token
    /// blowup) — it degrades to its reference line so the agent reads the extracted text via
    /// `file_read`. Conservative across providers (Anthropic caps PDFs at 32 MB).
    static let defaultMaxDocumentBytes = 20 * 1024 * 1024

    /// The result of assembling attachments: image + document content blocks to attach to a
    /// `.user` turn, and reference lines to append to that turn's text.
    struct Assembled {
        var images: [LLMImageContent]
        var documents: [LLMDocumentContent]
        var referenceLines: [String]

        var isEmpty: Bool { images.isEmpty && documents.isEmpty && referenceLines.isEmpty }
    }

    /// Builds image blocks + reference lines for `attachments`.
    ///
    /// EVERY attachment gets a `file://` reference line (the `id=` forwarding handle a model can
    /// quote into `create_task`/`task_update`, plus a path it can pass to `file_read`). On top of
    /// that, an injectable image on a vision-capable model also gets an image content block.
    ///
    /// - Parameters:
    ///   - attachments: the attachments to inject.
    ///   - modelSupportsVision: when false, image bytes are NOT injected as blocks — the image
    ///     still gets its reference line (with a note), so a non-vision model is never sent bytes
    ///     it can't read (which some providers reject outright).
    ///   - maxLongEdge: downscale target for images (defaults to the standard 1024px tier;
    ///     nil skips resizing).
    ///   - urlProvider: resolves an attachment's stable `file://` URL for its reference line.
    static func assemble(
        _ attachments: [Attachment],
        modelSupportsVision: Bool,
        modelSupportsDocuments: Bool = false,
        maxLongEdge: Int? = ImageDownscaler.defaultMaxLongEdge,
        maxDocumentBytes: Int = defaultMaxDocumentBytes,
        urlProvider: (UUID, String) -> URL?
    ) -> Assembled {
        var images: [LLMImageContent] = []
        var documents: [LLMDocumentContent] = []
        var referenceLines: [String] = []

        for attachment in attachments {
            // When media the model COULD have shown isn't injected, `skipNote` carries the reason
            // onto the reference line so the omission is visible to the agent, never silent.
            var skipNote: String?
            let data = attachment.data
            let hasEmptyBytes = data?.isEmpty == true

            if attachment.isImage {
                if !modelSupportsVision {
                    skipNote = "image not shown — the assigned model is not vision-capable"
                } else if data == nil || hasEmptyBytes {
                    if hasEmptyBytes {
                        Self.logger.warning("Attachment \(attachment.filename, privacy: .public) (id=\(attachment.id.uuidString, privacy: .public)) has 0 bytes — not injecting an empty image block.")
                    }
                    skipNote = "image not shown — no readable bytes; use file_read if it has text"
                } else if let data {
                    let resized = ImageDownscaler.downscale(data, maxLongEdge: maxLongEdge, sourceMimeType: attachment.mimeType)
                    if ImageDownscaler.isProviderInjectable(mimeType: resized.mimeType) {
                        images.append(LLMImageContent(data: resized.data, mimeType: resized.mimeType))
                    } else {
                        skipNote = "image not shown — unsupported format; use file_read if it has text"
                    }
                }
            } else if attachment.isPDF, modelSupportsDocuments {
                if data == nil || hasEmptyBytes {
                    if hasEmptyBytes {
                        Self.logger.warning("Attachment \(attachment.filename, privacy: .public) (id=\(attachment.id.uuidString, privacy: .public)) has 0 bytes — not injecting an empty document block.")
                    }
                    skipNote = "PDF not embedded — no readable bytes; use file_read"
                } else if let data, data.count > maxDocumentBytes {
                    Self.logger.warning("PDF \(attachment.filename, privacy: .public) is \(attachment.formattedSize, privacy: .public), over the \(maxDocumentBytes) byte embed cap — sending a reference instead; the agent can file_read its text.")
                    skipNote = "PDF not embedded — \(attachment.formattedSize) exceeds the embed limit; use file_read for its text"
                } else if let data {
                    documents.append(LLMDocumentContent(data: data, mimeType: attachment.mimeType, filename: attachment.filename))
                }
            }

            // Reference line for EVERY attachment — the forwarding handle stays even when the media
            // is also shown inline; it's how the model quotes an id or reads non-image bytes.
            let url = urlProvider(attachment.id, attachment.filename)
            let urlString = url.map { "file://" + $0.path(percentEncoded: false) } ?? "#"
            var line = "[\(attachment.filename)](\(urlString)) \(attachment.mimeType) · \(attachment.formattedSize) · id=\(attachment.id.uuidString)"
            if let skipNote {
                line += "  (\(skipNote))"
            }
            referenceLines.append(line)
        }

        return Assembled(images: images, documents: documents, referenceLines: referenceLines)
    }
}
