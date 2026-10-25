import Foundation

/// Registry fields that WRAP `ReleaseDateEngine`. Precedence lives in the engine
/// (`Resolution.classify` for albums, `Snapshot.trackResolution` for tracks:
/// track override > primary album's date > the track's own cache row); these
/// only read it and convert its "YYYY[-MM[-DD]]" string to a value.
extension QueryFieldRegistry {
    /// One resolution per entity, memoized so Release year and Release date on the
    /// same query share it.
    private static func releaseResolutions(_ run: QueryRun, _ entities: [QueryEntity]) -> [QueryEntityID: ReleaseDateEngine.Resolution] {
        let snapshot = run.snapshots.releaseDates
        let byEntity = run.scrobblesByEntity
        return Dictionary(uniqueKeysWithValues: entities.map { entity in
            switch entity.target {
            case .album:
                return (entity.id, snapshot.albumResolution(artist: entity.artist, album: entity.name))
            case .track:
                let primary = ReleaseDateEngine.primaryAlbum(scrobbles: byEntity[entity.id] ?? [])
                return (entity.id, snapshot.trackResolution(artist: entity.artist, track: entity.name, primaryAlbum: primary))
            case .artist, .scrobble:
                preconditionFailure("release date fields are not offered for artists or single plays")
            }
        })
    }

    private static func releaseCell(
        _ resolution: ReleaseDateEngine.Resolution, _ value: (String) -> QueryValue?
    ) -> QueryCell {
        switch resolution {
        case .pending: .pending
        case .unknown: .missing
        // A stored string that doesn't parse would be a data bug — absent, never a guessed value.
        case .date(let raw): value(raw).map { .value($0) } ?? .missing
        }
    }

    static let releaseDateFields: [QueryField] = [
        QueryField(
            id: "releaseYear", name: "Release year", group: .dates, type: .numeric, targets: [.album, .track],
            column: .standard(for: .numeric, style: .year, width: 100),
            help: "The year it was first released. A track uses its own date if you set one, otherwise its main album’s. Exact even when only the year is known. “Missing” means no date could be found; one still being looked up matches neither.",
            isBackgroundResolved: true, resolver: .releaseDate
        ) { run, _, entities in
            releaseResolutions(run, entities).mapValues { resolution in
                releaseCell(resolution) { ReleaseDateEngine.year(of: $0).map { .number(Double($0)) } }
            }
        },
        QueryField(
            id: "releaseDate", name: "Release date", group: .dates, type: .date, targets: [.album, .track],
            column: .standard(for: .date),
            help: "The day it was first released. Where only the year (or month) is known this is the FIRST day of that year (or month), so it shows as Jan 1 — use Release year to filter those exactly.",
            isBackgroundResolved: true, resolver: .releaseDate
        ) { run, _, entities in
            releaseResolutions(run, entities).mapValues { resolution in
                releaseCell(resolution) { ReleaseDateEngine.periodStart(of: $0).map { .date($0) } }
            }
        },
    ]
}
