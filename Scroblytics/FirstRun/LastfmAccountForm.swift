import Foundation
import Observation

extension Notification.Name {
    /// A Last.fm account was checked and saved. The app starts a sync (the first one is the full import).
    static let lastfmAccountConnected = Notification.Name("LastfmAccountConnected")
}

/// The username/API-key form shared by Settings › Sync and the welcome screen: checks the pair with Last.fm, saves it
/// to the Keychain only if it works, and starts the import.
@MainActor
@Observable
final class LastfmAccountForm {
    enum Phase: Equatable {
        case idle
        case checking
        case saved(LastfmAccountCheck.Account)
        case failed(String)
    }

    var username = ""
    var apiKey = ""
    private(set) var phase = Phase.idle

    var isChecking: Bool { phase == .checking }
    var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !isChecking
    }

    /// Fills the fields from the saved account, if there is one. Returns whether there was one.
    @discardableResult
    func loadSaved() -> Bool {
        guard let saved = LastfmCredentialsStore.load() else { return false }
        username = saved.username
        apiKey = saved.apiKey
        return true
    }

    func reset() {
        username = ""
        apiKey = ""
        phase = .idle
    }

    /// Checks the pair with Last.fm and, if it works, saves it and tells the app to sync. Nothing is saved when the
    /// check fails, so a typo never replaces a working account.
    @discardableResult
    func testAndSave() async -> Bool {
        guard canSubmit else { return false }
        phase = .checking
        let outcome = await LastfmAccountCheck.validate(username: username, apiKey: apiKey)
        switch outcome {
        case .invalid(let message):
            phase = .failed(message)
            return false
        case .valid(let account):
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // Saving the same account again keeps its write access (secret and session); a different account or key
            // starts without it, as before.
            var credentials = LastfmCredentials(username: account.username, apiKey: key, apiSecret: nil, sessionKey: nil)
            if let existing = LastfmCredentialsStore.load(), existing.apiKey == key, existing.username.caseInsensitiveCompare(account.username) == .orderedSame {
                credentials.apiSecret = existing.apiSecret
                credentials.sessionKey = existing.sessionKey
            }
            do {
                try LastfmCredentialsStore.save(credentials)
            } catch {
                phase = .failed("Last.fm accepted these, but they couldn’t be saved: \(describeSyncError(error))")
                return false
            }
            username = account.username
            phase = .saved(account)
            NotificationCenter.default.post(name: .lastfmCredentialsDidChange, object: nil)
            NotificationCenter.default.post(name: .lastfmAccountConnected, object: account)
            return true
        }
    }
}
