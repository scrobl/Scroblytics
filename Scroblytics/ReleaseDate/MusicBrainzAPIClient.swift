import Foundation

/// MusicBrainz's release-group search — the primary release-date source.
/// `first-release-date` is the canonical EARLIEST release date across every
/// edition/reissue of an album, unlike Deezer's `/album/{id}` `release_date`,
/// which reflects whichever single edition Deezer's fuzzy search happens to
/// match (sometimes a much later reissue, remaster, or an unrelated
/// same-titled release — confirmed against real source as the root cause of
/// a documented bad date: R.E.M.'s "Document" showed 1998 via Deezer/Last.fm,
/// 1987-08-31 via MusicBrainz). Deezer is used as a fallback only when
/// MusicBrainz has no match at all — see `ReleaseDateEngine`.
///
/// Deliberately does NOT expose a track/recording lookup: MusicBrainz's
/// recording search ranks by text-match score, not canonicity, so the top
/// hit for a well-known song is often a live/alternate recording with its
/// own unrelated `first-release-date` — the same class of bug this client
/// exists to fix, just moved to a different field. Track-level dates are
/// resolved via the track's own observed album instead (`ReleaseDateEngine`).
///
/// Unauthenticated usage is rate-limited to ~1 request/second and requires an
/// identifying User-Agent — callers (the `ReleaseDateEngine` warmer) must
/// throttle to that rate themselves; this client makes no attempt to do so.
enum MusicBrainzAPIError: Error {
    case http(Int)
    case network(Error)
    case invalidResponse
}

actor MusicBrainzAPIClient {
    private static let releaseGroupURL = "https://musicbrainz.org/ws/2/release-group/"
    /// MusicBrainz asks for an application name/version plus a contact (email or URL) so it can reach
    /// the operator instead of blocking; anonymous-looking traffic is throttled harder. Replace the
    /// email with the project's URL if the app is ever released.
    private static let userAgent = "Scroblytics/1.0 ( Scroblytics@proton.me )"

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    private struct ReleaseGroup: Decodable {
        let disambiguation: String?
        let firstReleaseDate: String?
        enum CodingKeys: String, CodingKey {
            case disambiguation
            case firstReleaseDate = "first-release-date"
        }
    }

    private struct SearchResponse: Decodable {
        let releaseGroups: [ReleaseGroup]?
        enum CodingKeys: String, CodingKey {
            case releaseGroups = "release-groups"
        }
    }

    /// Searches for an album's release-group and returns its
    /// `first-release-date`, or `nil` when MusicBrainz genuinely has no
    /// match (or the match has no date on file).
    ///
    /// `hints` (from `TextNormalization.extractQueryHints`) are nickname text
    /// pulled OUT of the query on purpose — quoting a nickname literally can
    /// exact-match an unrelated release-group whose title happens to contain
    /// that text instead of the real album. When a hint is supplied, this
    /// fetches multiple candidates and prefers whichever one's
    /// `disambiguation` field matches a hint; with no hint (or no match among
    /// candidates) it falls back to MusicBrainz's own top-ranked result.
    ///
    /// Network/HTTP errors THROW so the caller retries instead of caching a
    /// false negative — same transient-vs-genuine-miss contract as every
    /// other resolver in this app.
    func fetchAlbumReleaseDate(artist: String, album: String, hints: [String] = []) async throws -> String? {
        var components = URLComponents(string: Self.releaseGroupURL)!
        components.queryItems = [
            .init(name: "query", value: "artist:\"\(escapeLucene(artist))\" AND releasegroup:\"\(escapeLucene(album))\""),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: hints.isEmpty ? "1" : "25"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        try ConnectivityGate.check(host: request.url?.host)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            ConnectivityHub.reportSuccess()
        } catch {
            ConnectivityHub.report(error, host: request.url?.host, source: "MusicBrainz")
            throw MusicBrainzAPIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MusicBrainzAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MusicBrainzAPIError.http(http.statusCode) }
        let decoded: SearchResponse
        do {
            decoded = try decoder.decode(SearchResponse.self, from: data)
        } catch {
            throw MusicBrainzAPIError.invalidResponse
        }
        let groups = decoded.releaseGroups ?? []

        if !hints.isEmpty {
            let normHints = hints.map(normalizeHint).filter { !$0.isEmpty }
            let hintMatches = groups.filter { group in
                guard let disambiguation = group.disambiguation, !disambiguation.isEmpty else { return false }
                let normDisambiguation = normalizeHint(disambiguation)
                return normHints.contains { normDisambiguation.contains($0) || $0.contains(normDisambiguation) }
            }
            if !hintMatches.isEmpty {
                let dated = hintMatches.filter { $0.firstReleaseDate != nil }
                let pool = dated.isEmpty ? hintMatches : dated
                let best = pool.min { ($0.firstReleaseDate ?? "9999") < ($1.firstReleaseDate ?? "9999") }
                return best?.firstReleaseDate
            }
        }

        return groups.first?.firstReleaseDate
    }

    /// Escapes Lucene special characters so a name can be safely quoted in an MB query.
    private func escapeLucene(_ value: String) -> String {
        var result = ""
        for ch in value {
            if ch == "\\" || ch == "\"" { result.append("\\") }
            result.append(ch)
        }
        return result
    }

    /// Lowercased, "the "-stripped, alnum-only form used to compare a hint against a disambiguation.
    private func normalizeHint(_ s: String) -> String {
        var n = s.lowercased()
        if n.hasPrefix("the ") { n = String(n.dropFirst(4)) }
        n = n.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return n.trimmingCharacters(in: .whitespaces)
    }
}
