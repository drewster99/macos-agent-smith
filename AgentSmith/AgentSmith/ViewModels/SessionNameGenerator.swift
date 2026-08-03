import Foundation

/// Generates friendly, memorable session names like "brave otter" — so new sessions are
/// distinguishable at a glance instead of a wall of "New Session". Collision-checked against the
/// names already in use.
enum SessionNameGenerator {

    private static let adjectives = [
        "brave", "calm", "clever", "eager", "gentle", "jolly", "keen", "lively",
        "merry", "nimble", "plucky", "quiet", "swift", "witty", "bold", "cosmic",
        "dapper", "fuzzy", "grand", "humble", "mellow", "spry", "sunny", "zesty"
    ]

    private static let nouns = [
        "otter", "falcon", "maple", "comet", "willow", "badger", "heron", "cedar",
        "lynx", "raven", "koala", "marmot", "puffin", "walrus", "gecko", "yak",
        "finch", "moth", "newt", "quail", "bison", "ibex", "wren", "vole"
    ]

    /// A random "adjective noun" name not present in `existing`. Falls back to appending a number if
    /// the (large) combination space somehow can't produce a fresh pairing.
    static func uniqueName(avoiding existing: Set<String>) -> String {
        for _ in 0..<64 {
            let candidate = randomPair()
            if !existing.contains(candidate) { return candidate }
        }
        var suffix = 2
        while true {
            let candidate = "\(randomPair()) \(suffix)"
            if !existing.contains(candidate) { return candidate }
            suffix += 1
        }
    }

    private static func randomPair() -> String {
        let adjective = adjectives.randomElement() ?? "brave"
        let noun = nouns.randomElement() ?? "otter"
        return "\(adjective) \(noun)"
    }
}
