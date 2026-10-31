import Foundation
import SwiftData

/// What a Top Charts list is made of, enough to run it again: the chart's kind, the period by its preset (so "Last 30 days" moves
/// on and "2026" stays), what it is ranked by, and how many rows it has.
struct TopChartsPlaylistRecipe: Codable, Equatable, Sendable {
    var entity: TopChartsEntity
    var rangeID: String
    var metric: TopChartsMetric
    var rowLimit: Int

    /// How the list is described in the list of automatic playlists and in the dialog: "Top tracks · 2026 · by plays · 100 rows".
    func summary(periodLabel: String) -> String {
        "Top \(entity.displayName.lowercased()) · \(periodLabel) · by \(metric == .timeListened ? "time listened" : "plays") · \(rowLimit) rows"
    }
}

/// Most Recent, Most Often with its thresholds, ordering and row limit (0 = all).
struct MostRecentMostOftenPlaylistRecipe: Codable, Equatable, Sendable {
    var windowDays: Int
    var minPlays: Int
    var sort: MostRecentMostOftenSort
    var rowLimit: Int

    var summary: String {
        "Most Recent, Most Often · discovered in the last \(windowDays) days · \(minPlays)+ plays · by \(sort == .velocity ? "speed" : "plays") · \(rowLimit == 0 ? "all rows" : "\(rowLimit) rows")"
    }
}

/// The list an automatic playlist is made from, saved with it so each refresh can run the same list again. Only lists that can be run
/// again have one: a list built from a random walk or from one answer of Last.fm would give a different list every time.
enum AutoPlaylistRecipe: Equatable, Sendable {
    case topCharts(TopChartsPlaylistRecipe)
    /// A Query whose rows are tracks.
    case query(QuerySpec)
    case mostRecentMostOften(MostRecentMostOftenPlaylistRecipe)

    static let topChartsKind = "topCharts"
    static let queryKind = "query"
    static let mostRecentMostOftenKind = "mostRecentMostOften"

    var kind: String {
        switch self {
        case .topCharts: Self.topChartsKind
        case .query: Self.queryKind
        case .mostRecentMostOften: Self.mostRecentMostOftenKind
        }
    }

    func encodedData() throws -> Data {
        switch self {
        case .topCharts(let recipe): try JSONEncoder().encode(recipe)
        case .query(let spec): try spec.encoded()
        case .mostRecentMostOften(let recipe): try JSONEncoder().encode(recipe)
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
        case Self.mostRecentMostOftenKind:
            guard let recipe = try? JSONDecoder().decode(MostRecentMostOftenPlaylistRecipe.self, from: data) else { return nil }
            self = .mostRecentMostOften(recipe)
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
        case .mostRecentMostOften(let tool):
            let all = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            let computed = await Task.detached(priority: .utility) {
                MostRecentMostOftenEngine.compute(scrobbles: all, recencyWindowDays: tool.windowDays, minPlays: tool.minPlays, sort: tool.sort)
            }.value
            let rows = MostRecentMostOftenEngine.limited(computed?.rows ?? [], to: tool.rowLimit)
            let lookup = (try? ImageResolutionEngine.imageLookup(context: container.mainContext)) ?? [:]
            return MostRecentMostOftenEngine.playlistTracks(rows: rows, scrobbles: all, lookup: lookup)
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

/// What the list of automatic playlists does to a saved playlist, apart from refreshing it.
enum AutoPlaylistStore {
    /// Stops keeping the playlist up to date. The playlist stays in Music as it is.
    static func stopUpdating(_ list: AutoPlaylist, context: ModelContext) throws {
        context.delete(list)
        try context.save()
    }

    /// For a playlist that was deleted in Music: forget the old one, so the next refresh makes it again under the same name.
    static func makeAgain(_ list: AutoPlaylist) {
        list.playlistPersistentID = ""
        list.lastStatus = AutoPlaylistStatus.neverRun.rawValue
        list.lastDetail = ""
    }

    /// The saved queries an automatic playlist can be made from: those that list tracks and can run, by name.
    static func eligibleQueries(_ sets: [SavedConditionSet]) -> [(set: SavedConditionSet, spec: QuerySpec)] {
        sets.compactMap { set -> (SavedConditionSet, QuerySpec)? in
            guard let spec = try? QuerySpec.decode(set.specJSON), spec.target == .track,
                  (try? spec.validate(against: QueryFieldRegistry.standard)) != nil else { return nil }
            return (set, spec)
        }
        .sorted { $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }
    }
}
