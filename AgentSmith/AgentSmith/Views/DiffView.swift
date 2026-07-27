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
        // Compute the diff exactly once per body render. Both counts and the
        // visible line slice are derived from `allLines` locally. When the
        // diff was precomputed upstream (e.g. by AgentActor for file_write),
        // we use it directly instead of re-running LCS.
        let allLines: [DiffLine] = precomputedLines
            ?? DiffGenerator.generate(
                old: oldContent,
                new: newContent,
                contextLines: contextLines
            )
        if allLines.isEmpty {
            EmptyView()
        } else if allLines.count == 1, allLines[0].kind == .tooLarge {
            // Oversized diff — show a compact summary line instead.
            HStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(AppFonts.bannerIconSmall)
                    .foregroundStyle(.secondary)
                Text(allLines[0].text)
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 12)
            .padding(.top, 2)
        } else {
            let addedCount = allLines.reduce(into: 0) { $0 += ($1.kind == .added ? 1 : 0) }
            let removedCount = allLines.reduce(into: 0) { $0 += ($1.kind == .removed ? 1 : 0) }
            let needsTruncation = allLines.count > defaultVisibleLines
            let visibleLines = (isExpanded || !needsTruncation)
                ? allLines
                : Array(allLines.prefix(defaultVisibleLines))

            VStack(alignment: .leading, spacing: 0) {
                Button(action: {
                    if needsTruncation { isExpanded.toggle() }
                }, label: {
                    HStack(spacing: 6) {
                        Text("\(Text("+\(addedCount)").foregroundStyle(AppColors.diffAddedForeground))  \(Text("-\(removedCount)").foregroundStyle(AppColors.diffRemovedForeground))")
                            .font(AppFonts.channelTimestamp.monospacedDigit())
                        if needsTruncation {
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
                .disabled(!needsTruncation)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleLines) { line in
                        DiffLineView(line: line)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(.leading, 12)
            .padding(.top, 2)
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
