import Foundation
import SwiftData

/// Basic drill-down stats — Plays and First/Last scrobble only, per the
/// revised Phase 1 brief. Time listened, Milestones, Chart positions, Tags,
/// and Turnover status are all deferred to a later layer once their
/// underlying subsystems (track duration resolution, historical rank
/// snapshots, Tags, Album Turnover) exist.
struct EntityStats: Sendable {
    let plays: Int
    let firstScrobble: Date?
    let lastScrobble: Date?
    let imageURL: String?
    /// Track-only — Last.fm loves are scoped to (artist, track), so this is
    /// always `false` for artist/album stats. Read from the locally-synced
    /// `LovedTrackEntry` set, never a live per-view call.
    let loved: Bool
    /// Dense bucketed play counts spanning the selected period — feeds the
    /// header's mini-trend sparkline. Empty when there aren't at least two
    /// scrobbles to draw a line between.
    let trend: [TrendBucket]
    /// This entity's own milestone thresholds crossed, plus the next one
    /// upcoming — see `MilestonesEngine.fetchForEntity`.
    let milestones: MilestonesEngine.EntityMilestones

    /// Play frequency stat: average days
    /// between plays across the entity's own lifetime. `nil` (rendered "—")
    /// until there are at least two scrobbles to measure a gap between.
    var averageDaysBetweenPlays: Double? {
        guard plays > 1, let firstScrobble, let lastScrobble else { return nil }
        return lastScrobble.timeIntervalSince(firstScrobble) / 86400 / Double(plays - 1)
    }
}

struct ScrobbleHistoryEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let playedAt: Date
    let album: String?
}

/// Entity stats matching rules: an artist-only query matches the artist ignoring capitalization;
/// an album query additionally applies `trackMatchesArtistContext` so a
/// collab-credited track ("Artist A & Artist B") still counts toward the
/// artist's own album; a track query is artist (capitalization ignored) + exact track title,
/// deliberately album-agnostic — a track's plays span every album it
/// appears under.
@ModelActor
private actor EntityStatsDataReader {
    func fetchAlbumSnapshots(
        artist: String,
        album: String,
        range: DateRange
    ) throws -> [ScrobbleSnapshot] {
        let descriptor = FetchDescriptor<Scrobble>(predicate: #Predicate<Scrobble> {
            $0.albumName == album
        })
        return try modelContext.fetch(descriptor)
            .filter {
                TextNormalization.trackMatchesArtistContext(trackArtist: $0.artistName, context: artist)
            }
            .map(\.snapshot)
    }
}

enum EntityStatsEngine {
    static func fetchArtistStats(context: ModelContext, artist: String, range: DateRange) throws -> EntityStats {
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let descriptor = FetchDescriptor<Scrobble>(predicate: #Predicate<Scrobble> {
            $0.artistName.localizedStandardContains(artist)
        })
        return try summarize(context.fetch(descriptor).filter { matchesArtist($0.artistName, key: artistKey) }, loved: false, range: range)
    }

    static func fetchAlbumStats(
        container: ModelContainer,
        artist: String,
        album: String,
        range: DateRange
    ) async throws -> EntityStats {
        let snapshots = try await offMain { try await EntityStatsDataReader(modelContainer: container).fetchAlbumSnapshots(artist: artist, album: album, range: range) }
        return summarize(snapshots, loved: false, range: range)
    }

    static func fetchAlbumStats(context: ModelContext, artist: String, album: String, range: DateRange) throws -> EntityStats {
        let descriptor = FetchDescriptor<Scrobble>(predicate: #Predicate<Scrobble> {
            $0.albumName == album
        })
        let candidates = try context.fetch(descriptor)
        let matched = candidates.filter { TextNormalization.trackMatchesArtistContext(trackArtist: $0.artistName, context: artist) }
        return summarize(matched, loved: false, range: range)
    }

    @MainActor
    static func fetchTrackStats(context: ModelContext, artist: String, track: String, range: DateRange) throws -> EntityStats {
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate<Scrobble> {
                $0.artistName.localizedStandardContains(artist) && $0.trackName == track
            }
        )
        let loved = LovedTracksEngine.isLoved(context: context, artist: artist, track: track)
        return try summarize(context.fetch(descriptor).filter { matchesArtist($0.artistName, key: artistKey) }, loved: loved, range: range)
    }

    /// Every individual play of this track —
    /// artist+track exact match, same album-agnostic scope as
    /// `fetchTrackStats` — newest first. Reached only at the deepest, track
    /// level of the drill chain (Phase 6): a flat scrobble list has no
    /// meaning for an artist or album, which each span many tracks.
    static func fetchTrackScrobbleHistory(context: ModelContext, artist: String, track: String, range: DateRange) throws -> [ScrobbleHistoryEntry] {
        let from = range.from
        let to = range.to
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate<Scrobble> {
                $0.artistName.localizedStandardContains(artist) && $0.trackName == track && $0.playedAt >= from && $0.playedAt <= to
            },
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).filter { matchesArtist($0.artistName, key: artistKey) }.map { ScrobbleHistoryEntry(playedAt: $0.playedAt, album: $0.albumName.isEmpty ? nil : $0.albumName) }
    }

    /// Time Listened for one artist — same fetch scope as `fetchArtistStats`.
    /// Not folded into `EntityStats` itself: unlike every other stat here,
    /// this needs `DurationEngine` (network on a cold cache), so it's loaded
    /// as its own separate, optional async value by callers, matching this
    /// app's established "on-demand, not baked into the fast local fetch"
    /// convention for anything Deezer-backed.
    @MainActor
    static func fetchArtistTimeListened(context: ModelContext, client: DeezerAPIClient, artist: String, range: DateRange) async -> Int {
        let from = range.from
        let to = range.to
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let descriptor = FetchDescriptor<Scrobble>(predicate: #Predicate<Scrobble> {
            $0.artistName.localizedStandardContains(artist) && $0.playedAt >= from && $0.playedAt <= to
        })
        let scrobbles = (try? context.fetch(descriptor).filter { matchesArtist($0.artistName, key: artistKey) }.map(\.snapshot)) ?? []
        return await DurationEngine.timeListenedSeconds(context: context, client: client, scrobbles: scrobbles)
    }

    /// Time Listened for one album — same fetch scope as `fetchAlbumStats`.
    @MainActor
    static func fetchAlbumTimeListened(context: ModelContext, client: DeezerAPIClient, artist: String, album: String, range: DateRange) async -> Int {
        let from = range.from
        let to = range.to
        let descriptor = FetchDescriptor<Scrobble>(predicate: #Predicate<Scrobble> {
            $0.albumName == album && $0.playedAt >= from && $0.playedAt <= to
        })
        let candidates = (try? context.fetch(descriptor)) ?? []
        let matched = candidates.filter { TextNormalization.trackMatchesArtistContext(trackArtist: $0.artistName, context: artist) }
        return await DurationEngine.timeListenedSeconds(context: context, client: client, scrobbles: matched.map(\.snapshot))
    }

    /// Time Listened for one track — same fetch scope as `fetchTrackStats`.
    @MainActor
    static func fetchTrackTimeListened(context: ModelContext, client: DeezerAPIClient, artist: String, track: String) async -> Int {
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let descriptor = FetchDescriptor<Scrobble>(predicate: #Predicate<Scrobble> { $0.artistName.localizedStandardContains(artist) && $0.trackName == track })
        let scrobbles = (try? context.fetch(descriptor).filter { matchesArtist($0.artistName, key: artistKey) }.map(\.snapshot)) ?? []
        return await DurationEngine.timeListenedSeconds(context: context, client: client, scrobbles: scrobbles)
    }

    /// The database narrows by a loose, case-insensitive text match; the exact identity test (capitalization and
    /// surrounding spaces ignored, nothing else) happens here.
    private static func matchesArtist(_ name: String, key: String) -> Bool {
        TextNormalization.artistIdentityKey(name) == key
    }

    private static func summarize(
        _ allTime: [ScrobbleSnapshot],
        loved: Bool,
        range: DateRange
    ) -> EntityStats {
        let scrobbles = allTime.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
        let first = scrobbles.map(\.playedAt).min()
        let last = scrobbles.map(\.playedAt).max()
        let image = TextNormalization.firstNonPlaceholderImage(scrobbles.map(\.imageURL))
        let trend = scrobbles.count > 1
            ? TrendEngine.series(
                scrobbles: scrobbles,
                range: range,
                granularity: TrendEngine.autoGranularity(range)
            )
            : []
        // Milestones are always all-time, regardless of the selected period.
        let sortedAscending = allTime.sorted { $0.playedAt < $1.playedAt }
        let milestones = MilestonesEngine.fetchForEntity(scrobblesSortedAscending: sortedAscending)
        return EntityStats(
            plays: scrobbles.count,
            firstScrobble: first,
            lastScrobble: last,
            imageURL: image,
            loved: loved,
            trend: trend,
            milestones: milestones
        )
    }

    private static func summarize(_ allTime: [Scrobble], loved: Bool, range: DateRange) -> EntityStats {
        let scrobbles = allTime.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
        var first: Date?
        var last: Date?
        for s in scrobbles {
            if first == nil || s.playedAt < first! { first = s.playedAt }
            if last == nil || s.playedAt > last! { last = s.playedAt }
        }
        let image = TextNormalization.firstNonPlaceholderImage(scrobbles.map(\.imageURL))
        let trend: [TrendBucket]
        if scrobbles.count > 1 {
            trend = TrendEngine.series(scrobbles: scrobbles.map(\.snapshot), range: range, granularity: TrendEngine.autoGranularity(range))
        } else {
            trend = []
        }
        // Milestones are always all-time, regardless of the selected period.
        let sortedAscending = allTime.sorted { $0.playedAt < $1.playedAt }.map(\.snapshot)
        let milestones = MilestonesEngine.fetchForEntity(scrobblesSortedAscending: sortedAscending)
        return EntityStats(plays: scrobbles.count, firstScrobble: first, lastScrobble: last, imageURL: image, loved: loved, trend: trend, milestones: milestones)
    }
}
