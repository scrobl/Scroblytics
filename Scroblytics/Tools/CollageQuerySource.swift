import Foundation
import Observation
import SwiftData

/// What the Query tool hands the Collage tool: the rows of a result as collage items, in the order the query put them, with the value of
/// the column the results are sorted by to show on each tile, and what to call the collage.
struct CollageQueryPayload: Equatable, Sendable {
    /// Distinct for every hand-off, so the tool notices a new one even when the rows are the same.
    let id = UUID()
    /// The question or filters the results answered ("Loved albums · released in the 90s"): the caption's title.
    var title: String
    /// Where the rows came from, as the caption says it: "From Query" for results handed over, "Saved query" for one run here.
    var origin = "From Query"
    var entity: TopChartsEntity
    var items: [CollageItem]
    /// The column whose values are on the tiles ("Plays", "Release year"); nil when the query has no column to show.
    var valueLabel: String?
    /// How many rows the query had, of which the largest grid holds only some.
    var totalRows: Int
    /// What to tell the person when the rows may be incomplete (values still being looked up); nil when they are complete.
    var pendingNote: String?

    /// What a collage of these rows says under the picture: "Loved albums · From Query · Showing Plays · Oct 26, 2026".
    var caption: CollageCaption {
        CollageCaption(title: title, period: origin, measure: valueLabel.map { "Showing \($0)" } ?? "")
    }

    /// Some rows carry a year (a query broken down by year), which the tile's period label can show.
    var hasPeriodLabels: Bool { items.contains { $0.periodLabel != nil } }
}

enum CollageQuerySource {
    /// The most tiles any grid holds (12 × 12); rows beyond them cannot be shown.
    static let maxItems = CollageGrid.allCases.map(\.tileCount).max() ?? 144

    /// The kind of thing a query's rows are, when a collage of them makes sense: the collage tool's three kinds, not plays or sessions.
    static func entity(for target: QueryTarget) -> TopChartsEntity? {
        switch target {
        case .artist: .artist
        case .album: .album
        case .track: .track
        case .scrobble, .session: nil
        }
    }

    /// The smallest square grid with room for `count` items (the largest when there are more than it holds).
    static func suggestedGrid(count: Int) -> CollageGrid {
        let squares: [CollageGrid] = [.three, .five, .seven, .ten, .twelve]
        return squares.first { $0.tileCount >= count } ?? .twelve
    }

    /// The collage items for a query's rows, or nil when there is nothing to make one of (no rows, or plays or sessions).
    @MainActor
    static func payload(
        title: String, target: QueryTarget, rows: [QueryDisplayRow], columns: [ResolvedField], sortedColumn: Int?,
        entityInfo: [QueryEntityID: QueryResult.EntityInfo]
    ) -> CollageQueryPayload? {
        guard let entity = entity(for: target), !rows.isEmpty else { return nil }
        let column = sortedColumn.flatMap { columns.indices.contains($0) ? columns[$0] : nil } ?? columns.first
        let items = rows.prefix(maxItems).enumerated().map { index, row -> CollageItem in
            let id = row.entity
            // A cell with nothing to say ("—") puts no badge on the tile.
            let value = column.map { QueryCellText.string(row.row.cells[$0.cacheKey] ?? .missing, column: $0) }.flatMap { $0 == "—" || $0 == "…" ? nil : $0 }
            let album: String? = switch entity {
            case .artist: nil
            case .album: id.name
            case .track: entityInfo[row.entityID]?.album
            }
            return CollageItem(
                id: "q\(index)", name: id.name, artist: entity == .artist ? id.name : id.artist, album: album, metricValue: 0,
                imageURL: row.imageURL, periodLabel: row.period.map(String.init), valueText: value
            )
        }
        return CollageQueryPayload(title: title, entity: entity, items: items, valueLabel: column?.title, totalRows: rows.count)
    }
}

/// A query saved in Query, as the Collage tool's source: found, run and turned into tiles here, with the engine, data and artwork the
/// Query tool itself uses, so the tiles are the rows Query would list.
enum SavedQueryCollage {
    enum Failure: LocalizedError {
        case unreadable(String)
        case notItems(String, String)
        case invalid(String, String)
        case noRows(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "“\(name)” couldn’t be opened: it was saved by a newer version of Scroblytics, or is damaged."
            case .notItems(let name, let kind): "“\(name)” lists \(kind), which a collage can’t show. A collage is made of artists, albums or tracks."
            case .invalid(let name, let reason): "“\(name)” can’t run: \(reason)"
            case .noRows(let name): "“\(name)” has no results right now, so there is nothing to place. Open it in Query to see why."
            }
        }
    }

    /// What a saved query lists, or nil when it can't be read or lists plays or sessions (which have no collage).
    static func entity(of set: SavedConditionSet) -> TopChartsEntity? {
        guard let spec = try? QuerySpec.decode(set.specJSON) else { return nil }
        return CollageQuerySource.entity(for: spec.target)
    }

    /// The saved queries a collage can be made of, by name.
    static func eligible(_ sets: [SavedConditionSet]) -> [SavedConditionSet] {
        sets.filter { entity(of: $0) != nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Runs `set` over the whole history (or `history`, where a check supplies made-up plays) and returns its rows as collage items.
    @MainActor
    static func payload(
        for set: SavedConditionSet, container: ModelContainer, popularity: PopularityStore?, history: [ScrobbleSnapshot]? = nil
    ) async throws -> CollageQueryPayload {
        guard let spec = try? QuerySpec.decode(set.specJSON) else { throw Failure.unreadable(set.name) }
        guard CollageQuerySource.entity(for: spec.target) != nil else { throw Failure.notItems(set.name, spec.target.pluralLabel.lowercased()) }
        let registry = QueryFieldRegistry.standard
        let validated: ValidatedQuery
        do { validated = try spec.validate(against: registry) } catch { throw Failure.invalid(set.name, "\(error)") }
        let scrobbles: [ScrobbleSnapshot]
        if let history { scrobbles = history } else {
            scrobbles = try await offMain {
                try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            }
        }
        let loaded = await QuerySnapshotReader.loadAll(container: container)
        let snapshots = QuerySnapshots(
            popularity: popularity?.snapshot ?? .empty, durations: loaded.durations, bpm: loaded.bpm, releaseDates: loaded.releaseDates,
            turnover: loaded.turnover, lovedKeys: loaded.lovedKeys, flaggedKeys: loaded.flaggedKeys,
            entityTags: loaded.entityTags, libraryPresence: loaded.libraryPresence, weather: loaded.weather, images: loaded.images
        )
        let result = await Task.detached(priority: .userInitiated) { () -> QueryResult in
            let inScope = validated.spec.countedPlays(scrobbles, weather: snapshots.weather)
            let run = QueryRun(
                target: validated.spec.target, asOf: validated.spec.asOf ?? Date(), scrobbles: inScope, allTimeScrobbles: scrobbles,
                snapshots: snapshots, sessionGapMinutes: Double(validated.spec.effectiveSessionGapMinutes)
            )
            return QueryEngine.evaluate(validated, run: run)
        }.value
        let rows = QueryDisplayRow.make(from: result, imageLookup: loaded.images.lookup)
        let sorted = ShareCards.sortedColumnIndex(columns: result.columns, sorts: spec.sorts, target: spec.target, registry: registry)
        guard var payload = CollageQuerySource.payload(
            title: set.name, target: spec.target, rows: rows, columns: result.columns, sortedColumn: sorted, entityInfo: result.entityInfo
        ) else { throw Failure.noRows(set.name) }
        payload.origin = "Saved query"
        payload.pendingNote = pendingNote(result)
        return payload
    }

    /// A note when some values the query reads were still being looked up, so rows may be missing from it.
    static func pendingNote(_ result: QueryResult) -> String? {
        result.pending.isEmpty ? nil : "Some values this query reads haven’t been looked up yet, so rows may be missing. Open it in Query and press Resolve."
    }
}

/// The one place a result waits for the Collage tool to pick it up: the Query tool puts it here and asks for the tool to open.
@MainActor
@Observable
final class CollageHandoff {
    static let shared = CollageHandoff()
    private(set) var pending: CollageQueryPayload?

    func offer(_ payload: CollageQueryPayload) { pending = payload }

    /// Takes what is waiting, once.
    func take() -> CollageQueryPayload? {
        defer { pending = nil }
        return pending
    }
}
