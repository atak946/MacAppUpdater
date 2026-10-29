import Foundation
import os
import Security

/// Storage for a secret API token. Production uses the Keychain; tests use an in-memory stub.
public protocol TokenStoring: Sendable {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

public enum TokenStoreError: Error, Sendable, Equatable, LocalizedError {
    case invalidToken
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidToken: String(coreLocalized: "The token is empty or contains invalid characters.")
        case .keychain(let status):
            String(coreLocalized: "Keychain error \(Int(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")")
        }
    }
}

/// Generic-password Keychain item holding the GitHub API token. Never stored in UserDefaults.
public struct KeychainTokenStore: TokenStoring {
    public static let githubService = "com.macappupdater.github"
    public static let defaultAccount = "api-token"

    private static let logger = Logger(subsystem: "com.macappupdater", category: "TokenStore")

    private let service: String
    private let account: String

    public init(service: String = KeychainTokenStore.githubService, account: String = KeychainTokenStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    /// Trims whitespace; rejects empty values and control characters (header injection).
    public static func sanitized(_ token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) && $0 != " " })
        else { return nil }
        return trimmed
    }

    /// Reads the data-protection item; falls back to (and migrates) a legacy file-keychain item,
    /// e.g. one saved by an older version or by a build without keychain entitlements.
    public func readToken() throws -> String? {
        let modern = try copyToken(dataProtection: true)
        if case .found(let token) = modern { return token }
        guard case .found(let legacyToken) = try copyToken(dataProtection: false) else { return nil }
        if case .notFound = modern, (try? store(Data(legacyToken.utf8), dataProtection: true)) == true {
            _ = SecItemDelete(query(dataProtection: false) as CFDictionary)
        }
        return legacyToken
    }

    public func saveToken(_ token: String) throws {
        guard let value = Self.sanitized(token) else { throw TokenStoreError.invalidToken }
        let data = Data(value.utf8)
        if try store(data, dataProtection: true) {
            _ = SecItemDelete(query(dataProtection: false) as CFDictionary)
            return
        }
        Self.logger.notice("Data-protection keychain unavailable (unsigned build?); using the login keychain")
        guard try store(data, dataProtection: false) else { throw TokenStoreError.keychain(errSecMissingEntitlement) }
    }

    public func deleteToken() throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(query(dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
                throw TokenStoreError.keychain(status)
            }
        }
    }

    private enum CopyResult { case found(String), notFound, unavailable }

    private func copyToken(dataProtection: Bool) throws -> CopyResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery(dataProtection: dataProtection) as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }.map(CopyResult.found) ?? .notFound
        case errSecItemNotFound: return .notFound
        case errSecMissingEntitlement: return .unavailable
        default: throw TokenStoreError.keychain(status)
        }
    }

    /// Update-then-add. Returns false only when this keychain is unavailable (missing entitlement).
    private func store(_ data: Data, dataProtection: Bool) throws -> Bool {
        let base = query(dataProtection: dataProtection)
        let updateStatus = SecItemUpdate(base as CFDictionary, Self.updateAttributes(data: data) as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecMissingEntitlement { return false }
        guard updateStatus == errSecItemNotFound else { throw TokenStoreError.keychain(updateStatus) }
        let addStatus = SecItemAdd(addQuery(data: data, dataProtection: dataProtection) as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement { return false }
        guard addStatus == errSecSuccess else { throw TokenStoreError.keychain(addStatus) }
        return true
    }

    // MARK: Query builders (pure; unit-tested without touching the keychain)

    /// `dataProtection: true` targets the data-protection keychain (per-app access group,
    /// not the legacy file keychain); `false` is the legacy fallback/migration source.
    func query(dataProtection: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    func readQuery(dataProtection: Bool = true) -> [String: Any] {
        query(dataProtection: dataProtection).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
    }

    func addQuery(data: Data, dataProtection: Bool = true) -> [String: Any] {
        query(dataProtection: dataProtection).merging(Self.updateAttributes(data: data)) { _, new in new }
    }

    /// Accessibility is (re)applied on update too, so items created before this policy get it.
    static func updateAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

extension TokenStoring {
    /// Token provider for `GitHubReleasesSource`; read failures degrade to anonymous requests.
    public var tokenProvider: GitHubReleasesSource.TokenProvider {
        { [self] in
            do {
                return try readToken()
            } catch {
                Logger(subsystem: "com.macappupdater", category: "TokenStore")
                    .error("Token read failed, using anonymous requests: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
}
