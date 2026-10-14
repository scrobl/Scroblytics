import AppKit
import Foundation
import os
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
///
/// The Keychain can stop to ask (a locked login keychain, a changed app identity), and while it asks the calling thread waits: most
/// callers are on the main thread, so the window freezes until the dialog is answered. So a successful read is kept in memory for
/// the session: one Keychain call, one prompt, instead of one per caller. Reads are serialized, and callers that queued behind a
/// read share its answer instead of each asking again. A failure is never kept for later callers, and "not saved" isn't either,
/// so a fix (unlocking the keychain, saving an account) is seen at once. Saving or clearing updates the memory itself, and the
/// memory is dropped when the app becomes active, to notice a change made by another copy of the app (the Debug and installed
/// builds share the item).
enum LastfmCredentialsStore {
    private static let service = AppIdentity.keychainService("lastfm")
    private static let account = "credentials"

    private struct StoredCredentials: Codable {
        var username: String
        var apiKey: String
        var apiSecret: String?
        var sessionKey: String?
    }

    /// What reading the saved account found.
    enum ReadResult: Equatable {
        case connected(LastfmCredentials)
        /// The Keychain answered: there is no saved account.
        case notSaved
        /// The Keychain did not give the account up (locked, access denied or cancelled, or the item is unreadable): the macOS
        /// status, so a message can say why. An account may well be saved.
        case unreadable(OSStatus)
    }

    typealias RawRead = @Sendable () -> (status: OSStatus, data: Data?)

    private struct State {
        var credentials: LastfmCredentials?
        var problem: OSStatus?
        /// Counts finished reads, so a caller that waited behind one can tell it finished and share its answer.
        var generation = 0
        var lastResult: ReadResult?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let readGate = NSLock()
    private static let rawReader = OSAllocatedUnfairLock<RawRead>(initialState: defaultRawRead())
    /// Registers the activation observer the first time it is touched (it then lives as long as the app).
    private static let observesActivation: Bool = {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in dropCache() }
        return true
    }()

    /// The saved account, or nil when there is none or it couldn't be read (see `read()` to tell those apart).
    static func load() -> LastfmCredentials? {
        if case .connected(let credentials) = read() { return credentials }
        return nil
    }

    /// Why the last read failed, or nil when it didn't (or there has been none). Cleared by a successful read, "not saved", save and clear.
    static var lastProblem: OSStatus? { state.withLock { $0.problem } }

    static func read() -> ReadResult {
        _ = observesActivation
        if let cached = state.withLock({ $0.credentials }) { return .connected(cached) }
        let generationSeen = state.withLock { $0.generation }
        readGate.lock()
        defer { readGate.unlock() }
        let (cached, generation, last) = state.withLock { ($0.credentials, $0.generation, $0.lastResult) }
        if let cached { return .connected(cached) }
        // A read finished while this call waited for its turn: share its answer rather than ask (and maybe prompt) again.
        if generation != generationSeen, let last { return last }
        let raw = rawReader.withLock { $0 }()
        let result = classify(status: raw.status, data: raw.data)
        state.withLock { state in
            state.generation += 1
            state.lastResult = result
            switch result {
            case .connected(let credentials): state.credentials = credentials; state.problem = nil
            case .notSaved: state.credentials = nil; state.problem = nil
            case .unreadable(let status): state.credentials = nil; state.problem = status
            }
        }
        return result
    }

    /// Sorts what the Keychain returned into "here it is", "nothing saved" and "couldn't read it".
    static func classify(status: OSStatus, data: Data?) -> ReadResult {
        switch status {
        case errSecSuccess:
            guard let data, let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
                return .unreadable(errSecDecode)
            }
            return .connected(LastfmCredentials(username: stored.username, apiKey: stored.apiKey, apiSecret: stored.apiSecret, sessionKey: stored.sessionKey))
        case errSecItemNotFound:
            return .notSaved
        default:
            return .unreadable(status)
        }
    }

    /// Forgets what was read, so the next call asks the Keychain again.
    static func dropCache() {
        state.withLock { state in
            state.credentials = nil
            state.problem = nil
            state.lastResult = nil
        }
    }

    private static func defaultRawRead() -> RawRead {
        #if DEBUG
        // A test or a scripted run can make the Keychain answer "locked", "denied" or "nothing saved" without touching it.
        if let mode = ProcessInfo.processInfo.environment["SCROBLYTICS_KEYCHAIN_SIMULATE"] {
            switch mode {
            case "locked": return { (errSecInteractionNotAllowed, nil) }
            case "denied": return { (errSecAuthFailed, nil) }
            case "none": return { (errSecItemNotFound, nil) }
            default: break
            }
        }
        #endif
        let service = service, account = account
        return {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        }
    }

    #if DEBUG
    /// Replaces the Keychain call (checks only), and forgets everything read so far.
    static func useRawReaderForTesting(_ reader: @escaping RawRead) {
        rawReader.withLock { $0 = reader }
        state.withLock { $0 = State() }
    }
    #endif

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
        noteSaved(credentials)
    }

    /// What saving does to the memory: the saved account is now the known one.
    static func noteSaved(_ credentials: LastfmCredentials) {
        state.withLock { state in
            state.credentials = credentials
            state.problem = nil
            state.generation += 1
            state.lastResult = .connected(credentials)
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        noteCleared()
    }

    /// What clearing does to the memory: there is no known account, and "not saved" is the answer to share.
    static func noteCleared() {
        state.withLock { state in
            state.credentials = nil
            state.problem = nil
            state.generation += 1
            state.lastResult = .notSaved
        }
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
