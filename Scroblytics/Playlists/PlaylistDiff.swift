import Foundation

/// How to turn the playlist Music holds into the one that is wanted, with as little change as Music's scripting allows.
///
/// Music can remove tracks from a playlist and add tracks to its end, but it cannot move a track inside a playlist. So the
/// plan keeps the longest run of tracks that already match at the top, removes everything after it, and adds the rest in rank
/// order. When tracks have only dropped out of the middle of a list (a goal's tracks being heard) it is cheaper to remove just those
/// tracks, which leaves the order of the rest alone; `bestPlan` picks whichever needs fewer changes. A playlist that already matches
/// needs no change at all; the worst case (a new #1) is a full rewrite of the same playlist.
enum PlaylistDiff {
    struct Plan: Equatable, Sendable {
        /// How many tracks at the top stay as they are.
        let keep: Int
        /// How many tracks after those are removed.
        let removeCount: Int
        /// What is added after the kept tracks, in order.
        let append: [String]
        /// When set, only these tracks (positions in the playlist, from 0, ascending) are removed, one by one, and the others stay where they
        /// are; `keep` is then how many of the target's first tracks are among those that stay. nil: everything after `keep` is removed.
        var removeIndexes: [Int]? = nil

        var isNoOp: Bool { removalCount == 0 && append.isEmpty }
        /// How many tracks are removed.
        var removalCount: Int { removeIndexes?.count ?? removeCount }
    }

    /// The plan that turns `current` (Music's track IDs, in playlist order) into `target`.
    static func plan(current: [String], target: [String]) -> Plan {
        var keep = 0
        let shared = min(current.count, target.count)
        while keep < shared, current[keep] == target[keep] { keep += 1 }
        return Plan(keep: keep, removeCount: current.count - keep, append: Array(target[keep...]))
    }

    /// The plan that needs the fewest changes: the tail plan above, or removing only the tracks that left when the target is the playlist
    /// minus those tracks plus new ones at the end. A removal of a range at the end counts as one change.
    static func bestPlan(current: [String], target: [String]) -> Plan {
        let tail = plan(current: current, target: target)
        if tail.isNoOp { return tail }
        // The longest start of the target that is still in the playlist, in the same order.
        var matched: [Int] = []
        var position = 0
        for wanted in target {
            while position < current.count, current[position] != wanted { position += 1 }
            if position == current.count { break }
            matched.append(position)
            position += 1
        }
        let stays = Set(matched)
        let removals = (0..<current.count).filter { !stays.contains($0) }
        let scatteredCost = removals.count + (target.count - matched.count)
        let tailCost = (tail.removeCount > 0 ? 1 : 0) + tail.append.count
        guard scatteredCost < tailCost else { return tail }
        return Plan(keep: matched.count, removeCount: removals.count, append: Array(target[matched.count...]), removeIndexes: removals)
    }

    /// What the playlist holds after the plan is carried out.
    static func apply(_ plan: Plan, to current: [String]) -> [String] {
        if let removeIndexes = plan.removeIndexes {
            let gone = Set(removeIndexes)
            return current.enumerated().filter { !gone.contains($0.offset) }.map(\.element) + plan.append
        }
        return Array(current.prefix(plan.keep)) + plan.append
    }

    /// The same list with each ID kept only the first time it appears (a song is never in the playlist twice), and how many were dropped.
    static func droppingRepeats(_ ids: [String]) -> (ids: [String], dropped: Int) {
        var seen = Set<String>()
        let kept = ids.filter { seen.insert($0).inserted }
        return (kept, ids.count - kept.count)
    }
}

/// What a refresh of one automatic playlist ended with.
enum AutoPlaylistStatus: String, Sendable, Equatable {
    case neverRun
    /// The playlist already matched; nothing was changed.
    case upToDate
    /// The playlist was made now.
    case created
    /// Tracks were added or removed.
    case updated
    case musicNotRunning
    case notAuthorized
    /// The playlist is not in Music any more (deleted, or Music's library was replaced).
    case playlistMissing
    /// Music cannot change this playlist (a smart playlist, or a folder).
    case notEditable
    /// The list came out empty, so the playlist was left as it was rather than emptied.
    case emptyResult
    case failed

    /// Needs the person's attention (shown in the list of playlists and in the sync report).
    var isProblem: Bool {
        switch self {
        case .neverRun, .upToDate, .created, .updated: false
        case .musicNotRunning, .notAuthorized, .playlistMissing, .notEditable, .emptyResult, .failed: true
        }
    }
}

/// Which library track each wanted track was matched to, so a refresh does not search the whole library again for tracks it
/// already found. A cached ID is trusted only while the library still has it.
struct AutoPlaylistMatchCache: Codable, Equatable, Sendable {
    var ids: [String: String] = [:]

    /// One wanted track's identity: artist, title and album, trimmed and lowercased (the album is part of it because a song on two
    /// albums can be two library tracks).
    static func key(for track: AppleMusicPlaylistTrack) -> String {
        func clean(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() }
        return "\(clean(track.artist))\u{241F}\(clean(track.track))\u{241F}\(clean(track.album))"
    }

    static func decode(_ data: Data?) -> AutoPlaylistMatchCache {
        guard let data, let cache = try? JSONDecoder().decode(AutoPlaylistMatchCache.self, from: data) else { return AutoPlaylistMatchCache() }
        return cache
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// The plain wording for a refresh, one place so the list of playlists, the sync report and the checks agree.
enum AutoPlaylistWording {
    static func detail(status: AutoPlaylistStatus, trackCount: Int, added: Int, removed: Int, missing: Int, droppedRepeats: Int = 0, message: String = "") -> String {
        func tracks(_ n: Int) -> String { n == 1 ? "1 track" : "\(n.formatted()) tracks" }
        var text: String
        switch status {
        case .neverRun: return "Not refreshed yet."
        case .upToDate: text = "Up to date, \(tracks(trackCount))."
        case .created: text = "Made with \(tracks(trackCount))."
        case .updated:
            var parts: [String] = []
            if added > 0 { parts.append("added \(tracks(added))") }
            if removed > 0 { parts.append("removed \(tracks(removed))") }
            text = "Updated: " + (parts.isEmpty ? "changed" : parts.joined(separator: ", ")) + ", now \(tracks(trackCount))."
        case .musicNotRunning: return "Music isn't open, so the playlist wasn't refreshed. It will be on the next sync after Music is open."
        case .notAuthorized: return "Scroblytics isn't allowed to control Music. Allow it in System Settings › Privacy & Security › Automation."
        case .playlistMissing: return "The playlist is no longer in Music. Stop updating it, or make it again."
        case .notEditable: return "Music can't change this playlist (it is a smart playlist or a folder)."
        case .emptyResult: return "The list is empty now, so the playlist was left as it was."
        case .failed: return message.isEmpty ? "The refresh failed." : "The refresh failed: \(message)"
        }
        if missing > 0 { text += " \(missing.formatted()) not in your library." }
        if droppedRepeats > 0 { text += " \(droppedRepeats.formatted()) repeated \(droppedRepeats == 1 ? "song" : "songs") left out." }
        return text
    }
}
