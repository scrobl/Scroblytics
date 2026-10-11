import Foundation
import Observation
import SwiftData

struct FlaggedTrackSnapshot: Sendable {
    let artist: String
    let track: String
    let album: String?
    let flaggedAt: Date
}

struct FlaggedTrackRow: Identifiable, Sendable {
    let id: String
    let artist: String
    let track: String
    let album: String?
    let flaggedAt: Date
    let playCount: Int
    let lastPlayed: Date?
    let imageURL: String?
}

enum FlaggedTracksSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case recentlyFlagged, mostPlayed, recentlyPlayed, artist, track
    var id: Self { self }
    var label: String {
        switch self {
        case .recentlyFlagged: "Recently Flagged"
        case .mostPlayed: "Most Played"
        case .recentlyPlayed: "Recently Played"
        case .artist: "Artist"
        case .track: "Track"
        }
    }
}

enum FlaggedTrackIdentity {
    static func key(artist: String, track: String, album: String?) -> String {
        [artist, track, album ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\u{0}")
    }
}

enum FlaggedTracksEngine {
    static func rows(flags: [FlaggedTrackSnapshot], scrobbles: [ScrobbleSnapshot]) -> [FlaggedTrackRow] {
        flags.map { flag in
            let artist = normalized(flag.artist)
            let track = normalized(flag.track)
            let album = flag.album.map(normalized)
            let matches = scrobbles.filter {
                normalized($0.artistName) == artist
                    && normalized($0.trackName) == track
                    && (album == nil || normalized($0.albumName) == album)
            }
            let newest = matches.max { $0.playedAt < $1.playedAt }
            return FlaggedTrackRow(
                id: FlaggedTrackIdentity.key(artist: flag.artist, track: flag.track, album: flag.album),
                artist: flag.artist,
                track: flag.track,
                album: flag.album ?? mostPlayedAlbum(in: matches),
                flaggedAt: flag.flaggedAt,
                playCount: matches.count,
                lastPlayed: newest?.playedAt,
                imageURL: newest?.imageURL
            )
        }
    }

    static func sorted(_ rows: [FlaggedTrackRow], by sort: FlaggedTracksSort) -> [FlaggedTrackRow] {
        rows.sorted { lhs, rhs in
            switch sort {
            case .recentlyFlagged: lhs.flaggedAt > rhs.flaggedAt
            case .mostPlayed: lhs.playCount != rhs.playCount ? lhs.playCount > rhs.playCount : lhs.flaggedAt > rhs.flaggedAt
            case .recentlyPlayed: (lhs.lastPlayed ?? .distantPast) > (rhs.lastPlayed ?? .distantPast)
            case .artist: lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
            case .track: lhs.track.localizedCaseInsensitiveCompare(rhs.track) == .orderedAscending
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func mostPlayedAlbum(in scrobbles: [ScrobbleSnapshot]) -> String? {
        Dictionary(grouping: scrobbles.filter { !$0.albumName.isEmpty }, by: \.albumName)
            .max { $0.value.count < $1.value.count }?.key
    }
}

@ModelActor
private actor FlaggedTracksDataReader {
    func fetch() throws -> [FlaggedTrackSnapshot] {
        try modelContext.fetch(FetchDescriptor<FlaggedTrack>()).map {
            FlaggedTrackSnapshot(artist: $0.artist, track: $0.track, album: $0.album, flaggedAt: $0.flaggedAt)
        }
    }
}

@MainActor
@Observable
final class FlaggedTracksStore {
    private(set) var snapshots: [FlaggedTrackSnapshot] = []
    private(set) var revision = 0
    private(set) var hasLoaded = false

    func load(container: ModelContainer, force: Bool = false) async {
        guard force || !hasLoaded else { return }
        guard let values = try? await offMain({ try await FlaggedTracksDataReader(modelContainer: container).fetch() }) else { return }
        snapshots = values
        hasLoaded = true
    }

    func isFlagged(artist: String, track: String, album: String?) -> Bool {
        let key = FlaggedTrackIdentity.key(artist: artist, track: track, album: album)
        return snapshots.contains { FlaggedTrackIdentity.key(artist: $0.artist, track: $0.track, album: $0.album) == key }
    }

    func isFlagged(artist: String, track: String) -> Bool {
        let artistKey = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trackKey = track.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return snapshots.contains {
            $0.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == artistKey
                && $0.track.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trackKey
        }
    }

    func toggle(context: ModelContext, artist: String, track: String, album: String?) throws {
        let key = FlaggedTrackIdentity.key(artist: artist, track: track, album: album)
        let matches = try context.fetch(FetchDescriptor<FlaggedTrack>()).filter {
            FlaggedTrackIdentity.key(artist: $0.artist, track: $0.track, album: $0.album) == key
        }
        if matches.isEmpty {
            let flag = FlaggedTrackSnapshot(artist: artist, track: track, album: album, flaggedAt: Date())
            context.insert(FlaggedTrack(artist: artist, track: track, album: album, flaggedAt: flag.flaggedAt))
            snapshots.append(flag)
        } else {
            matches.forEach(context.delete)
            snapshots.removeAll { FlaggedTrackIdentity.key(artist: $0.artist, track: $0.track, album: $0.album) == key }
        }
        try context.save()
        revision += 1
    }

    func remove(context: ModelContext, id: String) throws {
        let matches = try context.fetch(FetchDescriptor<FlaggedTrack>()).filter {
            FlaggedTrackIdentity.key(artist: $0.artist, track: $0.track, album: $0.album) == id
        }
        matches.forEach(context.delete)
        try context.save()
        snapshots.removeAll { FlaggedTrackIdentity.key(artist: $0.artist, track: $0.track, album: $0.album) == id }
        revision += 1
    }

    @discardableResult
    func flagAll(
        context: ModelContext,
        tracks: [(artist: String, track: String, album: String?)]
    ) throws -> Int {
        var existingKeys = Set(try context.fetch(FetchDescriptor<FlaggedTrack>()).map {
            FlaggedTrackIdentity.key(artist: $0.artist, track: $0.track, album: $0.album)
        })
        var added: [FlaggedTrackSnapshot] = []
        let flaggedAt = Date()

        for track in tracks {
            let key = FlaggedTrackIdentity.key(artist: track.artist, track: track.track, album: track.album)
            guard existingKeys.insert(key).inserted else { continue }
            context.insert(FlaggedTrack(
                artist: track.artist,
                track: track.track,
                album: track.album,
                flaggedAt: flaggedAt
            ))
            added.append(FlaggedTrackSnapshot(
                artist: track.artist,
                track: track.track,
                album: track.album,
                flaggedAt: flaggedAt
            ))
        }

        guard !added.isEmpty else { return 0 }
        try context.save()
        snapshots.append(contentsOf: added)
        revision += 1
        return added.count
    }

    func removeAll(context: ModelContext) throws {
        try context.fetch(FetchDescriptor<FlaggedTrack>()).forEach(context.delete)
        try context.save()
        snapshots = []
        revision += 1
    }
}
