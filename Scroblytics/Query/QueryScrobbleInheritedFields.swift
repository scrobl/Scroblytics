import Foundation

/// What a play inherits from the track, album or artist it is of, for a query that finds single plays: "Track · Plays", "Album · Release
/// year", "Artist · Tags". Each is an existing field, computed by the existing code on an ordinary query of that kind over the same
/// plays, and handed to every play of that item. So "the plays of songs with at most 5 plays", "my plays of 1990s albums" and "plays of
/// songs under 3 minutes" read exactly as the same field does on the Tracks, Albums and Artists targets.
extension QueryFieldRegistry {
    /// The item fields a play carries, by level. A short list on purpose: the fields that describe the item, not the ones that rank it
    /// against others in a way that would read oddly on a single play.
    static let inheritedFieldIDs: [(level: QueryTarget, ids: [String])] = [
        (.track, [
            "plays", "allTimePlays", "playsInLast", "playRank", "timeListened", "firstPlayed", "lastPlayed", "daysSinceFirstPlayed", "daysSinceLastPlayed",
            "loved", "flagged", "inAppleLibrary", "tags", "myTags", "duration", "bpm", "tempoBucket", "musicalKey", "timeSignature",
            "releaseYear", "releaseDate", "popularityScore", "popular", "popularForArtist",
        ]),
        (.album, ["plays", "allTimePlays", "firstPlayed", "lastPlayed", "tags", "myTags", "releaseYear", "releaseDate", "popularityScore", "popular"]),
        (.artist, ["plays", "allTimePlays", "playRank", "timeListened", "firstPlayed", "lastPlayed", "tags", "myTags", "popularityScore", "popular"]),
    ]

    /// The inherited fields the larger models are told about.
    private static let askableInherited: Set<String> = [
        "track.plays", "track.firstPlayed", "track.loved", "track.tags", "track.duration", "track.releaseYear", "track.popular",
        "album.releaseYear", "artist.plays", "artist.firstPlayed", "artist.tags",
    ]

    static func inheritedFieldID(_ level: QueryTarget, _ base: String) -> String { "\(level.rawValue).\(base)" }

    private static func levelName(_ level: QueryTarget) -> String {
        switch level {
        case .artist: "Artist"
        case .album: "Album"
        case .track: "Track"
        case .scrobble: "Scrobble"
        }
    }

    /// The base field's answer for the item each of `entities` (plays) is of, found with the item-level run over the same plays.
    private static func inheritedCells(
        level: QueryTarget, base: QueryField, run: QueryRun, parameters: [String: QueryValue], scope: QueryScope?, baseline: QueryScope?, entities: [QueryEntity]
    ) -> [QueryEntityID: QueryCell] {
        let itemRun = run.itemRun(level)
        var itemOfPlay: [QueryEntityID: QueryEntityID] = [:]
        var items: [QueryEntityID: QueryEntity] = [:]
        for entity in entities {
            guard let id = run.itemID(level, ofPlay: entity.id) else { continue }
            itemOfPlay[entity.id] = id
            items[id] = QueryEntity(id: id)
        }
        let resolved = ResolvedField(field: base, parameters: parameters, scope: scope, baseline: baseline)
        let cells = itemRun.cells(for: resolved, entities: Array(items.values))
        return Dictionary(uniqueKeysWithValues: entities.map { entity in
            (entity.id, itemOfPlay[entity.id].flatMap { cells[$0] } ?? .missing)
        })
    }

    private static func inherited(_ base: QueryField, level: QueryTarget) -> QueryField {
        let id = inheritedFieldID(level, base.id)
        let name = levelName(level) + " · " + base.name
        let help = "For the \(level.rawValue) this play is of: " + base.help
        var field: QueryField
        if base.comparedCompute != nil {
            field = QueryField(id: id, name: name, group: base.group, type: base.type, targets: [.scrobble], parameters: base.parameters, column: base.column, help: help) {
                run, parameters, scope, baseline, entities in
                inheritedCells(level: level, base: base, run: run, parameters: parameters, scope: scope, baseline: baseline, entities: entities)
            }
        } else if base.scopedCompute != nil {
            field = QueryField(
                id: id, name: name, group: base.group, type: base.type, targets: [.scrobble], parameters: base.parameters, column: base.column, help: help,
                isBackgroundResolved: base.isBackgroundResolved, inputUnit: base.inputUnit, resolver: base.resolver
            ) { run, parameters, scope, entities in
                inheritedCells(level: level, base: base, run: run, parameters: parameters, scope: scope, baseline: nil, entities: entities)
            }
        } else {
            field = QueryField(
                id: id, name: name, group: base.group, type: base.type, targets: [.scrobble], parameters: base.parameters, column: base.column, help: help,
                isBackgroundResolved: base.isBackgroundResolved, inputUnit: base.inputUnit, resolver: base.resolver
            ) { run, parameters, entities in
                inheritedCells(level: level, base: base, run: run, parameters: parameters, scope: nil, baseline: nil, entities: entities)
            }
        }
        field.choices = base.choices
        field.caveat = base.caveat
        field.askable = false
        // Only the fields a request about plays is likely to name: the rest stay in the picker, not in the model's list.
        field.askableByLargeModels = askableInherited.contains(id)
        field.itemLevel = level
        return field
    }

    static let inheritedScrobbleFields: [QueryField] = {
        let byID = Dictionary(uniqueKeysWithValues: itemFields.map { ($0.id, $0) })
        return inheritedFieldIDs.flatMap { entry in
            entry.ids.compactMap { id in
                guard let base = byID[id], base.targets.contains(entry.level) else { return nil }
                return inherited(base, level: entry.level)
            }
        }
    }()
}
