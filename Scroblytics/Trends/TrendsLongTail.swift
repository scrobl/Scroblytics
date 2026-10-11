import Foundation

/// The value whose distribution the Long Tail chart shows, for each artist / album / track played in the period.
enum LongTailMetric: String, CaseIterable, Identifiable, Sendable {
    case plays, timeListened, daysSinceLastPlayed, duration
    var id: String { rawValue }

    var label: String {
        switch self {
        case .plays: "Plays"
        case .timeListened: "Time listened"
        case .daysSinceLastPlayed: "Days since last played"
        case .duration: "Track duration"
        }
    }

    /// The Query field this reads — the same one a column or condition of that name uses.
    var fieldID: String {
        switch self {
        case .plays: "plays"
        case .timeListened: "timeListened"
        case .daysSinceLastPlayed: "daysSinceLastPlayed"
        case .duration: "duration"
        }
    }

    var isTrackOnly: Bool { self == .duration }
    /// Whole-number values: bin edges and labels stay integers.
    var isInteger: Bool { self == .plays || self == .daysSinceLastPlayed }
    /// Rounding step for the mode, so noisy seconds still cluster.
    var modeStep: Double { self == .timeListened ? 60 : self == .duration ? 5 : 1 }
    /// Waits on a runtime lookup that may not have finished.
    var needsRuntimes: Bool { self == .timeListened || self == .duration }

    func format(_ v: Double) -> String {
        switch self {
        case .plays: return Int(v.rounded()).formatted()
        case .timeListened: return TrendsDuration.format(Int(v.rounded()))
        case .daysSinceLastPlayed: return "\(Int(v.rounded()).formatted())d"
        case .duration:
            let s = Int(v.rounded())
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    /// A shorter form for axis labels and bin ranges: times drop the smaller units ("6m", "1h 8m", "1d 17h").
    func formatCompact(_ v: Double) -> String {
        guard self == .timeListened else { return format(v) }
        return TrendsDuration.formatCompact(Int(v.rounded()))
    }

    /// For mean and median: a whole-number metric keeps a decimal when the value has one (an average of 2.65 plays
    /// is not "3").
    func formatAverage(_ v: Double) -> String {
        guard isInteger, v.rounded() != v else { return format(v) }
        return v.formatted(.number.precision(.fractionLength(1)))
    }

    static func available(for target: QueryTarget) -> [LongTailMetric] { allCases.filter { !$0.isTrackOnly || target == .track } }
}

struct LongTailBin: Identifiable, Sendable {
    let index: Int
    let lo: Double
    let hi: Double
    let isLast: Bool
    let label: String
    var count = 0
    var id: Int { index }
}

/// The population's values and how they are spread.
struct TrendsLongTail: Sendable {
    let target: QueryTarget
    let metric: LongTailMetric
    let range: DateRange
    /// Entities played in the period, and those with a value for the metric (the rest are still waiting on a lookup,
    /// or have none).
    let population: Int
    let values: [Double]
    let bins: [LongTailBin]
    /// What "the top N% account for" is measured in: time listened when that is the metric, plays otherwise.
    let concentrationMetric: LongTailMetric
    let concentrationValues: [Double]

    var pending: Int { population - values.count }

    struct Stats: Sendable { let min, max, mean, median, mode: Double }

    var stats: Stats? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        var counts: [Double: Int] = [:]
        var best = sorted[0], bestCount = 0
        for v in values {
            let key = metric.modeStep > 1 ? (v / metric.modeStep).rounded() * metric.modeStep : v.rounded()
            counts[key, default: 0] += 1
            if counts[key]! > bestCount { bestCount = counts[key]!; best = key }
        }
        return Stats(min: sorted[0], max: sorted[sorted.count - 1], mean: values.reduce(0, +) / Double(values.count), median: median, mode: best)
    }

    /// "The top N% of the population accounts for X% of the total" — the entities, and the share.
    func concentration(topPercent: Int) -> (topCount: Int, share: Double)? {
        guard !concentrationValues.isEmpty else { return nil }
        let sorted = concentrationValues.sorted(by: >)
        let total = sorted.reduce(0, +)
        guard total > 0 else { return nil }
        let topCount = max(1, Int((Double(sorted.count) * Double(topPercent) / 100).rounded(.up)))
        return (topCount, sorted.prefix(topCount).reduce(0, +) / total * 100)
    }
}

enum TrendsLongTailEngine {
    private static let targetBins = 14
    private static let consolidateThreshold = 12
    private static let minBins = 12

    /// `scrobbles` must have canonical artist names. Read through the Query engine — every entity played in the
    /// period with its plays and the metric — so a bar's count is exactly what Query lists when it is clicked.
    static func compute(scrobbles: [ScrobbleSnapshot], snapshots: QuerySnapshots, target: QueryTarget, metric: LongTailMetric, range: DateRange, now: Date = Date()) -> TrendsLongTail? {
        let concentrationMetric: LongTailMetric = metric == .timeListened ? .timeListened : .plays
        var spec = QuerySpec(target: target)
        spec.period = QueryPeriod(from: range.from, to: range.to)
        spec.asOf = now
        var ids = [metric.fieldID]
        if concentrationMetric.fieldID != metric.fieldID { ids.append(concentrationMetric.fieldID) }
        spec.columns = ids.map { QueryFieldRef($0) }
        guard let validated = try? spec.validate(against: .standard) else { return nil }
        let run = QueryRun(target: target, asOf: now, scrobbles: spec.countedPlays(scrobbles), allTimeScrobbles: scrobbles, snapshots: snapshots)
        let result = QueryEngine.evaluate(validated, run: run)
        guard let metricKey = result.columns.first(where: { $0.field.id == metric.fieldID })?.cacheKey,
              let concKey = result.columns.first(where: { $0.field.id == concentrationMetric.fieldID })?.cacheKey else { return nil }

        func number(_ cell: QueryCell?) -> Double? { if case .value(.number(let n))? = cell { return n } else { return nil } }
        var values: [Double] = [], conc: [Double] = []
        for row in result.rows {
            if let v = number(row.cells[metricKey]) { values.append(v) }
            if let c = number(row.cells[concKey]) { conc.append(c) }
        }
        guard !result.rows.isEmpty else { return nil }
        return TrendsLongTail(
            target: target, metric: metric, range: range, population: result.rows.count, values: values,
            bins: bins(values, metric: metric), concentrationMetric: concentrationMetric, concentrationValues: conc
        )
    }

    /// Histogram bins for these values. Small whole-number ranges get one bar per value; anything wider gets
    /// log-spaced edges (finer at the low end, where most things cluster) so the long tail stays readable.
    static func bins(_ values: [Double], metric: LongTailMetric) -> [LongTailBin] {
        guard let min = values.min(), let max = values.max() else { return [] }
        let integer = metric.isInteger
        let distinct = Set(values.map { integer ? $0.rounded() : $0 }).sorted()

        if integer, distinct.count <= consolidateThreshold {
            var bins = distinct.enumerated().map { LongTailBin(index: $0.offset, lo: $0.element, hi: $0.element, isLast: false, label: metric.format($0.element)) }
            let position = Dictionary(uniqueKeysWithValues: distinct.enumerated().map { ($0.element, $0.offset) })
            for v in values { bins[position[v.rounded()]!].count += 1 }
            return bins
        }

        let logStart = log1p(Swift.max(0, min))
        let logEnd = log1p(Swift.max(min + 1, max))
        func edges(_ count: Int) -> [Double] {
            var out: [Double] = []
            // Whole-number metrics round to integers; times round to a readable step (a minute; five seconds for a
            // track's length) so a bar reads "6m–13m", not "6m 27s–13m 37s".
            let step = metric.isInteger ? 1 : (metric == .timeListened ? 60.0 : 5.0)
            for i in 0...count {
                let raw = expm1(logStart + (logEnd - logStart) * Double(i) / Double(count))
                let e: Double = i == 0 ? (min / step).rounded(.down) * step
                    : i == count ? (max / step).rounded(.up) * step
                    : (raw / step).rounded() * step
                if out.isEmpty || e > out.last! { out.append(e) }
            }
            return out
        }
        let raw = Swift.max(targetBins, minBins + 4)
        var e = edges(raw)
        if e.count - 1 < minBins, integer { e = edges(raw * 2) }
        if e.count < 2 { e.append(e[0] + 1) }

        var bins: [LongTailBin] = []
        for i in 0..<(e.count - 1) {
            let lo = e[i], hi = e[i + 1], isLast = i == e.count - 2
            let label: String
            if integer {
                label = hi - 1 > lo ? "\(metric.format(lo))–\(metric.format(isLast ? hi : hi - 1))" : metric.format(lo)
            } else {
                label = "\(metric.formatCompact(lo))–\(metric.formatCompact(hi))"
            }
            bins.append(LongTailBin(index: i, lo: lo, hi: hi, isLast: isLast, label: label))
        }
        for v in values {
            let i = bins.firstIndex { v >= $0.lo && (v < $0.hi || ($0.isLast && v <= $0.hi)) } ?? bins.count - 1
            bins[i].count += 1
        }
        return bins
    }
}
