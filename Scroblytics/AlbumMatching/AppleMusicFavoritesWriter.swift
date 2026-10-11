import Foundation

/// The one thing in Scroblytics that changes Music: unfavoriting entries of the Favorite Songs playlist that are not in the
/// library (Loved Status Audit › "Not in library"). It only ever clears the favorite flag of the exact entries it is given;
/// it never touches library tracks, playlists or anything else, and it is only called after the person confirms.
///
/// Each entry is found by its Music `database ID` and is left alone unless its name and artist still match what the
/// person was shown, so a stale list can't unfavorite the wrong track. Music must already be running (it is never launched).
enum AppleMusicFavoritesWriter {
    struct Target: Sendable, Hashable {
        let id: Int
        let name: String
        let artist: String
    }

    enum Outcome: Sendable, Equatable {
        case removed
        /// A dry run: the entry was found and matched, and nothing was changed.
        case wouldRemove
        case notFound
        /// The entry with that ID has a different name or artist now; it was left alone. The text is what it is called now.
        case mismatch(String)
        case failed(String)
        case musicNotRunning

        var succeeded: Bool { self == .removed || self == .wouldRemove }
    }

    /// Reads the script's reply. (It reads nothing after the change: an unfavorited entry leaves the playlist at once.)
    nonisolated static func parse(_ reply: String) -> Outcome {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "REMOVED" { return .removed }
        if text == "WOULD REMOVE" { return .wouldRemove }
        if text.hasPrefix("NOT FOUND") { return .notFound }
        if text.hasPrefix("MISMATCH") { return .mismatch(String(text.dropFirst("MISMATCH".count)).trimmingCharacters(in: .whitespaces)) }
        return .failed(text.isEmpty ? "Music gave no answer" : text)
    }

    private static let script = """
    on run argv
      set theID to (item 1 of argv) as integer
      set expectedName to item 2 of argv
      set expectedArtist to item 3 of argv
      set isDry to (item 4 of argv) is "dry"
      tell application "Music"
        set matches to (every track of playlist "Favorite Songs" whose database ID is theID)
        if (count of matches) is 0 then return "NOT FOUND"
        set t to item 1 of matches
        set n to name of t
        set a to artist of t
        if n is not expectedName or a is not expectedArtist then return "MISMATCH " & n & " / " & a
        if isDry then return "WOULD REMOVE"
        set favorited of t to false
        return "REMOVED"
      end tell
    end run
    """

    /// Unfavorites each target in turn and reports what happened to each. With `dryRun` nothing is changed.
    static func unfavorite(_ targets: [Target], dryRun: Bool = false) async -> [(target: Target, outcome: Outcome)] {
        guard AppleMusicFavoritesReader.isMusicRunning else { return targets.map { ($0, .musicNotRunning) } }
        var results: [(target: Target, outcome: Outcome)] = []
        for target in targets {
            do {
                let reply = try await AppleMusicMatcher.runAppleScript(script, arguments: [String(target.id), target.name, target.artist, dryRun ? "dry" : "do"])
                results.append((target, parse(reply)))
            } catch {
                results.append((target, .failed(error.localizedDescription)))
            }
        }
        return results
    }
}
