import Foundation
import SwiftData

enum ReverbRowType: String, Codable {
    case artist, album, track
}

/// A Reverb row. `loved` is dropped — the PRD says loved
/// status is explicitly not a requirement or a boost for Reverb, nothing
/// else here tracks "loved" for it either, and it isn't part of
/// the row content the PRD specifies (thumbnail/name/attribution/staleness).
struct ReverbRow: Codable, Identifiable, Hashable {
    var id: String { "\(type.rawValue)\u{0}\(artist)\u{0}\(name)" }
    let type: ReverbRowType
    /// The picked entity's display name (artist / album title / track title).
    let name: String
    let artist: String
    let album: String?
    let track: String?
    /// Seed that most contributed to this pick ("Because you liked …").
    let attributionSeed: String
    let daysSinceLastPlayed: Int
    let lastPlayed: Date
    /// Combined match/staleness score, used as the weight for the render-time draw.
    let weight: Double
    /// Locally-known artwork — same Scrobble.imageURL every other Overview
    /// card reads, not a new image-override subsystem.
    let imageURL: String?
}

struct ReverbPool: Codable {
    /// The store's sync identity when this pool was computed; nil if never synced.
    let computedForSyncAt: Date?
    let computedAt: Date
    let artists: [ReverbRow]
    let albums: [ReverbRow]
    let tracks: [ReverbRow]

    static func empty(computedForSyncAt: Date?, computedAt: Date) -> ReverbPool {
        ReverbPool(computedForSyncAt: computedForSyncAt, computedAt: computedAt, artists: [], albums: [], tracks: [])
    }

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && tracks.isEmpty }
}

/// The Reverb Overview card's backend: auto-seeds
/// `SimilarSoundsEngine` from the last 14 days of listening, excludes
/// anything played in that same window, re-ranks the rest by match score ×
/// staleness, and rolls the shared candidate pool up into three independent
/// artist/album/track lists.
///
/// The full pool is genuinely the expensive part (external Last.fm calls
/// per seed) — mirrors the PRD's explicit requirement to compute it once per
/// sync and cache it, the same category of gap just found and fixed on
/// Album Turnover's tracklist lookups. Only the final weighted-random draw
/// (`weightedPick`) is meant to run fresh on every Overview load.
@MainActor
enum ReverbEngine {
    /// The PRD's prose says "last 10
    /// days" / "top 10 seeds", but the implemented values are 14 and 15
    /// (as with Milestones' thresholds and Album Turnover's
    /// MIN_TURNOVER_TRACKS).
    static let recentDays = 14
    static let maxSeeds = 15
    static let listCap = 10

    /// Combines match score (0-100) with staleness and the candidate's own
    /// local play count. Staleness gives strong matches a bounded boost the
    /// longer they've gone unplayed (days clamped to a year); the play-count
    /// factor pulls the other way, favoring picks the user has actually
    /// listened to before over ones heard once or twice — so a rare/barely-
    /// heard pick still surfaces sometimes, but far less often than familiar
    /// stale favorites.
    static func reverbWeight(matchScore: Int, daysSince: Double, playCount: Int) -> Double {
        let stalenessBoost = 1 + min(max(daysSince, 0), 365) / 365
        let playCountBoost = 1 + log2(Double(max(playCount, 1)) + 1) * 0.25
        return Double(matchScore) * stalenessBoost * playCountBoost
    }

    enum Grouping {
        case track, artist, album
    }

    /// Rolls a shared candidate pool up into one of the three independent
    /// rankings. Track rows map 1:1; artist/album rows group the underlying
    /// track candidates and aggregate their weights, so an entity backed by
    /// several strong stale matches ranks above one lucky track.
    static func buildReverbRows(pool: [RecommendedCandidate], now: Date, grouping: Grouping) -> [ReverbRow] {
        func daysSince(_ lastPlayed: Date) -> Double {
            max(0, now.timeIntervalSince(lastPlayed) / 86400)
        }

        if grouping == .track {
            return pool
                .map { c -> ReverbRow in
                    let d = daysSince(c.lastPlayed)
                    return ReverbRow(
                        type: .track, name: c.track, artist: c.artist, album: c.album, track: c.track,
                        attributionSeed: c.topSource, daysSinceLastPlayed: Int(d.rounded()), lastPlayed: c.lastPlayed,
                        weight: reverbWeight(matchScore: c.matchScore, daysSince: d, playCount: c.totalPlaycount),
                        imageURL: c.imageURL
                    )
                }
                .sorted { $0.weight > $1.weight }
                .prefix(listCap)
                .map { $0 }
        }

        struct Group {
            var name: String
            var artist: String
            var album: String?
            var weight: Double
            var bestMatch: Int
            var attributionSeed: String
            var lastPlayed: Date
            /// Every member candidate's image, resolved to one non-placeholder
            /// URL (if any) once the group is fully collected.
            var images: [String?]
        }
        var groups: [String: Group] = [:]
        var groupKeysOrdered: [String] = []
        for c in pool {
            if grouping == .album, c.album == nil { continue }
            let key = grouping == .artist ? c.artist.lowercased() : "\(c.artist.lowercased())\u{0}\(c.album!.lowercased())"
            let d = daysSince(c.lastPlayed)
            let w = reverbWeight(matchScore: c.matchScore, daysSince: d, playCount: c.totalPlaycount)
            if var existing = groups[key] {
                existing.weight += w
                if c.lastPlayed > existing.lastPlayed { existing.lastPlayed = c.lastPlayed }
                if c.matchScore > existing.bestMatch {
                    existing.bestMatch = c.matchScore
                    existing.attributionSeed = c.topSource
                }
                existing.images.append(c.imageURL)
                groups[key] = existing
            } else {
                groups[key] = Group(
                    name: grouping == .artist ? c.artist : c.album!, artist: c.artist,
                    album: grouping == .album ? c.album : nil, weight: w, bestMatch: c.matchScore,
                    attributionSeed: c.topSource, lastPlayed: c.lastPlayed, images: [c.imageURL]
                )
                groupKeysOrdered.append(key)
            }
        }
        return groupKeysOrdered.map { groups[$0]! }
            .map { g -> ReverbRow in
                ReverbRow(
                    type: grouping == .artist ? .artist : .album, name: g.name, artist: g.artist, album: g.album, track: nil,
                    attributionSeed: g.attributionSeed, daysSinceLastPlayed: Int(daysSince(g.lastPlayed).rounded()), lastPlayed: g.lastPlayed,
                    weight: g.weight, imageURL: TextNormalization.firstNonPlaceholderImage(g.images)
                )
            }
            .sorted { $0.weight > $1.weight }
            .prefix(listCap)
            .map { $0 }
    }

    /// Returns nil (rather than an empty pool) when the compute produced no
    /// candidates BECAUSE OF a transient upstream failure — the caller must
    /// then keep the previous pool instead of overwriting it.
    static func computeReverbPool(context: ModelContext, client: LastfmAPIClient, syncedAt: Date?) async throws -> ReverbPool? {
        let now = Date()
        // One background read of the library, shared with the similar-sounds matching below.
        let container = context.container
        let allScrobbles = try await ScrobbleHistoryCache.shared.snapshots(container: container)

        // Auto-seed: distinct artists played in the last 14 days, capped to
        // the top 15 by play count within that window. First-encountered
        // order breaks count ties
        // under a stable sort.
        let windowStart = now.addingTimeInterval(-Double(recentDays) * 86400)
        let maxSeeds = Self.maxSeeds
        let seeds: [RecommendationSeed] = await offMain {
            var recentCounts: [String: Int] = [:]
            var recentOrder: [String] = []
            var recentDisplayName: [String: String] = [:]
            for s in allScrobbles where s.playedAt >= windowStart {
                let key = s.artistName.lowercased()
                if recentCounts[key] == nil {
                    recentOrder.append(key)
                    recentDisplayName[key] = s.artistName
                }
                recentCounts[key, default: 0] += 1
            }
            return recentOrder
                .sorted { recentCounts[$0]! > recentCounts[$1]! }
                .prefix(maxSeeds)
                .map { .artist(recentDisplayName[$0]!) }
        }

        guard !seeds.isEmpty else { return .empty(computedForSyncAt: syncedAt, computedAt: now) }

        let (candidates, seedResults) = try await SimilarSoundsEngine.run(seeds: seeds, scrobbles: allScrobbles, client: client)
        if candidates.isEmpty {
            // fetchSimilarArtists/fetchSimilarTracks swallow Last.fm errors
            // (rate-limit/network) and return [] (see LastfmAPIClient), so a
            // bad moment upstream surfaces here as zero candidates. If not a
            // single seed found ANY similar artist/track, that's almost
            // certainly a fetch failure, not "nothing is similar to
            // anything" — persisting an empty pool would overwrite the last
            // good one and freeze the card blank until the next sync.
            let anySimilarFound = seedResults.contains { $0.similarFound > 0 }
            return anySimilarFound ? .empty(computedForSyncAt: syncedAt, computedAt: now) : nil
        }

        // Staleness exclusion: drop anything played within the recent window
        // — a "similar" pick already in heavy rotation defeats the purpose.
        let stale = candidates.filter { $0.lastPlayed < windowStart }
        // Relaxed fallback keeps every candidate, used per-entity only when
        // the stale pool can't fill that list, so a row never renders empty.
        func pick(_ grouping: Grouping) -> [ReverbRow] {
            let primary = buildReverbRows(pool: stale, now: now, grouping: grouping)
            return primary.isEmpty ? buildReverbRows(pool: candidates, now: now, grouping: grouping) : primary
        }

        return ReverbPool(
            computedForSyncAt: syncedAt, computedAt: now,
            artists: pick(.artist), albums: pick(.album), tracks: pick(.track)
        )
    }

    /// Cache-aware entry point. The pool is recomputed synchronously the first
    /// time a new sync's pool is needed, with an instant cache hit on every
    /// reload after that — the "compute once per sync, not per page load"
    /// guarantee the PRD requires, without a background-task-plus-broadcast
    /// mechanism nothing else in this app has.
    /// First load after a new sync pays the cost once; every reload after
    /// that until the next sync is free.
    static func fetch(context: ModelContext, client: LastfmAPIClient) async throws -> ReverbPool {
        let syncedAt = try context.fetch(FetchDescriptor<SyncState>()).first?.lastSyncedAt

        var descriptor = FetchDescriptor<ReverbPoolCache>()
        descriptor.fetchLimit = 1
        let cachedEntry = try context.fetch(descriptor).first
        let cachedPool = cachedEntry.map { entry -> ReverbPool in
            ReverbPool(
                computedForSyncAt: entry.computedForSyncAt, computedAt: entry.computedAt,
                artists: (try? JSONDecoder().decode([ReverbRow].self, from: entry.artistsJSON)) ?? [],
                albums: (try? JSONDecoder().decode([ReverbRow].self, from: entry.albumsJSON)) ?? [],
                tracks: (try? JSONDecoder().decode([ReverbRow].self, from: entry.tracksJSON)) ?? []
            )
        }

        let fresh = cachedPool != nil && cachedPool?.computedForSyncAt == syncedAt
        // A "fresh" but fully empty pool is almost always the residue of a
        // past transient failure — retry it too, so the card self-heals on
        // the next load instead of staying blank until a resync.
        let needsRecompute = (!fresh || cachedPool?.isEmpty == true) && syncedAt != nil && !allScrobblesEmpty(context)

        guard needsRecompute else {
            return cachedPool ?? .empty(computedForSyncAt: nil, computedAt: Date())
        }

        guard let recomputed = try await computeReverbPool(context: context, client: client, syncedAt: syncedAt) else {
            // Transient failure signal — keep serving whatever was cached.
            return cachedPool ?? .empty(computedForSyncAt: nil, computedAt: Date())
        }

        let entry = cachedEntry ?? ReverbPoolCache(
            computedForSyncAt: nil, computedAt: Date(),
            artistsJSON: Data(), albumsJSON: Data(), tracksJSON: Data()
        )
        entry.computedForSyncAt = recomputed.computedForSyncAt
        entry.computedAt = recomputed.computedAt
        entry.artistsJSON = (try? JSONEncoder().encode(recomputed.artists)) ?? Data()
        entry.albumsJSON = (try? JSONEncoder().encode(recomputed.albums)) ?? Data()
        entry.tracksJSON = (try? JSONEncoder().encode(recomputed.tracks)) ?? Data()
        if cachedEntry == nil { context.insert(entry) }
        try context.save()

        return recomputed
    }

    private static func allScrobblesEmpty(_ context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<Scrobble>()
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).isEmpty) ?? true
    }

    /// Weighted random draw from a ranked list — stronger matches are more
    /// likely but not guaranteed, so each Overview load re-rolls a fresh
    /// pick. Weighted random pick, including a
    /// 0.0001 floor (avoids a zero-weight row ever being unpickable, and
    /// avoids a divide-by-zero when every row's weight is 0).
    static func weightedPick(_ rows: [ReverbRow]) -> ReverbRow? {
        let pool = Array(rows.prefix(10))
        guard !pool.isEmpty else { return nil }
        let total = pool.reduce(0.0) { $0 + max($1.weight, 0.0001) }
        var r = Double.random(in: 0..<total)
        for row in pool {
            r -= max(row.weight, 0.0001)
            if r <= 0 { return row }
        }
        return pool.last
    }

    /// Formats staleness in days.
    static func formatStaleness(days: Int) -> String {
        let whole = max(0, days)
        if whole <= 1 { return "yesterday" }
        if whole < 14 { return "\(whole) days ago" }
        if whole < 60 {
            let weeks = Int((Double(whole) / 7).rounded())
            return "\(weeks) \(weeks == 1 ? "week" : "weeks") ago"
        }
        if whole < 365 {
            let months = Int((Double(whole) / 30).rounded())
            return "\(months) \(months == 1 ? "month" : "months") ago"
        }
        let years = whole / 365
        let remMonths = Int((Double(whole - years * 365) / 30).rounded())
        if remMonths == 0 || years >= 3 { return "\(years) \(years == 1 ? "year" : "years") ago" }
        return "\(years)y \(remMonths)mo ago"
    }
}
