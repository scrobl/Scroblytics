import Foundation
import os
import SwiftData

#if DEBUG
/// A stand-in for Last.fm that records which questions were asked.
private final class StubLastfm: SimilaritySourcing, RabbitHoleSimilarityProviding, @unchecked Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (topTracks: 0, similarTracks: 0))
    var tracks: [String: [SimilarTrack]] = [:]
    var artists: [String: [SimilarArtist]] = [:]
    var top: [String: [String]] = [:]
    var topTrackCalls: Int { counts.withLock { $0.topTracks } }

    func fetchSimilarTracks(artist: String, track: String, limit: Int) async -> [SimilarTrack] { tracks[track.lowercased()] ?? [] }
    func fetchSimilarArtists(artist: String, limit: Int) async -> [SimilarArtist] { artists[artist.lowercased()] ?? [] }
    func fetchTopTracks(artist: String, limit: Int) async -> [String] {
        counts.withLock { $0.topTracks += 1 }
        return Array((top[artist.lowercased()] ?? []).prefix(limit))
    }
    func similarTracks(artist: String, track: String) async throws -> [SimilarTrack] { tracks[track.lowercased()] ?? [] }
    func similarArtists(artist: String) async throws -> [SimilarArtist] { artists[artist.lowercased()] ?? [] }
}

/// `SCROBLYTICS_NEWMUSIC_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the "new music" option of Similar Sounds and Rabbit Hole,
/// on made-up data with a stand-in for Last.fm. Exits 0 on success.
enum NewMusicChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_NEWMUSIC_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }

            // MARK: Recognising a track you've played
            check("the same track is the same however it is cased or tagged",
                  NewMusic.key(artist: "Artist A", track: "Song One") == NewMusic.key(artist: " artist a ", track: "song one - 2011 Remaster")
                    && NewMusic.key(artist: "Artist A", track: "Song One") == NewMusic.key(artist: "Artist A", track: "Song One (feat. Someone)"))
            check("a different track or artist is a different key",
                  NewMusic.key(artist: "Artist A", track: "Song One") != NewMusic.key(artist: "Artist A", track: "Song Two")
                    && NewMusic.key(artist: "Artist A", track: "Song One") != NewMusic.key(artist: "Artist B", track: "Song One"))
            let url = NewMusic.lastfmURL(artist: "Artist & Co/1", track: "What? #1 (live)")
            check("the Last.fm page link keeps punctuation out of the route",
                  url?.host == "www.last.fm" && url?.absoluteString == "https://www.last.fm/music/Artist+%26+Co%2F1/_/What%3F+%231+%28live%29", url?.absoluteString ?? "nil")

            // MARK: A made-up history
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            var history: [ScrobbleSnapshot] = []
            var clock = t0
            func play(_ artist: String, _ track: String, album: String = "") {
                clock = clock.addingTimeInterval(4_000_000)
                history.append(ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: nil, playedAt: clock))
            }
            for _ in 0..<3 { play("Artist A", "X", album: "A1") }
            play("Artist A", "Song One", album: "A1"); play("Artist A", "Song One", album: "A1")
            play("Artist B", "Y"); play("Artist B", "Y")
            play("Artist C", "Z")

            // MARK: Similar Sounds: finding them
            let stub = StubLastfm()
            stub.tracks["x"] = [
                SimilarTrack(name: "Y", artist: "Artist B", match: 0.9),
                SimilarTrack(name: "Song One - 2011 Remaster", artist: "artist a", match: 0.8),
                SimilarTrack(name: "Fresh One", artist: "New Artist", match: 0.7),
                SimilarTrack(name: "Fresh Two", artist: "New Artist", match: 0.4),
                SimilarTrack(name: "X", artist: "Artist A", match: 1.0),
            ]
            let trackSeed = RecommendationSeed(kind: .track, artist: "Artist A", album: nil, track: "X")
            let tracksOnly = try? await SimilarSoundsEngine.run(seeds: [trackSeed], scrobbles: history, client: stub, includeNewMusic: true)
            check("a track seed's new music is what Last.fm named that you haven't played",
                  tracksOnly?.newMusic.map(\.track) == ["Fresh One", "Fresh Two"], "\(tracksOnly?.newMusic.map(\.track) ?? [])")
            check("a track you've played under another title, and the seed itself, are not new",
                  tracksOnly?.newMusic.contains { $0.track.contains("Song One") || $0.track == "X" } == false)
            check("the library results are the same with or without looking for new music",
                  (try? await SimilarSoundsEngine.run(seeds: [trackSeed], scrobbles: history, client: stub, includeNewMusic: false))?.candidates.map(\.track) == tracksOnly?.candidates.map(\.track))
            check("a new track carries its score (best across seeds) and the seed that found it",
                  tracksOnly?.newMusic.first.map { $0.matchScore == 70 && $0.topSource == "X — Artist A" && $0.sources == ["X — Artist A"] } == true)
            check("the seed's result counts the new tracks it found", tracksOnly?.seedResults.first?.newFound == 2)

            let off = try? await SimilarSoundsEngine.run(seeds: [trackSeed], scrobbles: history, client: stub, includeNewMusic: false)
            check("with the option off there is no new music and no top-tracks lookup", off?.newMusic.isEmpty == true && stub.topTrackCalls == 0)

            // An artist seed: the closest similar artists' best-known tracks.
            let artistStub = StubLastfm()
            artistStub.artists["artist a"] = (1...8).map { SimilarArtist(name: "Similar \($0)", match: 1.0 - Double($0) / 20) } + [SimilarArtist(name: "Artist B", match: 0.99)]
            for n in 1...8 { artistStub.top["similar \(n)"] = ["Hit \(n)a", "Hit \(n)b", "Hit \(n)c"] }
            artistStub.top["artist b"] = ["Y", "Unplayed B"]
            let artistSeed = RecommendationSeed.artist("Artist A")
            let fromArtists = try? await SimilarSoundsEngine.run(seeds: [artistSeed], scrobbles: history, client: artistStub, includeNewMusic: true)
            let found = fromArtists?.newMusic ?? []
            check("only the \(SimilarSoundsEngine.newMusicArtistsUsed) closest similar artists are looked at", artistStub.topTrackCalls == SimilarSoundsEngine.newMusicArtistsUsed, "\(artistStub.topTrackCalls)")
            check("at most \(SimilarSoundsEngine.newMusicTracksPerArtist) tracks come from one artist",
                  Dictionary(grouping: found, by: \.artist).values.allSatisfy { $0.count <= SimilarSoundsEngine.newMusicTracksPerArtist })
            check("an artist you play is included for the tracks of theirs you haven't, but not the ones you have",
                  found.contains { $0.artist == "Artist B" && $0.track == "Unplayed B" } && !found.contains { $0.track == "Y" })
            check("a top track scores a little under its artist's match", found.first { $0.track == "Unplayed B" }?.matchScore == Int((0.99 * SimilarSoundsEngine.newMusicArtistDiscount * 100).rounded()), "\(found.map(\.matchScore))")

            // Two seeds finding the same track: best match wins, both seeds are kept.
            let twoStub = StubLastfm()
            twoStub.tracks["x"] = [SimilarTrack(name: "Shared", artist: "New Artist", match: 0.5)]
            twoStub.tracks["y"] = [SimilarTrack(name: "shared", artist: "new artist", match: 0.8)]
            let two = try? await SimilarSoundsEngine.run(
                seeds: [trackSeed, RecommendationSeed(kind: .track, artist: "Artist B", album: nil, track: "Y")], scrobbles: history, client: twoStub, includeNewMusic: true
            )
            check("a track found by two seeds appears once, at the better match, crediting both",
                  two?.newMusic.count == 1 && two?.newMusic.first?.matchScore == 80 && two?.newMusic.first?.sources.count == 2 && two?.newMusic.first?.topSource == "Y — Artist B", "\(two?.newMusic ?? [])")

            // MARK: Similar Sounds: placing them among the results
            let libraryCandidates = [("L90", "Artist A", 90), ("L70", "Artist B", 70), ("L50", "Artist C", 50)].map { name, artist, score in
                RecommendedCandidate(track: name, artist: artist, album: nil, totalPlaycount: 5, lastPlayed: t0, matchScore: score, sources: ["Seed"], topSource: "Seed", imageURL: nil)
            }
            var scrobbles: [ScrobbleSnapshot] = []
            for (name, artist, _) in [("L90", "Artist A", 0), ("L70", "Artist B", 0), ("L50", "Artist C", 0)] {
                scrobbles.append(ScrobbleSnapshot(artistName: artist, albumName: "", trackName: name, imageURL: nil, playedAt: t0))
            }
            let newOnes = [
                NewMusicCandidate(artist: "New Artist", track: "N80", matchScore: 80, sources: ["Seed"], topSource: "Seed"),
                NewMusicCandidate(artist: "Another", track: "N70", matchScore: 70, sources: ["Seed", "Other"], topSource: "Seed"),
                NewMusicCandidate(artist: "Artist A", track: "N20", matchScore: 20, sources: ["Seed"], topSource: "Seed"),
            ]
            let pool = SimilarSoundsTool.pool(candidates: libraryCandidates, seedResults: [], newMusic: newOnes, searchedNewMusic: true)
            check("new music is never one of the pool's Query entities", pool.ids.count == 3 && pool.newMusic.count == 3)
            @MainActor func run(_ arrangement: SimilarSoundsArrangement, groups: [[QueryCondition]] = []) -> (SimilarSoundsBlend.Output, [QueryDisplayRow])? {
                guard let result = try? SimilarSoundsTool.evaluate(
                    pool: pool, groups: groups, columns: SimilarSoundsTool.defaultColumns, scrobbles: scrobbles, snapshots: QuerySnapshots(), now: clock, arrangement: arrangement
                ) else { return nil }
                let rows = QueryDisplayRow.make(from: result, imageLookup: [:])
                return (SimilarSoundsBlend.blend(
                    library: rows, result: result, newMusic: pool.newMusic, scores: pool.snapshot, hasConditions: groups.contains { !$0.isEmpty },
                    arrangement: arrangement, imageLookup: [:]
                ), rows)
            }
            check("the Query tab's rows are never marked as new music", run(SimilarSoundsArrangement())?.1.allSatisfy { !$0.isNewMusic } == true)

            let byScore = run(SimilarSoundsArrangement())
            check("by match score a new track falls between the library tracks around its score (a tie goes after the library's)",
                  byScore?.0.rows.map(\.entity.name) == ["L90", "N80", "L70", "N70", "L50", "N20"], "\(byScore?.0.rows.map(\.entity.name) ?? [])")
            check("only the new tracks are marked, and they are counted",
                  byScore?.0.rows.filter(\.isNewMusic).map(\.entity.name) == ["N80", "N70", "N20"] && byScore?.0.shown == 3)
            if let first = byScore?.0.rows.first(where: { $0.isNewMusic }), let result = try? SimilarSoundsTool.evaluate(pool: pool, groups: [], columns: SimilarSoundsTool.defaultColumns, scrobbles: scrobbles, snapshots: QuerySnapshots(), now: clock) {
                let scoreKey = result.columns.first { $0.field.id == "similarScore" }?.cacheKey ?? ""
                let becauseKey = result.columns.first { $0.field.id == "similarBecause" }?.cacheKey ?? ""
                let playsKey = result.columns.first { $0.field.id == "plays" }?.cacheKey ?? ""
                check("a new row shows its score and its seeds, and no plays", first.row.cells[scoreKey] == .value(.number(80)) && first.row.cells[becauseKey] == .value(.text("Seed")) && first.row.cells[playsKey] == nil)
            } else { check("a new row exists to inspect", false) }

            let byPlays = run(SimilarSoundsArrangement(sort: .plays))
            check("by play count the new tracks follow your own", byPlays?.0.rows.suffix(3).allSatisfy(\.isNewMusic) == true && byPlays?.0.rows.prefix(3).allSatisfy { !$0.isNewMusic } == true)
            let byRecent = run(SimilarSoundsArrangement(sort: .lastPlayed))
            check("by last played the new tracks follow your own", byRecent?.0.rows.suffix(3).allSatisfy(\.isNewMusic) == true)

            let shuffledA = run(SimilarSoundsArrangement(sort: .shuffled, shuffleSeed: 7)), shuffledB = run(SimilarSoundsArrangement(sort: .shuffled, shuffleSeed: 7))
            let shuffledC = run(SimilarSoundsArrangement(sort: .shuffled, shuffleSeed: 8))
            check("shuffled keeps its order for a seed and holds every row", shuffledA?.0.rows.map(\.entity.name) == shuffledB?.0.rows.map(\.entity.name) && shuffledA?.0.rows.count == 6)
            check("shuffled does not move your own tracks relative to each other",
                  shuffledA?.0.rows.filter { !$0.isNewMusic }.map(\.entity.name) == shuffledA?.1.map(\.entity.name))
            _ = shuffledC

            let withCondition = run(SimilarSoundsArrangement(), groups: [[QueryCondition(QueryFieldRef("plays"), .greaterThanOrEqual, [.number(1)])]])
            check("a condition leaves the new tracks out and says how many", withCondition?.0.shown == 0 && withCondition?.0.hiddenByConditions == 3 && withCondition?.0.rows.allSatisfy { !$0.isNewMusic } == true)

            let limited = run(SimilarSoundsArrangement(songLimit: 4))
            check("the song limit applies to the whole list", limited?.0.rows.map(\.entity.name) == ["L90", "N80", "L70", "N70"], "\(limited?.0.rows.map(\.entity.name) ?? [])")
            let perArtist = run(SimilarSoundsArrangement(perArtist: 1))
            check("the per-artist limit counts new tracks, and never drops a library track",
                  perArtist?.0.rows.map(\.entity.name) == ["L90", "N80", "L70", "N70", "L50"], "\(perArtist?.0.rows.map(\.entity.name) ?? [])")
            let none = SimilarSoundsBlend.blend(library: byScore?.1 ?? [], result: (try? SimilarSoundsTool.evaluate(pool: pool, groups: [], columns: SimilarSoundsTool.defaultColumns, scrobbles: scrobbles, snapshots: QuerySnapshots(), now: clock))!, newMusic: [], scores: pool.snapshot, hasConditions: false, arrangement: SimilarSoundsArrangement(), imageLookup: [:])
            check("with no new music the results are untouched", none.rows.map(\.entity.name) == byScore?.1.map(\.entity.name) && none.shown == 0)

            // MARK: The cost of recognising played tracks on a big library
            var big: [ScrobbleSnapshot] = []
            big.reserveCapacity(60_000)
            for n in 0..<60_000 {
                big.append(ScrobbleSnapshot(artistName: "Artist \(n % 3000)", albumName: "", trackName: "Track number \(n) (Remastered 2011)", imageURL: nil, playedAt: t0.addingTimeInterval(Double(n) * 300)))
            }
            let started = Date()
            let bigLibrary = RabbitHoleLibrary.build(scrobbles: big)
            let seconds = Date().timeIntervalSince(started)
            print("INFO  indexing 60,000 distinct tracks took \(String(format: "%.2f", seconds)) s")
            check("indexing 60,000 distinct tracks, including their normalised keys, stays under 5 seconds", seconds < 5 && bigLibrary.hasPlayed(artist: "artist 5", track: "TRACK NUMBER 5 - 2011 remaster"), "\(seconds)")

            // MARK: Rabbit Hole: finding them
            let library = RabbitHoleLibrary.build(scrobbles: history)
            check("a track counts as played however Last.fm spells it", library.hasPlayed(artist: "ARTIST A", track: "song one - 2011 Remaster") && library.hasPlayed(artist: "Artist B", track: "Y") && !library.hasPlayed(artist: "New Artist", track: "Fresh One"))
            let hole = StubLastfm()
            hole.tracks["x"] = stub.tracks["x"]! + [SimilarTrack(name: "On The Path", artist: "Pathy", match: 0.95)]
            hole.tracks["y"] = [SimilarTrack(name: "Fresh One", artist: "New Artist", match: 0.9), SimilarTrack(name: "Fresh Three", artist: "Third", match: 0.6)]
            let seeds = [RabbitHoleCandidates.Seed(artist: "Artist A", track: "X", weight: 1), RabbitHoleCandidates.Seed(artist: "Artist B", track: "Y", weight: 0.5)]
            let fresh = await RabbitHoleCandidates.newMusic(seeds: seeds, excludingKeys: [NewMusic.key(artist: "Pathy", track: "On The Path")], library: library, provider: hole)
            check("new music for a step is what Last.fm named for it that you haven't played, off the path, best first",
                  fresh.map(\.track) == ["Fresh One", "Fresh Two", "Fresh Three"], "\(fresh.map(\.track))")
            check("a track found for two steps keeps its better score, weighted by the step",
                  fresh.first { $0.track == "Fresh One" }.map { abs($0.score - 70) < 0.001 && $0.reason == "Last.fm: similar to X" } == true, "\(fresh.first?.score ?? 0)")
            check("a track found only for an earlier step is weighted down and says so",
                  fresh.first { $0.track == "Fresh Three" }.map { abs($0.score - 30) < 0.001 && $0.reason.contains("an earlier step") } == true)

            // MARK: Rabbit Hole: how much is mixed in
            func selectorItem(_ key: String, score: Double, outside: Bool) -> RabbitHoleSelector.Item {
                RabbitHoleSelector.Item(key: key, artistKey: key, albumKey: key, topTag: nil, score: score, plays: outside ? 0 : 20, lastPlayed: t0, loved: false, isOutside: outside)
            }
            let mixed = (0..<20).map { selectorItem("lib\($0)", score: 80, outside: false) } + (0..<5).map { selectorItem("new\($0)", score: 20, outside: true) }
            var neutral = RabbitHoleKnobs(); neutral.avoidRepeats = false
            func outsideShare(_ share: Double, items: [RabbitHoleSelector.Item] = mixed) -> Double {
                var rng = SeededGenerator(state: 17)
                var outside = 0
                let rounds = 3000
                for _ in 0..<rounds {
                    let picked = RabbitHoleSelector.pick(items, count: 1, knobs: neutral, memory: RabbitHoleMemory(), pathArtistCounts: [:], pathAlbumCounts: [:], perArtist: 0, perAlbum: 0, newShare: share, using: &rng)
                    if picked.first?.isOutside == true { outside += 1 }
                }
                return Double(outside) / Double(rounds)
            }
            let little = outsideShare(0.25), half = outsideShare(0.5), natural = outsideShare(0)
            check("“a little” makes about one pick in four new, whatever the scores", abs(little - 0.25) < 0.04, "\(little)")
            check("“half” makes about one pick in two new", abs(half - 0.5) < 0.04, "\(half)")
            check("with the option off, new tracks have only their own small weight", natural < 0.1, "\(natural)")
            check("with no new tracks to draw on the picks are unchanged", outsideShare(0.5, items: mixed.filter { !$0.isOutside }) == 0)
            check("with only new tracks they are all that can be picked", outsideShare(0.25, items: mixed.filter(\.isOutside)) == 1)
            var rngA = SeededGenerator(state: 5), rngB = SeededGenerator(state: 5)
            let without = RabbitHoleSelector.pick(mixed, count: 3, knobs: neutral, memory: RabbitHoleMemory(), pathArtistCounts: [:], pathAlbumCounts: [:], perArtist: 0, perAlbum: 0, using: &rngA)
            let withZero = RabbitHoleSelector.pick(mixed, count: 3, knobs: neutral, memory: RabbitHoleMemory(), pathArtistCounts: [:], pathAlbumCounts: [:], perArtist: 0, perAlbum: 0, newShare: 0, using: &rngB)
            check("a share of zero picks exactly as before", without.map(\.key) == withZero.map(\.key))

            // MARK: Rabbit Hole: the engine
            let seedTrack = RabbitHoleTrack(artist: "Artist A", track: "X", album: "A1", imageURL: nil, playCount: 3, lastPlayed: nil, matchScore: 0, source: "start")
            let root = RabbitHoleNode(id: UUID(), track: seedTrack, parentID: nil, candidates: nil, childIDs: [])
            hole.tracks["x"] = (1...12).map { SimilarTrack(name: "Fresh \($0)", artist: "New \($0)", match: 0.8) } + [SimilarTrack(name: "Y", artist: "Artist B", match: 0.9), SimilarTrack(name: "Z", artist: "Artist C", match: 0.8)]
            let finalHistory = history
            func generate(newMusic: Int, groups: [[QueryCondition]] = [], round: UInt64) async -> [RabbitHoleTrack] {
                var knobs = RabbitHoleKnobs(); knobs.avoidRepeats = false; knobs.newMusic = newMusic
                var rng = SeededGenerator(state: round)
                let result = try? await RabbitHoleEngine.generate(
                    from: seedTrack, path: [root], groups: groups, perArtist: 1, perAlbum: 0, knobs: knobs, memory: RabbitHoleMemory(), library: library,
                    scrobbles: finalHistory, snapshots: QuerySnapshots(), provider: hole, now: Date(), using: &rng
                )
                return result?.candidates ?? []
            }
            var offeredNew = 0, offeredAll = 0
            var sample: RabbitHoleTrack?
            for round in 1...40 {
                let offered = await generate(newMusic: 2, round: UInt64(round))
                offeredAll += offered.count
                for track in offered where track.isNew == true { offeredNew += 1; sample = sample ?? track }
            }
            check("with new music on, some suggestions are new (about half of them)", offeredNew > 0 && Double(offeredNew) / Double(max(1, offeredAll)) > 0.25, "\(offeredNew) of \(offeredAll)")
            check("a new suggestion has no plays or album, is marked, and says why in two lines",
                  sample.map { $0.playCount == 0 && $0.album == nil && $0.lastPlayed == nil && $0.isNew == true && $0.reasons?.map(\.kind) == [.similar, .newToYou] } == true)
            var anyNewWhenOff = false
            for round in 1...20 where await generate(newMusic: 0, round: UInt64(round)).contains(where: { $0.isNew == true }) { anyNewWhenOff = true }
            check("with it off nothing is new", !anyNewWhenOff)
            var anyNewWithCondition = false
            let played = QueryCondition(QueryFieldRef("plays"), .greaterThanOrEqual, [.number(1)])
            for round in 1...20 where await generate(newMusic: 2, groups: [[played]], round: UInt64(round)).contains(where: { $0.isNew == true }) { anyNewWithCondition = true }
            check("a condition leaves new music out", !anyNewWithCondition)
            var distinctArtists = true
            for round in 1...20 {
                let offered = await generate(newMusic: 2, round: UInt64(round))
                if Set(offered.map { $0.artist.lowercased() }).count != offered.count { distinctArtists = false }
            }
            check("the per-artist limit holds with new tracks in the mix", distinctArtists)

            // MARK: Saved settings from before keep working
            check("knobs saved before this option open with it off", (try? JSONDecoder().decode(RabbitHoleKnobs.self, from: Data(#"{"familiarity":1,"wander":2}"#.utf8)))?.newMusic == 0)
            var knobs = RabbitHoleKnobs(); knobs.newMusic = 2
            check("the option survives saving", (try? JSONDecoder().decode(RabbitHoleKnobs.self, from: JSONEncoder().encode(knobs)))?.newMusic == 2)
            check("an out-of-range value is brought back into range", (try? JSONDecoder().decode(RabbitHoleKnobs.self, from: Data(#"{"newMusic":9}"#.utf8)))?.newMusic == 2)
            check("a saved step is not new, and one that is new survives saving",
                  (try? JSONDecoder().decode(RabbitHoleTrack.self, from: Data(#"{"artist":"A","track":"T","playCount":3,"matchScore":80,"source":"s"}"#.utf8)))?.isNew == nil
                    && (sample.flatMap { try? JSONDecoder().decode(RabbitHoleTrack.self, from: JSONEncoder().encode($0)) })?.isNew == true)
            check("an old similar-sounds setting opens with new music off", (try? JSONDecoder().decode(SimilarSoundsView.Options.self, from: Data(#"{"seeds":[],"sort":"matchScore","songLimit":50}"#.utf8)))?.includeNew == false)

            print(failures == 0 ? "ALL NEW MUSIC CHECKS PASSED" : "\(failures) NEW MUSIC CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

/// A random source that always gives the same sequence, so a check can be repeated exactly.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
