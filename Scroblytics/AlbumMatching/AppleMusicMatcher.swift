import Foundation

/// Reads album editions straight from the user's local Music.app library via
/// classic AppleScript (`osascript`) — this app has no MusicKit/Apple
/// Developer catalog integration anywhere (per the PRD's explicit callout that this project has
/// repeatedly and wrongly assumed MusicKit exists in past features). It does
/// the search/group/rank work with one AppleScript query shape, shared
/// field/entry separators and edition-grouping and ranking rules, reusing this
/// codebase's own `TextNormalization`.
enum AppleMusicMatcher {
    struct DurationRequest: Sendable {
        let key: String
        let artist: String
        let track: String
        let album: String?
    }

    struct DurationImportResult: Sendable {
        let matches: [String: Int]
        let libraryTrackCount: Int
        let unmatchedCount: Int
        let ambiguousCount: Int
    }

    struct Track: Sendable {
        let title: String
        let trackNumber: Int?
        let discNumber: Int?
        /// Runtime in whole seconds; nil when Music.app has no duration (e.g. an undownloaded cloud track).
        let seconds: Int?
    }

    struct Edition: Sendable {
        /// The exact raw album tag this edition's tracks carry in the library.
        let album: String
        let tracks: [Track]
        /// How many of this edition's distinct tracks match the user's already-
        /// scrobbled titles for this album group — a ranking hint, not a silent pick.
        let observedMatches: Int
    }

    enum MatchError: Error, LocalizedError {
        case scriptFailed(String)
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message):
                return "Couldn't search Music.app: \(message)"
            case .notAuthorized:
                return "Scroblytics isn't authorized to control Music.app. Grant access in System Settings > Privacy & Security > Automation."
            }
        }
    }

    private static let fieldSep = "\u{241F}" // ␟
    private static let entrySep = "\u{241E}" // ␞

    /// Every distinct edition of an album found in the user's local Music.app
    /// library — normally just one, but a library can hold more than one
    /// physical release under a similar name (see `groupIntoEditions`).
    /// Returns an empty array when nothing in the library matches this
    /// artist+album at all; the caller decides how to handle zero/one/many editions.
    /// `observedTitles` (the user's own already-scrobbled track titles for this
    /// album) ranks the most likely edition first — a hint, never a silent pick.
    static func findAlbumEditions(artist: String, album: String, observedTitles: [String]) async throws -> [Edition] {
        let script = """
        on trimText(t)
            set t to t as string
            repeat while (length of t > 0) and (t begins with " ")
                set t to text 2 thru (length of t) of t
            end repeat
            repeat while (length of t > 0) and (t ends with " ")
                set t to text 1 thru ((length of t) - 1) of t
            end repeat
            return t
        end trimText

        on run argv
            set targetArtist to item 1 of argv
            set searchText to item 2 of argv
            set candOut to {}
            tell application "Music"
                set candidates to {}
                try
                    set foundCandidates to (search library playlist 1 for searchText only songs)
                    if foundCandidates is not missing value then set candidates to foundCandidates
                end try
                repeat with c in candidates
                    set cAlbum to ""
                    set cArtist to ""
                    set cName to ""
                    try
                        set cAlbum to album of c
                        set cArtist to artist of c
                        set cName to name of c
                    end try
                    if cName is not "" and my trimText(cArtist) is targetArtist then
                        set cTrackNum to 0
                        set cDiscNum to 0
                        set cDuration to 0
                        try
                            set cTrackNum to track number of c
                        end try
                        try
                            set cDiscNum to disc number of c
                        end try
                        try
                            set cDuration to duration of c
                        end try
                        set end of candOut to (cName & "\(fieldSep)" & cAlbum & "\(fieldSep)" & (cTrackNum as string) & "\(fieldSep)" & (cDiscNum as string) & "\(fieldSep)" & (cDuration as string))
                    end if
                end repeat
            end tell
            set AppleScript's text item delimiters to "\(entrySep)"
            set outStr to candOut as string
            set AppleScript's text item delimiters to ""
            return outStr
        end run
        """

        let output = try await runAppleScript(script, arguments: [artist.trimmingCharacters(in: .whitespaces), album.trimmingCharacters(in: .whitespaces)])
        let candidates = parseCandidates(output)
        return groupIntoEditions(candidates, targetAlbum: album, observedTitles: observedTitles)
    }

    /// Finds a track in the user's Music.app library and returns its runtime.
    /// Matching is normalized in Swift so harmless title variants do not prevent
    /// an import. When multiple copies exist, the current album is preferred.
    static func findTrackDuration(artist: String, track: String, album: String?) async throws -> Int? {
        let script = """
        on run argv
            set searchText to item 1 of argv
            set candOut to {}
            tell application "Music"
                set candidates to {}
                try
                    set foundCandidates to (search library playlist 1 for searchText only songs)
                    if foundCandidates is not missing value then set candidates to foundCandidates
                end try
                repeat with c in candidates
                    set cName to ""
                    set cArtist to ""
                    set cAlbum to ""
                    set cDuration to 0
                    try
                        set cName to name of c
                        set cArtist to artist of c
                        set cAlbum to album of c
                        set cDuration to duration of c
                    end try
                    if cName is not "" and cDuration is greater than 0 then
                        set end of candOut to (cName & "\(fieldSep)" & cArtist & "\(fieldSep)" & cAlbum & "\(fieldSep)" & (cDuration as string))
                    end if
                end repeat
            end tell
            set AppleScript's text item delimiters to "\(entrySep)"
            set outStr to candOut as string
            set AppleScript's text item delimiters to ""
            return outStr
        end run
        """

        let output = try await runAppleScript(script, arguments: [track.trimmingCharacters(in: .whitespacesAndNewlines)])
        let targetArtist = TextNormalization.artistIdentityKey(artist)
        let targetTrack = TextNormalization.normalizeTrackTitle(track)
        let targetAlbum = album.map(TextNormalization.normalizeAlbumName)

        let matches = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: entrySep)
            .compactMap { entry -> (albumMatches: Bool, seconds: Int)? in
                let fields = entry.components(separatedBy: fieldSep)
                guard fields.count >= 4,
                      TextNormalization.artistIdentityKey(fields[1]) == targetArtist,
                      TextNormalization.normalizeTrackTitle(fields[0]) == targetTrack,
                      let seconds = Double(fields[3]).map({ Int($0.rounded()) }),
                      seconds > 0 else { return nil }
                let albumMatches = targetAlbum.map {
                    TextNormalization.normalizeAlbumName(fields[2]) == $0
                } ?? false
                return (albumMatches, seconds)
            }
            .sorted { lhs, rhs in lhs.albumMatches && !rhs.albumMatches }

        return matches.first?.seconds
    }

    /// Reads Music.app once and matches all requested tracks in memory. A match
    /// is accepted only when the preferred album, or all exact artist/title
    /// candidates, agree on one duration. Conflicting editions are left for
    /// manual review rather than silently choosing one.
    static func findTrackDurations(_ requests: [DurationRequest]) async throws -> DurationImportResult {
        guard !requests.isEmpty else {
            return DurationImportResult(matches: [:], libraryTrackCount: 0, unmatchedCount: 0, ambiguousCount: 0)
        }

        let script = """
        set candOut to {}
        tell application "Music"
            set candidateNames to name of every track of library playlist 1
            set candidateArtists to artist of every track of library playlist 1
            set candidateAlbums to album of every track of library playlist 1
            set candidateDurations to duration of every track of library playlist 1
            set candidateCount to count of candidateNames
            repeat with i from 1 to candidateCount
                set cName to ""
                set cArtist to ""
                set cAlbum to ""
                set cDuration to 0
                try
                    set cName to item i of candidateNames
                    set cArtist to item i of candidateArtists
                    set cAlbum to item i of candidateAlbums
                    set cDuration to item i of candidateDurations
                end try
                if cName is not "" and cArtist is not "" and cDuration is greater than 0 then
                    set end of candOut to (cName & "\(fieldSep)" & cArtist & "\(fieldSep)" & cAlbum & "\(fieldSep)" & (cDuration as string))
                end if
            end repeat
        end tell
        set AppleScript's text item delimiters to "\(entrySep)"
        set outStr to candOut as string
        set AppleScript's text item delimiters to ""
        return outStr
        """

        let output = try await runAppleScript(script, arguments: [])
        var candidatesByKey: [String: [(album: String, seconds: Int)]] = [:]
        var libraryTrackCount = 0
        for entry in output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: entrySep) {
            let fields = entry.components(separatedBy: fieldSep)
            guard fields.count >= 4,
                  let seconds = Double(fields[3]).map({ Int($0.rounded()) }),
                  seconds > 0 else { continue }
            libraryTrackCount += 1
            let key = durationMatchKey(artist: fields[1], track: fields[0])
            candidatesByKey[key, default: []].append((album: fields[2], seconds: seconds))
        }

        var matches: [String: Int] = [:]
        var unmatchedCount = 0
        var ambiguousCount = 0
        for request in requests {
            let matchKey = durationMatchKey(artist: request.artist, track: request.track)
            guard let candidates = candidatesByKey[matchKey], !candidates.isEmpty else {
                unmatchedCount += 1
                continue
            }

            let preferred = request.album.map(TextNormalization.normalizeAlbumName).flatMap { album in
                let albumMatches = candidates.filter { TextNormalization.normalizeAlbumName($0.album) == album }
                return albumMatches.isEmpty ? nil : albumMatches
            }
            let durations = Set((preferred ?? candidates).map(\.seconds))
            if durations.count == 1, let seconds = durations.first {
                matches[request.key] = seconds
            } else {
                ambiguousCount += 1
            }
        }

        return DurationImportResult(
            matches: matches,
            libraryTrackCount: libraryTrackCount,
            unmatchedCount: unmatchedCount,
            ambiguousCount: ambiguousCount
        )
    }

    /// The artist + normalized-title key this app matches Apple Music tracks by (also the Loved Status Audit's).
    static func durationMatchKey(artist: String, track: String) -> String {
        "\(TextNormalization.artistIdentityKey(artist))\u{0}\(TextNormalization.normalizeTrackTitle(track))"
    }

    // MARK: - AppleScript execution

    static func runAppleScript(_ script: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script] + arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                throw MatchError.scriptFailed(error.localizedDescription)
            }

            // Drain stdout while Music.app is producing it so a large library
            // cannot fill the pipe and deadlock before the process exits.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                if err.contains("-1743") || err.localizedCaseInsensitiveContains("not allowed") {
                    throw MatchError.notAuthorized
                }
                throw MatchError.scriptFailed(err.isEmpty ? "exit \(process.terminationStatus)" : err)
            }
            return out
        }.value
    }

    // MARK: - Parsing / grouping (`parseRawCandidates` / `groupIntoEditions` / `toAlbumTracks`)

    private struct RawCandidate {
        let title: String
        let album: String
        let trackNumber: Int?
        let discNumber: Int?
        let seconds: Int?
    }

    private static func parseCandidates(_ raw: String) -> [RawCandidate] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [RawCandidate] = []
        for entry in trimmed.components(separatedBy: entrySep) {
            let fields = entry.components(separatedBy: fieldSep)
            guard fields.count >= 5, !fields[0].isEmpty else { continue }
            let title = fields[0]
            let album = fields[1]
            let trackNumber = Int(fields[2]).flatMap { $0 > 0 ? $0 : nil }
            let discNumber = Int(fields[3]).flatMap { $0 > 0 ? $0 : nil }
            let seconds = Double(fields[4]).map { Int($0.rounded()) }.flatMap { $0 > 0 ? $0 : nil }
            out.append(RawCandidate(title: title, album: album, trackNumber: trackNumber, discNumber: discNumber, seconds: seconds))
        }
        return out
    }

    private static func groupIntoEditions(_ candidates: [RawCandidate], targetAlbum: String, observedTitles: [String]) -> [Edition] {
        var groups: [String: [RawCandidate]] = [:]
        var groupsOrdered: [String] = []
        for c in candidates {
            let key = TextNormalization.normalizeAlbumName(c.album)
            if groups[key] == nil { groupsOrdered.append(key) }
            groups[key, default: []].append(c)
        }

        let observedNorm = Set(observedTitles.map(TextNormalization.normalizeTrackTitle).filter { !$0.isEmpty })
        let normTarget = TextNormalization.normalizeAlbumName(targetAlbum)

        var editions: [Edition] = []
        for key in groupsOrdered {
            let group = groups[key]!
            let groupTitles = Set(group.map { TextNormalization.normalizeTrackTitle($0.title) })
            let observedMatches = groupTitles.filter { observedNorm.contains($0) }.count
            editions.append(Edition(album: group[0].album, tracks: toAlbumTracks(group), observedMatches: observedMatches))
        }

        editions.sort { a, b in
            if a.observedMatches != b.observedMatches { return a.observedMatches > b.observedMatches }
            let aExact = TextNormalization.normalizeAlbumName(a.album) == normTarget
            let bExact = TextNormalization.normalizeAlbumName(b.album) == normTarget
            if aExact != bExact { return aExact }
            return a.tracks.count > b.tracks.count
        }
        return editions
    }

    /// Dedups by disc+track number+title (some libraries carry the same album
    /// twice, e.g. an explicit and a clean copy) and sorts by disc then track number.
    private static func toAlbumTracks(_ candidates: [RawCandidate]) -> [Track] {
        var seen = Set<String>()
        var tracks: [Track] = []
        for c in candidates {
            let dedupeKey = "\(c.discNumber ?? 0)\u{0}\(c.trackNumber ?? 0)\u{0}\(c.title.lowercased())"
            if seen.contains(dedupeKey) { continue }
            seen.insert(dedupeKey)
            tracks.append(Track(title: c.title, trackNumber: c.trackNumber, discNumber: c.discNumber, seconds: c.seconds))
        }
        tracks.sort {
            ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0)
        }
        return tracks
    }
}
