import Foundation
import Observation
import SwiftData

extension Notification.Name {
    /// A sync started. `userInfo["first"]` is true when it is the very first import.
    static let scrobbleSyncDidStart = Notification.Name("ScrobbleSyncDidStart")
    /// A sync ran to the end (whether or not anything changed).
    static let scrobbleSyncDidFinish = Notification.Name("ScrobbleSyncDidFinish")
    /// A sync failed. `object` is a `HistoryStatus.Failure`.
    static let scrobbleSyncDidFail = Notification.Name("ScrobbleSyncDidFail")
    /// Something outside the toolbar (an empty page, a strip) wants a normal sync started.
    static let syncRequested = Notification.Name("SyncRequested")
}

/// What the app knows about the history right now, for the screens that have nothing to show yet: whether there is an
/// account, how much has been imported, and whether an import is running, paused or has failed. One place decides what
/// an empty screen should say, so a brand-new Last.fm account, an import in progress and a missing account read
/// differently instead of all looking like a broken app.
@MainActor
@Observable
final class HistoryStatus {
    /// A failed sync, in words, and what to offer: fix the account in Settings, or just try again.
    struct Failure: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case retry, fixAccount }
        let message: String
        let kind: Kind

        /// Key, suspended-key and privacy errors can't be cured by retrying; everything else might be.
        init(error: Error) {
            // Not being able to reach Last.fm at all gets the same plain words as the account check.
            if error is OfflineError || ConnectivityGate.isConnectivityError(error) {
                message = LastfmAccountCheck.message(for: error, username: "")
            } else {
                message = describeSyncError(error)
            }
            if case .api(let code, _)? = error as? LastfmAPIError, [4, 9, 10, 17, 26].contains(code) {
                kind = .fixAccount
            } else {
                kind = .retry
            }
        }

        init(message: String, kind: Kind) {
            self.message = message
            self.kind = kind
        }
    }

    enum Phase: Equatable {
        case idle
        case running(isFirstImport: Bool)
        case paused
        case failed(Failure)
    }

    /// Why a screen has nothing to show, if it has no history at all.
    enum EmptyReason: Equatable {
        case noAccount
        case importing
        case interrupted
        case failed(Failure)
        case accountHasNoScrobbles
    }

    private(set) var scrobbleCount = 0
    private(set) var hasAccount = false
    /// Set when the Keychain wouldn't give up the saved account (locked, access refused): the macOS status. Not the same as having
    /// no account.
    private(set) var credentialsProblem: OSStatus?
    private(set) var hasCompletedSync = false
    private(set) var phase = Phase.idle

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastLogged = ""

    init(container: ModelContainer) {
        self.container = container
        refresh()
        let center = NotificationCenter.default
        func listen(_ name: Notification.Name, _ handle: @escaping @MainActor (_ first: Bool?, _ failure: Failure?) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let first = note.userInfo?["first"] as? Bool
                let failure = note.object as? Failure
                MainActor.assumeIsolated { handle(first, failure) }
            })
        }
        listen(.lastfmCredentialsDidChange) { [weak self] _, _ in self?.refresh() }
        listen(.scrobbleSyncDidProgress) { [weak self] _, _ in self?.refresh() }
        listen(.scrobbleSyncDidComplete) { [weak self] _, _ in self?.refresh() }
        listen(.scrobbleSyncDidStart) { [weak self] first, _ in
            self?.phase = .running(isFirstImport: first ?? false)
            self?.refresh()
        }
        listen(.scrobbleSyncDidFinish) { [weak self] _, _ in
            self?.phase = .idle
            self?.refresh()
        }
        listen(.scrobbleSyncDidStop) { [weak self] _, _ in
            self?.phase = .paused
            self?.refresh()
        }
        listen(.scrobbleSyncDidFail) { [weak self] _, failure in
            self?.phase = failure.map { .failed($0) } ?? .paused
            self?.refresh()
        }
    }

    /// "Try Again" after the Keychain couldn't be read: asks it afresh, and when the account now reads, tells the rest of the app
    /// (so Now Playing and the sync pick it up).
    func retryCredentials() {
        LastfmCredentialsStore.dropCache()
        refresh()
        if hasAccount {
            NotificationCenter.default.post(name: .lastfmCredentialsDidChange, object: nil)
            NotificationCenter.default.post(name: .syncRequested, object: nil)
        }
    }

    /// Reads the facts from the store and the Keychain. A count and one row.
    func refresh() {
        let context = container.mainContext
        scrobbleCount = (try? context.fetchCount(FetchDescriptor<Scrobble>())) ?? 0
        let before = credentialsProblem
        switch LastfmCredentialsStore.read() {
        case .connected: hasAccount = true; credentialsProblem = nil
        case .notSaved: hasAccount = false; credentialsProblem = nil
        case .unreadable(let status): hasAccount = false; credentialsProblem = status
        }
        // One line in the activity log when it starts or stops, for Report a Problem (a status number, nothing else).
        if credentialsProblem != before {
            ActivityLog.record(.account, credentialsProblem.map { "Couldn't read the saved Last.fm account from the Keychain (status \($0))" } ?? "The saved Last.fm account can be read from the Keychain again")
        }
        var descriptor = FetchDescriptor<SyncState>()
        descriptor.fetchLimit = 1
        let state = try? context.fetch(descriptor).first
        hasCompletedSync = state?.lastSyncedAt != nil
        // Nothing is running at launch, so an unfinished import left a cursor behind: it is paused until it resumes.
        if phase == .idle, hasAccount, state?.backfillNextPage != nil { phase = .paused }
        if hasAccount == false { phase = .idle }
        logIfChanged()
    }

    /// Where the person is in getting started (see `FirstRunState`).
    var firstRunState: FirstRunState {
        FirstRunState.derive(hasCredentials: hasAccount, scrobbleCount: scrobbleCount, hasCompletedSync: hasCompletedSync, isSyncing: false, credentialsUnreadable: credentialsProblem != nil)
    }

    var emptyReason: EmptyReason? {
        Self.emptyReason(scrobbleCount: scrobbleCount, hasAccount: hasAccount, hasCompletedSync: hasCompletedSync, phase: phase)
    }

    /// True while the first import is unfinished but some history is already showing, so the numbers are partial.
    var isPartial: Bool {
        Self.isPartial(scrobbleCount: scrobbleCount, hasAccount: hasAccount, hasCompletedSync: hasCompletedSync)
    }

    nonisolated static func emptyReason(scrobbleCount: Int, hasAccount: Bool, hasCompletedSync: Bool, phase: Phase) -> EmptyReason? {
        guard scrobbleCount == 0 else { return nil }
        guard hasAccount else { return .noAccount }
        switch phase {
        case .running: return .importing
        case .failed(let failure): return .failed(failure)
        case .paused: return .interrupted
        case .idle: return hasCompletedSync ? .accountHasNoScrobbles : .importing
        }
    }

    nonisolated static func isPartial(scrobbleCount: Int, hasAccount: Bool, hasCompletedSync: Bool) -> Bool {
        hasAccount && !hasCompletedSync && scrobbleCount > 0
    }

    private func logIfChanged() {
        #if DEBUG
        let line = "HISTORY count=\(scrobbleCount) account=\(hasAccount) keychainProblem=\(credentialsProblem.map(String.init) ?? "none") completed=\(hasCompletedSync) phase=\(phase) reason=\(String(describing: emptyReason)) partialNote=\(isPartial)"
        if line != lastLogged {
            lastLogged = line
            TestProfile.log(line)
        }
        #endif
    }
}
