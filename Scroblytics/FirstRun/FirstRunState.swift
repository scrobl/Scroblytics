import Foundation

/// Where a person is in getting started, worked out from what the app holds rather than stored as a flag, so a
/// removed account, a restored backup or an interrupted import all land in the right place.
enum FirstRunState: Equatable {
    /// No Last.fm account and no history: show the welcome screen.
    case noAccount
    /// No history, and the Keychain wouldn't give up the saved account (locked, or access refused): an account is probably
    /// saved, so the welcome screen would be wrong. Show how to get it back instead.
    case credentialsUnreadable
    /// An account is saved but nothing has been imported yet and no import is running.
    case awaitingFirstImport
    /// The first import is running, or was interrupted part-way (it resumes).
    case importing
    /// A first import has finished (or there is history and an account was removed): the normal app.
    case ready

    static func derive(hasCredentials: Bool, scrobbleCount: Int, hasCompletedSync: Bool, isSyncing: Bool, credentialsUnreadable: Bool = false) -> FirstRunState {
        if !hasCredentials && scrobbleCount == 0 { return credentialsUnreadable ? .credentialsUnreadable : .noAccount }
        if hasCredentials && !hasCompletedSync {
            return (isSyncing || scrobbleCount > 0) ? .importing : .awaitingFirstImport
        }
        return .ready
    }
}
