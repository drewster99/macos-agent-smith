import Foundation
import AppKit
import SwiftLLMKit
import os

nonisolated private let codexSignInLogger = Logger(subsystem: "com.agentsmith", category: "CodexSignIn")

/// Sign-in for the ChatGPT-subscription provider, delegated to the `codex` CLI.
///
/// We do not implement the OAuth flow. It is PKCE against `auth.openai.com` with a browser redirect
/// to a loopback listener, which would mean shipping a redirect server, a login window, and a client
/// id we do not own — for a credential the user can mint with one `codex login`. Reading the file
/// the CLI already writes costs none of that, and `CodexAuthCoordinator` writes refreshes back so
/// the two never disagree about which token is current.
enum CodexSignIn {

    /// What the UI needs to say about the credential, without handing any of it to the caller.
    enum Status: Equatable {
        /// No `codex` binary was found, so there is nothing to launch.
        case cliMissing
        /// The CLI is installed but has no credential — the user has not signed in.
        case signedOut
        /// Signed in. `plan` is the subscription tier for display; `expiry` is the access token's,
        /// which the coordinator refreshes automatically well before it matters.
        case signedIn(plan: String?, expiry: Date?)

        var isSignedIn: Bool { if case .signedIn = self { return true }; return false }
    }

    /// Reads the current credential state.
    ///
    /// NOT cheap: it opens and JSON-parses `~/.codex/auth.json`. Call it on an event — appear, a
    /// button press — and cache the result; never from a `body`, which SwiftUI may evaluate many
    /// times per display pass. An earlier version of this doc said the opposite and a caller
    /// believed it, which is how a file read ended up on a render path.
    ///
    /// Deliberately returns only a tier string and an expiry date — never the tokens, and never the
    /// account id, which is account-linked and must not reach a log or a screenshot.
    nonisolated static func status() -> Status {
        let store = CodexAuthStore()
        guard store.isPresent, let tokens = store.load() else {
            return binaryURL() == nil ? .cliMissing : .signedOut
        }
        let plan = tokens.idToken.flatMap(CodexJWT.planType)
            ?? CodexJWT.planType(tokens.accessToken)
        return .signedIn(plan: plan, expiry: tokens.expiry)
    }

    /// Locates the `codex` binary.
    ///
    /// A GUI app does not inherit the user's interactive `PATH`, so `which codex` in a login shell
    /// finding it proves nothing about what this process can see — hence the explicit candidate
    /// list covering Homebrew (both architectures), a manual install, and the usual Node managers.
    nonisolated static func binaryURL() -> URL? {
        var candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.npm-global/bin/codex",
            "\(NSHomeDirectory())/.bun/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex"
        ]
        // Whatever PATH we DID inherit, still checked — it costs nothing and covers installs the
        // list above does not anticipate.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Opens Terminal running `codex login` so the user can complete the browser flow and watch it.
    ///
    /// Terminal rather than a `Process` we own: the flow prints a URL, waits on a browser round
    /// trip, and can ask questions. Swallowing that into a background process would leave the user
    /// staring at a spinner with no way to see what it wants. This takes focus, which is why it is
    /// only ever called from an explicit button press.
    @MainActor
    static func launchLogin() {
        guard let binary = binaryURL() else {
            codexSignInLogger.error("codex CLI not found; cannot start ChatGPT sign-in")
            return
        }
        // TWO quoting layers, and both matter. The path is wrapped in shell single quotes because
        // it can contain spaces — so any single quote inside it has to be closed, escaped and
        // reopened first, or it escapes the quoting entirely. Then the whole command is escaped for
        // AppleScript's own string syntax. A `$PATH` entry is user-controlled, which is the only way
        // an odd character reaches here, and is exactly why this is not left to luck.
        let shellSafePath = binary.path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "clear; echo '── codex login ──'; '\(shellSafePath)' login"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        guard let apple = NSAppleScript(source: script) else {
            codexSignInLogger.error("Could not build the Terminal launch script")
            return
        }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
        if let error {
            codexSignInLogger.error("Terminal launch failed: \(error.description, privacy: .public)")
        }
    }
}
