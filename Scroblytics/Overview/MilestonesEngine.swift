import Foundation

struct MilestoneUpcoming: Identifiable, Hashable, Sendable {
    let id = UUID()
    let entity: TopChartsEntity
    /// nil for an artist-level entry (the name itself IS the artist).
    let artist: String?
    let name: String
    let album: String?
    let imageURL: String?
    let current: Int
    let next: Int
    let remaining: Int
    let etaDays: Int?
}

struct MilestoneAchieved: Identifiable, Hashable, Sendable {
    let id = UUID()
    let artist: String?
    let name: String
    let album: String?
    let imageURL: String?
    let current: Int
    let milestone: Int
    let achievedAt: Date
    let firstAt: Date
}

struct MilestoneCategory: Sendable {
    let upcoming: [MilestoneUpcoming]
    let achieved: [MilestoneAchieved]
}

struct TotalMilestones: Sendable {
    let current: Int
    let upcoming: (next: Int, remaining: Int, etaDays: Int?)?
    let achieved: [(milestone: Int, achievedAt: Date, firstAt: Date)]
}

struct MilestonesResult: Sendable {
    let total: TotalMilestones
    let artists: MilestoneCategory
    let albums: MilestoneCategory
    let tracks: MilestoneCategory
}

/// Milestones. There's no dedicated PRD for this one; thresholds include 250
/// and 2500.
enum MilestonesEngine {
    private static let base = [100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000]
    /// Max cards per category, so a huge library stays readable/fast.
    private static let cap = 60
    /// Trailing window used to estimate each entity's current scrobble pace.
    private static let etaWindowDays = 30

    private static func nextMilestone(_ count: Int) -> Int {
        for t in base where count < t { return t }
        return (count / 100_000 + 1) * 100_000
    }

    private static func isMilestone(_ count: Int) -> Bool {
        if base.contains(count) { return true }
        return count > 100_000 && count % 100_000 == 0
    }

    private static func estimateEtaDays(remaining: Int, recentCount: Int) -> Int? {
        guard recentCount > 0 else { return nil }
        return Int((Double(remaining) * Double(etaWindowDays) / Double(recentCount)).rounded(.up))
    }

    private struct ArtistTrackKey: Hashable { let artist: String; let track: String }
    private struct ArtistAlbumKey: Hashable { let artist: String; let album: String }

    /// Mutable reference type of
    /// plain mutable objects, avoiding value-type copy-on-write churn while
    /// accumulating in place across a six-figure scrobble count.
    private final class Accumulator {
        let name: String
        let artist: String?
        var album: String?
        var count = 0
        var image: String?
        var milestones: [(milestone: Int, achievedAt: Date)] = []
        var recentCount = 0
        let firstAt: Date

        init(name: String, artist: String?, album: String?, firstAt: Date) {
            self.name = name
            self.artist = artist
            self.album = album
            self.firstAt = firstAt
        }
    }

    /// Every per-entity accumulator plus the library-wide totals, before any card cap.
    private struct Accumulation {
        var artists: [String: Accumulator] = [:]
        var albums: [ArtistAlbumKey: Accumulator] = [:]
        var tracks: [ArtistTrackKey: Accumulator] = [:]
        var totalCount = 0
        var totalRecentCount = 0
        var totalAchieved: [(milestone: Int, achievedAt: Date, firstAt: Date)] = []
    }

    private static func accumulate(_ sorted: [ScrobbleSnapshot], referenceDate: Date) -> Accumulation {
        let etaCutoff = referenceDate.addingTimeInterval(-Double(etaWindowDays) * 86400)

        var artistAcc: [String: Accumulator] = [:]
        var albumAcc: [ArtistAlbumKey: Accumulator] = [:]
        var trackAcc: [ArtistTrackKey: Accumulator] = [:]

        var totalCount = 0
        var totalRecentCount = 0
        var totalAchieved: [(milestone: Int, achievedAt: Date, firstAt: Date)] = []
        let totalFirstAt = sorted.first?.playedAt ?? referenceDate

        func bump(_ acc: Accumulator, playedAt: Date, imageURL: String?) {
            acc.count += 1
            if playedAt >= etaCutoff { acc.recentCount += 1 }
            if acc.image == nil, let imageURL, !imageURL.isEmpty { acc.image = imageURL }
            if isMilestone(acc.count) { acc.milestones.append((acc.count, playedAt)) }
        }

        for s in sorted {
            totalCount += 1
            if s.playedAt >= etaCutoff { totalRecentCount += 1 }
            if isMilestone(totalCount) { totalAchieved.append((totalCount, s.playedAt, totalFirstAt)) }

            let artist: Accumulator
            if let existing = artistAcc[s.artistName] {
                artist = existing
            } else {
                artist = Accumulator(name: s.artistName, artist: nil, album: nil, firstAt: s.playedAt)
                artistAcc[s.artistName] = artist
            }
            bump(artist, playedAt: s.playedAt, imageURL: s.imageURL)

            if !s.albumName.isEmpty {
                let key = ArtistAlbumKey(artist: s.artistName, album: s.albumName)
                let album: Accumulator
                if let existing = albumAcc[key] {
                    album = existing
                } else {
                    album = Accumulator(name: s.albumName, artist: s.artistName, album: nil, firstAt: s.playedAt)
                    albumAcc[key] = album
                }
                bump(album, playedAt: s.playedAt, imageURL: s.imageURL)
            }

            let tkey = ArtistTrackKey(artist: s.artistName, track: s.trackName)
            let track: Accumulator
            if let existing = trackAcc[tkey] {
                track = existing
            } else {
                track = Accumulator(name: s.trackName, artist: s.artistName, album: s.albumName.isEmpty ? nil : s.albumName, firstAt: s.playedAt)
                trackAcc[tkey] = track
            }
            if track.album == nil, !s.albumName.isEmpty { track.album = s.albumName }
            bump(track, playedAt: s.playedAt, imageURL: s.imageURL)
        }

        return Accumulation(
            artists: artistAcc, albums: albumAcc, tracks: trackAcc,
            totalCount: totalCount, totalRecentCount: totalRecentCount, totalAchieved: totalAchieved
        )
    }

    /// One entity's milestone standing: how many plays, the next threshold, the pace-based
    /// estimate, and every threshold it has crossed (oldest first).
    struct EntityStats: Sendable {
        let count: Int
        let next: Int
        let remaining: Int
        /// Days to the next milestone at the last 30 days' pace; nil with no recent plays.
        let etaDays: Int?
        let achieved: [Achievement]

        struct Achievement: Sendable {
            let milestone: Int
            let achievedAt: Date
        }
    }

    struct EntityEntry: Sendable {
        /// nil for an artist (the name IS the artist).
        let artist: String?
        let name: String
        let stats: EntityStats
    }

    /// Milestone standing for EVERY artist, album and track — uncapped, unlike the card's
    /// per-category top 60. `scrobbles` must be sorted ascending.
    static func entityStats(scrobbles sorted: [ScrobbleSnapshot], referenceDate: Date = Date())
        -> (artists: [EntityEntry], albums: [EntityEntry], tracks: [EntityEntry]) {
        let accumulation = accumulate(sorted, referenceDate: referenceDate)
        func entries(_ accs: [Accumulator]) -> [EntityEntry] {
            accs.map { acc in
                let next = nextMilestone(acc.count)
                let remaining = next - acc.count
                return EntityEntry(artist: acc.artist, name: acc.name, stats: EntityStats(
                    count: acc.count, next: next, remaining: remaining,
                    etaDays: estimateEtaDays(remaining: remaining, recentCount: acc.recentCount),
                    achieved: acc.milestones.map { .init(milestone: $0.milestone, achievedAt: $0.achievedAt) }
                ))
            }
        }
        return (entries(Array(accumulation.artists.values)), entries(Array(accumulation.albums.values)), entries(Array(accumulation.tracks.values)))
    }

    static func fetch(scrobbles sorted: [ScrobbleSnapshot], referenceDate: Date = Date()) -> MilestonesResult {
        let accumulation = accumulate(sorted, referenceDate: referenceDate)
        let (artistAcc, albumAcc, trackAcc) = (accumulation.artists, accumulation.albums, accumulation.tracks)
        let (totalCount, totalRecentCount, totalAchieved) = (accumulation.totalCount, accumulation.totalRecentCount, accumulation.totalAchieved)

        func buildCategory(_ accs: [Accumulator], entity: TopChartsEntity) -> MilestoneCategory {
            let upcoming = accs
                .map { acc -> MilestoneUpcoming in
                    let next = nextMilestone(acc.count)
                    let remaining = next - acc.count
                    return MilestoneUpcoming(
                        entity: entity,
                        artist: acc.artist, name: acc.name, album: acc.album, imageURL: acc.image,
                        current: acc.count, next: next, remaining: remaining,
                        etaDays: estimateEtaDays(remaining: remaining, recentCount: acc.recentCount)
                    )
                }
                // Closest to their next milestone first; ties broken alphabetically.
                .sorted { a, b in
                    if a.remaining != b.remaining { return a.remaining < b.remaining }
                    return a.name < b.name
                }
                .prefix(cap)

            // One row per threshold crossed, not per entity.
            let achieved = accs
                .flatMap { acc in
                    acc.milestones.map { m in
                        MilestoneAchieved(
                            artist: acc.artist, name: acc.name, album: acc.album, imageURL: acc.image,
                            current: acc.count, milestone: m.milestone, achievedAt: m.achievedAt, firstAt: acc.firstAt
                        )
                    }
                }
                // Most recently achieved first; ties broken by bigger milestone.
                .sorted { a, b in
                    if a.achievedAt != b.achievedAt { return a.achievedAt > b.achievedAt }
                    return a.milestone > b.milestone
                }

            return MilestoneCategory(upcoming: Array(upcoming), achieved: achieved)
        }

        let artists = buildCategory(Array(artistAcc.values), entity: .artist)
        let albums = buildCategory(Array(albumAcc.values), entity: .album)
        let tracks = buildCategory(Array(trackAcc.values), entity: .track)

        let nextTotal = nextMilestone(totalCount)
        let totalRemaining = nextTotal - totalCount
        let total = TotalMilestones(
            current: totalCount,
            upcoming: totalCount > 0
                ? (next: nextTotal, remaining: totalRemaining, etaDays: estimateEtaDays(remaining: totalRemaining, recentCount: totalRecentCount))
                : nil,
            achieved: totalAchieved.reversed()
        )

        return MilestonesResult(total: total, artists: artists, albums: albums, tracks: tracks)
    }

    /// Overview card: mixed artist/album/track "upcoming" entries (the total's own upcoming isn't
    /// included in the Overview card, only per-entity ones).
    static func overviewCandidates(from result: MilestonesResult) -> [MilestoneUpcoming] {
        result.artists.upcoming + result.albums.upcoming + result.tracks.upcoming
    }

    /// Achieved thresholds plus the next upcoming one, for a single entity's
    /// own history — the detail page's Milestones section. Deliberately not
    /// `fetch(scrobbles:)`: that walks the whole library building per-artist/
    /// album/track accumulators simultaneously, far more than one entity's
    /// header needs. Reuses the same threshold/ETA rules on the caller's
    /// already-scoped, ascending-by-date scrobbles.
    struct EntityMilestones: Sendable {
        let achieved: [(milestone: Int, achievedAt: Date, firstAt: Date)]
        let upcoming: (next: Int, remaining: Int, etaDays: Int?)?
    }

    static func fetchForEntity(scrobblesSortedAscending sorted: [ScrobbleSnapshot], referenceDate: Date = Date()) -> EntityMilestones {
        guard let firstAt = sorted.first?.playedAt else {
            return EntityMilestones(achieved: [], upcoming: nil)
        }
        let etaCutoff = referenceDate.addingTimeInterval(-Double(etaWindowDays) * 86400)
        var achieved: [(milestone: Int, achievedAt: Date, firstAt: Date)] = []
        var count = 0
        var recentCount = 0
        for s in sorted {
            count += 1
            if s.playedAt >= etaCutoff { recentCount += 1 }
            if isMilestone(count) { achieved.append((count, s.playedAt, firstAt)) }
        }
        let next = nextMilestone(count)
        let remaining = next - count
        return EntityMilestones(
            achieved: achieved.reversed(),
            upcoming: (next: next, remaining: remaining, etaDays: estimateEtaDays(remaining: remaining, recentCount: recentCount))
        )
    }
}
