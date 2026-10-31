import AppKit
import Foundation
import SwiftData

#if DEBUG
/// A stand-in for Music that keeps its library and playlists in memory and records every call it gets, so the rules of
/// `AutoPlaylistEngine` can be tested without touching a real library. It behaves like Music's scripting: tracks can be removed
/// from a playlist and added to its end, never moved, and removing a track from a playlist never touches the library.
private final class FakeMusic: PlaylistBackend, @unchecked Sendable {
    struct Song { let id: String; let name: String; let artist: String; let album: String }
    struct Playlist { var name: String; var tracks: [String]; var smart = false }
    struct State {
        var running = true
        var library: [Song] = []
        var playlists: [String: Playlist] = [:]
        var calls: [String] = []
        var denyAccess = false
        /// Track IDs a playlist silently refuses to take (a stand-in for Music misbehaving).
        var refuses: Set<String> = []
        /// The nth append call (1-based) throws a cancellation, as if the task had been stopped.
        var cancelOnAppend: Int?
        var appendCalls = 0
        var nextPlaylist = 1
    }

    private let lock = NSLock()
    private var state = State()
    /// Runs just before a tail is removed, to change the playlist behind the engine's back.
    var beforeRemove: (@Sendable () -> Void)?

    func with<T>(_ body: (inout State) throws -> T) rethrows -> T { try lock.withLock { try body(&state) } }
    var calls: [String] { with { $0.calls } }
    func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
    func clearCalls() { with { $0.calls = [] } }
    func tracks(of id: String) -> [String] { with { $0.playlists[id]?.tracks ?? [] } }

    var isMusicRunning: Bool { with { $0.running } }

    private func log(_ text: String) throws {
        let denied = with { state -> Bool in state.calls.append(text); return state.denyAccess }
        if denied { throw AutoPlaylistError.notAuthorized }
    }

    func libraryTrackIDs() async throws -> Set<String> {
        try log("library")
        return with { Set($0.library.map(\.id)) }
    }

    func libraryTracks() async throws -> [LibraryTrack] {
        try log("tracks")
        return with { $0.library.map { LibraryTrack(id: $0.id, name: $0.name, artist: $0.artist, album: $0.album) } }
    }

    func readPlaylist(id: String) async throws -> PlaylistReadResult {
        try log("read")
        return with { state in
            guard let playlist = state.playlists[id] else { return .missing }
            return playlist.smart ? .notEditable : .tracks(playlist.tracks)
        }
    }

    func createPlaylist(named name: String) async throws -> String {
        try log("create \(name)")
        return with { state in
            let id = "P\(state.nextPlaylist)"
            state.nextPlaylist += 1
            state.playlists[id] = Playlist(name: name, tracks: [])
            return id
        }
    }

    func removeTail(id: String, from index: Int, expectedCount: Int) async throws {
        try log("remove \(index) of \(expectedCount)")
        beforeRemove?()
        let outcome = with { state -> Bool in
            guard var playlist = state.playlists[id], playlist.tracks.count == expectedCount else { return false }
            playlist.tracks = Array(playlist.tracks.prefix(index))
            state.playlists[id] = playlist
            return true
        }
        if !outcome { throw AutoPlaylistError.changedDuringRefresh }
    }

    func append(id: String, trackIDs: [String]) async throws {
        try log("append \(trackIDs.count)")
        let cancel = with { state -> Bool in state.appendCalls += 1; return state.cancelOnAppend == state.appendCalls }
        if cancel { throw CancellationError() }
        try with { state in
            guard var playlist = state.playlists[id] else { throw AutoPlaylistError.message("no playlist") }
            let known = Set(state.library.map(\.id))
            for trackID in trackIDs {
                guard known.contains(trackID) else { throw AutoPlaylistError.message("no track") }
                if state.refuses.contains(trackID) { continue }
                playlist.tracks.append(trackID)
            }
            state.playlists[id] = playlist
        }
    }
}

/// `SCROBLYTICS_AUTOPLAYLIST_CHECK=1`: the rules for keeping an Apple Music playlist up to date, against a stand-in Music with
/// made-up songs. Exits 0 on success.
///
/// Two read-only/dry-run hooks run the real Music code against a real library and are not part of release.sh:
/// `SCROBLYTICS_AUTOPLAYLIST_LIVE_READ=<playlist persistent ID>` (reads the playlist, then checks that finding each of its tracks in
/// the library gives back the same tracks, and that the plan for it is "nothing to change") and
/// `SCROBLYTICS_AUTOPLAYLIST_LIVE_WRITE=<playlist persistent ID>`, which makes and deletes a scratch playlist and is only run
/// with the owner's say-so.
enum AutoPlaylistChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let environment = ProcessInfo.processInfo.environment
        if environment["SCROBLYTICS_AUTOPLAYLIST_SOURCE_DUMP"] != nil {
            HeadlessTask.run("autoplaylist-source-dump") { try await sourceDump(container: container) }
            return
        }
        if let source = environment["SCROBLYTICS_AUTOPLAYLIST_LIVE_READ"] {
            HeadlessTask.run("autoplaylist-live-read") { try await liveRead(source: source) }
            return
        }
        if let source = environment["SCROBLYTICS_AUTOPLAYLIST_LIVE_WRITE"] {
            HeadlessTask.run("autoplaylist-live-write") { try await liveWrite(source: source) }
            return
        }
        guard environment["SCROBLYTICS_AUTOPLAYLIST_CHECK"] != nil else { return }
        HeadlessTask.run("autoplaylist-check") {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            diffChecks(check)
            await engineChecks(check)
            wordingAndCacheChecks(check)
            try modelAndBackupChecks(check)
            try await recipeChecks(check)
            try await schedulerChecks(check)
            try await toolChecks(check)
            HeadlessTask.finish(failures)
        }
    }

    // MARK: - The plan

    @MainActor
    private static func diffChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let same = PlaylistDiff.plan(current: ["a", "b", "c"], target: ["a", "b", "c"])
        check("a playlist that already matches needs no change", same.isNoOp && same.keep == 3)
        let appended = PlaylistDiff.plan(current: ["a", "b"], target: ["a", "b", "c", "d"])
        check("new tracks at the end are only added", appended == .init(keep: 2, removeCount: 0, append: ["c", "d"]))
        let shrunk = PlaylistDiff.plan(current: ["a", "b", "c", "d"], target: ["a", "b"])
        check("a shorter list only removes the tail", shrunk == .init(keep: 2, removeCount: 2, append: []))
        let swapped = PlaylistDiff.plan(current: ["a", "b", "c", "d"], target: ["a", "c", "b", "d"])
        check("a changed rank keeps the matching top and rewrites from the first difference", swapped == .init(keep: 1, removeCount: 3, append: ["c", "b", "d"]))
        let newFirst = PlaylistDiff.plan(current: ["a", "b", "c"], target: ["z", "a", "b", "c"])
        check("a new number one rewrites the whole playlist", newFirst == .init(keep: 0, removeCount: 3, append: ["z", "a", "b", "c"]))
        check("an empty playlist is filled", PlaylistDiff.plan(current: [], target: ["a"]) == .init(keep: 0, removeCount: 0, append: ["a"]))
        check("an emptied list removes everything", PlaylistDiff.plan(current: ["a", "b"], target: []) == .init(keep: 0, removeCount: 2, append: []))
        let repeats = PlaylistDiff.droppingRepeats(["a", "b", "a", "c", "b"])
        check("a song is kept once, at its first place", repeats.ids == ["a", "b", "c"] && repeats.dropped == 2)

        // Random lists over a small alphabet, so repeats and long shared tops both happen. The check is made independently of the
        // plan's own loop: carrying the plan out gives the target, the kept top really is shared, and no longer top would be.
        struct Lcg { var state: UInt64; mutating func next(_ bound: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(bound)) } }
        var rng = Lcg(state: 20260101)
        var bad = 0
        for _ in 0..<3_000 {
            let current = (0..<rng.next(9)).map { _ in String(rng.next(4)) }
            let target = (0..<rng.next(9)).map { _ in String(rng.next(4)) }
            let plan = PlaylistDiff.plan(current: current, target: target)
            let sharedTop = zip(current, target).prefix(while: { $0.0 == $0.1 }).count
            if PlaylistDiff.apply(plan, to: current) != target || plan.keep != sharedTop || plan.keep + plan.removeCount != current.count { bad += 1 }
        }
        check("3,000 random lists: carrying out the plan gives exactly the target, keeping the longest shared top", bad == 0, "\(bad) wrong")
    }

    // MARK: - The refresh, against the stand-in Music

    private static func song(_ n: Int) -> FakeMusic.Song {
        FakeMusic.Song(id: "S\(String(format: "%04d", n))", name: "Song \(n)", artist: n.isMultiple(of: 2) ? "Artist A" : "Artist B", album: "Album \(n % 7)")
    }
    private static func wanted(_ numbers: [Int]) -> [AppleMusicPlaylistTrack] {
        numbers.map { AppleMusicPlaylistTrack(artist: $0.isMultiple(of: 2) ? "Artist A" : "Artist B", track: "Song \($0)", album: "Album \($0 % 7)") }
    }
    private static func ids(_ numbers: [Int]) -> [String] { numbers.map { song($0).id } }

    @MainActor
    private static func engineChecks(_ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func makeMusic(songs: Int = 300) -> FakeMusic {
            let music = FakeMusic()
            music.with { $0.library = (1...songs).map(song) }
            return music
        }

        // Not open, empty list
        do {
            let music = makeMusic()
            music.with { $0.running = false }
            let outcome = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: nil, tracks: wanted([1, 2])), backend: music)
            check("Music not open: nothing is attempted", outcome.status == .musicNotRunning && music.calls.isEmpty, "\(outcome.status) \(music.calls)")
            music.with { $0.running = true }
            let empty = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: nil, tracks: []), backend: music)
            check("an empty list makes no playlist", empty.status == .emptyResult && music.calls.isEmpty)
        }

        // First fill, then the same list again, then changes
        do {
            let music = makeMusic()
            let top = Array(1...120)
            var request = AutoPlaylistRequest(name: "Top", playlistID: nil, tracks: wanted(top))
            var outcome = await AutoPlaylistEngine.refresh(request, backend: music)
            let playlistID = outcome.playlistID ?? ""
            check("first refresh makes the playlist in rank order", outcome.status == .created && music.tracks(of: playlistID) == ids(top) && outcome.trackCount == 120 && outcome.added == 120, "\(outcome.status) \(outcome.detail)")
            check("a long list is added in pieces of \(AutoPlaylistEngine.appendChunk)", music.count("append") == 3, music.calls.joined(separator: ", "))
            request.playlistID = playlistID
            request.cache = outcome.cache
            check("the match cache holds each track, and the library was read once", outcome.cache.ids.count == 120 && music.count("tracks") == 1)

            music.clearCalls()
            outcome = await AutoPlaylistEngine.refresh(request, backend: music)
            check("the same list again changes nothing and adds no song twice", outcome.status == .upToDate && music.count("append") == 0 && music.count("remove") == 0 && music.tracks(of: playlistID) == ids(top))
            check("…and does not read the library's tracks again (the cache is used, only checked against the library's IDs)", music.count("tracks") == 0 && music.count("library") == 1, music.calls.joined(separator: ", "))

            // Two tracks swap places at ranks 10 and 11
            var swapped = top
            swapped.swapAt(9, 10)
            request.tracks = wanted(swapped)
            music.clearCalls()
            outcome = await AutoPlaylistEngine.refresh(request, backend: music)
            check("a swapped rank keeps the first 9 and rewrites the rest in order", outcome.status == .updated && music.tracks(of: playlistID) == ids(swapped) && outcome.removed == 111 && outcome.added == 111, "\(outcome.removed)/\(outcome.added)")
            check("…without a repeated song", Set(music.tracks(of: playlistID)).count == music.tracks(of: playlistID).count)
            check("…and the library is untouched", music.with { $0.library.count } == 300)

            // A new number one
            let newFirst = [200] + top.dropLast()
            request.tracks = wanted(newFirst)
            outcome = await AutoPlaylistEngine.refresh(request, backend: music)
            check("a new number one rewrites the same playlist", outcome.status == .updated && music.tracks(of: playlistID) == ids(newFirst) && outcome.playlistID == playlistID)
            check("…and it stays the one playlist", music.with { $0.playlists.count } == 1)

            // The list gets shorter
            request.tracks = wanted(Array(newFirst.prefix(40)))
            music.clearCalls()
            outcome = await AutoPlaylistEngine.refresh(request, backend: music)
            check("a shorter list only removes the tail", outcome.status == .updated && music.count("append") == 0 && music.tracks(of: playlistID) == ids(Array(newFirst.prefix(40))) && outcome.removed == 80 && outcome.added == 0)

            // A dry run
            request.tracks = wanted(Array(1...30))
            music.clearCalls()
            let before = music.tracks(of: playlistID)
            func dryRun(_ base: AutoPlaylistRequest) async -> AutoPlaylistOutcome {
                var copy = base
                copy.dryRun = true
                return await AutoPlaylistEngine.refresh(copy, backend: music)
            }
            let dry = await dryRun(request)
            check("a dry run reports the change and makes none", dry.status == .updated && dry.added > 0 && music.tracks(of: playlistID) == before && music.count("append") == 0 && music.count("remove") == 0 && music.count("create") == 0)
            let dryNew = await dryRun(AutoPlaylistRequest(name: "Not made", playlistID: nil, tracks: wanted([1, 2])))
            check("a dry run does not make the playlist", dryNew.status == .created && music.count("create") == 0 && music.with { $0.playlists.count } == 1)
        }

        // Tracks the library doesn't have, and repeats
        do {
            let music = makeMusic(songs: 50)
            let tracks = wanted([1, 2, 900, 3, 901, 4, 2])
            let outcome = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: nil, tracks: tracks), backend: music)
            let playlistID = outcome.playlistID ?? ""
            check("tracks not in the library are skipped and the rest keep their order", music.tracks(of: playlistID) == ids([1, 2, 3, 4]), "\(music.tracks(of: playlistID))")
            check("…they are counted and named", outcome.missing == 2 && outcome.missingSample == ["Artist A – Song 900", "Artist B – Song 901"], "\(outcome.missingSample)")
            check("a song listed twice is added once", outcome.droppedRepeats == 1 && outcome.trackCount == 4)
            check("the wording mentions both", outcome.detail.contains("2 not in your library") && outcome.detail.contains("1 repeated song left out"), outcome.detail)
            check("a missing track is not cached (and a repeated one is cached once)", outcome.cache.ids.count == 4, "\(outcome.cache.ids.count)")

            // It turns up in the library later
            music.with { $0.library.append(song(900)) }
            let again = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: playlistID, tracks: tracks, cache: outcome.cache), backend: music)
            check("a track added to the library later is found on the next refresh", music.tracks(of: playlistID) == ids([1, 2, 900, 3, 4]) && again.missing == 1, "\(music.tracks(of: playlistID))")

            // Removed from the library: the cached ID is not trusted
            music.with { $0.library.removeAll { $0.id == song(3).id } }
            music.clearCalls()
            let gone = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: playlistID, tracks: tracks, cache: again.cache), backend: music)
            check("a track that left the library is searched for again, not trusted from the cache", music.count("tracks") == 1 && gone.missing == 2, music.calls.joined(separator: ", "))
        }

        // Nothing found at all leaves the playlist alone
        do {
            let music = makeMusic(songs: 10)
            let first = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: nil, tracks: wanted([1, 2, 3])), backend: music)
            let playlistID = first.playlistID ?? ""
            let none = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: playlistID, tracks: wanted([700, 701]), cache: first.cache), backend: music)
            check("a list with nothing in the library does not empty the playlist", none.status == .emptyResult && music.tracks(of: playlistID) == ids([1, 2, 3]))
        }

        // The playlist is gone, or can't be changed
        do {
            let music = makeMusic()
            let gone = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: "NOPE", tracks: wanted([1, 2])), backend: music)
            check("a deleted playlist is reported, not remade", gone.status == .playlistMissing && music.count("create") == 0 && music.count("append") == 0)
            music.with { $0.playlists["SMART"] = .init(name: "Smart", tracks: ids([5]), smart: true) }
            let smart = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: "SMART", tracks: wanted([1, 2])), backend: music)
            check("a smart playlist is never changed", smart.status == .notEditable && music.tracks(of: "SMART") == ids([5]) && music.count("remove") == 0 && music.count("append") == 0)
        }

        // Things that go wrong
        do {
            let music = makeMusic()
            music.with { $0.denyAccess = true }
            let denied = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: nil, tracks: wanted([1])), backend: music)
            check("a refusal to control Music is reported as such", denied.status == .notAuthorized && denied.detail.contains("Automation"))

            music.with { $0.denyAccess = false }
            let first = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: nil, tracks: wanted([1, 2, 3, 4])), backend: music)
            let playlistID = first.playlistID ?? ""
            // The person edits the playlist in Music while a refresh is under way
            music.beforeRemove = { music.with { $0.playlists[playlistID]?.tracks.append(song(99).id) } }
            let changed = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: playlistID, tracks: wanted([1, 2, 9, 8]), cache: first.cache), backend: music)
            check("a playlist edited during the refresh is not guessed at", changed.status == .failed && changed.message.contains("changed in Music"), changed.detail)
            music.beforeRemove = nil
            let healed = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: playlistID, tracks: wanted([1, 2, 9, 8]), cache: changed.cache), backend: music)
            check("…and the next refresh puts it right", healed.status == .updated && music.tracks(of: playlistID) == ids([1, 2, 9, 8]))

            // Music silently refuses a track
            music.with { $0.refuses = [song(7).id] }
            let short = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: playlistID, tracks: wanted([1, 2, 7, 8]), cache: healed.cache), backend: music)
            check("if Music ends up with something else, that is reported", short.status == .failed && short.message.contains("didn't match"), short.detail)
            music.with { $0.refuses = [] }
            let fixed = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: playlistID, tracks: wanted([1, 2, 7, 8]), cache: short.cache), backend: music)
            check("…and the next refresh puts it right", fixed.status == .updated && music.tracks(of: playlistID) == ids([1, 2, 7, 8]))
        }

        // Stopping part way through a long list
        do {
            let music = makeMusic()
            music.with { $0.cancelOnAppend = 2 }
            let tracks = wanted(Array(1...120))
            let stopped = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: nil, tracks: tracks), backend: music)
            let playlistID = stopped.playlistID ?? ""
            check("stopping part way is reported and keeps what was added so far", stopped.status == .failed && stopped.message.contains("Stopped") && music.tracks(of: playlistID) == ids(Array(1...50)), "\(music.tracks(of: playlistID).count)")
            let finished = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: playlistID, tracks: tracks, cache: stopped.cache), backend: music)
            check("…and the next refresh adds only the rest", finished.status == .updated && finished.added == 70 && music.tracks(of: playlistID) == ids(Array(1...120)), "\(finished.added)")
        }

        // Several hundred tracks
        do {
            let music = makeMusic(songs: 1_200)
            let big = Array(1...1_000)
            let outcome = await AutoPlaylistEngine.refresh(.init(name: "T", playlistID: nil, tracks: wanted(big)), backend: music)
            check("a thousand-track list is made in order, in \(1_000 / AutoPlaylistEngine.appendChunk) pieces", music.tracks(of: outcome.playlistID ?? "") == ids(big) && music.count("append") == 20)
        }
    }

    // MARK: - Wording, cache

    @MainActor
    private static func wordingAndCacheChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        typealias W = AutoPlaylistWording
        check("up to date wording", W.detail(status: .upToDate, trackCount: 100, added: 0, removed: 0, missing: 0) == "Up to date, 100 tracks.")
        check("made wording, singular", W.detail(status: .created, trackCount: 1, added: 1, removed: 0, missing: 0) == "Made with 1 track.")
        check("updated wording", W.detail(status: .updated, trackCount: 100, added: 3, removed: 1, missing: 0) == "Updated: added 3 tracks, removed 1 track, now 100 tracks.")
        check("problem statuses are marked", AutoPlaylistStatus.musicNotRunning.isProblem && AutoPlaylistStatus.emptyResult.isProblem && !AutoPlaylistStatus.upToDate.isProblem && !AutoPlaylistStatus.updated.isProblem)
        check("failed wording carries the reason", W.detail(status: .failed, trackCount: 0, added: 0, removed: 0, missing: 0, message: "no").contains("failed: no"))
        let a = AppleMusicPlaylistTrack(artist: "  Artist A ", track: "Song  1", album: "Album")
        let b = AppleMusicPlaylistTrack(artist: "artist a", track: "song 1", album: "ALBUM")
        check("a track's cache key ignores case and spacing", AutoPlaylistMatchCache.key(for: a) == AutoPlaylistMatchCache.key(for: b))
        check("…but not the album", AutoPlaylistMatchCache.key(for: a) != AutoPlaylistMatchCache.key(for: .init(artist: "Artist A", track: "Song 1", album: "Other")))
        var cache = AutoPlaylistMatchCache()
        cache.ids["k"] = "ID1"
        check("the cache survives encoding", AutoPlaylistMatchCache.decode(cache.encoded()) == cache)
        check("garbage in the cache column is an empty cache", AutoPlaylistMatchCache.decode(Data("nope".utf8)).ids.isEmpty && AutoPlaylistMatchCache.decode(nil).ids.isEmpty)
        let library = [
            LibraryTrack(id: "1", name: "Song One", artist: "Artist A", album: "Album X"),
            LibraryTrack(id: "2", name: "Song One", artist: "Artist A", album: "Album Y"),
            LibraryTrack(id: "3", name: "Täg 東京 🎵", artist: "Artist B", album: ""),
        ]
        let index = LibraryMatcher.index(library)
        func find(_ artist: String, _ track: String, _ album: String) -> String? { LibraryMatcher.find(.init(artist: artist, track: track, album: album), in: index) }
        check("matching: the song on the wanted album", find("Artist A", "Song One", "Album Y") == "2")
        check("matching: the first one when the album is not given or not found", find("Artist A", "Song One", "") == "1" && find("Artist A", "Song One", "Album Z") == "1")
        check("matching: case and the spaces at the ends are ignored", find("ARTIST a ", "  song one", "album y") == "2")
        check("matching: another artist or a longer title is not the same song", find("Artist B", "Song One", "") == nil && find("Artist A", "Song One (Live)", "") == nil)
        check("matching: other alphabets and emoji", find("Artist B", "Täg 東京 🎵", "") == "3")
        check("Music's lists of IDs are read", AppleMusicPlaylistBackend.parseList("A1,B2, C3\n") == ["A1", "B2", "C3"] && AppleMusicPlaylistBackend.parseList("  ").isEmpty)
    }

    // MARK: - Saved playlists and backups

    @MainActor
    private static func modelAndBackupChecks(_ report: (String, Bool, String) -> Void) throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let container = try ModelContainer(for: AutoPlaylist.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let recipe = Data("{\"kind\":\"test\"}".utf8)
        let list = AutoPlaylist(name: "Top 100 of 2026", recipeKind: "test", recipeData: recipe, sourceSummary: "Top tracks · 2026 · 100")
        context.insert(list)
        check("a new playlist has never been refreshed", list.status == .neverRun && list.lastRefreshAt == nil && list.isEnabled)

        let day = Date(timeIntervalSince1970: 1_800_000_000)
        var outcome = AutoPlaylistOutcome(status: .updated, playlistID: "PID1", trackCount: 98, added: 5, removed: 5, missing: 2, missingSample: ["Artist A – Song 9", "Artist B – Song 8"])
        outcome.cache.ids["k"] = "ID9"
        list.record(outcome, at: day)
        check("a refresh is recorded", list.status == .updated && list.playlistPersistentID == "PID1" && list.lastTrackCount == 98 && list.lastMissingCount == 2 && list.lastChangedAt == day && list.lastRefreshAt == day, list.lastDetail)
        check("…with the missing tracks named, one per line", list.lastMissingSample == "Artist A – Song 9\nArtist B – Song 8")
        check("…and the match cache kept", AutoPlaylistMatchCache.decode(list.matchCacheData).ids == ["k": "ID9"])

        let later = day.addingTimeInterval(3_600)
        list.record(AutoPlaylistOutcome(status: .musicNotRunning, playlistID: "PID1", cache: .init()), at: later)
        check("a refresh that couldn't start keeps the earlier cache and counts", AutoPlaylistMatchCache.decode(list.matchCacheData).ids == ["k": "ID9"] && list.lastTrackCount == 98 && list.lastChangedAt == day && list.lastRefreshAt == later)
        list.record(AutoPlaylistOutcome(status: .upToDate, playlistID: "PID1", trackCount: 98, cache: .init()), at: later)
        check("an up-to-date refresh does not move the changed date", list.lastChangedAt == day)

        // Backup
        let records = try NativeBackupEngine.autoPlaylistRecords(context: context)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode([NativeBackupFormat.AutoPlaylistRecord].self, from: encoder.encode(records))
        let id = list.id
        context.delete(list)
        try context.save()
        try NativeBackupEngine.restoreAutoPlaylists(round, context: context)
        let restored = try context.fetch(FetchDescriptor<AutoPlaylist>())
        check("a backup round trip brings the playlist back", restored.count == 1 && restored[0].id == id && restored[0].name == "Top 100 of 2026" && restored[0].recipeData == recipe && restored[0].sourceSummary == "Top tracks · 2026 · 100" && restored[0].playlistPersistentID == "PID1" && restored[0].isEnabled)
        check("…refreshed from scratch (status and cache are not backed up)", restored[0].status == .neverRun && restored[0].matchCacheData == nil)
        try NativeBackupEngine.restoreAutoPlaylists(nil, context: context)
        check("an older archive without playlists leaves the current ones alone", try context.fetch(FetchDescriptor<AutoPlaylist>()).count == 1)
        try NativeBackupEngine.restoreAutoPlaylists([round[0], round[0]], context: context)
        check("a repeated playlist in an archive is restored once", try context.fetch(FetchDescriptor<AutoPlaylist>()).count == 1)
        check("the backup summary counts them", NativeBackupEngine.Summary(albums: 0, tracks: 0, customImages: 0, flaggedTracks: 0, savedQueries: 0, autoPlaylists: 2).description.contains("2 automatic playlists"))
    }


    // MARK: - Recipes, the scheduler, making a playlist

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private static func recipeList(_ n: Int) -> AutoPlaylistRecipe {
        .topCharts(TopChartsPlaylistRecipe(entity: .track, rangeID: "year-2026", metric: .scrobbles, rowLimit: n))
    }

    @MainActor
    private static func recipeChecks(_ report: (String, Bool, String) -> Void) async throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let chart = AutoPlaylistRecipe.topCharts(TopChartsPlaylistRecipe(entity: .album, rangeID: "last30", metric: .timeListened, rowLimit: 25))
        let chartBack = AutoPlaylistRecipe(kind: chart.kind, data: try chart.encodedData())
        check("a Top Charts recipe survives saving", chartBack == chart && chart.kind == "topCharts")
        var spec = QuerySpec(target: .track)
        spec.period = QueryPeriod(from: Date(timeIntervalSince1970: 1_700_000_000), to: Date(timeIntervalSince1970: 1_730_000_000))
        spec.limit = 100
        spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
        let query = AutoPlaylistRecipe.query(spec)
        check("a Query recipe survives saving", AutoPlaylistRecipe(kind: query.kind, data: try query.encodedData()) == query && query.kind == "query")
        let recent = AutoPlaylistRecipe.mostRecentMostOften(MostRecentMostOftenPlaylistRecipe(windowDays: 90, minPlays: 5, sort: .velocity, rowLimit: 50))
        check("a Most Recent, Most Often recipe survives saving", AutoPlaylistRecipe(kind: recent.kind, data: try recent.encodedData()) == recent && recent.kind == "mostRecentMostOften")
        check("…and describes itself", MostRecentMostOftenPlaylistRecipe(windowDays: 90, minPlays: 5, sort: .velocity, rowLimit: 50).summary == "Most Recent, Most Often · discovered in the last 90 days · 5+ plays · by speed · 50 rows" && MostRecentMostOftenPlaylistRecipe(windowDays: 30, minPlays: 1, sort: .plays, rowLimit: 0).summary.hasSuffix("by plays · all rows"))
        let toppers = AutoPlaylistRecipe.chartToppers(ChartToppersPlaylistRecipe(entity: .track, period: .year, metric: .scrobbles, yearRange: 0))
        check("a Chart Toppers recipe survives saving", AutoPlaylistRecipe(kind: toppers.kind, data: try toppers.encodedData()) == toppers && toppers.kind == "chartToppers")
        check("…and describes itself", toppers.summary == "Chart Toppers · #1 tracks by year · by plays · all years" && ChartToppersPlaylistRecipe(entity: .artist, period: .decade, metric: .timeListened, yearRange: 10).summary == "Chart Toppers · #1 artists by decade · by time listened · last 10 years")
        func entry(_ artist: String, _ track: String, rank: Int = 1) -> ChartTopperEntry {
            ChartTopperEntry(id: "\(artist)\(track)\(rank)", rank: rank, name: track, artist: artist, album: nil, metricValue: 10, imageURL: nil, loved: false, flagged: false, exportTrack: .init(artist: artist, track: track, album: ""))
        }
        func period(_ label: String, _ entries: [ChartTopperEntry]) -> ChartTopperPeriod { ChartTopperPeriod(id: label, label: label, start: Date(), entries: entries) }
        let toppersTracks = ChartToppersReader.playlistTracks(periods: [
            period("1999", [entry("Artist A", "Song 1"), entry("Artist B", "Song 2", rank: 2)]), period("2000", [entry("Artist B", "Song 2")]),
            period("2001", [entry("artist a", "SONG 1")]), period("2002", []), period("2003", [entry("Artist C", "Song 3")]),
        ])
        check("Chart Toppers: each period's number one, a track once however many periods it won, empty periods skipped", toppersTracks.map(\.track) == ["Song 1", "Song 2", "Song 3"], "\(toppersTracks.map(\.track))")
        check("an unknown kind or damaged data is not a recipe", AutoPlaylistRecipe(kind: "other", data: Data()) == nil && AutoPlaylistRecipe(kind: "topCharts", data: Data("x".utf8)) == nil && AutoPlaylistRecipe(kind: "query", data: Data("x".utf8)) == nil)
        let list = AutoPlaylist(name: "L", recipeKind: chart.kind, recipeData: try chart.encodedData(), sourceSummary: "s")
        check("a saved playlist gives its recipe back", AutoPlaylistRecipe(playlist: list) == chart)

        // Query rows become tracks in the order the query lists them; a row with no artist is left out
        func row(_ artist: String, _ name: String) -> QueryRow { QueryRow(entity: QueryEntity(id: QueryEntityID(target: .track, artist: artist, name: name)), cells: [:]) }
        let rows = [row("Artist A", "Song 2"), row("Artist B", "Song 1"), row("", "No Artist")]
        let result = QueryResult(
            rows: rows, columns: [], matchedCount: 3, universeCount: 3, pending: [], pendingEntities: [:],
            entityInfo: [rows[0].id: .init(imageURL: nil, album: "Album X")]
        )
        let tracks = AutoPlaylistSources.queryTracks(result)
        check("a track Query's rows are the playlist, in order, with their albums", tracks.map(\.track) == ["Song 2", "Song 1"] && tracks.map(\.album) == ["Album X", ""], "\(tracks)")
    }

    @MainActor
    private static func schedulerChecks(_ report: (String, Bool, String) -> Void) async throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func makeContainer() throws -> ModelContainer { try ModelContainer(for: AutoPlaylist.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)) }
        func makeMusic() -> FakeMusic {
            let music = FakeMusic()
            music.with { $0.library = (1...300).map(song) }
            return music
        }
        func insert(_ container: ModelContainer, name: String, recipe: AutoPlaylistRecipe?, enabled: Bool = true, offset: TimeInterval = 0) throws -> AutoPlaylist {
            let list = AutoPlaylist(
                name: name, recipeKind: recipe?.kind ?? "gone", recipeData: try recipe?.encodedData() ?? Data("?".utf8), sourceSummary: name,
                isEnabled: enabled, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + offset)
            )
            container.mainContext.insert(list)
            return list
        }

        // Several playlists with different fates
        do {
            let container = try makeContainer()
            let music = makeMusic()
            let a = try insert(container, name: "A", recipe: recipeList(10), offset: 0)
            let b = try insert(container, name: "B", recipe: recipeList(5), enabled: false, offset: 1)
            let c = try insert(container, name: "C", recipe: nil, offset: 2)
            let d = try insert(container, name: "D", recipe: recipeList(7), offset: 3)
            let calls = Counter()
            let provider: AutoPlaylistScheduler.TrackProvider = { recipe in
                calls.bump()
                guard case .topCharts(let chart) = recipe else { return [] }
                if chart.rowLimit == 7 { throw AutoPlaylistSources.SourceError.rangeGone }
                return wanted(Array(1...chart.rowLimit))
            }
            let scheduler = AutoPlaylistScheduler()
            await scheduler.refreshAll(container: container, reason: "check", backend: music, trackProvider: provider)
            check("a playlist is made and remembered on its first refresh", a.status == .created && !a.playlistPersistentID.isEmpty && music.tracks(of: a.playlistPersistentID) == ids(Array(1...10)), a.lastDetail)
            check("a playlist that is switched off is left alone", b.status == .neverRun && b.lastRefreshAt == nil)
            check("a recipe that can't be read is reported", c.status == .failed && c.lastDetail.contains("can't be read"), c.lastDetail)
            check("a list that can't run is reported with the reason, and the others still ran", d.status == .failed && d.lastDetail.contains("no longer available") && a.status == .created, d.lastDetail)
            check("only the playlists switched on ran", calls.count == 2, "\(calls.count)")
            check("no other playlist was made in Music", music.with { $0.playlists.count } == 1)

            await scheduler.refreshAll(container: container, reason: "check", backend: music, trackProvider: provider)
            check("the next round finds nothing to change", a.status == .upToDate && music.tracks(of: a.playlistPersistentID) == ids(Array(1...10)))
            check("…and the cache saved the library read", music.count("tracks") == 1, "\(music.count("tracks"))")

            // The list changes: a new number one
            let shifted: AutoPlaylistScheduler.TrackProvider = { recipe in
                guard case .topCharts(let chart) = recipe, chart.rowLimit == 10 else { throw AutoPlaylistSources.SourceError.rangeGone }
                return wanted([200] + Array(1...9))
            }
            await scheduler.refreshAll(container: container, reason: "check", backend: music, trackProvider: shifted)
            check("a changed list is carried into the same playlist", a.status == .updated && music.tracks(of: a.playlistPersistentID) == ids([200] + Array(1...9)) && music.with { $0.playlists.count } == 1)
            check("…and its record says when it changed", a.lastChangedAt != nil && a.lastTrackCount == 10)

            // Music not open: nothing is computed
            music.with { $0.running = false }
            let before = calls.count
            await scheduler.refreshAll(container: container, reason: "check", backend: music, trackProvider: provider)
            check("with Music closed the lists are not even run", calls.count == before && a.status == .musicNotRunning && a.lastTrackCount == 10)
            music.with { $0.running = true }

            // The playlist is deleted in Music
            music.with { $0.playlists.removeAll() }
            await scheduler.refreshAll(container: container, reason: "check", backend: music, trackProvider: provider)
            check("a playlist deleted in Music is reported, not remade", a.status == .playlistMissing && music.with { $0.playlists.count } == 0, a.lastDetail)

            // Refresh Now works on a switched-off playlist too
            await scheduler.refresh(b, container: container, backend: music, trackProvider: provider)
            check("Refresh Now runs a playlist even when it is switched off", b.status == .created && music.with { $0.playlists.count } == 1)

            let tally = AutoPlaylistScheduler.Tally(updated: 1, upToDate: 2, attention: 1)
            check("a round is described without names", tally.summary == "1 updated, 2 already up to date, 1 need attention" && AutoPlaylistScheduler.Tally().summary == "nothing to do")
        }

        // Two syncs finishing together: the second round waits for the first and runs once after it
        do {
            let container = try makeContainer()
            let music = makeMusic()
            let list = try insert(container, name: "A", recipe: recipeList(6))
            let calls = Counter()
            let provider: AutoPlaylistScheduler.TrackProvider = { _ in
                calls.bump()
                try await Task.sleep(for: .milliseconds(40))
                return wanted(Array(1...6))
            }
            let scheduler = AutoPlaylistScheduler()
            async let first: Void = scheduler.refreshAll(container: container, reason: "check", backend: music, trackProvider: provider)
            async let second: Void = scheduler.refreshAll(container: container, reason: "check", backend: music, trackProvider: provider)
            _ = await (first, second)
            check("overlapping rounds never overlap: two rounds, one after the other", calls.count == 2 && !scheduler.isRefreshing && list.status == .upToDate, "\(calls.count) \(list.status)")
        }

        // No playlists, nothing happens
        do {
            let container = try makeContainer()
            let music = makeMusic()
            let calls = Counter()
            await AutoPlaylistScheduler().refreshAll(container: container, reason: "check", backend: music, trackProvider: { _ in calls.bump(); return [] })
            check("with no automatic playlists a sync costs nothing", calls.count == 0 && music.calls.isEmpty)
        }

        // Making a playlist from a dialog
        do {
            let container = try makeContainer()
            let music = makeMusic()
            let context = container.mainContext
            let made = try await AutoPlaylistCreator.create(name: "Top 5", recipe: recipeList(5), summary: "Top tracks · 2026", tracks: wanted([3, 1, 2, 5, 4]), takeOverID: nil, context: context, backend: music)
            let saved = try context.fetch(FetchDescriptor<AutoPlaylist>())
            check("a new playlist is made in rank order and saved as automatic", made.outcome.status == .created && saved.count == 1 && music.tracks(of: saved[0].playlistPersistentID) == ids([3, 1, 2, 5, 4]) && saved[0].sourceSummary == "Top tracks · 2026" && AutoPlaylistRecipe(playlist: saved[0]) == recipeList(5))

            // Taking over a playlist that is already there replaces what is in it
            music.with { $0.playlists["OLD"] = .init(name: "Mine", tracks: ids([100, 101, 3]), smart: false) }
            let taken = try await AutoPlaylistCreator.create(name: "Mine", recipe: recipeList(3), summary: "s", tracks: wanted([3, 7, 8]), takeOverID: "OLD", context: context, backend: music)
            check("taking over a playlist replaces its contents and keeps it as the same playlist", taken.outcome.status == .updated && music.tracks(of: "OLD") == ids([3, 7, 8]) && taken.list?.playlistPersistentID == "OLD" && music.with { $0.playlists.count } == 2)

            // Failures save nothing
            let before = try context.fetch(FetchDescriptor<AutoPlaylist>()).count
            music.with { $0.denyAccess = true }
            let denied = try await AutoPlaylistCreator.create(name: "X", recipe: recipeList(1), summary: "s", tracks: wanted([1]), takeOverID: nil, context: context, backend: music)
            music.with { $0.denyAccess = false }
            let empty = try await AutoPlaylistCreator.create(name: "Y", recipe: recipeList(1), summary: "s", tracks: wanted([900, 901]), takeOverID: nil, context: context, backend: music)
            let gone = try await AutoPlaylistCreator.create(name: "Z", recipe: recipeList(1), summary: "s", tracks: wanted([1]), takeOverID: "NOPE", context: context, backend: music)
            let after = try context.fetch(FetchDescriptor<AutoPlaylist>()).count
            check("a failed attempt saves no playlist", denied.list == nil && empty.list == nil && gone.list == nil && after == before)
            check("…and says why", denied.outcome.status == .notAuthorized && empty.outcome.status == .emptyResult && gone.outcome.status == .playlistMissing)
            check("the dialog gets every track that wasn't found", empty.outcome.missingAll == ["Artist A – Song 900", "Artist B – Song 901"], "\(empty.outcome.missingAll)")
        }
    }

    // MARK: - The tool

    @MainActor
    private static func toolChecks(_ report: (String, Bool, String) -> Void) async throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let descriptor = ToolDescriptor.all.first { $0.id == .autoPlaylists }
        check("the tool is on the landing page, under Create", descriptor?.category == "Create" && descriptor?.name == "Auto-Updating Playlists")
        check("its summary describes it", descriptor.map { $0.summary.localizedCaseInsensitiveContains("playlists") } == true)
        check("a Top Charts recipe describes itself", TopChartsPlaylistRecipe(entity: .track, rangeID: "year-2026", metric: .scrobbles, rowLimit: 100).summary(periodLabel: "2026") == "Top tracks · 2026 · by plays · 100 rows")
        check("…and one ranked by time listened says so", TopChartsPlaylistRecipe(entity: .album, rangeID: "last30", metric: .timeListened, rowLimit: 25).summary(periodLabel: "Last 30 days") == "Top albums · Last 30 days · by time listened · 25 rows")

        // Saved queries an automatic playlist can be made from: tracks only, readable, by name
        func saved(_ name: String, target: QueryTarget) throws -> SavedConditionSet {
            var spec = QuerySpec(target: target)
            spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
            return SavedConditionSet(name: name, specJSON: try spec.encoded())
        }
        let sets = [try saved("Zebra tracks", target: .track), try saved("Albums", target: .album), try saved("apple tracks", target: .track), SavedConditionSet(name: "Broken", specJSON: Data("x".utf8))]
        check("only saved queries of tracks that can run are offered, by name", AutoPlaylistStore.eligibleQueries(sets).map(\.set.name) == ["apple tracks", "Zebra tracks"])

        // Stopping and making again
        let container = try ModelContainer(for: AutoPlaylist.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let music = FakeMusic()
        music.with { $0.library = (1...30).map(song) }
        let recipe = recipeList(5)
        let made = try await AutoPlaylistCreator.create(name: "Kept", recipe: recipe, summary: "s", tracks: wanted([1, 2, 3, 4, 5]), takeOverID: nil, context: context, backend: music)
        guard let list = made.list else { check("a playlist can be made for the tool checks", false, made.outcome.detail); return }
        let firstID = list.playlistPersistentID
        music.with { $0.playlists.removeAll() }
        let scheduler = AutoPlaylistScheduler()
        let provider: AutoPlaylistScheduler.TrackProvider = { _ in wanted([1, 2, 3, 4, 5]) }
        await scheduler.refresh(list, container: container, backend: music, trackProvider: provider)
        check("a deleted playlist shows as missing", list.status == .playlistMissing && music.with { $0.playlists.count } == 0)
        AutoPlaylistStore.makeAgain(list)
        check("Make It Again forgets the old playlist", list.playlistPersistentID.isEmpty && list.status == .neverRun)
        await scheduler.refresh(list, container: container, backend: music, trackProvider: provider)
        check("…and the next refresh makes it again under the same name", list.status == .created && !list.playlistPersistentID.isEmpty && list.playlistPersistentID != firstID && music.with { $0.playlists[list.playlistPersistentID]?.name } == "Kept" && music.tracks(of: list.playlistPersistentID) == ids([1, 2, 3, 4, 5]))
        let keptTracks = music.tracks(of: list.playlistPersistentID)
        try AutoPlaylistStore.stopUpdating(list, context: context)
        check("Stop Updating forgets the list and leaves the playlist in Music as it is", try context.fetch(FetchDescriptor<AutoPlaylist>()).isEmpty && music.with { $0.playlists.count } == 1 && music.tracks(of: music.with { Array($0.playlists.keys) }[0]) == keptTracks)

        // The words on a row
        let row = AutoPlaylist(name: "R", recipeKind: "topCharts", recipeData: Data(), sourceSummary: "s")
        check("a new row says it has not been refreshed", AutoPlaylistRowText.status(row) == "Not refreshed yet." && AutoPlaylistRowText.times(row) == nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        row.record(AutoPlaylistOutcome(status: .updated, playlistID: "P", trackCount: 10, added: 2, removed: 2), at: now.addingTimeInterval(-3_600))
        let times = AutoPlaylistRowText.times(row, now: now) ?? ""
        check("a refreshed row says when, and when it last changed", times.hasPrefix("Last refreshed ") && times.contains("changed"), times)
        row.isEnabled = false
        check("a switched-off row says so", AutoPlaylistRowText.status(row).hasPrefix("Switched off"))
    }

    // MARK: - Real data, no Music

    /// On a copy of a real store (Offline mode on): runs a Top Charts recipe and a Query recipe for the last full year and checks the
    /// tracks against an independent count of that year's plays. Nothing is sent to Music.
    @MainActor
    private static func sourceDump(container: ModelContainer) async throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
            if !ok { failures += 1 }
        }
        let calendar = AppCalendars.listening
        let year = calendar.component(.year, from: Date()) - 1
        let range = DateRange(
            from: calendar.date(from: DateComponents(year: year, month: 1, day: 1))!,
            to: calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!.addingTimeInterval(-1)
        )
        let plays = try await ScrobbleHistoryCache.shared.snapshots(container: container).filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
        print("year \(year): \(plays.count) plays")
        guard !plays.isEmpty else { print("no plays in that year"); HeadlessTask.finish(1) }
        func songKey(_ artist: String, _ title: String) -> String { "\(TextNormalization.artistIdentityKey(artist))\u{0}\(TextNormalization.normalizeTrackTitle(title))" }
        var counts: [String: Int] = [:]
        for play in plays { counts[songKey(play.artistName, play.trackName), default: 0] += 1 }
        let ranked = counts.values.sorted(by: >)

        func verify(_ label: String, _ tracks: [AppleMusicPlaylistTrack], limit: Int) {
            let listed = tracks.map { counts[songKey($0.artist, $0.track)] ?? 0 }
            let nonIncreasing = zip(listed, listed.dropFirst()).allSatisfy { $0 >= $1 }
            let expectedCount = min(limit, ranked.count)
            let boundary = listed.last ?? 0
            // nothing outside the list may have more plays than the last track inside it
            let listedKeys = Set(tracks.map { songKey($0.artist, $0.track) })
            let outsiders = counts.filter { !listedKeys.contains($0.key) && $0.value > boundary }.count
            check("\(label): \(tracks.count) tracks in non-increasing play order (independent recount)", nonIncreasing && listed.allSatisfy { $0 > 0 }, "listed counts start \(listed.prefix(8))")
            check("\(label): the right number of tracks", tracks.count == expectedCount, "\(tracks.count) vs \(expectedCount)")
            check("\(label): no track left out that was played more than the last one listed", outsiders == 0, "\(outsiders) outsiders above \(boundary) plays")
            check("\(label): no song twice", listedKeys.count == tracks.count)
        }

        let began = Date()
        let chartTracks = try await AutoPlaylistSources.tracks(
            for: .topCharts(TopChartsPlaylistRecipe(entity: .track, rangeID: "year-\(year)", metric: .scrobbles, rowLimit: 100)), container: container, popularity: nil
        )
        print(String(format: "  Top Charts recipe: %.2f s", Date().timeIntervalSince(began)))
        verify("Top Charts, top 100 tracks of \(year)", chartTracks, limit: 100)

        var spec = TrendsDrill.spec(from: range.from, to: range.to, target: .track)
        spec.limit = 100
        let queryBegan = Date()
        let queryTracks = try await AutoPlaylistSources.tracks(for: .query(spec), container: container, popularity: nil)
        print(String(format: "  Query recipe: %.2f s", Date().timeIntervalSince(queryBegan)))
        verify("Query, top 100 tracks of \(year)", queryTracks, limit: 100)

        let sameSongs = Set(chartTracks.map { songKey($0.artist, $0.track) }).symmetricDifference(Set(queryTracks.map { songKey($0.artist, $0.track) })).count
        print("  songs in one list but not the other (ties at the cut-off can differ): \(sameSongs)")

        // Most Recent, Most Often: the tracks first played in the last 90 days with at least 5 plays, by speed
        let now = Date()
        let mrmo = MostRecentMostOftenPlaylistRecipe(windowDays: 90, minPlays: 5, sort: .velocity, rowLimit: 50)
        let mrmoTracks = try await AutoPlaylistSources.tracks(for: .mostRecentMostOften(mrmo), container: container, popularity: nil)
        let all = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
        var firstPlay: [String: Date] = [:], total: [String: Int] = [:], albumCounts: [String: [String: Int]] = [:]
        for play in all {
            let key = "\(play.artistName)\u{0}\(play.trackName)"
            if firstPlay[key].map({ play.playedAt < $0 }) ?? true { firstPlay[key] = play.playedAt }
            total[key, default: 0] += 1
            albumCounts[key, default: [:]][play.albumName, default: 0] += 1
        }
        let eligibleCount = firstPlay.keys.filter { key in
            guard let first = firstPlay[key], let plays = total[key] else { return false }
            return plays >= mrmo.minPlays && now.timeIntervalSince(first) <= Double(mrmo.windowDays) * 86_400
        }.count
        let allEligible = mrmoTracks.allSatisfy { track in
            let key = "\(track.artist)\u{0}\(track.track)"
            guard let first = firstPlay[key], let plays = total[key] else { return false }
            return plays >= mrmo.minPlays && now.timeIntervalSince(first) <= Double(mrmo.windowDays) * 86_400
        }
        let albumsRight = mrmoTracks.allSatisfy { track in
            let counts = albumCounts["\(track.artist)\u{0}\(track.track)"] ?? [:]
            return (counts[track.album] ?? 0) == (counts.values.max() ?? 0)
        }
        print("  Most Recent, Most Often: \(mrmoTracks.count) tracks (\(eligibleCount) tracks qualify in all)")
        check("Most Recent, Most Often: every track qualifies by an independent count (first played in the window, enough plays)", allEligible)
        check("Most Recent, Most Often: the right number of tracks", mrmoTracks.count == min(mrmo.rowLimit, eligibleCount), "\(mrmoTracks.count) vs \(min(mrmo.rowLimit, eligibleCount))")
        check("Most Recent, Most Often: each track carries its most-played album", albumsRight)

        // Chart Toppers: each year's number one track; its plays must equal an independent count of the track's plays
        let toppersRecipe = ChartToppersPlaylistRecipe(entity: .track, period: .year, metric: .scrobbles, yearRange: 0)
        let periods = try await ChartToppersReader(modelContainer: container).load(entity: .track, metric: .scrobbles, period: .year, yearRange: 0)
        let allPlays = try await ScrobbleHistoryCache.shared.snapshots(container: container)
        var allTime: [String: Int] = [:]
        for play in allPlays { allTime[songKey(play.artistName, play.trackName), default: 0] += 1 }
        let winners = periods.compactMap { $0.entries.first }
        let countsMatch = winners.filter { allTime[songKey($0.artist, $0.name)] == $0.metricValue }.count
        let sortedWithin = periods.allSatisfy { p in zip(p.entries, p.entries.dropFirst()).allSatisfy { $0.metricValue >= $1.metricValue } }
        let toppersList = try await AutoPlaylistSources.tracks(for: .chartToppers(toppersRecipe), container: container, popularity: nil)
        print("  Chart Toppers: \(periods.count) years, \(winners.count) with a number one, \(countsMatch) whose plays equal the independent count, \(toppersList.count) tracks")
        check("Chart Toppers: each year's list is in non-increasing order", sortedWithin)
        check("Chart Toppers: the number ones' plays equal an independent count (all but a few merged spellings)", winners.isEmpty || Double(countsMatch) / Double(winners.count) >= 0.9, "\(countsMatch) of \(winners.count)")
        check("Chart Toppers: the playlist is the winners, each song once", toppersList.count == Set(toppersList.map { songKey($0.artist, $0.track) }).count && toppersList.count <= winners.count)

        // The same chart for artists: the playlist holds the tracks of the top artists
        let artistTracks = try await AutoPlaylistSources.tracks(
            for: .topCharts(TopChartsPlaylistRecipe(entity: .artist, rangeID: "year-\(year)", metric: .scrobbles, rowLimit: 10)), container: container, popularity: nil
        )
        check("Top Charts, top 10 artists: tracks of the artists, up to the builder's limits", !artistTracks.isEmpty && artistTracks.count <= 500, "\(artistTracks.count)")
        HeadlessTask.finish(failures)
    }

    // MARK: - Real Music

    /// Reads one playlist and checks the real backend against it: every track of the playlist, searched for in the library by
    /// name, artist and album, must come back as the playlist's own track, and the plan must be "nothing to change". Changes nothing.
    @MainActor
    private static func liveRead(source: String) async throws {
        let backend = AppleMusicPlaylistBackend()
        guard backend.isMusicRunning else { print("Music isn't open"); exit(1) }
        let rows = try await readPlaylistRows(source)
        print("playlist read: \(rows.count) tracks")
        let began = Date()
        let resolved = try await AutoPlaylistEngine.resolve(rows.map(\.track), cache: .init(), backend: backend)
        print(String(format: "  found each in the library: %.1f s", Date().timeIntervalSince(began)))
        var sameTrack = 0, otherTrack = 0, notFound = 0
        for (index, row) in rows.enumerated() {
            if let found = resolved.ids[index] { if found == row.id { sameTrack += 1 } else { otherTrack += 1 } } else { notFound += 1 }
        }
        print("  same library track as the playlist holds: \(sameTrack) · a different library track with the same name/artist/album: \(otherTrack) · not found: \(notFound)")
        let request = AutoPlaylistRequest(name: "unused", playlistID: source, tracks: rows.map(\.track), cache: resolved.cache, dryRun: true)
        let started = Date()
        let outcome = await AutoPlaylistEngine.refresh(request, backend: backend)
        print(String(format: "  dry-run refresh with a warm cache: %.1f s → %@ (%@)", Date().timeIntervalSince(started), outcome.status.rawValue, outcome.detail))
        // With the playlist's own IDs as the match cache, the answer must be "nothing to change": the diff and the playlist read agree.
        var exact = AutoPlaylistMatchCache()
        for row in rows { exact.ids[AutoPlaylistMatchCache.key(for: row.track)] = row.id }
        let own = await AutoPlaylistEngine.refresh(.init(name: "unused", playlistID: source, tracks: rows.map(\.track), cache: exact, dryRun: true), backend: backend)
        let repeats = rows.count - Set(rows.map(\.id)).count
        let ok = own.status == .upToDate || (repeats > 0 && own.removed + own.added > 0)
        print("  with the playlist's own tracks as the matches: \(own.status.rawValue)\(repeats > 0 ? " (the playlist holds \(repeats) repeated tracks, which a refresh would remove)" : "")")
        HeadlessTask.finish(ok ? 0 : 1)
    }

    private struct Row { let id: String; let track: AppleMusicPlaylistTrack }

    private static func readPlaylistRows(_ playlistID: String) async throws -> [Row] {
        let columnSeparator = "\u{1D}", itemSeparator = "\u{1E}"
        let reply = try await AppleMusicMatcher.runAppleScript("""
        on run argv
          tell application "Music"
            set pl to first user playlist whose persistent ID is (item 1 of argv)
            set ns to name of every track of pl
            set ars to artist of every track of pl
            set als to album of every track of pl
            set ids to persistent ID of every track of pl
            set AppleScript's text item delimiters to "\(itemSeparator)"
            set a to ns as string
            set b to ars as string
            set c to als as string
            set d to ids as string
            return a & "\(columnSeparator)" & b & "\(columnSeparator)" & c & "\(columnSeparator)" & d
          end tell
        end run
        """, arguments: [playlistID])
        let columns = reply.trimmingCharacters(in: .newlines).components(separatedBy: columnSeparator)
        guard columns.count == 4 else { throw AutoPlaylistError.message("unexpected answer") }
        func items(_ text: String) -> [String] { text.isEmpty ? [] : text.components(separatedBy: itemSeparator) }
        let names = items(columns[0]), artists = items(columns[1]), albums = items(columns[2]), ids = items(columns[3])
        guard names.count == artists.count, names.count == albums.count, names.count == ids.count else { throw AutoPlaylistError.message("columns differ") }
        return names.indices.map { Row(id: ids[$0], track: .init(artist: artists[$0], track: names[$0], album: albums[$0])) }
    }

    /// Makes a scratch playlist from the first tracks of another, runs the real sequence of refreshes on it and deletes it again.
    /// Only run with the owner's permission: it writes to Music (to one playlist it makes itself).
    @MainActor
    private static func liveWrite(source: String) async throws {
        let backend = AppleMusicPlaylistBackend()
        guard backend.isMusicRunning else { print("Music isn't open"); exit(1) }
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
            if !ok { failures += 1 }
        }
        let rows = try await readPlaylistRows(source)
        var seen = Set<String>()
        let pool = rows.filter { seen.insert($0.id).inserted }.prefix(12).map { $0 }
        guard pool.count >= 12 else { print("the source playlist needs 12 different tracks"); exit(1) }
        func tracks(_ indexes: [Int]) -> [AppleMusicPlaylistTrack] { indexes.map { pool[$0].track } }
        func expected(_ indexes: [Int]) -> [String] { indexes.map { pool[$0].id } }
        let name = "Scroblytics test"
        var request = AutoPlaylistRequest(name: name, playlistID: nil, tracks: tracks(Array(0..<8)))
        var outcome = await AutoPlaylistEngine.refresh(request, backend: backend)
        guard let playlistID = outcome.playlistID else { print("could not make the playlist: \(outcome.detail)"); exit(1) }
        func held() async -> [String] { if case .tracks(let ids)? = try? await backend.readPlaylist(id: playlistID) { return ids }; return [] }
        var heldNow = await held()
        check("the playlist is made in order", outcome.status == .created && heldNow == expected(Array(0..<8)), outcome.detail)
        request.playlistID = playlistID; request.cache = outcome.cache

        outcome = await AutoPlaylistEngine.refresh(request, backend: backend)
        heldNow = await held()
        check("the same list again changes nothing", outcome.status == .upToDate && heldNow == expected(Array(0..<8)), outcome.detail)
        request.cache = outcome.cache

        request.tracks = tracks([0, 1, 3, 2, 4, 5, 6, 7]); request.cache = outcome.cache
        outcome = await AutoPlaylistEngine.refresh(request, backend: backend)
        heldNow = await held()
        check("a swapped rank is put in order", outcome.status == .updated && outcome.removed == 6 && heldNow == expected([0, 1, 3, 2, 4, 5, 6, 7]), outcome.detail)
        request.cache = outcome.cache

        request.tracks = tracks([11, 0, 1, 3, 2, 4])
        outcome = await AutoPlaylistEngine.refresh(request, backend: backend)
        heldNow = await held()
        check("a new number one and a shorter list", outcome.status == .updated && heldNow == expected([11, 0, 1, 3, 2, 4]), outcome.detail)

        // Music's own library is untouched by all of that
        let stillThere = try await backend.libraryTrackIDs()
        check("every track used is still in the library", pool.allSatisfy { stillThere.contains($0.id) })

        // Clean up: delete only the playlist just made, and only if it is the scratch one
        let cleanup = try await AppleMusicMatcher.runAppleScript("""
        on run argv
          tell application "Music"
            set pl to first user playlist whose persistent ID is (item 1 of argv)
            if name of pl is not (item 2 of argv) then return "WRONG NAME"
            delete pl
            return "DELETED"
          end tell
        end run
        """, arguments: [playlistID, name])
        check("the scratch playlist is deleted", cleanup.trimmingCharacters(in: .whitespacesAndNewlines) == "DELETED", cleanup)
        let left = await backend.readPlaylistIfPresent(id: playlistID)
        check("…and is gone from Music", !left)
        HeadlessTask.finish(failures)
    }
}

private extension AppleMusicPlaylistBackend {
    func readPlaylistIfPresent(id: String) async -> Bool {
        if case .missing? = try? await readPlaylist(id: id) { return false }
        return true
    }
}
#endif
