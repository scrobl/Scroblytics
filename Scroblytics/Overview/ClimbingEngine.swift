import Foundation

/// Climbers core ranking: compares each track's all-time rank now against its
/// all-time rank as of `windowDays` ago. "Hot Shot Debut" marks a
/// track with no plays before the cutoff that broke into the top quarter of the whole library.
///
/// The only consumer left is the Field Registry's climbing columns (`QueryClimbingFields.swift`) — the
/// Overview "Climbing" card and the Tools page's own The Climb both moved onto `TheClimbEngine`
/// (`Tools/TheClimb.swift`), which reads a track's rank at several points via `playRank` instead of this
/// engine's own two-point `fetch`, and gates on breaking into a competitive tier rather than raw distance.
enum ClimbingEngine {
    private struct ArtistTrackKey: Hashable {
        let artist: String
        let track: String
    }

    static let allowedWindows = [30, 60, 90, 180, 365]
    private static let hotShotFraction = 0.25

    /// One track's climbing numbers. The query framework's fields read these.
    struct Stats: Hashable, Sendable {
        let track: String
        let artist: String
        /// All-time rank as of `referenceDate` (1 = most played).
        let currentRank: Int
        /// All-time rank as of the window's start; nil = no plays before it.
        let previousRank: Int?
        /// Plays within the recent window only (not all-time).
        let recentPlays: Int
        let lastPlayed: Date
        /// The engine's own ranking value: places gained when the track already had
        /// history, or the debut score (`priorTracks + 1 - currentRank`) when it didn't.
        /// Negative when a track fell.
        let velocity: Int
        /// No plays before the window AND currently in the top quarter of the library.
        let isHotShotDebut: Bool
    }

    /// Stats for every track, in current-rank order. `scrobbles` must be sorted ascending.
    static func stats(scrobbles all: [ScrobbleSnapshot], windowDays: Int = 90, referenceDate: Date = Date()) -> [Stats] {
        let days = allowedWindows.contains(windowDays) ? windowDays : 90
        let cutoff = referenceDate.addingTimeInterval(-Double(days) * 86400)

        guard !all.isEmpty else { return [] }

        var groups: [ArtistTrackKey: [ScrobbleSnapshot]] = [:]
        for s in all {
            groups[ArtistTrackKey(artist: s.artistName, track: s.trackName), default: []].append(s)
        }

        // Value desc (play count), ties by artist then track name — identical
        // rule to Top Charts' own track ranking.
        func rankSort(_ a: (key: ArtistTrackKey, value: [ScrobbleSnapshot]), _ b: (key: ArtistTrackKey, value: [ScrobbleSnapshot])) -> Bool {
            if a.value.count != b.value.count { return a.value.count > b.value.count }
            if a.key.artist != b.key.artist { return a.key.artist < b.key.artist }
            return a.key.track < b.key.track
        }

        let currentRanked = groups.sorted(by: rankSort)

        var priorGroups: [ArtistTrackKey: [ScrobbleSnapshot]] = [:]
        for (key, group) in groups {
            let prior = group.filter { $0.playedAt <= cutoff }
            if !prior.isEmpty { priorGroups[key] = prior }
        }
        let priorRanked = priorGroups.sorted(by: rankSort)
        var priorRanks: [ArtistTrackKey: Int] = [:]
        for (index, entry) in priorRanked.enumerated() { priorRanks[entry.key] = index + 1 }
        let totalPriorTracks = priorRanked.count
        let hotShotCutoffRank = Int((Double(currentRanked.count) * hotShotFraction).rounded(.up))

        var stats: [Stats] = []
        stats.reserveCapacity(currentRanked.count)
        for (index, entry) in currentRanked.enumerated() {
            let currentRank = index + 1
            let previousRank = priorRanks[entry.key]
            let isHotShotDebut = previousRank == nil && currentRank <= hotShotCutoffRank
            stats.append(Stats(
                track: entry.key.track, artist: entry.key.artist, currentRank: currentRank, previousRank: previousRank,
                recentPlays: entry.value.filter { $0.playedAt > cutoff }.count,
                lastPlayed: entry.value.last?.playedAt ?? referenceDate,
                velocity: previousRank.map { $0 - currentRank } ?? (totalPriorTracks + 1 - currentRank),
                isHotShotDebut: isHotShotDebut
            ))
        }
        return stats
    }
}
