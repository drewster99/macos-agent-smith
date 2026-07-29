import SwiftUI
import AgentSmithKit

/// Inline diff view for tool_request rows. Collapsed by default when the diff
/// exceeds `defaultVisibleLines` rows.
///
/// Two construction modes:
/// - `DiffView(lines:)` — use a precomputed `[DiffLine]` array, e.g. the one
///   `AgentActor` stored in `fileWriteDiff` metadata at post time. This avoids
///   re-running LCS in the view layer and doesn't require the raw old/new
///   file contents to be stored in the channel log.
/// - `DiffView(oldContent:newContent:)` — compute the diff on the fly. Used for
///   `file_edit` where `old_string` and `new_string` live in the tool args and
///   are already small enough to hold inline.
struct DiffView: View {
    private let precomputedLines: [DiffLine]?
    let oldContent: String
    let newContent: String
    var contextLines: Int = 2
    var defaultVisibleLines: Int = 6

    @State private var isExpanded = false
    /// The single in-flight diff generation. Replacing it cancels the previous one; see
    /// `scheduleDiffUpdate`.
    @State private var diffTask: Task<Void, Never>?
    @State private var cachedAllLines: [DiffLine] = []
    @State private var cachedAddedCount: Int = 0
    @State private var cachedRemovedCount: Int = 0
    @State private var cachedNeedsTruncation: Bool = false

    init(oldContent: String, newContent: String, contextLines: Int = 2, defaultVisibleLines: Int = 6) {
        self.precomputedLines = nil
        self.oldContent = oldContent
        self.newContent = newContent
        self.contextLines = contextLines
        self.defaultVisibleLines = defaultVisibleLines
    }

    init(lines: [DiffLine], defaultVisibleLines: Int = 6) {
        self.precomputedLines = lines
        self.oldContent = ""
        self.newContent = ""
        self.contextLines = 2
        self.defaultVisibleLines = defaultVisibleLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if cachedAllLines.isEmpty {
                EmptyView()
            } else if cachedAllLines.count == 1, cachedAllLines[0].kind == .tooLarge {
                // Oversized diff — show a compact summary line instead.
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(AppFonts.bannerIconSmall)
                        .foregroundStyle(.secondary)
                    Text(cachedAllLines[0].text)
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 12)
                .padding(.top, 2)
            } else {
                Button(action: {
                    if cachedNeedsTruncation { isExpanded.toggle() }
                }, label: {
                    HStack(spacing: 6) {
                        Text("\(Text("+\(cachedAddedCount)").foregroundStyle(AppColors.diffAddedForeground))  \(Text("-\(cachedRemovedCount)").foregroundStyle(AppColors.diffRemovedForeground))")
                            .font(AppFonts.channelTimestamp.monospacedDigit())
                        if cachedNeedsTruncation {
                            Text(isExpanded ? "(show less)" : "(show more)")
                                .font(.caption)
                                .foregroundStyle(AppColors.disclosureToggle)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                .disabled(!cachedNeedsTruncation)

                VStack(alignment: .leading, spacing: 0) {
                    let visibleLines = (isExpanded || !cachedNeedsTruncation)
                        ? cachedAllLines
                        : Array(cachedAllLines.prefix(defaultVisibleLines))
                    ForEach(visibleLines) { line in
                        DiffLineView(line: line)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .padding(.leading, 12)
        .padding(.top, 2)
        .task {
            await updateDiffCache()
        }
        // Every one of these used to spawn its OWN unstructured, uncancelled Task. `oldContent` and
        // `newContent` change together whenever a diff is presented, so two full generations of the
        // same diff racing to assign was the normal case — and the winner was whichever finished
        // last, which is not necessarily the one built from the newest inputs.
        //
        // One task at a time, cancelled and replaced. Cancellation alone would fix only the race
        // (it is cooperative, so it stops no work), but task bodies are ENQUEUED rather than run
        // inline: all four handlers finish before the first body starts, so the superseded tasks
        // hit `updateDiffCache`'s opening cancellation guard and return before generating anything.
        .onChange(of: oldContent) { _, _ in scheduleDiffUpdate() }
        .onChange(of: newContent) { _, _ in scheduleDiffUpdate() }
        .onChange(of: contextLines) { _, _ in scheduleDiffUpdate() }
        .onChange(of: precomputedLines) { _, _ in scheduleDiffUpdate() }
        .onDisappear {
            // A large diff shouldn't keep generating for a view nobody is looking at.
            diffTask?.cancel()
            diffTask = nil
        }
    }

    private func scheduleDiffUpdate() {
        diffTask?.cancel()
        diffTask = Task { await updateDiffCache() }
    }

    /// Two cancellation guards, doing two different jobs — both are load-bearing.
    @Sendable private func updateDiffCache() async {
        // BEFORE the generate: this is what makes a burst of input changes cost one diff instead of
        // four. Superseded tasks reach here already cancelled and return without doing the work.
        guard !Task.isCancelled else { return }
        let allLines: [DiffLine] = precomputedLines
            ?? DiffGenerator.generate(old: oldContent, new: newContent, contextLines: contextLines)
        let added = allLines.reduce(into: 0) { $0 += ($1.kind == .added ? 1 : 0) }
        let removed = allLines.reduce(into: 0) { $0 += ($1.kind == .removed ? 1 : 0) }
        let needsTrunc = allLines.count > defaultVisibleLines

        // AFTER it: this is what kills the race. A task that got past the first guard before being
        // superseded must not publish a diff built from inputs that have since changed.
        guard !Task.isCancelled else { return }
        await MainActor.run {
            cachedAllLines = allLines
            cachedAddedCount = added
            cachedRemovedCount = removed
            cachedNeedsTruncation = needsTrunc
        }
    }

    /// Nested View struct for diff line display (refactored from diffLineView(_:))
    private struct DiffLineView: View {
        let line: DiffLine
        
        var body: some View {
            switch line.kind {
        case .context:
            HStack(spacing: 0) {
                Text("  ")
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(.secondary)
                Text(line.text)
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        case .removed:
            HStack(spacing: 0) {
                Text("- ")
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(AppColors.diffRemovedForeground)
                Text(line.text)
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(AppColors.diffRemovedForeground)
                Spacer(minLength: 0)
            }
            .background(AppColors.diffRemovedBackground)
        case .added:
            HStack(spacing: 0) {
                Text("+ ")
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(AppColors.diffAddedForeground)
                Text(line.text)
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(AppColors.diffAddedForeground)
                Spacer(minLength: 0)
            }
            .background(AppColors.diffAddedBackground)
        case .separator:
            Text(line.text)
                .font(AppFonts.channelBody.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.vertical, 1)
        case .tooLarge:
            // Rendered separately in the main body; never reached here.
            EmptyView()
        }
    }
    }
}
