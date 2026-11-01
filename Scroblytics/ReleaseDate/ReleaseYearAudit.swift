import Foundation
import SwiftData

/// The services that give an album its release date, as recorded when a date is detected.
enum ReleaseDateSource: String, Sendable, Codable {
    case musicBrainz, deezer

    var label: String {
        switch self {
        case .musicBrainz: "MusicBrainz"
        case .deezer: "Deezer"
        }
    }
}

/// Where a Scroblytics album date came from, as far as that is known.
enum AlbumDateOrigin: Equatable, Sendable {
    /// A date you set yourself.
    case manual
    /// Recorded when the date was detected.
    case musicBrainz, deezer
    /// Detected before sources were recorded, and known only to the year or month: only MusicBrainz gives those (Deezer always gives a day).
    case musicBrainzInferred
    /// Detected before sources were recorded, with a full day: MusicBrainz or Deezer.
    case detectedUnrecorded
    /// No date at all.
    case none

    var label: String {
        switch self {
        case .manual: "Manual"
        case .musicBrainz: "MusicBrainz"
        case .deezer: "Deezer"
        case .musicBrainzInferred: "MusicBrainz (inferred)"
        case .detectedUnrecorded: "Detected (source not recorded)"
        case .none: "No date"
        }
    }

    /// `recorded` is the album's stored `releaseDateSource`.
    static func of(override: String?, detected: String?, recorded: String?) -> AlbumDateOrigin {
        if let override, !override.isEmpty { return .manual }
        guard let detected, !detected.isEmpty else { return .none }
        switch recorded.flatMap(ReleaseDateSource.init(rawValue:)) {
        case .musicBrainz?: return .musicBrainz
        case .deezer?: return .deezer
        case nil: return detected.split(separator: "-").count < 3 ? .musicBrainzInferred : .detectedUnrecorded
        }
    }
}

/// One album's date in Scroblytics: your override, else the detected one.
struct AuditAlbum: Sendable, Hashable {
    let title: String
    let artist: String
    let artistKey: String
    let normalizedTitle: String
    /// "YYYY", "YYYY-MM" or "YYYY-MM-DD".
    let date: String?
    let origin: AlbumDateOrigin

    var year: Int? { date.flatMap(ReleaseDateEngine.year(of:)) }
}

/// One track of the Apple Music library with the year Music holds for it (nil when Music has none).
struct AppleMusicTrackYear: Sendable, Hashable {
    let name: String
    let artist: String
    let albumArtist: String
    let album: String
    let year: Int?
}

/// Compares the release years Scroblytics holds with the ones in the Apple Music library, album by album and track by track. Only the
/// year is compared. Pure: it works on what it is given and never reads Music, the store or the network.
///
/// Music has no year of its own for an album, so an album's Music year is the most common year among its tracks (the earliest of a tie).
enum ReleaseYearAudit {
    enum Category: String, Sendable, CaseIterable {
        case same
        case offByOne
        case differs
        /// Scroblytics has no date for the album.
        case scroblyticsUndated
        /// No track of the album has a year in Music.
        case musicUndated
    }

    enum Match: String, Sendable {
        case albumArtist, trackArtist, titleOnly
    }

    /// A track whose year in Music differs from the year Scroblytics shows for it: its own date if you set one, else its album's.
    struct TrackDifference: Sendable, Hashable {
        let name: String
        let artist: String
        let musicYear: Int
        let scroblyticsYear: Int
        /// The Scroblytics year is a date set on this track (rather than its album's).
        let ownDate: Bool
    }

    struct AlbumRow: Identifiable, Sendable {
        var id: String { "\(scroblytics.artistKey)\u{0}\(scroblytics.normalizedTitle)" }
        let musicArtist: String
        let musicAlbum: String
        let trackCount: Int
        let scroblytics: AuditAlbum
        /// The most common year among the album's tracks in Music (the earliest of a tie).
        let musicYear: Int?
        let musicEarliest: Int?
        let musicLatest: Int?
        let musicDistinctYears: Int
        let category: Category
        let matchedBy: Match
        let trackDifferences: [TrackDifference]

        /// The album's tracks do not share one year in Music (a compilation, a greatest-hits set).
        var musicVaries: Bool { musicDistinctYears > 1 }
        /// Years from Scroblytics to Music (positive: Scroblytics is later), when both are known.
        var gap: Int? {
            guard let a = scroblytics.year, let m = musicYear else { return nil }
            return a - m
        }
    }

    struct Report: Sendable {
        let rows: [AlbumRow]
        /// Albums in Music that matched no Scroblytics album (never scrobbled, or named differently).
        let unmatchedMusicAlbums: Int
        let musicAlbums: Int
        let musicTracks: Int
        /// Tracks in Music with no year.
        let musicTracksWithoutYear: Int

        func count(_ category: Category) -> Int { rows.filter { $0.category == category }.count }
        var matched: Int { rows.count }
        var disagreements: Int { rows.filter { $0.category == .offByOne || $0.category == .differs }.count }
        var albumsWithTrackDifferences: Int { rows.filter { !$0.trackDifferences.isEmpty }.count }
        var trackDifferences: Int { rows.reduce(0) { $0 + $1.trackDifferences.count } }
    }

    /// The category for a Scroblytics year against a Music year.
    static func category(scroblytics: Int?, music: Int?) -> Category {
        guard let scroblytics else { return .scroblyticsUndated }
        guard let music else { return .musicUndated }
        if scroblytics == music { return .same }
        return abs(scroblytics - music) == 1 ? .offByOne : .differs
    }

    /// The most common year; the earliest of a tie; nil for none.
    static func modalYear(_ years: [Int]) -> Int? {
        guard !years.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for year in years { counts[year, default: 0] += 1 }
        let top = counts.values.max() ?? 0
        return counts.filter { $0.value == top }.keys.min()
    }

    private struct Key: Hashable {
        let artist: String
        let title: String
    }

    /// `trackOverrides` are the dates set on individual tracks, by `TextNormalization.lovedKey`.
    static func compare(music: [AppleMusicTrackYear], albums: [AuditAlbum], trackOverrides: [String: String] = [:]) -> Report {
        var byKey: [Key: AuditAlbum] = [:]
        var byTitle: [String: [AuditAlbum]] = [:]
        for album in albums {
            byKey[Key(artist: album.artistKey, title: album.normalizedTitle)] = album
            byTitle[album.normalizedTitle, default: []].append(album)
        }

        // Music's albums, in the order they first appear.
        var order: [Key] = []
        var groups: [Key: [AppleMusicTrackYear]] = [:]
        for track in music where !track.album.isEmpty {
            let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            let key = Key(artist: TextNormalization.artistIdentityKey(artist), title: TextNormalization.normalizeAlbumName(track.album))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }

        var rows: [AlbumRow] = []
        var unmatched = 0
        for key in order {
            let tracks = groups[key] ?? []
            var found = byKey[key].map { ($0, Match.albumArtist) }
            if found == nil {
                // The album artist may be "Various Artists" or spelled otherwise; a track's own artist is how it was scrobbled.
                for track in tracks {
                    let k = Key(artist: TextNormalization.artistIdentityKey(track.artist), title: key.title)
                    if let album = byKey[k] { found = (album, .trackArtist); break }
                }
            }
            if found == nil, let only = byTitle[key.title], only.count == 1 { found = (only[0], .titleOnly) }
            guard let (album, how) = found else { unmatched += 1; continue }

            let years = tracks.compactMap(\.year)
            let modal = modalYear(years)
            let albumYear = album.year
            var differences: [TrackDifference] = []
            for track in tracks {
                guard let musicYear = track.year else { continue }
                let own = trackOverrides[TextNormalization.lovedKey(artist: track.artist, track: track.name)].flatMap(ReleaseDateEngine.year(of:))
                guard let shown = own ?? albumYear, shown != musicYear else { continue }
                differences.append(TrackDifference(name: track.name, artist: track.artist, musicYear: musicYear, scroblyticsYear: shown, ownDate: own != nil))
            }
            let first = tracks[0]
            rows.append(AlbumRow(
                musicArtist: first.albumArtist.isEmpty ? first.artist : first.albumArtist, musicAlbum: first.album, trackCount: tracks.count,
                scroblytics: album, musicYear: modal, musicEarliest: years.min(), musicLatest: years.max(), musicDistinctYears: Set(years).count,
                category: category(scroblytics: albumYear, music: modal), matchedBy: how, trackDifferences: differences
            ))
        }
        return Report(
            rows: rows, unmatchedMusicAlbums: unmatched, musicAlbums: order.count, musicTracks: music.count,
            musicTracksWithoutYear: music.filter { $0.year == nil }.count
        )
    }
}

/// Reads what the comparison needs from the Scroblytics store: every album's date with its origin, and the dates set on tracks.
@ModelActor
actor ReleaseYearAuditStoreReader {
    func load() -> (albums: [AuditAlbum], trackOverrides: [String: String]) {
        var albums: [AuditAlbum] = []
        for album in (try? modelContext.fetch(FetchDescriptor<Album>())) ?? [] {
            guard let artist = album.artist?.name else { continue }
            let date = album.releaseDateOverride.flatMap { $0.isEmpty ? nil : $0 } ?? album.releaseDateDetected
            albums.append(AuditAlbum(
                title: album.title, artist: artist, artistKey: TextNormalization.artistIdentityKey(artist), normalizedTitle: album.normalizedTitle,
                date: date, origin: AlbumDateOrigin.of(override: album.releaseDateOverride, detected: album.releaseDateDetected, recorded: album.releaseDateSource)
            ))
        }
        var overrides: [String: String] = [:]
        let tracks = (try? modelContext.fetch(FetchDescriptor<Track>(predicate: #Predicate { $0.releaseDateOverride != nil }))) ?? []
        for track in tracks {
            if let date = track.releaseDateOverride, !date.isEmpty { overrides[track.identityKey] = date }
        }
        return (albums, overrides)
    }
}
