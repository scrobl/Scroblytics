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
    /// The key a row's length is saved under: its track's own artist and title, as the row's page opens them.
    static func key(for row: AlbumTrackRow, albumArtist: String, playedNames: [String: PlayedName] = [:]) -> String {
        let who = AlbumTrackRows.identity(for: row, albumArtist: albumArtist, playedNames: playedNames)
        return DurationEngine.cacheKey(artist: who.artist, track: who.name)
    }

    /// Every row's key, by row id.
    static func keys(for rows: [AlbumTrackRow], albumArtist: String, playedNames: [String: PlayedName] = [:]) -> [String: String] {
        Dictionary(rows.map { ($0.id, key(for: $0, albumArtist: albumArtist, playedNames: playedNames)) }, uniquingKeysWith: { first, _ in first })
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
