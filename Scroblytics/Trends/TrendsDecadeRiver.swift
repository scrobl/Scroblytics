import Foundation

/// "Eras": for each week / month / year of the period, the share of listening by the release decade of what was
/// played. Release years come from the Query engine's own `releaseYear` field (a track's own date, else its main
/// album's), so what counts as "a 1990s track" is exactly what Query says, and a band opens Query on those plays.
struct TrendsDecadeRiver: Sendable {
    /// The fixed set of decades, oldest first; everything before 1970 shares one band.
    static let decades = ["1960s & earlier", "1970s", "1980s", "1990s", "2000s", "2010s", "2020s"]

    /// The band a release year falls in.
    static func decadeIndex(forYear year: Int) -> Int { max(0, min(decades.count - 1, (year - 1960) / 10)) }

    /// The years a band covers, for Query (the first and last bands are open-ended).
    static func yearRange(ofDecade index: Int) -> (from: Int?, to: Int?) {
        (index == 0 ? nil : 1960 + index * 10, index == decades.count - 1 ? nil : 1960 + index * 10 + 9)
    }

    struct Point: Identifiable, Sendable {
        let index: Int
        let start: Date
        let from: Date
        let to: Date
        /// Plays per decade band (`decades` order) whose release year is known.
        let counts: [Int]
        /// The same plays by exact release year.
        let years: [Int: Int]
        /// Plays still waiting for a release-date lookup, and plays with none on record.
        let pending: Int
        let noDate: Int
        var id: Int { index }
        var total: Int { counts.reduce(0, +) }
    }

    let target: QueryTarget
    let bucketing: TrendsRankBump.Bucketing
    let range: DateRange
    let compareRange: DateRange?
    let metric: TrendsMetric
    let points: [Point]
    let comparePoints: [Point]?

    var pending: Int { points.reduce(0) { $0 + $1.pending } }
    var noDate: Int { points.reduce(0) { $0 + $1.noDate } }
    var comparePending: Int { (comparePoints ?? []).reduce(0) { $0 + $1.pending } }
    /// Decades that appear in either period, so the two graphs share one colour key.
    var presentDecades: [Int] {
        (0..<Self.decades.count).filter { d in (points + (comparePoints ?? [])).contains { $0.counts[d] > 0 } }
    }
}

enum TrendsDecadeRiverEngine {
    /// `scrobbles` must be sorted by time with canonical artist names. `target` is `.album` or `.track`. Weighs each
    /// track's contribution to its release-year band by plays, or by time listened (needs a resolved runtime — a
    /// track whose length isn't known yet contributes nothing and is counted in `pending`, same as an unknown release
    /// date; it never silently drops from the total the way an unweighted count would hide it).
    static func compute(
        scrobbles: [ScrobbleSnapshot], snapshots: QuerySnapshots, target: QueryTarget, range: DateRange, compareRange: DateRange?,
        metric: TrendsMetric = .plays, now: Date = Date()
    ) -> TrendsDecadeRiver? {
        guard target == .album || target == .track else { return nil }
        let valueField = metric == .plays ? "plays" : "timeListened"
        var spec = QuerySpec(target: target)
        spec.columns = [QueryFieldRef("releaseYear"), QueryFieldRef("plays")] + (valueField == "plays" ? [] : [QueryFieldRef(valueField)])
        spec.asOf = now
        guard let validated = try? spec.validate(against: .standard) else { return nil }

        let bucketing = TrendsRankBump.Bucketing.forRange(range)
        func series(_ r: DateRange) -> [TrendsDecadeRiver.Point] {
            var out: [TrendsDecadeRiver.Point] = []
            var cursor = bucketing.start(of: r.from)
            let end = bucketing.start(of: r.to)
            while cursor <= end {
                let next = bucketing.next(after: cursor)
                let from = max(cursor, r.from), to = min(next.addingTimeInterval(-1), r.to)
                let plays = scrobbles.filter { $0.playedAt >= from && $0.playedAt <= to }
                var counts = Array(repeating: 0, count: TrendsDecadeRiver.decades.count)
                var years: [Int: Int] = [:]
                var pending = 0, noDate = 0
                if !plays.isEmpty {
                    let run = QueryRun(target: target, asOf: now, scrobbles: plays, allTimeScrobbles: scrobbles, snapshots: snapshots)
                    let result = QueryEngine.evaluate(validated, run: run)
                    if let yearKey = result.columns.first(where: { $0.field.id == "releaseYear" })?.cacheKey,
                       let playsKey = result.columns.first(where: { $0.field.id == "plays" })?.cacheKey,
                       let valueKey = result.columns.first(where: { $0.field.id == valueField })?.cacheKey {
                        for row in result.rows {
                            guard case .value(.number(let p))? = row.cells[playsKey] else { continue }
                            let plays = Int(p)
                            let value: Int?
                            switch row.cells[valueKey] {
                            case .value(.number(let v))?: value = Int(v)
                            case .pending?: value = nil
                            default: value = metric == .plays ? plays : 0
                            }
                            switch row.cells[yearKey] ?? .missing {
                            case .value(.number(let year)):
                                guard let value else { pending += plays; continue }
                                counts[TrendsDecadeRiver.decadeIndex(forYear: Int(year))] += value
                                years[Int(year), default: 0] += value
                            case .pending: pending += plays
                            default: noDate += plays
                            }
                        }
                    }
                }
                out.append(.init(index: out.count, start: cursor, from: from, to: to, counts: counts, years: years, pending: pending, noDate: noDate))
                cursor = next
            }
            return out
        }

        let main = series(range)
        return TrendsDecadeRiver(target: target, bucketing: bucketing, range: range, compareRange: compareRange, metric: metric, points: main, comparePoints: compareRange.map(series))
    }
}
