import Foundation

/// What the engine needs from Music. `AppleMusicPlaylistBackend` is the real one (AppleScript); the checks use a stand-in that
/// keeps playlists in memory, so every rule below is tested without touching a real library.
protocol PlaylistBackend: Sendable {
    var isMusicRunning: Bool { get }
    /// The persistent ID of every track in the library.
    func libraryTrackIDs() async throws -> Set<String>
    /// Every library track, to match wanted tracks against (`LibraryMatcher`).
    func libraryTracks() async throws -> [LibraryTrack]
    func readPlaylist(id: String) async throws -> PlaylistReadResult
    /// Makes an empty playlist and returns its persistent ID.
    func createPlaylist(named name: String) async throws -> String
    /// Removes the tracks after the first `index` from the playlist (only from the playlist, never from the library). Throws
    /// `AutoPlaylistError.changedDuringRefresh` when the playlist no longer holds `expectedCount` tracks.
    func removeTail(id: String, from index: Int, expectedCount: Int) async throws
    /// Removes just these tracks (positions from 0) from the playlist, leaving the others in order. Like `removeTail`, only from the
    /// playlist, and it throws `AutoPlaylistError.changedDuringRefresh` when the playlist no longer holds `expectedCount` tracks.
    func removeIndexes(id: String, indexes: [Int], expectedCount: Int) async throws
    func append(id: String, trackIDs: [String]) async throws
}

struct LibraryTrack: Equatable, Sendable {
    let id: String
    let name: String
    let artist: String
    let album: String
}

enum PlaylistReadResult: Equatable, Sendable {
    case tracks([String])
    case missing
    case notEditable
}

enum AutoPlaylistError: Error, Equatable, Sendable {
    case notAuthorized
    case changedDuringRefresh
    case message(String)
}

struct AutoPlaylistRequest: Sendable {
    var name: String
    /// The playlist's persistent ID; nil or empty = make it.
    var playlistID: String?
    /// The wanted tracks in rank order.
    var tracks: [AppleMusicPlaylistTrack]
    var cache = AutoPlaylistMatchCache()
    /// Read and decide, change nothing (not even making the playlist).
    var dryRun = false
}

struct AutoPlaylistOutcome: Sendable, Equatable {
    var status: AutoPlaylistStatus
    var playlistID: String?
    /// How many tracks the playlist holds afterwards (would hold, for a dry run).
    var trackCount = 0
    var added = 0
    var removed = 0
    /// Wanted tracks the library doesn't have, and the first few of them as "Artist – Title".
    var missing = 0
    var missingSample: [String] = []
    /// Every wanted track the library doesn't have, as "Artist – Title" (the sample is its first few).
    var missingAll: [String] = []
    var droppedRepeats = 0
    var cache = AutoPlaylistMatchCache()
    var message = ""

    var detail: String {
        AutoPlaylistWording.detail(status: status, trackCount: trackCount, added: added, removed: removed, missing: missing, droppedRepeats: droppedRepeats, message: message)
    }
}

/// Makes one Apple Music playlist match a list of tracks, in order, without adding a song twice. Only ever changes the one
/// playlist it is given (found by its persistent ID), never the library; it never launches Music; and it leaves a playlist as it
/// is when the list comes out empty, so a list that failed to load can't empty a playlist.
enum AutoPlaylistEngine {
    /// How many tracks are added to Music in one go, so a long playlist can be stopped between pieces.
    static let appendChunk = 50
    static let missingSampleLimit = 20

    static func refresh(_ request: AutoPlaylistRequest, backend: PlaylistBackend) async -> AutoPlaylistOutcome {
        var outcome = AutoPlaylistOutcome(status: .failed, playlistID: request.playlistID, cache: request.cache)
        guard backend.isMusicRunning else { outcome.status = .musicNotRunning; return outcome }
        guard !request.tracks.isEmpty else { outcome.status = .emptyResult; return outcome }
        do {
            // 1. Which library track is each wanted track?
            let resolved = try await resolve(request.tracks, cache: request.cache, backend: backend)
            outcome.cache = resolved.cache
            let missingIndexes = resolved.ids.indices.filter { resolved.ids[$0] == nil }
            outcome.missing = missingIndexes.count
            outcome.missingAll = missingIndexes.map { "\(request.tracks[$0].artist) – \(request.tracks[$0].track)" }
            outcome.missingSample = Array(outcome.missingAll.prefix(missingSampleLimit))
            let unique = PlaylistDiff.droppingRepeats(resolved.ids.compactMap { $0 })
            outcome.droppedRepeats = unique.dropped
            let target = unique.ids
            guard !target.isEmpty else { outcome.status = .emptyResult; return outcome }

            // 2. What does the playlist hold now?
            var playlistID = request.playlistID ?? ""
            var current: [String] = []
            var madeNow = false
            if playlistID.isEmpty {
                if !request.dryRun { playlistID = try await backend.createPlaylist(named: request.name) }
                madeNow = true
            } else {
                switch try await backend.readPlaylist(id: playlistID) {
                case .missing: outcome.status = .playlistMissing; return outcome
                case .notEditable: outcome.status = .notEditable; return outcome
                case .tracks(let ids): current = ids
                }
            }
            outcome.playlistID = playlistID.isEmpty ? nil : playlistID

            // 3. Change as little as possible.
            let plan = PlaylistDiff.bestPlan(current: current, target: target)
            outcome.trackCount = target.count
            outcome.added = plan.append.count
            outcome.removed = plan.removalCount
            if plan.isNoOp { outcome.status = .upToDate; return outcome }
            outcome.status = madeNow ? .created : .updated
            if request.dryRun { return outcome }

            if let indexes = plan.removeIndexes {
                try await backend.removeIndexes(id: playlistID, indexes: indexes, expectedCount: current.count)
            } else if plan.removeCount > 0 {
                try await backend.removeTail(id: playlistID, from: plan.keep, expectedCount: current.count)
            }
            var offset = 0
            while offset < plan.append.count {
                try Task.checkCancellation()
                let piece = Array(plan.append[offset..<min(offset + appendChunk, plan.append.count)])
                try await backend.append(id: playlistID, trackIDs: piece)
                offset += piece.count
            }

            // 4. Read it back: what Music holds must be what was asked for.
            if case .tracks(let after) = try await backend.readPlaylist(id: playlistID), after == target {
                return outcome
            }
            outcome.status = .failed
            outcome.message = "Music's playlist didn't match after the update. It will be fixed on the next refresh."
            return outcome
        } catch AutoPlaylistError.notAuthorized {
            outcome.status = .notAuthorized
        } catch AutoPlaylistError.changedDuringRefresh {
            outcome.status = .failed
            outcome.message = "The playlist changed in Music while it was being updated. It will be tried again after the next sync."
        } catch is CancellationError {
            outcome.status = .failed
            outcome.message = "Stopped before it finished. It will be completed on the next refresh."
        } catch AutoPlaylistError.message(let text) {
            outcome.status = .failed
            outcome.message = text
        } catch {
            outcome.status = .failed
            outcome.message = error.localizedDescription
        }
        return outcome
    }

    /// The library track for each wanted track. A match found before is reused while the library still has it; the rest are looked up
    /// in the library in one read. Tracks the library doesn't have are not cached, so they are found as soon as they are added.
    static func resolve(_ tracks: [AppleMusicPlaylistTrack], cache: AutoPlaylistMatchCache, backend: PlaylistBackend) async throws -> (ids: [String?], cache: AutoPlaylistMatchCache) {
        let keys = tracks.map(AutoPlaylistMatchCache.key(for:))
        var ids = [String?](repeating: nil, count: tracks.count)
        var misses: [Int] = []
        if cache.ids.isEmpty {
            misses = Array(tracks.indices)
        } else {
            let library = try await backend.libraryTrackIDs()
            for index in tracks.indices {
                if let cached = cache.ids[keys[index]], library.contains(cached) { ids[index] = cached } else { misses.append(index) }
            }
        }
        if !misses.isEmpty {
            let index = LibraryMatcher.index(try await backend.libraryTracks())
            for slot in misses { ids[slot] = LibraryMatcher.find(tracks[slot], in: index) }
        }
        var fresh = AutoPlaylistMatchCache()
        for index in tracks.indices { if let id = ids[index] { fresh.ids[keys[index]] = id } }
        return (ids, fresh)
    }
}

/// Finds the library track a wanted track means: the same title and artist (case and the spaces at the ends ignored, nothing else),
/// preferring the one on the same album. The same rule the playlist export has always used.
enum LibraryMatcher {
    struct Index {
        fileprivate let bySong: [String: [LibraryTrack]]
    }

    private static func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private static func songKey(title: String, artist: String) -> String { "\(clean(artist))\u{241F}\(clean(title))" }

    static func index(_ library: [LibraryTrack]) -> Index {
        Index(bySong: Dictionary(grouping: library) { songKey(title: $0.name, artist: $0.artist) })
    }

    static func find(_ wanted: AppleMusicPlaylistTrack, in index: Index) -> String? {
        guard let sameSong = index.bySong[songKey(title: wanted.track, artist: wanted.artist)] else { return nil }
        let album = clean(wanted.album)
        if !album.isEmpty, let onAlbum = sameSong.first(where: { clean($0.album) == album }) { return onAlbum.id }
        return sameSong.first?.id
    }
}

/// One refresh at a time: two syncs that finish close together, or a refresh the person asks for during one, can't interleave their
/// changes to the same playlist.
actor AutoPlaylistRunner {
    static let shared = AutoPlaylistRunner()

    func refresh(_ request: AutoPlaylistRequest, backend: PlaylistBackend) async -> AutoPlaylistOutcome {
        await AutoPlaylistEngine.refresh(request, backend: backend)
    }
}

extension AutoPlaylist {
    /// Stores what a refresh did. A dry run is never recorded.
    func record(_ outcome: AutoPlaylistOutcome, at date: Date = Date()) {
        lastRefreshAt = date
        lastStatus = outcome.status.rawValue
        lastDetail = outcome.detail
        if outcome.status == .created || outcome.status == .updated { lastChangedAt = date }
        if let id = outcome.playlistID, !id.isEmpty { playlistPersistentID = id }
        // A refresh that never got as far as searching must not throw away what an earlier one found.
        if outcome.status != .musicNotRunning, outcome.status != .notAuthorized { matchCacheData = outcome.cache.encoded() }
        if outcome.status == .created || outcome.status == .updated || outcome.status == .upToDate {
            lastTrackCount = outcome.trackCount
            lastMissingCount = outcome.missing
            lastMissingSample = outcome.missingSample.joined(separator: "\n")
        }
    }

    var status: AutoPlaylistStatus { AutoPlaylistStatus(rawValue: lastStatus) ?? .neverRun }
}
