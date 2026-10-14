import Foundation

/// One line of the new Album page's track table: a track of the album's tracklist (played in the chosen period or not), or a track
/// that was played but matches nothing on the tracklist.
struct AlbumTrackRow: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A track on the album's tracklist.
        case listed
        /// A track that was played in the period but is not on the tracklist (a bonus or live version, a renamed title), or, when
        /// no tracklist is known, any played track.
        case extra
    }

    let id: String
    let kind: Kind
    /// 1-based place on the tracklist; nil for an extra.
    let position: Int?
    let title: String
    /// Its plays in the chosen period; nil when it has none (or is an unmatched title with no plays).
    let entry: TopChartEntry?
    /// Whether it counts toward the current listen-through; nil when there is no tracklist to take cycles from.
    let heardThisCycle: Bool?

    var isPlayedInPeriod: Bool { entry != nil }
}

enum AlbumTrackSort: String, CaseIterable, Identifiable {
    case trackOrder, mostPlayed, alphabetical, recentlyPlayed, releaseYear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trackOrder: "Track order"
        case .mostPlayed: "Most played"
        case .alphabetical: "A–Z"
        case .recentlyPlayed: "Recently played"
        case .releaseYear: "Release year"
        }
    }

    /// The direction a sort starts in: first to last and A to Z read upward, the others start with the most, newest or latest first.
    var startsAscending: Bool {
        switch self {
        case .trackOrder, .alphabetical: true
        case .mostPlayed, .recentlyPlayed, .releaseYear: false
        }
    }

    /// What the direction button says, in the sort's own words.
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .trackOrder: ascending ? "First to last" : "Last to first"
        case .alphabetical: ascending ? "A to Z" : "Z to A"
        case .mostPlayed: ascending ? "Fewest first" : "Most first"
        case .recentlyPlayed: ascending ? "Oldest first" : "Newest first"
        case .releaseYear: ascending ? "Oldest first" : "Newest first"
        }
    }
}

enum AlbumTrackFilter: String, CaseIterable, Identifiable {
    case all, playedInPeriod, notHeardThisCycle

    var id: String { rawValue }
}

/// How a track on an album's tracklist is actually spelled in the listening history: the name to open its page under.
struct PlayedName: Sendable, Hashable {
    let artist: String
    let name: String
}

/// Joins an album's tracklist with the plays in the chosen period. A pure function of its inputs, checked on made-up data.
enum AlbumTrackRows {
    struct ListedTrack: Equatable {
        let title: String
        /// Whether the track is heard in the current listen-through; nil when cycles are not known.
        let heardThisCycle: Bool?
    }

    /// The tracklist in order, each track paired with its plays in the period (matched by normalized title; a title that appears
    /// twice is paired in order), then every played track that matched nothing. With no tracklist, just the played tracks.
    static func merge(tracklist: [ListedTrack]?, entries: [TopChartEntry]) -> [AlbumTrackRow] {
        guard let tracklist, !tracklist.isEmpty else {
            return entries.map { AlbumTrackRow(id: "e\($0.id)", kind: .extra, position: nil, title: $0.name, entry: $0, heardThisCycle: nil) }
        }
        var waiting: [String: [TopChartEntry]] = [:]
        for entry in entries { waiting[TextNormalization.normalizeTrackTitle(entry.name), default: []].append(entry) }
        var rows: [AlbumTrackRow] = []
        for (index, track) in tracklist.enumerated() {
            let key = TextNormalization.normalizeTrackTitle(track.title)
            var matched: TopChartEntry?
            if var queue = waiting[key], !queue.isEmpty {
                matched = queue.removeFirst()
                waiting[key] = queue
            }
            rows.append(AlbumTrackRow(id: "t\(index)", kind: .listed, position: index + 1, title: track.title, entry: matched, heardThisCycle: track.heardThisCycle))
        }
        // Whatever is left over, in the order the plays were ranked.
        let claimed = Set(rows.compactMap { $0.entry?.id })
        for entry in entries where !claimed.contains(entry.id) {
            rows.append(AlbumTrackRow(id: "e\(entry.id)", kind: .extra, position: nil, title: entry.name, entry: entry, heardThisCycle: nil))
        }
        return rows
    }

    /// Every track this album has ever been played as, keyed by normalized title, so a tracklist title that was scrobbled under another
    /// spelling ("Song - 2011 Remaster") still finds its own page. A title played under two spellings goes to the one played most (ties
    /// to the alphabetically first, so the answer never changes between runs). Plays are matched to the album the way the table's own
    /// ranking does: the same artist, and the same album once edition suffixes are set aside.
    static func playedNames(from plays: [ScrobbleSnapshot], artist: String, album: String) -> [String: PlayedName] {
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let albumKey = TextNormalization.normalizeAlbumName(album)
        var counts: [String: [PlayedName: Int]] = [:]
        for play in plays where !play.trackName.isEmpty {
            guard TextNormalization.artistIdentityKey(play.artistName) == artistKey,
                  TextNormalization.normalizeAlbumName(play.albumName) == albumKey else { continue }
            counts[TextNormalization.normalizeTrackTitle(play.trackName), default: [:]][PlayedName(artist: play.artistName, name: play.trackName), default: 0] += 1
        }
        return counts.mapValues { spellings in
            spellings.max { a, b in
                a.value != b.value ? a.value < b.value : (a.key.name, a.key.artist) > (b.key.name, b.key.artist)
            }!.key
        }
    }

    /// The artist and title a row's track page opens under: the played track's own names, else how the history spells it, else the
    /// tracklist's title under the album's artist (a track nobody has played).
    static func identity(for row: AlbumTrackRow, albumArtist: String, playedNames: [String: PlayedName]) -> PlayedName {
        if let entry = row.entry { return PlayedName(artist: entry.artist ?? albumArtist, name: entry.name) }
        if let seen = playedNames[TextNormalization.normalizeTrackTitle(row.title)] { return seen }
        return PlayedName(artist: albumArtist, name: row.title)
    }

    static func filtered(_ rows: [AlbumTrackRow], by filter: AlbumTrackFilter) -> [AlbumTrackRow] {
        switch filter {
        case .all: rows
        case .playedInPeriod: rows.filter(\.isPlayedInPeriod)
        case .notHeardThisCycle: rows.filter { $0.heardThisCycle == false }
        }
    }

    static func notHeardCount(_ rows: [AlbumTrackRow]) -> Int {
        rows.filter { $0.heardThisCycle == false }.count
    }

    /// Orders the rows, ascending or descending (nil = the sort's own starting direction). Tracks with no plays count as zero plays
    /// in "Most played"; in the date orders a track with nothing to date is last whichever way the list runs, since "unknown" is not
    /// oldest or newest. "Track order" puts extras after the tracklist, and a reversed list starts with them.
    static func sorted(_ rows: [AlbumTrackRow], by sort: AlbumTrackSort, metric: TopChartsMetric, ascending: Bool? = nil) -> [AlbumTrackRow] {
        let up = ascending ?? sort.startsAscending
        func byTitle(_ a: AlbumTrackRow, _ b: AlbumTrackRow) -> Bool {
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        func inTracklistOrder(_ a: AlbumTrackRow, _ b: AlbumTrackRow) -> Bool {
            switch (a.position, b.position) {
            case (let x?, let y?): return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return byTitle(a, b)
            }
        }
        /// Rows with a value in the chosen direction; rows without one last, in tracklist order.
        func byValue<V: Comparable>(_ value: @escaping (AlbumTrackRow) -> V?) -> [AlbumTrackRow] {
            rows.sorted { a, b in
                switch (value(a), value(b)) {
                case (let x?, let y?): return x != y ? (up ? x < y : x > y) : inTracklistOrder(a, b)
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return inTracklistOrder(a, b)
                }
            }
        }
        switch sort {
        case .trackOrder:
            let natural = rows.sorted(by: inTracklistOrder)
            return up ? natural : Array(natural.reversed())
        case .alphabetical:
            let natural = rows.sorted(by: byTitle)
            return up ? natural : Array(natural.reversed())
        case .mostPlayed:
            return byValue { Optional($0.entry?.metricValue(for: metric) ?? 0) }
        case .recentlyPlayed:
            return byValue { $0.entry?.lastPlayedAt }
        case .releaseYear:
            return byValue { $0.entry?.releaseDate.flatMap(ReleaseDateEngine.year(of:)) }
        }
    }

    /// The tracklist from a turnover result, only when it is a real album tracklist (not just the titles that were played).
    static func tracklist(from state: AlbumTurnoverState) -> [ListedTrack]? {
        guard case .ready(let turnover) = state, turnover.applicable, turnover.basis == .canonical, !turnover.tracks.isEmpty else { return nil }
        return turnover.tracks.map { ListedTrack(title: $0.title, heardThisCycle: $0.heardThisCycle) }
    }
}
