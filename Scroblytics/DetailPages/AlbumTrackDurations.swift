import Foundation
import SwiftData

/// Reads the saved lengths of just the tracks in one album's table: a person's own correction, else the cached lookup. It asks the
/// store for those few keys only, off the main thread, rather than loading every length the app knows.
@ModelActor
private actor AlbumTrackDurationReader {
    func seconds(forKeys keys: [String]) -> [String: Int] {
        guard !keys.isEmpty else { return [:] }
        var result: [String: Int] = [:]
        let cached = (try? modelContext.fetch(FetchDescriptor<TrackDurationCacheEntry>(predicate: #Predicate { keys.contains($0.cacheKey) }))) ?? []
        for entry in cached {
            if let seconds = entry.seconds { result[entry.cacheKey] = seconds }
        }
        // A correction wins over the lookup, the same precedence the duration engine uses everywhere.
        let corrected = (try? modelContext.fetch(FetchDescriptor<Track>(predicate: #Predicate { keys.contains($0.identityKey) }))) ?? []
        for track in corrected {
            if let seconds = track.durationOverrideSeconds { result[track.identityKey] = seconds }
        }
        return result
    }
}

enum AlbumTrackDurations {
    /// The key a row's length is saved under: the track's own artist and title when it was played (the names the app has lengths for),
    /// otherwise the tracklist's title under the album's artist.
    static func key(for row: AlbumTrackRow, albumArtist: String) -> String {
        DurationEngine.cacheKey(artist: row.entry?.artist ?? albumArtist, track: row.entry?.name ?? row.title)
    }

    /// Every row's key, by row id.
    static func keys(for rows: [AlbumTrackRow], albumArtist: String) -> [String: String] {
        Dictionary(rows.map { ($0.id, key(for: $0, albumArtist: albumArtist)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The text for a length column: m:ss, or a dash when the length isn't known.
    @MainActor
    static func text(seconds: Int?) -> String {
        guard let seconds else { return "—" }
        return DurationEngine.formatDuration(seconds)
    }

    static func seconds(forKeys keys: [String], container: ModelContainer) async -> [String: Int] {
        await AlbumTrackDurationReader(modelContainer: container).seconds(forKeys: keys)
    }
}
