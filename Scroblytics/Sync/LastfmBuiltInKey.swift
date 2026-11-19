import Foundation
import os

/// The Last.fm API key and shared secret built into this release, so a person only has to enter a username.
///
/// They are injected at build time from the git-ignored `Config/Secrets.xcconfig` into Info.plist (the same way as the built-in
/// tempo-lookup key), so they are never in the source. Anyone can read them out of the app: the key identifies Scroblytics to
/// Last.fm, and the secret only lets a request claim to come from it. Neither can act on a person's account without that person
/// approving access in their browser.
///
/// A person can still use their own key instead (Settings › Sync › advanced); `LastfmCredentials.usesBuiltInKey` says which. The
/// built-in pair is never written to the Keychain, so a later release can replace it.
enum LastfmBuiltInKey {
    struct Pair: Equatable, Sendable {
        let key: String
        let secret: String
    }

    /// The pair baked into this build, or nil when there is none (a build made without `Config/Secrets.xcconfig`).
    static var pair: Pair? {
        #if DEBUG
        switch override.withLock({ $0 }) {
        case .pair(let pair): return pair
        case .unavailable: return nil
        case .none: break
        }
        #endif
        if let key = plistValue("LastfmAPIKey"), let secret = plistValue("LastfmAPISecret") { return Pair(key: key, secret: secret) }
        #if DEBUG
        // A test profile talking to the stand-in server needs no real key: any non-empty key works there.
        if TestProfile.name != nil, TestProfile.lastfmBaseURLOverride != nil { return standIn }
        #endif
        return nil
    }

    static var isAvailable: Bool { pair != nil }

    /// Whether `key` is the built-in key (for wording that depends on which key a request used).
    static func isBuiltIn(key: String) -> Bool { pair?.key == key }

    private static func plistValue(_ name: String) -> String? { cleaned(Bundle.main.object(forInfoDictionaryKey: name)) }

    /// A value read from Info.plist, or nil when it is missing, blank or an unexpanded build setting.
    static func cleaned(_ raw: Any?) -> String? {
        let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset build setting reaches Info.plist unexpanded.
        guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    #if DEBUG
    /// The made-up pair used with the stand-in server; its secret is the one `scripts/fake-lastfm.py` signs with by default.
    static let standIn = Pair(key: "5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e", secret: "scrobblesecret")

    enum Override: Sendable {
        case none
        case pair(Pair)
        case unavailable
    }

    private static let override = OSAllocatedUnfairLock<Override>(initialState: .none)

    /// Replaces what this build has built in (checks only). Pass `.none` to go back to the real answer.
    static func useForTesting(_ value: Override) {
        override.withLock { $0 = value }
        LastfmCredentialsStore.dropCache()
    }
    #endif
}
