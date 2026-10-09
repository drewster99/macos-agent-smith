import Testing
import Foundation

/// Accessibility baseline for the app target (#19): a `Button` whose label is only an image has
/// nothing for VoiceOver to read except a symbol name, so it must carry `.accessibilityLabel`.
///
/// Absolute, not a ratchet: every icon-only button had a label when this was added.
@Suite("Accessibility guards (app target)")
struct AccessibilityGuardTests {

    /// One icon-only button found in the source.
    struct IconButton: CustomStringConvertible {
        let path: String
        let line: Int
        let hasAccessibilityLabel: Bool
        var description: String { "\(path):\(line)" }
    }

    /// Every `Button(…)` whose label (a `label:` argument or, for an untitled button, the trailing
    /// closure) holds an `Image` and no `Text` or `Label`. A titled button (`Button("Title"…)`,
    /// including `systemImage:` forms) carries its own label, and its trailing closure is the
    /// action. The modifier chain is the run of lines after the button that start with `.`.
    ///
    /// Not covered, by design of a baseline: `Menu` labels, a label that is a custom view
    /// (`label: { SomeIconView() }`), and the `Button { } label: { }` form the style rules forbid.
    static func iconButtons(in source: String, path: String) -> [IconButton] {
        let scanned = Array(CodeStyleGuardTests.blankingCommentsAndStringContents(source))
        var found: [IconButton] = []
        var index = 0
        while let start = nextButtonCall(in: scanned, from: index) {
            index = start + 1
            guard let callEnd = matchingClose(in: scanned, openAt: start) else { continue }
            var labelText = ""
            let call = String(scanned[start...callEnd])
            if let labelRange = call.range(of: "label:") {
                labelText = String(call[labelRange.upperBound...])
            }
            var end = callEnd
            var cursor = callEnd + 1
            while cursor < scanned.count, scanned[cursor] == " " { cursor += 1 }
            if cursor < scanned.count, scanned[cursor] == "{", let closureEnd = matchingClose(in: scanned, openAt: cursor) {
                if !isTitled(call) { labelText += String(scanned[cursor...closureEnd]) }
                end = closureEnd
            }
            guard calls("Image", in: labelText), !calls("Text", in: labelText), !calls("Label", in: labelText) else { continue }
            let line = scanned[..<start].filter { $0 == "\n" }.count + 1
            found.append(IconButton(path: path, line: line, hasAccessibilityLabel: chain(after: end, in: scanned).contains(".accessibilityLabel(")))
        }
        return found
    }

    /// Whether a `Button(…)` call's first argument is a title (a string literal, blanked to `"…"`).
    private static func isTitled(_ call: String) -> Bool {
        call.dropFirst().drop { $0 == " " || $0 == "\n" }.first == "\""
    }

    /// Whether `text` calls `name(` as a whole identifier — so `NSImage(` isn't `Image(` and
    /// `.accessibilityLabel(` isn't `Label(`.
    private static func calls(_ name: String, in text: String) -> Bool {
        var search = text[...]
        while let range = search.range(of: name + "(") {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            if let before, before.isLetter || before.isNumber || before == "_" || before == "." {
                search = search[range.upperBound...]
                continue
            }
            return true
        }
        return false
    }

    /// The offset of the `(` of the next `Button(` at or after `offset` that isn't part of a longer
    /// identifier (`MyButton(`).
    private static func nextButtonCall(in text: [Character], from offset: Int) -> Int? {
        let token = Array("Button")
        var i = offset
        while i + token.count < text.count {
            if Array(text[i..<(i + token.count)]) == token,
               i == 0 || !(text[i - 1].isLetter || text[i - 1].isNumber || text[i - 1] == "_") {
                var j = i + token.count
                while j < text.count, text[j] == " " { j += 1 }
                if j < text.count, text[j] == "(" { return j }
            }
            i += 1
        }
        return nil
    }

    /// The offset of the bracket closing the one at `open`, counting all three bracket kinds.
    private static func matchingClose(in text: [Character], openAt open: Int) -> Int? {
        var depth = 0
        for i in open..<text.count {
            switch text[i] {
            case "(", "{", "[": depth += 1
            case ")", "}", "]":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
        }
        return nil
    }

    /// The modifier lines following `end`: the rest of its line, then each line starting with `.`.
    private static func chain(after end: Int, in text: [Character]) -> String {
        let lines = String(text[(end + 1)...]).split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return "" }
        var chain = String(first)
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix(".") else { break }
            chain += "\n" + trimmed
        }
        return chain
    }

    @Test("the scanner finds icon-only buttons in every form, and sees a label in the chain")
    func scannerShapes() {
        let source = """
            Button(action: go, label: {
                Image(systemName: "play.fill")
            })
            .buttonStyle(.plain)
            .accessibilityLabel("Play")

            Button(action: stop) {
                Image(systemName: "stop.fill")
            }
            .help("Stop")

            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .accessibilityLabel(deleteLabel)

            Button("Start", systemImage: "play.circle.fill", action: start)
            Button(action: open, label: { Label("Open", systemImage: "folder") })
            Button(action: copy) { HStack { Image(systemName: "doc"); Text("Copy") } }
            MyButton(action: x) { Image(systemName: "x") }
            Button("Render") { let image = NSImage(size: .zero); render(image) }
            Button(action: info, label: { Image(systemName: "info").accessibilityLabel("Info") })
            """
        let found = Self.iconButtons(in: source, path: "Sample.swift")
        // Line 20: a label put on the Image inside the closure doesn't make the button titled, and
        // isn't on the button, so it is reported. Line 19's NSImage is in a titled button's action.
        #expect(found.map(\.line) == [1, 7, 12, 20])
        #expect(found.map(\.hasAccessibilityLabel) == [true, false, true, false])
    }

    @Test("every icon-only button in the app has an accessibility label")
    func iconButtonsAreLabeled() throws {
        let root = CodeStyleGuardTests.appTargetRoot.path
        var unlabeled: [IconButton] = []
        var total = 0
        for file in CodeStyleGuardTests.swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let buttons = Self.iconButtons(in: source, path: String(file.path.dropFirst(root.count + 1)))
            total += buttons.count
            unlabeled += buttons.filter { !$0.hasAccessibilityLabel }
        }
        // A scan that finds nothing is a broken scan, not a clean app.
        #expect(total > 30)
        #expect(unlabeled.isEmpty, "Icon-only buttons with no .accessibilityLabel (reuse the .help text):\n\(unlabeled.map(\.description).joined(separator: "\n"))")
    }
}
