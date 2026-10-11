import Foundation

struct RecentScrobbleEntry: Identifiable, Sendable {
    let id = UUID()
    let artist: String
    let album: String?
    let track: String
    let playedAt: Date
    let imageURL: String?
    /// This track's Billboard-style chart position (by playcount) within the
    /// selected range — same tie-break as Top Charts' track ranking.
    let rank: Int
    /// Whether a compare range exists at all for the current selection (the
    /// same `endingDaysAgo` window Listening Totals uses) — false when the
    /// range is too short, in which case Prev/Move show "–" rather than a
    /// "new entry" badge.
    let hasCompareRange: Bool
    /// The same track's chart rank within the compare range. Nil either
    /// because there's no compare range at all (`hasCompareRange == false`)
    /// or because the track wasn't charted in the compare range (a genuine
    /// new entry — "Hot Shot Debut").
    let previousRank: Int?
    /// Reads from a pre-resolved `lovedSet` snapshot, same shape as
    /// `OverviewTopEntry.loved` — never a live per-row lookup.
    let loved: Bool
}

/// The 10 most recent
/// scrobbles in the selected range, each carrying its chart rank and that
/// same track's rank in the period-over-period compare range (the same
/// shared `ChartDateSettings`-resolved compare range every other Overview
/// card uses). The flagged marker is omitted — flagging isn't a built
/// feature at all (FlaggedTrack only exists for backup
/// round-tripping so far). Pure computation over a `Sendable` snapshot —
/// safe to run off the main actor.
enum RecentScrobblesEngine {
    private struct Key: Hashable {
        let artist: String
        let track: String
    }

    /// Rank by playcount desc, ties broken by artist then track name asc —
    /// identical rule to Top Charts' track ranking and ClimbingEngine's.
    private static func ranks(
        _ scrobbles: [ScrobbleSnapshot], metric: TopChartsMetric,
        durationLookup: [String: Int]
    ) -> [Key: Int] {
        var groups: [Key: [ScrobbleSnapshot]] = [:]
        var order: [Key] = []
        for s in scrobbles {
            let key = Key(artist: s.artistName, track: s.trackName)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(s)
        }
        let sorted = order.sorted { a, b in
            let valueA = metricValue(groups[a]!, metric: metric, durationLookup: durationLookup)
            let valueB = metricValue(groups[b]!, metric: metric, durationLookup: durationLookup)
            if valueA != valueB { return valueA > valueB }
            if a.artist != b.artist { return a.artist < b.artist }
            return a.track < b.track
        }
        var result: [Key: Int] = [:]
        for (index, key) in sorted.enumerated() { result[key] = index + 1 }
        return result
    }

    private static func metricValue(
        _ group: [ScrobbleSnapshot], metric: TopChartsMetric,
        durationLookup: [String: Int]
    ) -> Int {
        guard metric == .timeListened else { return group.count }
        return group.reduce(0) { total, scrobble in
            total + (durationLookup[TextNormalization.lovedKey(artist: scrobble.artistName, track: scrobble.trackName)] ?? 0)
        }
    }

    static func fetch(
        scrobbles all: [ScrobbleSnapshot], range: DateRange, compareRange: DateRange?,
        metric: TopChartsMetric = .scrobbles, durationLookup: [String: Int] = [:],
        lovedSet: Set<String> = [], imageLookup: [String: String] = [:]
    ) -> [RecentScrobbleEntry] {
        let inRange = all.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
        let currentRanks = ranks(inRange, metric: metric, durationLookup: durationLookup)

        let compareRanks: [Key: Int]? = compareRange.map { cr in
            ranks(
                all.filter { $0.playedAt >= cr.from && $0.playedAt <= cr.to },
                metric: metric, durationLookup: durationLookup
            )
        }

        let recent = inRange.sorted { $0.playedAt > $1.playedAt }.prefix(10)
        return recent.map { s in
            let key = Key(artist: s.artistName, track: s.trackName)
            let album = s.albumName.isEmpty ? nil : s.albumName
            let target = ImageTarget(
                kind: .track,
                artist: s.artistName,
                album: album,
                track: s.trackName
            )
            return RecentScrobbleEntry(
                artist: s.artistName,
                album: album,
                track: s.trackName,
                playedAt: s.playedAt,
                imageURL: ImageResolutionEngine.effectiveImageURL(
                    for: target,
                    lookup: imageLookup,
                    fallbackURL: s.imageURL
                ),
                rank: currentRanks[key]!,
                hasCompareRange: compareRanks != nil,
                previousRank: compareRanks?[key],
                loved: lovedSet.contains(TextNormalization.lovedKey(artist: s.artistName, track: s.trackName))
            )
        }
    }
}
