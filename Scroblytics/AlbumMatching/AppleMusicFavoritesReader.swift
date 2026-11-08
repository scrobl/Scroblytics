import AppKit
import Foundation

/// What Music.app holds that the Loved Status Audit needs: the user's favorites and the whole library.
struct AppleMusicSnapshot: Sendable {
    struct Track: Sendable, Hashable {
        let name: String
        let artist: String
        let album: String
        /// Music's `cloud status` for the track ("subscription", "matched", "no longer available", …) — only
        /// filled when the read asked for it; "" otherwise.
        var cloudStatus: String = ""
        /// Music's `database ID` for the track, when read. A favorite whose ID is not among the library's IDs is not a library
        /// track (see the Loved Status Audit's "Not in library").
        var databaseID: Int? = nil
        /// Music's `album artist` for the track, when the read asked for it; "" otherwise (and for a track that has none).
        var albumArtist: String = ""
        /// When Music last played the track (its `played date`), when the read asked for it; nil when it never has, or wasn't asked.
        var lastPlayedAt: Date? = nil
        /// Music's `played count` for the track, when the read asked for it; 0 otherwise.
        var playCount: Int = 0
    }

    enum Source: Sendable {
        /// The auto-generated "Favorite Songs" playlist — Apple's own favorites set.
        case favoritesPlaylist
        /// The `favorited` flag read across the whole library — slower, but doesn't depend on the playlist's name.
        case favoritedFlag
    }

    let favorites: [Track]
    /// Every track in the library, favorited or not — so "not loved" can be told from "not in the library".
    let library: [Track]
    let source: Source
    let readSeconds: Double
}

/// Reads Music.app's favorites and library in COLUMNS — one Apple Event per property for the whole list — rather
/// than walking tracks one at a time. Measured on a 19,001-track library with 5,412 favorites: 0.57 s, versus
/// about 27 ms per track (~150 s) for an indexed walk. Read-only; never writes to Music.
enum AppleMusicFavoritesReader {
    enum ReadError: Error, LocalizedError {
        case musicNotRunning
        case unexpectedOutput

        var errorDescription: String? {
            switch self {
            case .musicNotRunning: "Music isn't open. Open Music, then try again."
            case .unexpectedOutput: "Music returned something unexpected while reading your library."
            }
        }
    }

    static let musicBundleID = "com.apple.Music"

    /// A plain `tell application "Music"` LAUNCHES Music if it isn't running, so check first. Asks both ways:
    /// `runningApplications(withBundleIdentifier:)` was observed to come back empty for a Music that was plainly
    /// running (right after an Apple Event read of a smart playlist), while the workspace's full list still had it.
    static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).isEmpty
            || NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == musicBundleID }
    }

    private static let columnSep = "\u{1D}"
    private static let itemSep = "\u{1E}"

    /// Columns come back joined in ONE step each (not row by row in AppleScript, which is ~20x slower for the same
    /// data). First column names the source; the rest are favorites then library columns.
    private static func script(includeCloudStatus: Bool, includeAlbumArtist: Bool, includePlayed: Bool) -> String {
    """
    set includeCloud to \(includeCloudStatus)
    set includeAlbumArtist to \(includeAlbumArtist)
    set includePlayed to \(includePlayed)
    set rs to (ASCII character 30)
    set gs to (ASCII character 29)
    set mode to "playlist"
    tell application "Music"
        set ln to name of every track of library playlist 1
        set la to artist of every track of library playlist 1
        set lb to album of every track of library playlist 1
        set lc to {}
        if includeCloud then set lc to cloud status of every track of library playlist 1
        set lg to {}
        if includeAlbumArtist then set lg to album artist of every track of library playlist 1
        set li to database ID of every track of library playlist 1
        set lpd to {}
        set lpc to {}
        if includePlayed then
            set lpd to played date of every track of library playlist 1
            set lpc to played count of every track of library playlist 1
        end if
        set fn to {}
        set fa to {}
        set fb to {}
        set ff to {}
        set fi to {}
        set fc to {}
        try
            set fs to playlist "Favorite Songs"
            set fn to name of every track of fs
            set fa to artist of every track of fs
            set fb to album of every track of fs
            set fi to database ID of every track of fs
            set fc to cloud status of every track of fs
        on error
            set mode to "flag"
            set ff to favorited of every track of library playlist 1
        end try
    end tell
    -- Played dates as seconds since 1970. A date printed as text uses TODAY's UTC offset for every date (so a summer date
    -- reads an hour off in winter), so the dates are turned into absolute seconds here instead: both `current date` and each
    -- played date are instants, and their difference is exact.
    set pdOut to {}
    if includePlayed then
        set nowDate to current date
        set nowEpoch to (do shell script "date +%s") as integer
        repeat with d in lpd
            set dv to contents of d
            if dv is missing value then
                set end of pdOut to ""
            else
                set end of pdOut to (nowEpoch - (nowDate - dv)) as integer
            end if
        end repeat
    end if
    set AppleScript's text item delimiters to rs
    set o1 to fn as string
    set o2 to fa as string
    set o3 to fb as string
    set o4 to ln as string
    set o5 to la as string
    set o6 to lb as string
    set o7 to ff as string
    set o8 to lc as string
    set o9 to li as string
    set o10 to fi as string
    set o11 to fc as string
    set o12 to lg as string
    set o13 to pdOut as string
    set o14 to lpc as string
    set AppleScript's text item delimiters to ""
    return mode & gs & o1 & gs & o2 & gs & o3 & gs & o4 & gs & o5 & gs & o6 & gs & o7 & gs & o8 & gs & o9 & gs & o10 & gs & o11 & gs & o12 & gs & o13 & gs & o14
    """
    }

    /// `includeCloudStatus` adds one more whole-library column (`cloud status`); the Loved Status Audit doesn't need it.
    /// Only the songs Music has played in the last `days` days, with their played dates and counts, in about a second and a half on a
    /// 19,000-song library (the whole-library read takes about nine). It is what the background scrobbling check uses.
    ///
    /// It takes two steps, for reasons found by measuring on a real library. Picking the recent songs in AppleScript is slow (looping over
    /// 19,000 dates takes about four seconds), and Music's own filter (`whose played date > …`) leaves out some songs whose played date
    /// it does return when asked directly, which would hide exactly the plays this is meant to notice. So JavaScript for Automation reads
    /// every song's played date in one call and picks the recent ones with a day's margin, together with their names, artists, albums and
    /// counts. But its dates are not trustworthy to the hour (for a play from before a daylight-saving change they come back an hour
    /// early, which does not match Last.fm's own timestamps for the same play), so the exact dates of just those songs are then read in
    /// AppleScript, the way the whole-library read does, and the cut-off is applied to those.
    static func readRecentlyPlayed(days: Int) async throws -> AppleMusicSnapshot {
        guard isMusicRunning else { throw ReadError.musicNotRunning }
        let started = Date()
        let cutoff = started.addingTimeInterval(-Double(max(days, 1)) * 86_400)
        func items(_ column: String) -> [String] { column.isEmpty ? [] : column.components(separatedBy: itemSep) }
        // A song added or removed between the two steps would shift their positions; the second step notices and the pair is read again.
        for _ in 0..<2 {
            let first = try await AppleMusicMatcher.runAppleScript(recentCandidatesScript, arguments: [String(max(days, 1) + 1)], language: "JavaScript")
            let columns = first.trimmingCharacters(in: .newlines).components(separatedBy: columnSep)
            guard columns.count == 6, let total = Int(columns[0]) else { throw ReadError.unexpectedOutput }
            let positions = items(columns[1])
            let names = items(columns[2]), artists = items(columns[3]), albums = items(columns[4]), counts = items(columns[5])
            guard names.count == positions.count, artists.count == positions.count, albums.count == positions.count, counts.count == positions.count else {
                throw ReadError.unexpectedOutput
            }
            guard !positions.isEmpty else {
                return AppleMusicSnapshot(favorites: [], library: [], source: .favoritedFlag, readSeconds: Date().timeIntervalSince(started))
            }
            let second = try await AppleMusicMatcher.runAppleScript(
                exactDatesScript, arguments: [String(total), positions.joined(separator: ",")]
            )
            let dateText = second.trimmingCharacters(in: .newlines)
            if dateText == "MISMATCH" { continue }
            let dates = items(dateText)
            guard dates.count == positions.count else { throw ReadError.unexpectedOutput }
            var tracks: [AppleMusicSnapshot.Track] = []
            for i in 0..<positions.count {
                guard let seconds = Double(dates[i]) else { continue }
                let played = Date(timeIntervalSince1970: seconds)
                guard played > cutoff else { continue }
                tracks.append(AppleMusicSnapshot.Track(name: names[i], artist: artists[i], album: albums[i], lastPlayedAt: played, playCount: Int(counts[i]) ?? 0))
            }
            return AppleMusicSnapshot(favorites: [], library: tracks, source: .favoritedFlag, readSeconds: Date().timeIntervalSince(started))
        }
        throw ReadError.unexpectedOutput
    }

    /// Step one, in JavaScript for Automation: how many songs the library has, which of them (1-based positions) were played in the last
    /// `argv[0]` days by Music's own dates, and those songs' names, artists, albums and play counts.
    private static let recentCandidatesScript = """
    function run(argv) {
      var days = parseInt(argv[0] || "14", 10);
      var tracks = Application("Music").libraryPlaylists[0].tracks;
      var dates = tracks.playedDate();
      var cutoff = Date.now() - days * 86400000;
      var idx = [];
      for (var i = 0; i < dates.length; i++) { if (dates[i] && dates[i].getTime() > cutoff) idx.push(i); }
      var names = tracks.name(), artists = tracks.artist(), albums = tracks.album(), counts = tracks.playedCount();
      var rs = String.fromCharCode(30), gs = String.fromCharCode(29);
      function col(f) { var o = []; for (var k = 0; k < idx.length; k++) o.push(f(idx[k])); return o.join(rs); }
      return String(dates.length) + gs + col(function (i) { return String(i + 1); }) + gs + col(function (i) { return names[i]; }) + gs +
             col(function (i) { return artists[i]; }) + gs + col(function (i) { return albums[i]; }) + gs + col(function (i) { return counts[i]; });
    }
    """

    /// Step two, in AppleScript: the exact played dates (seconds since 1970, by the same arithmetic the whole-library read uses) of the songs
    /// at the given positions. Answers MISMATCH when the library no longer has the number of songs step one saw.
    private static let exactDatesScript = """
    on run argv
        set total to (item 1 of argv) as integer
        set idxText to item 2 of argv
        set rs to (ASCII character 30)
        set nowDate to current date
        set nowEpoch to (do shell script "date +%s") as integer
        tell application "Music" to set x to played date of every track of library playlist 1
        if (count of x) is not total then return "MISMATCH"
        set AppleScript's text item delimiters to ","
        set positions to text items of idxText
        set out to {}
        repeat with p in positions
            set dv to item ((p as text) as integer) of x
            if dv is missing value then
                set end of out to ""
            else
                set end of out to (nowEpoch - (nowDate - dv)) as integer
            end if
        end repeat
        set AppleScript's text item delimiters to rs
        set r to out as string
        set AppleScript's text item delimiters to ""
        return r
    end run
    """

    /// How many songs the library holds: one quick question, used to notice that songs were added or removed without reading everything.
    static func libraryTrackCount() async throws -> Int {
        guard isMusicRunning else { throw ReadError.musicNotRunning }
        let output = try await AppleMusicMatcher.runAppleScript("tell application \"Music\" to return count of tracks of library playlist 1", arguments: [])
        guard let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ReadError.unexpectedOutput }
        return count
    }

    /// Every song's artist, title, album, album artist, genre, tempo tag, length and the date it was added, for `AppleMusicDetailsIndex`. About six
    /// seconds on a 19,000-song library: JavaScript for Automation fetches the text columns in a moment, but its dates come back an hour off
    /// for songs from before a daylight-saving change, so the dates are read in AppleScript (whose arithmetic matches Last.fm's own
    /// timestamps, see `readRecentlyPlayed`), at the same time. Read-only; the two reads are checked to be of the same library.
    static func readLibraryDetails() async throws -> [AppleMusicDetailRow] {
        guard isMusicRunning else { throw ReadError.musicNotRunning }
        func items(_ column: String) -> [String] { column.isEmpty ? [] : column.components(separatedBy: itemSep) }
        for _ in 0..<2 {
            async let textRead = AppleMusicMatcher.runAppleScript(libraryTextScript, arguments: [], language: "JavaScript")
            async let dateRead = AppleMusicMatcher.runAppleScript(libraryDatesScript, arguments: [])
            let (text, dates) = try await (textRead, dateRead)
            let columns = text.trimmingCharacters(in: .newlines).components(separatedBy: columnSep)
            guard columns.count == 8, let total = Int(columns[0]) else { throw ReadError.unexpectedOutput }
            let names = items(columns[1]), artists = items(columns[2]), albumArtists = items(columns[3])
            let albums = items(columns[4]), genres = items(columns[5]), tempos = items(columns[6]), lengths = items(columns[7])
            // `items` drops an all-empty column to nothing, so a column that is empty for every song is rebuilt as that many blanks.
            func padded(_ list: [String]) -> [String] { list.isEmpty ? Array(repeating: "", count: total) : list }
            let albumArtistList = padded(albumArtists), albumList = padded(albums), genreList = padded(genres), tempoList = padded(tempos), lengthList = padded(lengths)
            let dateText = dates.trimmingCharacters(in: .newlines)
            if dateText == "MISMATCH" { continue }
            let dateList = items(dateText)
            guard names.count == total, artists.count == total, albumArtistList.count == total, albumList.count == total, genreList.count == total,
                  tempoList.count == total, lengthList.count == total, dateList.count == total else { continue }
            var rows: [AppleMusicDetailRow] = []
            rows.reserveCapacity(total)
            for i in 0..<total {
                let tempo = Int(Double(tempoList[i]) ?? 0)
                let length = Int((Double(lengthList[i]) ?? 0).rounded())
                var added: Date?
                if let seconds = Double(dateList[i]) { added = Date(timeIntervalSince1970: seconds) }
                rows.append(AppleMusicDetailRow(
                    artist: artists[i], title: names[i], album: albumList[i], albumArtist: albumArtistList[i], genre: genreList[i],
                    bpm: tempo, dateAdded: added, seconds: length
                ))
            }
            return rows
        }
        throw ReadError.unexpectedOutput
    }

    private static let libraryTextScript = """
    function run(argv) {
      var tracks = Application("Music").libraryPlaylists[0].tracks;
      var names = tracks.name(), artists = tracks.artist(), albumArtists = tracks.albumArtist(), albums = tracks.album(), genres = tracks.genre(), tempos = tracks.bpm(), lengths = tracks.duration();
      var rs = String.fromCharCode(30), gs = String.fromCharCode(29);
      return String(names.length) + gs + names.join(rs) + gs + artists.join(rs) + gs + albumArtists.join(rs) + gs + albums.join(rs) + gs + genres.join(rs) + gs + tempos.join(rs) + gs + lengths.join(rs);
    }
    """

    private static let libraryDatesScript = """
    set rs to (ASCII character 30)
    set nowDate to current date
    set nowEpoch to (do shell script "date +%s") as integer
    tell application "Music"
        set x to date added of every track of library playlist 1
        set total to count of x
    end tell
    set out to {}
    repeat with d in x
        set dv to contents of d
        if dv is missing value then
            set end of out to ""
        else
            set end of out to (nowEpoch - (nowDate - dv)) as integer
        end if
    end repeat
    set AppleScript's text item delimiters to rs
    set r to out as string
    set AppleScript's text item delimiters to ""
    return r
    """

    /// `includeAlbumArtist` and `includePlayed` (the played date and count) add more whole-library columns; callers that don't
    /// need them don't pay for them.
    static func read(includeCloudStatus: Bool = false, includeAlbumArtist: Bool = false, includePlayed: Bool = false) async throws -> AppleMusicSnapshot {
        guard isMusicRunning else { throw ReadError.musicNotRunning }
        let started = Date()
        let output = try await AppleMusicMatcher.runAppleScript(script(includeCloudStatus: includeCloudStatus, includeAlbumArtist: includeAlbumArtist, includePlayed: includePlayed), arguments: [])
        let columns = output.trimmingCharacters(in: .newlines).components(separatedBy: columnSep)
        guard columns.count == 15 else { throw ReadError.unexpectedOutput }
        func items(_ column: String) -> [String] { column.isEmpty ? [] : column.components(separatedBy: itemSep) }

        let libNames = items(columns[4]), libArtists = items(columns[5]), libAlbums = items(columns[6])
        guard libNames.count == libArtists.count, libNames.count == libAlbums.count else { throw ReadError.unexpectedOutput }
        let cloud = includeCloudStatus ? items(columns[8]) : []
        guard !includeCloudStatus || cloud.count == libNames.count else { throw ReadError.unexpectedOutput }
        // The IDs are only used to tell favorites that aren't in the library from ones that are; if they don't line up
        // with the names, leave them out rather than fail the whole read.
        let libAlbumArtists = includeAlbumArtist ? items(columns[12]) : []
        guard !includeAlbumArtist || libAlbumArtists.count == libNames.count else { throw ReadError.unexpectedOutput }
        let libPlayedAt = includePlayed ? items(columns[13]) : []
        let libPlayCounts = includePlayed ? items(columns[14]) : []
        guard !includePlayed || (libPlayedAt.count == libNames.count && libPlayCounts.count == libNames.count) else { throw ReadError.unexpectedOutput }
        let libIDs = items(columns[9]).compactMap { Int($0) }
        let hasLibIDs = libIDs.count == libNames.count
        let library = (0..<libNames.count).map {
            AppleMusicSnapshot.Track(
                name: libNames[$0], artist: libArtists[$0], album: libAlbums[$0], cloudStatus: includeCloudStatus ? cloud[$0] : "",
                databaseID: hasLibIDs ? libIDs[$0] : nil, albumArtist: includeAlbumArtist ? libAlbumArtists[$0] : "",
                lastPlayedAt: includePlayed ? Double(libPlayedAt[$0]).map { Date(timeIntervalSince1970: $0) } : nil,
                playCount: includePlayed ? (Int(libPlayCounts[$0]) ?? 0) : 0
            )
        }

        if columns[0] == "playlist" {
            let names = items(columns[1]), artists = items(columns[2]), albums = items(columns[3])
            guard names.count == artists.count, names.count == albums.count else { throw ReadError.unexpectedOutput }
            let favIDs = items(columns[10]).compactMap { Int($0) }
            let favClouds = items(columns[11])
            let hasFavIDs = favIDs.count == names.count && hasLibIDs
            let favorites = (0..<names.count).map {
                AppleMusicSnapshot.Track(
                    name: names[$0], artist: artists[$0], album: albums[$0],
                    cloudStatus: favClouds.count == names.count ? favClouds[$0] : "", databaseID: hasFavIDs ? favIDs[$0] : nil
                )
            }
            return AppleMusicSnapshot(favorites: favorites, library: library, source: .favoritesPlaylist, readSeconds: Date().timeIntervalSince(started))
        }
        let flags = items(columns[7])
        guard flags.count == library.count else { throw ReadError.unexpectedOutput }
        let favorites = zip(library, flags).compactMap { $1 == "true" ? $0 : nil }
        return AppleMusicSnapshot(favorites: favorites, library: library, source: .favoritedFlag, readSeconds: Date().timeIntervalSince(started))
    }
}
