import AppKit
import SwiftUI
import AgentSmithKit

/// A block of markdown prose as ONE AppKit text view, so a selection runs across its lines.
///
/// SwiftUI cannot do this: a selection never crosses from one `Text` to the next, and merging the
/// lines into one `Text` loses list indentation (SwiftUI ignores `NSParagraphStyle.headIndent` —
/// measured 2026-10-14). The view sizes itself to its width through `sizeThatFits`, so it lays
/// out like any SwiftUI view.
struct SelectableProseView: NSViewRepresentable {
    let lines: [MarkdownLine]
    let baseFont: MarkdownFont
    let textColor: MarkdownTextColor
    @Environment(\.lineLimit) private var lineLimit

    /// Everything the text view's content is built from — rebuilt only when this changes.
    struct ContentKey: Equatable {
        let lines: [MarkdownLine]
        let baseFont: MarkdownFont
        let textColor: MarkdownTextColor
        let lineLimit: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProseTextView {
        let textView = ProseTextView()
        textView.delegate = context.coordinator
        return textView
    }

    func updateNSView(_ textView: ProseTextView, context: Context) {
        let key = ContentKey(lines: lines, baseFont: baseFont, textColor: textColor, lineLimit: lineLimit)
        guard key != context.coordinator.renderedKey else { return }
        context.coordinator.renderedKey = key
        let prose = MarkdownProseBuilder.prose(for: lines, baseFont: baseFont, textColor: textColor.nsColor)
        textView.show(prose, lineLimit: lineLimit)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProseTextView, context: Context) -> CGSize? {
        nsView.size(fittingWidth: proposal.width)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var renderedKey: ContentKey?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            MarkdownLinkOpener.open(url)
            return true
        }
    }
}

/// A read-only, selectable text view that measures its height for a given width.
final class ProseTextView: NSTextView {
    /// Lays the same text out at whatever width SwiftUI proposes, so measuring never touches the
    /// container the text is DRAWN in. SwiftUI may propose several widths in one layout pass; a
    /// measurement that resized the drawing container left the text wrapped at the last proposal
    /// rather than at the width the view was finally given.
    private let measuringLayoutManager = NSLayoutManager()
    private let measuringContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    /// Height of blank lines at the end of the prose, which are not in the text (an empty last
    /// paragraph would take the previous line's full height) but still separate it from what follows.
    private var trailingBlankHeight: CGFloat = 0

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        measuringContainer.lineFragmentPadding = 0
        measuringLayoutManager.addTextContainer(measuringContainer)
        storage.addLayoutManager(measuringLayoutManager)
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        usesFontPanel = false
        isAutomaticLinkDetectionEnabled = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
    }

    @available(*, unavailable, message: "Created in code only")
    required init?(coder: NSCoder) {
        nil
    }

    func show(_ prose: MarkdownProseBuilder.Prose, lineLimit: Int?) {
        textStorage?.setAttributedString(prose.text)
        trailingBlankHeight = prose.trailingBlankHeight
        for container in [textContainer, measuringContainer].compactMap({ $0 }) {
            container.maximumNumberOfLines = lineLimit ?? 0
            container.lineBreakMode = lineLimit == nil ? .byWordWrapping : .byTruncatingTail
        }
    }

    /// The size the text needs at `width`; with no width, its natural (unwrapped) size.
    func size(fittingWidth width: CGFloat?) -> CGSize {
        let boundedWidth = width.flatMap { $0.isFinite ? max(1, $0) : nil }
        guard let textStorage, textStorage.length > 0 else {
            return CGSize(width: boundedWidth ?? 0, height: trailingBlankHeight)
        }
        measuringContainer.size = NSSize(width: boundedWidth ?? CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude)
        measuringLayoutManager.ensureLayout(for: measuringContainer)
        let used = measuringLayoutManager.usedRect(for: measuringContainer)
        return CGSize(width: boundedWidth ?? used.width.rounded(.up),
                      height: used.height.rounded(.up) + trailingBlankHeight)
    }

    /// One selection on screen at a time: a text view the user has left drops its selection
    /// rather than leaving a stale gray highlight in every row it was ever used in.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }
}

/// Builds the attributed string a `SelectableProseView` shows.
enum MarkdownProseBuilder {
    /// The text to draw, plus the height of blank lines ending the prose, which are space below
    /// the text rather than part of it.
    struct Prose {
        let text: NSAttributedString
        let trailingBlankHeight: CGFloat
    }

    static func prose(for allLines: [MarkdownLine], baseFont: MarkdownFont, textColor: NSColor) -> Prose {
        var lines = allLines
        var trailingBlanks = 0
        while lines.last == .blank {
            lines.removeLast()
            trailingBlanks += 1
        }
        // The static renderer's spacing exactly: each blank is its own 6pt row plus the line gap.
        let trailingHeight = CGFloat(trailingBlanks) * (MarkdownLine.blankLineHeight + MarkdownLine.lineSpacing)
        return Prose(text: attributedString(for: lines, baseFont: baseFont, textColor: textColor),
                     trailingBlankHeight: trailingHeight)
    }

    private static func attributedString(for lines: [MarkdownLine], baseFont: MarkdownFont,
                                         textColor: NSColor) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            switch line {
            case .heading(let level, let text):
                let font = MarkdownLine.headingFont(level: level)
                appendInline(text, font: font, color: textColor, paragraph: paragraphStyle(), to: output)
            case .blank:
                // An empty paragraph: all it has is the line break below, which carries the
                // reduced height. Never last — `prose(for:)` moved trailing blanks out.
                break
            case .listItem(let marker, let text, let indent):
                let markerWidth = (marker as NSString).size(withAttributes: [.font: baseFont.nsFont]).width
                let textStart = indent + markerWidth.rounded(.up) + MarkdownLine.listMarkerSpacing
                let style = paragraphStyle()
                style.firstLineHeadIndent = indent
                style.headIndent = textStart
                style.tabStops = [NSTextTab(textAlignment: .left, location: textStart)]
                output.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: baseFont.nsFont, .foregroundColor: textColor, .paragraphStyle: style
                ]))
                appendInline(text, font: baseFont, color: textColor, paragraph: style, to: output)
            case .indented(let text, let indent):
                let style = paragraphStyle()
                style.firstLineHeadIndent = indent
                style.headIndent = indent
                appendInline(text, font: baseFont, color: textColor, paragraph: style, to: output)
            case .plain(let text):
                appendInline(text, font: baseFont, color: textColor, paragraph: paragraphStyle(), to: output)
            }
            if !isLast {
                // The line break carries the line's own paragraph style, so an empty (blank) line
                // gets its reduced height.
                let lastStyle = output.length > 0
                    ? output.attribute(.paragraphStyle, at: output.length - 1, effectiveRange: nil)
                    : nil
                var attributes: [NSAttributedString.Key: Any] = [.font: baseFont.nsFont]
                if case .blank = line {
                    let style = paragraphStyle()
                    style.minimumLineHeight = MarkdownLine.blankLineHeight
                    style.maximumLineHeight = MarkdownLine.blankLineHeight
                    attributes[.paragraphStyle] = style
                    attributes[.font] = NSFont.systemFont(ofSize: MarkdownLine.blankLineHeight * 0.75)
                } else if let lastStyle {
                    attributes[.paragraphStyle] = lastStyle
                }
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return output
    }

    private static func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = MarkdownLine.lineSpacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Appends one line of inline markdown — emphasis, links, code-span color — styled by the same
    /// `InlineMarkdownStyler` the static renderer uses.
    private static func appendInline(_ raw: String, font: MarkdownFont, color: NSColor,
                                     paragraph: NSParagraphStyle, to output: NSMutableAttributedString) {
        let styled = InlineMarkdownStyler.styledLine(raw, inlineCodeColor: AppColors.inlineCode)
        for run in styled.runs {
            var runFont = font.nsFont
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
                }
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            attributes[.font] = runFont
            attributes[.foregroundColor] = run.swiftUI.foregroundColor.map { NSColor($0) } ?? color
            if let link = run.link { attributes[.link] = link }
            output.append(NSAttributedString(string: String(styled[run.range].characters), attributes: attributes))
        }
    }
}
