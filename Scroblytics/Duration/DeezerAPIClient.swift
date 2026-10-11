import Foundation

/// Deezer's public search API — no auth required. The sole source this app
/// resolves track duration from: Last.fm (no duration field on scrobbles),
/// MusicBrainz, and Apple Music are never consulted automatically for
/// duration. The five lookup tiers are five query-string strategies against
/// this one API, not five services.
enum DeezerAPIError: Error {
    case http(Int)
    case api(message: String)
    case network(Error)
    case invalidResponse
}

actor DeezerAPIClient {
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    private struct TrackResult: Decodable {
        let id: Int?
        let duration: Int?
        let rank: Int?
        let title: String?
        let artist: AlbumArtist?
        let album: TrackResultAlbum?
    }

    private struct TrackDetailResponse: Decodable {
        let bpm: Double?
        let error: DeezerErrorPayload?
    }

    private struct TrackResultAlbum: Decodable {
        let id: Int?
    }

    private struct AlbumDetailResponse: Decodable {
        let releaseDate: String?
        let error: DeezerErrorPayload?
        enum CodingKeys: String, CodingKey {
            case releaseDate = "release_date"
            case error
        }
    }

    private struct TrackSearchResponse: Decodable {
        let data: [TrackResult]?
        let error: DeezerErrorPayload?
    }

    private struct AlbumResult: Decodable {
        let id: Int?
        let coverMedium: String?
        let coverBig: String?
        let coverXL: String?
        let artist: AlbumArtist?

        enum CodingKeys: String, CodingKey {
            case id, artist
            case coverMedium = "cover_medium"
            case coverBig = "cover_big"
            case coverXL = "cover_xl"
        }
    }

    private struct AlbumArtist: Decodable {
        let name: String?
    }

    private struct AlbumSearchResponse: Decodable {
        let data: [AlbumResult]?
        let error: DeezerErrorPayload?
    }

    private struct ArtistResult: Decodable {
        let name: String?
        let nbFan: Int?
        let pictureMedium: String?
        let pictureBig: String?
        let pictureXL: String?

        enum CodingKeys: String, CodingKey {
            case name
            case nbFan = "nb_fan"
            case pictureMedium = "picture_medium"
            case pictureBig = "picture_big"
            case pictureXL = "picture_xl"
        }
    }

    private struct AlbumFansResponse: Decodable {
        let fans: Int?
        let error: DeezerErrorPayload?
    }

    private struct ArtistSearchResponse: Decodable {
        let data: [ArtistResult]?
        let error: DeezerErrorPayload?
    }

    private struct AlbumTrack: Decodable {
        let title: String?
        let duration: Int?
    }

    private struct AlbumTracklistResponse: Decodable {
        let data: [AlbumTrack]?
        let error: DeezerErrorPayload?
    }

    private struct DeezerErrorPayload: Decodable {
        let message: String?
        let type: String?
    }

    /// Fetches a track's duration — five-tier retry order, with a
    /// transient-vs-genuine-miss contract:
    /// a genuine "Deezer has no such track" returns `nil`; a network/HTTP/
    /// rate-limit failure at ANY tier throws immediately rather than falling
    /// through to the next tier (a transient failure must never be cached as
    /// a false miss — caching one poisoned the cache with ~77% false negatives
    /// during bulk warm-up).
    ///
    /// 1. Exact quoted `artist:"X" track:"Y"` — Deezer's own field-scoped query.
    /// 2. Unquoted `"artist track"` fallback — the quoted form returns zero
    ///    results for some real, well-known tracks with long titles.
    /// 3. Bare-title retry with `(...)`/`[...]` annotations stripped — Deezer's
    ///    parser chokes on parenthesized/bracketed feature/version tags.
    /// 4. Apostrophe-spaced retry — Deezer's parser also chokes on apostrophes
    ///    ("What Might've Been" vs. Deezer's "What Might Have Been").
    /// 5. Album-tracklist fallback, when an album name is supplied — some
    ///    tracks simply aren't indexed by track search at all even though the
    ///    album's own tracklist carries them with a real duration.
    func fetchTrackDuration(artist: String, track: String, album: String?) async throws -> Int? {
        if let exact = try await searchTrack(query: "artist:\"\(artist)\" track:\"\(track)\""), let duration = exact.duration, duration > 0 {
            return duration
        }

        if let fallback = try await searchTrack(query: "\(artist) \(track)"), let duration = fallback.duration, duration > 0 {
            return duration
        }

        let bareTitle = stripParentheticalAnnotations(track)
        if !bareTitle.isEmpty, bareTitle != track {
            if let stripped = try await searchTrack(query: "\(artist) \(bareTitle)"), let duration = stripped.duration, duration > 0 {
                return duration
            }
        }

        let spacedTitle = spaceOutApostrophes(track)
        if !spacedTitle.isEmpty, spacedTitle != track, spacedTitle != bareTitle {
            if let spaced = try await searchTrack(query: "\(artist) \(spacedTitle)"), let duration = spaced.duration, duration > 0 {
                return duration
            }
        }

        if let album, !album.isEmpty {
            if let fromAlbum = try await durationFromAlbumTracklist(artist: artist, album: album, track: track) {
                return fromAlbum
            }
        }

        return nil
    }

    /// Fetches a track's tempo. Search results carry no `bpm`, so this finds the track (exact, then unquoted, then
    /// with `(...)`/`[...]` tags stripped) and reads its full record. A result by a different artist is skipped — a
    /// wrong tempo is worse than none. Deezer reports 0 when it never detected one, which is a genuine miss (`nil`);
    /// a network or API failure throws so it is never cached as one.
    func fetchTrackBPM(artist: String, track: String) async throws -> Double? {
        let bareTitle = stripParentheticalAnnotations(track)
        var queries = ["artist:\"\(artist)\" track:\"\(track)\"", "\(artist) \(track)"]
        if !bareTitle.isEmpty, bareTitle != track { queries.append("\(artist) \(bareTitle)") }
        for query in queries {
            guard let match = try await searchTrack(query: query), let id = match.id,
                  TextNormalization.trackMatchesArtistContext(trackArtist: match.artist?.name ?? "", context: artist) else { continue }
            let response: TrackDetailResponse = try await request(url: URL(string: "https://api.deezer.com/track/\(id)")!)
            if let error = response.error { throw DeezerAPIError.api(message: error.message ?? error.type ?? "unknown") }
            if let bpm = response.bpm, bpm > 0 { return bpm }
            return nil
        }
        return nil
    }

    func fetchArtistImageURL(artist: String) async throws -> URL? {
        var components = URLComponents(string: "https://api.deezer.com/search/artist")!
        components.queryItems = [.init(name: "q", value: artist), .init(name: "limit", value: "5")]
        let response: ArtistSearchResponse = try await request(url: components.url!)
        if let error = response.error { throw DeezerAPIError.api(message: error.message ?? error.type ?? "unknown") }
        let normalizedArtist = normalizeForDeezerMatch(artist)
        guard let results = response.data, let match = results.first(where: {
            normalizeForDeezerMatch($0.name ?? "") == normalizedArtist
        }) else { return nil }
        return (match.pictureXL ?? match.pictureBig ?? match.pictureMedium).flatMap(URL.init(string:))
    }

    func fetchAlbumImageURL(artist: String, album: String) async throws -> URL? {
        var components = URLComponents(string: "https://api.deezer.com/search/album")!
        components.queryItems = [
            .init(name: "q", value: "artist:\"\(artist)\" album:\"\(album)\""),
            .init(name: "limit", value: "20"),
        ]
        let response: AlbumSearchResponse = try await request(url: components.url!)
        if let error = response.error { throw DeezerAPIError.api(message: error.message ?? error.type ?? "unknown") }
        let normalizedArtist = normalizeForDeezerMatch(artist)
        guard let results = response.data, let match = results.first(where: {
            normalizeForDeezerMatch($0.artist?.name ?? "") == normalizedArtist
        }) else { return nil }
        return (match.coverXL ?? match.coverBig ?? match.coverMedium).flatMap(URL.init(string:))
    }

    /// Fallback album release date, used only when MusicBrainz has no match
    /// at all (see `ReleaseDateEngine`) — Deezer's per-edition `release_date`
    /// can reflect the wrong pressing/reissue, so it's never the primary
    /// source. `nil` is a genuine "Deezer has no such album" miss.
    func fetchAlbumReleaseDate(artist: String, album: String) async throws -> String? {
        guard let albumId = try await searchAlbumId(artist: artist, album: album) else { return nil }
        return try await fetchAlbumReleaseDate(albumId: albumId)
    }

    /// Direct per-track release date via the track's own album — used only
    /// for the rare track with no locally-observed album at all (see
    /// `ReleaseDateEngine`); every other track's date comes from its primary
    /// album instead, resolved through MusicBrainz first.
    func fetchTrackReleaseDate(artist: String, track: String) async throws -> String? {
        guard let result = try await searchTrack(query: "artist:\"\(artist)\" track:\"\(track)\""),
              let albumId = result.album?.id else { return nil }
        return try await fetchAlbumReleaseDate(albumId: albumId)
    }

    private func fetchAlbumReleaseDate(albumId: Int) async throws -> String? {
        let url = URL(string: "https://api.deezer.com/album/\(albumId)")!
        let response: AlbumDetailResponse = try await request(url: url)
        if let error = response.error {
            throw DeezerAPIError.api(message: error.message ?? error.type ?? "unknown")
        }
        return response.releaseDate
    }

    // MARK: - Popularity signals

    /// Deezer fan count for an artist — one input to the popularity indicator
    /// (`PopularityStore`). `nil` is a genuine miss; network/HTTP/quota
    /// failures THROW so the warmer retries rather than caching a false "no
    /// data" (same contract as the fetchers above). Prefers a result whose name
    /// matches the artist (a common name can rank a different artist first),
    /// falling back to the top result.
    func fetchArtistFans(artist: String) async throws -> Int? {
        var components = URLComponents(string: "https://api.deezer.com/search/artist")!
        components.queryItems = [.init(name: "q", value: artist), .init(name: "limit", value: "5")]
        let response: ArtistSearchResponse = try await request(url: components.url!)
        if let error = response.error { throw DeezerAPIError.api(message: error.message ?? error.type ?? "unknown") }
        guard let results = response.data, !results.isEmpty else { return nil }
        let target = normalizeForDeezerMatch(artist)
        let match = results.first { normalizeForDeezerMatch($0.name ?? "") == target } ?? results[0]
        return match.nbFan
    }

    /// Deezer fan count for an album, via the same artist-preferring album
    /// search as release dates, then a second request for the matched album
    /// (search results omit `fans`).
    func fetchAlbumFans(artist: String, album: String) async throws -> Int? {
        guard let albumId = try await searchAlbumId(artist: artist, album: album) else { return nil }
        let url = URL(string: "https://api.deezer.com/album/\(albumId)")!
        let response: AlbumFansResponse = try await request(url: url)
        if let error = response.error { throw DeezerAPIError.api(message: error.message ?? error.type ?? "unknown") }
        return response.fans
    }

    /// Deezer's track `rank` — an internal, unscaled popularity score, only
    /// meaningful for relative comparison.
    func fetchTrackRank(artist: String, track: String) async throws -> Int? {
        try await searchTrack(query: "artist:\"\(artist)\" track:\"\(track)\"")?.rank
    }

    // MARK: - Tier implementations

    private func searchTrack(query: String) async throws -> TrackResult? {
        var components = URLComponents(string: "https://api.deezer.com/search/track")!
        components.queryItems = [.init(name: "q", value: query), .init(name: "limit", value: "1")]
        let response: TrackSearchResponse = try await request(url: components.url!)
        if let error = response.error {
            throw DeezerAPIError.api(message: error.message ?? error.type ?? "unknown")
        }
        return response.data?.first
    }

    private func searchAlbumId(artist: String, album: String) async throws -> Int? {
        var components = URLComponents(string: "https://api.deezer.com/search/album")!
        components.queryItems = [
            .init(name: "q", value: "artist:\"\(artist)\" album:\"\(album)\""),
            .init(name: "limit", value: "20"),
        ]
        let response: AlbumSearchResponse = try await request(url: components.url!)
        if let error = response.error {
            throw DeezerAPIError.api(message: error.message ?? error.type ?? "unknown")
        }
        guard let results = response.data, !results.isEmpty else { return nil }
        // Deezer's album search doesn't rank by exact artist match — a common
        // artist name can surface a different artist's album first; prefer a
        // result whose artist name matches, falling back to the top result.
        let targetArtist = normalizeForDeezerMatch(artist)
        let byArtist = results.first { normalizeForDeezerMatch($0.artist?.name ?? "") == targetArtist }
        return (byArtist ?? results[0]).id
    }

    private func fetchAlbumTracklist(albumId: Int) async throws -> [AlbumTrack] {
        let url = URL(string: "https://api.deezer.com/album/\(albumId)/tracks")!
        let response: AlbumTracklistResponse = try await request(url: url)
        if let error = response.error {
            throw DeezerAPIError.api(message: error.message ?? error.type ?? "unknown")
        }
        return response.data ?? []
    }

    private func durationFromAlbumTracklist(artist: String, album: String, track: String) async throws -> Int? {
        guard let albumId = try await searchAlbumId(artist: artist, album: album) else { return nil }
        let tracks = try await fetchAlbumTracklist(albumId: albumId)
        let target = normalizeForDeezerMatch(track)
        guard !target.isEmpty else { return nil }
        for t in tracks {
            if let title = t.title, normalizeForDeezerMatch(title) == target, let duration = t.duration, duration > 0 {
                return duration
            }
        }
        return nil
    }

    // MARK: - Title normalization (`normalizeTitleForMatch`)

    private func stripParentheticalAnnotations(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s*\[[^\]]*\]\s*"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func spaceOutApostrophes(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(of: "['\u{2019}\u{2018}]", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Lowercase, strip parenthesized/bracketed annotations, drop apostrophes
    /// entirely (not space them — this is for equality matching, not search
    /// querying), collapse whitespace. Deliberately a lighter, Deezer-specific
    /// normalization, NOT `TextNormalization.normalizeTrackTitle` — that
    /// function also strips "- Remastered"/version tails this matching step
    /// doesn't.
    private func normalizeForDeezerMatch(_ s: String) -> String {
        var result = s.lowercased()
        result = result.replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s*\[[^\]]*\]\s*"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "['\u{2019}\u{2018}]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Transport

    private func request<T: Decodable>(url: URL) async throws -> T {
        try ConnectivityGate.check(host: url.host)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
            ConnectivityHub.reportSuccess()
        } catch {
            ConnectivityHub.report(error, host: url.host, source: "Deezer")
            throw DeezerAPIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw DeezerAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw DeezerAPIError.http(http.statusCode) }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DeezerAPIError.invalidResponse
        }
    }
}
