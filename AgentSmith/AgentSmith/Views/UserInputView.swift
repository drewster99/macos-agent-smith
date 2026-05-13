import SwiftUI
import UniformTypeIdentifiers
import AgentSmithKit

/// Text field with attachment support for sending messages to Smith.
struct UserInputView: View {
    @Binding var text: String
    var pendingAttachments: [Attachment]
    var isRunning: Bool
    var onSend: () -> Void
    var onAttach: ([URL]) -> Void
    var onRemoveAttachment: (UUID) -> Void
    var onHistoryUp: () -> Bool
    var onHistoryDown: () -> Bool
    var onPaste: () -> Bool

    @State private var showingFilePicker = false
    @State private var showingExpandedEditor = false

    var body: some View {
        let hasComposedContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty

        VStack(spacing: 0) {
            if !pendingAttachments.isEmpty {
                PendingAttachmentBar(
                    attachments: pendingAttachments,
                    onRemove: onRemoveAttachment
                )
                Divider()
            }

            HStack(spacing: 8) {
                UserInputAttachButtonsColumn(
                    isEnabled: isRunning,
                    onAttach: { showingFilePicker = true },
                    onExpand: { showingExpandedEditor = true }
                )

                UserInputTextField(
                    text: $text,
                    isRunning: isRunning,
                    pendingAttachmentCount: pendingAttachments.count,
                    onSend: onSend,
                    onHistoryUp: onHistoryUp,
                    onHistoryDown: onHistoryDown,
                    onPaste: onPaste
                )

                Button(action: onSend, label: {
                    Image(systemName: "paperplane.fill")
                        .imageScale(.large)
                })
                .buttonStyle(.borderedProminent)
                .disabled(!hasComposedContent || !isRunning)
                .opacity(hasComposedContent && isRunning ? 1.0 : 0.4)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(8)
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                onAttach(urls)
            }
        }
        .sheet(isPresented: $showingExpandedEditor) {
            ExpandedEditorSheet(text: $text)
        }
    }
}

/// Horizontal scrolling bar of pending attachments before sending.
private struct PendingAttachmentBar: View {
    let attachments: [Attachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    PendingAttachmentChip(
                        attachment: attachment,
                        onRemove: { onRemove(attachment.id) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(AppColors.secondaryBackground.opacity(0.5))
    }
}

/// A single removable attachment chip in the pending bar.
/// Shows an aspect-fit thumbnail on a square matte for image attachments.
private struct PendingAttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    @State private var chipImage: NSImage?
    @State private var isLoadingImage = false

    var body: some View {
        HStack(spacing: 4) {
            if attachment.isImage, let nsImage = chipImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if attachment.isImage && isLoadingImage {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            } else if attachment.isImage {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
            }
            Text(attachment.filename)
                .font(.caption)
                .lineLimit(1)
            Text(attachment.formattedSize)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary)
        .clipShape(Capsule())
        .task(id: attachment.id) {
            guard attachment.isImage else {
                setChipImage(nil, isLoading: false)
                return
            }
            if let cached = ImageCache.shared.cachedImage(for: attachment, tier: .chip) {
                setChipImage(cached, isLoading: false)
                return
            }
            setChipImage(nil, isLoading: true)
            let loadedImage = await ImageCache.shared.image(for: attachment, tier: .chip)
            guard !Task.isCancelled else { return }
            setChipImage(loadedImage, isLoading: false)
        }
    }

    private func setChipImage(_ image: NSImage?, isLoading: Bool) {
        DispatchQueue.main.async {
            chipImage = image
            isLoadingImage = isLoading
        }
    }

    private var iconName: String {
        if attachment.isPDF { return "doc.richtext" }
        if attachment.mimeType.hasPrefix("text/") { return "doc.text" }
        if attachment.mimeType.hasPrefix("video/") { return "film" }
        if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }
}

/// Large editor window for composing longer messages.
private struct ExpandedEditorSheet: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    /// Local copy so edits can be discarded on Cancel.
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Compose Message")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Done") {
                    text = draft
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            TextEditor(text: $draft)
                .font(AppFonts.inputField)
                .padding(8)
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            // Project rule: defer @State mutation out of lifecycle closures.
            DispatchQueue.main.async { draft = text }
        }
    }
}
