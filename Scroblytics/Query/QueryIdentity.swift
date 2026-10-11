import Foundation

/// What counts as "the same thing" in a query. A row must mean the same artist in every column and
/// every date scope, so identity is decided ONCE for the whole library, not per window.
enum QueryIdentity {
    /// Gives every scrobble of one artist the same spelling: the library's most-played one, by the
    /// same rule Top Charts applies inside each window (`TextNormalization.canonicalArtistNames`).
    /// Last.fm can spell one artist several ways ("Angine de poitrine" / "Angine de Poitrine"); without
    /// this they are separate rows whose plays, ranks and tags are split between them.
    ///
    /// Every engine groups by these names, so fixing them here fixes every field at once. Only the
    /// scrobbles that actually change are rebuilt.
    static func canonicalizingArtists(_ scrobbles: [ScrobbleSnapshot]) -> [ScrobbleSnapshot] {
        let canonical = TextNormalization.canonicalArtistNames(scrobbles.map(\.artistName))
        var spelling: [String: String] = [:]
        for raw in Set(scrobbles.map(\.artistName)) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = canonical[TextNormalization.artistIdentityKey(trimmed)] ?? raw
            if chosen != raw { spelling[raw] = chosen }
        }
        guard !spelling.isEmpty else { return scrobbles }
        return scrobbles.map { s in
            guard let chosen = spelling[s.artistName] else { return s }
            return ScrobbleSnapshot(artistName: chosen, albumName: s.albumName, trackName: s.trackName, imageURL: s.imageURL, playedAt: s.playedAt)
        }
    }
}
