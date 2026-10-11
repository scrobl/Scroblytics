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
    private static func script(includeCloudStatus: Bool) -> String {
    """
    set includeCloud to \(includeCloudStatus)
    set rs to (ASCII character 30)
    set gs to (ASCII character 29)
    set mode to "playlist"
    tell application "Music"
        set ln to name of every track of library playlist 1
        set la to artist of every track of library playlist 1
        set lb to album of every track of library playlist 1
        set lc to {}
        if includeCloud then set lc to cloud status of every track of library playlist 1
        set li to database ID of every track of library playlist 1
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
    set AppleScript's text item delimiters to ""
    return mode & gs & o1 & gs & o2 & gs & o3 & gs & o4 & gs & o5 & gs & o6 & gs & o7 & gs & o8 & gs & o9 & gs & o10 & gs & o11
    """
    }

    /// `includeCloudStatus` adds one more whole-library column (`cloud status`); the Loved Status Audit doesn't need it.
    static func read(includeCloudStatus: Bool = false) async throws -> AppleMusicSnapshot {
        guard isMusicRunning else { throw ReadError.musicNotRunning }
        let started = Date()
        let output = try await AppleMusicMatcher.runAppleScript(script(includeCloudStatus: includeCloudStatus), arguments: [])
        let columns = output.trimmingCharacters(in: .newlines).components(separatedBy: columnSep)
        guard columns.count == 12 else { throw ReadError.unexpectedOutput }
        func items(_ column: String) -> [String] { column.isEmpty ? [] : column.components(separatedBy: itemSep) }

        let libNames = items(columns[4]), libArtists = items(columns[5]), libAlbums = items(columns[6])
        guard libNames.count == libArtists.count, libNames.count == libAlbums.count else { throw ReadError.unexpectedOutput }
        let cloud = includeCloudStatus ? items(columns[8]) : []
        guard !includeCloudStatus || cloud.count == libNames.count else { throw ReadError.unexpectedOutput }
        // The IDs are only used to tell favorites that aren't in the library from ones that are; if they don't line up
        // with the names, leave them out rather than fail the whole read.
        let libIDs = items(columns[9]).compactMap { Int($0) }
        let hasLibIDs = libIDs.count == libNames.count
        let library = (0..<libNames.count).map {
            AppleMusicSnapshot.Track(
                name: libNames[$0], artist: libArtists[$0], album: libAlbums[$0], cloudStatus: includeCloudStatus ? cloud[$0] : "",
                databaseID: hasLibIDs ? libIDs[$0] : nil
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
