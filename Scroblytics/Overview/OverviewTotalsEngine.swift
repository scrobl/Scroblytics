import Foundation

struct OverviewCompare: Sendable {
    let scrobbles: Int
    let artists: Int
    let albums: Int
    let tracks: Int
}

/// One "Top artist/album/track" pick. `loved` is only ever true for the Top
/// track pick (Last.fm loves are track-scoped) and reads from a
/// pre-resolved `lovedSet` snapshot (`LovedTracksEngine.lovedSet`, resolved
/// on MainActor before this pure/detached computation runs) — same "resolve
/// before detaching, consume a plain value inside" shape as the Time
/// Listened duration lookup.
struct OverviewTopEntry: Sendable {
    let name: String
    let artist: String?
    let album: String?
    let playcount: Int
    let imageURL: String?
    let loved: Bool
    /// Only populated when picked by `.timeListened` — mirrors
    /// `TopChartEntry.timeListenedSeconds`'s same nil-when-not-requested
    /// convention.
    let timeListenedSeconds: Int?

    func metricValue(for metric: TopChartsMetric) -> Int {
        metric == .scrobbles ? playcount : (timeListenedSeconds ?? 0)
    }
}

struct OverviewTotals: Sendable {
    let scrobbles: Int
    let artists: Int
    let albums: Int
    let tracks: Int
    /// The `lovedKey` of each distinct track played in the range, so the Tracks tile can count how many are loved
    /// against the live loved list.
    let trackKeys: Set<String>
    let perDay: Double
    /// Artists whose all-time-earliest scrobble falls inside the selected range.
    let newArtists: Int
    /// Nil when the selected range is shorter than the compare window.
    let compare: OverviewCompare?
    let topArtist: OverviewTopEntry?
    let topAlbum: OverviewTopEntry?
    let topTrack: OverviewTopEntry?
}

/// Overview totals plus a time-measure
/// variant for Top Picks (the Metric toggle also drives which artist/album/
/// track wins, not just the Listening Totals number) and the period-over-
/// period `ChangeIndicator` math.
/// `metric`/`durationLookup` default to Scrobbles/empty so every existing
/// caller stays untouched; Time Listened resolution itself still happens
/// entirely outside this function (network, MainActor) — this stays pure
/// computation over a `Sendable` snapshot plus a pre-resolved lookup, safe to
/// run off the main actor either way. TopTagsEngine's own Metric deferral is
/// unrelated and still stands.
enum OverviewTotalsEngine {
    /// The compare range Overview actually uses: the SAME range with its end
    /// shifted back `days` days from `min(range.to, now)` — NOT a true
    /// previous-period-of-equal-length (that's Trends' separate Compare
    /// toggle, which Overview never uses). Nil when the range is shorter
    /// than `days`.
    static func endingDaysAgo(_ range: DateRange, days: Int = 30) -> DateRange? {
        let effectiveTo = min(range.to, Date())
        let to = effectiveTo.addingTimeInterval(-Double(days) * 86400)
        guard to > range.from else { return nil }
        return DateRange(from: range.from, to: to)
    }

    /// Same range with its end shifted to a specific calendar date (through
    /// the end of that local day) — the "Custom date" alternative to a fixed
    /// N-days-ago offset, used by Top Charts' Chart comparison picker. Nil
    /// when the date falls on/after the range's effective end or on/before
    /// its start, mirroring `endingDaysAgo`'s guard.
    static func endingOnDate(_ range: DateRange, date: Date) -> DateRange? {
        let effectiveTo = min(range.to, Date())
        let endOfDay = AppCalendars.listening.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date
        let to = min(endOfDay, effectiveTo)
        guard to > range.from else { return nil }
        return DateRange(from: range.from, to: to)
    }

    /// `round(((current - previous) / previous) * 100)`. Nil when there's no
    /// previous to compare against. A zero previous with a nonzero current
    /// is reported as `nil` here (the UI shows a "New" badge for that case,
    /// not a numeric percent) — callers distinguish it via `previous == 0`.
    static func percentChange(current: Int, previous: Int?) -> Int? {
        guard let previous else { return nil }
        guard previous != 0 else { return nil }
        return Int((Double(current - previous) / Double(previous) * 100).rounded())
    }

    static func fetch(
        scrobbles allScrobbles: [ScrobbleSnapshot], range: DateRange, compareRange: DateRange?,
        metric: TopChartsMetric = .scrobbles, durationLookup: [String: Int] = [:], lovedSet: Set<String> = [],
        imageLookup: [String: String] = [:]
    ) -> OverviewTotals {
        let inRange = allScrobbles.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }

        // Explicit "Ordered" bookkeeping so the top-entity pick's tie-break
        // follows insertion order (a stable sort) —
        // Swift's Dictionary iteration order isn't insertion order, same
        // reasoning as buildAlbumGroups/SimilarSoundsEngine elsewhere.
        var artistGroups: [String: [ScrobbleSnapshot]] = [:]
        var artistOrder: [String] = []
        var albumGroups: [String: [ScrobbleSnapshot]] = [:]
        var albumOrder: [String] = []
        var trackGroups: [String: [ScrobbleSnapshot]] = [:]
        var trackOrder: [String] = []
        for s in inRange {
            if artistGroups[s.artistName] == nil { artistOrder.append(s.artistName) }
            artistGroups[s.artistName, default: []].append(s)

            if !s.albumName.isEmpty {
                let key = "\(s.artistName)\u{0}\(s.albumName)"
                if albumGroups[key] == nil { albumOrder.append(key) }
                albumGroups[key, default: []].append(s)
            }

            let trackKey = "\(s.artistName)\u{0}\(s.trackName)"
            if trackGroups[trackKey] == nil { trackOrder.append(trackKey) }
            trackGroups[trackKey, default: []].append(s)
        }

        let days = max(1, range.to.timeIntervalSince(range.from) / 86400)
        let perDay = Double(inRange.count) / days

        // New artists: all-time-earliest scrobble (across the ENTIRE synced
        // history, not just this range) falls inside the selected range.
        var firstArtistDate: [String: Date] = [:]
        for s in allScrobbles {
            if let existing = firstArtistDate[s.artistName] {
                if s.playedAt < existing { firstArtistDate[s.artistName] = s.playedAt }
            } else {
                firstArtistDate[s.artistName] = s.playedAt
            }
        }
        let newArtists = artistOrder.filter { name in
            guard let first = firstArtistDate[name] else { return false }
            return first >= range.from && first <= range.to
        }.count

        var compare: OverviewCompare?
        if let compareRange {
            let compareInRange = allScrobbles.filter { $0.playedAt >= compareRange.from && $0.playedAt <= compareRange.to }
            var compareAlbumKeys = Set<String>()
            for s in compareInRange where !s.albumName.isEmpty {
                compareAlbumKeys.insert("\(s.artistName)\u{0}\(s.albumName)")
            }
            var compareTrackKeys = Set<String>()
            for s in compareInRange {
                compareTrackKeys.insert("\(s.artistName)\u{0}\(s.trackName)")
            }
            compare = OverviewCompare(
                scrobbles: compareInRange.count,
                artists: Set(compareInRange.map(\.artistName)).count,
                albums: compareAlbumKeys.count,
                tracks: compareTrackKeys.count
            )
        }

        // A group's Time Listened value: each scrobble contributes its own
        // track's resolved duration once — matches TopChartsEngine.rank's
        // identical `timeListened(_ group:)` helper. Missing/unresolved
        // durations contribute 0, not an error.
        func timeListened(_ group: [ScrobbleSnapshot]) -> Int {
            group.reduce(0) { total, s in
                total + (durationLookup[TextNormalization.lovedKey(artist: s.artistName, track: s.trackName)] ?? 0)
            }
        }
        func metricValue(_ group: [ScrobbleSnapshot]) -> Int {
            metric == .scrobbles ? group.count : timeListened(group)
        }

        // Descending metric-value winner, no further tie-break beyond
        // insertion order — for the Scrobbles case
        // (unlike the ranked lists elsewhere, which do tie-break by name);
        // Time Listened reuses the identical selection, just swapping the
        // compared value.
        func topArtist() -> OverviewTopEntry? {
            var bestName: String?
            var bestValue = -1
            for name in artistOrder where metricValue(artistGroups[name]!) > bestValue {
                bestValue = metricValue(artistGroups[name]!)
                bestName = name
            }
            guard let bestName else { return nil }
            let group = artistGroups[bestName]!
            return OverviewTopEntry(
                name: bestName, artist: nil, album: nil, playcount: group.count,
                imageURL: ImageResolutionEngine.effectiveImageURL(
                    for: ImageTarget(kind: .artist, artist: bestName, album: nil, track: nil),
                    lookup: imageLookup
                ), loved: false,
                timeListenedSeconds: metric == .timeListened ? timeListened(group) : nil
            )
        }
        func topAlbum() -> OverviewTopEntry? {
            var bestKey: String?
            var bestValue = -1
            for key in albumOrder where metricValue(albumGroups[key]!) > bestValue {
                bestValue = metricValue(albumGroups[key]!)
                bestKey = key
            }
            guard let bestKey, let group = albumGroups[bestKey] else { return nil }
            return OverviewTopEntry(
                name: group[0].albumName, artist: group[0].artistName, album: nil, playcount: group.count,
                imageURL: ImageResolutionEngine.effectiveImageURL(
                    for: ImageTarget(kind: .album, artist: group[0].artistName, album: group[0].albumName, track: nil),
                    lookup: imageLookup,
                    fallbackURL: group.first(where: { $0.imageURL != nil })?.imageURL
                ), loved: false,
                timeListenedSeconds: metric == .timeListened ? timeListened(group) : nil
            )
        }
        func topTrack() -> OverviewTopEntry? {
            var bestKey: String?
            var bestValue = -1
            for key in trackOrder where metricValue(trackGroups[key]!) > bestValue {
                bestValue = metricValue(trackGroups[key]!)
                bestKey = key
            }
            guard let bestKey, let group = trackGroups[bestKey] else { return nil }
            let loved = lovedSet.contains(TextNormalization.lovedKey(artist: group[0].artistName, track: group[0].trackName))
            return OverviewTopEntry(
                name: group[0].trackName, artist: group[0].artistName, album: mostPlayedAlbum(in: group), playcount: group.count,
                imageURL: ImageResolutionEngine.effectiveImageURL(
                    for: ImageTarget(kind: .track, artist: group[0].artistName, album: mostPlayedAlbum(in: group), track: group[0].trackName),
                    lookup: imageLookup,
                    fallbackURL: group.first(where: { $0.imageURL != nil })?.imageURL
                ), loved: loved,
                timeListenedSeconds: metric == .timeListened ? timeListened(group) : nil
            )
        }

        return OverviewTotals(
            scrobbles: inRange.count, artists: artistGroups.count, albums: albumGroups.count, tracks: trackGroups.count,
            trackKeys: Set(trackGroups.values.compactMap { $0.first }.map { TextNormalization.lovedKey(artist: $0.artistName, track: $0.trackName) }),
            perDay: perDay, newArtists: newArtists, compare: compare,
            topArtist: topArtist(), topAlbum: topAlbum(), topTrack: topTrack()
        )
    }

    /// Most-played album variant among a track's own scrobbles — used only
    /// for the top track's displayed album context: the most-played one, the
    /// first-seen on a tie.
    private static func mostPlayedAlbum(in group: [ScrobbleSnapshot]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for s in group where !s.albumName.isEmpty {
            if counts[s.albumName] == nil { order.append(s.albumName) }
            counts[s.albumName, default: 0] += 1
        }
        var best: String?
        var bestCount = 0
        for name in order where counts[name]! > bestCount {
            bestCount = counts[name]!
            best = name
        }
        return best
    }
}
