import Foundation
import SwiftData

enum FadingFavoritesSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case peak, fade, rediscoveryScore
    var id: String { rawValue }
    var label: String {
        switch self {
        case .peak: "Biggest peak"
        case .fade: "Steepest fade"
        case .rediscoveryScore: "Rediscovery score"
        }
    }
}

/// A qualifying track's metrics — was once a real favorite (`fadingPeak` ≥ the minimum) and has since gone
/// significantly quiet (`fadingDecay` ≤ `FadingFavoritesEngine.maxDecay`). Read entirely through the Field
/// Registry's own fading columns (`QueryWrappedFields.swift`, which wrap `FadingFavoritesEngine.stats`
/// directly) — this never re-derives a peak, a decay ratio, or the rediscovery score.
///
/// Deliberately NOT sorted and carries no sparkline: these metrics don't depend on which of the three
/// sorts is active, so they're computed once per (window, minimum peak) and cached — switching sort only
/// re-orders and re-slices this same array, no re-run of the underlying whole-library scan.
struct FadingFavoriteCandidate: Identifiable, Sendable {
    let id: QueryEntityID
    let artist: String
    let title: String
    let peakPlays: Int
    let recentPlays: Int
    /// Recent plays as a fraction of the peak — 0 = gone silent, 1 = still at its peak.
    let decayRatio: Double
    let rediscoveryScore: Double
    let firstPlayed: Date
    /// The [start, end] of the peak-density window — when it actually happened, not just how big it was.
    let peakWindowStart: Date
    let peakWindowEnd: Date
}

struct FadingFavoriteRow: Identifiable, Sendable {
    let id: QueryEntityID
    let artist: String
    let title: String
    let peakPlays: Int
    let recentPlays: Int
    let decayRatio: Double
    let rediscoveryScore: Double
    let firstPlayed: Date
    let peakWindowStart: Date
    let peakWindowEnd: Date
    /// Daily play counts from `firstPlayed` to now — the exact same component (and framing) Most
    /// Recent, Most Often uses, since the peak-then-quiet shape this tool is about is literally what it draws.
    /// Built only for rows that actually make it into view (post sort + row limit) — the one part of this
    /// pipeline that scales with what's on screen, not with the whole qualifying set.
    let sparkline: [TrendBucket]
}

struct FadingFavorites: Sendable {
    let rows: [FadingFavoriteRow]
    let windowDays: Int
    let minPeak: Int
    let sort: FadingFavoritesSort
    /// The #1 row under the CURRENT sort and thresholds — the headline reads this directly, so it can
    /// never disagree with the list shown right below it.
    var headline: FadingFavoriteRow? { rows.first }
}

enum FadingFavoritesEngineTool {
    /// The nearest of `FadingFavoritesEngine.allowedDays` to an arbitrary day count — same reconciliation
    /// `TheClimbEngine.snappedWindow` already does for the climbing fields' own allowed-window list.
    static func snappedWindow(forDays days: Int) -> Int {
        FadingFavoritesEngine.allowedDays.min(by: { abs($0 - days) < abs($1 - days) }) ?? 90
    }

    /// The expensive, sort-independent part: one whole-library pass (via the Field Registry's fading
    /// columns, which wrap `FadingFavoritesEngine.stats`'s own sliding-window scan) plus the qualification
    /// guards. `scrobbles` must have canonical artist names. Real-"now" mode (no `spec.period`) — unlike
    /// the Overview card, which evaluates decay relative to the page's selected date range's end.
    static func computeCandidates(
        scrobbles: [ScrobbleSnapshot], windowDays days: Int, minPeak: Int, now: Date = Date()
    ) -> (candidates: [FadingFavoriteCandidate], windowDays: Int)? {
        let windowDays = snappedWindow(forDays: days)
        let windowParam: [String: QueryValue] = ["windowDays": .number(Double(windowDays))]
        func field(_ id: String) -> QueryFieldRef { QueryFieldRef(id, parameters: windowParam) }

        var spec = QuerySpec(target: .track)
        spec.columns = [
            field("fadingPeak"), field("fadingRecent"), field("fadingDecay"), field("rediscoveryScore"),
            field("fadingPeakStart"), field("fadingPeakEnd"), QueryFieldRef("firstPlayed"),
        ]
        spec.asOf = now
        guard let validated = try? spec.validate(against: .standard) else { return nil }
        let run = QueryRun(target: .track, asOf: now, scrobbles: scrobbles, allTimeScrobbles: scrobbles)
        let result = QueryEngine.evaluate(validated, run: run)
        guard let peakKey = result.columns.first(where: { $0.field.id == "fadingPeak" })?.cacheKey,
              let recentKey = result.columns.first(where: { $0.field.id == "fadingRecent" })?.cacheKey,
              let decayKey = result.columns.first(where: { $0.field.id == "fadingDecay" })?.cacheKey,
              let scoreKey = result.columns.first(where: { $0.field.id == "rediscoveryScore" })?.cacheKey,
              let peakStartKey = result.columns.first(where: { $0.field.id == "fadingPeakStart" })?.cacheKey,
              let peakEndKey = result.columns.first(where: { $0.field.id == "fadingPeakEnd" })?.cacheKey,
              let firstKey = result.columns.first(where: { $0.field.id == "firstPlayed" })?.cacheKey else { return nil }

        func number(_ cell: QueryCell?) -> Double? { if case .value(.number(let n))? = cell { return n } else { return nil } }
        func date(_ cell: QueryCell?) -> Date? { if case .value(.date(let d))? = cell { return d } else { return nil } }

        var candidates: [FadingFavoriteCandidate] = []
        for row in result.rows {
            guard let peak = number(row.cells[peakKey]), peak >= Double(minPeak) else { continue }
            guard let decay = number(row.cells[decayKey]), decay <= FadingFavoritesEngine.maxDecay else { continue }
            guard let recent = number(row.cells[recentKey]), let score = number(row.cells[scoreKey]),
                  let first = date(row.cells[firstKey]),
                  let peakStart = date(row.cells[peakStartKey]), let peakEnd = date(row.cells[peakEndKey]) else { continue }
            candidates.append(FadingFavoriteCandidate(
                id: row.entity.id, artist: row.entity.id.artist, title: row.entity.id.name,
                peakPlays: Int(peak), recentPlays: Int(recent), decayRatio: decay, rediscoveryScore: score,
                firstPlayed: first, peakWindowStart: peakStart, peakWindowEnd: peakEnd
            ))
        }
        return (candidates, windowDays)
    }

    /// Cheap in-memory re-ordering — no re-run of the underlying scan. Ties matter here more than they
    /// might look: a fully-silent track is decayRatio == 0 exactly, and with a real library that's a large
    /// tied group — the same reason Overview's own card breaks a rediscoveryScore tie by peak before
    /// falling back to recency (`FadingFavoritesEngine.fetch`). Every sort here follows that same chain:
    /// its own key, then peak (the biggest former favorite wins a tie), then title, so ties never resolve
    /// to plain alphabetical order.
    static func sorted(_ candidates: [FadingFavoriteCandidate], by sort: FadingFavoritesSort) -> [FadingFavoriteCandidate] {
        switch sort {
        case .peak:
            return candidates.sorted { a, b in
                if a.peakPlays != b.peakPlays { return a.peakPlays > b.peakPlays }
                if a.rediscoveryScore != b.rediscoveryScore { return a.rediscoveryScore > b.rediscoveryScore }
                return a.title < b.title
            }
        case .fade:
            // A lower fraction remaining IS the steeper fade — 0% is as steep as it gets.
            return candidates.sorted { a, b in
                if a.decayRatio != b.decayRatio { return a.decayRatio < b.decayRatio }
                if a.peakPlays != b.peakPlays { return a.peakPlays > b.peakPlays }
                return a.title < b.title
            }
        case .rediscoveryScore:
            return candidates.sorted { a, b in
                if a.rediscoveryScore != b.rediscoveryScore { return a.rediscoveryScore > b.rediscoveryScore }
                if a.peakPlays != b.peakPlays { return a.peakPlays > b.peakPlays }
                return a.title < b.title
            }
        }
    }

    /// Builds sparklines only for the given candidates — call this AFTER sorting and slicing to the row
    /// limit, so the one genuinely per-row-costly step scales with what's actually shown, not with the
    /// whole qualifying set (which can be much larger than the limit).
    static func rows(for candidates: [FadingFavoriteCandidate], scrobbles: [ScrobbleSnapshot], now: Date = Date()) -> [FadingFavoriteRow] {
        candidates.map { c in
            let sparkline = TrendEngine.fetch(
                scrobbles: scrobbles, artist: c.artist, album: nil, track: c.title,
                range: DateRange(from: c.firstPlayed, to: now)
            )
            return FadingFavoriteRow(
                id: c.id, artist: c.artist, title: c.title, peakPlays: c.peakPlays, recentPlays: c.recentPlays,
                decayRatio: c.decayRatio, rediscoveryScore: c.rediscoveryScore, firstPlayed: c.firstPlayed,
                peakWindowStart: c.peakWindowStart, peakWindowEnd: c.peakWindowEnd, sparkline: sparkline
            )
        }
    }

    /// One-shot convenience combining all three steps above, for callers (the debug hook, tests) that just
    /// want the full, sorted result and don't need the sort-switch caching the Tool view does.
    static func compute(
        scrobbles: [ScrobbleSnapshot], windowDays days: Int, minPeak: Int, sort: FadingFavoritesSort, now: Date = Date()
    ) -> FadingFavorites? {
        guard let (candidates, windowDays) = computeCandidates(scrobbles: scrobbles, windowDays: days, minPeak: minPeak, now: now),
              !candidates.isEmpty else { return nil }
        let ordered = sorted(candidates, by: sort)
        let finalRows = rows(for: ordered, scrobbles: scrobbles, now: now)
        return FadingFavorites(rows: finalRows, windowDays: windowDays, minPeak: minPeak, sort: sort)
    }

    /// The equivalent condition set for "Advanced" — the same two guards, sorted by whichever dimension
    /// is currently active.
    static func spec(windowDays days: Int, minPeak: Int, sort: FadingFavoritesSort) -> QuerySpec {
        let windowDays = snappedWindow(forDays: days)
        let windowParam: [String: QueryValue] = ["windowDays": .number(Double(windowDays))]
        var spec = QuerySpec(target: .track)
        spec.groups = [[
            QueryCondition(QueryFieldRef("fadingPeak", parameters: windowParam), .greaterThanOrEqual, [.number(Double(minPeak))]),
            QueryCondition(QueryFieldRef("fadingDecay", parameters: windowParam), .lessThanOrEqual, [.number(FadingFavoritesEngine.maxDecay)]),
        ]]
        let sortField = sort == .peak ? "fadingPeak" : sort == .fade ? "fadingDecay" : "rediscoveryScore"
        spec.sorts = [QuerySort(key: .field(QueryFieldRef(sortField, parameters: windowParam)), direction: sort == .fade ? .ascending : .descending)]
        spec.columns = ["fadingPeak", "fadingRecent", "fadingDecay", "rediscoveryScore", "fadingPeakStart", "fadingPeakEnd"]
            .map { QueryFieldRef($0, parameters: windowParam) }
        return spec
    }
}

#if DEBUG
/// Verification hook: with `SCROBLYTICS_FADING_DUMP=/path/out.tsv` set (and optionally
/// `SCROBLYTICS_FADING_WINDOW`/`SCROBLYTICS_FADING_MINPEAK`/`SCROBLYTICS_FADING_SORT`), computes Fading
/// Favorites against the real store at launch, writes it, and quits.
enum FadingFavoritesDebugEval {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_FADING_DUMP"] else { return }
        HeadlessTask.run("FadingFavoritesDebugEval") {
            let context = container.mainContext
            let raw = try context.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
            let scrobbles = QueryIdentity.canonicalizingArtists(raw)
            let windowDays = Int(ProcessInfo.processInfo.environment["SCROBLYTICS_FADING_WINDOW"] ?? "") ?? 90
            let minPeak = Int(ProcessInfo.processInfo.environment["SCROBLYTICS_FADING_MINPEAK"] ?? "") ?? FadingFavoritesEngine.minPeak
            let sort = FadingFavoritesSort(rawValue: ProcessInfo.processInfo.environment["SCROBLYTICS_FADING_SORT"] ?? "") ?? .rediscoveryScore
            let result = FadingFavoritesEngineTool.compute(scrobbles: scrobbles, windowDays: windowDays, minPeak: minPeak, sort: sort)
            let lines = (result?.rows ?? []).map { r in
                "\(r.artist)\t\(r.title)\t\(r.peakPlays)\t\(r.recentPlays)\t\(r.decayRatio)\t\(r.rediscoveryScore)\t\(r.peakWindowStart)\t\(r.peakWindowEnd)"
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif
