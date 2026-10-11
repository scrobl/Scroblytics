import Foundation

/// Finds the Apple Music page for an artist, album or track, using Apple's public catalogue search (no key, no
/// sign-in), so "View in Apple Music" can open the page itself in the Music app. Only used when someone asks for it.
enum AppleMusicCatalog {
    /// One search result. Which fields are present depends on what was searched for.
    struct Hit: Decodable, Sendable, Equatable {
        var artistName: String?
        var collectionName: String?
        var trackName: String?
        var artistLinkUrl: String?
        var collectionViewUrl: String?
        var trackViewUrl: String?
    }

    private struct Response: Decodable { let results: [Hit] }

    nonisolated static func decode(_ data: Data) throws -> [Hit] {
        try JSONDecoder().decode(Response.self, from: data).results
    }

    /// The `entity` parameter the search needs for each kind.
    nonisolated static func entity(for kind: ImageTargetKind) -> String {
        switch kind {
        case .artist: "musicArtist"
        case .album: "album"
        case .track: "song"
        }
    }

    /// Words that mark an edition ("Deluxe", "Remastered", "Expanded", …). "Edition" and "Version" alone say nothing, so
    /// "Deluxe Version" and "Deluxe Edition" count as the same edition.
    nonisolated static let editionWords: Set<String> = [
        "deluxe", "remastered", "remaster", "anniversary", "bonus", "special", "expanded", "collector's", "collectors",
        "limited", "reissue", "explicit", "clean", "instrumental", "acoustic", "live", "mono", "stereo", "platinum",
        "super", "extended", "complete", "international", "japan", "tour", "digital",
    ]

    /// Which edition a name says it is: the edition words in it (empty for a plain title).
    nonisolated static func editionTokens(_ name: String) -> Set<String> {
        let words = name.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
        return Set(words).intersection(editionWords)
    }

    /// How well a catalogue album name fits the album asked for, among albums that already match once edition tags
    /// are ignored: the same title (3), the same edition words (2), at least one in common (1), otherwise (0). So an
    /// album scrobbled as "… (Deluxe Version)" lands on the deluxe edition, not on the standard one Apple lists first.
    nonisolated static func albumFit(wanted: String, candidate: String) -> Int {
        if candidate.caseInsensitiveCompare(wanted) == .orderedSame { return 3 }
        let w = editionTokens(wanted), c = editionTokens(candidate)
        if w == c { return 2 }
        return w.isDisjoint(with: c) ? 0 : 1
    }

    /// The best result among `hits`, or nil when nothing is confidently the same item: the artist must match (case
    /// aside), and an album or song must match once edition tags ("Remastered", "Deluxe", "(feat. …)") are ignored.
    /// Among those, the edition the request names wins (see `albumFit`); ties keep Apple's own order. For a song the
    /// right album beats the first one, and an exact title beats a variant.
    nonisolated static func chooseHit(kind: ImageTargetKind, artist: String, album: String?, track: String?, from hits: [Hit]) -> Hit? {
        let wantedArtist = TextNormalization.artistIdentityKey(artist)
        let sameArtist = hits.filter { TextNormalization.artistIdentityKey($0.artistName ?? "") == wantedArtist }

        /// The first of the highest-scoring candidates (`max(by:)` would pick the last of equals).
        func best(_ candidates: [Hit], score: (Hit) -> Int) -> Hit? {
            var winner: (hit: Hit, score: Int)?
            for hit in candidates {
                let value = score(hit)
                if winner == nil || value > winner!.score { winner = (hit, value) }
            }
            return winner?.hit
        }

        switch kind {
        case .artist:
            return sameArtist.first { $0.artistLinkUrl != nil }
        case .album:
            guard let album, !album.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let wanted = TextNormalization.normalizeAlbumName(album)
            let matches = sameArtist.filter { $0.collectionViewUrl != nil && TextNormalization.normalizeAlbumName($0.collectionName ?? "") == wanted }
            return best(matches) { albumFit(wanted: album, candidate: $0.collectionName ?? "") }
        case .track:
            guard let track, !track.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let wanted = TextNormalization.normalizeTrackTitle(track)
            let matches = sameArtist.filter { $0.trackViewUrl != nil && TextNormalization.normalizeTrackTitle($0.trackName ?? "") == wanted }
            let wantedAlbum = album.map(TextNormalization.normalizeAlbumName)
            return best(matches) { hit in
                var score = 0
                if (hit.trackName ?? "").caseInsensitiveCompare(track) == .orderedSame { score += 1 }
                if let album, let wantedAlbum, TextNormalization.normalizeAlbumName(hit.collectionName ?? "") == wantedAlbum {
                    score += 10 * (1 + albumFit(wanted: album, candidate: hit.collectionName ?? ""))
                }
                return score
            }
        }
    }

    /// The page of `chooseHit`.
    nonisolated static func choose(kind: ImageTargetKind, artist: String, album: String?, track: String?, from hits: [Hit]) -> URL? {
        guard let hit = chooseHit(kind: kind, artist: artist, album: album, track: track, from: hits) else { return nil }
        let link: String?
        switch kind {
        case .artist: link = hit.artistLinkUrl
        case .album: link = hit.collectionViewUrl
        case .track: link = hit.trackViewUrl
        }
        return link.flatMap(URL.init(string:))
    }

    /// The same page as a `music://` address (so it opens in the Music app, not a browser), without Apple's tracking
    /// parameter.
    nonisolated static func musicURL(from page: URL) -> URL? {
        guard var components = URLComponents(url: page, resolvingAgainstBaseURL: false), components.host == "music.apple.com" else { return nil }
        components.scheme = "music"
        components.queryItems = components.queryItems?.filter { $0.name != "uo" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    /// Searches the catalogue and returns the best page, or nil when nothing matches. Throws when the request can't be
    /// made (Offline mode, no connection, Apple unreachable).
    static func lookup(kind: ImageTargetKind, artist: String, album: String?, track: String?, session: URLSession = .shared) async throws -> URL? {
        let term = AppleMusicLinks.searchTerm(kind: kind, artist: artist, album: album, track: track)
        guard !term.isEmpty else { return nil }
        let home = Locale.current.region?.identifier ?? "US"
        for country in home == "US" ? ["US"] : [home, "US"] {
            let hits = try await search(term: term, entity: entity(for: kind), country: country, session: session)
            if let page = choose(kind: kind, artist: artist, album: album, track: track, from: hits) { return page }
        }
        return nil
    }

    private static func search(term: String, entity: String, country: String, session: URLSession) async throws -> [Hit] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term), URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "country", value: country),
        ]
        guard let url = components.url else { return [] }
        try ConnectivityGate.check(host: url.host)
        do {
            let (data, response) = try await session.data(from: url)
            ConnectivityHub.reportSuccess()
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return [] }
            return try decode(data)
        } catch let error as DecodingError {
            throw error
        } catch {
            ConnectivityHub.report(error, host: url.host, source: "Apple Music")
            throw error
        }
    }
}
