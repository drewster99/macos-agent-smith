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
        }
        return nil
    }

    // MARK: - Delete

    public func delete(account: String) {
        for useDataProtection in [true, false] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: useDataProtection
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    /// Removes every secret belonging to a server (all env values and secret args).
    public func deleteAll(serverID: UUID, envVarNames: [String], secretArgIndices: Set<Int>) {
        for name in envVarNames { delete(account: Self.envAccount(serverID: serverID, name: name)) }
        for index in secretArgIndices { delete(account: Self.argAccount(serverID: serverID, index: index)) }
    }
}

public enum MCPSecretError: Error, Sendable {
    case encodingFailed
    case saveFailed(status: OSStatus)
}
