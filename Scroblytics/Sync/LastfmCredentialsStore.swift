import Foundation
import Security

/// A connected Last.fm account. Reading a public profile's scrobble history
/// only needs an app-level API key (no per-user OAuth) — `apiSecret` and
/// `sessionKey` are reserved for a future signed write call (e.g. track.love)
/// and are never required for sync.
struct LastfmCredentials: Equatable {
    var username: String
    var apiKey: String
    var apiSecret: String?
    var sessionKey: String?
}

/// Keychain-backed credential storage. There is no bundled API key to fall back to, so the user supplies
/// their own key/secret from last.fm/api/account/create — this store just
/// persists whatever they enter.
enum LastfmCredentialsStore {
    private static let service = AppIdentity.keychainService("lastfm")
    private static let account = "credentials"

    private struct StoredCredentials: Codable {
        var username: String
        var apiKey: String
        var apiSecret: String?
        var sessionKey: String?
    }

    static func load() -> LastfmCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        query.removeValue(forKey: kSecReturnData as String)
        guard status == errSecSuccess, let data = item as? Data,
              let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
            return nil
        }
        return LastfmCredentials(
            username: stored.username,
            apiKey: stored.apiKey,
            apiSecret: stored.apiSecret,
            sessionKey: stored.sessionKey
        )
    }

    static func save(_ credentials: LastfmCredentials) throws {
        let stored = StoredCredentials(
            username: credentials.username,
            apiKey: credentials.apiKey,
            apiSecret: credentials.apiSecret,
            sessionKey: credentials.sessionKey
        )
        let data = try JSONEncoder().encode(stored)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.write(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.write(updateStatus)
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error, LocalizedError {
        case write(OSStatus)

        var errorDescription: String? {
            switch self {
            case .write(let status): "The Keychain refused to save the credentials (error \(status))."
            }
        }
    }
}
