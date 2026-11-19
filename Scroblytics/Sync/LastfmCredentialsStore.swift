import AppKit
import Foundation
import os
import Security

/// A connected Last.fm account. Reading a public profile's scrobble history only needs an app-level API key (no per-user OAuth);
/// `apiSecret` and `sessionKey` are for the signed write calls (track actions, scrobbling) and are never required for sync.
///
/// `apiKey` and `apiSecret` are always the **effective** pair: when `usesBuiltInKey` is true they are the key and secret built into
/// this release (`LastfmBuiltInKey`), filled in when the account is read; otherwise they are the person's own. Everything that calls
/// Last.fm just uses them, and `sessionKey` is the person's approval for that particular key.
struct LastfmCredentials: Equatable {
    var username: String
    var apiKey: String
    var apiSecret: String?
    var sessionKey: String?
    /// True when `apiKey` and `apiSecret` are the built-in pair rather than the person's own.
    var usesBuiltInKey: Bool = false

    /// An account that uses the built-in key and secret (empty strings if this build has none; see `LastfmBuiltInKey.isAvailable`).
    static func builtIn(username: String, sessionKey: String? = nil) -> LastfmCredentials {
        let pair = LastfmBuiltInKey.pair
        return LastfmCredentials(username: username, apiKey: pair?.key ?? "", apiSecret: pair?.secret, sessionKey: sessionKey, usesBuiltInKey: true)
    }
}

/// Keychain-backed credential storage. A person either uses the key built into the app or their own key and secret from
/// last.fm/api/account/create; this store persists the username, the session key and, for an own key, the key and secret. An
/// account that uses the built-in key is stored with an empty key and no secret, and the built-in pair is filled in when it is read,
/// so the pair itself is never written to the Keychain and a later release can replace it.
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

    /// The account already read in this session, or nil if none has been read (never touches the Keychain). For wording that depends on
    /// which key is in use, where reading the Keychain from an error path would be wrong.
    static var cachedAccount: LastfmCredentials? { state.withLock { $0.credentials } }

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
            // An empty stored key means "the built-in key"; items saved before it existed always hold the person's own key.
            if stored.apiKey.isEmpty { return .connected(.builtIn(username: stored.username, sessionKey: stored.sessionKey)) }
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

    /// Replaces the Keychain write (checks only): `save` hands the bytes it would store to `writer` and touches nothing real. Pass nil to
    /// go back to the Keychain.
    static func useRawWriterForTesting(_ writer: (@Sendable (Data) throws -> Void)?) {
        rawWriter.withLock { $0 = writer }
    }

    private static let rawWriter = OSAllocatedUnfairLock<(@Sendable (Data) throws -> Void)?>(initialState: nil)
    #endif

    /// The bytes written for `credentials`: an account on the built-in key keeps only the username and session (the built-in pair is
    /// never stored), an own-key account keeps its key and secret. Exposed so a check can look at exactly what would be saved.
    static func encodedForStorage(_ credentials: LastfmCredentials) throws -> Data {
        let builtIn = credentials.usesBuiltInKey
        let stored = StoredCredentials(
            username: credentials.username,
            apiKey: builtIn ? "" : credentials.apiKey,
            apiSecret: builtIn ? nil : credentials.apiSecret,
            sessionKey: credentials.sessionKey
        )
        return try JSONEncoder().encode(stored)
    }

    static func save(_ credentials: LastfmCredentials) throws {
        let data = try encodedForStorage(credentials)
        // What is remembered is the effective account, with the current built-in pair filled in.
        let effective = credentials.usesBuiltInKey ? LastfmCredentials.builtIn(username: credentials.username, sessionKey: credentials.sessionKey) : credentials
        #if DEBUG
        // A check can catch what would be written instead of touching the real Keychain item.
        if let writer = rawWriter.withLock({ $0 }) {
            try writer(data)
            noteSaved(effective)
            return
        }
        #endif

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
        noteSaved(effective)
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
