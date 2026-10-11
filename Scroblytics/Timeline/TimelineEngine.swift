import Foundation

struct TimelineTopItem: Hashable, Sendable {
    let entity: TopChartsEntity
    let name: String
    /// nil for the artist entity itself.
    let artist: String?
    /// The album the period's earliest scrobble was played from (track entity only).
    let album: String?
    let playcount: Int
    /// Only populated when ranked by `.timeListened`.
    let timeListenedSeconds: Int?
    let imageURL: String?
    let loved: Bool
}

struct TimelinePeriodTop: Hashable, Sendable {
    let artist: TimelineTopItem?
    let album: TimelineTopItem?
    let track: TimelineTopItem?

    var items: [TimelineTopItem] { [artist, album, track].compactMap { $0 } }
}

struct TimelineWeek: Identifiable, Hashable, Sendable {
    /// Local Monday-start-of-week instant.
    let weekStart: Date
    let top: TimelinePeriodTop
    var id: Date { weekStart }
}

struct TimelineMonthTotals: Hashable, Sendable {
    let plays: Int
    let artists: Int
    let albums: Int
    let tracks: Int
}

enum TimelineMilestoneKind: Int, Hashable, Sendable {
    case total, artist, album, track

    var label: String {
        switch self {
        case .total: return "Total"
        case .artist: return "Artist"
        case .album: return "Album"
        case .track: return "Track"
        }
    }
}

struct TimelineMilestone: Hashable, Sendable {
    let kind: TimelineMilestoneKind
    let name: String
    let artist: String?
    let milestone: Int
    let achievedAt: Date
}

struct TimelineMonth: Identifiable, Hashable, Sendable {
    /// Local start-of-month instant.
    let monthStart: Date
    let top: TimelinePeriodTop
    /// This month's weeks, most recent first.
    let weeks: [TimelineWeek]
    let totals: TimelineMonthTotals
    /// Most recently achieved first; ties broken by bigger milestone.
    let milestones: [TimelineMilestone]
    var id: Date { monthStart }
}

struct TimelineResult: Sendable {
    /// Most recent first.
    let months: [TimelineMonth]
    let metric: TopChartsMetric
}

/// The top artist/album/track for every local
/// calendar week (Monday start) and month, plus per-month totals and the
/// milestone thresholds crossed that month.
///
/// Behavior (confirmed with the user):
/// - Artist casing variants are merged via `TextNormalization.canonicalArtistNames`
///   across the whole library, matching Top Charts; albums otherwise stay keyed
///   by artist + raw album name (no Various Artists merging).
/// - Milestones run over the same canonicalized scrobbles, so an artist's
///   casing variants count toward one milestone total.
///
/// Winner tie-break: value desc, then earliest first
/// play within the period, then artist name — deliberately NOT Top Charts'
/// comparator, so a period's winner doesn't flip from sync to sync.
/// Pure computation over a `Sendable` snapshot — safe to run off the main actor.
enum TimelineEngine {
    private struct Group {
        let sampleIndex: Int
        let firstAt: Date
        var count = 0
        var value = 0
        var image: String?
        var placeholderImage: String?
    }

    private struct PeriodBucket {
        let start: Date
        var artists: [String: Group] = [:]
        var albums: [String: Group] = [:]
        var tracks: [String: Group] = [:]
        var plays = 0
    }

    static func fetch(
        scrobbles rawSorted: [ScrobbleSnapshot], metric: TopChartsMetric,
        durationLookup: [String: Int] = [:], lovedSet: Set<String> = [], imageLookup: [String: String] = [:]
    ) -> TimelineResult {
        let canonicalNames = TextNormalization.canonicalArtistNames(rawSorted.map(\.artistName))
        let scrobbles = rawSorted.map { s in
            ScrobbleSnapshot(
                artistName: canonicalNames[TextNormalization.artistIdentityKey(s.artistName)]
                    ?? s.artistName.trimmingCharacters(in: .whitespacesAndNewlines),
                albumName: s.albumName, trackName: s.trackName, imageURL: s.imageURL, playedAt: s.playedAt
            )
        }

        var weekBuckets: [PeriodBucket] = []
        var monthBuckets: [PeriodBucket] = []
        var weekEnd = Date.distantPast
        var monthEnd = Date.distantPast
        let calendar = AppCalendars.listening
        var previousPlayedAt = Date.distantPast

        func add(_ s: ScrobbleSnapshot, index: Int, value: Int, to groups: inout [String: Group], key: String) {
            var group = groups[key] ?? Group(sampleIndex: index, firstAt: s.playedAt)
            group.count += 1
            group.value += value
            if group.image == nil, let img = s.imageURL, !img.isEmpty {
                if TextNormalization.isLastfmPlaceholderImage(img) {
                    if group.placeholderImage == nil { group.placeholderImage = img }
                } else {
                    group.image = img
                }
            }
            groups[key] = group
        }

        for (index, s) in scrobbles.enumerated() {
            // Bucket bookkeeping below relies on ascending order; a caller
            // passing unsorted input would silently mis-bucket, so fail loud.
            precondition(s.playedAt >= previousPlayedAt, "TimelineEngine requires scrobbles sorted ascending by playedAt")
            previousPlayedAt = s.playedAt

            if s.playedAt >= weekEnd {
                let start = TrendEngine.bucketStart(s.playedAt, granularity: .week)
                weekEnd = calendar.date(byAdding: .day, value: 7, to: start)!
                weekBuckets.append(PeriodBucket(start: start))
            }
            if s.playedAt >= monthEnd {
                let start = TrendEngine.bucketStart(s.playedAt, granularity: .month)
                monthEnd = calendar.date(byAdding: .month, value: 1, to: start)!
                monthBuckets.append(PeriodBucket(start: start))
            }

            let value = metric == .scrobbles
                ? 1
                : durationLookup[TextNormalization.lovedKey(artist: s.artistName, track: s.trackName)] ?? 0
            let artistKey = s.artistName
            // Match Top Charts: scrobbles with no album tag never win a period
            // as a phantom empty-name album.
            let albumKey: String? = s.albumName.isEmpty ? nil : "\(s.artistName)\u{0}\(s.albumName)"
            // Album-agnostic, matching Milestones — a track wins on its plays
            // across every album it's been scrobbled under.
            let trackKey = "\(s.artistName)\u{0}\(s.trackName)"

            func update(_ bucket: inout PeriodBucket) {
                bucket.plays += 1
                add(s, index: index, value: value, to: &bucket.artists, key: artistKey)
                if let albumKey { add(s, index: index, value: value, to: &bucket.albums, key: albumKey) }
                add(s, index: index, value: value, to: &bucket.tracks, key: trackKey)
            }
            update(&weekBuckets[weekBuckets.count - 1])
            update(&monthBuckets[monthBuckets.count - 1])
        }

        func pickTop(_ groups: [String: Group], entity: TopChartsEntity) -> TimelineTopItem? {
            var best: Group?
            for group in groups.values {
                guard let current = best else { best = group; continue }
                if group.value != current.value {
                    if group.value > current.value { best = group }
                } else if group.firstAt != current.firstAt {
                    if group.firstAt < current.firstAt { best = group }
                } else if scrobbles[group.sampleIndex].artistName.localizedCompare(scrobbles[current.sampleIndex].artistName) == .orderedAscending {
                    best = group
                }
            }
            guard let best else { return nil }
            let sample = scrobbles[best.sampleIndex]
            let name: String
            switch entity {
            case .artist: name = sample.artistName
            case .album: name = sample.albumName
            case .track: name = sample.trackName
            }
            let album: String? = entity == .track && !sample.albumName.isEmpty ? sample.albumName : nil
            let imageTarget = ImageTarget(
                kind: entity == .artist ? .artist : (entity == .album ? .album : .track),
                artist: sample.artistName,
                album: entity == .album ? name : album,
                track: entity == .track ? name : nil
            )
            return TimelineTopItem(
                entity: entity,
                name: name,
                artist: entity == .artist ? nil : sample.artistName,
                album: album,
                playcount: best.count,
                timeListenedSeconds: metric == .timeListened ? best.value : nil,
                imageURL: ImageResolutionEngine.effectiveImageURL(
                    for: imageTarget, lookup: imageLookup, fallbackURL: best.image ?? best.placeholderImage
                ),
                loved: entity == .track && lovedSet.contains(TextNormalization.lovedKey(artist: sample.artistName, track: sample.trackName))
            )
        }

        func top(_ bucket: PeriodBucket) -> TimelinePeriodTop {
            TimelinePeriodTop(
                artist: pickTop(bucket.artists, entity: .artist),
                album: pickTop(bucket.albums, entity: .album),
                track: pickTop(bucket.tracks, entity: .track)
            )
        }

        // A week belongs to the month containing its (Monday) start date, even
        // when its tail end spills into the next calendar month.
        var weeksByMonth: [Date: [TimelineWeek]] = [:]
        for bucket in weekBuckets.reversed() {
            let monthStart = TrendEngine.bucketStart(bucket.start, granularity: .month)
            weeksByMonth[monthStart, default: []].append(TimelineWeek(weekStart: bucket.start, top: top(bucket)))
        }

        let milestonesByMonth = monthlyMilestones(scrobbles: scrobbles)

        let months = monthBuckets.reversed().map { bucket in
            TimelineMonth(
                monthStart: bucket.start,
                top: top(bucket),
                weeks: weeksByMonth.removeValue(forKey: bucket.start) ?? [],
                totals: TimelineMonthTotals(
                    plays: bucket.plays, artists: bucket.artists.count, albums: bucket.albums.count, tracks: bucket.tracks.count
                ),
                milestones: milestonesByMonth[bucket.start] ?? []
            )
        }

        // Source silently drops a week whose Monday falls in a month with no
        // scrobbles of its own (e.g. nothing played Aug 31, but plenty Sep 1–6).
        // Kept as source does, but surfaced rather than absorbed.
        let orphaned = weeksByMonth.values.reduce(0) { $0 + $1.count }
        if orphaned > 0 {
            print("[TimelineEngine] \(orphaned) week(s) dropped: their Monday falls in a month with no scrobbles — \(weeksByMonth.keys.sorted())")
        }

        return TimelineResult(months: months, metric: metric)
    }

    /// Every milestone threshold crossed (total + per artist/album/track),
    /// bucketed by the local month it happened in — reuses `MilestonesEngine`'s
    /// cumulative walk rather than a second copy of it.
    private static func monthlyMilestones(scrobbles: [ScrobbleSnapshot]) -> [Date: [TimelineMilestone]] {
        let result = MilestonesEngine.fetch(scrobbles: scrobbles)
        var all: [TimelineMilestone] = result.total.achieved.map {
            TimelineMilestone(kind: .total, name: "Total scrobbles", artist: nil, milestone: $0.milestone, achievedAt: $0.achievedAt)
        }
        for (kind, category) in [(TimelineMilestoneKind.artist, result.artists), (.album, result.albums), (.track, result.tracks)] {
            all += category.achieved.map {
                TimelineMilestone(kind: kind, name: $0.name, artist: $0.artist, milestone: $0.milestone, achievedAt: $0.achievedAt)
            }
        }
        var byMonth: [Date: [TimelineMilestone]] = [:]
        for m in all {
            byMonth[TrendEngine.bucketStart(m.achievedAt, granularity: .month), default: []].append(m)
        }
        return byMonth.mapValues {
            $0.sorted { a, b in
                a.achievedAt != b.achievedAt ? a.achievedAt > b.achievedAt : a.milestone > b.milestone
            }
        }
    }
}
