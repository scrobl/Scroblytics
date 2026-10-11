import Foundation

/// The Trends page's volume chart: scrobbles per time bucket over the selected period, with the comparison
/// period lined up bucket-for-bucket (by position) and running totals for both.
/// Built on `TrendEngine`'s validated bucketing rather than a second implementation.
struct TrendsVolume: Sendable {
    struct Point: Identifiable, Sendable {
        let index: Int
        /// The bucket's own dates, clipped to the selected period (the first and last bucket can be partial).
        let from: Date
        let to: Date
        /// Where the bucket starts on the calendar (a week starts Monday, a month on the 1st) — the x position.
        let start: Date
        let count: Int
        let compareStart: Date?
        let compareCount: Int?
        let cumulative: Int
        let cumulativeCompare: Int?
        var id: Int { index }
    }

    let granularity: TrendGranularity
    let points: [Point]
    let total: Int
    let compareTotal: Int?
    let range: DateRange
    let compareRange: DateRange?
    let metric: TrendsMetric
    /// Plays left out of `total` because their runtime hasn't been resolved yet (time listened only).
    let pending: Int

    /// "+12%" / "-5%" / nil when there is nothing to compare against (a zero baseline has no percentage).
    var changeLabel: String? {
        guard let compareTotal, compareTotal > 0 else { return nil }
        let pct = (Double(total) - Double(compareTotal)) / Double(compareTotal) * 100
        return (pct >= 0 ? "+" : "") + String(format: "%.0f%%", pct)
    }
}

enum TrendsEngine {
    /// Buckets `scrobbles` by `granularity`, each bucket weighted by `metric` (plays, or seconds of runtime).
    /// Time listened leaves out plays whose runtime isn't resolved yet and reports how many that was.
    private static func weightedSeries(
        _ scrobbles: [ScrobbleSnapshot], range: DateRange, granularity: TrendGranularity, metric: TrendsMetric, durations: DurationEngine.Snapshot
    ) -> (buckets: [(start: Date, value: Int)], pending: Int) {
        var sums: [Date: Int] = [:]
        var pending = 0
        for s in scrobbles where s.playedAt >= range.from && s.playedAt <= range.to {
            guard let weight = TrendsWeight.of(s, metric: metric, durations: durations) else { pending += 1; continue }
            sums[TrendEngine.bucketStart(s.playedAt, granularity: granularity), default: 0] += weight
        }
        var buckets: [(Date, Int)] = []
        var cursor = TrendEngine.bucketStart(range.from, granularity: granularity)
        let end = TrendEngine.bucketStart(range.to, granularity: granularity)
        while cursor <= end {
            buckets.append((cursor, sums[cursor] ?? 0))
            cursor = TrendEngine.nextBucket(cursor, granularity: granularity)
        }
        return (buckets, pending)
    }

    static func volume(
        scrobbles: [ScrobbleSnapshot], range: DateRange, compareRange: DateRange?,
        metric: TrendsMetric = .plays, durations: DurationEngine.Snapshot = .empty
    ) -> TrendsVolume {
        let granularity = TrendEngine.autoGranularity(range)
        let main = weightedSeries(scrobbles, range: range, granularity: granularity, metric: metric, durations: durations)
        let compare = compareRange.map { weightedSeries(scrobbles, range: $0, granularity: granularity, metric: metric, durations: durations) }

        var points: [TrendsVolume.Point] = []
        var running = 0, runningCompare = 0
        for (i, bucket) in main.buckets.enumerated() {
            let next = TrendEngine.nextBucket(bucket.start, granularity: granularity)
            let compareBucket = compare.flatMap { i < $0.buckets.count ? $0.buckets[i] : nil }
            running += bucket.value
            runningCompare += compareBucket?.value ?? 0
            points.append(TrendsVolume.Point(
                index: i,
                from: max(bucket.start, range.from), to: min(next.addingTimeInterval(-1), range.to),
                start: bucket.start, count: bucket.value,
                compareStart: compareBucket?.start, compareCount: compareBucket?.value,
                cumulative: running, cumulativeCompare: compare == nil ? nil : runningCompare
            ))
        }
        // A comparison period can span more buckets than the main one; keep their counts in the total.
        let compareTotal = compare.map { $0.buckets.reduce(0) { $0 + $1.value } }
        return TrendsVolume(
            granularity: granularity, points: points, total: running, compareTotal: compareTotal, range: range, compareRange: compareRange,
            metric: metric, pending: main.pending + (compare?.pending ?? 0)
        )
    }
}


/// "When you listen": scrobbles per local (weekday, hour) cell for the period and its comparison, with ONE colour
/// scale over both so the two grids can be compared by eye.
struct TrendsHeatmap: Sendable {
    let range: DateRange
    let compareRange: DateRange?
    /// Indexed `day * 24 + hour`, day 0 = Sunday.
    let counts: [Int]
    let compareCounts: [Int]?
    let thresholds: [Double]
    let total: Int
    let compareTotal: Int?
    let metric: TrendsMetric
    let pending: Int

    /// Weekday (0 = Sunday) and hour of the busiest cell.
    var peak: (day: Int, hour: Int, count: Int)? {
        guard let best = counts.enumerated().max(by: { $0.element < $1.element }), best.element > 0 else { return nil }
        return (best.offset / 24, best.offset % 24, best.element)
    }
}

extension TrendsEngine {
    static func heatmap(
        scrobbles: [ScrobbleSnapshot], range: DateRange, compareRange: DateRange?,
        metric: TrendsMetric = .plays, durations: DurationEngine.Snapshot = .empty
    ) -> TrendsHeatmap {
        let calendar = AppCalendars.listening
        func weighted(_ r: DateRange) -> (cells: [Int], pending: Int) {
            var cells = Array(repeating: 0, count: 168)
            var pending = 0
            for s in scrobbles where s.playedAt >= r.from && s.playedAt <= r.to {
                guard let weight = TrendsWeight.of(s, metric: metric, durations: durations) else { pending += 1; continue }
                let day = calendar.component(.weekday, from: s.playedAt) - 1
                let hour = calendar.component(.hour, from: s.playedAt)
                cells[day * 24 + hour] += weight
            }
            return (cells, pending)
        }
        let main = weighted(range)
        let compare = compareRange.map(weighted)
        return TrendsHeatmap(
            range: range, compareRange: compareRange, counts: main.cells, compareCounts: compare?.cells,
            thresholds: HeatColorScale.computeThresholds(main.cells + (compare?.cells ?? [])),
            total: main.cells.reduce(0, +), compareTotal: compare?.cells.reduce(0, +),
            metric: metric, pending: main.pending + (compare?.pending ?? 0)
        )
    }
}

/// "Top tags": the tags your plays fall under in the period, and how each compares with the comparison period.
/// Computed BY the Query engine — every track with its plays and its `tags` — so a tag's total is exactly the
/// plays of the tracks Query lists when you click it, and a track's tags mean what they mean everywhere else
/// (its own community tags or its artist's, plus yours).
struct TrendsTags: Sendable {
    struct Row: Identifiable, Sendable {
        let tag: String
        let plays: Int
        let comparePlays: Int?
        var id: String { tag }
    }

    let rows: [Row]
    let range: DateRange
    let compareRange: DateRange?
    /// Plays in the period, those on a track whose tags are known, and those still waiting for a tag lookup.
    let totalPlays: Int
    let taggedPlays: Int
    let pendingPlays: Int
    let metric: TrendsMetric
    /// Time listened only: plays counted (their tags are known) whose runtime isn't resolved, so left out of the weight.
    let pendingRuntime: Int

    /// Share of the period's plays whose tags have been looked up (tagged or known to have none).
    var lookedUpShare: Double { totalPlays == 0 ? 1 : Double(totalPlays - pendingPlays) / Double(totalPlays) }
}

enum TrendsTagsEngine {
    static func compute(
        scrobbles: [ScrobbleSnapshot], snapshots: QuerySnapshots, range: DateRange, compareRange: DateRange?,
        metric: TrendsMetric = .plays, limit: Int = 10, now: Date = Date()
    ) -> TrendsTags {
        let main = weights(scrobbles: scrobbles, snapshots: snapshots, range: range, metric: metric, now: now)
        let compare = compareRange.map { weights(scrobbles: scrobbles, snapshots: snapshots, range: $0, metric: metric, now: now) }
        let top = main.perTag.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit)
        return TrendsTags(
            rows: top.map { entry in TrendsTags.Row(tag: entry.key, plays: entry.value, comparePlays: compare.map { $0.perTag[entry.key] ?? 0 }) },
            range: range, compareRange: compareRange,
            totalPlays: main.total, taggedPlays: main.tagged, pendingPlays: main.pending, metric: metric, pendingRuntime: main.pendingRuntime
        )
    }

    private struct Weights {
        var perTag: [String: Int] = [:]
        var total = 0, tagged = 0, pending = 0, pendingRuntime = 0
    }

    private static func weights(scrobbles: [ScrobbleSnapshot], snapshots: QuerySnapshots, range: DateRange, metric: TrendsMetric, now: Date) -> Weights {
        var spec = QuerySpec(target: .track)
        spec.period = QueryPeriod(from: range.from, to: range.to)
        spec.groups = [[QueryCondition("plays", .greaterThan, [.number(0)])]]
        let valueField = metric == .plays ? "plays" : "timeListened"
        spec.columns = [QueryFieldRef("plays")] + (valueField == "plays" ? [] : [QueryFieldRef(valueField)]) + [QueryFieldRef("tags")]
        spec.asOf = now
        guard let validated = try? spec.validate(against: .standard) else { return Weights() }
        let run = QueryRun(target: .track, asOf: now, scrobbles: spec.countedPlays(scrobbles), allTimeScrobbles: scrobbles, snapshots: snapshots)
        let result = QueryEngine.evaluate(validated, run: run)
        guard let playsKey = result.columns.first(where: { $0.field.id == "plays" })?.cacheKey,
              let valueKey = result.columns.first(where: { $0.field.id == valueField })?.cacheKey,
              let tagsKey = result.columns.first(where: { $0.field.id == "tags" })?.cacheKey else { return Weights() }

        var out = Weights()
        for row in result.rows {
            guard case .value(.number(let n))? = row.cells[playsKey] else { continue }
            let plays = Int(n)
            out.total += plays
            let value: Int?
            switch row.cells[valueKey] {
            case .value(.number(let v))?: value = Int(v)
            case .pending?: value = nil
            default: value = metric == .plays ? plays : 0
            }
            switch row.cells[tagsKey] ?? .missing {
            case .value(.tags(let tags)):
                out.tagged += plays
                guard let value else { out.pendingRuntime += plays; continue }
                for tag in tags { out.perTag[tag, default: 0] += value }
            case .pending: out.pending += plays
            default: break
            }
        }
        return out
    }
}

/// "Discovery": for each time bucket, how many plays were a track's first-ever play (a discovery) and how many were
/// repeat listens. A track is the same artist (spelled as everywhere else in Query) and title, so this agrees with
/// Query's own "First played". Compare buckets line up by position, like the volume chart.
struct TrendsDiscovery: Sendable {
    struct Point: Identifiable, Sendable {
        let index: Int
        let start: Date
        let from: Date
        let to: Date
        let newCount: Int
        let repeatCount: Int
        let compareNewCount: Int?
        let compareRepeatCount: Int?
        var id: Int { index }
        var total: Int { newCount + repeatCount }
        var newPercent: Double { total == 0 ? 0 : Double(newCount) / Double(total) * 100 }
        var comparePercent: Double? {
            guard let n = compareNewCount, let r = compareRepeatCount else { return nil }
            return n + r == 0 ? 0 : Double(n) / Double(n + r) * 100
        }
    }

    let granularity: TrendGranularity
    let points: [Point]
    let range: DateRange
    let compareRange: DateRange?
    let newTotal: Int
    let repeatTotal: Int
    let compareNewTotal: Int?
    let compareRepeatTotal: Int?
    let metric: TrendsMetric
    let pending: Int

    var newPercent: Double { newTotal + repeatTotal == 0 ? 0 : Double(newTotal) / Double(newTotal + repeatTotal) * 100 }
    var comparePercent: Double? {
        guard let n = compareNewTotal, let r = compareRepeatTotal else { return nil }
        return n + r == 0 ? 0 : Double(n) / Double(n + r) * 100
    }
}

enum TrendsDiscoveryEngine {
    /// `scrobbles` must be sorted by time and have canonical artist names (`QueryIdentity.canonicalizingArtists`).
    /// Weighted by `metric`: "new" and "repeat" become time spent on each, not just counts.
    static func compute(
        scrobbles: [ScrobbleSnapshot], range: DateRange, compareRange: DateRange?,
        metric: TrendsMetric = .plays, durations: DurationEngine.Snapshot = .empty
    ) -> TrendsDiscovery {
        // Mark each track's first play, once, over the whole history.
        var seen = Set<String>()
        var isFirst: [Bool] = []
        isFirst.reserveCapacity(scrobbles.count)
        for s in scrobbles {
            guard !s.trackName.isEmpty else { isFirst.append(false); continue }
            let first = seen.insert(s.artistName + "\u{0}" + s.trackName).inserted
            isFirst.append(first)
        }

        let granularity = TrendEngine.autoGranularity(range)
        func series(_ r: DateRange) -> (buckets: [(start: Date, new: Int, repeats: Int)], pending: Int) {
            var counts: [Date: (Int, Int)] = [:]
            var pending = 0
            for (i, s) in scrobbles.enumerated() where s.playedAt >= r.from && s.playedAt <= r.to && !s.trackName.isEmpty {
                guard let weight = TrendsWeight.of(s, metric: metric, durations: durations) else { pending += 1; continue }
                let bucket = TrendEngine.bucketStart(s.playedAt, granularity: granularity)
                var c = counts[bucket] ?? (0, 0)
                if isFirst[i] { c.0 += weight } else { c.1 += weight }
                counts[bucket] = c
            }
            var out: [(Date, Int, Int)] = []
            var cursor = TrendEngine.bucketStart(r.from, granularity: granularity)
            let end = TrendEngine.bucketStart(r.to, granularity: granularity)
            while cursor <= end {
                out.append((cursor, counts[cursor]?.0 ?? 0, counts[cursor]?.1 ?? 0))
                cursor = TrendEngine.nextBucket(cursor, granularity: granularity)
            }
            return (out, pending)
        }

        let main = series(range)
        let compare = compareRange.map(series)
        var points: [TrendsDiscovery.Point] = []
        for (i, bucket) in main.buckets.enumerated() {
            let next = TrendEngine.nextBucket(bucket.start, granularity: granularity)
            let c = compare.flatMap { i < $0.buckets.count ? $0.buckets[i] : nil }
            points.append(TrendsDiscovery.Point(
                index: i, start: bucket.start, from: max(bucket.start, range.from), to: min(next.addingTimeInterval(-1), range.to),
                newCount: bucket.new, repeatCount: bucket.repeats, compareNewCount: c?.new, compareRepeatCount: c?.repeats
            ))
        }
        return TrendsDiscovery(
            granularity: granularity, points: points, range: range, compareRange: compareRange,
            newTotal: main.buckets.reduce(0) { $0 + $1.new }, repeatTotal: main.buckets.reduce(0) { $0 + $1.repeats },
            compareNewTotal: compare?.buckets.reduce(0) { $0 + $1.new }, compareRepeatTotal: compare?.buckets.reduce(0) { $0 + $1.repeats },
            metric: metric, pending: main.pending + (compare?.pending ?? 0)
        )
    }
}
