import Foundation
import SwiftData
import Observation

/// A milestone crossed by a sync, surfaced as a post-sync banner on Overview.
struct NewMilestone: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case total, artist, album, track }
    let kind: Kind
    let name: String
    let artist: String?
    let album: String?
    let milestone: Int
}

/// An album that completed a new turnover cycle during a sync.
struct NewAlbumTurnover: Codable, Hashable, Sendable {
    let artist: String
    let album: String
    let imageURL: String?
    let cyclesCompleted: Int
    let rateDays: Double?
}

/// Diffs milestone state before vs. after a sync,
/// and finds albums whose latest turnover cycle completed since the previous
/// sync. Both are skipped on the very first sync (no baseline to diff).
enum SyncEventsEngine {
    /// Per-entity scrobble counts, used to diff milestone state before/after a sync. Every key starts with the artist's
    /// identity key (trimmed, lowercased), not its display spelling: the library-wide most-played spelling can flip when a
    /// sync adds plays, and a spelling-keyed diff would then report the merged total as a fresh milestone.
    struct EntityCounts: Sendable {
        struct Named: Sendable { var count: Int; let artist: String; let name: String; var album: String? }
        var total = 0
        var artists: [String: Named] = [:]
        var albums: [String: Named] = [:]
        var tracks: [String: Named] = [:]
        /// Album-tagged scrobbles per artist identity key — a count change marks the
        /// artist as "touched" for turnover detection.
        var albumTaggedByArtist: [String: Int] = [:]
    }

    private static let base = [100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000]
    /// Cap on how many achievements one sync adds to the banner.
    private static let newMilestoneCap = 12
    /// Cap on how many newly-completed cycles one sync adds to the banner.
    private static let newTurnoverCap = 8

    static func countEntities(_ scrobbles: [ScrobbleSnapshot]) -> EntityCounts {
        var c = EntityCounts()
        c.total = scrobbles.count
        for s in scrobbles {
            let identity = TextNormalization.artistIdentityKey(s.artistName)
            c.artists[identity, default: .init(count: 0, artist: s.artistName, name: s.artistName)].count += 1
            if !s.albumName.isEmpty {
                c.albumTaggedByArtist[identity, default: 0] += 1
                let key = "\(identity)\u{0}\(s.albumName)"
                c.albums[key, default: .init(count: 0, artist: s.artistName, name: s.albumName)].count += 1
            }
            let tkey = "\(identity)\u{0}\(s.trackName)"
            var track = c.tracks[tkey] ?? .init(count: 0, artist: s.artistName, name: s.trackName, album: s.albumName.isEmpty ? nil : s.albumName)
            track.count += 1
            if track.album == nil, !s.albumName.isEmpty { track.album = s.albumName }
            c.tracks[tkey] = track
        }
        return c
    }

    /// The highest milestone threshold `count` has crossed, or nil if none.
    private static func achievedMilestone(for count: Int) -> Int? {
        var result: Int?
        for t in base {
            if count >= t { result = t } else { break }
        }
        if count > base[base.count - 1] { result = count / 100_000 * 100_000 }
        return result
    }

    static func findNewMilestones(before: EntityCounts, after: EntityCounts) -> [NewMilestone] {
        var result: [NewMilestone] = []
        func changed(_ beforeCount: Int, _ afterCount: Int) -> Int? {
            guard let afterM = achievedMilestone(for: afterCount), afterM != achievedMilestone(for: beforeCount) else { return nil }
            return afterM
        }
        if let m = changed(before.total, after.total) {
            result.append(NewMilestone(kind: .total, name: "Total scrobbles", artist: nil, album: nil, milestone: m))
        }
        for (key, entry) in after.artists {
            if let m = changed(before.artists[key]?.count ?? 0, entry.count) {
                result.append(NewMilestone(kind: .artist, name: entry.name, artist: nil, album: nil, milestone: m))
            }
        }
        for (key, entry) in after.albums {
            if let m = changed(before.albums[key]?.count ?? 0, entry.count) {
                result.append(NewMilestone(kind: .album, name: entry.name, artist: entry.artist, album: nil, milestone: m))
            }
        }
        for (key, entry) in after.tracks {
            if let m = changed(before.tracks[key]?.count ?? 0, entry.count) {
                result.append(NewMilestone(kind: .track, name: entry.name, artist: entry.artist, album: entry.album, milestone: m))
            }
        }
        // Total first, then biggest milestone first; ties broken alphabetically.
        return Array(result.sorted { a, b in
            if (a.kind == .total) != (b.kind == .total) { return a.kind == .total }
            if a.milestone != b.milestone { return a.milestone > b.milestone }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }.prefix(newMilestoneCap))
    }

    /// Identity keys of artists whose album-tagged scrobble count changed: those that received newly added
    /// album-tagged scrobbles.
    static func touchedArtists(before: EntityCounts, after: EntityCounts) -> Set<String> {
        Set(after.albumTaggedByArtist.compactMap { artist, count in
            count != (before.albumTaggedByArtist[artist] ?? 0) ? artist : nil
        })
    }

    /// Albums that completed a new turnover cycle (the Album Turnover tool's
    /// canonical logic) since `since`, scoped to `touchedArtists` so an
    /// incremental sync stays fast despite needing tracklist lookups.
    /// Compilations excluded, matching the tool's default.
    @MainActor
    static func findNewAlbumTurnovers(
        context: ModelContext, client: LastfmAPIClient, scrobbles: [ScrobbleSnapshot],
        touchedArtists: Set<String>, since: Date
    ) async throws -> [NewAlbumTurnover] {
        let byArtist = Dictionary(
            grouping: scrobbles.filter { !$0.albumName.isEmpty && touchedArtists.contains(TextNormalization.artistIdentityKey($0.artistName)) },
            by: \.artistName
        )
        let groups = await offMain {
            byArtist.values.flatMap { AlbumTurnoverEngine.buildAlbumGroups(from: $0) }
                .filter { !TextNormalization.isCompilationArtist($0.artist) }
        }
        var result: [NewAlbumTurnover] = []
        for turnover in try await AlbumTurnoverEngine.resolveTurnovers(for: groups, context: context, client: client) {
            if turnover.applicable, let last = turnover.lastTurnoverDate, last > since {
                result.append(NewAlbumTurnover(
                    artist: turnover.artist, album: turnover.album, imageURL: turnover.imageURL,
                    cyclesCompleted: turnover.cyclesCompleted, rateDays: turnover.rateDays
                ))
            }
        }
        return Array(result.sorted { a, b in
            a.artist != b.artist
                ? a.artist.localizedCompare(b.artist) == .orderedAscending
                : a.album.localizedCompare(b.album) == .orderedAscending
        }.prefix(newTurnoverCap))
    }
}

/// Milestone/turnover banners must survive an app restart and only clear on an
/// explicit dismiss — each sync's events are just that sync's delta, so they
/// accumulate here rather than overwriting (otherwise an auto-sync that finds
/// one, followed by quitting before visiting Overview, silently drops it).
@MainActor
@Observable
final class PendingSyncEventsStore {
    private static let milestonesKey = "pendingMilestones"
    private static let turnoversKey = "pendingTurnovers"

    private(set) var milestones: [NewMilestone]
    private(set) var turnovers: [NewAlbumTurnover]

    init() {
        milestones = Self.load(Self.milestonesKey)
        turnovers = Self.load(Self.turnoversKey)
    }

    func append(milestones new: [NewMilestone], turnovers newTurnovers: [NewAlbumTurnover]) {
        if !new.isEmpty {
            milestones += new
            Self.save(milestones, key: Self.milestonesKey)
        }
        if !newTurnovers.isEmpty {
            turnovers += newTurnovers
            Self.save(turnovers, key: Self.turnoversKey)
        }
    }

    func dismissMilestones() {
        milestones = []
        Self.save(milestones, key: Self.milestonesKey)
    }

    func dismissTurnovers() {
        turnovers = []
        Self.save(turnovers, key: Self.turnoversKey)
    }

    private static func load<T: Decodable>(_ key: String) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private static func save<T: Encodable>(_ list: [T], key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }
}
