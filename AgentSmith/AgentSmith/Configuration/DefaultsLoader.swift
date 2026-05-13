import Foundation
import AgentSmithKit

/// Errors that can occur when loading bundled defaults.
private enum DefaultsLoaderError: Error, LocalizedError {
    case missingBundledFile

    var errorDescription: String? {
        switch self {
        case .missingBundledFile:
            return "defaults.json not found in app bundle"
        }
    }
}

/// Loads the bundled `defaults.json` from the app's resource bundle.
enum DefaultsLoader {
    /// Decodes and returns the bundled `AppDefaults` from `defaults.json`.
    static func loadBundledDefaults() throws -> AppDefaults {
        guard let url = Bundle.main.url(forResource: "defaults", withExtension: "json") else {
            throw DefaultsLoaderError.missingBundledFile
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppDefaults.self, from: data)
    }
}
