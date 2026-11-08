import Foundation
import SwiftData

/// Reads the release dates a person has set on individual tracks, for just the tracks in one album's table. It asks the store for
/// those few keys only, off the main thread.
@ModelActor
private actor AlbumTrackReleaseDateReader {
    func overrides(forKeys keys: [String], album: String?) -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        let tracks = (try? modelContext.fetch(FetchDescriptor<Track>(predicate: #Predicate { keys.contains($0.identityKey) }))) ?? []
        var result: [String: String] = [:]
        for track in tracks {
            // A date set for the same song on another album is that version's, not this one's.
            if let date = track.releaseDateOverride(forAlbum: album), !date.isEmpty { result[track.identityKey] = date }
        }
        return result
    }
}

/// A track's own release date next to its album's, for the Album page's track table. A track normally shares its album's date; one
/// that was set separately (a greatest-hits song first released years earlier, a single out ahead of its album) shows its own date,
/// and the table gains a Released column only when some track's date differs from the album's.
enum AlbumTrackReleaseDates {
    /// The key a track's own date is saved under (the same one the track's page edits).
    static func key(for row: AlbumTrackRow, albumArtist: String, playedNames: [String: PlayedName] = [:]) -> String {
        let who = AlbumTrackRows.identity(for: row, albumArtist: albumArtist, playedNames: playedNames)
        return TextNormalization.lovedKey(artist: who.artist, track: who.name)
    }

    /// Every row's key, by row id.
    static func keys(for rows: [AlbumTrackRow], albumArtist: String, playedNames: [String: PlayedName] = [:]) -> [String: String] {
        Dictionary(rows.map { ($0.id, key(for: $0, albumArtist: albumArtist, playedNames: playedNames)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether a track's own date says something the album's doesn't. Dates are compared as far as both are known, so a track dated to a
    /// day inside an album known only by its year is the same date, and a year-only track date against a full album date differs only
    /// when the year does. An album with no date known has nothing to agree with.
    static func differs(_ track: String, from album: String?) -> Bool {
        guard let album else { return true }
        func parts(_ date: String) -> [Int] { date.split(separator: "-").map { Int($0) ?? -1 } }
        let (t, a) = (parts(track), parts(album))
        let shared = min(t.count, a.count)
        return Array(t.prefix(shared)) != Array(a.prefix(shared))
    }

    /// The date each row shows, by row id: the track's own date when it has one, otherwise the album's. Rows with neither are left out.
    static func dates(rowKeys: [String: String], overrides: [String: String], albumDate: String?) -> [String: String] {
        var result: [String: String] = [:]
        for (id, key) in rowKeys {
            if let own = overrides[key] { result[id] = own } else if let albumDate { result[id] = albumDate }
        }
        return result
    }

    /// The rows whose own date differs from the album's, by row id.
    static func differing(rowKeys: [String: String], overrides: [String: String], albumDate: String?) -> Set<String> {
        Set(rowKeys.compactMap { id, key in overrides[key].flatMap { differs($0, from: albumDate) ? id : nil } })
    }

    /// The text for a Released column: the day, month or year as far as it is known, with the month shortened to fit a table cell.
    static func text(_ raw: String) -> String {
        let parts = raw.split(separator: "-").map(String.init)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        func month(_ text: String) -> String? {
            guard let number = Int(text), (1...12).contains(number) else { return nil }
            return formatter.shortMonthSymbols[number - 1]
        }
        switch parts.count {
        case 1: return parts[0]
        case 2: return month(parts[1]).map { "\($0) \(parts[0])" } ?? raw
        case 3: return month(parts[1]).flatMap { name in Int(parts[2]).map { "\(name) \($0), \(parts[0])" } } ?? raw
        default: return raw
        }
    }

    static func overrides(forKeys keys: [String], album: String? = nil, container: ModelContainer) async -> [String: String] {
        await AlbumTrackReleaseDateReader(modelContainer: container).overrides(forKeys: keys, album: album)
    }
}
