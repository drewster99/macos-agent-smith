import AppKit
import SwiftUI
import AgentSmithKit

/// Lets SwiftUI ask the transcript table to scroll — the "jump to latest" button lives in SwiftUI,
/// the scroll position in AppKit.
final class TranscriptScrollController {
    fileprivate weak var coordinator: TranscriptTableView.Coordinator?

    func scrollToBottom(animated: Bool) {
        coordinator?.scrollToBottom(animated: animated)
    }

    /// Scrolls the transcript at a fixed speed and reports how smoothly it drew. Debug tooling.
    func runScrollBenchmark(completion: @escaping (TranscriptScrollBenchmarkOutcome) -> Void) {
        coordinator?.runScrollBenchmark(completion: completion)
    }
}

/// The transcript's rows, in an `NSTableView`.
///
/// Why AppKit: a table keeps views only for the rows on screen and remembers every row's height,
/// so scrolling and appending cost the same at 5,000 rows as at 50. SwiftUI's non-lazy stacks lay
/// out every row they hold on every change, and its lazy stacks mis-size variable-height rows on
/// macOS (project rule) — between them, the transcript had to choose between scrollback and speed.
///
/// Each row is the existing SwiftUI row view in an `NSHostingView`. A row reports its own height
/// (`onGeometryChange`) whenever it changes — first layout, expand/collapse, a window resize — and
/// the table re-tiles around it, keeping whatever the user is reading in place.
struct TranscriptTableView: NSViewRepresentable {
    let messages: [ChannelMessage]
    let options: TranscriptRows.Options
    /// Persisted messages not yet loaded; non-zero shows a "restore full history" row at the top.
    let restorableHistoryCount: Int
    let rowContext: TranscriptRowContext
    let scrollController: TranscriptScrollController
    /// Whether the viewport is at the end of the transcript — drives the jump-to-latest button.
    let onAtBottomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptContainerView {
        let scrollView = TranscriptScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false

        let tableView = TranscriptNSTableView()
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsEmptySelection = true
        tableView.gridStyleMask = []
        tableView.usesAutomaticRowHeights = false
        tableView.focusRingType = .none
        tableView.refusesFirstResponder = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        context.coordinator.attach(scrollView: scrollView, tableView: tableView)
        return TranscriptContainerView(scrollView: scrollView)
    }

    /// The transcript fills whatever it is offered; it never asks SwiftUI for a size of its own.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptContainerView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ container: TranscriptContainerView, context: Context) {
        let coordinator = context.coordinator
        scrollController.coordinator = coordinator
        coordinator.onAtBottomChange = onAtBottomChange
        coordinator.update(
            messages: messages,
            options: options,
            restorableHistoryCount: restorableHistoryCount,
            rowContext: rowContext
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        /// How close to the end still counts as "at the bottom", as a fraction of the viewport, so
        /// tail-following survives the small drift a row's late height change leaves behind.
        private static let bottomProximity: CGFloat = 0.2
        /// Row views kept alive off screen, so a row scrolled away and back keeps its state
        /// (expanded, popover anchor). Rows on screen are never evicted.
        private static let hostCacheCapacity = 400

        var onAtBottomChange: ((Bool) -> Void)?

        private weak var scrollView: TranscriptScrollView?
        private weak var tableView: NSTableView?

        private var displayRows: [TranscriptDisplayRow] = []
        /// Render keys of the MESSAGE rows (no header), for planning the next edit.
        private var messageRowKeys: [TranscriptRow.RenderKey] = []
        private var indexByKey: [TranscriptDisplayRow.Key: Int] = [:]
        private var lastInput: InputSignature?
        private var rowContext: TranscriptRowContext?

        /// Measured heights, reported by the rows themselves. A row not yet shown is estimated.
        private var heightByKey: [TranscriptDisplayRow.Key: CGFloat] = [:]
        private var hosts = RowHostCache(capacity: hostCacheCapacity)
        private var pendingHeightKeys: Set<TranscriptDisplayRow.Key> = []
        private var heightFlushScheduled = false

        /// Follow the end of the transcript as it grows. Changed only by the USER scrolling (and
        /// the jump-to-latest button) — never by content growth or a row changing height.
        private var isPinnedToBottom = true
        private var reportedAtBottom: Bool?
        private var benchmark: BenchmarkRun?

        /// Non-zero while this coordinator moves the scroll position itself.
        private var programmaticScrollDepth = 0
        /// Until when bounds changes count as the user's. A smooth-scrolling wheel moves the view
        /// over the frames AFTER its event, so the position right after `scrollWheel` can still
        /// read "at the bottom" — judging only then would miss the user scrolling away.
        private var userScrollDeadline = Date.distantPast
        private static let userScrollSettleInterval: TimeInterval = 0.5

        /// What `update` last built from — rebuilding rows is skipped when it's unchanged. Under the
        /// transcript's append-at-end, trim-at-front rule, count + first + last identify the array.
        private struct InputSignature: Equatable {
            let count: Int
            let firstID: UUID?
            let lastID: UUID?
            let options: TranscriptRows.Options
            let restorableHistoryCount: Int
        }

        func attach(scrollView: TranscriptScrollView, tableView: NSTableView) {
            self.scrollView = scrollView
            self.tableView = tableView
            tableView.dataSource = self
            tableView.delegate = self

            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            clipView.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(clipViewBoundsDidChange),
                               name: NSView.boundsDidChangeNotification, object: clipView)
            center.addObserver(self, selector: #selector(clipViewFrameDidChange),
                               name: NSView.frameDidChangeNotification, object: clipView)
            center.addObserver(self, selector: #selector(userDidScroll),
                               name: NSScrollView.didLiveScrollNotification, object: scrollView)
            center.addObserver(self, selector: #selector(userDidScroll),
                               name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            scrollView.onUserScrollWheel = { [weak self] in self?.userDidScrollWheel() }
        }

        // MARK: Updates from SwiftUI

        func update(messages: [ChannelMessage], options: TranscriptRows.Options,
                    restorableHistoryCount: Int, rowContext newContext: TranscriptRowContext) {
            let displayPrefsChanged = rowContext.map { $0.displayPrefs != newContext.displayPrefs } ?? false
            rowContext = newContext
            if displayPrefsChanged { refreshAllCachedHosts() }

            let input = InputSignature(
                count: messages.count, firstID: messages.first?.id, lastID: messages.last?.id,
                options: options, restorableHistoryCount: restorableHistoryCount
            )
            guard input != lastInput else { return }
            lastInput = input

            let rows = TranscriptRows.make(from: messages, options: options)
            let newKeys = rows.map(\.renderKey)
            var newDisplayRows: [TranscriptDisplayRow] = []
            newDisplayRows.reserveCapacity(rows.count + 1)
            if restorableHistoryCount > 0 { newDisplayRows.append(.restoreHistory(count: restorableHistoryCount)) }
            newDisplayRows.append(contentsOf: rows.map(TranscriptDisplayRow.message))

            let hadHeader = displayRows.first?.key == .restoreHistory
            let hasHeader = restorableHistoryCount > 0
            let edit = hadHeader == hasHeader
                ? TranscriptRows.edit(from: messageRowKeys, to: newKeys)
                : .reload
            apply(edit, displayRows: newDisplayRows, messageRowKeys: newKeys, hasHeader: hasHeader)
        }

        private func apply(_ edit: TranscriptRows.Edit, displayRows newDisplayRows: [TranscriptDisplayRow],
                           messageRowKeys newKeys: [TranscriptRow.RenderKey], hasHeader: Bool) {
            guard let tableView else { return }
            let headerOffset = hasHeader ? 1 : 0
            switch edit {
            case .none:
                commit(newDisplayRows, newKeys)
                // The header's count may have changed without its presence changing.
                if hasHeader { refreshCachedHost(for: newDisplayRows[0]) }
            case .reload:
                preservingReadingPosition {
                    commit(newDisplayRows, newKeys)
                    tableView.reloadData()
                    // Rows can keep their key but change what they show (a filter change).
                    refreshAllCachedHosts()
                }
                pruneCaches()
            case .incremental(let removedFromFront, let appended, let reloaded):
                let removedKeys = displayRows[headerOffset..<(headerOffset + removedFromFront)].map(\.key)
                preservingReadingPosition {
                    commit(newDisplayRows, newKeys)
                    tableView.beginUpdates()
                    if removedFromFront > 0 {
                        tableView.removeRows(
                            at: IndexSet(headerOffset..<(headerOffset + removedFromFront)), withAnimation: [])
                    }
                    if appended > 0 {
                        let start = headerOffset + newKeys.count - appended
                        tableView.insertRows(at: IndexSet(start..<(start + appended)), withAnimation: [])
                    }
                    tableView.endUpdates()
                    for index in reloaded {
                        refreshCachedHost(for: newDisplayRows[headerOffset + index])
                    }
                    if hasHeader { refreshCachedHost(for: newDisplayRows[0]) }
                }
                for key in removedKeys {
                    hosts.remove(key)
                    heightByKey[key] = nil
                }
            }
        }

        private func commit(_ newDisplayRows: [TranscriptDisplayRow], _ newKeys: [TranscriptRow.RenderKey]) {
            displayRows = newDisplayRows
            messageRowKeys = newKeys
            var index: [TranscriptDisplayRow.Key: Int] = [:]
            index.reserveCapacity(newDisplayRows.count)
            for (position, row) in newDisplayRows.enumerated() { index[row.key] = position }
            indexByKey = index
        }

        /// Drops cached views and heights for rows that no longer exist.
        private func pruneCaches() {
            hosts.removeAll { indexByKey[$0] == nil }
            heightByKey = heightByKey.filter { indexByKey[$0.key] != nil }
        }

        // MARK: Row views

        private func makeRoot(for row: TranscriptDisplayRow) -> TranscriptRowHostRoot? {
            guard let rowContext else { return nil }
            let key = row.key
            return TranscriptRowHostRoot(row: row, context: rowContext, onHeightChange: { [weak self] height in
                self?.rowReportedHeight(height, for: key)
            })
        }

        private func refreshCachedHost(for row: TranscriptDisplayRow) {
            guard let host = hosts.host(for: row.key), let root = makeRoot(for: row) else { return }
            host.rootView = root
        }

        private func refreshAllCachedHosts() {
            for key in hosts.keys {
                guard let index = indexByKey[key] else { continue }
                refreshCachedHost(for: displayRows[index])
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { displayRows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let displayRow = displayRows[row]
            if let host = hosts.host(for: displayRow.key) { return host }
            guard let root = makeRoot(for: displayRow) else { return nil }
            let host = NSHostingView(rootView: root)
            // The table sizes the row; the row only REPORTS its height. Intrinsic-size constraints
            // would fight the frame the table assigns.
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            hosts.insert(host, for: displayRow.key)
            return host
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let displayRow = displayRows[row]
            return heightByKey[displayRow.key] ?? Self.estimatedHeight(of: displayRow)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        /// A first guess for a row never shown, so the scroll bar is roughly right before the row
        /// measures itself. Bounded work: it stops counting lines past where a row would collapse.
        private static func estimatedHeight(of row: TranscriptDisplayRow) -> CGFloat {
            switch row {
            case .restoreHistory:
                return 32
            case .message(let transcriptRow):
                var lines = 1
                for byte in transcriptRow.message.content.utf8 where byte == UInt8(ascii: "\n") {
                    lines += 1
                    if lines >= 40 { break }
                }
                return 26 + 17 * CGFloat(lines)
            }
        }

        // MARK: Heights

        private func rowReportedHeight(_ height: CGFloat, for key: TranscriptDisplayRow.Key) {
            let rounded = max(1, height.rounded(.up))
            guard heightByKey[key] != rounded else { return }
            heightByKey[key] = rounded
            pendingHeightKeys.insert(key)
            guard !heightFlushScheduled else { return }
            heightFlushScheduled = true
            // Reported from inside SwiftUI's layout of the row; re-tiling the table there would
            // re-enter that layout. Coalesced: every row measured in one pass re-tiles once.
            DispatchQueue.main.async { [weak self] in self?.flushHeightChanges() }
        }

        private func flushHeightChanges() {
            heightFlushScheduled = false
            guard let tableView else { return }
            let indexes = IndexSet(pendingHeightKeys.compactMap { indexByKey[$0] })
            pendingHeightKeys.removeAll()
            guard !indexes.isEmpty else { return }
            preservingReadingPosition {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: indexes)
                NSAnimationContext.endGrouping()
            }
        }

        // MARK: Benchmark

        /// One benchmark in progress: from the bottom, scrolling up and down between the ends at a
        /// fixed speed — reversing at each end, so the run never sits still and dilutes the result.
        private final class BenchmarkRun {
            let link: CADisplayLink
            /// The bottom: the furthest the transcript can scroll.
            let maxY: CGFloat
            let completion: (TranscriptScrollBenchmarkOutcome) -> Void
            var startTimestamp: CFTimeInterval?
            var lastTimestamp: CFTimeInterval?
            /// The interval the display promised for the frame now being waited on.
            var expectedInterval: CFTimeInterval?
            var samples: [FrameTimingStats.Sample] = []

            init(link: CADisplayLink, maxY: CGFloat,
                 completion: @escaping (TranscriptScrollBenchmarkOutcome) -> Void) {
                self.link = link
                self.maxY = maxY
                self.completion = completion
            }
        }

        func runScrollBenchmark(completion: @escaping (TranscriptScrollBenchmarkOutcome) -> Void) {
            guard benchmark == nil, let scrollView else { return }
            scrollToBottom(animated: false)
            let maxY = scrollView.contentView.bounds.minY
            let viewportHeight = scrollView.contentView.bounds.height
            guard maxY >= viewportHeight * TranscriptScrollBenchmarkResult.minimumScrollableViewports else {
                completion(.tooShort(scrollableHeight: Double(maxY), viewportHeight: Double(viewportHeight)))
                return
            }
            isPinnedToBottom = false
            let link = scrollView.displayLink(target: self, selector: #selector(benchmarkTick(_:)))
            benchmark = BenchmarkRun(link: link, maxY: maxY, completion: completion)
            link.add(to: .main, forMode: .common)
        }

        @objc private func benchmarkTick(_ link: CADisplayLink) {
            guard let run = benchmark, let tableView else {
                link.invalidate()
                return
            }
            let start = run.startTimestamp ?? link.timestamp
            run.startTimestamp = start
            if let last = run.lastTimestamp, let expected = run.expectedInterval {
                run.samples.append(FrameTimingStats.Sample(interval: link.timestamp - last, refreshInterval: expected))
            }
            run.lastTimestamp = link.timestamp
            run.expectedInterval = link.targetTimestamp - link.timestamp

            // Distance travelled folded back and forth over [0, maxY]: up from the bottom, back
            // down from the top, and so on.
            let elapsed = link.timestamp - start
            let travelled = TranscriptScrollBenchmarkResult.speedPointsPerSecond * CGFloat(elapsed)
            let lap = travelled.truncatingRemainder(dividingBy: 2 * run.maxY)
            scroll(toY: lap <= run.maxY ? run.maxY - lap : lap - run.maxY)

            guard elapsed >= TranscriptScrollBenchmarkResult.durationSeconds else { return }
            link.invalidate()
            benchmark = nil
            let result = TranscriptScrollBenchmarkResult(
                date: Date(),
                rowCount: displayRows.count,
                documentHeight: Double(tableView.frame.height),
                stats: FrameTimingStats(samples: run.samples)
            )
            scrollToBottom(animated: false)
            run.completion(.completed(result))
        }

        // MARK: Scrolling

        /// Runs `mutation` without moving what the user is looking at: pinned to the bottom, it
        /// stays at the bottom; otherwise a visible row that survives the mutation keeps its
        /// distance from the top of the viewport. Rows inserted or resized ABOVE the viewport would
        /// otherwise push the reader's place down — the "can't stop scrolling" defect.
        ///
        /// The anchor is the first row whose TOP is on screen. A row the user expands has its top
        /// on screen, so it stays put and grows downward; a never-measured row scrolled in at the top
        /// has its top above the viewport, so it is passed over and grows upward, out of the way.
        /// Only when no row's top is visible (one row taller than the viewport) does a row with its
        /// top above the viewport anchor.
        ///
        /// The whole transaction counts as a programmatic scroll: `tile()` can clamp the viewport
        /// mid-way (the document shrank), and that bounds change must not read as the user scrolling.
        private func preservingReadingPosition(_ mutation: () -> Void) {
            guard let tableView, let scrollView else { mutation(); return }
            programmaticScrollDepth += 1
            defer { programmaticScrollDepth -= 1 }
            if isPinnedToBottom {
                mutation()
                tableView.tile()
                scrollToBottom(animated: false)
                return
            }
            let visible = scrollView.contentView.bounds
            let visibleRows = tableView.rows(in: visible)
            var topOnScreen: [(key: TranscriptDisplayRow.Key, offset: CGFloat)] = []
            var topAbove: [(key: TranscriptDisplayRow.Key, offset: CGFloat)] = []
            if visibleRows.location != NSNotFound {
                for row in visibleRows.location..<NSMaxRange(visibleRows) where row < displayRows.count {
                    let rowTop = tableView.rect(ofRow: row).minY
                    let anchor = (key: displayRows[row].key, offset: visible.minY - rowTop)
                    if rowTop >= visible.minY { topOnScreen.append(anchor) } else { topAbove.append(anchor) }
                }
            }
            mutation()
            tableView.tile()
            for anchor in topOnScreen + topAbove {
                guard let newIndex = indexByKey[anchor.key] else { continue }
                scroll(toY: tableView.rect(ofRow: newIndex).minY + anchor.offset)
                break
            }
            reportAtBottom()
        }

        private func scroll(toY y: CGFloat) {
            guard let scrollView, let tableView else { return }
            let clipView = scrollView.contentView
            let maxY = max(0, tableView.frame.height - clipView.bounds.height)
            programmaticScrollDepth += 1
            clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: min(max(0, y), maxY)))
            scrollView.reflectScrolledClipView(clipView)
            programmaticScrollDepth -= 1
        }

        func scrollToBottom(animated: Bool) {
            guard let scrollView, let tableView else { return }
            isPinnedToBottom = true
            let clipView = scrollView.contentView
            let bottomY = max(0, tableView.frame.height - clipView.bounds.height)
            if animated {
                programmaticScrollDepth += 1
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: bottomY))
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let scrollView = self.scrollView else { return }
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                        self.programmaticScrollDepth -= 1
                        self.reportAtBottom()
                    }
                })
            } else {
                scroll(toY: bottomY)
                reportAtBottom()
            }
        }

        private func isNearBottom() -> Bool {
            guard let scrollView, let tableView else { return true }
            let visible = scrollView.contentView.bounds
            return tableView.frame.height - visible.maxY <= visible.height * Self.bottomProximity
        }

        /// Tells SwiftUI only when the answer changes, and never from inside its update pass.
        private func reportAtBottom() {
            let atBottom = isNearBottom()
            guard atBottom != reportedAtBottom else { return }
            reportedAtBottom = atBottom
            let report = onAtBottomChange
            DispatchQueue.main.async { report?(atBottom) }
        }

        /// The user moved the transcript (wheel, trackpad, scroller). Only this decides whether
        /// to keep following the end: scrolled to the bottom follows, anywhere else stays put.
        @objc private func userDidScroll() {
            guard programmaticScrollDepth == 0 else { return }
            isPinnedToBottom = isNearBottom()
            reportAtBottom()
        }

        private func userDidScrollWheel() {
            userScrollDeadline = Date().addingTimeInterval(Self.userScrollSettleInterval)
            userDidScroll()
        }

        @objc private func clipViewBoundsDidChange() {
            if programmaticScrollDepth == 0, Date() < userScrollDeadline {
                isPinnedToBottom = isNearBottom()
            }
            reportAtBottom()
        }

        /// The pane was resized. A pinned transcript stays on its last line.
        @objc private func clipViewFrameDidChange() {
            if isPinnedToBottom { scrollToBottom(animated: false) } else { reportAtBottom() }
        }
    }
}

/// A row's SwiftUI root: the row content, reporting the height it needs at the width it is given.
struct TranscriptRowHostRoot: View {
    let row: TranscriptDisplayRow
    let context: TranscriptRowContext
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        TranscriptRowContent(row: row, context: context)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Its own height, whatever height the table currently gives the row — that is what
            // the table needs to learn. Top-aligned so a row drawn before its height is known
            // doesn't float in the middle of a too-tall cell.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { onHeightChange($0) })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// What SwiftUI hosts: a plain view holding the scroll view, so the transcript's internal churn
/// stays internal. Every row height change re-tiles the table, and the scroll view passes the
/// resulting invalidation up — which, reaching the window's SwiftUI host, re-laid-out the whole
/// window (the split view, the inspector) on every frame of a scroll. Measured 2026-10-14: about a
/// tenth of the main thread during a benchmark run.
final class TranscriptContainerView: NSView {
    init(scrollView: NSScrollView) {
        super.init(frame: .zero)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable, message: "Created in code only")
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Nothing inside can change this view's size; the window decides it.
    override func invalidateIntrinsicContentSize() {}
}

/// The transcript's scroll view: reports wheel and trackpad scrolling, which is the user's.
final class TranscriptScrollView: NSScrollView {
    var onUserScrollWheel: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScrollWheel?()
    }
}

/// Lets a click inside a row reach the row's own controls and selectable text. A table normally
/// claims those clicks to select the row — and this table never selects rows.
final class TranscriptNSTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

/// Row views kept alive by message, least-recently-used out first. Rows on screen are never
/// evicted — the table is still showing them.
private struct RowHostCache {
    let capacity: Int
    private var hosts: [TranscriptDisplayRow.Key: NSHostingView<TranscriptRowHostRoot>] = [:]
    private var lastUse: [TranscriptDisplayRow.Key: UInt64] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) { self.capacity = capacity }

    var keys: Dictionary<TranscriptDisplayRow.Key, NSHostingView<TranscriptRowHostRoot>>.Keys { hosts.keys }

    mutating func host(for key: TranscriptDisplayRow.Key) -> NSHostingView<TranscriptRowHostRoot>? {
        guard let host = hosts[key] else { return nil }
        clock += 1
        lastUse[key] = clock
        return host
    }

    mutating func insert(_ host: NSHostingView<TranscriptRowHostRoot>, for key: TranscriptDisplayRow.Key) {
        clock += 1
        hosts[key] = host
        lastUse[key] = clock
        // Evicts in batches, so the sort runs once per batch rather than per row.
        guard hosts.count > capacity + capacity / 8 else { return }
        let evictable = hosts.filter { $0.value.window == nil }
            .map(\.key)
            .sorted { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) }
        for key in evictable.prefix(hosts.count - capacity) { remove(key) }
    }

    mutating func remove(_ key: TranscriptDisplayRow.Key) {
        hosts[key] = nil
        lastUse[key] = nil
    }

    mutating func removeAll(where shouldRemove: (TranscriptDisplayRow.Key) -> Bool) {
        for key in hosts.keys where shouldRemove(key) { remove(key) }
    }
}
