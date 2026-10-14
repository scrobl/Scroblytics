import AppKit
import Foundation
import os
import Security

/// GetSongBPM's search API (api.getsong.co) — the first source for a track's tempo, with Deezer as the fallback.
/// The free tier allows 3,000 requests an hour for the whole key, and requires the credit shown in Settings › Tempo.
/// The app's own key is injected at build time from the git-ignored `Config/Secrets.xcconfig` into Info.plist, so it
/// is never in the source. A key a user saves in the Keychain takes its place. With neither, tempos come from Deezer
/// alone.
enum GetSongBPMKeychain {
    /// The key baked into this build, if any.
    static var builtInKey: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "GetSongBPMAPIKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset build setting reaches Info.plist unexpanded.
        guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    /// The key to use: the user's own, else the built-in one.
    static func activeKey() -> String? { key() ?? builtInKey }

    private static let service = AppIdentity.keychainService("getsongbpm")
    private static let account = "apiKey"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    typealias RawRead = @Sendable () -> (status: OSStatus, data: Data?)

    /// What is known about the saved key. Every tempo lookup asks for it, so the answer is kept for the session once the Keychain has
    /// given a definite one, including "no key saved" (the usual case, where the built-in key is used). A read that failed (a locked
    /// keychain, a refused prompt) is remembered for a minute, not for good: lookups run in a loop, and without that each would ask
    /// the Keychain, and so prompt, again.
    private enum Known {
        case unknown
        case answer(String?)
        case failed(Date)
    }

    static let failureMemory: TimeInterval = 60

    private static let known = OSAllocatedUnfairLock(initialState: Known.unknown)
    private static let readGate = NSLock()
    private static let rawReader = OSAllocatedUnfairLock<RawRead>(initialState: defaultRawRead())
    /// Registers the activation observer the first time it is touched, so a key saved or removed by another copy of the app is noticed.
    private static let observesActivation: Bool = {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            known.withLock { $0 = .unknown }
        }
        return true
    }()

    static func key() -> String? {
        _ = observesActivation
        if let remembered = remembered() { return remembered.key }
        readGate.lock()
        defer { readGate.unlock() }
        if let remembered = remembered() { return remembered.key }
        let raw = rawReader.withLock { $0 }()
        switch raw.status {
        case errSecSuccess:
            let text = raw.data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = text?.isEmpty == false ? text : nil
            known.withLock { $0 = .answer(key) }
            return key
        case errSecItemNotFound:
            known.withLock { $0 = .answer(nil) }
            return nil
        default:
            known.withLock { $0 = .failed(Date()) }
            return nil
        }
    }

    /// A kept answer (possibly "no key"), or nil when the Keychain has to be asked.
    private struct Remembered { let key: String? }

    private static func remembered() -> Remembered? {
        switch known.withLock({ $0 }) {
        case .answer(let key): return Remembered(key: key)
        case .failed(let when) where Date().timeIntervalSince(when) < failureMemory: return Remembered(key: nil)
        default: return nil
        }
    }

    private static func defaultRawRead() -> RawRead {
        let service = service, account = account
        return {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
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
        known.withLock { $0 = .unknown }
    }
    #endif

    static var hasKey: Bool { key() != nil }

    static func setKey(_ key: String) throws {
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw GetSongBPMError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw GetSongBPMError.keychain(status)
        }
        let trimmed = String(decoding: data, as: UTF8.self)
        known.withLock { $0 = .answer(trimmed.isEmpty ? nil : trimmed) }
    }

    static func removeKey() {
        SecItemDelete(query as CFDictionary)
        known.withLock { $0 = .answer(nil) }
    }
}

enum GetSongBPMError: Error {
    case http(Int)
    case api(String)
    /// The key was refused — nothing else this session will succeed either.
    case invalidKey
    case network(Error)
    case invalidResponse
    case keychain(OSStatus)
}

extension GetSongBPMError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidKey: "GetSongBPM didn’t accept the API key."
        case .keychain(let status): "The key couldn’t be saved to the Keychain (error \(status))."
        case .http(let code): "GetSongBPM answered with HTTP \(code)."
        case .api(let message): "GetSongBPM said: \(message)"
        case .network: "GetSongBPM couldn’t be reached."
        case .invalidResponse: "GetSongBPM sent a reply that couldn’t be read."
        }
    }
}

struct GetSongBPMFeatures: Sendable, Equatable {
    let bpm: Double
    let timeSignature: String?
    let musicalKey: String?
}

actor GetSongBPMClient {
    private let session: URLSession
    private let apiKey: String

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Looks a track up by title and artist. `nil` is a genuine miss (no result, or only results by a different
    /// artist or with a different title); network, HTTP and API failures throw so they are retried and never cached
    /// as a miss. Retries once with `(...)`/`[...]` tags stripped when the full title finds nothing.
    func fetchFeatures(artist: String, track: String) async throws -> GetSongBPMFeatures? {
        if let found = try await search(artist: artist, track: track) { return found }
        let bare = Self.stripAnnotations(track)
        if !bare.isEmpty, bare != track { return try await search(artist: artist, track: bare) }
        return nil
    }

    private func search(artist: String, track: String) async throws -> GetSongBPMFeatures? {
        var components = URLComponents(string: "https://api.getsong.co/search/")!
        components.queryItems = [
            .init(name: "api_key", value: apiKey),
            // "both" is the documented combined song + artist lookup.
            .init(name: "type", value: "both"),
            .init(name: "lookup", value: "song:\(track) artist:\(artist)"),
        ]
        let songs = try await request(components.url!)
        for song in songs where Self.isSameSong(song, artist: artist, track: track) {
            if let bpm = song.tempo, bpm > 0 {
                return GetSongBPMFeatures(bpm: bpm, timeSignature: song.timeSignature, musicalKey: song.key)
            }
        }
        return nil
    }

    /// The service ranks by text similarity, so the first hit can be a different artist's song of the same name.
    nonisolated static func isSameSong(_ song: Song, artist: String, track: String) -> Bool {
        guard TextNormalization.trackMatchesArtistContext(trackArtist: song.artist, context: artist) else { return false }
        return comparable(song.title) == comparable(track) || comparable(stripAnnotations(song.title)) == comparable(stripAnnotations(track))
    }

    nonisolated static func comparable(_ title: String) -> String {
        String(TextNormalization.normalizeTrackTitle(title).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    nonisolated static func stripAnnotations(_ title: String) -> String {
        var result = title.replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s*\[[^\]]*\]\s*"#, with: " ", options: .regularExpression)
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Transport

    struct Song: Sendable {
        let title: String
        let artist: String
        let tempo: Double?
        let timeSignature: String?
        let key: String?
    }

    /// `search` is an array of songs on a hit but an `{"error": "no result"}` object on a miss; real failures
    /// (a bad key, a malformed query) come back as a top-level `error`.
    private struct Response: Decodable {
        struct RawSong: Decodable {
            struct Artist: Decodable { let name: String? }
            let title: String?
            let artist: Artist?
            let tempo: FlexibleString?
            let timeSig: FlexibleString?
            let keyOf: String?

            enum CodingKeys: String, CodingKey { case title, artist, tempo, timeSig = "time_sig", keyOf = "key_of" }
        }
        struct SearchError: Decodable { let error: String? }

        let songs: [RawSong]
        let searchError: String?
        let error: String?

        enum CodingKeys: String, CodingKey { case search, error }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = try container.decodeIfPresent(String.self, forKey: .error)
            if let songs = try? container.decode([RawSong].self, forKey: .search) {
                self.songs = songs
                searchError = nil
            } else {
                songs = []
                searchError = (try? container.decode(SearchError.self, forKey: .search))?.error
            }
        }
    }

    /// The service sends numbers as either strings or numbers depending on the field.
    private struct FlexibleString: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) { value = string }
            else if let number = try? container.decode(Double.self) { value = String(number) }
            else { throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "not a string or number")) }
        }
    }

    private func request(_ url: URL) async throws -> [Song] {
        try ConnectivityGate.check(host: url.host)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
            ConnectivityHub.reportSuccess()
        } catch {
            ConnectivityHub.report(error, host: url.host, source: "GetSongBPM")
            throw GetSongBPMError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw GetSongBPMError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw GetSongBPMError.http(http.statusCode) }
        return try Self.parse(data)
    }

    /// Reads a search reply: the songs on a hit, an empty list on a genuine miss, a thrown error on a real failure.
    nonisolated static func parse(_ data: Data) throws -> [Song] {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw GetSongBPMError.invalidResponse }
        if let message = decoded.error {
            if message.localizedCaseInsensitiveContains("api key") { throw GetSongBPMError.invalidKey }
            throw GetSongBPMError.api(message)
        }
        // A miss is reported inside `search`; anything but "no result" there is a real failure.
        if let message = decoded.searchError, !message.localizedCaseInsensitiveContains("no result") {
            throw GetSongBPMError.api(message)
        }
        return decoded.songs.map {
            Song(
                title: $0.title ?? "", artist: $0.artist?.name ?? "", tempo: $0.tempo.flatMap { Double($0.value) },
                timeSignature: $0.timeSig?.value, key: $0.keyOf
            )
        }
    }
}
