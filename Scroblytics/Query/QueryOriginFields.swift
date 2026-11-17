import Foundation
import SwiftData

/// Where each artist is from, as a Query run sees it: the saved lookups and the person's own corrections, read once (see
/// `QuerySnapshotReader`). An album or track takes its artist's place.
struct QueryOriginSnapshot: Sendable {
    var entries: [String: OriginEntrySnapshot] = [:]
    var edits: [String: OriginEditSnapshot] = [:]
    /// Whether looking up is switched on. With it off an artist nobody has answered for has no value, instead of waiting for an answer
    /// that will not come (and instead of a Resolve button that does nothing).
    var lookupsOn = false

    /// What every run that doesn't load origins sees: no places, nothing pending.
    static let empty = QueryOriginSnapshot()

    static func load(context: ModelContext) -> QueryOriginSnapshot {
        var snapshot = QueryOriginSnapshot(lookupsOn: ArtistOriginStore.lookupsEnabled)
        for row in (try? context.fetch(FetchDescriptor<ArtistOriginEntry>())) ?? [] { snapshot.entries[row.normalizedName] = OriginEntrySnapshot(row: row) }
        for row in (try? context.fetch(FetchDescriptor<ArtistOriginEdit>())) ?? [] { snapshot.edits[row.normalizedName] = OriginEditSnapshot(row: row) }
        return snapshot
    }

    func display(artist: String) -> ArtistOriginDisplay {
        let key = TextNormalization.artistIdentityKey(artist)
        return ArtistOriginResolver.display(entry: entries[key], edit: edits[key])
    }
}

/// Fields that read where an artist is from (`ArtistOriginEngine`): city, state or region, country, all three together, and whether a best
/// guess is waiting to be checked. They answer from what was looked up (or typed by the person) and never ask anything themselves; Query's
/// Resolve button hands the artists with no answer yet to the background lookup.
extension QueryFieldRegistry {
    private static func artistName(_ entity: QueryEntity) -> String { entity.target == .artist ? entity.name : entity.artist }

    /// The text of one part of the place. An artist not looked up yet is pending (or has no value while looking up is off); one MusicBrainz
    /// doesn't know, or whose place lacks this part, has no value.
    private static func originCell(_ run: QueryRun, _ entity: QueryEntity, _ part: (OriginPlace) -> String?) -> QueryCell {
        let snapshot = run.snapshots.origins
        let display = snapshot.display(artist: artistName(entity))
        switch display.state {
        case .pending: return snapshot.lookupsOn ? .pending : .missing
        case .unknown: return .missing
        case .known:
            guard let text = part(display.place)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return .missing }
            return .value(.text(text))
        }
    }

    private static let originTargets: Set<QueryTarget> = [.artist, .album, .track]

    static let originFields: [QueryField] = {
        var fields = originFieldList
        // Ask is offered the three parts to filter on; the combined text and the review flag are columns and Missing Data's, not questions.
        for id in ["originPlace", "originNeedsReview"] {
            if let index = fields.firstIndex(where: { $0.id == id }) { fields[index].askable = false }
        }
        return fields
    }()

    private static let originFieldList: [QueryField] = [
        QueryField(
            id: "originCity", name: "Artist origin city", group: .origin, type: .text, targets: originTargets,
            column: .standard(for: .text, width: 150),
            help: "The city the artist was born in (a person) or formed in (a group), from MusicBrainz or as you corrected it; an album or track takes its artist’s. Artists not looked up yet, or without a city on MusicBrainz, have no value.",
            isBackgroundResolved: true, resolver: .origin
        ) { run, _, entities in
            Dictionary(uniqueKeysWithValues: entities.map { ($0.id, originCell(run, $0) { $0.city }) })
        },
        QueryField(
            id: "originRegion", name: "Artist origin state or region", group: .origin, type: .text, targets: originTargets,
            column: .standard(for: .text, width: 150),
            help: "The state, province or nation the artist is from: the highest of those below the country (Georgia, England, Ontario). Places with none (a city directly under its country) have no value.",
            isBackgroundResolved: true, resolver: .origin
        ) { run, _, entities in
            Dictionary(uniqueKeysWithValues: entities.map { ($0.id, originCell(run, $0) { $0.region }) })
        },
        QueryField(
            id: "originCountry", name: "Artist origin country", group: .origin, type: .text, targets: originTargets,
            column: .standard(for: .text, width: 160),
            help: "The country the artist is from, spelled the same way for every artist (United States, United Kingdom). Artists not looked up yet, or with no country on MusicBrainz, have no value.",
            isBackgroundResolved: true, resolver: .origin
        ) { run, _, entities in
            Dictionary(uniqueKeysWithValues: entities.map { ($0.id, originCell(run, $0) { $0.country }) })
        },
        QueryField(
            id: "originPlace", name: "Artist origin", group: .origin, type: .text, targets: originTargets,
            column: .standard(for: .text, width: 260),
            help: "Where the artist is from in one piece: city, state or region and country, the parts that are known (Athens, Georgia, United States). Handy as a column and for sorting; to filter, use the city, state or country fields.",
            isBackgroundResolved: true, resolver: .origin
        ) { run, _, entities in
            Dictionary(uniqueKeysWithValues: entities.map { ($0.id, originCell(run, $0) { $0.text }) })
        },
        QueryField(
            id: "originNeedsReview", name: "Artist origin to review", group: .origin, type: .boolean, targets: originTargets,
            column: .standard(for: .boolean),
            help: "True when several artists share the artist’s name on MusicBrainz and the best one was used as a guess that nobody has checked. Checking it on the artist page (Looks Right, or picking the right artist) clears it. False for everything else, including artists not looked up yet."
        ) { run, _, entities in
            Dictionary(uniqueKeysWithValues: entities.map { entity in
                (entity.id, .value(.bool(run.snapshots.origins.display(artist: artistName(entity)).needsReview)))
            })
        },
    ]
}
