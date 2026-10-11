import Foundation

/// Stable, name-based identities for the three chained detail pages —
/// deliberately NOT `TopChartEntry` (whose `id` is a fresh `UUID` every
/// ranking pass, and which only exists for entries currently visible in a
/// Top Charts list). A drill chain needs identity that survives across
/// pages and reloads: artist → one of its albums or tracks → (for an
/// album) one of its tracks → that track's own scrobble history. Each type
/// carries just enough to re-query from scratch and render a header without
/// waiting on a parent page's data.
struct ArtistIdentity: Hashable, Identifiable, Sendable {
    let name: String
    let imageURL: String?
    var id: String { name }

    init(name: String, imageURL: String? = nil) {
        self.name = name
        self.imageURL = imageURL
    }

    init(from entry: TopChartEntry) {
        self.init(name: entry.name, imageURL: entry.imageURL)
    }
}

struct AlbumIdentity: Hashable, Identifiable, Sendable {
    /// The album's own artist context — may be `TextNormalization.variousArtistsLabel`
    /// for a detected compilation, matching how `TopChartsEngine` already displays it.
    let artist: String
    let name: String
    let imageURL: String?
    var id: String { "\(artist)\u{0}\(name)" }

    init(artist: String, name: String, imageURL: String? = nil) {
        self.artist = artist
        self.name = name
        self.imageURL = imageURL
    }

    /// Only valid for a `.album`-entity `TopChartEntry`, whose `artist` field
    /// is always populated (`TopChartsEngine.rank`'s `.album` branch never
    /// leaves it nil).
    init(from entry: TopChartEntry) {
        self.init(artist: entry.artist ?? "", name: entry.name, imageURL: entry.imageURL)
    }
}

struct TrackIdentity: Hashable, Identifiable, Sendable {
    let artist: String
    let name: String
    /// The album the track was reached FROM, if any — display context only,
    /// never used to scope the track's own stats (a track's plays span
    /// every album it appears under, matching `EntityStatsEngine.fetchTrackStats`).
    let album: String?
    let imageURL: String?
    var id: String { "\(artist)\u{0}\(name)" }

    init(artist: String, name: String, album: String? = nil, imageURL: String? = nil) {
        self.artist = artist
        self.name = name
        self.album = album
        self.imageURL = imageURL
    }

    /// Only valid for a `.track`-entity `TopChartEntry`, whose `artist` field
    /// is always populated (`TopChartsEngine.rank`'s `.track` branch never
    /// leaves it nil).
    init(from entry: TopChartEntry) {
        self.init(artist: entry.artist ?? "", name: entry.name, album: entry.album, imageURL: entry.imageURL)
    }
}
