import Foundation

/// A track as Music.app reports it for a playlist or the library. `duration` is in seconds (exact, from the file or
/// catalog entry — which is what tells a live cut from a reissue).
struct AppleMusicTrack: Sendable, Hashable {
    let name: String
    let artist: String
    let album: String
    let duration: Double
}

/// One of the user's Music playlists, as listed (no tracks yet).
struct AppleMusicPlaylistInfo: Sendable, Identifiable, Hashable {
    /// Music's `persistent ID` — stable across renames, unlike the name.
    let id: String
    let name: String
    /// A smart playlist's membership is computed by Music from rules, so it changes on its own.
    let isSmart: Bool
}

/// Reads playlists from Music.app in whole columns (one Apple Event per property for the whole list), like
/// `AppleMusicFavoritesReader`. A 968-track playlist reads in ~0.17 s with durations. Read-only; never launches Music.
enum AppleMusicPlaylistReader {
    typealias ReadError = AppleMusicFavoritesReader.ReadError

    private static let groupSep = "\u{1D}"
    private static let columnSep = "\u{1F}"
    private static let itemSep = "\u{1E}"

    /// Music's own "special" playlists (the library itself, Podcasts, …) and folders can't be tagged from, so
    /// only ordinary user playlists come back.
    private static let listScript = """
    set rs to (ASCII character 30)
    set us to (ASCII character 31)
    tell application "Music"
        set ids to persistent ID of every user playlist
        set ns to name of every user playlist
        set ks to special kind of every user playlist
        set ss to smart of every user playlist
        set cs to class of every user playlist
    end tell
    set out to {}
    repeat with i from 1 to (count of ids)
        if ((item i of ks) as string) is "none" and ((item i of cs) as string) is not "folder playlist" then
            set end of out to (item i of ids) & us & (item i of ns) & us & ((item i of ss) as string)
        end if
    end repeat
    set AppleScript's text item delimiters to rs
    set o to out as string
    set AppleScript's text item delimiters to ""
    return o
    """

    static func listPlaylists() async throws -> [AppleMusicPlaylistInfo] {
        guard AppleMusicFavoritesReader.isMusicRunning else { throw ReadError.musicNotRunning }
        let output = try await AppleMusicMatcher.runAppleScript(listScript, arguments: [])
        let text = output.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return [] }
        return try text.components(separatedBy: itemSep).map { item in
            let parts = item.components(separatedBy: columnSep)
            guard parts.count == 3 else { throw ReadError.unexpectedOutput }
            return AppleMusicPlaylistInfo(id: parts[0], name: parts[1], isSmart: parts[2] == "true")
        }
    }

    /// Tracks of one playlist, in playlist order. A playlist that no longer exists reads as an error, not as empty.
    private static let playlistScript = """
    on run argv
        set pid to item 1 of argv
        set rs to (ASCII character 30)
        set us to (ASCII character 31)
        tell application "Music"
            set p to (first user playlist whose persistent ID is pid)
            set n to name of every track of p
            set a to artist of every track of p
            set b to album of every track of p
            set d to duration of every track of p
        end tell
        set AppleScript's text item delimiters to rs
        set o1 to n as string
        set o2 to a as string
        set o3 to b as string
        set o4 to d as string
        set AppleScript's text item delimiters to ""
        return o1 & us & o2 & us & o3 & us & o4
    end run
    """

    static func readPlaylist(id: String) async throws -> [AppleMusicTrack] {
        guard AppleMusicFavoritesReader.isMusicRunning else { throw ReadError.musicNotRunning }
        let output = try await AppleMusicMatcher.runAppleScript(playlistScript, arguments: [id])
        return try parseColumns(output)
    }

    /// Every track in the library with durations — to find the OTHER versions of a playlist's tracks.
    private static let libraryScript = """
    set rs to (ASCII character 30)
    set us to (ASCII character 31)
    tell application "Music"
        set n to name of every track of library playlist 1
        set a to artist of every track of library playlist 1
        set b to album of every track of library playlist 1
        set d to duration of every track of library playlist 1
    end tell
    set AppleScript's text item delimiters to rs
    set o1 to n as string
    set o2 to a as string
    set o3 to b as string
    set o4 to d as string
    set AppleScript's text item delimiters to ""
    return o1 & us & o2 & us & o3 & us & o4
    """

    static func readLibrary() async throws -> [AppleMusicTrack] {
        guard AppleMusicFavoritesReader.isMusicRunning else { throw ReadError.musicNotRunning }
        let output = try await AppleMusicMatcher.runAppleScript(libraryScript, arguments: [])
        return try parseColumns(output)
    }

    private static func parseColumns(_ output: String) throws -> [AppleMusicTrack] {
        let columns = output.trimmingCharacters(in: .newlines).components(separatedBy: columnSep)
        guard columns.count == 4 else { throw ReadError.unexpectedOutput }
        func items(_ column: String) -> [String] { column.isEmpty ? [] : column.components(separatedBy: itemSep) }
        let names = items(columns[0]), artists = items(columns[1]), albums = items(columns[2]), durations = items(columns[3])
        guard names.count == artists.count, names.count == albums.count, names.count == durations.count else { throw ReadError.unexpectedOutput }
        return (0..<names.count).map { i in
            // AppleScript renders reals with the system's decimal mark.
            AppleMusicTrack(name: names[i], artist: artists[i], album: albums[i], duration: Double(durations[i].replacingOccurrences(of: ",", with: ".")) ?? 0)
        }
    }
}
