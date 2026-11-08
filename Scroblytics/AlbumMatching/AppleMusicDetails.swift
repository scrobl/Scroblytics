import Foundation

/// What Apple Music knows about a song that Last.fm doesn't: when it was added to the library, its genre, and its tempo tag. Read
/// from the running Music app (`AppleMusicFavoritesReader.readLibraryDetails`), kept in a small file on this Mac so Query and the
/// detail pages can use it while Music is closed, and matched to Last.fm songs here. Nothing leaves the Mac.
///
/// Matching a Last.fm song (which is just an artist name and a title) to a library song is where mistakes could creep in, so the rule
/// is deliberately cautious. See `AppleMusicDetailsIndex.match`.
struct AppleMusicDetailRow: Codable, Sendable, Equatable {
    var artist: String
    var title: String
    var album: String
    var albumArtist: String
    /// Music's genre for the song; empty when it has none.
    var genre: String
    /// Music's own tempo tag in beats per minute; 0 when it has none.
    var bpm: Int
    /// When the song was added to the library; nil when Music has no date.
    var dateAdded: Date?
    /// How long Music says the song runs, in whole seconds; 0 when it has no length.
    var seconds: Int = 0

    private enum CodingKeys: String, CodingKey { case artist, title, album, albumArtist, genre, bpm, dateAdded, seconds }
}

extension AppleMusicDetailRow {
    /// A read saved before lengths were kept has no `seconds`; it still loads (the length is just unknown until the next read).
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        artist = try values.decode(String.self, forKey: .artist)
        title = try values.decode(String.self, forKey: .title)
        album = try values.decode(String.self, forKey: .album)
        albumArtist = try values.decode(String.self, forKey: .albumArtist)
        genre = try values.decode(String.self, forKey: .genre)
        bpm = try values.decode(Int.self, forKey: .bpm)
        dateAdded = try values.decodeIfPresent(Date.self, forKey: .dateAdded)
        seconds = try values.decodeIfPresent(Int.self, forKey: .seconds) ?? 0
    }
}

/// One read of the library: every song in it (a song present in two copies, such as a file and a streaming copy, is two rows).
struct AppleMusicDetailsFile: Codable, Sendable {
    var version = 1
    var readAt: Date
    var rows: [AppleMusicDetailRow]
    /// For each song the library holds more than once (`BPMEngine.cacheKey`), the albums Last.fm has it scrobbled under, most played first
    /// (plain names, at most three). It lets the tempo and length that other parts of the app read pick the copy on the album you actually
    /// play, without those parts having the history at hand. Kept current by `AppleMusicDetailsStore`; absent in a file saved before it existed.
    var albums: [String: [String]] = [:]

    private enum CodingKeys: String, CodingKey { case version, readAt, rows, albums }
}

extension AppleMusicDetailsFile {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        readAt = try values.decode(Date.self, forKey: .readAt)
        rows = try values.decode([AppleMusicDetailRow].self, forKey: .rows)
        albums = try values.decodeIfPresent([String: [String]].self, forKey: .albums) ?? [:]
    }
}

/// Where the read is kept, and a decoded copy shared by everything that asks for it until the file changes.
enum AppleMusicDetailsStorage {
    private nonisolated static let folderName = "MusicLibrary"
    private nonisolated static let fileName = "library-details.json"

    /// Next to the app's other caches. A headless run on a scratch store keeps it beside that store, so a test never touches the real one.
    nonisolated static func defaultURL() -> URL {
        var base = URL.applicationSupportDirectory.appending(path: "Scroblytics", directoryHint: .isDirectory)
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SCROBLYTICS_STORE_PATH"], !path.isEmpty {
            base = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        #endif
        return base.appending(path: folderName, directoryHint: .isDirectory).appending(path: fileName, directoryHint: .notDirectory)
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var key: String?
        var file: AppleMusicDetailsFile?
        var tempo: [String: Double] = [:]
        var durations: [String: Int] = [:]
    }
    private nonisolated static let cache = Cache()

    /// The saved read, or nil when there is none (never read, or deleted). Decoded once per change of the file.
    nonisolated static func load(from url: URL = defaultURL()) -> AppleMusicDetailsFile? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes?[.modificationDate] as? Date, let size = attributes?[.size] as? NSNumber else { return nil }
        let key = "\(url.path)|\(modified.timeIntervalSince1970)|\(size)"
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if cache.key == key, let file = cache.file { return file }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(AppleMusicDetailsFile.self, from: data), file.version == 1 else { return nil }
        cache.key = key
        cache.file = file
        cache.tempo = AppleMusicDetailsIndex.tempoByKey(file.rows, albums: file.albums)
        cache.durations = AppleMusicDetailsIndex.durationByKey(file.rows, albums: file.albums)
        return file
    }

    /// Music's length for each song (`AppleMusicDetailsIndex.durationByKey`) from the saved read; empty when there is none.
    nonisolated static func durationMap(from url: URL = defaultURL()) -> [String: Int] {
        guard load(from: url) != nil else { return [:] }
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return cache.durations
    }

    /// Music's tempo tag for each song (`AppleMusicDetailsIndex.tempoByKey`) from the saved read; empty when there is none. Computed once per
    /// change of the file.
    nonisolated static func tempoMap(from url: URL = defaultURL()) -> [String: Double] {
        guard load(from: url) != nil else { return [:] }
        cache.lock.lock()
        defer { cache.lock.unlock() }
        return cache.tempo
    }

    nonisolated static func save(_ file: AppleMusicDetailsFile, to url: URL = defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    nonisolated static func delete(at url: URL = defaultURL()) {
        try? FileManager.default.removeItem(at: url)
        cache.lock.lock()
        cache.key = nil
        cache.file = nil
        cache.tempo = [:]
        cache.durations = [:]
        cache.lock.unlock()
    }
}

/// One matching index kept between uses, so a Query that is edited and run again, or a detail page, doesn't rebuild it (about a second on a big
/// library). It is rebuilt when the saved read or the history changes.
enum AppleMusicDetailsIndexCache {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var key: [Double] = []
        var index: AppleMusicDetailsIndex?
    }
    private nonisolated static let box = Box()

    nonisolated static func index(for file: AppleMusicDetailsFile, scrobbles: [ScrobbleSnapshot]) -> AppleMusicDetailsIndex {
        let firstPlay: Double = scrobbles.first?.playedAt.timeIntervalSince1970 ?? 0
        let lastPlay: Double = scrobbles.last?.playedAt.timeIntervalSince1970 ?? 0
        let key: [Double] = [file.readAt.timeIntervalSince1970, Double(file.rows.count), Double(scrobbles.count), firstPlay, lastPlay]
        box.lock.lock()
        defer { box.lock.unlock() }
        if box.key == key, let index = box.index { return index }
        let built = AppleMusicDetailsIndex(rows: file.rows, scrobbles: scrobbles)
        box.key = key
        box.index = built
        return built
    }
}

/// The saved read as the Query engine carries it (a value, so a run reads one fixed copy). Empty until the library has been read.
struct AppleMusicDetailsSnapshot: Sendable {
    var file: AppleMusicDetailsFile?

    nonisolated static let empty = AppleMusicDetailsSnapshot()

    nonisolated static func load() -> AppleMusicDetailsSnapshot {
        AppleMusicDetailsSnapshot(file: AppleMusicDetailsStorage.load())
    }

    nonisolated var isEmpty: Bool { file == nil }
}

/// Matches Last.fm songs, albums and artists to the library rows, and answers the three questions Query and the detail pages ask.
///
/// A song is matched like this, and never more loosely:
/// 1. **Same artist and title** (ignoring capitals and spacing): that is the song. When the library holds it more than once, **the album
///    decides which copy**: the copy on the album Last.fm has it scrobbled under (the most played one the library has a copy of) is the
///    version, and the other copies are ignored (`pickVersion`). Only when no scrobbled album has a copy does it fall back to all the copies,
///    where date added is the earliest, genre the one most carry, and tempo and length are used only if the copies agree.
/// 2. **A different spelling of the same song** (the library says "Title", Last.fm says "Title (feat. Someone)" or a remaster tag): matched
///    only when it pairs one to one, that is, exactly one library title and exactly one Last.fm title are left over once the identical
///    ones are paired off. Otherwise there is more than one possible partner.
/// 3. **Anything else is not matched.** When the library has several titles that could be the partner, it is *ambiguous* and the song
///    gets nothing; `unmatched()` lists those so the person can see what was skipped. A library title already taken by an identical
///    Last.fm title is never lent to a different spelling.
struct AppleMusicDetailsIndex: Sendable {
    enum TrackMatch: Sendable, Equatable {
        /// The library songs this Last.fm song is. `viaSpelling` is true when the titles differ (rule 2).
        case matched(rows: [Int], viaSpelling: Bool)
        /// More than one library title could be it; the candidates are named "Artist — Title".
        case ambiguous(candidates: [String])
        case none
    }

    /// A Last.fm song that couldn't be matched because the library holds several possible partners.
    struct Unmatched: Sendable, Identifiable, Equatable {
        var id: String { "\(artist)\u{241F}\(track)" }
        let artist: String
        let track: String
        let plays: Int
        let candidates: [String]
    }

    let rows: [AppleMusicDetailRow]
    private let byExact: [String: [Int]]
    private let libraryKeysByFuzzy: [String: [String]]
    private let scrobbledKeysByFuzzy: [String: Set<String>]
    private let libraryDisplay: [String: String]
    private let scrobbledTitles: [String: (artist: String, track: String, plays: Int)]
    private let byAlbum: [String: [Int]]
    private let byArtist: [String: [Int]]
    /// `exactKey` → the albums a song is scrobbled under, most played first (plain names).
    private let albumsByKey: [String: [String]]

    nonisolated init(rows: [AppleMusicDetailRow], scrobbles: [ScrobbleSnapshot]) {
        self.rows = rows
        var exact: [String: [Int]] = [:]
        var fuzzy: [String: Set<String>] = [:]
        var display: [String: String] = [:]
        var album: [String: [Int]] = [:]
        var artist: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() where !row.title.isEmpty {
            let key = UnscrobbledPlaysEngine.exactKey(artist: row.artist, track: row.title)
            exact[key, default: []].append(index)
            if display[key] == nil {
                display[key] = "\(row.artist) — \(row.title)"
                fuzzy[LibraryGapsEngine.key(artist: row.artist, track: row.title), default: []].insert(key)
            }
            let normalizedAlbum = Self.albumKey(row.album)
            let owners = Set([Self.plain(row.artist), Self.plain(row.albumArtist.isEmpty ? row.artist : row.albumArtist), Self.plain(row.albumArtist)].filter { !$0.isEmpty })
            for owner in owners {
                if !normalizedAlbum.isEmpty { album[owner + "\u{241F}" + normalizedAlbum, default: []].append(index) }
                artist[owner, default: []].append(index)
            }
        }
        var titles: [String: (artist: String, track: String, plays: Int)] = [:]
        var albumCounts: [String: [String: Int]] = [:]
        // Distinct songs first (a long history repeats the same few thousand), so a name is normalized once per song, not once per play.
        for song in Self.distinctSongs(scrobbles) {
            let key = UnscrobbledPlaysEngine.exactKey(artist: song.artist, track: song.track)
            if let existing = titles[key] { titles[key] = (existing.artist, existing.track, existing.plays + song.plays) } else { titles[key] = (song.artist, song.track, song.plays) }
            for (name, count) in song.albums where !name.isEmpty { albumCounts[key, default: [:]][Self.plain(name), default: 0] += count }
        }
        var scrobbledFuzzy: [String: Set<String>] = [:]
        for (key, title) in titles where exact[key] == nil {
            // Only titles with no identical library title can need a fuzzy partner, so only they are keyed.
            scrobbledFuzzy[LibraryGapsEngine.key(artist: title.artist, track: title.track), default: []].insert(key)
        }
        byExact = exact
        libraryKeysByFuzzy = fuzzy.mapValues { $0.sorted() }
        scrobbledKeysByFuzzy = scrobbledFuzzy
        libraryDisplay = display
        scrobbledTitles = titles
        byAlbum = album.mapValues { Array(Set($0)).sorted() }
        byArtist = artist.mapValues { Array(Set($0)).sorted() }
        albumsByKey = albumCounts.mapValues(Self.ranked)
    }

    /// Case-insensitive, whitespace-collapsed: the same rule as `UnscrobbledPlaysEngine.exactKey` applies to each half.
    nonisolated static func plain(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    // MARK: Matching

    nonisolated func match(artist: String, track: String) -> TrackMatch {
        let exact = UnscrobbledPlaysEngine.exactKey(artist: artist, track: track)
        if let indexes = byExact[exact] { return .matched(rows: indexes, viaSpelling: false) }
        let fuzzy = LibraryGapsEngine.key(artist: artist, track: track)
        guard let libraryKeys = libraryKeysByFuzzy[fuzzy] else { return .none }
        // Library titles with no identical Last.fm title, and Last.fm titles with no identical library title, are the two sides left to pair up.
        // `scrobbledKeysByFuzzy` holds only Last.fm titles with no identical library title, so it already is the Last.fm side.
        let leftoverScrobbled = (scrobbledKeysByFuzzy[fuzzy] ?? []).union([exact])
        let leftoverLibrary = libraryKeys.filter { scrobbledTitles[$0] == nil }
        if leftoverLibrary.isEmpty { return .none }
        if leftoverLibrary.count == 1, leftoverScrobbled.count == 1, let indexes = byExact[leftoverLibrary[0]] {
            return .matched(rows: indexes, viaSpelling: true)
        }
        return .ambiguous(candidates: leftoverLibrary.compactMap { libraryDisplay[$0] })
    }

    /// The library rows that are this song, or none: every copy the match found, narrowed to the copy on the album the song is scrobbled
    /// under when the library holds it more than once (`pickVersion`).
    nonisolated func rows(artist: String, track: String) -> [AppleMusicDetailRow] {
        guard case .matched(let indexes, _) = match(artist: artist, track: track) else { return [] }
        let copies = indexes.map { rows[$0] }
        let albums = albumsByKey[UnscrobbledPlaysEngine.exactKey(artist: artist, track: track)] ?? []
        return Self.pickVersion(copies, albums: albums)
    }

    /// Which copies of a song are "the song" when the library holds it more than once (a studio album, a greatest hits, a live record).
    /// The album decides: walking the albums Last.fm has the song under, most played first, the first one the library has a copy on wins,
    /// and only the copies on it count: first those whose album name is identical, then those the app's album-name rule treats as the same
    /// (edition suffixes and punctuation ignored). With no scrobbled album, or none the library has a copy on, every copy is kept and the
    /// callers' cautious rules apply (tempo and length need agreeing copies).
    nonisolated static func pickVersion(_ copies: [AppleMusicDetailRow], albums: [String]) -> [AppleMusicDetailRow] {
        guard copies.count > 1, !albums.isEmpty else { return copies }
        for album in albums {
            let exact = copies.filter { plain($0.album) == album }
            if !exact.isEmpty { return exact }
            let key = albumKey(album)
            guard !key.isEmpty else { continue }
            let near = copies.filter { albumKey($0.album) == key }
            if !near.isEmpty { return near }
        }
        return copies
    }

    // MARK: Scrobbled albums

    /// One distinct Last.fm song with its play count and how many plays each album name got.
    struct ScrobbledSong: Sendable {
        let artist: String
        let track: String
        var plays: Int
        var albums: [String: Int]
    }

    /// The history folded to its distinct songs (identical artist and title text), without normalizing a name for every play.
    nonisolated static func distinctSongs(_ scrobbles: [ScrobbleSnapshot]) -> [ScrobbledSong] {
        var songs: [String: ScrobbledSong] = [:]
        for s in scrobbles where !s.trackName.isEmpty && !s.artistName.isEmpty {
            let key = s.artistName + "\u{0}" + s.trackName
            if songs[key] == nil { songs[key] = ScrobbledSong(artist: s.artistName, track: s.trackName, plays: 0, albums: [:]) }
            songs[key]?.plays += 1
            if !s.albumName.isEmpty { songs[key]?.albums[s.albumName, default: 0] += 1 }
        }
        return Array(songs.values)
    }

    /// Album names most played first (ties alphabetical), at most three, as plain names.
    nonisolated static func ranked(_ counts: [String: Int]) -> [String] {
        Array(counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3).map(\.key))
    }

    /// For every song the library holds more than once (`BPMEngine.cacheKey`), the albums it is scrobbled under, most played first. Only those
    /// songs need it: with one copy there is nothing to choose between. This is what `AppleMusicDetailsFile.albums` keeps.
    nonisolated static func albumsForRepeatedSongs(rows: [AppleMusicDetailRow], scrobbles: [ScrobbleSnapshot]) -> [String: [String]] {
        var copies: [String: Int] = [:]
        for row in rows where !row.title.isEmpty { copies[BPMEngine.cacheKey(artist: row.artist, track: row.title), default: 0] += 1 }
        let repeated = Set(copies.filter { $0.value > 1 }.keys)
        guard !repeated.isEmpty else { return [:] }
        var counts: [String: [String: Int]] = [:]
        for song in distinctSongs(scrobbles) where !song.albums.isEmpty {
            let key = BPMEngine.cacheKey(artist: song.artist, track: song.track)
            guard repeated.contains(key) else { continue }
            for (name, count) in song.albums { counts[key, default: [:]][plain(name), default: 0] += count }
        }
        return counts.mapValues(ranked)
    }

    /// An album's name for matching: the app's usual album-name rule (which ignores capitals, punctuation and edition suffixes), except that
    /// a name that rule reduces to nothing (a title in another script, or only accented letters) is compared plainly rather than never matching.
    nonisolated static func albumKey(_ album: String) -> String {
        let normalized = TextNormalization.normalizeAlbumName(album)
        return normalized.isEmpty ? plain(album) : normalized
    }

    nonisolated func rows(artist: String, album: String) -> [AppleMusicDetailRow] {
        let key = Self.plain(artist) + "\u{241F}" + Self.albumKey(album)
        return (byAlbum[key] ?? []).map { rows[$0] }
    }

    nonisolated func rows(artist: String) -> [AppleMusicDetailRow] {
        (byArtist[Self.plain(artist)] ?? []).map { rows[$0] }
    }

    /// Last.fm songs the library has several possible partners for, most played first: what was skipped because it was unclear.
    nonisolated func unmatched() -> [Unmatched] {
        var out: [Unmatched] = []
        for (key, title) in scrobbledTitles where byExact[key] == nil {
            if case .ambiguous(let candidates) = match(artist: title.artist, track: title.track) {
                out.append(Unmatched(artist: title.artist, track: title.track, plays: title.plays, candidates: candidates))
            }
        }
        return out.sorted { ($0.plays, $1.artist, $1.track) > ($1.plays, $0.artist, $0.track) }
    }

    // MARK: What the rows say

    /// The earliest date any of the rows was added.
    nonisolated static func earliestAdded(_ rows: [AppleMusicDetailRow]) -> Date? {
        rows.compactMap(\.dateAdded).min()
    }

    /// The genre most of the rows carry (ties go to the one on the earliest-added row, then alphabetically); nil when none has one.
    nonisolated static func commonGenre(_ rows: [AppleMusicDetailRow]) -> String? {
        var counts: [String: Int] = [:]
        var earliest: [String: Date] = [:]
        for row in rows where !row.genre.isEmpty {
            counts[row.genre, default: 0] += 1
            if let added = row.dateAdded, added < (earliest[row.genre] ?? .distantFuture) { earliest[row.genre] = added }
        }
        return counts.max { a, b in
            if a.value != b.value { return a.value < b.value }
            let da = earliest[a.key] ?? .distantFuture, db = earliest[b.key] ?? .distantFuture
            if da != db { return da > db }
            return a.key > b.key
        }?.key
    }

    // MARK: Length

    /// Music's length for each song, keyed the way lengths are everywhere (`DurationEngine.cacheKey`), for songs whose length is usable. Like tempo it
    /// belongs to a recording, so only identical titles count. A song the library holds more than once uses the copy on the album it is scrobbled
    /// under (`albums`, from `albumsForRepeatedSongs`); if that doesn't settle it, a song whose copies disagree by more than 2 seconds (a studio
    /// and a live take under one title, say) gets none rather than a guess.
    nonisolated static func durationByKey(_ rows: [AppleMusicDetailRow], albums: [String: [String]] = [:]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, group) in rowsByKey(rows) {
            let version = pickVersion(group, albums: albums[key] ?? [])
            let list = version.map(\.seconds).filter { $0 > 0 }
            guard let low = list.min(), let high = list.max(), high - low <= 2 else { continue }
            out[key] = list.sorted()[list.count / 2]
        }
        return out
    }

    // MARK: Tempo

    /// Music's tempo tag for each song, keyed the way tempo is everywhere (`BPMEngine.cacheKey`), for songs whose tag is usable. Tempo
    /// belongs to a recording, so only identical titles count (no spelling variants). A song the library holds more than once uses the copy on
    /// the album it is scrobbled under; if that doesn't settle it, a song whose copies disagree by more than 2 BPM gets none rather than a guess.
    nonisolated static func tempoByKey(_ rows: [AppleMusicDetailRow], albums: [String: [String]] = [:]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, group) in rowsByKey(rows) {
            let version = pickVersion(group, albums: albums[key] ?? [])
            let list = version.map(\.bpm).filter { $0 > 0 }
            guard let low = list.min(), let high = list.max(), high - low <= 2 else { continue }
            out[key] = Double(list.sorted()[list.count / 2])
        }
        return out
    }

    /// The rows grouped by song the way tempo and length are keyed (`BPMEngine.cacheKey`; the two keys are the same rule).
    private nonisolated static func rowsByKey(_ rows: [AppleMusicDetailRow]) -> [String: [AppleMusicDetailRow]] {
        var groups: [String: [AppleMusicDetailRow]] = [:]
        for row in rows where !row.title.isEmpty { groups[BPMEngine.cacheKey(artist: row.artist, track: row.title), default: []].append(row) }
        return groups
    }
}
