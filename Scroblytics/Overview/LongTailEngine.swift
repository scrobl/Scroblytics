import Foundation

struct LongTailStats: Sendable {
    let entity: TopChartsEntity
    let metric: TopChartsMetric
    let topPercent: Int
    let concentrationPercent: Double
    let mean: Double
    let median: Double
    let max: Int
    /// Simplified bar heights (counts per bin) for the decorative mini-
    /// histogram — log-scale bins, since real play-count distributions are
    /// heavily long-tailed (mirrors the full Trends chart's own rationale,
    /// scaled down to a fixed bin count for a compact, non-interactive echo).
    let histogram: [Int]
}

/// Overview-card-scoped slice of the Long Tail: just the Concentration
/// callout (as one sentence, per the PRD's explicit correction) plus the
/// Mean/Median/Max stat row and a decorative mini-histogram — required parts
/// of the basic card, not deferred richness. The full Trends chart (dynamic
/// quantile binning, entity/metric toggles, Compare mode, drill-down) is a
/// separate, later build.
enum LongTailEngine {
    static func fetch(
        scrobbles: [ScrobbleSnapshot], range: DateRange, entity: TopChartsEntity = .artist,
        topPercent: Int = 10, binCount: Int = 8, metric: TopChartsMetric = .scrobbles,
        durationLookup: [String: Int] = [:]
    ) -> LongTailStats? {
        // Reuse Top Charts' ranking to get every entity of this type ranked
        // by plays within range — Long Tail's population is the exact same
        // grouping Top Charts already computes correctly (album merges
        // included). Peak-rank computation is skipped: Long Tail only reads
        // `.playcount`, and at `limit: .max` every entity in the library
        // would be a "wanted" key, making the checkpoint sampler needlessly
        // expensive here.
        let ranked = TopChartsEngine.fetchRankings(
            scrobbles: scrobbles, entity: entity, range: range, limit: .max,
            includePeak: false, metric: metric, durationLookup: durationLookup
        )
        guard !ranked.isEmpty else { return nil }

        let counts = ranked.map { $0.metricValue(for: metric) } // already sorted descending
        let totalPlays = counts.reduce(0, +)
        let n = counts.count

        let topCount = max(1, Int((Double(n) * Double(topPercent) / 100).rounded(.up)))
        let topSum = counts.prefix(topCount).reduce(0, +)
        let concentrationPercent = totalPlays > 0 ? (Double(topSum) / Double(totalPlays)) * 100 : 0

        let mean = Double(totalPlays) / Double(n)
        let sortedAscending = counts.sorted()
        let median: Double = n % 2 == 0
            ? Double(sortedAscending[n / 2 - 1] + sortedAscending[n / 2]) / 2
            : Double(sortedAscending[n / 2])
        let maxValue = counts.first ?? 0

        return LongTailStats(
            entity: entity, metric: metric, topPercent: topPercent, concentrationPercent: concentrationPercent,
            mean: mean, median: median, max: maxValue,
            histogram: logBinnedCounts(counts, binCount: binCount)
        )
    }

    private static func logBinnedCounts(_ counts: [Int], binCount: Int) -> [Int] {
        guard let maxValue = counts.max(), maxValue > 0 else { return Array(repeating: 0, count: binCount) }
        let logMax = log(Double(maxValue) + 1)
        var bins = Array(repeating: 0, count: binCount)
        guard logMax > 0 else { bins[0] = counts.count; return bins }
        for c in counts {
            let logC = log(Double(c) + 1)
            let index = min(max(Int((logC / logMax) * Double(binCount)), 0), binCount - 1)
            bins[index] += 1
        }
        return bins
    }
}
