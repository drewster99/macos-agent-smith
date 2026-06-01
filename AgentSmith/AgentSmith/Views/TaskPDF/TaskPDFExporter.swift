import SwiftUI
import AppKit
import AgentSmithKit

/// Which task elements a generated PDF should include. The four metadata flags and the
/// three body flags map 1:1 to the toggles offered in the task-detail "Save as PDF" sheet.
/// `title` and the completion date/time are always rendered (they identify the document),
/// so they are not represented here.
struct TaskPDFFieldOptions: Equatable {
    var startTime: Bool
    var elapsedTime: Bool
    var tokens: Bool
    var cost: Bool
    var description: Bool
    var summary: Bool
    var result: Bool

    /// Everything on — used by the task-list "PDF" context-menu action, which is not
    /// configurable and shows start/finish, request, result, tokens, cost, and summary.
    static let full = TaskPDFFieldOptions(
        startTime: true,
        elapsedTime: true,
        tokens: true,
        cost: true,
        description: true,
        summary: true,
        result: true
    )

    /// Minimal preset used by the in-transcript "Task Completed" banner: task title,
    /// task detail (description), date/time completed, and the final result only.
    static let transcript = TaskPDFFieldOptions(
        startTime: false,
        elapsedTime: false,
        tokens: false,
        cost: false,
        description: true,
        summary: false,
        result: true
    )
}

/// Renders an `AgentTask` to a multi-page, print-friendly PDF.
///
/// The document (`TaskPDFDocumentView.pdfBlocks()`) is laid out block-by-block onto
/// US-Letter pages with uniform margins. Each block is rendered with `ImageRenderer` and
/// placed whole; a block that doesn't fit in the remaining space moves to the next page, so
/// page breaks fall *between* paragraphs rather than through them. Only a single block
/// taller than a full page is sliced (unavoidable, and rare).
@MainActor
enum TaskPDFExporter {
    /// US-Letter page geometry in PDF points.
    private static let pageSize = CGSize(width: 612, height: 792)
    /// Uniform page margin in PDF points (0.5"). Applied on every page — top and bottom
    /// included — so content never runs to the paper edge at a page break.
    private static let margin: CGFloat = 48
    /// Vertical gap inserted between consecutive blocks on the same page.
    private static let interBlockGap: CGFloat = 12

    /// Builds PDF bytes for `task`. `tokens` / `cost` are only consulted when the matching
    /// option flag is set; pass `nil` otherwise. Returns `nil` if the renderer fails to
    /// produce a Core Graphics context.
    static func makePDFData(
        for task: AgentTask,
        options: TaskPDFFieldOptions,
        tokens: AppViewModel.TaskTokenTotals?,
        cost: Double?,
        generatedAt: Date
    ) -> Data? {
        let contentWidth = pageSize.width - margin * 2
        let liveHeight = pageSize.height - margin * 2
        let topY = pageSize.height - margin       // PDF-y of the top of the live area
        let bottomY = margin                       // PDF-y of the bottom of the live area

        let document = TaskPDFDocumentView(
            task: task,
            options: options,
            tokens: tokens,
            cost: cost,
            generatedAt: generatedAt
        )
        let blocks = document.pdfBlocks()

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var pageOpen = false
        var cursorY = topY   // PDF-y at which the next block's TOP should sit

        func beginPage() {
            pdfContext.beginPDFPage(nil)
            pdfContext.setFillColor(CGColor(gray: 1, alpha: 1))
            pdfContext.fill(CGRect(origin: .zero, size: pageSize))
            cursorY = topY
            pageOpen = true
        }
        func endPage() {
            guard pageOpen else { return }
            pdfContext.endPDFPage()
            pageOpen = false
        }
        /// Draws a block (visual top at PDF-y `top`), clipped to the live area so it can
        /// never bleed into a margin.
        func drawBlock(_ render: (CGContext) -> Void, height: CGFloat, top: CGFloat) {
            pdfContext.saveGState()
            pdfContext.clip(to: CGRect(x: margin, y: bottomY, width: contentWidth, height: liveHeight))
            // ImageRenderer draws content with its visual top at content-space y == height;
            // shift so that maps to page-y == top, inset by the left margin.
            pdfContext.translateBy(x: margin, y: top - height)
            render(pdfContext)
            pdfContext.restoreGState()
        }

        for block in blocks {
            let renderer = ImageRenderer(content: block
                .frame(width: contentWidth, alignment: .topLeading)
                .foregroundStyle(.black)
                // Force light rendering so theme-adaptive `AppColors` resolve to
                // ink-on-paper values regardless of the app's current appearance.
                .environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)

            renderer.render { size, renderInContext in
                let height = size.height
                if height <= 0 { return }
                if !pageOpen { beginPage() }

                let atTop = abs(cursorY - topY) < 0.5
                let blockTop = atTop ? cursorY : cursorY - interBlockGap

                if height <= liveHeight {
                    if blockTop - height < bottomY - 0.5 {
                        // Won't fit in the remaining space — move to a fresh page.
                        endPage()
                        beginPage()
                        drawBlock(renderInContext, height: height, top: cursorY)
                        cursorY -= height
                    } else {
                        drawBlock(renderInContext, height: height, top: blockTop)
                        cursorY = blockTop - height
                    }
                } else {
                    // Block taller than a whole page: slice it (unavoidable). Start on a
                    // fresh page, then lay successive page-height bands.
                    if !atTop {
                        endPage()
                        beginPage()
                    }
                    let sliceCount = max(1, Int(ceil(height / liveHeight)))
                    for k in 0..<sliceCount {
                        if k > 0 {
                            endPage()
                            beginPage()
                        }
                        pdfContext.saveGState()
                        pdfContext.clip(to: CGRect(x: margin, y: bottomY, width: contentWidth, height: liveHeight))
                        let yTranslate = topY - (height - CGFloat(k) * liveHeight)
                        pdfContext.translateBy(x: margin, y: yTranslate)
                        renderInContext(pdfContext)
                        pdfContext.restoreGState()
                    }
                    let usedOnLast = height - CGFloat(sliceCount - 1) * liveHeight
                    cursorY = topY - usedOnLast
                }
            }
        }

        endPage()
        pdfContext.closePDF()
        return mutableData as Data
    }

    /// A filesystem-safe `<title>.pdf` filename for `task`.
    nonisolated static func sanitizedFilename(for task: AgentTask) -> String {
        let base = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var cleaned = base
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading dots so a title like ".zshrc" doesn't produce a hidden file.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Task" : cleaned) + ".pdf"
    }
}
