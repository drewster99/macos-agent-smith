// Reproduces, empirically, what `async` MEANS on each side of this repo's
// app-target/package boundary. Run it when a Swift or Xcode upgrade might have
// moved the defaults (Swift 7 language mode will) — the answers below are the
// premise behind ROADMAP.md's "Actor-isolation boundary" entry.
//
//   # app target: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor,
//   #             SWIFT_APPROACHABLE_CONCURRENCY = YES
//   xcrun swiftc -parse-as-library -swift-version 6 \
//       -default-isolation=MainActor \
//       -enable-upcoming-feature NonisolatedNonsendingByDefault \
//       scripts/actor_isolation_probe.swift -o /tmp/probe_app && /tmp/probe_app
//
//   # AgentSmithKit: neither setting
//   xcrun swiftc -parse-as-library -swift-version 6 \
//       scripts/actor_isolation_probe.swift -o /tmp/probe_pkg && /tmp/probe_pkg
//
// Expected (verified 2026-07-29, Xcode 27 beta 4):
//
//   APP TARGET                          AgentSmithKit
//   plain async             : MAIN      plain async             : off-main
//   nonisolated async       : MAIN      nonisolated async       : off-main
//   @Sendable async         : MAIN      @Sendable async         : off-main
//   @concurrent async       : off-main  @concurrent async       : off-main

import Foundation

nonisolated func where_(_ label: String) {
    print("\(label): \(Thread.isMainThread ? "MAIN" : "off-main")")
}

struct Probe {
    /// Inherits the module default.
    func defaulted() async { where_("plain async      ") }

    /// Under NonisolatedNonsendingByDefault this inherits the CALLER's isolation,
    /// so in the app target it is main whenever a main-actor caller awaits it.
    nonisolated func nonisolatedAsync() async { where_("nonisolated async") }

    /// `@Sendable` does NOT strip the module's default isolation — the shape that
    /// made `DiffView`/`MarkdownText` read as off-main while running on main.
    @Sendable func sendableAsync() async { where_("@Sendable async  ") }

    /// The only spelling that reaches the global concurrent executor regardless
    /// of caller. Implies `nonisolated`; must precede modifiers if both appear.
    @concurrent func concurrentAsync() async { where_("@concurrent async") }
}

@main
struct Main {
    static func main() async {
        let probe = Probe()
        where_("caller (main)    ")
        await probe.defaulted()
        await probe.nonisolatedAsync()
        await probe.sendableAsync()
        await probe.concurrentAsync()
    }
}
