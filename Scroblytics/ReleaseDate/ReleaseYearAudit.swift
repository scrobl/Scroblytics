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
    /// "YYYY", "YYYY-MM" or "YYYY-MM-DD": your own date if you set one, else the detected one.
    let date: String?
    let origin: AlbumDateOrigin
    /// The detected date, even when your own shows instead (the date editor shows it).
    var detected: String? = nil

    var year: Int? { date.flatMap(ReleaseDateEngine.year(of:)) }
    /// The date you set yourself, if any.
    var override: String? { origin == .manual ? date : nil }
}

/// One track of the Apple Music library with the year Music holds for it (nil when Music has none).
struct AppleMusicTrackYear: Sendable, Hashable {
    let name: String
    let artist: String
    let albumArtist: String
    let album: String
    let year: Int?
    /// Music's `persistent ID` for the track, which is how a change finds it again ("" when the read didn't include it).
    var persistentID: String = ""
}

/// Compares the release years Scroblytics holds with the ones in the Apple Music library, album by album and track by track. Only the
/// year is compared. Pure: it works on what it is given and never reads Music, the store or the network.
///
/// Music has no year of its own for an album, so an album's Music year is the most common year among its tracks. When several years tie,
/// the album's own year agrees if it is any of them; otherwise the earliest is shown.
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

    /// One of an album's tracks in Music, with the year Scroblytics shows for it when that is a date set on the track itself.
    struct MusicTrackRef: Sendable, Hashable {
        let persistentID: String
        let name: String
        let artist: String
        let musicYear: Int?
        /// A date you set on the track (its year); nil when it just shows its album's.
        let ownYear: Int?
        /// Scroblytics has a row for the track (you have played it), so it has a date that can be set.
        var inScroblytics = true
    }

    /// The tracks of an album that would differ from Music once the album itself shows `albumYear`: those that show their album's date and
    /// whose year in Music is another. A track you set a date on, and one you have never played, are not among them.
    static func trackChanges(for row: AlbumRow, albumYear: Int?) -> [TrackDifference] {
        guard let target = albumYear ?? row.scroblytics.year else { return [] }
        return row.musicTracks.compactMap { track in
            guard track.inScroblytics, track.ownYear == nil, let year = track.musicYear, year != target else { return nil }
            return TrackDifference(name: track.name, artist: track.artist, musicYear: year, scroblyticsYear: target, ownDate: false)
        }
    }

    /// A change to the year Music holds for one track.
    struct MusicYearUpdate: Sendable, Hashable {
        let persistentID: String
        let name: String
        let artist: String
        let album: String
        /// The year Music has now (nil: none), which must still be what it is when the change is made.
        let from: Int?
        let to: Int
    }

    /// The Music years to change so they follow Scroblytics, for one album: each track gets the year Scroblytics shows for it (its own
    /// date, else the album's `albumYear`). An album whose tracks span several years in Music may be a compilation, whose years are real
    /// data: unless `includeVaried` (you chose that one album yourself, and are shown what it will do), only the tracks you set a date on
    /// are brought into line there, never the rest to one album year.
    static func musicUpdates(for row: AlbumRow, albumYear: Int?, includeVaried: Bool = false) -> [MusicYearUpdate] {
        let target = albumYear ?? row.scroblytics.year
        var updates: [MusicYearUpdate] = []
        for track in row.musicTracks where !track.persistentID.isEmpty {
            let wanted: Int?
            if row.musicVaries && !includeVaried { wanted = track.ownYear } else { wanted = track.ownYear ?? target }
            guard let wanted, wanted != track.musicYear else { continue }
            updates.append(MusicYearUpdate(persistentID: track.persistentID, name: track.name, artist: track.artist, album: row.musicAlbum, from: track.musicYear, to: wanted))
        }
        return updates
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
        var id: String { albumKey }
        var albumKey: String { ReleaseYearAudit.albumKey(artistKey: scroblytics.artistKey, normalizedTitle: scroblytics.normalizedTitle) }
        let musicArtist: String
        let musicAlbum: String
        let trackCount: Int
        let scroblytics: AuditAlbum
        /// The most common year among the album's tracks in Music; with a tie, the album's own year if it is one of the tied years, else the earliest.
        let musicYear: Int?
        let musicEarliest: Int?
        let musicLatest: Int?
        let musicDistinctYears: Int
        let category: Category
        let matchedBy: Match
        let trackDifferences: [TrackDifference]
        /// Every track of the album in Music (see `musicUpdates`).
        var musicTracks: [MusicTrackRef] = []

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
        /// Albums that disagree by this much (1–2 years, or 3 and more).
        func count(band: GapBand) -> Int { rows.filter { ReleaseYearAudit.band(forGap: $0.gap) == band }.count }
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
    static func modalYear(_ years: [Int]) -> Int? { modalYears(years).min() }

    /// Every year that is the most common (more than one when the tracks are spread evenly over several years); empty for none.
    static func modalYears(_ years: [Int]) -> Set<Int> {
        var counts: [Int: Int] = [:]
        for year in years { counts[year, default: 0] += 1 }
        let top = counts.values.max() ?? 0
        return Set(counts.filter { $0.value == top }.keys)
    }

    /// The album's identity in a decision: its artist and normalized title, as Scroblytics knows them.
    static func albumKey(artistKey: String, normalizedTitle: String) -> String { "\(artistKey)\u{1F}\(normalizedTitle)" }

    /// A decision about an album, as the list needs it.
    struct Decision: Sendable, Hashable {
        enum Verdict: String, Sendable { case keepMine, usedApple }
        let albumKey: String
        let verdict: Verdict
        let scroblyticsYear: Int
        let musicYear: Int
        /// Which tracks differed when it was decided (`tracksSignature`); empty when none did.
        var tracksSignature: String = ""
    }

    /// A track's own date that was set from Music's year, and what it was, so it can be put back.
    struct TrackChange: Codable, Sendable, Equatable {
        let key: String
        let previous: String?
        let applied: String
    }

    /// A short fingerprint of which of an album's tracks differ from Music and how, so a decision about them holds only while that stays true.
    /// Deterministic (FNV-1a), unlike `hashValue`, which changes with every launch. Empty when no track differs.
    static func tracksSignature(_ differences: [TrackDifference]) -> String {
        guard !differences.isEmpty else { return "" }
        let text = differences.map { "\($0.artist.lowercased())|\($0.name.lowercased())|\($0.musicYear)|\($0.scroblyticsYear)" }.sorted().joined(separator: "\n")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    /// Whether you have already settled this album: "keep Scroblytics" holds only while both years are still the ones it was made against, so
    /// a change on either side asks again.
    static func isDecided(_ row: AlbumRow, decisions: [String: Decision]) -> Bool {
        guard let decision = decisions[row.albumKey], decision.verdict == .keepMine else { return false }
        return decision.scroblyticsYear == row.scroblytics.year && decision.musicYear == row.musicYear
            && decision.tracksSignature == tracksSignature(row.trackDifferences)
    }

    /// The compilations that need a look: Music's tracks have several years and some of them differ from what Scroblytics shows, whether or
    /// not the album's own year agrees. The albums not yet settled.
    static func compilations(_ rows: [AlbumRow], decisions: [String: Decision]) -> [AlbumRow] {
        rows.filter { $0.musicVaries && !$0.trackDifferences.isEmpty && !isDecided($0, decisions: decisions) }
    }

    /// How far apart the two years are, for the filters: a year or two (often a release-date edge or a reissue), or three and more.
    enum GapBand: Sendable { case close, far }

    static func band(forGap gap: Int?) -> GapBand? {
        guard let gap, gap != 0 else { return nil }
        return abs(gap) <= 2 ? .close : .far
    }

    /// The raw values of `close` and `far` are the names the filters had before they were split at two years, so a saved choice still reads.
    enum Filter: String, Codable, CaseIterable, Sendable {
        case all
        case close = "offByOne"
        case far = "differs"
        case yourDates, musicVaries
    }

    /// What the list is ordered by.
    enum SortKey: String, Codable, CaseIterable, Sendable, Identifiable {
        case difference, album, artist, scroblyticsYear, musicYear, source, tracksDiffering

        var id: String { rawValue }

        var label: String {
            switch self {
            case .difference: "Difference"
            case .album: "Album"
            case .artist: "Artist"
            case .scroblyticsYear: "Scroblytics year"
            case .musicYear: "Apple Music year"
            case .source: "Source of the date"
            case .tracksDiffering: "Tracks that differ"
            }
        }

        /// The direction each starts in: names A to Z, the others biggest or newest first.
        var startsAscending: Bool {
            switch self {
            case .album, .artist, .source: true
            case .difference, .scroblyticsYear, .musicYear, .tracksDiffering: false
            }
        }

        func directionLabel(ascending: Bool) -> String {
            switch self {
            case .difference: ascending ? "Smallest first" : "Largest first"
            case .album, .artist, .source: ascending ? "A to Z" : "Z to A"
            case .scroblyticsYear, .musicYear: ascending ? "Oldest first" : "Newest first"
            case .tracksDiffering: ascending ? "Fewest first" : "Most first"
            }
        }
    }

    /// The rows in the chosen order (`ascending` nil: that sort's own starting direction). Rows with nothing to order by (no year) come last
    /// whichever way the list runs; ties are broken by artist, then album, always A to Z, so the order never shuffles.
    static func sorted(_ rows: [AlbumRow], by key: SortKey, ascending: Bool? = nil) -> [AlbumRow] {
        let up = ascending ?? key.startsAscending
        func byName(_ a: AlbumRow, _ b: AlbumRow) -> Bool {
            let artists = a.scroblytics.artist.localizedStandardCompare(b.scroblytics.artist)
            if artists != .orderedSame { return artists == .orderedAscending }
            return a.scroblytics.title.localizedStandardCompare(b.scroblytics.title) == .orderedAscending
        }
        func ordered<V: Comparable>(_ value: @escaping (AlbumRow) -> V?) -> [AlbumRow] {
            rows.sorted { a, b in
                switch (value(a), value(b)) {
                case (let x?, let y?): return x != y ? (up ? x < y : x > y) : byName(a, b)
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return byName(a, b)
                }
            }
        }
        switch key {
        case .difference:
            // The bigger the gap the larger; an album whose own year agrees (a compilation) is ordered by how many tracks differ.
            return ordered { row in
                (row.gap.map { abs($0) } ?? 0) * 1000 + min(row.trackDifferences.count, 999)
            }
        case .album:
            return rows.sorted { a, b in
                let titles = a.scroblytics.title.localizedStandardCompare(b.scroblytics.title)
                return titles == .orderedSame ? byName(a, b) : ((titles == .orderedAscending) == up)
            }
        case .artist:
            return rows.sorted { a, b in
                let artists = a.scroblytics.artist.localizedStandardCompare(b.scroblytics.artist)
                return artists == .orderedSame ? byName(a, b) : ((artists == .orderedAscending) == up)
            }
        case .scroblyticsYear: return ordered { $0.scroblytics.year }
        case .musicYear: return ordered { $0.musicYear }
        case .source: return ordered { $0.scroblytics.origin.label }
        case .tracksDiffering: return ordered { $0.trackDifferences.count }
        }
    }

    /// The albums a filter lists: those that disagree and that you haven't settled.
    static func listed(_ rows: [AlbumRow], filter: Filter, decisions: [String: Decision]) -> [AlbumRow] {
        if filter == .musicVaries { return compilations(rows, decisions: decisions) }
        let open = rows.filter { ($0.category == .offByOne || $0.category == .differs) && !isDecided($0, decisions: decisions) }
        switch filter {
        case .all: return open
        case .close: return open.filter { band(forGap: $0.gap) == .close }
        case .far: return open.filter { band(forGap: $0.gap) == .far }
        case .yourDates: return open.filter { $0.scroblytics.origin == .manual }
        case .musicVaries: return compilations(rows, decisions: decisions)
        }
    }

    private struct Key: Hashable {
        let artist: String
        let title: String
    }

    /// How a track is found when Music and Scroblytics spell its title differently: its artist and normalized title.
    static func trackIndexKey(artist: String, title: String) -> String {
        trackIndexKey(artist: artist, normalizedTitle: TextNormalization.normalizeTrackTitle(title))
    }

    /// The same key from a title already normalized: what a stored track holds, which is what the audit's changes look a track up by.
    static func trackIndexKey(artist: String, normalizedTitle: String) -> String {
        "\(TextNormalization.artistIdentityKey(artist))\u{1F}\(normalizedTitle)"
    }

    /// The tracks Scroblytics has a row for (every track you have played), by saved key and by `trackIndexKey`. A track of Music's that is
    /// in neither was never played, so there is nothing of it here to change and it is left out of the track comparison.
    struct KnownTracks: Sendable {
        var identityKeys: Set<String> = []
        var indexKeys: Set<String> = []
    }

    /// `trackOverrides` are the dates set on individual tracks, by `TextNormalization.lovedKey`; `trackOverrideIndex` the same dates by
    /// `trackIndexKey`, for a track whose spelling differs between Music and the scrobbles. `knownTracks` nil: every track counts.
    static func compare(
        music: [AppleMusicTrackYear], albums: [AuditAlbum], trackOverrides: [String: String] = [:], trackOverrideIndex: [String: String] = [:],
        knownTracks: KnownTracks? = nil
    ) -> Report {
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

        // Which Scroblytics album each of Music's albums is. Matching by album title alone is only for compilations (a "Various
        // Artists" album on both sides, whose tracks have no one artist): for any other album a shared title proves nothing.
        struct Candidate {
            let key: Key
            let tracks: [AppleMusicTrackYear]
            let album: AuditAlbum
            let how: Match
        }
        var candidates: [Candidate] = []
        var unmatched = 0
        for key in order {
            let tracks = groups[key] ?? []
            var found = byKey[key].map { ($0, Match.albumArtist) }
            if found == nil {
                // The album artist may be spelled otherwise; a track's own artist is how it was scrobbled.
                for track in tracks {
                    let k = Key(artist: TextNormalization.artistIdentityKey(track.artist), title: key.title)
                    if let album = byKey[k] { found = (album, .trackArtist); break }
                }
            }
            if found == nil, let only = byTitle[key.title], only.count == 1,
               TextNormalization.isCompilationArtist(only[0].artist), tracks.contains(where: { $0.albumArtist.isEmpty || TextNormalization.isCompilationArtist($0.albumArtist) }) {
                found = (only[0], .titleOnly)
            }
            guard let (album, how) = found else { unmatched += 1; continue }
            candidates.append(Candidate(key: key, tracks: tracks, album: album, how: how))
        }

        // Each Scroblytics album is compared once: if several of Music's albums matched it, the best match (by the artist, then
        // by how many tracks it has) is the one; the rest are counted with the unmatched.
        func rank(_ how: Match) -> Int { how == .albumArtist ? 0 : (how == .trackArtist ? 1 : 2) }
        var best: [String: Candidate] = [:]
        for candidate in candidates {
            let id = albumKey(artistKey: candidate.album.artistKey, normalizedTitle: candidate.album.normalizedTitle)
            if let current = best[id], (rank(current.how), -current.tracks.count) <= (rank(candidate.how), -candidate.tracks.count) { unmatched += 1; continue }
            if best[id] != nil { unmatched += 1 }
            best[id] = candidate
        }

        var rows: [AlbumRow] = []
        for candidate in candidates where best[albumKey(artistKey: candidate.album.artistKey, normalizedTitle: candidate.album.normalizedTitle)]?.key == candidate.key {
            let (tracks, album, how) = (candidate.tracks, candidate.album, candidate.how)
            let years = tracks.compactMap(\.year)
            let albumYear = album.year
            // With no single most common year (tracks spread evenly over several years) the album has no year of its own in Music, so
            // any of the tied years agrees with it; only a year outside them is a disagreement.
            let tied = modalYears(years)
            let modal = albumYear.flatMap { tied.count > 1 && tied.contains($0) ? $0 : nil } ?? tied.min()
            var differences: [TrackDifference] = []
            for track in tracks {
                guard let musicYear = track.year else { continue }
                let savedKey = TextNormalization.lovedKey(artist: track.artist, track: track.name)
                let indexKey = trackIndexKey(artist: track.artist, title: track.name)
                if let knownTracks, !knownTracks.identityKeys.contains(savedKey), !knownTracks.indexKeys.contains(indexKey) { continue }
                let ownDate = trackOverrides[savedKey] ?? trackOverrideIndex[indexKey]
                let own = ownDate.flatMap(ReleaseDateEngine.year(of:))
                guard let shown = own ?? albumYear, shown != musicYear else { continue }
                differences.append(TrackDifference(name: track.name, artist: track.artist, musicYear: musicYear, scroblyticsYear: shown, ownDate: own != nil))
            }
            let first = tracks[0]
            let refs = tracks.map { track -> MusicTrackRef in
                let ownDate = trackOverrides[TextNormalization.lovedKey(artist: track.artist, track: track.name)]
                    ?? trackOverrideIndex[trackIndexKey(artist: track.artist, title: track.name)]
                let savedKey = TextNormalization.lovedKey(artist: track.artist, track: track.name)
                let played = knownTracks.map { $0.identityKeys.contains(savedKey) || $0.indexKeys.contains(trackIndexKey(artist: track.artist, title: track.name)) } ?? true
                return MusicTrackRef(persistentID: track.persistentID, name: track.name, artist: track.artist, musicYear: track.year, ownYear: ownDate.flatMap(ReleaseDateEngine.year(of:)), inScroblytics: played)
            }
            rows.append(AlbumRow(
                musicArtist: first.albumArtist.isEmpty ? first.artist : first.albumArtist, musicAlbum: first.album, trackCount: tracks.count,
                scroblytics: album, musicYear: modal, musicEarliest: years.min(), musicLatest: years.max(), musicDistinctYears: Set(years).count,
                category: category(scroblytics: albumYear, music: modal), matchedBy: how, trackDifferences: differences, musicTracks: refs
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
    struct Loaded: Sendable {
        let albums: [AuditAlbum]
        let trackOverrides: [String: String]
        let trackOverrideIndex: [String: String]
        let known: ReleaseYearAudit.KnownTracks
    }

    func load() -> Loaded {
        var albums: [AuditAlbum] = []
        for album in (try? modelContext.fetch(FetchDescriptor<Album>())) ?? [] {
            guard let artist = album.artist?.name else { continue }
            let date = album.releaseDateOverride.flatMap { $0.isEmpty ? nil : $0 } ?? album.releaseDateDetected
            albums.append(AuditAlbum(
                title: album.title, artist: artist, artistKey: TextNormalization.artistIdentityKey(artist), normalizedTitle: album.normalizedTitle,
                date: date, origin: AlbumDateOrigin.of(override: album.releaseDateOverride, detected: album.releaseDateDetected, recorded: album.releaseDateSource),
                detected: album.releaseDateDetected
            ))
        }
        var overrides: [String: String] = [:]
        var index: [String: String] = [:]
        var known = ReleaseYearAudit.KnownTracks()
        for track in (try? modelContext.fetch(FetchDescriptor<Track>())) ?? [] {
            known.identityKeys.insert(track.identityKey)
            let key = track.artist.map { ReleaseYearAudit.trackIndexKey(artist: $0.name, normalizedTitle: track.normalizedTitle) }
            if let key { known.indexKeys.insert(key) }
            guard let date = track.releaseDateOverride, !date.isEmpty else { continue }
            overrides[track.identityKey] = date
            if let key { index[key] = date }
        }
        return Loaded(albums: albums, trackOverrides: overrides, trackOverrideIndex: index, known: known)
    }
}
