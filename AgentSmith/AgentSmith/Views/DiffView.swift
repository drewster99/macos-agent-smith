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
        // Routed through the same scheduler as every other trigger, so there is exactly ONE
        // tracked task. `.task` used to call `updateDiffCache()` directly — untracked and
        // uncancellable by `scheduleDiffUpdate`, which was harmless only while generation held the
        // main actor and could not interleave. It cannot stay that way now that generation runs
        // off-actor: an untracked slow generate on old inputs would publish after a tracked fast
        // one on new inputs, and the stale diff would stick.
        .onAppear { scheduleDiffUpdate() }
        // ONE watcher over every input `updateDiffCache()` reads — including `defaultVisibleLines`,
        // which had none. Four separate watchers each compared their own input on every body pass
        // of the row, and `precomputedLines` is a `[DiffLine]?`, so that was a full array-of-structs
        // equality per pass to detect a change that, at both call sites, cannot happen: these are
        // seeded once per message identity and the message list is append-only.
        //
        // Previously each watcher also spawned its own unstructured, uncancelled Task. That was
        // four redundant generations, not the publish race it looked like — main-actor tasks run
        // FIFO, so the last enqueued was always the last to publish. The redundancy was real; the
        // race was not. It becomes real now that generation is off-actor, which is what
        // `scheduleDiffUpdate` and the second guard are for.
        .onChange(of: inputSignature) { _, _ in scheduleDiffUpdate() }
        .onDisappear {
            // A large diff shouldn't keep generating for a view nobody is looking at.
            diffTask?.cancel()
            diffTask = nil
        }
    }

    /// Every input the cache is built from. One value, one watcher — an input added to
    /// `updateDiffCache()` without being added here is a cache that goes stale silently.
    private struct InputSignature: Equatable {
        let oldContent: String
        let newContent: String
        let contextLines: Int
        let precomputedCount: Int?
        let defaultVisibleLines: Int
    }

    private var inputSignature: InputSignature {
        InputSignature(
            oldContent: oldContent,
            newContent: newContent,
            contextLines: contextLines,
            // Count, not the array: these are seeded once per message and never mutated in place,
            // so identity-by-count is sufficient and avoids an array-of-structs compare per pass.
            precomputedCount: precomputedLines?.count,
            defaultVisibleLines: defaultVisibleLines
        )
    }

    private func scheduleDiffUpdate() {
        diffTask?.cancel()
        diffTask = Task { await updateDiffCache() }
    }

    /// Generation runs OFF the main actor, and both cancellation guards are load-bearing.
    ///
    /// This target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so this function was
    /// main-actor isolated by default and `DiffGenerator.generate` — an O(m·n) LCS with a DP table
    /// of up to 1000×1000, so ~10⁶ string comparisons and megabytes of allocation — ran on the main
    /// thread, hitching the UI on every file-edit row with a large diff. The `await MainActor.run`
    /// below was a no-op hop back to the actor it never left.
    @Sendable private func updateDiffCache() async {
        // BEFORE the generate: a burst of input changes costs one diff, not four. Superseded tasks
        // reach here already cancelled and return without doing any work.
        guard !Task.isCancelled else { return }
        let allLines: [DiffLine]
        if let precomputedLines {
            allLines = precomputedLines
        } else {
            let (old, new, context) = (oldContent, newContent, contextLines)
            // `@concurrent` (not `Task.detached`) so the generate hops off-main AND stays part of
            // THIS task: a superseded/dismissed diff's cancellation then reaches DiffGenerator's
            // per-row `Task.isCancelled` and stops the O(m·n) work. A detached task is a fresh root
            // that never sees `diffTask.cancel()`, so its cancellation check was unreachable.
            allLines = await Self.generateDiffOffMain(old: old, new: new, contextLines: context)
        }
        let added = allLines.reduce(into: 0) { $0 += ($1.kind == .added ? 1 : 0) }
        let removed = allLines.reduce(into: 0) { $0 += ($1.kind == .removed ? 1 : 0) }
        let needsTrunc = allLines.count > defaultVisibleLines

        // AFTER it: now genuinely load-bearing. Generation is a real suspension point, so a task
        // superseded WHILE generating resumes here and must not publish a diff built from inputs
        // that have since changed. While generation held the main actor this guard could not
        // differ from the one above — it was dead code that read like a race fix.
        guard !Task.isCancelled else { return }
        // Assigned directly: this function is main-actor isolated (target default), and the
        // detached generate above already hopped back on resume. The `await MainActor.run` that
        // used to wrap this was a no-op that read like a hop to the main thread — the single most
        // misleading line in the file, since it implied the generate above it had been off-main.
        cachedAllLines = allLines
        cachedAddedCount = added
        cachedRemovedCount = removed
        cachedNeedsTruncation = needsTrunc
    }

    /// Runs the LCS off the main actor while remaining a structured child of the caller's task, so
    /// cancellation propagates into `DiffGenerator.generate`'s per-row check. `@concurrent` is what
    /// moves it off-main in this `MainActor`-by-default target.
    @concurrent nonisolated private static func generateDiffOffMain(old: String, new: String, contextLines: Int) async -> [DiffLine] {
        DiffGenerator.generate(old: old, new: new, contextLines: contextLines)
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
