import Foundation

/// Registry fields that find album edition names merged by mistake: a bonus-heavy edition ("Album (25th Anniversary
/// Edition)") that shares an album group with the standard album, so its plays are measured against a tracklist it doesn't
/// have. They compare each album name's own played tracks with the group's real tracklist (`AlbumTurnoverEngine.Snapshot
/// .canonicalTitles`), read the same cached groups and tracklist snapshot as the match fields, and never use the network.
/// An album whose tracklist isn't cached yet is `.pending` ("Resolve now" fetches it).
extension QueryFieldRegistry {
    private struct EditionInfo: Sendable {
        /// Edition names in the album's group (1 when it stands alone or is counted on its own).
        var names: Int
        /// Distinct tracks of this name's own plays that aren't on the group's real tracklist; nil with no real tracklist.
        var offList: Int?
        var tracklistPending: Bool
        /// The person chose to keep this name merged.
        var reviewed: Bool
        /// The Merged Editions test: a merged, unreviewed edition name with enough off-list tracks.
        var review: Bool
    }

    /// Per album name, over the query's plays. Groups with one name skip the tracklist work unless a column asks for it.
    private static func editionInfo(_ run: QueryRun, needsTracklists: Bool) -> [QueryEntityID: EditionInfo] {
        run.memoized("editionInfo.\(needsTracklists)") {
            let snapshot = run.snapshots.turnover
            let byArtist = run.snapshots.turnoverGroups.groups(for: run.scrobbles, separating: snapshot.separateEditions)
            let minimum = AlbumTurnoverEngine.mergedEditionOffListMinimum
            var result: [QueryEntityID: EditionInfo] = [:]
            for groups in byArtist.values {
                for group in groups {
                    let names = group.editionKey != nil ? 1 : Set(group.variants.map { TextNormalization.editionIdentityKey(artist: group.artist, album: $0) }).count
                    let merged = names > 1
                    var titles: AlbumTurnoverEngine.Snapshot.Titles = .none
                    if merged || needsTracklists { titles = snapshot.canonicalTitles(for: group) }
                    for variant in group.variants {
                        let id = QueryEntityID(target: .album, artist: group.artist, name: variant)
                        guard let plays = run.scrobblesByEntity[id] else { continue }
                        let reviewed = snapshot.reviewedEditions.contains(TextNormalization.editionIdentityKey(artist: group.artist, album: variant))
                        var info = EditionInfo(names: names, offList: nil, tracklistPending: false, reviewed: reviewed, review: false)
                        switch titles {
                        case .pending: info.tracklistPending = true
                        case .none: break
                        case .titles(let list):
                            let played = Set(plays.map { TextNormalization.normalizeTrackTitle($0.trackName) }.filter { !$0.isEmpty })
                            info.offList = played.subtracting(list).count
                        }
                        if merged, !reviewed, let off = info.offList { info.review = off >= minimum }
                        result[id] = info
                    }
                }
            }
            return result
        }
    }

    static let editionFields: [QueryField] = {
        var names = QueryField(
            id: "albumEditionNames", name: "Edition names counted together", group: .metadata, type: .numeric, targets: [.album],
            column: .standard(for: .numeric, style: .integer, width: 120),
            help: "How many edition names of this album (the standard album, a Deluxe or Anniversary edition…) are counted together for turnover and the album match. 1 when it stands alone or you counted it on its own."
        ) { run, _, entities in
            let info = editionInfo(run, needsTracklists: false)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                (entity.id, info[entity.id].map { .value(.number(Double($0.names))) } ?? .missing)
            })
        }
        names.askable = false

        var offList = QueryField(
            id: "albumOffListTracks", name: "Played tracks not on the tracklist", group: .metadata, type: .numeric, targets: [.album],
            column: .standard(for: .numeric, style: .integer, width: 130),
            help: "How many different tracks you played under this album name that aren’t on the album’s matched tracklist. Bonus material of an edition that was merged with the standard album shows up here. No value when the album has no real tracklist; needs the tracklist to be looked up first.",
            isBackgroundResolved: true, resolver: .albumTracklists
        ) { run, _, entities in
            let info = editionInfo(run, needsTracklists: true)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                guard let item = info[entity.id] else { return (entity.id, .missing) }
                if item.tracklistPending { return (entity.id, .pending) }
                return (entity.id, item.offList.map { .value(.number(Double($0))) } ?? .missing)
            })
        }
        offList.askable = false

        var review = QueryField(
            id: "mergedEditionReview", name: "Merged edition to review", group: .flags, type: .boolean, targets: [.album],
            column: QueryColumnSpec(alignment: .center, style: .boolean, width: 130),
            help: "True when this album name is counted together with other editions of the album but at least \(AlbumTurnoverEngine.mergedEditionOffListMinimum) of the different tracks you played under it aren’t on the album’s tracklist — likely an edition with its own tracks (an anniversary edition, a demos or live version) that should be counted on its own. False once you counted it on its own or chose to keep it merged. Needs the album’s tracklist to be looked up first.",
            isBackgroundResolved: true, resolver: .albumTracklists
        ) { run, _, entities in
            let info = editionInfo(run, needsTracklists: false)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                guard let item = info[entity.id] else { return (entity.id, .missing) }
                if item.tracklistPending, item.names > 1, !item.reviewed { return (entity.id, .pending) }
                return (entity.id, .value(.bool(item.review)))
            })
        }
        review.askable = false
        review.askableByLargeModels = true
        return [names, offList, review]
    }()
}
