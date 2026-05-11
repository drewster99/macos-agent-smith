import Testing
import Foundation
@testable import AgentSmithKit

/// Pure tests of `GlobTool.spotlightPlan` — the glob→Spotlight-query translation. Independent of
/// any actual `mdfind` call; assertions are over the produced `scope` / `nameQuery` strings.
@Suite("GlobTool Spotlight plan")
struct GlobToolSpotlightPlanTests {

    private let base = "/Users/test/proj"

    private func plan(_ pattern: String, base: String? = nil) throws -> SpotlightPlan {
        let segs = try GlobTool.parseSegments(pattern)
        return GlobTool.spotlightPlan(forSegments: segs, resolvedBase: base ?? self.base, fullRegexBody: GlobTool.globToRegex(pattern))
    }

    @Test("`**/*.swift` → scope=base, name=*.swift")
    func leadingDoubleStarWithExtensionLeaf() throws {
        let p = try plan("**/*.swift")
        #expect(p.scope == base)
        #expect(p.nameQuery == #"kMDItemFSName == "*.swift""#)
    }

    @Test("`src/**/*.ts` → folds `src` into scope, leaf=*.ts")
    func leadingLiteralFoldedIntoScope() throws {
        let p = try plan("src/**/*.ts")
        #expect(p.scope == base + "/src")
        #expect(p.nameQuery == #"kMDItemFSName == "*.ts""#)
    }

    @Test("`**/src/**/*.swift` cannot fold leading `**` — scope stays at base")
    func leadingDoubleStarStopsFolding() throws {
        let p = try plan("**/src/**/*.swift")
        #expect(p.scope == base)
        #expect(p.nameQuery == #"kMDItemFSName == "*.swift""#)
    }

    @Test("`**/AppDelegate.swift` → exact-filename leaf")
    func exactFilenameLeaf() throws {
        let p = try plan("**/AppDelegate.swift")
        #expect(p.scope == base)
        #expect(p.nameQuery == #"kMDItemFSName == "AppDelegate.swift""#)
    }

    @Test("`*.{ts,tsx}` leaf expands to OR'd predicates")
    func braceLeafExpands() throws {
        let p = try plan("*.{ts,tsx}")
        #expect(p.scope == base)
        // Order is preserved by `expandBraces`.
        #expect(p.nameQuery == #"kMDItemFSName == "*.ts" || kMDItemFSName == "*.tsx""#)
    }

    @Test("`src/**` (trailing `**`) → scope=base/src, name=*")
    func trailingDoubleStarMatchesEverything() throws {
        let p = try plan("src/**")
        #expect(p.scope == base + "/src")
        #expect(p.nameQuery == #"kMDItemFSName == "*""#)
    }

    @Test("`?` in the leaf collapses with adjacent wildcards in the mdfind query")
    func questionMarkCollapsedForMdfind() throws {
        let p = try plan("**/Foo?.swift")
        // `?` collapses to `*` (a superset) for mdfind; the post-filter regex narrows precisely.
        #expect(p.nameQuery == #"kMDItemFSName == "Foo*.swift""#)
    }

    @Test("scope-folding stops short of the trailing segment even when it's a literal")
    func allLiteralsScopeIsParentDir() throws {
        let p = try plan("src/lib/foo.swift")
        // `src` and `lib` are folded; `foo.swift` becomes the name predicate. Scope must be the
        // parent dir, not the file itself.
        #expect(p.scope == base + "/src/lib")
        #expect(p.nameQuery == #"kMDItemFSName == "foo.swift""#)
    }
}
