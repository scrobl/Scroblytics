import Foundation

struct FadingFavoriteEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let track: String
    let artist: String
    let album: String?
    let imageURL: String?
    let totalPlaycount: Int
    let peakPlaycount: Int
    let recentPlaycount: Int
    let lastPlayed: Date
    let decayScore: Double
}

/// Per-track fading stats for one (artist, track) group, with NO qualification
/// guards applied — every track that has any plays in the period gets one.
/// This is the single computation behind both the Overview card (`fetch`
/// applies the card's guards/sort/limit on top) and the query framework's
/// Fading Favorites fields (which express those same guards as conditions).
struct FadingFavoriteStats: Hashable, Sendable {
    let track: String
    let artist: String
    let album: String?
    let imageURL: String?
    let totalPlaycount: Int
    /// Most plays in any span `windowDays` long.
    let peakPlaycount: Int
    /// The [start, end] of the `windowDays`-long span where the peak actually occurred — the first and
    /// last play inside it, not the window's nominal edges.
    let peakWindowStart: Date
    let peakWindowEnd: Date
    /// Plays in the trailing `windowDays` before the as-of date.
    let recentPlaycount: Int
    let lastPlayed: Date

    /// Recent plays as a fraction of the peak (0 = went silent, 1 = still at peak).
    var decayScore: Double { Double(recentPlaycount) / Double(peakPlaycount) }
    /// "Big peak x how faded it is" — the card's ranking score.
    var rediscoveryScore: Double { Double(peakPlaycount) * (1 - decayScore) }
}

/// "Rediscovery Engine" — the core
/// algorithm: tracks that once had a high play density but have gone
/// near-silent recently. Compares each track's plays in the trailing window
/// against its own historical peak density over any window of the same
/// length (sliding-window max, not just "plays this window vs plays ever").
///
/// Unlike On This Day/Climbing/Most Recent-Most Often (each a fixed window
/// independent of the page range), this card IS range-scoped: it
/// derives its window from the Overview page's selected date range (snapped
/// to the nearest allowed value) and evaluates decay relative to the range's
/// END, not real "now" — so it surfaces songs that faded *within that
/// period*. Only that Overview-embedded mode is implemented.
enum FadingFavoritesEngine {
    private struct ArtistTrackKey: Hashable {
        let artist: String
        let track: String
    }

    static let allowedDays = [30, 60, 90, 180, 365]
    /// Must have been a real favorite at its peak.
    static let minPeak = 5
    /// Recent plays must be <= 25% of the peak window's count.
    static let maxDecay = 0.25

    static func snappedRecentDays(for range: DateRange) -> Int {
        let days = Int((range.to.timeIntervalSince(range.from) / 86400).rounded())
        return allowedDays.min(by: { abs($0 - days) < abs($1 - days) }) ?? 90
    }

    /// Fading stats for every (artist, track) with plays up to `asOf`.
    /// `scrobbles` must be sorted ascending by `playedAt`.
    static func stats(scrobbles all: [ScrobbleSnapshot], windowDays: Int, asOf now: Date) -> [FadingFavoriteStats] {
        let windowSecs = Double(windowDays) * 86400
        let recentCutoff = now.addingTimeInterval(-windowSecs)

        // Drop plays after the period end so they don't inflate the peak or
        // recent counts.
        let inPeriod = all.filter { $0.playedAt <= now }

        var groups: [ArtistTrackKey: [ScrobbleSnapshot]] = [:]
        for s in inPeriod {
            groups[ArtistTrackKey(artist: s.artistName, track: s.trackName), default: []].append(s)
        }

        var result: [FadingFavoriteStats] = []
        result.reserveCapacity(groups.count)
        for (key, group) in groups {
            let times = group.map(\.playedAt) // ascending, since `all` was fetched sorted and append preserves order
            guard !times.isEmpty else { continue }

            // Peak density: most plays in any span `windowSecs` long (sliding window, two-pointer).
            // The window's actual bounds (not just its count) are tracked as a side effect of the same
            // pass, at no extra asymptotic cost.
            var left = 0
            var peakCount = 0
            var peakWindowStart = times[0]
            var peakWindowEnd = times[0]
            for right in 0..<times.count {
                while times[right].timeIntervalSince(times[left]) >= windowSecs { left += 1 }
                let count = right - left + 1
                if count > peakCount {
                    peakCount = count
                    peakWindowStart = times[left]
                    peakWindowEnd = times[right]
                }
            }

            var recentCount = 0
            var i = times.count - 1
            while i >= 0 && times[i] >= recentCutoff {
                recentCount += 1
                i -= 1
            }

            var albumCounts: [String: Int] = [:]
            for s in group where !s.albumName.isEmpty { albumCounts[s.albumName, default: 0] += 1 }
            // Most-played album; a tie goes to the alphabetically-first name so
            // the result never depends on dictionary iteration order.
            let bestAlbum = albumCounts.max { a, b in
                a.value != b.value ? a.value < b.value : a.key > b.key
            }?.key
            let image = TextNormalization.firstNonPlaceholderImage(group.map(\.imageURL))

            result.append(FadingFavoriteStats(
                track: key.track, artist: key.artist, album: bestAlbum, imageURL: image,
                totalPlaycount: times.count, peakPlaycount: peakCount,
                peakWindowStart: peakWindowStart, peakWindowEnd: peakWindowEnd,
                recentPlaycount: recentCount, lastPlayed: times.last!
            ))
        }
        return result
    }

    static func fetch(scrobbles all: [ScrobbleSnapshot], range: DateRange, limit: Int = 100) -> [FadingFavoriteEntry] {
        let all = stats(scrobbles: all, windowDays: snappedRecentDays(for: range), asOf: range.to)

        var entries: [FadingFavoriteEntry] = []
        for stat in all {
            guard stat.peakPlaycount >= minPeak, stat.decayScore <= maxDecay else { continue }
            entries.append(FadingFavoriteEntry(
                track: stat.track, artist: stat.artist, album: stat.album, imageURL: stat.imageURL,
                totalPlaycount: stat.totalPlaycount, peakPlaycount: stat.peakPlaycount,
                recentPlaycount: stat.recentPlaycount, lastPlayed: stat.lastPlayed, decayScore: stat.decayScore
            ))
        }

        // Rediscovery score: big peak x how faded it is. Then most-forgotten first.
        entries.sort { a, b in
            let scoreA = Double(a.peakPlaycount) * (1 - a.decayScore)
            let scoreB = Double(b.peakPlaycount) * (1 - b.decayScore)
            if scoreA != scoreB { return scoreA > scoreB }
            if a.peakPlaycount != b.peakPlaycount { return a.peakPlaycount > b.peakPlaycount }
            return a.lastPlayed < b.lastPlayed
        }
        return Array(entries.prefix(limit))
    }
}
