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

    /// Whether any of the four metadata rows are enabled — drives whether the metadata
    /// grid renders at all.
    var hasAnyMetadata: Bool {
        startTime || elapsedTime || tokens || cost
    }
}

/// Renders an `AgentTask` to a multi-page, print-friendly PDF.
///
/// The document is laid out as a single continuous SwiftUI view at US-Letter width and
/// then sliced into 612×792 pages by translating the PDF context's CTM between
/// `beginPDFPage` calls — so long results paginate instead of producing one oversized page.
@MainActor
enum TaskPDFExporter {
    /// US-Letter page geometry in PDF points.
    private static let pageSize = CGSize(width: 612, height: 792)
    /// Uniform page margin in PDF points (0.5"). Applied on every page — top and bottom
    /// included — so content never runs to the paper edge at a page break.
    private static let margin: CGFloat = 48

    /// Builds PDF bytes for `task`. `tokens` / `cost` are only consulted when the matching
    /// option flag is set; pass `nil` otherwise. Returns `nil` if the renderer fails to
    /// produce a context (e.g. zero-size content).
    static func makePDFData(
        for task: AgentTask,
        options: TaskPDFFieldOptions,
        tokens: AppViewModel.TaskTokenTotals?,
        cost: Double?,
        generatedAt: Date
    ) -> Data? {
        let contentWidth = pageSize.width - margin * 2
        let content = TaskPDFDocumentView(
            task: task,
            options: options,
            tokens: tokens,
            cost: cost,
            generatedAt: generatedAt
        )
        .frame(width: contentWidth, alignment: .topLeading)
        .background(Color.white)
        // Force light rendering so theme-adaptive `AppColors` resolve to ink-on-paper
        // values regardless of the app's current appearance.
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)

        var pdfData: Data?
        renderer.render { size, renderInContext in
            let mutableData = NSMutableData()
            guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else { return }
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            guard let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }

            let totalHeight = max(size.height, 1)
            // Height available for content on each page, once the top and bottom margins
            // are reserved. Content is sliced into bands of this height.
            let liveHeight = pageSize.height - margin * 2
            let pageCount = max(1, Int(ceil(totalHeight / liveHeight)))

            for pageIndex in 0..<pageCount {
                pdfContext.beginPDFPage(nil)

                // Paint the whole page white first — content shorter than a full page would
                // otherwise leave the remainder transparent.
                pdfContext.setFillColor(CGColor(gray: 1, alpha: 1))
                pdfContext.fill(CGRect(origin: .zero, size: pageSize))

                pdfContext.saveGState()
                // Clip to the live content area so this page's band never bleeds into the
                // margins (top, bottom, or sides) — including at interior page breaks.
                pdfContext.clip(to: CGRect(x: margin, y: margin, width: contentWidth, height: liveHeight))
                // PDF origin is bottom-left and the rendered content's visual top sits at
                // y == totalHeight. Anchor page 0's content to the top of the live area and
                // advance one `liveHeight` band per page.
                let yTranslate = pageSize.height - margin - totalHeight + CGFloat(pageIndex) * liveHeight
                pdfContext.translateBy(x: margin, y: yTranslate)
                renderInContext(pdfContext)
                pdfContext.restoreGState()

                pdfContext.endPDFPage()
            }
            pdfContext.closePDF()
            pdfData = mutableData as Data
        }
        return pdfData
    }

    /// A filesystem-safe `<title>.pdf` filename for `task`.
    nonisolated static func sanitizedFilename(for task: AgentTask) -> String {
        let base = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = base
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Task" : cleaned) + ".pdf"
    }
}
