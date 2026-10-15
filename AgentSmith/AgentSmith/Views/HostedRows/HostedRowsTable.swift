import AppKit
import SwiftUI
import AgentSmithKit

/// A row a `HostedRowsTable` can show.
nonisolated protocol HostedTableRow {
    associatedtype ID: Hashable, Sendable
    associatedtype RenderKey: Equatable, Sendable
    /// Identity: a row keeps its view — and that view's state, such as expanded — while this stays.
    var id: ID { get }
    /// What the row is drawn from. A change redraws the row in place.
    var renderKey: RenderKey { get }
    /// A first guess at the row's height, used until the row has been shown and measured, so the
    /// scroll bar is roughly right. Keep it cheap: it is asked for every row on a reload.
    var estimatedHeight: CGFloat { get }
}

/// Lets SwiftUI move a `HostedRowsTable`'s scroll position, which lives in AppKit.
final class HostedRowsTableController {
    fileprivate weak var engine: HostedRowsTableEngine?

    func scrollToBottom(animated: Bool) {
        engine?.scrollToBottom(animated: animated)
    }

    /// Scrolls at a fixed speed and reports how smoothly the table drew. Debug tooling.
    func runScrollBenchmark(completion: @escaping (TranscriptScrollBenchmarkOutcome) -> Void) {
        engine?.runScrollBenchmark(completion: completion)
    }
}

/// A long list of SwiftUI rows in an `NSTableView` — the app's ONE way to show a list that can grow
/// without bound (the transcript, the inspector's context lists).
///
/// Why AppKit: a table keeps views only for the rows on screen and remembers every row's height,
/// so scrolling and appending cost the same at 5,000 rows as at 50. SwiftUI's non-lazy stacks lay
/// out every row they hold on every change, and its lazy stacks mis-size variable-height rows on
/// macOS (project rule). See `docs/plans/TranscriptScrollPerformance.md`.
///
/// Each row is a SwiftUI view in an `NSHostingView`. It reports its own height whenever it changes —
/// first layout, expand/collapse, a resize — and the table re-tiles around it, keeping whatever the
/// user is reading in place. Row views are kept per row identity (least-recently-used out), so a row
/// scrolled away and back keeps its state.
struct HostedRowsTable<Row: HostedTableRow, RowContent: View>: NSViewRepresentable {
    /// Rows above `rows` that are not part of its edits — e.g. a "restore history" affordance. A
    /// leading row whose content changes is redrawn in place; adding or removing one reloads the
    /// table, so keep them few.
    var leadingRows: [Row] = []
    let rows: [Row]
    /// Keep the end in view as rows are added, until the user scrolls away from it.
    var followsTail = false
    /// When this changes, every row view is redrawn — for inputs `rowContent` captures that are not
    /// in any row's render key (display preferences).
    var contentRevision: AnyHashable = 0
    /// When this changes, every row view is thrown away and rebuilt — resetting all row state.
    var identityRevision: AnyHashable = 0
    /// When this changes, the table scrolls to its first row once the new rows are in — for a list
    /// swapped for a different one (new search results), where the old position would land the
    /// reader somewhere arbitrary. Recorded, not acted on, when the table first appears: it starts
    /// at the top anyway.
    var scrollResetRevision: AnyHashable = 0
    /// Space around each row's content.
    var rowInsets = EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
    var controller: HostedRowsTableController?
    /// Whether the viewport is at the end — reported only when it changes.
    var onAtBottomChange: ((Bool) -> Void)?
    /// The total height of the rows — reported when it changes, for a table sized to its content
    /// (up to a cap) rather than to a fixed box.
    var onContentHeightChange: ((CGFloat) -> Void)?
    @ViewBuilder let rowContent: (Row) -> RowContent

    func makeCoordinator() -> HostedRowsTableCoordinator<Row, RowContent> { HostedRowsTableCoordinator() }

    func makeNSView(context: Context) -> HostedRowsContainerView {
        let scrollView = HostedRowsScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false

        let tableView = HostedRowsNSTableView()
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
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rows"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        context.coordinator.attach(scrollView: scrollView, tableView: tableView)
        return HostedRowsContainerView(scrollView: scrollView)
    }

    /// The table fills whatever it is offered, exactly as `Color` does: an infinite proposal is
    /// taken whole (so a stack ranks it flexible), and an unspecified one gets SwiftUI's
    /// placeholder size. It never asks SwiftUI for a size of its own; callers that need a
    /// particular size frame it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HostedRowsContainerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ container: HostedRowsContainerView, context: Context) {
        let coordinator = context.coordinator
        controller?.engine = coordinator
        coordinator.onAtBottomChange = onAtBottomChange
        coordinator.onContentHeightChange = onContentHeightChange
        coordinator.update(
            leadingRows: leadingRows, rows: rows, followsTail: followsTail,
            contentRevision: contentRevision, identityRevision: identityRevision,
            scrollResetRevision: scrollResetRevision,
            makeContent: { row, onHeightChange in
                HostedRowRoot(content: rowContent(row), insets: rowInsets, onHeightChange: onHeightChange)
            }
        )
    }
}

/// What a `HostedRowsTableController` drives, independent of the row type.
@MainActor
protocol HostedRowsTableEngine: AnyObject {
    func scrollToBottom(animated: Bool)
    func runScrollBenchmark(completion: @escaping (TranscriptScrollBenchmarkOutcome) -> Void)
}

/// The table's data source and delegate: row bookkeeping, heights, scroll position.
final class HostedRowsTableCoordinator<Row: HostedTableRow, RowContent: View>: NSObject,
    NSTableViewDataSource, NSTableViewDelegate, HostedRowsTableEngine {
    typealias Root = HostedRowRoot<RowContent>

    /// How close to the end still counts as "at the bottom", as a fraction of the viewport, so
    /// tail-following survives the small drift a row's late height change leaves behind.
    private static var bottomProximity: CGFloat { 0.2 }
    /// Row views kept alive off screen. Rows on screen are never evicted.
    private static var hostCacheCapacity: Int { 400 }

    var onAtBottomChange: ((Bool) -> Void)?
    var onContentHeightChange: ((CGFloat) -> Void)?

    private weak var scrollView: HostedRowsScrollView?
    private weak var tableView: NSTableView?

    private var leadingRows: [Row] = []
    private var bodyRows: [Row] = []
    private var indexByID: [Row.ID: Int] = [:]
    private var makeContent: ((Row, @escaping (CGFloat) -> Void) -> Root)?
    private var followsTail = false
    private var contentRevision: AnyHashable?
    private var identityRevision: AnyHashable?
    private var scrollResetRevision: AnyHashable?

    /// Measured heights, reported by the rows themselves. A row not yet shown is estimated.
    private var heightByID: [Row.ID: CGFloat] = [:]
    private var hosts = RowHostCache<Row.ID, Root>(capacity: hostCacheCapacity)
    private var pendingHeightIDs: Set<Row.ID> = []
    private var heightFlushScheduled = false

    /// Follow the end as rows are added. Changed only by the USER scrolling (and the jump-to-latest
    /// button) — never by content growth or a row changing height.
    private var isPinnedToBottom = false
    private var reportedAtBottom: Bool?
    private var reportedContentHeight: CGFloat?
    private var benchmark: BenchmarkRun?

    /// Non-zero while this coordinator moves the scroll position itself.
    private var programmaticScrollDepth = 0
    /// Until when bounds changes count as the user's. A smooth-scrolling wheel moves the view over
    /// the frames AFTER its event, so the position right after `scrollWheel` can still read "at the
    /// bottom" — judging only then would miss the user scrolling away.
    private var userScrollDeadline = Date.distantPast
    private static var userScrollSettleInterval: TimeInterval { 0.5 }

    private var allRowCount: Int { leadingRows.count + bodyRows.count }

    private func row(at index: Int) -> Row {
        index < leadingRows.count ? leadingRows[index] : bodyRows[index - leadingRows.count]
    }

    func attach(scrollView: HostedRowsScrollView, tableView: NSTableView) {
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

    func update(leadingRows newLeading: [Row], rows newRows: [Row], followsTail newFollowsTail: Bool,
                contentRevision newContentRevision: AnyHashable, identityRevision newIdentityRevision: AnyHashable,
                scrollResetRevision newScrollResetRevision: AnyHashable,
                makeContent newMakeContent: @escaping (Row, @escaping (CGFloat) -> Void) -> Root) {
        makeContent = newMakeContent
        let isFirstUpdate = identityRevision == nil
        if isFirstUpdate { isPinnedToBottom = newFollowsTail }
        followsTail = newFollowsTail

        if let identityRevision, identityRevision != newIdentityRevision {
            hosts.removeAll { _ in true }
            heightByID.removeAll()
        }
        let identityChanged = identityRevision != newIdentityRevision
        identityRevision = newIdentityRevision

        let contentChanged = contentRevision != nil && contentRevision != newContentRevision
        contentRevision = newContentRevision

        let scrollResetRequested = scrollResetRevision != nil && scrollResetRevision != newScrollResetRevision
        scrollResetRevision = newScrollResetRevision

        // Leading rows that are the same rows with new content (a history count that grows with
        // every message) are redrawn in place; only a change in WHICH leading rows exist reloads.
        let leadingIDsChanged = newLeading.map(\.id) != leadingRows.map(\.id)
        let redrawnLeading = leadingIDsChanged ? [] : zip(leadingRows, newLeading)
            .filter { $0.renderKey != $1.renderKey }
            .map(\.1)
        let edit: RowListEdit = (leadingIDsChanged || identityChanged)
            ? .reload
            : plan(from: bodyRows, to: newRows)
        apply(edit, leading: newLeading, rows: newRows)
        if edit != .reload {
            if contentChanged {
                refreshAllCachedHosts()
            } else {
                for row in redrawnLeading { refreshCachedHost(for: row) }
            }
        }
        if scrollResetRequested { scrollToTop() }
    }

    /// The edit between two row lists, by row identity.
    private func plan(from old: [Row], to new: [Row]) -> RowListEdit {
        let oldPairs = old.map { IdentifiedKey(id: $0.id, render: $0.renderKey) }
        let newPairs = new.map { IdentifiedKey(id: $0.id, render: $0.renderKey) }
        return RowListEdit.plan(from: oldPairs, to: newPairs, identity: \.id)
    }

    private struct IdentifiedKey: Equatable {
        let id: Row.ID
        let render: Row.RenderKey
    }

    private func apply(_ edit: RowListEdit, leading newLeading: [Row], rows newRows: [Row]) {
        guard let tableView else { return }
        let headerOffset = newLeading.count
        switch edit {
        case .none:
            commit(newLeading, newRows)
        case .reload:
            preservingReadingPosition {
                commit(newLeading, newRows)
                tableView.reloadData()
                // Rows can keep their identity but change what they show (a filter change).
                refreshAllCachedHosts()
            }
            pruneCaches()
        case .incremental(let removedFromFront, let insertedAtFront, let appended, let reloaded):
            let removedIDs = bodyRows.prefix(removedFromFront).map(\.id)
            // A reader at the very top of a list that grows at the top (newest first) is reading the
            // newest rows, so they see the arriving ones — rather than having the old first row held
            // in place and the new rows slipped in above, out of sight.
            let staysAtTop = insertedAtFront > 0 && !isPinnedToBottom && isAtTop()
            preservingReadingPosition {
                commit(newLeading, newRows)
                tableView.beginUpdates()
                if removedFromFront > 0 {
                    tableView.removeRows(
                        at: IndexSet(headerOffset..<(headerOffset + removedFromFront)), withAnimation: [])
                }
                if insertedAtFront > 0 {
                    tableView.insertRows(
                        at: IndexSet(headerOffset..<(headerOffset + insertedAtFront)), withAnimation: [])
                }
                if appended > 0 {
                    let start = headerOffset + newRows.count - appended
                    tableView.insertRows(at: IndexSet(start..<(start + appended)), withAnimation: [])
                }
                tableView.endUpdates()
                for index in reloaded { refreshCachedHost(for: newRows[index]) }
            }
            for id in removedIDs {
                hosts.remove(id)
                heightByID[id] = nil
            }
            if staysAtTop { scrollToTop() }
        }
    }

    private func commit(_ newLeading: [Row], _ newRows: [Row]) {
        leadingRows = newLeading
        bodyRows = newRows
        var index: [Row.ID: Int] = [:]
        index.reserveCapacity(allRowCount)
        for (position, row) in newLeading.enumerated() { index[row.id] = position }
        for (position, row) in newRows.enumerated() { index[row.id] = newLeading.count + position }
        indexByID = index
    }

    /// Drops cached views and heights for rows that no longer exist.
    private func pruneCaches() {
        hosts.removeAll { indexByID[$0] == nil }
        heightByID = heightByID.filter { indexByID[$0.key] != nil }
    }

    // MARK: Row views

    private func makeRoot(for row: Row) -> Root? {
        guard let makeContent else { return nil }
        let id = row.id
        return makeContent(row) { [weak self] height in self?.rowReportedHeight(height, for: id) }
    }

    private func refreshCachedHost(for row: Row) {
        guard let host = hosts.host(for: row.id), let root = makeRoot(for: row) else { return }
        host.rootView = root
    }

    private func refreshAllCachedHosts() {
        for id in hosts.keys {
            guard let index = indexByID[id] else { continue }
            refreshCachedHost(for: row(at: index))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { allRowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let row = row(at: index)
        if let host = hosts.host(for: row.id) { return host }
        guard let root = makeRoot(for: row) else { return nil }
        let host = NSHostingView(rootView: root)
        // The table sizes the row; the row only REPORTS its height. Intrinsic-size constraints
        // would fight the frame the table assigns.
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        hosts.insert(host, for: row.id)
        return host
    }

    func tableView(_ tableView: NSTableView, heightOfRow index: Int) -> CGFloat {
        let row = row(at: index)
        return heightByID[row.id] ?? row.estimatedHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: Heights

    private func rowReportedHeight(_ height: CGFloat, for id: Row.ID) {
        let rounded = max(1, height.rounded(.up))
        guard heightByID[id] != rounded else { return }
        heightByID[id] = rounded
        pendingHeightIDs.insert(id)
        guard !heightFlushScheduled else { return }
        heightFlushScheduled = true
        // Reported from inside SwiftUI's layout of the row; re-tiling the table there would
        // re-enter that layout. Coalesced: every row measured in one pass re-tiles once.
        DispatchQueue.main.async { [weak self] in self?.flushHeightChanges() }
    }

    private func flushHeightChanges() {
        heightFlushScheduled = false
        guard let tableView else { return }
        let indexes = IndexSet(pendingHeightIDs.compactMap { indexByID[$0] })
        pendingHeightIDs.removeAll()
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
        /// The bottom: the furthest the table can scroll.
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

        // Distance travelled folded back and forth over [0, maxY]: up from the bottom, back down
        // from the top, and so on.
        let elapsed = link.timestamp - start
        let travelled = TranscriptScrollBenchmarkResult.speedPointsPerSecond * CGFloat(elapsed)
        let lap = travelled.truncatingRemainder(dividingBy: 2 * run.maxY)
        scroll(toY: lap <= run.maxY ? run.maxY - lap : lap - run.maxY)

        guard elapsed >= TranscriptScrollBenchmarkResult.durationSeconds else { return }
        link.invalidate()
        benchmark = nil
        let result = TranscriptScrollBenchmarkResult(
            date: Date(),
            rowCount: allRowCount,
            documentHeight: Double(tableView.frame.height),
            stats: FrameTimingStats(samples: run.samples)
        )
        scrollToBottom(animated: false)
        run.completion(.completed(result))
    }

    // MARK: Scrolling

    /// Runs `mutation` without moving what the user is looking at: pinned to the bottom, it stays at
    /// the bottom; otherwise a visible row that survives the mutation keeps its distance from the
    /// top of the viewport. Rows inserted or resized ABOVE the viewport would otherwise push the
    /// reader's place down — the "can't stop scrolling" defect.
    ///
    /// The anchor is the first row whose TOP is on screen. A row the user expands has its top on
    /// screen, so it stays put and grows downward; a never-measured row scrolled in at the top has
    /// its top above the viewport, so it is passed over and grows upward, out of the way. Only when
    /// no row's top is visible (one row taller than the viewport) does a row with its top above the
    /// viewport anchor.
    ///
    /// The whole transaction counts as a programmatic scroll: `tile()` can clamp the viewport
    /// mid-way (the document shrank), and that bounds change must not read as the user scrolling.
    private func preservingReadingPosition(_ mutation: () -> Void) {
        guard let tableView, let scrollView else { mutation(); return }
        programmaticScrollDepth += 1
        defer { programmaticScrollDepth -= 1 }
        defer { reportContentHeight() }
        if isPinnedToBottom {
            mutation()
            tableView.tile()
            scrollToBottom(animated: false)
            return
        }
        let visible = scrollView.contentView.bounds
        let visibleRows = tableView.rows(in: visible)
        var topOnScreen: [(id: Row.ID, offset: CGFloat)] = []
        var topAbove: [(id: Row.ID, offset: CGFloat)] = []
        if visibleRows.location != NSNotFound {
            for index in visibleRows.location..<NSMaxRange(visibleRows) where index < allRowCount {
                let rowTop = tableView.rect(ofRow: index).minY
                let anchor = (id: row(at: index).id, offset: visible.minY - rowTop)
                if rowTop >= visible.minY { topOnScreen.append(anchor) } else { topAbove.append(anchor) }
            }
        }
        mutation()
        tableView.tile()
        for anchor in topOnScreen + topAbove {
            guard let newIndex = indexByID[anchor.id] else { continue }
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
        isPinnedToBottom = followsTail
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

    /// Back to the first row, no longer following the end.
    private func scrollToTop() {
        isPinnedToBottom = false
        scroll(toY: 0)
        reportAtBottom()
    }

    private func isAtTop() -> Bool {
        guard let scrollView else { return true }
        return scrollView.contentView.bounds.minY <= 0
    }

    private func isNearBottom() -> Bool {
        guard let scrollView, let tableView else { return true }
        let visible = scrollView.contentView.bounds
        return tableView.frame.height - visible.maxY <= visible.height * Self.bottomProximity
    }

    /// The rows' total height — not the table's frame, which is never shorter than the viewport.
    /// Told to SwiftUI only when it changes, and never from inside its update pass.
    private func reportContentHeight() {
        guard let report = onContentHeightChange, let tableView else { return }
        let height = allRowCount > 0 ? tableView.rect(ofRow: allRowCount - 1).maxY : 0
        guard height != reportedContentHeight else { return }
        reportedContentHeight = height
        DispatchQueue.main.async { report(height) }
    }

    /// Tells SwiftUI only when the answer changes, and never from inside its update pass.
    private func reportAtBottom() {
        guard let report = onAtBottomChange else { return }
        let atBottom = isNearBottom()
        guard atBottom != reportedAtBottom else { return }
        reportedAtBottom = atBottom
        DispatchQueue.main.async { report(atBottom) }
    }

    /// The user moved the table (wheel, trackpad, scroller). Only this decides whether to keep
    /// following the end: scrolled to the bottom follows, anywhere else stays put.
    @objc private func userDidScroll() {
        guard programmaticScrollDepth == 0 else { return }
        isPinnedToBottom = followsTail && isNearBottom()
        reportAtBottom()
    }

    private func userDidScrollWheel() {
        userScrollDeadline = Date().addingTimeInterval(Self.userScrollSettleInterval)
        userDidScroll()
    }

    @objc private func clipViewBoundsDidChange() {
        if programmaticScrollDepth == 0, Date() < userScrollDeadline {
            isPinnedToBottom = followsTail && isNearBottom()
        }
        reportAtBottom()
    }

    /// The table was resized. A pinned table stays on its last line.
    @objc private func clipViewFrameDidChange() {
        if isPinnedToBottom { scrollToBottom(animated: false) } else { reportAtBottom() }
    }
}

/// A row's SwiftUI root: the row content, reporting the height it needs at the width it is given.
struct HostedRowRoot<Content: View>: View {
    let content: Content
    let insets: EdgeInsets
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        content
            .padding(insets)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Its own height, whatever height the table currently gives the row — that is what the
            // table needs to learn. Top-aligned so a row drawn before its height is known doesn't
            // float in the middle of a too-tall cell.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { onHeightChange($0) })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// What SwiftUI hosts: a plain view holding the scroll view, so the table's internal churn stays
/// internal. Every row height change re-tiles the table, and the scroll view passes the resulting
/// invalidation up — which, reaching the window's SwiftUI host, re-laid-out the whole window (the
/// split view, the inspector) on every frame of a scroll. Measured 2026-10-14: about a tenth of the
/// main thread during a transcript benchmark run.
final class HostedRowsContainerView: NSView {
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

    /// Nothing inside can change this view's size; its container decides it.
    override func invalidateIntrinsicContentSize() {}
}

/// The table's scroll view: reports wheel and trackpad scrolling, which is the user's.
final class HostedRowsScrollView: NSScrollView {
    var onUserScrollWheel: (() -> Void)?

    /// A scroll view with nothing to scroll still swallows the wheel, so a table nested in another
    /// scrolling view (a call's outgoing messages, sized to its rows, inside the inspector) would
    /// stop the inspector scrolling under the pointer. With all rows showing, the wheel belongs to
    /// whatever scrolls around the table. (The table's frame is never shorter than the viewport,
    /// so "no taller than the viewport" is "every row fits".)
    override func scrollWheel(with event: NSEvent) {
        let documentHeight = documentView?.frame.height ?? 0
        guard documentHeight > contentView.bounds.height else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
        onUserScrollWheel?()
    }
}

/// Lets a click inside a row reach the row's own controls and selectable text. A table normally
/// claims those clicks to select the row — and this table never selects rows.
final class HostedRowsNSTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

/// Row views kept alive by row identity, least-recently-used out first. Rows on screen are never
/// evicted — the table is still showing them.
private struct RowHostCache<Key: Hashable, Root: View> {
    let capacity: Int
    private var hosts: [Key: NSHostingView<Root>] = [:]
    private var lastUse: [Key: UInt64] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) { self.capacity = capacity }

    var keys: Dictionary<Key, NSHostingView<Root>>.Keys { hosts.keys }

    mutating func host(for key: Key) -> NSHostingView<Root>? {
        guard let host = hosts[key] else { return nil }
        clock += 1
        lastUse[key] = clock
        return host
    }

    mutating func insert(_ host: NSHostingView<Root>, for key: Key) {
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

    mutating func remove(_ key: Key) {
        hosts[key] = nil
        lastUse[key] = nil
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in hosts.keys where shouldRemove(key) { remove(key) }
    }
}
