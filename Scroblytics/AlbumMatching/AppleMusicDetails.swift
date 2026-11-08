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
}

/// One read of the library: every song in it (a song present in two copies, such as a file and a streaming copy, is two rows).
struct AppleMusicDetailsFile: Codable, Sendable {
    var version = 1
    var readAt: Date
    var rows: [AppleMusicDetailRow]
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
        cache.tempo = AppleMusicDetailsIndex.tempoByKey(file.rows)
        return file
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
/// 1. **Same artist and title** (ignoring capitals and spacing): that is the song. Date added is the earliest across its copies, genre the
///    one most of them carry.
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
        for s in scrobbles where !s.trackName.isEmpty && !s.artistName.isEmpty {
            let key = UnscrobbledPlaysEngine.exactKey(artist: s.artistName, track: s.trackName)
            if let existing = titles[key] { titles[key] = (existing.artist, existing.track, existing.plays + 1) } else { titles[key] = (s.artistName, s.trackName, 1) }
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

    /// The library rows of a song's match, or none.
    nonisolated func rows(artist: String, track: String) -> [AppleMusicDetailRow] {
        guard case .matched(let indexes, _) = match(artist: artist, track: track) else { return [] }
        return indexes.map { rows[$0] }
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

    // MARK: Tempo

    /// Music's tempo tag for each song, keyed the way tempo is everywhere (`BPMEngine.cacheKey`), for songs whose tag is usable. Tempo
    /// belongs to a recording, so only identical titles count (no spelling variants), and a song whose copies disagree by more than
    /// 2 BPM gets none rather than a guess.
    nonisolated static func tempoByKey(_ rows: [AppleMusicDetailRow]) -> [String: Double] {
        var values: [String: [Int]] = [:]
        for row in rows where row.bpm > 0 && !row.title.isEmpty {
            values[BPMEngine.cacheKey(artist: row.artist, track: row.title), default: []].append(row.bpm)
        }
        var out: [String: Double] = [:]
        for (key, list) in values {
            guard let low = list.min(), let high = list.max(), high - low <= 2 else { continue }
            out[key] = Double(list.sorted()[list.count / 2])
        }
        return out
    }
}
