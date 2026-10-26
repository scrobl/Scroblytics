import Foundation
import Observation

/// What the Query tool hands the Collage tool: the rows of a result as collage items, in the order the query put them, with the value of
/// the column the results are sorted by to show on each tile, and what to call the collage.
struct CollageQueryPayload: Equatable, Sendable {
    /// Distinct for every hand-off, so the tool notices a new one even when the rows are the same.
    let id = UUID()
    /// The question or filters the results answered ("Loved albums · released in the 90s"): the caption's title.
    var title: String
    var entity: TopChartsEntity
    var items: [CollageItem]
    /// The column whose values are on the tiles ("Plays", "Release year"); nil when the query has no column to show.
    var valueLabel: String?
    /// How many rows the query had, of which the largest grid holds only some.
    var totalRows: Int

    /// What a collage of these rows says under the picture: "Loved albums · From Query · Showing Plays · Oct 26, 2026".
    var caption: CollageCaption {
        CollageCaption(title: title, period: "From Query", measure: valueLabel.map { "Showing \($0)" } ?? "")
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
