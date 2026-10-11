import Foundation

/// Album match status, wrapping the Album Turnover matcher (`AlbumTurnoverEngine.matchResult` through
/// `AlbumMatchStatus.classify`): whether Last.fm's album for it was found automatically, confirmed by
/// you, judged uncertain, or not found — for tracking down albums whose match needs a look. Like the
/// turnover fields it reads the query's scrobbles and a cached tracklist snapshot, never the network:
/// an album whose tracklist isn't cached yet is still resolving.
extension QueryFieldRegistry {
    private static func matchStatuses(_ run: QueryRun) -> [QueryEntityID: AlbumMatchStatus?] {
        run.memoized("albumMatchStatus") {
            let byArtist = run.snapshots.turnoverGroups.groups(for: run.scrobbles)
            let snapshot = run.snapshots.turnover
            return Dictionary(uniqueKeysWithValues: run.universe.entities.compactMap { entity -> (QueryEntityID, AlbumMatchStatus?)? in
                guard let group = byArtist[entity.artist].flatMap({ AlbumTurnoverEngine.findAlbumGroup($0, album: entity.name) }) else { return nil }
                return (entity.id, snapshot.matchStatus(for: group))
            })
        }
    }

    static let matchFields: [QueryField] = {
        let statusHelp = "Automatic: Last.fm’s album was found and looks right. Confirmed by you: you fixed the match. Using played tracks: you chose to ignore Last.fm’s tracklist. Uncertain match / No match found: still needs a look."
        var status = QueryField(
            id: "albumMatchStatus", name: "Match status", group: .metadata, type: .text, targets: [.album],
            column: .standard(for: .text, width: 190),
            help: "How the album matched Last.fm. " + statusHelp + " Needs the album’s tracklist to be looked up first; albums without one yet are still resolving.",
            isBackgroundResolved: true, resolver: .albumTracklists
        ) { run, _, entities in
            let statuses = matchStatuses(run)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                switch statuses[entity.id] {
                case .some(.some(let status)): return (entity.id, .value(.text(status.rawValue)))
                case .some(.none): return (entity.id, .pending)
                case .none: return (entity.id, .missing)
                }
            })
        }
        status.choices = AlbumMatchStatus.allCases.map(\.rawValue)
        let review = QueryField(
            id: "needsMatchReview", name: "Needs match review", group: .flags, type: .boolean, targets: [.album],
            column: QueryColumnSpec(alignment: .center, style: .boolean, width: 130),
            help: "True when the album’s Last.fm match is uncertain or not found and you haven’t fixed it — the albums worth opening “Fix album match…” on. Needs the album’s tracklist to be looked up first.",
            isBackgroundResolved: true, resolver: .albumTracklists
        ) { run, _, entities in
            let statuses = matchStatuses(run)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                switch statuses[entity.id] {
                case .some(.some(let status)): return (entity.id, .value(.bool(status.needsReview)))
                case .some(.none): return (entity.id, .pending)
                case .none: return (entity.id, .missing)
                }
            })
        }
        return [status, review]
    }()
}
