import Foundation

/// The Last.fm "loved" flag, wrapping `LovedTracksEngine.lovedSet` — the same membership test the
/// Top Charts hearts use (`lovedKey(artist, track)` ∈ set), read from a snapshot of the synced
/// loved list. A track that isn't in the list is "not loved"; it is never "unknown".
extension QueryFieldRegistry {
    private static func lovedRatio(
        tracks: Set<String>, lovedKeys: Set<String>
    ) -> QueryCell {
        guard !tracks.isEmpty else { return .missing }
        let lovedCount = tracks.intersection(lovedKeys).count
        return .value(.number(Double(lovedCount) / Double(tracks.count)))
    }

    static let lovedFields: [QueryField] = [
        QueryField(
            id: "loved", name: "Loved", group: .flags, type: .boolean, targets: [.track],
            column: QueryColumnSpec(alignment: .center, style: .custom("lovedHeart"), width: 70),
            help: "Whether you’ve loved the track on Last.fm, as of the last sync (or your last love/unlove in the app)."
        ) { run, _, entities in
            let loved = run.snapshots.lovedKeys
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                (entity.id, .value(.bool(loved.contains(TextNormalization.lovedKey(artist: entity.artist, track: entity.name)))))
            })
        },
        QueryField(
            id: "artistLovedRatio", name: "Artist loved ratio", group: .sentiment, type: .numeric, targets: [.artist, .album, .track],
            column: .standard(for: .numeric, style: .percent, width: 110),
            help: "The share of this artist’s distinct tracks in your whole scrobble library that are currently loved on Last.fm."
        ) { run, _, entities in
            let tracksByArtist: [String: Set<String>] = run.memoized("lovedRatio.tracksByArtist") {
                var result: [String: Set<String>] = [:]
                for scrobble in run.allTimeScrobbles {
                    result[scrobble.artistName, default: []].insert(
                        TextNormalization.lovedKey(artist: scrobble.artistName, track: scrobble.trackName)
                    )
                }
                return result
            }
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                (entity.id, lovedRatio(tracks: tracksByArtist[entity.artist] ?? [], lovedKeys: run.snapshots.lovedKeys))
            })
        },
        QueryField(
            id: "albumLovedRatio", name: "Album loved ratio", group: .sentiment, type: .numeric, targets: [.album],
            column: .standard(for: .numeric, style: .percent, width: 110),
            help: "The share of this album’s distinct tracks in your whole scrobble library that are currently loved on Last.fm."
        ) { run, _, entities in
            let tracksByAlbum: [QueryEntityID: Set<String>] = run.memoized("lovedRatio.tracksByAlbum") {
                var result: [QueryEntityID: Set<String>] = [:]
                for scrobble in run.allTimeScrobbles where !scrobble.albumName.isEmpty {
                    let album = QueryEntityID(target: .album, artist: scrobble.artistName, name: scrobble.albumName)
                    result[album, default: []].insert(
                        TextNormalization.lovedKey(artist: scrobble.artistName, track: scrobble.trackName)
                    )
                }
                return result
            }
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                (entity.id, lovedRatio(tracks: tracksByAlbum[entity.id] ?? [], lovedKeys: run.snapshots.lovedKeys))
            })
        },
    ]

    static let flaggedFields: [QueryField] = [
        QueryField(
            id: "flagged", name: "Flagged", group: .flags, type: .boolean, targets: [.track],
            column: QueryColumnSpec(alignment: .center, style: .custom("flaggedFlag"), width: 70),
            help: "Whether the track has been added to your Flagged Tracks collection."
        ) { run, _, entities in
            let flagged = run.snapshots.flaggedKeys
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                (
                    entity.id,
                    .value(.bool(flagged.contains(
                        TextNormalization.lovedKey(artist: entity.artist, track: entity.name)
                    )))
                )
            })
        },
    ]
}
