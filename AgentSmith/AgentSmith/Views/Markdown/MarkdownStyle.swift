import AppKit
import SwiftUI

/// A markdown base font, usable by both renderers: AppKit text views (selectable rendering) take
/// the `NSFont`, SwiftUI `Text` (static rendering) takes the `Font` derived from it. One `NSFont`
/// per face is the source, so the two renderings cannot drift apart.
///
/// A case per face rather than a stored `NSFont`, which is not `Sendable`: the value compares in
/// `MarkdownText`'s nonisolated `==`, and the font is resolved on the main actor where it's drawn.
nonisolated enum MarkdownFont: Equatable, Sendable {
    /// The transcript's monospaced body — `AppFonts.channelBody` is derived from it.
    case channelBody
    /// Italic transcript body — verdict comments, task descriptions.
    case channelBodyItalic
    case body
    case callout
    /// PDF export body — `AppFonts.pdfBody` is derived from it.
    case pdfBody
    case heading1
    case heading2
    case heading3

    /// The AI Commentary inset — `AppFonts.aiCommentaryBody`'s face.
    static let aiCommentaryBody = MarkdownFont.callout

    @MainActor var nsFont: NSFont {
        switch self {
        case .channelBody: return Faces.channelBody
        case .channelBodyItalic: return Faces.channelBodyItalic
        case .body: return Faces.body
        case .callout: return Faces.callout
        case .pdfBody: return Faces.pdfBody
        case .heading1: return Faces.heading1
        case .heading2: return Faces.heading2
        case .heading3: return Faces.heading3
        }
    }

    @MainActor var font: Font { Font(nsFont as CTFont) }

    @MainActor private enum Faces {
        static func textStyleSize(_ style: NSFont.TextStyle) -> CGFloat {
            NSFont.preferredFont(forTextStyle: style).pointSize
        }
        static let channelBody = NSFont.monospacedSystemFont(ofSize: textStyleSize(.body), weight: .regular)
        static let channelBodyItalic = NSFontManager.shared.convert(channelBody, toHaveTrait: .italicFontMask)
        static let body = NSFont.preferredFont(forTextStyle: .body)
        static let callout = NSFont.preferredFont(forTextStyle: .callout)
        static let pdfBody = NSFont.systemFont(ofSize: 12)
        static let heading1 = NSFont.systemFont(ofSize: textStyleSize(.title2), weight: .bold)
        static let heading2 = NSFont.systemFont(ofSize: textStyleSize(.title3), weight: .bold)
        static let heading3 = NSFont.systemFont(ofSize: textStyleSize(.headline), weight: .bold)
    }
}

/// The color of markdown text. A parameter rather than an outer `.foregroundStyle`, because the
/// selectable rendering is an AppKit text view, which a SwiftUI style never reaches.
nonisolated enum MarkdownTextColor: Equatable, Sendable {
    /// The surrounding style in SwiftUI (so PDF export's ink color still applies); the label color
    /// in AppKit, where there is no surrounding style.
    case primary
    case secondary
    case custom(Color)

    /// The style to apply in SwiftUI, or nil to inherit the surrounding one.
    var overridingColor: Color? {
        switch self {
        case .primary: return nil
        case .secondary: return .secondary
        case .custom(let color): return color
        }
    }

    var nsColor: NSColor {
        switch self {
        case .primary: return .labelColor
        case .secondary: return .secondaryLabelColor
        case .custom(let color): return NSColor(color)
        }
    }
}

/// Applies a `MarkdownTextColor` in SwiftUI — leaving the surrounding style alone for `.primary`.
struct MarkdownForegroundModifier: ViewModifier {
    let textColor: MarkdownTextColor

    func body(content: Content) -> some View {
        if let color = textColor.overridingColor {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}

/// How `MarkdownText` draws its prose.
enum MarkdownRendering {
    /// One AppKit text view per prose block — selection runs across lines, as in any Mac app.
    case selectable
    /// One SwiftUI `Text` per line. For `ImageRenderer` (PDF export), which cannot draw AppKit
    /// views; a selection cannot cross from one line's `Text` to the next.
    case staticText
}

private struct MarkdownRenderingKey: EnvironmentKey {
    static let defaultValue = MarkdownRendering.selectable
}

extension EnvironmentValues {
    /// How `MarkdownText` draws prose. Selectable unless a renderer that can't host AppKit
    /// views (PDF export) asks for `.staticText`.
    var markdownRendering: MarkdownRendering {
        get { self[MarkdownRenderingKey.self] }
        set { self[MarkdownRenderingKey.self] = newValue }
    }
}

/// What clicking a link in markdown does — the one implementation for both renderers.
enum MarkdownLinkOpener {
    /// Schemes whose handler is the browser or mail client — what a prose link is expected to do.
    /// Every other scheme hands the URL to whatever app registered it (ssh: → Terminal, smb: →
    /// Finder mounting a share, …), which a model-authored link must not drive on one click.
    private static let schemesOpenedWithoutConfirmation: Set<String> = ["http", "https", "mailto"]

    /// Local paths go through `LocalItemOpener`, which never launches. A path that vanished since
    /// it was linked does nothing. Web and mail links open directly; any other scheme asks first,
    /// naming the app that would handle it.
    static func open(_ url: URL) {
        if url.isFileURL {
            LocalItemOpener.open(url)
            return
        }
        guard let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            presentAlert(message: "No app can open this link", detail: url.absoluteString)
            return
        }
        if let scheme = url.scheme?.lowercased(), schemesOpenedWithoutConfirmation.contains(scheme) {
            openOrReport(url)
            return
        }
        let handlerName = FileManager.default.displayName(atPath: handlerURL.path(percentEncoded: false))
        // Deferred so the modal loop doesn't run inside NSTextView's click tracking or SwiftUI's
        // OpenURLAction dispatch; the click handler returns first.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Open this link in \(handlerName)?"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                openOrReport(url)
            }
        }
    }

    private static func openOrReport(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            presentAlert(message: "Couldn't open this link", detail: url.absoluteString)
        }
    }

    private static func presentAlert(message: String, detail: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.runModal()
        }
    }
}
