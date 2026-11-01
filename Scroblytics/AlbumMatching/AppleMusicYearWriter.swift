import Foundation

/// What Music holds for one track, read just before a change.
struct MusicTrackState: Sendable, Equatable {
    let name: String
    let artist: String
    let year: Int?
}

/// How the year writer reaches Music: the real one speaks to Music.app, the checks use a stand-in with made-up tracks.
protocol MusicYearBackend: Sendable {
    var isMusicRunning: Bool { get }
    /// nil when Music has no track with that persistent ID.
    func currentTrack(persistentID: String) async throws -> MusicTrackState?
    func setYear(persistentID: String, year: Int) async throws
}

/// Sets the year of tracks in the Music library, to bring Music in line with the release years in Scroblytics (Release Year Audit ›
/// "Update Apple Music…"). It changes only the `year` of the exact tracks it is given, never anything else, and only after the person
/// confirms, every time (the confirmation is the caller's job). Music must already be running; it is never launched.
///
/// Each track is found by its persistent ID and is left alone unless its name and artist still match what the person was shown AND its
/// year is still the one they were shown: a list that has gone stale can't change the wrong track, or overwrite a year changed in Music
/// since. After a change the track is read again, so a track Music refuses to change (a streaming track that can't be edited) is reported
/// as not changed rather than assumed.
enum AppleMusicYearWriter {
    enum Outcome: Sendable, Equatable {
        case updated
        /// A dry run: the track was found, matched and would be changed; nothing was.
        case wouldUpdate
        case notFound
        /// The track with that ID has a different name or artist now; it was left alone. The text is what it is called now.
        case mismatch(String)
        /// Its year in Music is no longer the one that was shown (nil: none); it was left alone.
        case changedSince(Int?)
        /// Music did not take the change (the track can't be edited, or Music answered with an error).
        case failed(String)
        case musicNotRunning
        /// The run was stopped before this track.
        case notAttempted

        var succeeded: Bool { self == .updated || self == .wouldUpdate }
    }

    /// Changes each track in turn and reports what happened to each. With `dryRun` nothing is changed.
    static func apply(
        _ updates: [ReleaseYearAudit.MusicYearUpdate], dryRun: Bool = false, backend: MusicYearBackend = AppleScriptMusicYearBackend(),
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [(update: ReleaseYearAudit.MusicYearUpdate, outcome: Outcome)] {
        guard backend.isMusicRunning else { return updates.map { ($0, .musicNotRunning) } }
        var results: [(update: ReleaseYearAudit.MusicYearUpdate, outcome: Outcome)] = []
        for (index, update) in updates.enumerated() {
            // Stopping leaves the rest untouched; what was already changed stays changed.
            if Task.isCancelled { results.append((update, .notAttempted)); continue }
            progress?(index, updates.count)
            results.append((update, await apply(update, dryRun: dryRun, backend: backend)))
        }
        return results
    }

    /// About how long a change of this many tracks takes (Music answers in about a fifth of a second per track).
    static func estimate(tracks: Int) -> String? {
        let seconds = Double(tracks) * 0.2
        guard seconds >= 20 else { return nil }
        return seconds < 90 ? "about a minute" : "about \(Int((seconds / 60).rounded(.up))) minutes"
    }

    private static func apply(_ update: ReleaseYearAudit.MusicYearUpdate, dryRun: Bool, backend: MusicYearBackend) async -> Outcome {
        do {
            guard let now = try await backend.currentTrack(persistentID: update.persistentID) else { return .notFound }
            if now.name != update.name || now.artist != update.artist { return .mismatch("\(now.name) / \(now.artist)") }
            if now.year != update.from { return .changedSince(now.year) }
            if dryRun { return .wouldUpdate }
            try await backend.setYear(persistentID: update.persistentID, year: update.to)
            guard let after = try await backend.currentTrack(persistentID: update.persistentID), after.year == update.to else {
                return .failed("Music kept the old year (a track it can’t edit, such as a streaming track)")
            }
            return .updated
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A short summary of a run, for the screen.
    static func summary(_ results: [(update: ReleaseYearAudit.MusicYearUpdate, outcome: Outcome)]) -> String {
        func count(_ test: (Outcome) -> Bool) -> Int { results.filter { test($0.outcome) }.count }
        if results.allSatisfy({ $0.outcome == .musicNotRunning }), !results.isEmpty { return "Music isn’t open, so nothing was changed there. Open Music and try again." }
        let done = count { $0 == .updated || $0 == .wouldUpdate }
        var parts = ["Changed the year of \(done.formatted()) \(done == 1 ? "track" : "tracks") in Apple Music"]
        let stopped = count { $0 == .notAttempted }
        if stopped > 0 { parts.append("stopped before \(stopped.formatted()) more") }
        let changed = count { if case .changedSince = $0 { true } else { false } }
        let mismatched = count { if case .mismatch = $0 { true } else { false } }
        let missing = count { $0 == .notFound }
        let failed = count { if case .failed = $0 { true } else { false } }
        if changed > 0 { parts.append("\(changed.formatted()) left alone because their year in Music had changed since") }
        if mismatched > 0 { parts.append("\(mismatched.formatted()) left alone because they are named differently now") }
        if missing > 0 { parts.append("\(missing.formatted()) not found") }
        if failed > 0 {
            let why = results.compactMap { r -> String? in if case .failed(let text) = r.outcome { text } else { nil } }.first ?? ""
            parts.append("\(failed.formatted()) couldn’t be changed (\(why))")
        }
        return parts.joined(separator: "; ") + "."
    }
}

/// The real backend: Music.app through its scripting interface, one track at a time (each looked up by persistent ID).
struct AppleScriptMusicYearBackend: MusicYearBackend {
    var isMusicRunning: Bool { AppleMusicFavoritesReader.isMusicRunning }

    private static let readScript = """
    on run argv
      set pid to item 1 of argv
      set rs to (ASCII character 30)
      tell application "Music"
        set matches to (every track of library playlist 1 whose persistent ID is pid)
        if (count of matches) is 0 then return "NOT FOUND"
        set t to item 1 of matches
        return (name of t) & rs & (artist of t) & rs & ((year of t) as string)
      end tell
    end run
    """

    private static let writeScript = """
    on run argv
      set pid to item 1 of argv
      set newYear to (item 2 of argv) as integer
      tell application "Music"
        set matches to (every track of library playlist 1 whose persistent ID is pid)
        if (count of matches) is 0 then return "NOT FOUND"
        set year of (item 1 of matches) to newYear
        return "OK"
      end tell
    end run
    """

    func currentTrack(persistentID: String) async throws -> MusicTrackState? {
        let reply = try await AppleMusicMatcher.runAppleScript(Self.readScript, arguments: [persistentID]).trimmingCharacters(in: .newlines)
        if reply == "NOT FOUND" { return nil }
        let parts = reply.components(separatedBy: "\u{1E}")
        guard parts.count == 3 else { throw AppleMusicFavoritesReader.ReadError.unexpectedOutput }
        let year = Int(parts[2].trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        return MusicTrackState(name: parts[0], artist: parts[1], year: year)
    }

    func setYear(persistentID: String, year: Int) async throws {
        let reply = try await AppleMusicMatcher.runAppleScript(Self.writeScript, arguments: [persistentID, String(year)]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard reply == "OK" else { throw AppleMusicFavoritesReader.ReadError.unexpectedOutput }
    }
}
