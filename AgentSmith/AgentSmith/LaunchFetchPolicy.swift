import Foundation
import SwiftLLMKit

/// How a launch should refresh the model catalog, from launch arguments.
///
/// One policy for every entry point — normal app launch, `--eval-capabilities`, `--list-models` —
/// so "when do we re-fetch model lists" has a single answer instead of each caller inventing its
/// own. The default is the app's own gated behavior (fetch once per day); the two flags override
/// it and compose with any launch.
///
///   --force-fetch-models   re-fetch every provider now, ignoring the daily gate
///   --no-fetch-models      never fetch; use whatever is cached
///   (neither)              gated: fetch only if the daily gate says it's due
enum LaunchFetchPolicy {
    case forced
    case none
    case gated

    static var fromArguments: LaunchFetchPolicy {
        let args = CommandLine.arguments
        if args.contains("--force-fetch-models") { return .forced }
        if args.contains("--no-fetch-models") { return .none }
        return .gated
    }

    /// Applies the policy to a manager whose `load()` has already brought in the cached catalog.
    @MainActor
    func apply(to kit: LLMKitManager) async {
        switch self {
        case .none:
            break                              // cache only
        case .forced:
            await kit.refreshAllModels()       // ungated, every provider
        case .gated:
            await kit.refreshIfNeeded()        // the app's normal once-per-day behavior
        }
    }
}
