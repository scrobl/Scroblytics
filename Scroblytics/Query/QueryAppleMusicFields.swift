import Foundation

/// Fields that read what Apple Music knows about a song, album or artist (`AppleMusicDetailsIndex`): when it was added to the library and
/// its genre. They answer from the saved read of the library, so they work while Music is closed, and are empty until the library has been
/// read (Settings › Sync › Apple Music library details). Tempo is not a separate field: Music's tempo tag is one more source for the
/// existing BPM, Tempo range and Tempo source fields.
extension QueryFieldRegistry {
    /// The matching index for this run, built once (and kept between runs for as long as neither the saved read nor the history changes).
    private static func musicIndex(_ run: QueryRun) -> AppleMusicDetailsIndex? {
        guard let file = run.snapshots.appleMusic.file else { return nil }
        return run.memoized("appleMusicIndex") { AppleMusicDetailsIndexCache.index(for: file, scrobbles: run.allTimeScrobbles) }
    }

    private static func musicRows(_ index: AppleMusicDetailsIndex, _ entity: QueryEntity) -> [AppleMusicDetailRow] {
        switch entity.target {
        case .track: index.rows(artist: entity.artist, track: entity.name)
        case .album: index.rows(artist: entity.artist, album: entity.name)
        case .artist: index.rows(artist: entity.name)
        case .scrobble, .session: []
        }
    }

    static let appleMusicFields: [QueryField] = [
        QueryField(
            id: "musicDateAdded", name: "Date added to Apple Music", group: .appleMusic, type: .date, targets: [.track, .album, .artist],
            column: .standard(for: .date),
            help: "When the song was added to your Apple Music library (the copy on the album you play it under, if the library holds it more than once); for an album or artist, the earliest of its songs. Last.fm only knows when a song was scrobbled, so this is the way to ask about when you got something. Songs that aren't in your library, and everything until the library has been read in Settings, have no value."
        ) { run, _, entities in
            guard let index = musicIndex(run) else { return Dictionary(uniqueKeysWithValues: entities.map { ($0.id, QueryCell.missing) }) }
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                guard let added = AppleMusicDetailsIndex.earliestAdded(musicRows(index, entity)) else { return (entity.id, QueryCell.missing) }
                return (entity.id, QueryCell.value(.date(added)))
            })
        },
        QueryField(
            id: "musicGenre", name: "Apple Music genre", group: .appleMusic, type: .text, targets: [.track, .album, .artist],
            column: .standard(for: .text, width: 150),
            help: "The genre Apple Music holds for the song (the copy on the album you play it under, if the library holds it more than once); for an album or artist, the genre most of its songs carry. Songs that aren't in your library, and everything until the library has been read in Settings, have no value."
        ) { run, _, entities in
            guard let index = musicIndex(run) else { return Dictionary(uniqueKeysWithValues: entities.map { ($0.id, QueryCell.missing) }) }
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                guard let genre = AppleMusicDetailsIndex.commonGenre(musicRows(index, entity)) else { return (entity.id, QueryCell.missing) }
                return (entity.id, QueryCell.value(.text(genre)))
            })
        },
    ]
}
