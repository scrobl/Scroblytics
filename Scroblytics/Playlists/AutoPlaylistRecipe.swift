import Foundation
import SwiftData

/// What a Top Charts list is made of, enough to run it again: the chart's kind, the period by its preset (so "Last 30 days" moves
/// on and "2026" stays), what it is ranked by, and how many rows it has.
struct TopChartsPlaylistRecipe: Codable, Equatable, Sendable {
    var entity: TopChartsEntity
    var rangeID: String
    var metric: TopChartsMetric
    var rowLimit: Int
}

/// The list an automatic playlist is made from, saved with it so each refresh can run the same list again. Only lists that can be run
/// again have one: a list built from a random walk or from one answer of Last.fm would give a different list every time.
enum AutoPlaylistRecipe: Equatable, Sendable {
    case topCharts(TopChartsPlaylistRecipe)
    /// A Query whose rows are tracks.
    case query(QuerySpec)

    static let topChartsKind = "topCharts"
    static let queryKind = "query"

    var kind: String {
        switch self {
        case .topCharts: Self.topChartsKind
        case .query: Self.queryKind
        }
    }

    func encodedData() throws -> Data {
        switch self {
        case .topCharts(let recipe): try JSONEncoder().encode(recipe)
        case .query(let spec): try spec.encoded()
        }
    }

    /// nil when the saved data can't be read (written by a newer version, or damaged).
    init?(kind: String, data: Data) {
        switch kind {
        case Self.topChartsKind:
            guard let recipe = try? JSONDecoder().decode(TopChartsPlaylistRecipe.self, from: data) else { return nil }
            self = .topCharts(recipe)
        case Self.queryKind:
            guard let spec = try? QuerySpec.decode(data) else { return nil }
            self = .query(spec)
        default:
            return nil
        }
    }

    init?(playlist: AutoPlaylist) { self.init(kind: playlist.recipeKind, data: playlist.recipeData) }
}

/// Runs a recipe: the tracks of the list as it is now, in rank order.
enum AutoPlaylistSources {
    enum SourceError: LocalizedError {
        case unreadableRecipe
        case rangeGone
        case invalidQuery(String)
        case notTracks

        var errorDescription: String? {
            switch self {
            case .unreadableRecipe: "The list this playlist is made from can't be read (it was saved by a newer version of Scroblytics, or is damaged)."
            case .rangeGone: "The period this chart used is no longer available."
            case .invalidQuery(let reason): "The query can't run: \(reason)"
            case .notTracks: "The query doesn't list tracks."
            }
        }
    }

    @MainActor
    static func tracks(
        for recipe: AutoPlaylistRecipe, container: ModelContainer, popularity: PopularityStore?, history: [ScrobbleSnapshot]? = nil
    ) async throws -> [AppleMusicPlaylistTrack] {
        switch recipe {
        case .topCharts(let chart):
            let oldest = try? await TopChartsEngine.fetchOldestScrobbleDate(container: container)
            guard let option = DateRangePresets.build(oldestScrobbleDate: oldest).first(where: { $0.id == chart.rangeID }) else {
                throw SourceError.rangeGone
            }
            let range = option.range()
            let entries = try await TopChartsEngine.fetchRankings(
                container: container, durationContext: container.mainContext, entity: chart.entity, range: range, compareRange: nil,
                limit: chart.rowLimit, includePeak: false, metric: chart.metric
            )
            return try await AppleMusicPlaylistBuilder.chartTracks(
                entries: entries, entity: chart.entity, range: range, metric: chart.metric, container: container, context: container.mainContext
            )
        case .query(let spec):
            guard spec.target == .track else { throw SourceError.notTracks }
            let validated: ValidatedQuery
            do { validated = try spec.validate(against: QueryFieldRegistry.standard) } catch { throw SourceError.invalidQuery("\(error)") }
            let (result, _) = try await QueryHeadlessRunner.run(validated, container: container, popularity: popularity, history: history)
            return queryTracks(result)
        }
    }

    /// The rows of a track query as playlist tracks, in the order the query lists them.
    static func queryTracks(_ result: QueryResult) -> [AppleMusicPlaylistTrack] {
        result.rows.compactMap { row in
            guard row.entity.target == .track, !row.entity.artist.isEmpty else { return nil }
            return AppleMusicPlaylistTrack(artist: row.entity.artist, track: row.entity.name, album: result.entityInfo[row.id]?.album ?? "")
        }
    }
}
