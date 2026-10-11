import Foundation

/// How the leaders of the period rose and fell: the period's top N artists / albums / tracks, and where each of them
/// ranked in every week, month or year of it. Ranks are Query's own "Play rank" (ties broken as in Top Charts), read
/// bucket by bucket from the Query engine, so a point means exactly what the same column in Query would say.
struct TrendsRankBump: Sendable {
    enum Bucketing: Sendable {
        case week, month, year

        var label: String { self == .week ? "week" : self == .month ? "month" : "year" }

        static func forRange(_ range: DateRange) -> Bucketing {
            let days = range.to.timeIntervalSince(range.from) / 86400
            return days <= 80 ? .week : days <= 1500 ? .month : .year
        }

        func start(of date: Date) -> Date {
            let calendar = AppCalendars.listening
            switch self {
            case .week: return calendar.dateInterval(of: .weekOfYear, for: date)!.start
            case .month: return calendar.dateInterval(of: .month, for: date)!.start
            case .year: return calendar.dateInterval(of: .year, for: date)!.start
            }
        }

        func next(after start: Date) -> Date {
            let calendar = AppCalendars.listening
            switch self {
            case .week: return calendar.date(byAdding: .day, value: 7, to: start)!
            case .month: return calendar.date(byAdding: .month, value: 1, to: start)!
            case .year: return calendar.date(byAdding: .year, value: 1, to: start)!
            }
        }

        func name(_ start: Date) -> String {
            switch self {
            case .week: "Week of " + start.formatted(.dateTime.month(.abbreviated).day().year())
            case .month: start.formatted(.dateTime.month(.wide).year())
            case .year: start.formatted(.dateTime.year())
            }
        }
    }

    struct Bucket: Identifiable, Sendable {
        let index: Int
        let start: Date
        /// Clipped to the selected period.
        let from: Date
        let to: Date
        var id: Int { index }
    }

    struct Series: Identifiable, Sendable {
        let id: QueryEntityID
        let title: String
        let subtitle: String?
        /// Rank in each bucket (1 = most played), nil when outside that bucket's top N or not played.
        let ranks: [Int?]
        /// Rank over the whole period.
        let overallRank: Int
    }

    let target: QueryTarget
    let topN: Int
    let bucketing: Bucketing
    let buckets: [Bucket]
    let series: [Series]
    let range: DateRange

    func title(_ id: QueryEntityID) -> String { id.target == .artist ? id.artist : id.name }
}

enum TrendsRankBumpEngine {
    /// `scrobbles` must be sorted by time with canonical artist names.
    static func compute(
        scrobbles: [ScrobbleSnapshot], target: QueryTarget, topN: Int, range: DateRange,
        metric: TrendsMetric = .plays, durations: DurationEngine.Snapshot = .empty, now: Date = Date()
    ) -> TrendsRankBump? {
        // Plays: Query's own "Play rank" (ties broken as in Top Charts). Time listened: no such field exists to wrap,
        // so the raw per-entity total is read and ranked here, the same tie rule (by artist, then title).
        let valueField = metric == .plays ? "playRank" : "timeListened"
        var spec = QuerySpec(target: target)
        spec.columns = [QueryFieldRef(valueField)]
        spec.asOf = now
        guard let validated = try? spec.validate(against: .standard) else { return nil }
        let snapshots = metric == .plays ? QuerySnapshots.empty : QuerySnapshots(durations: durations)

        /// Every entity's rank, keyed by entity.
        func ranks(_ plays: [ScrobbleSnapshot]) -> [QueryEntityID: Int] {
            let run = QueryRun(target: target, asOf: now, scrobbles: plays, allTimeScrobbles: scrobbles, snapshots: snapshots)
            let result = QueryEngine.evaluate(validated, run: run)
            guard let key = result.columns.first(where: { $0.field.id == valueField })?.cacheKey else { return [:] }
            if metric == .plays {
                var out: [QueryEntityID: Int] = [:]
                for row in result.rows { if case .value(.number(let n))? = row.cells[key] { out[row.entity.id] = Int(n) } }
                return out
            }
            // Rank by the raw value ourselves: highest first, ties by artist then title.
            let ranked = result.rows.compactMap { row -> (QueryEntityID, Double)? in
                guard case .value(.number(let n))? = row.cells[key] else { return nil }
                return (row.entity.id, n)
            }.sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.artist != b.0.artist { return a.0.artist < b.0.artist }
                return a.0.name < b.0.name
            }
            return Dictionary(uniqueKeysWithValues: ranked.enumerated().map { (i, entry) in (entry.0, i + 1) })
        }

        let inRange = scrobbles.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
        let overall = ranks(inRange)
        let cohort = overall.filter { $0.value <= topN }.sorted { $0.value < $1.value }
        guard !cohort.isEmpty else { return nil }

        let bucketing = TrendsRankBump.Bucketing.forRange(range)
        var buckets: [TrendsRankBump.Bucket] = []
        var cursor = bucketing.start(of: range.from)
        let end = bucketing.start(of: range.to)
        while cursor <= end {
            let next = bucketing.next(after: cursor)
            buckets.append(.init(index: buckets.count, start: cursor, from: max(cursor, range.from), to: min(next.addingTimeInterval(-1), range.to)))
            cursor = next
        }

        var perBucket: [[QueryEntityID: Int]] = []
        for bucket in buckets {
            let plays = inRange.filter { $0.playedAt >= bucket.from && $0.playedAt <= bucket.to }
            perBucket.append(plays.isEmpty ? [:] : ranks(plays))
        }

        let series = cohort.map { entry -> TrendsRankBump.Series in
            let id = entry.key
            return .init(
                id: id, title: target == .artist ? id.artist : id.name, subtitle: target == .artist ? nil : id.artist,
                ranks: perBucket.map { $0[id].flatMap { $0 <= topN ? $0 : nil } }, overallRank: entry.value
            )
        }
        return TrendsRankBump(target: target, topN: topN, bucketing: bucketing, buckets: buckets, series: series, range: range)
    }
}
