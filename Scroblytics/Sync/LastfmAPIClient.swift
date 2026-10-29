import Foundation

/// One play as returned by `user.getRecentTracks`, already filtered/flattened
/// to the fields the sync layer needs.
struct FetchedScrobble {
    let artist: String
    let album: String
    let track: String
    let imageURL: String?
    let uts: Int
}

/// A transient, undated track returned by `user.getRecentTracks` while it is
/// playing. It is intentionally distinct from `FetchedScrobble` so it cannot
/// enter the sync persistence path.
struct NowPlayingTrack: Hashable, Sendable {
    let artist: String
    let album: String
    let track: String
    let imageURL: String?

    var id: String {
        [artist, album, track]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\u{1f}")
    }
}

struct AlbumTracklist {
    /// Canonical album name as Last.fm returns it (after autocorrect).
    let album: String
    /// Canonical artist name as Last.fm returns it.
    let artist: String
    /// Ordered canonical track titles.
    let tracks: [String]
}

enum AlbumTracklistResult {
    case found(AlbumTracklist)
    case noMatch
}

struct AlbumSearchResult: Sendable, Hashable {
    let artist: String
    let album: String
}

struct SimilarArtist {
    let name: String
    /// Last.fm's similarity score, 0-1.
    let match: Double
}

struct SimilarTrack {
    let name: String
    let artist: String
    /// Last.fm's similarity score, 0-1.
    let match: Double
}

enum LastfmAPIError: Error {
    case http(Int)
    case api(code: Int, message: String)
    case decoding(Error)
    case network(Error)
    case invalidResponse
    /// A field Last.fm's API always includes in a well-formed response was
    /// missing or unparseable. Distinct from `.decoding` (a JSON shape
    /// mismatch) — this is "the JSON parsed fine, but a value inside it
    /// doesn't make sense." Deliberately thrown rather than silently
    /// defaulted: a default here (e.g. `totalPages` defaulting to 1) would
    /// look like a normal, small result instead of an error, silently
    /// truncating every future sync — the same failure shape that let
    /// `normalizeAlbumName`'s regex bug hide for an entire session.
    case malformedField(String)
}

extension LastfmAPIError: LocalizedError {
    /// Plain words for what went wrong and what to do. Last.fm's own message is kept for codes with no special wording.
    var errorDescription: String? {
        switch self {
        case .api(let code, let message):
            switch code {
            case 10: return "Last.fm doesn’t recognise this API key. Check it in Settings › Sync."
            case 26: return "Last.fm has suspended this API key."
            case 29: return "Last.fm is limiting requests from this connection, even after waiting several minutes. Wait a few minutes, then press Retry."
            case 17: return "Last.fm needs a login to show this data. If you hid your recent listening in your Last.fm privacy settings, that is the cause."
            case 4, 9: return "Last.fm rejected the session. Reconnect Track Actions in Settings › Sync."
            case 8, 11, 16: return "Last.fm is temporarily unavailable. Try again shortly."
            default: return "Last.fm error \(code): \(message)"
            }
        case .http(let status): return "Last.fm returned HTTP error \(status)."
        case .network(let underlying): return "Network error: \(underlying.localizedDescription)"
        case .decoding(let underlying): return "Couldn’t read Last.fm’s response: \(underlying)"
        case .invalidResponse: return "Last.fm sent a response the app couldn’t understand."
        case .malformedField(let detail): return "Last.fm’s response contained an unexpected value: \(detail)"
        }
    }
}

/// The text to show a person for any error from the sync, Last.fm or Keychain code paths.
func describeSyncError(_ error: Error) -> String {
    if error is CancellationError { return "Cancelled." }
    if let storeProblem = StoreProblem.describe(error) { return storeProblem }
    if let described = (error as? LocalizedError)?.errorDescription { return described }
    return error.localizedDescription
}

/// Transient Last.fm error codes worth retrying: 8 = operation failed,
/// 11 = service offline, 16 = temporary error, 29 = rate limit exceeded.
private let transientLastfmCodes: Set<Int> = [8, 11, 16, 29]

extension LastfmAPIError {
    /// Last.fm's "rate limit exceeded" (error 29).
    var isRateLimit: Bool {
        if case .api(let code, _) = self { return code == 29 }
        return false
    }
}

func isTransient(_ error: LastfmAPIError) -> Bool {
    switch error {
    case .network: return true
    case .api(let code, _): return transientLastfmCodes.contains(code)
    default: return false
    }
}

/// Where Last.fm requests go. A DEBUG run can point them at a stand-in server on this Mac
/// (`SCROBLYTICS_LASTFM_BASE_URL`, loopback only; see `TestProfile`) to test first-run and failure cases.
enum LastfmEndpoint {
    static let base: String = {
        #if DEBUG
        if let override = TestProfile.lastfmBaseURLOverride { return override }
        #endif
        return "https://ws.audioscrobbler.com/2.0/"
    }()
    static var host: String? { URL(string: base)?.host }
}

/// How the app keeps within Last.fm's request limit (about 5 requests a second per network address, averaged over five
/// minutes): it never sends two requests closer together than `minGap`, and after Last.fm answers "rate limit exceeded"
/// (error 29) it spaces them further apart for the rest of the session. Pure, so the arithmetic can be checked.
struct LastfmPacing: Sendable {
    var minGap: TimeInterval = 0.25
    var widenedGap: TimeInterval = 0.6
    private(set) var widened = false
    private var lastSlot: TimeInterval?

    /// How long to wait before a request that is ready at `now` may go, reserving its slot (so several waiting requests
    /// are spaced out one after another).
    mutating func delay(now: TimeInterval) -> TimeInterval {
        let gap = widened ? widenedGap : minGap
        let wait = lastSlot.map { max(0, $0 + gap - now) } ?? 0
        lastSlot = now + wait
        return wait
    }

    mutating func noteRateLimited() { widened = true }

    /// How long until a background request may be booked if it must come at least `gaps` gaps after the last booked request.
    func backgroundWait(now: TimeInterval, gaps: Double) -> TimeInterval {
        let gap = widened ? widenedGap : minGap
        return max(0, (lastSlot ?? -.infinity) + gap * gaps - now)
    }
}

/// One pacer for every Last.fm read in the app, so the history import and the background lookups (tags, popularity) share the
/// same budget. The import, and anything else a person is waiting for, goes first: while one has asked for a turn in the last few
/// seconds, a background lookup keeps twice the usual distance from the last booked request, so the import never queues behind it.
actor LastfmPacer {
    static let shared = LastfmPacer()
    private var pacing = LastfmPacing()
    private var lastForegroundAt: TimeInterval?
    /// How long after the last foreground request background lookups keep to the wider spacing.
    private static let foregroundWindow: TimeInterval = 3

    func waitForTurn(foreground: Bool) async throws {
        if foreground {
            lastForegroundAt = ProcessInfo.processInfo.systemUptime
        } else {
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                let foregroundActive = lastForegroundAt.map { now - $0 < Self.foregroundWindow } ?? false
                let wait = pacing.backgroundWait(now: now, gaps: foregroundActive ? 2 : 1)
                if wait <= 0.001 { break }
                try await Task.sleep(nanoseconds: UInt64(max(wait, 0.02) * 1_000_000_000))
            }
        }
        let wait = pacing.delay(now: ProcessInfo.processInfo.systemUptime)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    func noteRateLimited() { pacing.noteRateLimited() }
}

/// What to do when Last.fm answers "rate limit exceeded" (error 29): wait, then keep going, for up to `patience` in total.
/// The first wait is `waits[0]`, the next `waits[1]`, and so on (the last one repeats).
struct RateLimitPolicy: Sendable {
    var waits: [TimeInterval] = [30, 60]
    var patience: TimeInterval = 600

    func wait(afterRateLimits count: Int) -> TimeInterval { waits[min(count, waits.count - 1)] }

    /// The real policy; a DEBUG run can shrink every time by `SCROBLYTICS_RATELIMIT_TIME_SCALE` (e.g. 0.1) to test the waiting quickly.
    static let standard: RateLimitPolicy = {
        var policy = RateLimitPolicy()
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SCROBLYTICS_RATELIMIT_TIME_SCALE"], let scale = Double(raw), scale > 0 {
            policy.waits = policy.waits.map { $0 * scale }
            policy.patience *= scale
        }
        #endif
        return policy
    }()
}

/// Thin wrapper over Last.fm's REST API (page size, retry count, and backoff schedule below).
actor LastfmAPIClient {
    static let pageSize = 200
    static let maxRetries = 5

    private let apiKey: String
    let username: String
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let rateLimitPolicy: RateLimitPolicy

    init(apiKey: String, username: String, session: URLSession = .shared, rateLimitPolicy: RateLimitPolicy = .standard) {
        self.apiKey = apiKey
        self.username = username
        self.session = session
        self.rateLimitPolicy = rateLimitPolicy
    }

    struct Page {
        let scrobbles: [FetchedScrobble]
        let totalPages: Int
        let totalScrobbles: Int
    }

    /// Reads only Last.fm's transient now-playing row. This deliberately does
    /// not reuse the history-sync method, which filters that row out and
    /// requires timestamps and pagination totals suitable for persistence.
    func fetchNowPlaying() async throws -> NowPlayingTrack? {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "user.getRecentTracks"),
            .init(name: "user", value: username),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: "1"),
            .init(name: "page", value: "1"),
            .init(name: "extended", value: "0"),
        ]
        let response: RecentTracksResponse = try await request(queryItems: items)
        guard let raw = response.recenttracks.track.first,
              raw.attr?.nowplaying == "true" else { return nil }
        return NowPlayingTrack(
            artist: raw.artist.text,
            album: raw.album.text,
            track: raw.name,
            imageURL: pickImage(raw.image)
        )
    }

    /// One page of scrobble history. A transient failure is retried with a short backoff (1s, 2s, 4s, 8s). A rate limit (error 29)
    /// is different: the app waits as long as Last.fm needs (see `waitingOutRateLimits`) instead of giving up after a few seconds.
    func fetchRecentTracksPage(
        page: Int, from: Int? = nil, to: Int? = nil, onWait: (@Sendable (_ seconds: Int?) -> Void)? = nil
    ) async throws -> Page {
        try await waitingOutRateLimits(onWait: onWait) {
            var attempt = 0
            while true {
                attempt += 1
                do {
                    return try await fetchRecentTracksPageOnce(page: page, from: from, to: to)
                } catch let error as LastfmAPIError {
                    guard isTransient(error), !error.isRateLimit, attempt < Self.maxRetries else { throw error }
                    let delayMs = min(1000 * (1 << (attempt - 1)), 15_000)
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
            }
        }
    }

    /// Runs `body`; when Last.fm answers "rate limit exceeded" (error 29) waits (30 s, then 60 s each time, up to the policy's
    /// patience in total, 10 minutes) and tries again. `onWait` hears the length of each wait, and `nil` once a request goes
    /// through again, so the screen can say what is happening. Stopping cancels the wait at once. Past the patience the 29 is thrown.
    private func waitingOutRateLimits<T>(
        onWait: (@Sendable (_ seconds: Int?) -> Void)?, _ body: () async throws -> T
    ) async throws -> T {
        var rateLimits = 0
        var waited: TimeInterval = 0
        while true {
            do {
                let result = try await body()
                if rateLimits > 0 {
                    ActivityLog.record(.network, "Last.fm accepted requests again after waiting \(Int(waited)) s")
                    onWait?(nil)
                }
                return result
            } catch let error as LastfmAPIError where error.isRateLimit {
                let wait = rateLimitPolicy.wait(afterRateLimits: rateLimits)
                guard waited + wait <= rateLimitPolicy.patience else {
                    ActivityLog.record(.network, "Last.fm is still rate-limiting (error 29) after \(Int(waited)) s; giving up for now")
                    throw error
                }
                rateLimits += 1
                waited += wait
                ActivityLog.record(.network, "Last.fm rate limit (error 29): waiting \(Int(wait.rounded(.up))) s (wait \(rateLimits))")
                onWait?(Int(wait.rounded(.up)))
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private func fetchRecentTracksPageOnce(page: Int, from: Int?, to: Int?) async throws -> Page {
        var items: [URLQueryItem] = [
            .init(name: "method", value: "user.getRecentTracks"),
            .init(name: "user", value: username),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: String(Self.pageSize)),
            .init(name: "page", value: String(page)),
            .init(name: "extended", value: "0"),
        ]
        if let from { items.append(.init(name: "from", value: String(from))) }
        if let to { items.append(.init(name: "to", value: String(to))) }

        let response: RecentTracksResponse = try await request(queryItems: items, foreground: true)
        guard let totalPagesString = response.recenttracks.attr?.totalPages,
              let totalPages = Int(totalPagesString),
              let totalString = response.recenttracks.attr?.total,
              let totalScrobbles = Int(totalString) else {
            throw LastfmAPIError.malformedField("recenttracks.@attr totals missing or non-numeric")
        }

        let scrobbles = response.recenttracks.track
            .filter { $0.attr?.nowplaying != "true" && $0.date?.uts != nil }
            .compactMap { raw -> FetchedScrobble? in
                guard let utsString = raw.date?.uts, let uts = Int(utsString) else { return nil }
                return FetchedScrobble(
                    artist: raw.artist.text,
                    album: raw.album.text,
                    track: raw.name,
                    imageURL: pickImage(raw.image),
                    uts: uts
                )
            }
        return Page(scrobbles: scrobbles, totalPages: totalPages, totalScrobbles: totalScrobbles)
    }

    /// The account's name as Last.fm spells it and its total scrobbles (`user.getInfo`). Doubles as the check that a
    /// username and API key work together: an unknown user or a bad key comes back as an API error.
    func fetchUserInfo() async throws -> (name: String, playcount: Int) {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "user.getInfo"),
            .init(name: "user", value: username),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
        ]
        let response: UserInfoResponse = try await request(queryItems: items, foreground: true)
        guard let playcount = Int(response.user.playcount) else {
            throw LastfmAPIError.malformedField("user.playcount non-numeric: \(response.user.playcount)")
        }
        return (response.user.name ?? username, playcount)
    }

    /// The address of the account's profile picture (`user.getInfo`), the biggest size Last.fm lists, or nil when the account has none
    /// (Last.fm sends an empty address then).
    func fetchUserAvatarURL() async throws -> URL? {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "user.getInfo"),
            .init(name: "user", value: username),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
        ]
        let response: UserInfoResponse = try await waitingOutRateLimits(onWait: nil) { try await request(queryItems: items, foreground: true) }
        return Self.avatarURL(in: response.user.image ?? [])
    }

    private static func avatarURL(in images: [UserInfoResponse.UserImage]) -> URL? {
        for size in ["extralarge", "large", "medium", "small"] {
            if let text = images.first(where: { $0.size == size })?.url?.trimmingCharacters(in: .whitespaces),
               !text.isEmpty, let url = URL(string: text), url.scheme == "https" { return url }
        }
        return nil
    }

    /// The profile picture address from a raw `user.getInfo` answer (for checks).
    static func avatarURL(inUserInfo data: Data) -> URL? {
        (try? JSONDecoder().decode(UserInfoResponse.self, from: data)).flatMap { avatarURL(in: $0.user.image ?? []) }
    }

    /// Account-wide playcount, used to detect backdated plays after an
    /// incremental sync (`user.getInfo`).
    func fetchUserPlaycount() async throws -> Int {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "user.getInfo"),
            .init(name: "user", value: username),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
        ]
        let response: UserInfoResponse = try await waitingOutRateLimits(onWait: nil) { try await request(queryItems: items, foreground: true) }
        guard let playcount = Int(response.user.playcount) else {
            throw LastfmAPIError.malformedField("user.playcount non-numeric: \(response.user.playcount)")
        }
        return playcount
    }

    struct LovedTracksPage {
        let tracks: [(artist: String, track: String)]
        /// When each track in `tracks` was loved, in the same order (nil where Last.fm gave none).
        let dates: [Date?]
        let totalPages: Int
        /// `@attr.total` — how many loves the account has, as Last.fm counts them.
        let total: Int?
    }

    /// One page of the connected account's loved tracks (`user.getLovedTracks`)
    /// — read-only, needs only the public API key. Mirrors
    /// `fetchRecentTracksPage`'s page-size/shape conventions.
    func fetchLovedTracksPage(page: Int) async throws -> LovedTracksPage {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "user.getLovedTracks"),
            .init(name: "user", value: username),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: String(Self.pageSize)),
            .init(name: "page", value: String(page)),
        ]
        let response: LovedTracksResponse = try await request(queryItems: items, foreground: true)
        return try Self.lovedPage(from: response)
    }

    /// Reads a `user.getLovedTracks` answer (kept apart from the request so a check can feed it a canned one).
    static func lovedPage(fromJSON data: Data) throws -> LovedTracksPage {
        try lovedPage(from: JSONDecoder().decode(LovedTracksResponse.self, from: data))
    }

    private static func lovedPage(from response: LovedTracksResponse) throws -> LovedTracksPage {
        guard let totalPagesString = response.lovedtracks.attr?.totalPages,
              let totalPages = Int(totalPagesString) else {
            throw LastfmAPIError.malformedField("lovedtracks.@attr.totalPages missing or non-numeric")
        }
        let tracks = response.lovedtracks.track.map { (artist: $0.artist.name, track: $0.name) }
        let dates: [Date?] = response.lovedtracks.track.map { raw in
            raw.date.flatMap { Double($0.uts) }.map { Date(timeIntervalSince1970: $0) }
        }
        return LovedTracksPage(tracks: tracks, dates: dates, totalPages: totalPages, total: response.lovedtracks.attr?.total.flatMap(Int.init))
    }

    /// Community tags for an artist (`artist.getTopTags`), weight-sorted,
    /// lowercased, capped at `max`. Verified against real Last.fm responses
    /// (not just an assumed shape): `count` is a genuine JSON
    /// number (not a numeric string like `totalPages`/`playcount`), so
    /// Codable already fails loud on a type mismatch with no manual
    /// `Int(string)` parsing needed. Confirmed real cases: a normal multi-tag
    /// artist, a genuinely tag-less artist (`"tag": []`, not an absent key —
    /// a small local act), and an unknown-artist error (Last.fm error
    /// code 6, already handled generically by `request`'s error detection).
    /// Tag names came back mixed-case in every sample (e.g. "USA", "Shady"),
    /// confirming the `.lowercased()` normalization is required, not
    /// redundant.
    func fetchArtistTopTags(artist: String, max: Int = 20) async throws -> [String] {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "artist.getTopTags"),
            .init(name: "artist", value: artist),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "autocorrect", value: "1"),
        ]
        let response: TopTagsResponse = try await request(queryItems: items)
        return response.toptags.tag
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.count > $1.count }
            .prefix(max)
            .map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// The connected user's most-used personal tags (`user.getTopTags`). This
    /// is the authoritative vocabulary for tag-entry suggestions; unlike an
    /// entity's `getTags` response, it spans the user's whole Last.fm library.
    func fetchUserTopTags(max: Int = 500) async throws -> [String] {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "user.getTopTags"),
            .init(name: "user", value: username),
            .init(name: "limit", value: String(max)),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
        ]
        let response: TopTagsResponse = try await request(queryItems: items)
        return response.toptags.tag
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.count > $1.count }
            .prefix(max)
            .map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Community tags for an album (`album.getTopTags`) — same shape/weighting
    /// as `fetchArtistTopTags`, just a different entity-scoped endpoint.
    func fetchAlbumTopTags(artist: String, album: String, max: Int = 20) async throws -> [String] {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "album.getTopTags"),
            .init(name: "artist", value: artist),
            .init(name: "album", value: album),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "autocorrect", value: "1"),
        ]
        let response: TopTagsResponse = try await request(queryItems: items)
        return response.toptags.tag
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.count > $1.count }
            .prefix(max)
            .map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Community tags for a track (`track.getTopTags`).
    func fetchTrackTopTags(artist: String, track: String, max: Int = 20) async throws -> [String] {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "track.getTopTags"),
            .init(name: "artist", value: artist),
            .init(name: "track", value: track),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "autocorrect", value: "1"),
        ]
        let response: TopTagsResponse = try await request(queryItems: items)
        return response.toptags.tag
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.count > $1.count }
            .prefix(max)
            .map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// The connected account's own personal tags on an artist/album/track
    /// (`*.getTags` with a `user` param) — readable with just the API key and
    /// username, no signed session required. Signed writes (`addTags`/
    /// `removeTag`) are a separate, not-yet-built capability; this is
    /// read-only: readable without write access.
    func fetchUserTags(entity: TopChartsEntity, artist: String, album: String? = nil, track: String? = nil) async throws -> [String] {
        var items: [URLQueryItem] = [
            .init(name: "artist", value: artist),
            .init(name: "user", value: username),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "autocorrect", value: "1"),
        ]
        switch entity {
        case .artist:
            items.append(.init(name: "method", value: "artist.getTags"))
        case .album:
            items.append(.init(name: "method", value: "album.getTags"))
            items.append(.init(name: "album", value: album ?? ""))
        case .track:
            items.append(.init(name: "method", value: "track.getTags"))
            items.append(.init(name: "track", value: track ?? ""))
        }
        let response: UserTagsResponse = try await request(queryItems: items)
        return response.tags.tag
            .map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Everything the connected user has tagged with `tag`, for one kind of thing
    /// (`user.getPersonalTags`) — the bulk way to learn a personal tag's whole membership, instead of
    /// one `*.getTags` call per entity. Paginated; readable with just the API key and username.
    /// A tag with nothing tagged returns an empty list (Last.fm sends a `taggings` object with no
    /// items, or no `taggings` at all).
    func fetchPersonalTaggedItems(tag: String, kind: TopChartsEntity) async throws -> [(artist: String, name: String?)] {
        var found: [(artist: String, name: String?)] = []
        var page = 1
        var totalPages = 1
        while page <= totalPages {
            let items: [URLQueryItem] = [
                .init(name: "method", value: "user.getPersonalTags"),
                .init(name: "user", value: username),
                .init(name: "tag", value: tag),
                .init(name: "taggingtype", value: kind.rawValue),
                .init(name: "limit", value: "200"),
                .init(name: "page", value: String(page)),
                .init(name: "api_key", value: apiKey),
                .init(name: "format", value: "json"),
            ]
            let response: PersonalTagsResponse = try await request(queryItems: items)
            guard let taggings = response.taggings else { break }
            totalPages = Int(taggings.attr?.totalPages ?? "1") ?? 1
            switch kind {
            case .artist: found += taggings.artists.map { (artist: $0.name, name: nil) }
            case .album: found += taggings.albums.map { (artist: $0.artist.name, name: $0.name) }
            case .track: found += taggings.tracks.map { (artist: $0.artist.name, name: $0.name) }
            }
            page += 1
        }
        return found
    }

    /// Canonical tracklist for an album (`album.getInfo`). Distinguishes a
    /// genuine "Last.fm has no such album" (`.noMatch`, cacheable forever)
    /// from a transient failure (thrown, so the caller can retry — never
    /// cache a transient miss as permanent).
    ///
    /// Verified against real responses: `tracks.track[].@attr.rank` is a
    /// genuine JSON number in every sample checked (e.g. several popular
    /// albums) — NOT a string. Declared as a
    /// native `Int` so a real type mismatch fails loud instead of silently coercing.
    func fetchAlbumTracklist(artist: String, album: String) async throws -> AlbumTracklistResult {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "album.getInfo"),
            .init(name: "artist", value: artist),
            .init(name: "album", value: album),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "autocorrect", value: "1"),
        ]
        do {
            let response: AlbumInfoResponse = try await request(queryItems: items)
            let rawTracks = response.album.tracks?.track ?? []
            // Sort by Last.fm's own rank attribute rather than trusting array
            // order — album.getInfo has been observed to return tracks out of
            // sequence for some releases; falls back
            // to array position only when rank is genuinely absent, which is
            // an intentional recovery for a documented quirk, not a mask for
            // an unexpected failure.
            let ordered = rawTracks.enumerated()
                .sorted { ($0.element.attr?.rank ?? $0.offset) < ($1.element.attr?.rank ?? $1.offset) }
                .map(\.element)
            let titles = ordered
                .map { $0.name.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !titles.isEmpty else { return .noMatch }

            let canonicalAlbum = response.album.name?.trimmingCharacters(in: .whitespaces)
            let canonicalArtist = response.album.artist?.trimmingCharacters(in: .whitespaces)
            return .found(AlbumTracklist(
                album: (canonicalAlbum?.isEmpty == false) ? canonicalAlbum! : album,
                artist: (canonicalArtist?.isEmpty == false) ? canonicalArtist! : artist,
                tracks: titles
            ))
        } catch let error as LastfmAPIError {
            if case .api(let code, _) = error, !transientLastfmCodes.contains(code) {
                return .noMatch
            }
            throw error
        }
    }

    /// Alternate candidate albums for a name (`album.search`) — used by the
    /// "Fix album match…" UI to offer other plausible editions when the
    /// automatic classifier's single `album.getInfo` guess was ambiguous.
    /// Unlike `fetchAlbumTracklist`, this is a fuzzy text search (no
    /// `autocorrect`, since we WANT Last.fm's own ranked alternates, not a
    /// single corrected guess) and returns bare name/artist pairs, not full
    /// tracklists — the caller fetches a chosen candidate's tracklist
    /// separately via `fetchAlbumTracklist` once the user picks one. Same
    /// blanket-swallow rationale as `fetchSimilarArtists`: a failed search
    /// should present as "no alternates found," not crash the Fix UI.
    func searchAlbums(album: String, limit: Int = 10) async -> [AlbumSearchResult] {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "album.search"),
            .init(name: "album", value: album),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: String(limit)),
        ]
        do {
            let response: AlbumSearchResponse = try await request(queryItems: items)
            return response.results.albummatches.album
                .map { AlbumSearchResult(artist: $0.artist.trimmingCharacters(in: .whitespaces), album: $0.name.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.artist.isEmpty && !$0.album.isEmpty }
        } catch {
            return []
        }
    }

    /// Artists similar to `artistName` (`artist.getSimilar`), ranked by
    /// Last.fm's own match score. Deliberately swallows EVERY failure here
    /// (network, rate-limit, unknown artist, decode) into `[]` rather than
    /// throwing — a deliberate design for this specific call
    /// (`fetchSimilarArtists`/`fetchSimilarTracks` swallow Last.fm errors and
    /// return `[]`), which the caller compensates
    /// for at a higher level by checking whether ANY seed found ANY similar
    /// result at all before trusting an empty candidate pool. NOT a general
    /// exception to this codebase's fail-loud rule — see `LastfmMatchScore`.
    func fetchSimilarArtists(artist: String, limit: Int = 30) async -> [SimilarArtist] {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "artist.getSimilar"),
            .init(name: "artist", value: artist),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: String(limit)),
            .init(name: "autocorrect", value: "1"),
        ]
        do {
            let response: SimilarArtistsResponse = try await request(queryItems: items)
            return response.similarartists.artist
                .map { SimilarArtist(name: $0.name.trimmingCharacters(in: .whitespaces), match: $0.match.value) }
                .filter { !$0.name.isEmpty }
        } catch {
            return []
        }
    }

    /// An artist's most-played tracks on Last.fm (`artist.getTopTracks`), most played first. A failure reads as "none", like
    /// `fetchSimilarArtists`: it only widens a list that is useful without it.
    func fetchTopTracks(artist: String, limit: Int = 10) async -> [String] {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "artist.getTopTracks"),
            .init(name: "artist", value: artist),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: String(limit)),
            .init(name: "autocorrect", value: "1"),
        ]
        do {
            let response: TopTracksResponse = try await request(queryItems: items)
            return response.toptracks.track.map { $0.name.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    /// Like `fetchSimilarArtists`, but a failure (offline, rate limit, network) is thrown instead of looking like "nothing similar", so a
    /// caller that remembers answers never remembers a failure. Last.fm's "artist not found" (error 6) is a real, empty answer.
    func fetchSimilarArtistsChecked(artist: String, limit: Int = 30) async throws -> [SimilarArtist] {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "artist.getSimilar"),
            .init(name: "artist", value: artist),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: String(limit)),
            .init(name: "autocorrect", value: "1"),
        ]
        do {
            let response: SimilarArtistsResponse = try await request(queryItems: items)
            return response.similarartists.artist
                .map { SimilarArtist(name: $0.name.trimmingCharacters(in: .whitespaces), match: $0.match.value) }
                .filter { !$0.name.isEmpty }
        } catch LastfmAPIError.api(let code, _) where code == 6 {
            return []
        }
    }

    /// The checked form of `fetchSimilarTracks` (see `fetchSimilarArtistsChecked`).
    func fetchSimilarTracksChecked(artist: String, track: String, limit: Int = 100) async throws -> [SimilarTrack] {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "track.getSimilar"),
            .init(name: "artist", value: artist),
            .init(name: "track", value: track),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: String(limit)),
            .init(name: "autocorrect", value: "1"),
        ]
        do {
            let response: SimilarTracksResponse = try await request(queryItems: items)
            return response.similartracks.track
                .map { SimilarTrack(name: $0.name.trimmingCharacters(in: .whitespaces), artist: $0.artist.name.trimmingCharacters(in: .whitespaces), match: $0.match.value) }
                .filter { !$0.name.isEmpty && !$0.artist.isEmpty }
        } catch LastfmAPIError.api(let code, _) where code == 6 {
            return []
        }
    }

    /// Tracks similar to `artist`/`track` (`track.getSimilar`). Same
    /// blanket-swallow rationale as `fetchSimilarArtists`.
    func fetchSimilarTracks(artist: String, track: String, limit: Int = 50) async -> [SimilarTrack] {
        let items: [URLQueryItem] = [
            .init(name: "method", value: "track.getSimilar"),
            .init(name: "artist", value: artist),
            .init(name: "track", value: track),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: String(limit)),
            .init(name: "autocorrect", value: "1"),
        ]
        do {
            let response: SimilarTracksResponse = try await request(queryItems: items)
            return response.similartracks.track
                .map { SimilarTrack(name: $0.name.trimmingCharacters(in: .whitespaces), artist: $0.artist.name.trimmingCharacters(in: .whitespaces), match: $0.match.value) }
                .filter { !$0.name.isEmpty && !$0.artist.isEmpty }
        } catch {
            return []
        }
    }

    // MARK: - Popularity signals (listeners / playcount via *.getInfo)

    /// Global listener/playcount totals for an artist (`artist.getInfo`). One
    /// input to the popularity indicator (`PopularityStore`). `nil` is a
    /// genuine catalog miss (Last.fm error 6 etc.); a transient failure THROWS
    /// so the warmer retries instead of caching a false "no data".
    func fetchArtistPopularityStats(artist: String) async throws -> LastfmPopularityStats? {
        let response: ArtistStatsResponse? = try await requestStats(method: "artist.getInfo", extra: [.init(name: "artist", value: artist)])
        guard let stats = response?.artist?.stats else { return nil }
        return try LastfmPopularityStats(listeners: stats.listeners, playcount: stats.playcount)
    }

    /// `album.getInfo` listeners/playcount — see `fetchArtistPopularityStats`.
    func fetchAlbumPopularityStats(artist: String, album: String) async throws -> LastfmPopularityStats? {
        let response: AlbumStatsResponse? = try await requestStats(
            method: "album.getInfo",
            extra: [.init(name: "artist", value: artist), .init(name: "album", value: album)]
        )
        guard let info = response?.album else { return nil }
        return try LastfmPopularityStats(listeners: info.listeners, playcount: info.playcount)
    }

    /// `track.getInfo` listeners/playcount — see `fetchArtistPopularityStats`.
    func fetchTrackPopularityStats(artist: String, track: String) async throws -> LastfmPopularityStats? {
        let response: TrackStatsResponse? = try await requestStats(
            method: "track.getInfo",
            extra: [.init(name: "artist", value: artist), .init(name: "track", value: track)]
        )
        guard let info = response?.track else { return nil }
        return try LastfmPopularityStats(listeners: info.listeners, playcount: info.playcount)
    }

    private func requestStats<T: Decodable>(method: String, extra: [URLQueryItem]) async throws -> T? {
        let items: [URLQueryItem] = [.init(name: "method", value: method)] + extra + [
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "autocorrect", value: "1"),
        ]
        do {
            return try await request(queryItems: items) as T
        } catch let error as LastfmAPIError {
            // Permanent miss (bad name / not found) — a real "no data" answer.
            // Anything else (transient API code, HTTP, network, decode) throws.
            if case .api(let code, _) = error, !transientLastfmCodes.contains(code) { return nil }
            throw error
        }
    }

    // MARK: - Transport

    /// `foreground`: something a person is waiting for (the history import, the account check); it goes ahead of background
    /// lookups when the request budget is shared.
    private func request<T: Decodable>(queryItems: [URLQueryItem], foreground: Bool = false) async throws -> T {
        var components = URLComponents(string: LastfmEndpoint.base)!
        components.queryItems = queryItems
        guard let url = components.url else { throw LastfmAPIError.invalidResponse }
        try ConnectivityGate.check(host: url.host)
        try await LastfmPacer.shared.waitForTurn(foreground: foreground)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
            ConnectivityHub.reportSuccess()
        } catch {
            ConnectivityHub.report(error, host: url.host, source: "Last.fm")
            throw LastfmAPIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else { throw LastfmAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? decoder.decode(LastfmErrorResponse.self, from: data) {
                if apiError.error == 29 { await LastfmPacer.shared.noteRateLimited() }
                throw LastfmAPIError.api(code: apiError.error, message: apiError.message)
            }
            throw LastfmAPIError.http(http.statusCode)
        }
        if let apiError = try? decoder.decode(LastfmErrorResponse.self, from: data) {
            if apiError.error == 29 { await LastfmPacer.shared.noteRateLimited() }
            throw LastfmAPIError.api(code: apiError.error, message: apiError.message)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LastfmAPIError.decoding(error)
        }
    }
}

/// Prefers "extralarge" art, falling back to "large"; nil if neither has a
/// non-empty URL (no "medium"/"small" fallback).
private func pickImage(_ images: [LastfmImage]) -> String? {
    for size in ["extralarge", "large"] {
        if let found = images.first(where: { $0.size == size }), !found.text.isEmpty {
            return found.text
        }
    }
    return nil
}

// MARK: - Raw wire shapes

private struct LastfmTextField: Decodable {
    let text: String
    enum CodingKeys: String, CodingKey { case text = "#text" }
}

private struct LastfmImage: Decodable {
    let size: String
    let text: String
    enum CodingKeys: String, CodingKey { case size, text = "#text" }
}

private struct LastfmDateField: Decodable {
    let uts: String
}

private struct LastfmTrackAttr: Decodable {
    let nowplaying: String?
}

private struct LastfmRawTrack: Decodable {
    let name: String
    let artist: LastfmTextField
    let album: LastfmTextField
    let image: [LastfmImage]
    let date: LastfmDateField?
    let attr: LastfmTrackAttr?
    enum CodingKeys: String, CodingKey {
        case name, artist, album, image, date
        case attr = "@attr"
    }
}

/// `recenttracks.track` is a bare object (not an array) when there's exactly
/// one result — this decodes either shape into an array.
private struct RecentTracksResponse: Decodable {
    struct RecentTracks: Decodable {
        let track: [LastfmRawTrack]
        let attr: RecentTracksAttr?

        enum CodingKeys: String, CodingKey {
            case track
            case attr = "@attr"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.attr = try c.decodeIfPresent(RecentTracksAttr.self, forKey: .attr)
            // `track` is a bare object (not an array) when there's exactly one
            // result. Both shapes are expected; anything else is a genuine
            // decode failure and must propagate, not silently become "no
            // tracks on this page" — the same page-worth-of-scrobbles-vanish
            // risk as `totalPages` defaulting to 1.
            if let array = try? c.decode([LastfmRawTrack].self, forKey: .track) {
                self.track = array
            } else {
                self.track = [try c.decode(LastfmRawTrack.self, forKey: .track)]
            }
        }
    }
    struct RecentTracksAttr: Decodable {
        let totalPages: String?
        let page: String?
        let total: String?
    }
    let recenttracks: RecentTracks
}

/// `lovedtracks.track` is a bare object (not an array) when there's exactly
/// one result — same quirk as `recenttracks.track`, decoded the same way.
private struct LovedTracksResponse: Decodable {
    /// Unlike `recenttracks.track[].artist`, which nests under `"#text"`,
    /// `lovedtracks.track[].artist` nests under a plain `"name"` key —
    /// confirmed against the real API response shape, not assumed identical
    /// to the sibling endpoint.
    struct LovedTrackArtist: Decodable { let name: String }
    struct LovedTrackDate: Decodable { let uts: String }
    struct LovedTrackRaw: Decodable {
        let name: String
        let artist: LovedTrackArtist
        let date: LovedTrackDate?
    }
    struct LovedTracks: Decodable {
        let track: [LovedTrackRaw]
        let attr: RecentTracksResponse.RecentTracksAttr?

        enum CodingKeys: String, CodingKey {
            case track
            case attr = "@attr"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.attr = try c.decodeIfPresent(RecentTracksResponse.RecentTracksAttr.self, forKey: .attr)
            if let array = try? c.decode([LovedTrackRaw].self, forKey: .track) {
                self.track = array
            } else if let single = try? c.decode(LovedTrackRaw.self, forKey: .track) {
                self.track = [single]
            } else {
                self.track = []
            }
        }
    }
    let lovedtracks: LovedTracks
}

private struct UserInfoResponse: Decodable {
    struct UserField: Decodable {
        let playcount: String
        let name: String?
        /// The profile pictures by size. Read leniently: a shape Last.fm changes must never break the playcount this response is also used for.
        let image: [UserImage]?

        private enum CodingKeys: String, CodingKey { case playcount, name, image }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            playcount = try c.decode(String.self, forKey: .playcount)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            image = try? c.decodeIfPresent([UserImage].self, forKey: .image)
        }
    }
    struct UserImage: Decodable {
        let size: String?
        let url: String?
        private enum CodingKeys: String, CodingKey { case size; case url = "#text" }
    }
    let user: UserField
}

private struct LastfmErrorResponse: Decodable {
    let error: Int
    let message: String
}

private struct LastfmTag: Decodable {
    let name: String
    let count: Int

    private enum CodingKeys: String, CodingKey { case name, count }

    /// `artist/album/track.getTopTags` send `count` as a JSON number; `user.getTopTags` sends it as a
    /// numeric string. Either is fine — anything else is a genuine decode failure.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if let number = try? c.decode(Int.self, forKey: .count) {
            count = number
        } else {
            let text = try c.decode(String.self, forKey: .count)
            guard let number = Int(text) else {
                throw DecodingError.dataCorruptedError(forKey: .count, in: c, debugDescription: "count \"\(text)\" is not numeric")
            }
            count = number
        }
    }
}

private struct LastfmAlbumTrackAttr: Decodable {
    let rank: Int?
}

private struct LastfmAlbumTrack: Decodable {
    let name: String
    let attr: LastfmAlbumTrackAttr?
    enum CodingKeys: String, CodingKey {
        case name
        case attr = "@attr"
    }
}

private struct LastfmAlbumTracks: Decodable {
    let track: [LastfmAlbumTrack]
    enum CodingKeys: String, CodingKey { case track }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Same array-vs-bare-object quirk confirmed for recenttracks.track
        // and toptags.tag — it applies to this field too.
        if let array = try? c.decode([LastfmAlbumTrack].self, forKey: .track) {
            self.track = array
        } else {
            self.track = [try c.decode(LastfmAlbumTrack.self, forKey: .track)]
        }
    }
}

private struct LastfmAlbumInfo: Decodable {
    let name: String?
    let artist: String?
    let tracks: LastfmAlbumTracks?
}

/// Last.fm's global totals for one entity — `nil` per field only when Last.fm
/// omitted it. A field that is present but not an integer throws
/// `LastfmAPIError.malformedField` rather than silently becoming `nil`.
struct LastfmPopularityStats: Sendable {
    let listeners: Int?
    let playcount: Int?

    fileprivate init(listeners: String?, playcount: String?) throws {
        self.listeners = try Self.parse(listeners, field: "listeners")
        self.playcount = try Self.parse(playcount, field: "playcount")
    }

    private static func parse(_ raw: String?, field: String) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            throw LastfmAPIError.malformedField("\(field) was not an integer: \(raw)")
        }
        return value
    }
}

private struct ArtistStatsResponse: Decodable {
    struct Artist: Decodable {
        struct Stats: Decodable { let listeners: String?; let playcount: String? }
        let stats: Stats?
    }
    let artist: Artist?
}

private struct AlbumStatsResponse: Decodable {
    struct Album: Decodable { let listeners: String?; let playcount: String? }
    let album: Album?
}

private struct TrackStatsResponse: Decodable {
    struct Track: Decodable { let listeners: String?; let playcount: String? }
    let track: Track?
}

private struct AlbumInfoResponse: Decodable {
    let album: LastfmAlbumInfo
}

private struct LastfmAlbumMatch: Decodable {
    let name: String
    let artist: String
}

private struct AlbumMatches: Decodable {
    let album: [LastfmAlbumMatch]
    enum CodingKeys: String, CodingKey { case album }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Same array-vs-bare-object quirk as `LastfmAlbumTracks.track` — a
        // search with exactly one match collapses `album` to a bare object.
        if let array = try? c.decode([LastfmAlbumMatch].self, forKey: .album) {
            self.album = array
        } else if let single = try? c.decode(LastfmAlbumMatch.self, forKey: .album) {
            self.album = [single]
        } else {
            self.album = []
        }
    }
}

private struct AlbumSearchResults: Decodable {
    let albummatches: AlbumMatches
}

private struct AlbumSearchResponse: Decodable {
    let results: AlbumSearchResults
}

private struct TopTagsResponse: Decodable {
    struct TopTags: Decodable {
        let tag: [LastfmTag]
        enum CodingKeys: String, CodingKey { case tag }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Bare object instead of a single-element array when there's
            // exactly one tag (same XML->JSON quirk already confirmed for
            // recenttracks.track). Anything matching neither shape is a
            // genuine decode failure and must propagate — deliberately no
            // "key absent -> []" fallback: the real zero-tags case observed
            // from Last.fm is `"tag": []` (present, empty), not an absent key,
            // so tolerating absence would be assuming leniency for a case
            // with no supporting evidence.
            if let array = try? c.decode([LastfmTag].self, forKey: .tag) {
                self.tag = array
            } else {
                self.tag = [try c.decode(LastfmTag.self, forKey: .tag)]
            }
        }
    }
    let toptags: TopTags
}

/// `*.getTags`' personal-tag shape — no `count` field (unlike `toptags.tag`,
/// this is one user's own tags, not a weighted aggregate). Same bare-object-
/// vs-array quirk as everywhere else in this API.
private struct LastfmUserTag: Decodable {
    let name: String
}

/// `user.getPersonalTags`. Last.fm sends a single item as a bare object rather than a one-element
/// array, and omits the group entirely when empty — every group decodes to a plain array.
private struct PersonalTagsResponse: Decodable {
    struct NamedItem: Decodable { let name: String }
    struct ArtistedItem: Decodable {
        let name: String
        let artist: NamedItem
    }
    struct Attr: Decodable { let totalPages: String? }

    struct Taggings: Decodable {
        let artists: [NamedItem]
        let albums: [ArtistedItem]
        let tracks: [ArtistedItem]
        let attr: Attr?

        private enum CodingKeys: String, CodingKey { case artists, albums, tracks; case attr = "@attr" }
        private struct ArtistGroup: Decodable { let artist: OneOrMany<NamedItem>? }
        private struct AlbumGroup: Decodable { let album: OneOrMany<ArtistedItem>? }
        private struct TrackGroup: Decodable { let track: OneOrMany<ArtistedItem>? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            artists = (try c.decodeIfPresent(ArtistGroup.self, forKey: .artists)?.artist?.items) ?? []
            albums = (try c.decodeIfPresent(AlbumGroup.self, forKey: .albums)?.album?.items) ?? []
            tracks = (try c.decodeIfPresent(TrackGroup.self, forKey: .tracks)?.track?.items) ?? []
            attr = try c.decodeIfPresent(Attr.self, forKey: .attr)
        }
    }

    let taggings: Taggings?

    private enum CodingKeys: String, CodingKey { case taggings }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A tag with nothing tagged can come back as `"taggings": ""` rather than an object.
        taggings = try? c.decodeIfPresent(Taggings.self, forKey: .taggings)
    }
}

/// A JSON value that is either one object or an array of them.
private struct OneOrMany<T: Decodable>: Decodable {
    let items: [T]
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let many = try? single.decode([T].self) { items = many }
        else { items = [try single.decode(T.self)] }
    }
}

private struct UserTagsResponse: Decodable {
    struct Tags: Decodable {
        let tag: [LastfmUserTag]
        enum CodingKeys: String, CodingKey { case tag }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let array = try? c.decode([LastfmUserTag].self, forKey: .tag) {
                self.tag = array
            } else if let single = try? c.decode(LastfmUserTag.self, forKey: .tag) {
                self.tag = [single]
            } else {
                self.tag = []
            }
        }
        init(tag: [LastfmUserTag]) { self.tag = tag }
    }
    let tags: Tags

    enum CodingKeys: String, CodingKey { case tags }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Not live-verified for this specific endpoint (unlike toptags.tag's
        // confirmed-empty-array shape above) — Last.fm is known to return an
        // empty string instead of an object for an empty collection on some
        // sibling endpoints, so this tolerates that rather than crashing the
        // whole tags section on what may be a legitimate "no personal tags
        // yet" result.
        if let parsed = try? c.decode(Tags.self, forKey: .tags) {
            self.tags = parsed
        } else {
            self.tags = Tags(tag: [])
        }
    }
}

/// Last.fm's `match` field for a similar-artist/track result has TWO
/// different real wire types across these two endpoints — confirmed via
/// live calls, not assumed:
/// a genuine numeric STRING on `artist.getSimilar` (`"0.953170"`), but a
/// genuine JSON NUMBER on `track.getSimilar` (`0.940238`). Decodes either
/// shape. Defaults to 0 only on a value that's neither — a deliberate
/// leniency for this specific field, not a general exception to this
/// codebase's fail-loud rule: a similarity
/// score feeding a randomized suggestion card is low-stakes (worst case one
/// candidate is under-ranked), unlike totalPages/tag-count/album-rank,
/// where a wrong value silently corrupts a real stat.
private struct LastfmMatchScore: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self) {
            value = Double(s) ?? 0
        } else {
            value = 0
        }
    }
}

private struct LastfmSimilarArtistRaw: Decodable {
    let name: String
    let match: LastfmMatchScore
}

/// `similarartists.artist` — every live sample checked (including
/// `limit=1`) came back as a real array, unlike the bare-object-on-single-
/// result quirk confirmed elsewhere (recenttracks.track, toptags.tag,
/// album tracks). Kept defensive anyway, at no cost, for consistency.
private struct SimilarArtistsResponse: Decodable {
    struct Payload: Decodable {
        let artist: [LastfmSimilarArtistRaw]
        enum CodingKeys: String, CodingKey { case artist }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let array = try? c.decode([LastfmSimilarArtistRaw].self, forKey: .artist) {
                self.artist = array
            } else if let single = try? c.decode(LastfmSimilarArtistRaw.self, forKey: .artist) {
                self.artist = [single]
            } else {
                self.artist = []
            }
        }
    }
    let similarartists: Payload
}

private struct LastfmTopTrackRaw: Decodable {
    let name: String
}

/// `toptracks.track` is an array, or a bare object when the artist has exactly one.
private struct TopTracksResponse: Decodable {
    struct Payload: Decodable {
        let track: [LastfmTopTrackRaw]
        enum CodingKeys: String, CodingKey { case track }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let array = try? c.decode([LastfmTopTrackRaw].self, forKey: .track) {
                self.track = array
            } else if let single = try? c.decode(LastfmTopTrackRaw.self, forKey: .track) {
                self.track = [single]
            } else {
                self.track = []
            }
        }
    }
    let toptracks: Payload
}

private struct LastfmSimilarTrackArtist: Decodable {
    let name: String
}

private struct LastfmSimilarTrackRaw: Decodable {
    let name: String
    let artist: LastfmSimilarTrackArtist
    let match: LastfmMatchScore
}

private struct SimilarTracksResponse: Decodable {
    struct Payload: Decodable {
        let track: [LastfmSimilarTrackRaw]
        enum CodingKeys: String, CodingKey { case track }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let array = try? c.decode([LastfmSimilarTrackRaw].self, forKey: .track) {
                self.track = array
            } else if let single = try? c.decode(LastfmSimilarTrackRaw.self, forKey: .track) {
                self.track = [single]
            } else {
                self.track = []
            }
        }
    }
    let similartracks: Payload
}
