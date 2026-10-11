import Foundation

enum TrendGranularity {
    case day, week, month
}

struct TrendBucket: Sendable {
    let start: Date
    let count: Int
}

/// Trend series (`buildSeries`/`localBucketStart`/`autoGranularity`),
/// scoped to a single artist/album/track for Top Picks' inline sparklines.
/// Purely local (no network calls, no expensive per-sync computation), so
/// unlike Reverb/Album Turnover this needs no caching strategy. Pure
/// computation over a `Sendable` snapshot — safe to run off the main actor.
enum TrendEngine {
    static func autoGranularity(_ range: DateRange) -> TrendGranularity {
        let days = range.to.timeIntervalSince(range.from) / 86400
        if days <= 92 { return .day }
        if days <= 730 { return .week }
        return .month
    }

    /// Local-calendar bucket start (day / Monday-start week / month) —
    /// Anchored locally (bucketing by UTC calendar
    /// fields would shift evening/morning plays across the boundary for any
    /// non-UTC timezone).
    static func bucketStart(_ date: Date, granularity: TrendGranularity) -> Date {
        let calendar = AppCalendars.listening
        switch granularity {
        case .day: return calendar.startOfDay(for: date)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)!.start
        case .month: return calendar.dateInterval(of: .month, for: date)!.start
        }
    }

    static func nextBucket(_ date: Date, granularity: TrendGranularity) -> Date {
        let calendar = AppCalendars.listening
        switch granularity {
        case .day: return calendar.date(byAdding: .day, value: 1, to: date)!
        case .week: return calendar.date(byAdding: .day, value: 7, to: date)!
        case .month: return calendar.date(byAdding: .month, value: 1, to: date)!
        }
    }

    /// Dense, zero-filled bucket series covering the whole range — matches
    /// source walking `cursor` from the range's first bucket to its last
    /// regardless of which buckets actually have scrobbles.
    static func series(scrobbles: [ScrobbleSnapshot], range: DateRange, granularity: TrendGranularity) -> [TrendBucket] {
        var counts: [Date: Int] = [:]
        for s in scrobbles where s.playedAt >= range.from && s.playedAt <= range.to {
            let bucket = bucketStart(s.playedAt, granularity: granularity)
            counts[bucket, default: 0] += 1
        }
        var result: [TrendBucket] = []
        var cursor = bucketStart(range.from, granularity: granularity)
        let end = bucketStart(range.to, granularity: granularity)
        while cursor <= end {
            result.append(TrendBucket(start: cursor, count: counts[cursor] ?? 0))
            cursor = nextBucket(cursor, granularity: granularity)
        }
        return result
    }

    /// Scoped per top-entity kind:
    /// artist-only for Top artist, artist+album for Top album, artist+track
    /// (no album) for Top track.
    static func fetch(scrobbles all: [ScrobbleSnapshot], artist: String?, album: String?, track: String?, range: DateRange) -> [TrendBucket] {
        var filtered = all
        if let artist { filtered = filtered.filter { $0.artistName == artist } }
        if let album { filtered = filtered.filter { $0.albumName == album } }
        if let track { filtered = filtered.filter { $0.trackName == track } }
        return series(scrobbles: filtered, range: range, granularity: autoGranularity(range))
    }
}
