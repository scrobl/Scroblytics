import Foundation

/// One builder per screen: what to put on a card for what that screen is showing. Pure, so each is checked against hand-computed
/// expectations.
@MainActor
enum ShareCards {
    /// Top Charts: the ranked entries as shown, with movement against the comparison period when there is one.
    static func topChart(
        entries: [TopChartEntry], entity: TopChartsEntity, metric: TopChartsMetric, periodLabel: String,
        compareRange: DateRange? = nil, now: Date = Date()
    ) -> ShareCard {
        let hasMovement = entries.contains { $0.hasCompareRange }
        let rows = entries.map { entry in
            ShareRow(
                rank: entry.rank,
                title: entry.name,
                subtitle: entity == .artist ? nil : entry.artist,
                value: metric == .scrobbles ? entry.playcount.formatted() : DurationEngine.formatTimeListened(entry.timeListenedSeconds ?? 0),
                change: change(rank: entry.rank, previous: entry.previousRank, hasCompareRange: entry.hasCompareRange),
                imageURL: entry.imageURL
            )
        }
        return ShareCard(
            title: "Top \(entity.displayName)",
            period: periodLabel,
            measure: metric == .scrobbles ? "Ranked by scrobbles" : "Ranked by time listened",
            rows: rows,
            valueLabel: metric == .scrobbles ? "Plays" : "Time",
            hasMovement: hasMovement,
            movementNote: hasMovement ? compareRange.map(movementSince) : nil,
            generatedAt: now,
            kindID: "topChart.\(entity.rawValue)"
        )
    }

    /// Top Charts compares the chart over the same start with the same chart as it stood N days ago, so movement is "since" that day:
    /// "since Oct 10, 2026". (Another screen whose comparison is a different window words its own.)
    static func movementSince(_ compare: DateRange) -> String {
        "since " + compare.to.formatted(date: .abbreviated, time: .omitted)
    }

    /// "Oct 17, 2024 – Oct 16, 2025", or one date when the period is a single day.
    static func rangeLabel(_ range: DateRange) -> String {
        let from = range.from.formatted(date: .abbreviated, time: .omitted)
        let to = range.to.formatted(date: .abbreviated, time: .omitted)
        return from == to ? from : "\(from) – \(to)"
    }

    /// The rank change a chart shows: nothing without a comparison period, NEW when it wasn't charted there, otherwise how far it moved.
    nonisolated static func change(rank: Int, previous: Int?, hasCompareRange: Bool) -> ShareChange {
        guard hasCompareRange else { return .none }
        guard let previous else { return .new }
        if previous == rank { return .same }
        return rank < previous ? .up(previous - rank) : .down(rank - previous)
    }
}
