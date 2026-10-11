import Foundation

/// A single artist/album/track a popularity signal belongs to. `key` is the
/// cache key; the same builder is used for seeding and for every UI lookup so
/// they can never drift apart.
///
/// Deliberately NOT a `kind\0artist\0title` NUL-joined key (the same
/// NUL-in-SQLite hazard avoided elsewhere in this app) — U+241F
/// separates the parts instead.
struct PopularityLookup: Sendable, Hashable {
    let kind: PopularityKind
    /// Display artist name (for `.artist`, the artist's own name).
    let artist: String
    let album: String?
    let track: String?

    static func artist(_ name: String) -> PopularityLookup {
        .init(kind: .artist, artist: name, album: nil, track: nil)
    }

    static func album(artist: String, name: String) -> PopularityLookup {
        .init(kind: .album, artist: artist, album: name, track: nil)
    }

    static func track(artist: String, name: String) -> PopularityLookup {
        .init(kind: .track, artist: artist, album: nil, track: name)
    }

    init(kind: PopularityKind, artist: String, album: String?, track: String?) {
        self.kind = kind
        self.artist = artist
        self.album = album
        self.track = track
    }

    /// Maps a Top Charts/Library row. An album/track row's `artist` is always
    /// populated (see `TopChartsEngine.rank`); an empty one yields nil rather
    /// than a key that can never match anything.
    init?(entity: TopChartsEntity, entry: TopChartEntry) {
        switch entity {
        case .artist:
            self = .artist(entry.name)
        case .album:
            guard let artist = entry.artist, !artist.isEmpty else { return nil }
            self = .album(artist: artist, name: entry.name)
        case .track:
            guard let artist = entry.artist, !artist.isEmpty else { return nil }
            self = .track(artist: artist, name: entry.name)
        }
    }

    var artistKey: String { Self.artistKey(artist) }

    /// Matches `Artist.normalizedName` (`name.trimmed.lowercased()`).
    static func artistKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Album/track titles as sent to Last.fm/Deezer — edition suffixes
    /// stripped, exactly as source does before both querying and keying.
    var queryAlbum: String? { album.map(TextNormalization.stripEditionSuffix) }
    var queryTrack: String? { track.map(TextNormalization.stripEditionSuffix) }

    var key: String {
        let sep = "\u{241F}"
        switch kind {
        case .artist:
            return "artist\(sep)\(artistKey)"
        case .album:
            return "album\(sep)\(artistKey)\(sep)\(TextNormalization.normalizeAlbumName(album ?? ""))"
        case .track:
            return "track\(sep)\(artistKey)\(sep)\(Self.trackKeyPart(track ?? ""))"
        }
    }

    private static func trackKeyPart(_ track: String) -> String {
        TextNormalization.stripEditionSuffix(track).trimmingCharacters(in: .whitespaces).lowercased()
    }
}
