import Foundation

/// Moving a saved account between the key built into the app and the person's own key.
///
/// Only the key changes: the username, the imported history and everything else stay as they are. A session key (the person's approval
/// for write access) belongs to one key, so a switch clears it and write access has to be approved again, once, in the browser.
enum LastfmKeyMode {
    enum SwitchError: Error, LocalizedError {
        case noAccount
        case noBuiltInKey
        case blankKey

        var errorDescription: String? {
            switch self {
            case .noAccount: "There is no saved Last.fm account."
            case .noBuiltInKey: "This build of Scroblytics doesn't include its own Last.fm key."
            case .blankKey: "Enter your API key first."
            }
        }
    }

    /// Whether to offer the one-click move to the built-in key: the saved account uses its own key and this build has a built-in one.
    static func offersBuiltInSwitch(_ credentials: LastfmCredentials?) -> Bool {
        guard let credentials, !credentials.usesBuiltInKey else { return false }
        return LastfmBuiltInKey.isAvailable
    }

    /// Saves the account as using the built-in key, dropping the own key, its secret and the session approved under it.
    @discardableResult
    static func switchToBuiltIn() throws -> LastfmCredentials {
        guard LastfmBuiltInKey.isAvailable else { throw SwitchError.noBuiltInKey }
        guard let saved = LastfmCredentialsStore.load() else { throw SwitchError.noAccount }
        if saved.usesBuiltInKey { return saved }
        let moved = LastfmCredentials.builtIn(username: saved.username, sessionKey: nil)
        try LastfmCredentialsStore.save(moved)
        NotificationCenter.default.post(name: .lastfmCredentialsDidChange, object: nil)
        ActivityLog.record(.account, "Switched from an own Last.fm key to the built-in key")
        return moved
    }

    /// Saves the account as using the person's own key (and optionally its secret), dropping the session approved under the other key.
    @discardableResult
    static func useOwnKey(_ key: String, secret: String? = nil) throws -> LastfmCredentials {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SwitchError.blankKey }
        guard let saved = LastfmCredentialsStore.load() else { throw SwitchError.noAccount }
        let cleanSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let moved = LastfmCredentials(username: saved.username, apiKey: trimmed, apiSecret: (cleanSecret?.isEmpty ?? true) ? nil : cleanSecret, sessionKey: nil)
        try LastfmCredentialsStore.save(moved)
        NotificationCenter.default.post(name: .lastfmCredentialsDidChange, object: nil)
        ActivityLog.record(.account, "Switched from the built-in Last.fm key to an own key")
        return moved
    }
}
