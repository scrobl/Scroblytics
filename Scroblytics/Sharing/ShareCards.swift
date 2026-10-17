import Foundation
import SwiftUI

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

    /// An artist, album or track page: the numbers its header shows (the headline tiles and the page's facts that have a value), the
    /// rank-by-year chips, the milestones reached, and the trend line. `periodLabel` is the page's chosen period, which the plays and
    /// the first and last scrobble are measured over. Nil until the page's stats have loaded.
    static func profile(
        entity: TopChartsEntity, name: String, artist: String?, album: String?, imageURL: String?, periodLabel: String,
        stats: EntityStats?, metric: TopChartsMetric, timeListenedSeconds: Int?, facts: [DetailFact],
        yearlyTopRanks: [TopChartsEngine.YearlyRank], now: Date = Date()
    ) -> ShareCard? {
        guard let stats else { return nil }
        let shown = DetailHeaderCard<EmptyView>.headline(stats: stats, metric: metric, timeListenedSeconds: timeListenedSeconds) + facts
        let tiles = shown.compactMap { fact -> ShareStat? in
            guard fact.hasValue, fact.displayText != "—" else { return nil }
            return ShareStat(label: fact.label, value: fact.displayText)
        }
        var chips = yearlyTopRanks.map { ShareChip(kind: .rank, text: "#\($0.rank) of \($0.year)") }
        for milestone in stats.milestones.achieved.sorted(by: { $0.milestone > $1.milestone }).prefix(3) {
            let date = milestone.achievedAt.formatted(date: .abbreviated, time: .omitted)
            chips.append(ShareChip(kind: .milestone, text: "\(MilestoneFormatting.formatMilestone(milestone.milestone)) plays · \(date)", tier: milestone.milestone, detail: date))
        }
        let kind: String
        let subtitle: String
        switch entity {
        case .artist:
            kind = "Artist"
            subtitle = ""
        case .album:
            kind = "Album"
            subtitle = artist ?? ""
        case .track:
            kind = "Track"
            subtitle = [artist, album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return ShareCard(
            title: name,
            period: periodLabel,
            measure: subtitle,
            rows: [],
            valueLabel: metric == .scrobbles ? "Plays" : "Time",
            hasMovement: false,
            generatedAt: now,
            kindID: "page.\(entity.rawValue)",
            profile: ShareProfile(
                kind: kind, subtitle: subtitle, heroImageURL: imageURL, stats: tiles, chips: chips, trend: stats.trend.map(\.count)
            )
        )
    }

    /// One milestone reached by an artist, album or track (or by the whole library, with no name or picture of its own).
    static func milestone(
        kind: String, name: String, artist: String?, imageURL: String?, milestone: Int, achievedAt: Date, firstAt: Date, now: Date = Date()
    ) -> ShareCard {
        let days = achievedAt.timeIntervalSince(firstAt) / 86400
        var stats = [ShareStat(label: "Reached", value: achievedAt.formatted(date: .abbreviated, time: .omitted))]
        if days >= 0 { stats.append(ShareStat(label: "Time to get there", value: MilestoneFormatting.formatElapsedDays(days))) }
        stats.append(ShareStat(label: "First scrobble", value: firstAt.formatted(date: .abbreviated, time: .omitted)))
        return ShareCard(
            title: name,
            period: "All time",
            measure: artist ?? "",
            rows: [],
            valueLabel: "Plays",
            hasMovement: false,
            generatedAt: now,
            kindID: "milestone.\(kind.lowercased())",
            iconChoice: imageURL == nil && kind == "Total",
            profile: ShareProfile(kind: "\(kind) milestone", subtitle: artist ?? "", heroImageURL: imageURL, headline: "\(milestone.formatted()) plays", headlineTier: milestone, stats: stats, chips: [], trend: [])
        )
    }

    /// A Milestones page's achieved list, in the order shown (nothing is ranked, so no row numbers). `tierLabel` names the page's tier
    /// filter, and is empty when no tier is chosen (every milestone), so the card doesn't claim a filter that isn't there.
    struct MilestoneRow: Sendable {
        var name: String
        var artist: String?
        var imageURL: String?
        var milestone: Int
        var achievedAt: Date
    }

    static func milestones(category: String, tierLabel: String, rows: [MilestoneRow], now: Date = Date()) -> ShareCard {
        ShareCard(
            title: "Milestones reached",
            period: category,
            measure: tierLabel,
            rows: rows.enumerated().map { index, row in
                ShareRow(
                    rank: index + 1, title: row.name, subtitle: row.artist,
                    value: "\(MilestoneFormatting.formatMilestone(row.milestone)) · \(row.achievedAt.formatted(date: .abbreviated, time: .omitted))",
                    change: .none, imageURL: row.imageURL,
                    milestone: ShareMilestone(tier: row.milestone, date: row.achievedAt.formatted(date: .abbreviated, time: .omitted))
                )
            },
            valueLabel: "Milestone",
            hasMovement: false,
            generatedAt: now,
            kindID: "milestones.\(category.lowercased())",
            numbered: false,
            iconChoice: category == "Total"
        )
    }

    /// A Timeline month: its totals, its top artist, album and track, and the milestones reached.
    static func timelineMonth(_ month: TimelineMonth, metric: TopChartsMetric, now: Date = Date()) -> ShareCard {
        func pick(_ role: String, _ item: TimelineTopItem?) -> ShareHighlight? {
            guard let item else { return nil }
            let value = metric == .timeListened
                ? DurationEngine.formatTimeListened(item.timeListenedSeconds ?? 0)
                : "\(item.playcount.formatted()) \(item.playcount == 1 ? "play" : "plays")"
            return ShareHighlight(role: role, title: item.name, subtitle: item.artist, value: value, imageURL: item.imageURL)
        }
        let highlights = [pick("Top Artist", month.top.artist), pick("Top Album", month.top.album), pick("Top Track", month.top.track)].compactMap { $0 }
        let totals = month.totals
        let chips = month.milestones
            .sorted { $0.kind != $1.kind ? $0.kind.rawValue < $1.kind.rawValue : $0.milestone > $1.milestone }
            .prefix(8)
            .map { item -> ShareChip in
                let what = item.kind == .total ? "Total" : item.name
                return ShareChip(kind: .milestone, text: "\(MilestoneFormatting.formatMilestone(item.milestone)) · \(what)", tier: item.milestone, detail: what)
            }
        return ShareCard(
            title: month.monthStart.formatted(.dateTime.month(.wide).year()),
            period: "Month",
            measure: "",
            rows: [],
            valueLabel: metric == .timeListened ? "Time" : "Plays",
            hasMovement: false,
            generatedAt: now,
            kindID: "timeline.month",
            profile: ShareProfile(
                kind: "Timeline", subtitle: "", heroImageURL: nil,
                stats: [
                    ShareStat(label: "Plays", value: totals.plays.formatted()), ShareStat(label: "Artists", value: totals.artists.formatted()),
                    ShareStat(label: "Albums", value: totals.albums.formatted()), ShareStat(label: "Tracks", value: totals.tracks.formatted()),
                ],
                chips: Array(chips), highlights: highlights, trend: []
            )
        )
    }

    /// A Rabbit Hole path, track by track from where it started: each with its artist and, when the person wants it, why it was chosen.
    /// The image shows plays, the last play or the match score; the text copies carry them all.
    static func rabbitHole(path: [RabbitHoleNode], tree: RabbitHoleTree? = nil, now: Date = Date()) -> ShareCard {
        let rows = path.enumerated().map { index, node -> ShareRow in
            let track = node.track
            let plays = track.playCount.formatted()
            let last = track.lastPlayed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
            // The track it started from wasn't suggested by anything, so it has no match.
            let match = node.parentID == nil || track.matchScore <= 0 ? "—" : "\(track.matchScore)%"
            return ShareRow(
                rank: index + 1, title: track.track, subtitle: track.artist, value: plays, change: .none, imageURL: track.imageURL,
                values: [plays, last, match], note: track.reasons?.first?.text
            )
        }
        // The tree: at each step, what was offered by the step before and not taken (and branches explored from it), the first two.
        func pick(_ track: RabbitHoleTrack) -> ShareTree.Pick { ShareTree.Pick(title: track.track, artist: track.artist, imageURL: track.imageURL) }
        let steps = path.enumerated().map { index, node -> ShareTree.Step in
            guard index > 0 else { return ShareTree.Step(chosen: pick(node.track), others: []) }
            let parent = path[index - 1]
            var others: [RabbitHoleTrack] = parent.candidates ?? []
            for childID in parent.childIDs { if let child = tree?.nodes[childID], child.id != node.id { others.append(child.track) } }
            var seen: Set<String> = [node.track.id]
            let unique = others.filter { seen.insert($0.id).inserted }
            return ShareTree.Step(chosen: pick(node.track), others: Array(unique.prefix(2)).map(pick))
        }
        return ShareCard(
            title: "Down the rabbit hole",
            period: "",
            measure: "",
            rows: rows,
            valueLabel: "Plays",
            hasMovement: false,
            generatedAt: now,
            kindID: "rabbitHole",
            valueColumns: ["Plays", "Last played", "Match score"],
            defaultValueColumn: 0,
            tree: ShareTree(steps: steps),
            compactTitles: true
        )
    }

    /// A Query result: its rows as the table lists them, each with every column's value as the table writes it. The image shows one of the
    /// columns (the first the query sorts on unless the person picks another), the text copies carry them all.
    /// - Parameters:
    ///   - title: the question put to Ask, a saved set's name, or a description of the filters.
    ///   - measure: how much of the result this is and how it is ordered.
    static func queryResult(
        title: String, target: QueryTarget, measure: String, rows: [QueryDisplayRow], columns: [ResolvedField], sortedColumn: Int?,
        now: Date = Date()
    ) -> ShareCard {
        let titles = columns.map(\.title)
        let defaultColumn = min(max(sortedColumn ?? 0, 0), max(titles.count - 1, 0))
        let shareRows = rows.enumerated().map { index, row -> ShareRow in
            let values = columns.map { QueryCellText.string(row.row.cells[$0.cacheKey] ?? .missing, column: $0) }
            return ShareRow(
                rank: index + 1, title: row.entity.name, subtitle: row.subtitle,
                value: values.indices.contains(defaultColumn) ? values[defaultColumn] : "",
                change: .none, imageURL: row.imageURL, values: values
            )
        }
        return ShareCard(
            title: title,
            period: target.rawValue.capitalized + "s",
            measure: measure,
            rows: shareRows,
            valueLabel: titles.indices.contains(defaultColumn) ? titles[defaultColumn] : "Value",
            hasMovement: false,
            generatedAt: now,
            kindID: "query.\(target.rawValue)",
            valueColumns: titles,
            defaultValueColumn: defaultColumn
        )
    }

    /// The index of the first of `columns` that the query sorts on, which is the value its image shows by default.
    static func sortedColumnIndex(columns: [ResolvedField], sorts: [QuerySort], target: QueryTarget, registry: QueryFieldRegistry) -> Int? {
        for sort in sorts {
            guard case .field(let ref) = sort.key, let key = try? registry.resolve(ref, target: target).cacheKey,
                  let index = columns.firstIndex(where: { $0.cacheKey == key }) else { continue }
            return index
        }
        return nil
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
