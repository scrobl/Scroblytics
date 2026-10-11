import Foundation

/// What a chart adds up: play count, or time listened. Each chart offers this on its own — not one setting for the
/// whole page — because it doesn't mean the same thing everywhere, and some charts can't use it at all (Listening
/// flow counts hand-offs between plays, which have no duration of their own).
enum TrendsMetric: String, CaseIterable, Identifiable, Sendable {
    case plays, timeListened
    var id: String { rawValue }
    var label: String { self == .plays ? "Scrobbles" : "Time listened" }
}

enum TrendsWeight {
    /// The weight of one play under `metric`: always 1 for scrobbles; its track's runtime in seconds for time
    /// listened. nil means the runtime hasn't been looked up yet — never guessed at, so a chart can report it as
    /// pending instead of silently undercounting.
    static func of(_ s: ScrobbleSnapshot, metric: TrendsMetric, durations: DurationEngine.Snapshot) -> Int? {
        guard metric == .timeListened else { return 1 }
        guard !s.trackName.isEmpty else { return 0 }
        switch durations.resolution(forKey: DurationEngine.cacheKey(artist: s.artistName, track: s.trackName)) {
        case .seconds(let seconds): return seconds
        case .noMatch: return 0
        case .pending: return nil
        }
    }

    static func format(_ value: Int, metric: TrendsMetric) -> String {
        metric == .plays ? value.formatted() : TrendsDuration.format(value)
    }
}

/// `DurationEngine`'s own formatters are main-actor bound (they're only ever called from views); Trends computes on a
/// background task, so these are the same notations reproduced without that isolation.
enum TrendsDuration {
    /// "1d 2h 3m 4s" — aggregate listening time.
    static func format(_ totalSeconds: Int) -> String {
        let total = max(0, totalSeconds)
        let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 || days > 0 { parts.append("\(hours)h") }
        if minutes > 0 || hours > 0 || days > 0 { parts.append("\(minutes)m") }
        parts.append("\(seconds)s")
        return parts.joined(separator: " ")
    }

    /// A shorter form for axis labels and bin ranges: drops the smaller units ("6m", "1h 8m", "1d 17h").
    static func formatCompact(_ totalSeconds: Int) -> String {
        let total = max(0, totalSeconds)
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }
}
