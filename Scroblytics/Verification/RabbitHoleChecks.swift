import Foundation
import os
import SwiftData

#if DEBUG
/// A stand-in for Last.fm's similarity answers, with a count of the questions asked.
private final class StubSimilarity: RabbitHoleSimilarityProviding, @unchecked Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (tracks: 0, artists: 0))
    var tracks: [String: [SimilarTrack]] = [:]
    var artists: [String: [SimilarArtist]] = [:]
    var failTracksFor: Set<String> = []
    var trackCalls: Int { counts.withLock { $0.tracks } }
    var artistCalls: Int { counts.withLock { $0.artists } }

    struct Failure: Error {}

    func similarTracks(artist: String, track: String) async throws -> [SimilarTrack] {
        counts.withLock { $0.tracks += 1 }
        if failTracksFor.contains(track.lowercased()) { throw Failure() }
        return tracks[track.lowercased()] ?? []
    }

    func similarArtists(artist: String) async throws -> [SimilarArtist] {
        counts.withLock { $0.artists += 1 }
        return artists[artist.lowercased()] ?? []
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

/// `SCROBLYTICS_RABBITHOLE_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): Rabbit Hole's candidate pool, picking, memory,
/// saved-settings compatibility and similarity cache, on made-up data with a stand-in for Last.fm. Exits 0 on success.
///
/// `SCROBLYTICS_RABBITHOLE_DUMP=<file>` with `SCROBLYTICS_RABBITHOLE_SEEDS="Artist|Title;…"` is the live, read-only measurement against
/// the real Last.fm and a COPY of a real library (pool size and variety per seed).
enum RabbitHoleChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        if ProcessInfo.processInfo.environment["SCROBLYTICS_RABBITHOLE_DUMP"] != nil {
            runDump(container: container)
            return
        }
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_RABBITHOLE_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }

            // MARK: A made-up history with listening sessions
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            var history: [ScrobbleSnapshot] = []
            var clock = t0
            func play(_ artist: String, _ track: String, album: String = "", image: String? = nil, after seconds: TimeInterval = 4_000_000) {
                clock = clock.addingTimeInterval(seconds)
                history.append(ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: image, playedAt: clock))
            }
            let placeholder = "https://lastfm.example/2a96cbd8b46e442fc41c2b86b821562f.png"
            // Three separate sessions where X is followed within 5 minutes by Y.
            for _ in 0..<3 { play("Artist A", "X", album: "A1"); play("Artist B", "Y", after: 300) }
            // A follow-on after a long gap does not count; a one-off pair is below the minimum.
            play("Artist A", "X"); play("Artist C", "Z", after: 1_200)
            play("Artist D", "W"); play("Artist A", "X", after: 100)
            // The same track twice in a row is not a follow-on.
            play("Artist E", "Loop"); play("Artist E", "Loop", after: 60)
            play("Artist A", "X", album: "A1", image: placeholder); play("Artist A", "X", album: "A2", after: 4_000_000); play("Artist A", "X", album: "A1", image: "https://img.example/x.jpg", after: 4_000_000)
            // Filler tracks by similar artists.
            for n in 1...8 { play("Artist F", "F\(n)", after: 4_000_000); play("Artist F", "F\(n)", after: 4_000_000_0) }
            for n in 1...4 { play("Artist G", "G\(n)") }
            let library = RabbitHoleLibrary.build(scrobbles: history)
            let x = library.index(artist: "Artist A", track: "X")!
            let y = library.index(artist: "Artist B", track: "Y")!
            let follows = library.playedNext(after: x)
            check("the history is indexed by track, ignoring case", library.index(artist: "artist a", track: "x") == x && library.tracks[x].plays >= 6)
            check("a track's most-played album is its album", library.tracks[x].album == "A1")
            check("a placeholder picture is not used as artwork", library.tracks[x].imageURL == "https://img.example/x.jpg")
            check("a habit (3 plays right after) is found", follows.contains { $0.to == y && $0.count == 3 }, "\(follows)")
            check("a follow-on after a 20-minute gap is not counted", !follows.contains { library.tracks[$0.to].name == "Z" })
            check("a one-off follow-on is below the minimum", library.playedNext(after: library.index(artist: "Artist D", track: "W")!).isEmpty)
            check("the same track twice in a row is not a follow-on", library.playedNext(after: library.index(artist: "Artist E", track: "Loop")!).isEmpty)

            // MARK: The candidate pool
            var tags = EntityTagsSnapshot()
            tags.artistCommunity[EntityTagsSnapshot.artistKey("Artist A")] = ["dream pop", "slowcore", "indie"]
            tags.artistCommunity[EntityTagsSnapshot.artistKey("Artist G")] = ["dream pop", "slowcore", "folk"]
            tags.artistCommunity[EntityTagsSnapshot.artistKey("Artist F")] = ["metal"]
            let stub = StubSimilarity()
            stub.tracks["x"] = [SimilarTrack(name: "Y", artist: "Artist B", match: 0.9), SimilarTrack(name: "Not In Library", artist: "Nobody", match: 0.8), SimilarTrack(name: "G1", artist: "Artist G", match: 0.5)]
            stub.artists["artist a"] = [SimilarArtist(name: "Artist F", match: 0.7), SimilarArtist(name: "Artist Unknown", match: 0.6)]
            let seed = RabbitHoleCandidates.Seed(artist: "Artist A", track: "X", weight: 1)
            var pool = (try? await RabbitHoleCandidates.build(seeds: [seed], excluding: [], library: library, tags: tags, bpm: .empty, lovedKeys: [], provider: stub)) ?? []
            func candidate(_ name: String) -> RabbitHoleScoredCandidate? { pool.first { library.tracks[$0.trackIndex].name == name } }
            check("a Last.fm similar track you've played is offered, one you haven't is not", candidate("Y") != nil && !pool.contains { library.tracks[$0.trackIndex].name == "Not In Library" })
            check("the track itself is never offered", candidate("X") == nil)
            check("a track you play after it is offered because of that habit", candidate("Y")?.reasons.contains { $0.kind == .playedNext && $0.text.contains("3 times") } == true)
            check("a track offered by two kinds of source keeps both reasons and scores higher than the best one alone",
                  candidate("Y").map { $0.sources.isSuperset(of: [.similar, .playedNext]) && $0.score > 90 } == true, "\(candidate("Y")?.score ?? 0)")
            check("few similar tracks (under 15): similar artists are added, with their most-played tracks", candidate("F1") != nil && candidate("F1")?.reasons.contains { $0.kind == .similarArtist } == true)
            check("at most 6 tracks come from one similar artist", pool.filter { library.tracks[$0.trackIndex].artist == "Artist F" }.count <= 6)
            check("tracks by an artist sharing tags are offered, saying which tags", candidate("G2")?.reasons.contains { $0.kind == .sharedTags && $0.text.contains("dream pop") } == true)
            check("an artist with no tag in common is not offered for tags alone", candidate("F2")?.sources.contains(.sharedTags) != true)
            check("the second step out is taken when the pool is still thin", stub.trackCalls > 1)

            // A big enough track list does not trigger the fallbacks.
            let busy = StubSimilarity()
            busy.tracks["x"] = (1...8).map { SimilarTrack(name: "F\($0)", artist: "Artist F", match: 0.5) } + (1...4).map { SimilarTrack(name: "G\($0)", artist: "Artist G", match: 0.5) } + [SimilarTrack(name: "Y", artist: "Artist B", match: 0.9)]
            // (13 playable: still under 15, so make it 15 with the other tracks)
            busy.tracks["x"]! += [SimilarTrack(name: "Z", artist: "Artist C", match: 0.4), SimilarTrack(name: "W", artist: "Artist D", match: 0.4)]
            let busyPool = (try? await RabbitHoleCandidates.build(seeds: [seed], excluding: [], library: library, tags: .empty, bpm: .empty, lovedKeys: [], provider: busy)) ?? []
            check("15 playable similar tracks: no similar-artist lookup is made", busy.artistCalls == 0 && busyPool.count >= 15, "\(busy.artistCalls) \(busyPool.count)")

            // Exclusions and failures
            let withPath = (try? await RabbitHoleCandidates.build(seeds: [seed], excluding: [y], library: library, tags: tags, bpm: .empty, lovedKeys: [], provider: stub)) ?? []
            check("tracks already on the path are left out", !withPath.contains { $0.trackIndex == y })
            let failing = StubSimilarity(); failing.failTracksFor = ["x"]
            let thrown: Bool
            do { _ = try await RabbitHoleCandidates.build(seeds: [seed], excluding: [], library: library, tags: tags, bpm: .empty, lovedKeys: [], provider: failing); thrown = false } catch { thrown = true }
            check("a failed lookup for the step's own track is reported, not hidden", thrown)
            let earlier = RabbitHoleCandidates.Seed(artist: "Artist B", track: "Y", weight: 0.5)
            failing.failTracksFor = ["y"]; failing.tracks["x"] = stub.tracks["x"]
            let soft = (try? await RabbitHoleCandidates.build(seeds: [seed, earlier], excluding: [], library: library, tags: tags, bpm: .empty, lovedKeys: [], provider: failing)) ?? []
            check("a failed lookup for an earlier step is skipped quietly", !soft.isEmpty)
            pool = []

            // MARK: Picking
            let now = Date()
            func item(_ name: String, artist: String = "a", score: Double = 50, plays: Int = 10, ago: Double = 10, loved: Bool = false, tag: String? = nil) -> RabbitHoleSelector.Item {
                RabbitHoleSelector.Item(key: name, artistKey: artist, albumKey: artist + "\u{0}" + name, topTag: tag, score: score, plays: plays, lastPlayed: now.addingTimeInterval(-ago * 86400), loved: loved)
            }
            var neutral = RabbitHoleKnobs(); neutral.avoidRepeats = false
            let empty = RabbitHoleMemory()
            let favourite = item("fav", plays: 200, ago: 3, loved: true), forgotten = item("old", plays: 2, ago: 900)
            var familiar = neutral; familiar.familiarity = 2
            var forgettable = neutral; forgettable.familiarity = -2
            func ratio(_ knobs: RabbitHoleKnobs) -> Double { RabbitHoleSelector.weight(favourite, knobs: knobs, memory: empty, now: now) / RabbitHoleSelector.weight(forgotten, knobs: knobs, memory: empty, now: now) }
            check("leaning familiar favours the loved, often-played track; leaning forgotten favours the old one", ratio(familiar) > ratio(neutral) && ratio(neutral) > ratio(forgettable) && ratio(forgettable) < 1, "\(ratio(familiar)) \(ratio(neutral)) \(ratio(forgettable))")
            var close = neutral; close.wander = 0
            var wide = neutral; wide.wander = 2
            func spread(_ k: RabbitHoleKnobs) -> Double { RabbitHoleSelector.weight(item("hi", score: 90), knobs: k, memory: empty, now: now) / RabbitHoleSelector.weight(item("lo", score: 30), knobs: k, memory: empty, now: now) }
            check("staying close favours the best match more than wandering does", spread(close) > spread(neutral) && spread(neutral) > spread(wide), "\(spread(close)) \(spread(neutral)) \(spread(wide))")

            var memory = RabbitHoleMemory()
            memory.noteShown(["s"], now: now); memory.noteChosen("c", now: now)
            check("something just shown is down-weighted to about 0.35, just chosen to about 0.5", abs(memory.penalty(for: "s", now: now) - 0.35) < 0.01 && abs(memory.penalty(for: "c", now: now) - 0.5) < 0.01)
            check("the penalty fades away after a week", memory.penalty(for: "s", now: now.addingTimeInterval(RabbitHoleMemory.window + 1)) == 1)
            var big = RabbitHoleMemory()
            for n in 0..<700 { big.shown["k\(n)"] = now.addingTimeInterval(Double(-n)) }
            big.prune(now: now)
            check("the memory is kept to \(RabbitHoleMemory.capacity) entries, newest kept", big.shown.count == RabbitHoleMemory.capacity && big.shown["k0"] != nil && big.shown["k699"] == nil)

            let pickPool = (0..<30).map { item("t\($0)", artist: "artist\($0 % 10)", score: Double(40 + $0 % 50)) }
            var rngA = SeededGenerator(state: 42)
            let three = RabbitHoleSelector.pick(pickPool, count: 3, knobs: neutral, memory: empty, pathArtistCounts: [:], pathAlbumCounts: [:], perArtist: 0, perAlbum: 0, now: now, using: &rngA)
            check("three picks are made, all different", three.count == 3 && Set(three.map(\.key)).count == 3)
            let sameArtist = (0..<12).map { item("s\($0)", artist: $0 < 9 ? "one" : "two") }
            var rngB = SeededGenerator(state: 7)
            var spreadOut = 0
            for _ in 0..<50 {
                let picks = RabbitHoleSelector.pick(sameArtist, count: 3, knobs: neutral, memory: empty, pathArtistCounts: [:], pathAlbumCounts: [:], perArtist: 0, perAlbum: 0, now: now, using: &rngB)
                if Set(picks.map(\.artistKey)).count > 1 { spreadOut += 1 }
            }
            check("when two artists are available the three picks usually include both", spreadOut >= 40, "\(spreadOut) of 50")
            var rngC = SeededGenerator(state: 3)
            let capped = RabbitHoleSelector.pick(pickPool, count: 3, knobs: neutral, memory: empty, pathArtistCounts: ["artist0": 1], pathAlbumCounts: [:], perArtist: 1, perAlbum: 0, now: now, using: &rngC)
            check("the per-artist limit counts what is already on the path", !capped.contains { $0.artistKey == "artist0" } && Set(capped.map(\.artistKey)).count == capped.count)

            // Variety over repeated "New Suggestions": with the memory on, far fewer repeats.
            func distinctSeen(avoid: Bool) -> Int {
                var knobs = neutral; knobs.avoidRepeats = avoid
                var mem = RabbitHoleMemory(); var seen = Set<String>(); var rng = SeededGenerator(state: 99)
                for round in 0..<15 {
                    let at = now.addingTimeInterval(Double(round) * 60)
                    let picks = RabbitHoleSelector.pick(pickPool, count: 3, knobs: knobs, memory: mem, pathArtistCounts: [:], pathAlbumCounts: [:], perArtist: 0, perAlbum: 0, now: at, using: &rng)
                    seen.formUnion(picks.map(\.key)); mem.noteShown(picks.map(\.key), now: at)
                }
                return seen.count
            }
            let without = distinctSeen(avoid: false), with = distinctSeen(avoid: true)
            check("15 refreshes of a 30-track pool show more different tracks with the memory on (\(with)) than off (\(without))", with > without, "\(with) vs \(without)")

            // MARK: Saved settings from before keep working
            let oldOptions = Data(#"{"tree":{"nodes":[]},"groups":[],"perArtist":2,"perAlbum":1}"#.utf8)
            let decoded = try? JSONDecoder().decode(RabbitHoleView.Options.self, from: oldOptions)
            check("settings saved before the new options still open, with defaults for the new ones", decoded?.perArtist == 2 && decoded?.perAlbum == 1 && decoded?.knobs == RabbitHoleKnobs() && decoded?.memory.shown.isEmpty == true)
            let oldTrack = Data(#"{"artist":"A","track":"T","playCount":3,"matchScore":80,"source":"s"}"#.utf8)
            check("a saved step without reasons still decodes", (try? JSONDecoder().decode(RabbitHoleTrack.self, from: oldTrack))?.reasons == nil)
            let roundTrip = try? JSONDecoder().decode(RabbitHoleKnobs.self, from: JSONEncoder().encode({ var k = RabbitHoleKnobs(); k.familiarity = -2; k.wander = 2; k.avoidRepeats = false; return k }()))
            check("the knobs survive saving", roundTrip == { var k = RabbitHoleKnobs(); k.familiarity = -2; k.wander = 2; k.avoidRepeats = false; return k }())
            let order = RabbitHoleEngine.topReasons([RabbitHoleReason(kind: .tempo, text: "t"), RabbitHoleReason(kind: .sharedTags, text: "g"), RabbitHoleReason(kind: .playedNext, text: "p"), RabbitHoleReason(kind: .similar, text: "s")])
            check("at most three reasons are shown, the most telling first", order.map(\.kind) == [.playedNext, .similar, .sharedTags])

            // MARK: The engine, end to end on the made-up history
            let snapshots = QuerySnapshots(entityTags: tags)
            let node = RabbitHoleTrack(artist: "Artist A", track: "X", album: "A1", imageURL: nil, playCount: 6, lastPlayed: nil, matchScore: 0, source: "start")
            let rootNode = RabbitHoleNode(id: UUID(), track: node, parentID: nil, candidates: nil, childIDs: [])
            var rngD = SeededGenerator(state: 5)
            let generated = try? await RabbitHoleEngine.generate(
                from: node, path: [rootNode], groups: [], perArtist: 1, perAlbum: 0, knobs: neutral, memory: empty, library: library,
                scrobbles: history, snapshots: snapshots, provider: stub, now: now, using: &rngD
            )
            check("the engine offers three tracks, none is the start, each says why", generated?.candidates.count == 3 && generated?.candidates.allSatisfy { $0.track != "X" && ($0.reasons?.isEmpty == false) } == true, "\(generated?.candidates.map(\.track) ?? [])")
            check("it reports the pool the three came from", (generated?.poolSize ?? 0) >= 3 && (generated?.totalBeforeConditions ?? 0) >= (generated?.poolSize ?? 0))
            check("per-artist limit 1 gives three different artists", Set((generated?.candidates ?? []).map(\.artist)).count == generated?.candidates.count)

            // MARK: Starting without searching
            let later = Date(timeIntervalSince1970: 2_300_000_000) // long after every play in the made-up history
            let lovedX: Set<String> = [library.tracks[x].key]
            var rngS = SeededGenerator(state: 11)
            check("'what's playing' finds that track in the library, and nothing when it isn't there",
                  RabbitHoleSeeds.shortlist(.nowPlaying, library: library, lovedKeys: [], nowPlaying: ("artist a", "x"), using: &rngS) == [x]
                    && RabbitHoleSeeds.shortlist(.nowPlaying, library: library, lovedKeys: [], nowPlaying: ("Nobody", "Nothing"), using: &rngS).isEmpty
                    && RabbitHoleSeeds.shortlist(.nowPlaying, library: library, lovedKeys: [], nowPlaying: nil, using: &rngS).isEmpty)
            check("a forgotten favourite is a loved (or heavily played) track left alone for a year",
                  RabbitHoleSeeds.shortlist(.forgottenFavourite, library: library, lovedKeys: lovedX, nowPlaying: nil, now: later, using: &rngS) == [x])
            check("nothing is 'forgotten' when it was all played recently",
                  RabbitHoleSeeds.shortlist(.forgottenFavourite, library: library, lovedKeys: lovedX, nowPlaying: nil, now: t0, using: &rngS).isEmpty)
            let top = RabbitHoleSeeds.shortlist(.topTracks, library: library, lovedKeys: [], nowPlaying: nil, using: &rngS)
            check("top tracks are real library tracks, at most 12", !top.isEmpty && top.count <= 12 && top.allSatisfy { library.tracks.indices.contains($0) })
            let surprise = RabbitHoleSeeds.shortlist(.surprise, library: library, lovedKeys: [], nowPlaying: nil, using: &rngS)
            check("a surprise is a track played more than once", !surprise.isEmpty && surprise.allSatisfy { library.tracks[$0].plays >= 2 })
            let sizes = [10: 2, 11: 3, 12: 9, 13: 4, 14: 20]
            let viable = await RabbitHoleSeeds.firstViable([10, 11, 12, 13, 14]) { sizes[$0] ?? 0 }
            check("the first starting track with a big enough pool is taken", viable == 12)
            let none = await RabbitHoleSeeds.firstViable([10, 11, 13, 10, 14]) { sizes[$0] ?? 0 }
            check("only four are tried: a fifth that qualifies is not reached", none == nil)

            // MARK: Take steps for me
            func offered(_ names: [String], scores: [Int]) -> [RabbitHoleTrack] {
                zip(names, scores).enumerated().map { i, pair in
                    RabbitHoleTrack(artist: "Walker \(pair.0)", track: pair.0, album: nil, imageURL: nil, playCount: 5, lastPlayed: now.addingTimeInterval(Double(-(i + 1)) * 86400 * 100), matchScore: pair.1, source: "stub")
                }
            }
            final class Counter: @unchecked Sendable { var calls = 0; var firstRootCalls = 0 }
            func startTree() -> RabbitHoleTree {
                let id = UUID()
                return RabbitHoleTree(rootID: id, nodes: [id: RabbitHoleNode(id: id, track: RabbitHoleTrack(artist: "Start", track: "Start", album: nil, imageURL: nil, playCount: 1, lastPlayed: nil, matchScore: 0, source: "s"), parentID: nil, candidates: nil, childIDs: [])], currentID: id)
            }
            // Always offeredThree freshOffers, never-seen tracks, best match first.
            let counter = Counter()
            let freshOffers: (RabbitHoleTree, RabbitHoleNode, RabbitHoleMemory) async throws -> [RabbitHoleTrack] = { _, _, _ in
                counter.calls += 1
                let n = counter.calls
                return offered(["W\(n)a", "W\(n)b", "W\(n)c"], scores: [90, 70, 50])
            }
            var rngW = SeededGenerator(state: 21)
            let sixty = try? await RabbitHoleWalk.run(length: .minutes60, rule: .mostSimilar, tree: startTree(), memory: RabbitHoleMemory(), candidatesFor: freshOffers, seconds: { _ in 200 }, using: &rngW)
            check("a 60-minute walk of 200-second tracks adds 18 tracks, stopping at the first that reaches the hour",
                  sixty?.progress.tracksAdded == 18 && sixty?.ending == .reachedLength && (sixty?.progress.seconds ?? 0) == 3600, "\(sixty?.progress.tracksAdded ?? -1)")
            let pathOfSixty = sixty?.tree.path() ?? []
            check("the path is the start plus the 18 steps, each linked to its parent, no track twice",
                  pathOfSixty.count == 19 && Set(pathOfSixty.map(\.track.id)).count == 19 && pathOfSixty.dropFirst().allSatisfy { $0.parentID != nil && sixty?.tree.nodes[$0.parentID!] != nil })
            check("each step keeps the offeredThree options it chose from", (pathOfSixty.dropLast().allSatisfy { ($0.candidates ?? []).count == 3 }))
            check("the walk reports the nodes it added, in order", sixty?.addedNodeIDs == pathOfSixty.dropFirst().map(\.id))
            counter.calls = 0
            let twenty = try? await RabbitHoleWalk.run(length: .tracks20, rule: .balanced, tree: startTree(), memory: RabbitHoleMemory(), candidatesFor: freshOffers, seconds: { _ in 200 }, using: &rngW)
            check("a 20-track walk adds exactly 20", twenty?.progress.tracksAdded == 20 && twenty?.ending == .reachedLength)
            counter.calls = 0
            let quick = try? await RabbitHoleWalk.run(length: .minutes90, rule: .balanced, tree: startTree(), memory: RabbitHoleMemory(), candidatesFor: freshOffers, seconds: { _ in 1 }, using: &rngW)
            check("a walk never goes past \(RabbitHoleWalk.maxSteps) steps", quick?.progress.tracksAdded == RabbitHoleWalk.maxSteps && quick?.ending == .stepLimit)
            counter.calls = 0
            let unknown = try? await RabbitHoleWalk.run(length: .minutes60, rule: .balanced, tree: startTree(), memory: RabbitHoleMemory(), candidatesFor: freshOffers, seconds: { _ in nil }, using: &rngW)
            check("tracks of unknown length count as about 3.5 minutes and the result is marked approximate",
                  unknown?.progress.approximate == true && unknown?.progress.tracksAdded == 18 && unknown?.progress.seconds == 18 * RabbitHoleWalk.assumedTrackSeconds)

            // A dead end is backed out of.
            let deadCounter = Counter()
            let withDeadEnd: (RabbitHoleTree, RabbitHoleNode, RabbitHoleMemory) async throws -> [RabbitHoleTrack] = { _, node, _ in
                deadCounter.calls += 1
                if node.track.track == "DEAD1" { return [] }
                if node.parentID == nil {
                    deadCounter.firstRootCalls += 1
                    return deadCounter.firstRootCalls == 1 ? offered(["DEAD1", "A", "B"], scores: [95, 80, 70]) : offered(["DEAD1", "C", "D"], scores: [95, 85, 60])
                }
                return offered(["X\(deadCounter.calls)a", "X\(deadCounter.calls)b", "X\(deadCounter.calls)c"], scores: [90, 70, 50])
            }
            let recovered = try? await RabbitHoleWalk.run(length: .tracks10, rule: .mostSimilar, tree: startTree(), memory: RabbitHoleMemory(), candidatesFor: withDeadEnd, seconds: { _ in 200 }, using: &rngW)
            let recoveredPath = recovered?.tree.path() ?? []
            check("a dead end is backed out of and the walk carries on to its length", recovered?.progress.tracksAdded == 10 && recovered?.ending == .reachedLength, "\(recovered?.progress.tracksAdded ?? -1) \(String(describing: recovered?.ending))")
            check("the dead end is not on the path, and its time is not counted", !recoveredPath.contains { $0.track.track == "DEAD1" } && recoveredPath.count == 11 && recovered?.progress.seconds == 2000)
            let stuckCounter = Counter()
            let alwaysDead: (RabbitHoleTree, RabbitHoleNode, RabbitHoleMemory) async throws -> [RabbitHoleTrack] = { _, node, _ in
                stuckCounter.calls += 1
                return node.parentID == nil ? offered(["S\(stuckCounter.calls)a", "S\(stuckCounter.calls)b", "S\(stuckCounter.calls)c"], scores: [90, 70, 50]) : []
            }
            let stuck = try? await RabbitHoleWalk.run(length: .tracks10, rule: .mostSimilar, tree: startTree(), memory: RabbitHoleMemory(), candidatesFor: alwaysDead, seconds: { _ in 200 }, using: &rngW)
            check("repeated dead ends end the walk, back at where it began", stuck?.ending == .deadEnd && stuck?.progress.tracksAdded == 0 && stuck?.tree.currentID == stuck?.tree.rootID)

            // Stopping keeps a valid tree; an error keeps what was done.
            final class Box: @unchecked Sendable { var task: Task<RabbitHoleWalk.Result?, Never>? }
            let box = Box(); let stopCounter = Counter()
            box.task = Task { @MainActor in
                var rng = SeededGenerator(state: 8)
                return try? await RabbitHoleWalk.run(length: .minutes90, rule: .balanced, tree: startTree(), memory: RabbitHoleMemory(), candidatesFor: { _, _, _ in
                    stopCounter.calls += 1
                    if stopCounter.calls == 5 { box.task?.cancel() }
                    return offered(["P\(stopCounter.calls)a", "P\(stopCounter.calls)b", "P\(stopCounter.calls)c"], scores: [90, 70, 50])
                }, seconds: { _ in 200 }, using: &rng)
            }
            let stopped = await box.task?.value ?? nil
            check("stopping ends the walk where it is, with a valid tree", stopped?.ending == .stoppedByUser && (4...6).contains(stopped?.progress.tracksAdded ?? 0) && stopped?.tree.path().count == (stopped?.progress.tracksAdded ?? 0) + 1)
            let errCounter = Counter()
            let walkFailing: (RabbitHoleTree, RabbitHoleNode, RabbitHoleMemory) async throws -> [RabbitHoleTrack] = { _, _, _ in
                errCounter.calls += 1
                if errCounter.calls == 4 { throw StubSimilarity.Failure() }
                return offered(["E\(errCounter.calls)a", "E\(errCounter.calls)b", "E\(errCounter.calls)c"], scores: [90, 70, 50])
            }
            let failed = try? await RabbitHoleWalk.run(length: .minutes60, rule: .balanced, tree: startTree(), memory: RabbitHoleMemory(), candidatesFor: walkFailing, seconds: { _ in 200 }, using: &rngW)
            var failedAfterThree = false
            if case .failed? = failed?.ending { failedAfterThree = failed?.progress.tracksAdded == 3 }
            check("an error mid-walk keeps the steps already taken", failedAfterThree)

            // Rules and removal.
            let offeredThree = offered(["Hi", "Mid", "Lo"], scores: [90, 70, 50]) // lastPlayed gets older down the list
            var rngR = SeededGenerator(state: 2)
            check("'most similar' takes the best match; 'least recently played' takes the oldest",
                  RabbitHoleWalk.choose(from: offeredThree, rule: .mostSimilar, using: &rngR)?.track == "Hi" && RabbitHoleWalk.choose(from: offeredThree, rule: .leastRecent, using: &rngR)?.track == "Lo")
            check("'balanced' and 'wander' take one of the offeredThree, and nothing from none",
                  offeredThree.map(\.track).contains(RabbitHoleWalk.choose(from: offeredThree, rule: .balanced, using: &rngR)?.track ?? "") && RabbitHoleWalk.choose(from: [], rule: .wander, using: &rngR) == nil)
            var basis = RabbitHoleKnobs(); basis.familiarity = 1; basis.wander = 1
            check("each rule steers the picks: close, as set, wandering, forgotten",
                  RabbitHoleWalkRule.mostSimilar.knobs(base: basis).wander == 0 && RabbitHoleWalkRule.balanced.knobs(base: basis) == basis
                    && RabbitHoleWalkRule.wander.knobs(base: basis).wander == 2 && RabbitHoleWalkRule.leastRecent.knobs(base: basis).familiarity == -2)
            let before = startTree()
            counter.calls = 0
            let walked = try? await RabbitHoleWalk.run(length: .tracks10, rule: .balanced, tree: before, memory: RabbitHoleMemory(), candidatesFor: freshOffers, seconds: { _ in 200 }, using: &rngW)
            let restored = RabbitHoleWalk.remove(walk: walked?.addedNodeIDs ?? [], from: walked?.tree ?? before)
            check("removing a walk takes its steps off and returns to where it began", restored.nodes.count == 1 && restored.currentID == before.rootID && restored.nodes[before.rootID!]?.childIDs.isEmpty == true)
            let oldWalkOptions = Data(#"{"tree":{"nodes":[]},"groups":[],"perArtist":1,"perAlbum":0}"#.utf8)
            let walkDefaults = try? JSONDecoder().decode(RabbitHoleView.Options.self, from: oldWalkOptions)
            check("settings from before walks default to a balanced 60-minute walk", walkDefaults?.walkRule == .balanced && walkDefaults?.walkLength == .minutes60 && walkDefaults?.lastWalk.isEmpty == true)

            // MARK: The similarity cache
            let store = SimilarityCacheStore(modelContainer: container)
            let payload = Data(#"[{"name":"Y","artist":"Artist B","match":0.9}]"#.utf8)
            let key = "track\u{1F}artist a\u{1F}x-check"
            await store.write(key, payload: payload, now: now)
            let fresh = await store.read(key, maxAge: LastfmSimilarityProvider.maxAge, now: now.addingTimeInterval(86_400))
            let stale = await store.read(key, maxAge: LastfmSimilarityProvider.maxAge, now: now.addingTimeInterval(31 * 86_400))
            check("a stored answer is returned within 30 days and not after", fresh == payload && stale == nil)
            let provider = LastfmSimilarityProvider(client: LastfmAPIClient(apiKey: "0123456789abcdef0123456789abcdef", username: "nobody"), store: store)
            await store.write("track\u{1F}artist a\u{1F}x", payload: payload, now: Date())
            let cached = try? await provider.similarTracks(artist: "Artist A", track: "X")
            check("a cached answer is used without asking Last.fm", cached?.first?.name == "Y" && cached?.first?.artist == "Artist B")
            ConnectivityGate.set(offline: true)
            let offlineResult: Bool
            do { _ = try await provider.similarTracks(artist: "Someone", track: "Never Asked"); offlineResult = false } catch { offlineResult = true }
            ConnectivityGate.set(offline: false)
            let leaked = await store.read("track\u{1F}someone\u{1F}never asked", maxAge: LastfmSimilarityProvider.maxAge)
            check("offline, an uncached lookup fails and nothing is remembered as 'no data'", offlineResult && leaked == nil)

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: - Live, read-only measurement

    /// Per seed: how many library tracks each source gave, how many tracks the pool offered, and how many different tracks ten
    /// consecutive "New Suggestions" showed (with the memory on). Uses the real Last.fm (read-only) and the store at `SCROBLYTICS_STORE_PATH`.
    @MainActor
    private static func runDump(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SCROBLYTICS_RABBITHOLE_DUMP"] else { return }
        Task { @MainActor in
            var out: [String] = []
            do {
                guard let credentials = LastfmCredentialsStore.load() else { throw NSError(domain: "rabbithole", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Last.fm credentials"]) }
                let raw = try container.mainContext.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
                let scrobbles = QueryIdentity.canonicalizingArtists(raw)
                let library = RabbitHoleLibrary.build(scrobbles: scrobbles)
                let loaded = await QuerySnapshotReader(modelContainer: container).loadAll()
                let snapshots = QuerySnapshots(
                    durations: loaded.durations, releaseDates: loaded.releaseDates, turnover: loaded.turnover, lovedKeys: loaded.lovedKeys,
                    flaggedKeys: loaded.flaggedKeys, entityTags: loaded.entityTags, images: loaded.images
                )
                let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
                let provider = LastfmSimilarityProvider(client: client, store: SimilarityCacheStore(modelContainer: container))
                out.append("LIBRARY \(library.tracks.count) tracks")
                for spec in (env["SCROBLYTICS_RABBITHOLE_SEEDS"] ?? "").split(separator: ";") {
                    let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let seedIndex = library.index(artist: parts[0], track: parts[1]) else { out.append("SEED \(spec): not in the library"); continue }
                    let track = library.tracks[seedIndex]
                    let seed = RabbitHoleTrack(artist: track.artist, track: track.name, album: track.album, imageURL: nil, playCount: track.plays, lastPlayed: track.lastPlayed, matchScore: 0, source: "start")
                    let root = RabbitHoleNode(id: UUID(), track: seed, parentID: nil, candidates: nil, childIDs: [])
                    var memory = RabbitHoleMemory()
                    let started = Date()
                    var seen = Set<String>(); var first: RabbitHoleGeneration?
                    for round in 0..<10 {
                        let generated = try await RabbitHoleEngine.generate(
                            from: seed, path: [root], groups: [], perArtist: 1, perAlbum: 0, knobs: RabbitHoleKnobs(), memory: memory,
                            library: library, scrobbles: scrobbles, snapshots: snapshots, provider: provider
                        )
                        if round == 0 { first = generated }
                        seen.formUnion(generated.candidates.map(\.id))
                        memory.noteShown(generated.candidates.map(\.id))
                    }
                    // A 60-minute walk from this seed, as the "Take steps for me" panel would run it.
                    let walkStart = Date()
                    let walkStartTree = RabbitHoleTree(rootID: root.id, nodes: [root.id: root], currentID: root.id)
                    var walkRNG = SystemRandomNumberGenerator()
                    let walkKnobs = RabbitHoleWalkRule.balanced.knobs(base: RabbitHoleKnobs())
                    let walk = try await RabbitHoleWalk.run(
                        length: .minutes60, rule: .balanced, tree: walkStartTree, memory: RabbitHoleMemory(),
                        candidatesFor: { tree, node, mem in
                            try await RabbitHoleEngine.generate(
                                from: node.track, path: tree.path(to: node.id), groups: [], perArtist: 1, perAlbum: 0, knobs: walkKnobs, memory: mem,
                                library: library, scrobbles: scrobbles, snapshots: snapshots, provider: provider
                            ).candidates
                        },
                        seconds: { t in
                            if case .seconds(let value) = snapshots.durations.resolution(forKey: DurationEngine.cacheKey(artist: t.artist, track: t.track)) { return Double(value) }
                            return nil
                        },
                        using: &walkRNG
                    )
                    let walked = walk.tree.path()
                    let walkArtists = Set(walked.map { $0.track.artist.lowercased() })
                    out.append("   WALK \(walk.progress.tracksAdded) tracks, \(Int(walk.progress.seconds / 60)) min\(walk.progress.approximate ? " (about)" : ""), \(walkArtists.count) artists of \(walked.count), repeats=\(walked.count - Set(walked.map(\.track.id)).count), ending=\(walk.ending), seconds=\(String(format: "%.1f", Date().timeIntervalSince(walkStart)))")
                    let kinds = Set((first?.candidates ?? []).flatMap { ($0.reasons ?? []).map(\.kind.rawValue) })
                    out.append("SEED \(track.name) — \(track.artist): pool=\(first?.poolSize ?? 0) habits=\(library.playedNext(after: seedIndex).count) distinctInTenRefreshes=\(seen.count) seconds=\(String(format: "%.1f", Date().timeIntervalSince(started))) reasons=\(kinds.sorted())")
                    for c in first?.candidates ?? [] { out.append("   \(c.matchScore)\t\(c.track) — \(c.artist)\t\((c.reasons ?? []).map(\.text).joined(separator: " | "))") }
                }
            } catch {
                out.append("ERROR \(error)")
            }
            try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif
