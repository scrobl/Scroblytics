import Foundation

/// The real Music behind `AutoPlaylistEngine`, driven by AppleScript. It reads in bulk where it can (one call for the ordered track
/// IDs of a playlist, one for the whole library), only changes the playlist it is given by persistent ID, removes tracks only from
/// that playlist (never from the library), and never launches Music.
enum PlaylistLookup: Equatable, Sendable {
    case none
    case found(id: String)
    case notEditable
}

struct AppleMusicPlaylistBackend: PlaylistBackend {
    private static let listSeparator = ","
    private static let columnSeparator = "\u{1D}"
    private static let itemSeparator = "\u{1E}"

    var isMusicRunning: Bool { AppleMusicFavoritesReader.isMusicRunning }

    func libraryTrackIDs() async throws -> Set<String> {
        let reply = try await run("""
        tell application "Music"
          set ids to persistent ID of every track of library playlist 1
          set AppleScript's text item delimiters to "\(Self.listSeparator)"
          return ids as string
        end tell
        """, [])
        return Set(Self.parseList(reply))
    }

    /// Every library track with the three things a wanted track is matched on. Read in bulk (a column at a time), which takes about a
    /// second for a large library; searching for each track one by one takes minutes for a long playlist.
    func libraryTracks() async throws -> [LibraryTrack] {
        let reply = try await run("""
        tell application "Music"
          set ns to name of every track of library playlist 1
          set ars to artist of every track of library playlist 1
          set als to album of every track of library playlist 1
          set ids to persistent ID of every track of library playlist 1
          set AppleScript's text item delimiters to "\(Self.itemSeparator)"
          set a to ns as string
          set b to ars as string
          set c to als as string
          set d to ids as string
          return a & "\(Self.columnSeparator)" & b & "\(Self.columnSeparator)" & c & "\(Self.columnSeparator)" & d
        end tell
        """, [])
        let columns = reply.trimmingCharacters(in: .newlines).components(separatedBy: Self.columnSeparator)
        guard columns.count == 4 else { throw AutoPlaylistError.message("Music gave an unexpected answer when reading the library.") }
        func items(_ text: String) -> [String] { text.isEmpty ? [] : text.components(separatedBy: Self.itemSeparator) }
        let names = items(columns[0]), artists = items(columns[1]), albums = items(columns[2]), ids = items(columns[3])
        guard names.count == ids.count, artists.count == ids.count, albums.count == ids.count else {
            throw AutoPlaylistError.message("Music gave an unexpected answer when reading the library.")
        }
        return ids.indices.map { LibraryTrack(id: ids[$0], name: names[$0], artist: artists[$0], album: albums[$0]) }
    }

    func readPlaylist(id: String) async throws -> PlaylistReadResult {
        let reply = try await run("""
        on run argv
          set pid to item 1 of argv
          tell application "Music"
            set matches to (every playlist whose persistent ID is pid)
            if (count of matches) is 0 then return "MISSING"
            set pl to item 1 of matches
            if class of pl is not user playlist then return "NOT EDITABLE"
            if smart of pl then return "NOT EDITABLE"
            set ids to persistent ID of every track of pl
            set AppleScript's text item delimiters to "\(Self.listSeparator)"
            return "OK:" & (ids as string)
          end tell
        end run
        """, [id])
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "MISSING" { return .missing }
        if text == "NOT EDITABLE" { return .notEditable }
        guard text.hasPrefix("OK:") else { throw AutoPlaylistError.message("Music gave an unexpected answer when reading the playlist.") }
        return .tracks(Self.parseList(String(text.dropFirst(3))))
    }

    func createPlaylist(named name: String) async throws -> String {
        let reply = try await run("""
        on run argv
          tell application "Music"
            set pl to make new user playlist with properties {name:(item 1 of argv)}
            return persistent ID of pl
          end tell
        end run
        """, [name])
        let id = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw AutoPlaylistError.message("Music didn't make the playlist.") }
        return id
    }

    func removeTail(id: String, from index: Int, expectedCount: Int) async throws {
        let reply = try await run("""
        on run argv
          set pid to item 1 of argv
          set keepCount to (item 2 of argv) as integer
          set expectedCount to (item 3 of argv) as integer
          tell application "Music"
            set matches to (every user playlist whose persistent ID is pid)
            if (count of matches) is 0 then return "MISSING"
            set pl to item 1 of matches
            if (count of tracks of pl) is not expectedCount then return "CHANGED"
            if expectedCount > keepCount then delete (tracks (keepCount + 1) thru -1 of pl)
            return "OK"
          end tell
        end run
        """, [id, String(index), String(expectedCount)])
        switch reply.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "OK": return
        case "CHANGED": throw AutoPlaylistError.changedDuringRefresh
        case "MISSING": throw AutoPlaylistError.message("The playlist is no longer in Music.")
        default: throw AutoPlaylistError.message("Music gave an unexpected answer when removing tracks.")
        }
    }

    func append(id: String, trackIDs: [String]) async throws {
        guard !trackIDs.isEmpty else { return }
        let reply = try await run("""
        on run argv
          set pid to item 1 of argv
          set AppleScript's text item delimiters to "\(Self.listSeparator)"
          set wanted to text items of (item 2 of argv)
          set AppleScript's text item delimiters to ""
          tell application "Music"
            set matches to (every user playlist whose persistent ID is pid)
            if (count of matches) is 0 then return "MISSING"
            set pl to item 1 of matches
            repeat with trackID in wanted
              set matchesForTrack to (every track of library playlist 1 whose persistent ID is (trackID as string))
              if (count of matchesForTrack) is 0 then return "NO TRACK " & trackID
              duplicate (item 1 of matchesForTrack) to pl
            end repeat
            return "OK"
          end tell
        end run
        """, [id, trackIDs.joined(separator: Self.listSeparator)])
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "OK" { return }
        if text == "MISSING" { throw AutoPlaylistError.message("The playlist is no longer in Music.") }
        if text.hasPrefix("NO TRACK") { throw AutoPlaylistError.message("A track is no longer in the Music library.") }
        throw AutoPlaylistError.message("Music gave an unexpected answer when adding tracks.")
    }

    /// The playlist with this name, to take over: its ID, or that there is none, or that Music can't change it. (Names are matched the
    /// way Music matches them, ignoring case; the first of several playlists with the same name is the one.)
    func findPlaylist(named name: String) async throws -> PlaylistLookup {
        let reply = try await run("""
        on run argv
          tell application "Music"
            set matches to (every user playlist whose name is (item 1 of argv))
            if (count of matches) is 0 then return "NONE"
            set pl to item 1 of matches
            if class of pl is not user playlist then return "NOT EDITABLE"
            if smart of pl then return "NOT EDITABLE"
            return "FOUND:" & (persistent ID of pl)
          end tell
        end run
        """, [name])
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "NONE" { return .none }
        if text == "NOT EDITABLE" { return .notEditable }
        guard text.hasPrefix("FOUND:") else { throw AutoPlaylistError.message("Music gave an unexpected answer when looking for the playlist.") }
        return .found(id: String(text.dropFirst(6)))
    }

    /// Shows the playlist in Music (selects it in the sidebar). Only when Music is already open; it never launches it.
    func reveal(id: String) async throws -> Bool {
        guard isMusicRunning else { return false }
        let reply = try await run("""
        on run argv
          tell application "Music"
            set matches to (every playlist whose persistent ID is (item 1 of argv))
            if (count of matches) is 0 then return "MISSING"
            reveal (item 1 of matches)
            activate
            return "OK"
          end tell
        end run
        """, [id])
        return reply.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
    }

    // MARK: - Running scripts

    /// Library and playlist IDs are hexadecimal text, so a comma-separated list is unambiguous.
    static func parseList(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : trimmed.components(separatedBy: listSeparator).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func run(_ script: String, _ arguments: [String]) async throws -> String {
        do {
            return try await AppleMusicMatcher.runAppleScript(script, arguments: arguments)
        } catch AppleMusicMatcher.MatchError.notAuthorized {
            throw AutoPlaylistError.notAuthorized
        } catch AppleMusicMatcher.MatchError.scriptFailed(let message) {
            throw AutoPlaylistError.message(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
