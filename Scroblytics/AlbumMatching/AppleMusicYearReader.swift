import Foundation

/// Reads each library track's name, artist, album artist, album and year from Music.app, a column at a time (one Apple Event per
/// property for the whole library, about a second for a library of nineteen thousand tracks). Read-only; never writes to Music, and
/// never launches it.
enum AppleMusicYearReader {
    private static let columnSep = "\u{1D}"
    private static let itemSep = "\u{1E}"

    private static let script = """
    set rs to (ASCII character 30)
    set gs to (ASCII character 29)
    tell application "Music"
        set ns to name of every track of library playlist 1
        set ars to artist of every track of library playlist 1
        set aas to album artist of every track of library playlist 1
        set als to album of every track of library playlist 1
        set ys to year of every track of library playlist 1
    end tell
    set AppleScript's text item delimiters to rs
    set o1 to ns as string
    set o2 to ars as string
    set o3 to aas as string
    set o4 to als as string
    set o5 to ys as string
    set AppleScript's text item delimiters to ""
    return o1 & gs & o2 & gs & o3 & gs & o4 & gs & o5
    """

    static func read() async throws -> [AppleMusicTrackYear] {
        guard AppleMusicFavoritesReader.isMusicRunning else { throw AppleMusicFavoritesReader.ReadError.musicNotRunning }
        let output = try await AppleMusicMatcher.runAppleScript(script, arguments: [])
        guard let tracks = parse(output) else { throw AppleMusicFavoritesReader.ReadError.unexpectedOutput }
        return tracks
    }

    /// The five columns joined by the group separator, each a list joined by the record separator. A year of 0 or none is "no year".
    static func parse(_ output: String) -> [AppleMusicTrackYear]? {
        let columns = output.trimmingCharacters(in: .newlines).components(separatedBy: columnSep)
        guard columns.count == 5 else { return nil }
        func items(_ column: String) -> [String] { column.isEmpty ? [] : column.components(separatedBy: itemSep) }
        let names = items(columns[0]), artists = items(columns[1]), albumArtists = items(columns[2]), albums = items(columns[3]), years = items(columns[4])
        guard artists.count == names.count, albumArtists.count == names.count, albums.count == names.count, years.count == names.count else { return nil }
        return names.indices.map { i in
            let year = Int(years[i].trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
            return AppleMusicTrackYear(name: names[i], artist: artists[i], albumArtist: albumArtists[i], album: albums[i], year: year)
        }
    }
}
