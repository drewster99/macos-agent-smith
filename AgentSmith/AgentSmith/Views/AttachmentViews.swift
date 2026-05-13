import SwiftUI
import AgentSmithKit

/// SwiftUI environment key carrying the per-session attachment-bytes loader. The view
/// hierarchy reads it via `@Environment(\.attachmentBytesLoader)` so views that can't
/// own a closure (e.g. `MessageRow`, which is `Equatable`) still get session-aware
/// loading without modifying their public surface. Set at the root of each session
/// scene with `.environment(\.attachmentBytesLoader, viewModel.attachmentBytesLoader)`.
struct AttachmentBytesLoaderKey: EnvironmentKey {
    static let defaultValue: (@Sendable (UUID, String) async -> Data?)? = nil
}

extension EnvironmentValues {
    var attachmentBytesLoader: (@Sendable (UUID, String) async -> Data?)? {
        get { self[AttachmentBytesLoaderKey.self] }
        set { self[AttachmentBytesLoaderKey.self] = newValue }
    }
}

/// Displays an attachment inline: images as cached thumbnails, other files as badges.
/// Uses `ImageCache` for efficient tiered rendering. Tapping an image invokes `onTapImage`.
///
/// Reads the per-session bytes loader from the environment so session-restored
/// attachments (where `Attachment.data` is nil and bytes live on disk) still render.
struct AttachmentView: View {
    let attachment: Attachment
    let tier: ImageCache.Tier
    var onTapImage: (() -> Void)?

    @Environment(\.attachmentBytesLoader) private var bytesLoader
    @State private var loadedImage: NSImage?
    @State private var isLoadingImage = false

    var body: some View {
        if attachment.isImage {
            imageView()
                .task(id: imageLoadID) {
                    if let cached = ImageCache.shared.cachedImage(for: attachment, tier: tier) {
                        setLoadedImage(cached, isLoading: false)
                        return
                    }
                    setLoadedImage(nil, isLoading: true)
                    let image = await ImageCache.shared.image(for: attachment, tier: tier, bytesLoader: bytesLoader)
                    guard !Task.isCancelled else { return }
                    setLoadedImage(image, isLoading: false)
                }
        } else {
            fileBadge()
        }
    }

    @ViewBuilder
    private func imageView() -> some View {
        Group {
            if let nsImage = loadedImage {
                Button(action: { onTapImage?() }, label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: tier == .small ? 200 : 400,
                               maxHeight: tier == .small ? 150 : 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.set() }
                    else { NSCursor.arrow.set() }
                }
            } else if isLoadingImage {
                ProgressView()
                    .frame(width: 60, height: 60)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(width: 60, height: 60)
            }
        }
    }

    private var imageLoadID: String {
        "\(attachment.id.uuidString)-\(tier.rawValue)"
    }

    private func setLoadedImage(_ image: NSImage?, isLoading: Bool) {
        DispatchQueue.main.async {
            loadedImage = image
            isLoadingImage = isLoading
        }
    }

    @ViewBuilder
    private func fileBadge() -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text(attachment.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var iconName: String {
        if attachment.isPDF { return "doc.richtext" }
        if attachment.isImage { return "photo" }
        if attachment.mimeType.hasPrefix("text/") { return "doc.text" }
        if attachment.mimeType.hasPrefix("video/") { return "film" }
        if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }
}

/// Full-screen overlay that displays an image at its original resolution.
/// Dismisses on backdrop click or the close button. Escape is handled by the parent
/// view via a @FocusState so it intercepts before MainView's stop-agents handler.
struct ImageLightbox: View {
    let attachment: Attachment
    let onDismiss: () -> Void

    @Environment(\.attachmentBytesLoader) private var bytesLoader
    @State private var fullImage: NSImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Button(action: onDismiss, label: {
                AppColors.lightboxBackdrop
                    .ignoresSafeArea()
            })
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss image viewer")

            if let nsImage = fullImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(40)
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Image could not be loaded")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
                Spacer()
                Text(attachment.filename)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 16)
            }
        }
        .transition(.opacity)
        .task {
            let image = await ImageCache.shared.image(for: attachment, tier: .full, bytesLoader: bytesLoader)
            if let image {
                fullImage = image
            } else {
                loadFailed = true
            }
        }
    }
}

/// Renders a `file_write` path with colored directory components and a clickable filename.
/// If the path traversed a symlink (detected by checking the resolved path), shows the
/// symlink destination as a secondary label.
/// Renders a tool name as a styled chip (blue text, light background, subtle border).
struct ToolNameChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(AppFonts.channelBody)
            .foregroundStyle(AppColors.toolChipForeground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(AppColors.toolChipBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(AppColors.toolChipBorder, lineWidth: 1.0)
            )
    }
}

/// Renders a file path with the directory dimmed and the filename highlighted in bold cyan.
struct ToolPathText: View {
    let path: String

    private var directory: String {
        guard !path.isEmpty else { return "" }
        let dir = (path as NSString).deletingLastPathComponent
        return dir.hasSuffix("/") ? dir : dir + "/"
    }

    private var filename: String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(directory)
                .font(AppFonts.channelBody)
                .foregroundStyle(.secondary.opacity(0.7))
                .lineLimit(1)
            Text(filename)
                .font(AppFonts.channelBody.bold())
                .foregroundStyle(AppColors.toolPathFilename)
                .lineLimit(1)
        }
    }
}

struct FileWritePathView: View {
    let path: String

    private var url: URL { URL(fileURLWithPath: path) }

    /// If the path is a symlink (or contains symlinks), returns the resolved destination.
    private var symlinkDestination: String? {
        guard !path.isEmpty else { return nil }
        let resolved = url.resolvingSymlinksInPath().path
        let standardized = url.standardized.path
        return resolved != standardized ? resolved : nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ToolNameChip(name: "file_write")
            Button(action: { openInFinder() }, label: {
                ToolPathText(path: path)
            })
            .buttonStyle(.plain)
            .accessibilityLabel("Reveal \(path) in Finder")

            if let dest = symlinkDestination {
                Text(" \u{2192} ")
                    .font(AppFonts.channelBody)
                    .foregroundStyle(.secondary)
                Button(action: { openInFinder(path: dest) }, label: {
                    Text(dest)
                        .font(AppFonts.channelBody)
                        .foregroundStyle(AppColors.symlinkDestination)
                })
                .buttonStyle(.plain)
                .accessibilityLabel("Reveal symlink destination \(dest) in Finder")
            }
        }
    }

    private func openInFinder(path overridePath: String? = nil) {
        let targetPath = overridePath ?? path
        let targetURL = URL(fileURLWithPath: targetPath)
        if FileManager.default.fileExists(atPath: targetPath) {
            NSWorkspace.shared.activateFileViewerSelecting([targetURL])
        }
    }
}

// MARK: - Hover Tooltip

/// A lightweight tooltip that appears immediately on hover, positioned above the anchor view.
/// Avoids the long delay of the system `.help()` modifier.
private struct HoverTooltip: ViewModifier {
    let text: String

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isHovering {
                    Text(text)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        .fixedSize()
                        .offset(y: -26)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                }
            }
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverTooltip(_ text: String) -> some View {
        modifier(HoverTooltip(text: text))
    }
}
