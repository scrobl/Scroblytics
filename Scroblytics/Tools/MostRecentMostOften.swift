import Foundation
import SwiftData

/// One track that qualifies: discovered within the recency window, played at least the minimum number of
/// times since. Read entirely through the Query engine (plays, days since first played, first/last played)
/// so a row's numbers agree with what Query itself would show for the same track — this never re-derives
/// "how many times has this been played" or "when was it first played" on its own.
struct MostRecentMostOftenRow: Identifiable, Sendable {
    let id: QueryEntityID
    let artist: String
    let title: String
    let plays: Int
    let daysSinceFirstPlayed: Int
    let firstPlayed: Date
    let lastPlayed: Date
    /// Daily play counts from `firstPlayed` to now — the front-loaded-burst visual. Built with the same
    /// `TrendEngine.fetch` Overview's Top Picks sparkline already uses, not a new implementation.
    let sparkline: [TrendBucket]

    /// Plays per day since discovery — the tool's own primary metric. `daysSinceFirstPlayed` is floored at
    /// 1 HERE ONLY (never in the Query field itself, which correctly reports 0 for something first played
    /// today) so a same-day discovery gets a finite velocity instead of a divide-by-zero/infinite value.
    var velocity: Double { Double(plays) / Double(max(1, daysSinceFirstPlayed)) }
}

enum MostRecentMostOftenSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case velocity, plays
    var id: String { rawValue }
    var label: String { self == .velocity ? "Velocity" : "Plays" }
}

struct MostRecentMostOften: Sendable {
    let rows: [MostRecentMostOftenRow]
    let recencyWindowDays: Int
    let minPlays: Int
    let sort: MostRecentMostOftenSort

    /// The #1 row under the CURRENT sort and thresholds — the headline callout reads this directly, so it
    /// can never disagree with the list shown right below it.
    var headline: MostRecentMostOftenRow? { rows.first }
}

enum MostRecentMostOftenEngine {
    /// `scrobbles` must have canonical artist names (`QueryIdentity.canonicalizingArtists`) — a track's
    /// plays and discovery date are tracked across artist-spelling variants, matching Query's own identity.
    static func compute(
        scrobbles: [ScrobbleSnapshot], recencyWindowDays: Int, minPlays: Int, sort: MostRecentMostOftenSort, now: Date = Date()
    ) -> MostRecentMostOften? {
        var spec = QuerySpec(target: .track)
        spec.groups = [[
            QueryCondition("daysSinceFirstPlayed", .lessThanOrEqual, [.number(Double(recencyWindowDays))]),
            QueryCondition("plays", .greaterThanOrEqual, [.number(Double(minPlays))]),
        ]]
        spec.columns = [QueryFieldRef("plays"), QueryFieldRef("daysSinceFirstPlayed"), QueryFieldRef("firstPlayed"), QueryFieldRef("lastPlayed")]
        spec.asOf = now
        guard let validated = try? spec.validate(against: .standard) else { return nil }

        let run = QueryRun(target: .track, asOf: now, scrobbles: scrobbles, allTimeScrobbles: scrobbles)
        let result = QueryEngine.evaluate(validated, run: run)
        guard let playsKey = result.columns.first(where: { $0.field.id == "plays" })?.cacheKey,
              let daysKey = result.columns.first(where: { $0.field.id == "daysSinceFirstPlayed" })?.cacheKey,
              let firstKey = result.columns.first(where: { $0.field.id == "firstPlayed" })?.cacheKey,
              let lastKey = result.columns.first(where: { $0.field.id == "lastPlayed" })?.cacheKey else { return nil }

        var rows: [MostRecentMostOftenRow] = []
        for row in result.rows {
            guard case .value(.number(let p))? = row.cells[playsKey],
                  case .value(.number(let d))? = row.cells[daysKey],
                  case .value(.date(let first))? = row.cells[firstKey],
                  case .value(.date(let last))? = row.cells[lastKey] else { continue }
            let sparkline = TrendEngine.fetch(
                scrobbles: scrobbles, artist: row.entity.id.artist, album: nil, track: row.entity.id.name,
                range: DateRange(from: first, to: now)
            )
            rows.append(MostRecentMostOftenRow(
                id: row.entity.id, artist: row.entity.id.artist, title: row.entity.id.name,
                plays: Int(p), daysSinceFirstPlayed: Int(d), firstPlayed: first, lastPlayed: last, sparkline: sparkline
            ))
        }
        guard !rows.isEmpty else { return nil }

        switch sort {
        case .velocity: rows.sort { $0.velocity != $1.velocity ? $0.velocity > $1.velocity : $0.plays > $1.plays }
        case .plays: rows.sort { $0.plays != $1.plays ? $0.plays > $1.plays : $0.velocity > $1.velocity }
        }
        return MostRecentMostOften(rows: rows, recencyWindowDays: recencyWindowDays, minPlays: minPlays, sort: sort)
    }

    /// The equivalent condition set for "Advanced" — same thresholds, handed to Query as an ordinary,
    /// further-editable spec rather than a second filter representation.
    static func spec(recencyWindowDays: Int, minPlays: Int) -> QuerySpec {
        var spec = QuerySpec(target: .track)
        spec.groups = [[
            QueryCondition("daysSinceFirstPlayed", .lessThanOrEqual, [.number(Double(recencyWindowDays))]),
            QueryCondition("plays", .greaterThanOrEqual, [.number(Double(minPlays))]),
        ]]
        spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
        spec.columns = [QueryFieldRef("plays"), QueryFieldRef("daysSinceFirstPlayed"), QueryFieldRef("firstPlayed")]
        return spec
    }
}

#if DEBUG
/// Verification hook: with `SCROBLYTICS_MRMO_DUMP=/path/out.tsv` set (and optionally
/// `SCROBLYTICS_MRMO_WINDOW`/`SCROBLYTICS_MRMO_MINPLAYS`), computes this tool's own list against the real
/// store at launch, writes it, and quits — so it can be diffed against an independent read of the same
/// store, the same discipline `TimelineDebugDump`/`AskDebugEval` already use.
enum MostRecentMostOftenDebugEval {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_MRMO_DUMP"] else { return }
        Task { @MainActor in
            let context = container.mainContext
            let raw = try context.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
            let scrobbles = QueryIdentity.canonicalizingArtists(raw)
            let windowDays = Int(ProcessInfo.processInfo.environment["SCROBLYTICS_MRMO_WINDOW"] ?? "") ?? 90
            let minPlays = Int(ProcessInfo.processInfo.environment["SCROBLYTICS_MRMO_MINPLAYS"] ?? "") ?? 5
            let sort = MostRecentMostOftenSort(rawValue: ProcessInfo.processInfo.environment["SCROBLYTICS_MRMO_SORT"] ?? "") ?? .velocity
            let result = MostRecentMostOftenEngine.compute(scrobbles: scrobbles, recencyWindowDays: windowDays, minPlays: minPlays, sort: sort)
            let lines = (result?.rows ?? []).map { r in "\(r.artist)\t\(r.title)\t\(r.plays)\t\(r.daysSinceFirstPlayed)\t\(r.velocity)" }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif
