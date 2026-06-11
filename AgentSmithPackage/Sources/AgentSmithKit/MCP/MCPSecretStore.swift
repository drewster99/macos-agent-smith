import Foundation
import os
import Security

private let logger = Logger(subsystem: "AgentSmithKit", category: "MCPSecretStore")

/// Keychain-backed store for MCP server secrets (env values and secret command-line
/// arguments). Mirrors `SwiftLLMKit.KeychainService`'s approach: a generic-password
/// item per secret, stored in the Data Protection Keychain with a transparent
/// fallback to the legacy login keychain when the process lacks the entitlement
/// (CLI/test contexts).
///
/// Accounts are namespaced per server so removing a server can purge all of its
/// secrets in one pass:
/// - env value:  `<serverID>/env/<NAME>`
/// - secret arg: `<serverID>/arg/<index>`
/// Minimal write surface for MCP secrets, so config import can be unit-tested with an
/// in-memory fake instead of the real Keychain.
public protocol MCPSecretWriting: Sendable {
    func save(_ secret: String, account: String) throws
}

public struct MCPSecretStore: MCPSecretWriting, Sendable {
    private let service: String

    public init(appIdentifier: String = Bundle.main.bundleIdentifier ?? "com.nuclearcyborg.AgentSmith") {
        self.service = "com.agentsmith.mcp.\(appIdentifier)"
    }

    public static func envAccount(serverID: UUID, name: String) -> String {
        "\(serverID.uuidString)/env/\(name)"
    }

    public static func argAccount(serverID: UUID, index: Int) -> String {
        "\(serverID.uuidString)/arg/\(index)"
    }

    // MARK: - Save

    public func save(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else { throw MCPSecretError.encodingFailed }
        do {
            try saveImpl(data: data, account: account, useDataProtection: true)
        } catch MCPSecretError.saveFailed(let status) where status == errSecMissingEntitlement {
            logger.info("DPK save rejected (missing entitlement); falling back to legacy keychain")
            try saveImpl(data: data, account: account, useDataProtection: false)
        }
    }

    private func saveImpl(data: Data, account: String, useDataProtection: Bool) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: useDataProtection
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw MCPSecretError.saveFailed(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw MCPSecretError.saveFailed(status: updateStatus)
        }
    }

    // MARK: - Read

    public func secret(account: String) -> String? {
        for useDataProtection in [true, false] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: useDataProtection,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
                return value
            }
            // A miss in one keychain is expected (a secret lives in only one of the two),
            // but any other non-success status is a real read failure — surface it rather
            // than silently returning nil as if the secret simply didn't exist.
            if status != errSecSuccess && status != errSecItemNotFound {
                logger.error("Keychain read failed for account \(account, privacy: .public): OSStatus \(status, privacy: .public)")
            }
        }
        return nil
    }

    // MARK: - Delete

    /// Removes a secret from both the data-protection and legacy keychains. Throws
    /// `MCPSecretError.deleteFailed` if either delete returns a genuine error so callers
    /// never assume a secret was purged when it wasn't — leaving secret material on disk
    /// must be surfaced, not swallowed.
    public func delete(account: String) throws {
        var realFailure: OSStatus?
        for useDataProtection in [true, false] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: useDataProtection
            ]
            let status = SecItemDelete(query as CFDictionary)
            // `errSecItemNotFound` is expected: each account lives in only one of the two
            // keychains, so the other delete always misses. Anything else is a real failure.
            if status != errSecSuccess && status != errSecItemNotFound {
                logger.error("Keychain delete failed for account \(account, privacy: .public): OSStatus \(status, privacy: .public)")
                realFailure = status
            }
        }
        if let realFailure {
            throw MCPSecretError.deleteFailed(status: realFailure)
        }
    }

    /// Removes every secret belonging to a server (all env values and secret args).
    /// Best-effort: a failure on one account is logged (and surfaced by `delete`) but does
    /// not abort the rest, so server removal can't be blocked by a single Keychain error.
    public func deleteAll(serverID: UUID, envVarNames: [String], secretArgIndices: Set<Int>) {
        for name in envVarNames {
            do {
                try delete(account: Self.envAccount(serverID: serverID, name: name))
            } catch {
                logger.error("deleteAll: could not remove env secret \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        for index in secretArgIndices {
            do {
                try delete(account: Self.argAccount(serverID: serverID, index: index))
            } catch {
                logger.error("deleteAll: could not remove arg secret #\(index, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

public enum MCPSecretError: Error, Sendable {
    case encodingFailed
    case saveFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
}
