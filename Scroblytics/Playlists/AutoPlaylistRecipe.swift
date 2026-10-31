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

/// Chart Toppers: each period's number one, for the chosen kind, period and ranking (year range 0 = all years).
struct ChartToppersPlaylistRecipe: Codable, Equatable, Sendable {
    var entity: TopChartsEntity
    var period: CollagePeriod
    var metric: TopChartsMetric
    var yearRange: Int

    var summary: String {
        "Chart Toppers · #1 \(entity.displayName.lowercased()) by \(period.rawValue) · by \(metric == .timeListened ? "time listened" : "plays") · \(yearRange == 0 ? "all years" : "last \(yearRange) years")"
    }
}

/// Flagged Tracks as the tool lists them: the search, the loved-only switch, the ordering and the row limit (0 = all).
struct FlaggedTracksPlaylistRecipe: Codable, Equatable, Sendable {
    var sort: FlaggedTracksSort
    var rowLimit: Int
    var lovedOnly: Bool
    var searchText: String

    var summary: String {
        var text = "Flagged Tracks · \(sort.label.lowercased())"
        if lovedOnly { text += " · loved only" }
        if !searchText.isEmpty { text += " · matching “\(searchText)”" }
        return text + " · \(rowLimit == 0 ? "all rows" : "\(rowLimit) rows")"
    }
}

/// The tracks still to hear in a goal, as the goal's list shows them (its search, "Show" choice and ordering). It stores the goal's ID,
/// not a copy, so a change to the goal's settings is followed.
struct GoalPlaylistRecipe: Codable, Equatable, Sendable {
    var goalID: UUID
    var filter: GoalRemainingFilter
    var sort: GoalRemainingSort
    var search: String

    func summary(goalTitle: String) -> String {
        var text = "Goal “\(goalTitle)” · still to hear"
        if filter != .all { text += " · \(filter.label.lowercased())" }
        if !search.isEmpty { text += " · matching “\(search)”" }
        return text + " · \(sort.label(joinsOnPlay: false).lowercased())"
    }
}

/// The list an automatic playlist is made from, saved with it so each refresh can run the same list again. Only lists that can be run
/// again have one: a list built from a random walk or from one answer of Last.fm would give a different list every time.
enum AutoPlaylistRecipe: Equatable, Sendable {
    case topCharts(TopChartsPlaylistRecipe)
    /// A Query whose rows are tracks.
    case query(QuerySpec)
    case mostRecentMostOften(MostRecentMostOftenPlaylistRecipe)
    case chartToppers(ChartToppersPlaylistRecipe)
    case flaggedTracks(FlaggedTracksPlaylistRecipe)
    case goalRemaining(GoalPlaylistRecipe)

    static let topChartsKind = "topCharts"
    static let queryKind = "query"
    static let mostRecentMostOftenKind = "mostRecentMostOften"
    static let chartToppersKind = "chartToppers"
    static let flaggedTracksKind = "flaggedTracks"
    static let goalRemainingKind = "goalRemaining"

    var kind: String {
        switch self {
        case .topCharts: Self.topChartsKind
        case .query: Self.queryKind
        case .mostRecentMostOften: Self.mostRecentMostOftenKind
        case .chartToppers: Self.chartToppersKind
        case .flaggedTracks: Self.flaggedTracksKind
        case .goalRemaining: Self.goalRemainingKind
        }
    }

    /// The short description kept with the playlist when the screen has none of its own.
    var summary: String {
        switch self {
        case .topCharts(let chart): "Top \(chart.entity.displayName.lowercased()) · \(chart.rangeID)"
        case .query: "Query"
        case .mostRecentMostOften(let recipe): recipe.summary
        case .chartToppers(let recipe): recipe.summary
        case .flaggedTracks(let recipe): recipe.summary
        case .goalRemaining: "Goal · still to hear"
        }
    }

    func encodedData() throws -> Data {
        switch self {
        case .topCharts(let recipe): try JSONEncoder().encode(recipe)
        case .query(let spec): try spec.encoded()
        case .mostRecentMostOften(let recipe): try JSONEncoder().encode(recipe)
        case .chartToppers(let recipe): try JSONEncoder().encode(recipe)
        case .flaggedTracks(let recipe): try JSONEncoder().encode(recipe)
        case .goalRemaining(let recipe): try JSONEncoder().encode(recipe)
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
        case Self.chartToppersKind:
            guard let recipe = try? JSONDecoder().decode(ChartToppersPlaylistRecipe.self, from: data) else { return nil }
            self = .chartToppers(recipe)
        case Self.flaggedTracksKind:
            guard let recipe = try? JSONDecoder().decode(FlaggedTracksPlaylistRecipe.self, from: data) else { return nil }
            self = .flaggedTracks(recipe)
        case Self.goalRemainingKind:
            guard let recipe = try? JSONDecoder().decode(GoalPlaylistRecipe.self, from: data) else { return nil }
            self = .goalRemaining(recipe)
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
        case .chartToppers(let chart):
            let periods = try await ChartToppersReader(modelContainer: container).load(
                entity: chart.entity, metric: chart.metric, period: chart.period, yearRange: chart.period == .year ? chart.yearRange : 0
            )
            return ChartToppersReader.playlistTracks(periods: periods)
        case .flaggedTracks(let flagged):
            let flags = try await offMain { try await FlaggedTracksDataReader(modelContainer: container).fetch() }
            let scrobbles = try await ScrobbleHistoryCache.shared.snapshots(container: container)
            let rows = await Task.detached(priority: .utility) { FlaggedTracksEngine.rows(flags: flags, scrobbles: scrobbles) }.value
            let loved = LovedTracksEngine.lovedSet(context: container.mainContext)
            let visible = FlaggedTracksEngine.visible(
                rows, searchText: flagged.searchText, lovedOnly: flagged.lovedOnly, sort: flagged.sort, rowLimit: flagged.rowLimit,
                isLoved: { loved.contains(TextNormalization.lovedKey(artist: $0, track: $1)) }
            )
            return FlaggedTracksEngine.playlistTracks(visible)
        case .goalRemaining(let goal):
            return try await GoalPlaylistSource.tracks(goalID: goal.goalID, filter: goal.filter, sort: goal.sort, search: goal.search, container: container)
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
