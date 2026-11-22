import Foundation

/// What counts as "the same thing" in a query. A row must mean the same artist in every column and
/// every date scope, so identity is decided ONCE for the whole library, not per window.
enum QueryIdentity {
    /// Gives every scrobble of one artist the same spelling: the library's most-played one, by the
    /// same rule Top Charts applies inside each window (`TextNormalization.canonicalArtistNames`).
    /// Last.fm can spell one artist several ways ("Angine de poitrine" / "Angine de Poitrine"); without
    /// this they are separate rows whose plays, ranks and tags are split between them.
    ///
    /// The person's own name corrections (`NameCorrectionBook`) are applied in the same pass and always win over the most-played
    /// spelling: an artist, an album (found by its raw artist) or a track is shown the way they chose. Two spellings of an album or track
    /// that now read the same become one row everywhere.
    ///
    /// Every engine groups by these names, so fixing them here fixes every field at once. Only the
    /// scrobbles that actually change are rebuilt.
    /// Only the person's own name corrections, applied to the plays as Last.fm has them (no artist-spelling merge). For the screens and
    /// tools that read plays without merging artist spellings: they show the same names as everywhere else, and everything else about
    /// their numbers stays as it was.
    static func applyingNameCorrections(_ scrobbles: [ScrobbleSnapshot], book: NameCorrectionBook = NameCorrections.current) -> [ScrobbleSnapshot] {
        let applier = NameCorrectionApplier(book: book)
        guard !applier.isIdentity else { return scrobbles }
        return scrobbles.map { s in
            let artist = applier.artist(s.artistName) ?? s.artistName
            let (album, track) = applier.albumAndTrack(artist: s.artistName, album: s.albumName, track: s.trackName)
            guard artist != s.artistName || album != s.albumName || track != s.trackName else { return s }
            return ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: s.imageURL, playedAt: s.playedAt)
        }
    }

    static func canonicalizingArtists(_ scrobbles: [ScrobbleSnapshot], book: NameCorrectionBook = NameCorrections.current) -> [ScrobbleSnapshot] {
        let canonical = TextNormalization.canonicalArtistNames(scrobbles.map(\.artistName))
        var spelling: [String: String] = [:]
        for raw in Set(scrobbles.map(\.artistName)) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var chosen = canonical[TextNormalization.artistIdentityKey(trimmed)] ?? raw
            if let corrected = book.artist(raw) { chosen = corrected }
            if chosen != raw { spelling[raw] = chosen }
        }
        let applier = NameCorrectionApplier(book: book)
        guard !spelling.isEmpty || !applier.isIdentity else { return scrobbles }
        return scrobbles.map { s in
            let artist = spelling[s.artistName] ?? s.artistName
            let (album, track) = applier.albumAndTrack(artist: s.artistName, album: s.albumName, track: s.trackName)
            guard artist != s.artistName || album != s.albumName || track != s.trackName else { return s }
            return ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: s.imageURL, playedAt: s.playedAt)
        }
    }
}
