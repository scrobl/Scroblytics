import Foundation
import SwiftData

/// Why a track is being offered at a Rabbit Hole step, in words a person can read ("you often play it after …").
struct RabbitHoleReason: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case similar, similarArtist, viaStep, sharedTags, playedNext, tempo, loved, forgotten, newToYou
    }
    let kind: Kind
    let text: String
}

/// Everything the tool knows about the tracks you've played, built once from the history: each track's plays, last play, album and
/// artwork, the tracks of each artist, and which track you tend to play right after which (within one listening session).
struct RabbitHoleLibrary: Sendable {
    struct Track: Sendable {
        let artist: String
        let name: String
        let album: String?
        let plays: Int
        let lastPlayed: Date
        let imageURL: String?
        var key: String { TextNormalization.lovedKey(artist: artist, track: name) }
    }

    /// Two plays count as "one after the other" when they are at most this far apart.
    static let sessionGap: TimeInterval = 10 * 60
    /// A follow-on needs to have happened at least this many times to count as a habit rather than a coincidence.
    static let minimumFollowCount = 2

    private(set) var tracks: [Track] = []
    private var indexByPair: [String: Int] = [:]
    private var indexesByArtist: [String: [Int]] = [:]
    private var followers: [Int: [(to: Int, count: Int)]] = [:]
    /// Every played track under `NewMusic.key`, so a track Last.fm spells slightly differently is still recognised as played.
    private var normalizedKeys: Set<String> = []

    static func pairKey(artist: String, track: String) -> String { artist.lowercased() + "\u{0}" + track.lowercased() }

    /// `scrobbles` must be ascending by `playedAt` (the library's own order) and artist-canonicalized.
    static func build(scrobbles: [ScrobbleSnapshot]) -> RabbitHoleLibrary {
        var library = RabbitHoleLibrary()
        var names: [(artist: String, name: String)] = []
        var plays: [Int] = []
        var lastPlayed: [Date] = []
        var images: [String?] = []
        var albumCounts: [[String: Int]] = []
        var transitions: [UInt64: Int] = [:]
        var previous: Int?
        var previousAt = Date.distantPast
        var previousAlbum = ""
        var previousArtist = ""
        for s in scrobbles {
            let key = pairKey(artist: s.artistName, track: s.trackName)
            let index: Int
            if let existing = library.indexByPair[key] {
                index = existing
            } else {
                index = names.count
                library.indexByPair[key] = index
                names.append((s.artistName, s.trackName))
                library.normalizedKeys.insert(NewMusic.key(artist: s.artistName, track: s.trackName))
                plays.append(0)
                lastPlayed.append(s.playedAt)
                images.append(nil)
                albumCounts.append([:])
            }
            plays[index] += 1
            lastPlayed[index] = s.playedAt
            if let url = s.imageURL, !TextNormalization.isLastfmPlaceholderImage(url) { images[index] = url }
            if !s.albumName.isEmpty { albumCounts[index][s.albumName, default: 0] += 1 }
            // Track 4 following track 3 of the same album says nothing about your taste, only about the album's order.
            let sameAlbumOrder = !s.albumName.isEmpty && s.albumName == previousAlbum && s.artistName == previousArtist
            if let previous, previous != index, !sameAlbumOrder, s.playedAt.timeIntervalSince(previousAt) <= sessionGap {
                transitions[UInt64(previous) << 32 | UInt64(index), default: 0] += 1
            }
            previous = index
            previousAt = s.playedAt
            previousAlbum = s.albumName
            previousArtist = s.artistName
        }
        library.tracks = names.indices.map { i in
            let album = albumCounts[i].max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
            return Track(artist: names[i].artist, name: names[i].name, album: album, plays: plays[i], lastPlayed: lastPlayed[i], imageURL: images[i])
        }
        for (i, track) in library.tracks.enumerated() { library.indexesByArtist[track.artist.lowercased(), default: []].append(i) }
        for (artist, list) in library.indexesByArtist {
            library.indexesByArtist[artist] = list.sorted { library.tracks[$0].plays > library.tracks[$1].plays }
        }
        for (packed, count) in transitions where count >= minimumFollowCount {
            library.followers[Int(packed >> 32), default: []].append((Int(packed & 0xFFFF_FFFF), count))
        }
        for (from, list) in library.followers { library.followers[from] = list.sorted { $0.count > $1.count } }
        return library
    }

    func index(artist: String, track: String) -> Int? { indexByPair[Self.pairKey(artist: artist, track: track)] }

    /// Whether you have played this track (however Last.fm spells it).
    func hasPlayed(artist: String, track: String) -> Bool {
        indexByPair[Self.pairKey(artist: artist, track: track)] != nil || normalizedKeys.contains(NewMusic.key(artist: artist, track: track))
    }

    /// The artist's tracks, most played first. `artist` is matched without regard to case.
    func trackIndexes(ofArtist artist: String) -> [Int] { indexesByArtist[artist.lowercased()] ?? [] }

    var artistKeys: [String] { Array(indexesByArtist.keys) }

    func canonicalArtist(_ lowercased: String) -> String? { indexesByArtist[lowercased].flatMap { $0.first }.map { tracks[$0].artist } }

    /// The tracks you tend to play right after this one, most often first (only habits: at least `minimumFollowCount` times).
    func playedNext(after index: Int) -> [(to: Int, count: Int)] { followers[index] ?? [] }
}

/// Where similar tracks and artists come from. The real one asks Last.fm (and remembers the answer); checks use a stand-in.
protocol RabbitHoleSimilarityProviding: Sendable {
    func similarTracks(artist: String, track: String) async throws -> [SimilarTrack]
    func similarArtists(artist: String) async throws -> [SimilarArtist]
}

/// Reads and writes `SimilarityLookupCacheEntry` rows off the main actor.
@ModelActor
actor SimilarityCacheStore {
    func read(_ key: String, maxAge: TimeInterval, now: Date = Date()) -> Data? {
        var descriptor = FetchDescriptor<SimilarityLookupCacheEntry>(predicate: #Predicate { $0.cacheKey == key })
        descriptor.fetchLimit = 1
        guard let entry = try? modelContext.fetch(descriptor).first, now.timeIntervalSince(entry.cachedAt) <= maxAge else { return nil }
        return entry.payload
    }

    func write(_ key: String, payload: Data, now: Date = Date()) {
        var descriptor = FetchDescriptor<SimilarityLookupCacheEntry>(predicate: #Predicate { $0.cacheKey == key })
        descriptor.fetchLimit = 1
        if let entry = try? modelContext.fetch(descriptor).first {
            entry.payload = payload
            entry.cachedAt = now
        } else {
            modelContext.insert(SimilarityLookupCacheEntry(cacheKey: key, payload: payload, cachedAt: now))
        }
        try? modelContext.save()
    }
}

/// Last.fm similarity with a month-long local cache. A failure (offline, rate limit, network) is thrown and never remembered.
struct LastfmSimilarityProvider: RabbitHoleSimilarityProviding {
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    let client: LastfmAPIClient
    let store: SimilarityCacheStore

    private struct Stored: Codable {
        let name: String
        let artist: String?
        let match: Double
    }

    func similarTracks(artist: String, track: String) async throws -> [SimilarTrack] {
        let key = "track\u{1F}\(artist.lowercased())\u{1F}\(track.lowercased())"
        if let data = await store.read(key, maxAge: Self.maxAge), let stored = try? JSONDecoder().decode([Stored].self, from: data) {
            return stored.compactMap { s in s.artist.map { SimilarTrack(name: s.name, artist: $0, match: s.match) } }
        }
        let fetched = try await client.fetchSimilarTracksChecked(artist: artist, track: track)
        if let data = try? JSONEncoder().encode(fetched.map { Stored(name: $0.name, artist: $0.artist, match: $0.match) }) {
            await store.write(key, payload: data)
        }
        return fetched
    }

    func similarArtists(artist: String) async throws -> [SimilarArtist] {
        let key = "artist\u{1F}\(artist.lowercased())"
        if let data = await store.read(key, maxAge: Self.maxAge), let stored = try? JSONDecoder().decode([Stored].self, from: data) {
            return stored.map { SimilarArtist(name: $0.name, match: $0.match) }
        }
        let fetched = try await client.fetchSimilarArtistsChecked(artist: artist)
        if let data = try? JSONEncoder().encode(fetched.map { Stored(name: $0.name, artist: nil, match: $0.match) }) {
            await store.write(key, payload: data)
        }
        return fetched
    }
}

/// A library track offered as a next step, with where it came from.
struct RabbitHoleScoredCandidate: Sendable {
    let trackIndex: Int
    var score: Double
    var reasons: [RabbitHoleReason]
    var sources: Set<RabbitHoleReason.Kind>
    /// The label of the source that scored it best (for the `similarBecause` column).
    var topSource: String
    var topSourceScore: Double
}

/// A track Last.fm calls similar that you have never played.
struct RabbitHoleNewCandidate: Sendable, Equatable {
    let artist: String
    let track: String
    /// 0-100.
    let score: Double
    let reason: String
}

enum RabbitHoleCandidates {
    /// Never more than this many new tracks go into one step's pool.
    static let newMusicCap = 100

    /// The tracks Last.fm names as similar to the step's track (and, softly, the two before it) that you have never played. These come from
    /// the same lookups `build` makes, so with the local answer cache they cost no further requests. `excludingKeys` are `NewMusic.key`s
    /// already on the path.
    @MainActor
    static func newMusic(
        seeds: [Seed], excludingKeys: Set<String>, library: RabbitHoleLibrary, provider: any RabbitHoleSimilarityProviding
    ) async -> [RabbitHoleNewCandidate] {
        let seedKeys = Set(seeds.map { NewMusic.key(artist: $0.artist, track: $0.track) })
        var found: [String: RabbitHoleNewCandidate] = [:]
        for (position, seed) in seeds.enumerated() {
            guard let similar = try? await provider.similarTracks(artist: seed.artist, track: seed.track) else { continue }
            for s in similar {
                let key = NewMusic.key(artist: s.artist, track: s.name)
                guard !library.hasPlayed(artist: s.artist, track: s.name), !seedKeys.contains(key), !excludingKeys.contains(key) else { continue }
                let score = min(100, max(1, s.match * 100 * seed.weight))
                if let existing = found[key], existing.score >= score { continue }
                let reason = position == 0 ? "Last.fm: similar to \(seed.track)" : "Last.fm: similar to an earlier step, \(seed.track)"
                found[key] = RabbitHoleNewCandidate(artist: s.artist, track: s.name, score: score, reason: reason)
            }
        }
        return Array(found.values.sorted { $0.score != $1.score ? $0.score > $1.score : ($0.artist, $0.track) < ($1.artist, $1.track) }.prefix(newMusicCap))
    }

    /// The step's own track, or one of the earlier ones on the path.
    struct Seed: Sendable {
        let artist: String
        let track: String
        let weight: Double
    }

    /// Fewer playable tracks than this from Last.fm's track list: look at similar artists too.
    static let artistFallbackBelow = 15
    /// Fewer than this in total: take one more step out from the best few.
    static let secondHopBelow = 20
    static let similarArtistsUsed = 8
    static let tracksPerSimilarArtist = 6
    static let tagArtistsUsed = 10
    static let tracksPerTagArtist = 4
    static let tempoWindow = 6.0

    @MainActor
    static func build(
        seeds: [Seed], excluding: Set<Int>, library: RabbitHoleLibrary, tags: EntityTagsSnapshot, bpm: BPMEngine.Snapshot,
        lovedKeys: Set<String>, provider: any RabbitHoleSimilarityProviding, now: Date = Date()
    ) async throws -> [RabbitHoleScoredCandidate] {
        guard let primary = seeds.first else { return [] }
        let seedIndexes = Set(seeds.compactMap { library.index(artist: $0.artist, track: $0.track) })
        var found: [Int: RabbitHoleScoredCandidate] = [:]

        func add(_ index: Int, score: Double, kind: RabbitHoleReason.Kind, label: String, reason: String) {
            guard !seedIndexes.contains(index), !excluding.contains(index) else { return }
            let clamped = min(100, max(1, score))
            if var existing = found[index] {
                if !existing.sources.contains(kind) { existing.reasons.append(RabbitHoleReason(kind: kind, text: reason)) }
                existing.sources.insert(kind)
                if clamped > existing.topSourceScore { existing.topSourceScore = clamped; existing.topSource = label }
                existing.score = max(existing.score, clamped)
                found[index] = existing
            } else {
                found[index] = RabbitHoleScoredCandidate(trackIndex: index, score: clamped, reasons: [RabbitHoleReason(kind: kind, text: reason)], sources: [kind], topSource: label, topSourceScore: clamped)
            }
        }

        // 1. Last.fm's similar tracks, for the step's track (an error here is the caller's to show) and, softly, the steps before it.
        var primaryPlayable = 0
        for (position, seed) in seeds.enumerated() {
            let similar: [SimilarTrack]
            if position == 0 { similar = try await provider.similarTracks(artist: seed.artist, track: seed.track) }
            else { similar = (try? await provider.similarTracks(artist: seed.artist, track: seed.track)) ?? [] }
            for s in similar {
                guard let index = library.index(artist: s.artist, track: s.name) else { continue }
                if position == 0 { primaryPlayable += 1 }
                let text = position == 0 ? "Last.fm: similar to \(seed.track)" : "Last.fm: similar to an earlier step, \(seed.track)"
                add(index, score: s.match * 100 * seed.weight, kind: .similar, label: "Last.fm similar", reason: text)
            }
        }

        // 2. Tracks you tend to play right after this one.
        if let seedIndex = library.index(artist: primary.artist, track: primary.track) {
            for follower in library.playedNext(after: seedIndex).prefix(12) {
                add(follower.to, score: min(100, 45 + Double(follower.count) * 8), kind: .playedNext, label: "You play it next",
                    reason: "You often play it right after \(primary.track) (\(follower.count) times)")
            }
        }

        // 3. Tracks by artists that share this track's tags (all on this Mac). A tag few artists have ("shoegaze") says more than one
        //    nearly everyone has ("indie"), so each tag counts for how rare it is among the artists you've played.
        let seedTags = Array((tags.communityTags(kind: .track, artist: primary.artist, name: primary.track) ?? tags.tags(forArtist: primary.artist) ?? []).prefix(5))
        if !seedTags.isEmpty {
            var artistTags: [String: [String]] = [:]
            var artistCount = 0.0
            var frequency: [String: Double] = [:]
            for artistKey in library.artistKeys {
                guard let artistName = library.canonicalArtist(artistKey), let theirs = tags.tags(forArtist: artistName), !theirs.isEmpty else { continue }
                let top = theirs.prefix(5).map { $0.lowercased() }
                artistTags[artistName] = top
                artistCount += 1
                for tag in Set(top) { frequency[tag, default: 0] += 1 }
            }
            func rarity(_ tag: String) -> Double { log((artistCount + 1) / ((frequency[tag] ?? 0) + 1)) + 0.1 }
            let wanted = Set(seedTags.map { $0.lowercased() })
            var scored: [(artist: String, overlap: Double, shared: [String])] = []
            for (artistName, theirs) in artistTags {
                let other = Set(theirs)
                let shared = wanted.intersection(other)
                guard !shared.isEmpty else { continue }
                let overlap = shared.reduce(0) { $0 + rarity($1) } / wanted.union(other).reduce(0) { $0 + rarity($1) }
                if overlap >= 0.2 { scored.append((artistName, overlap, seedTags.filter { shared.contains($0.lowercased()) })) }
            }
            for entry in scored.sorted(by: { $0.overlap != $1.overlap ? $0.overlap > $1.overlap : $0.artist < $1.artist }).prefix(tagArtistsUsed) {
                for index in library.trackIndexes(ofArtist: entry.artist).prefix(tracksPerTagArtist) {
                    add(index, score: 25 + 70 * entry.overlap, kind: .sharedTags, label: "Shared tags",
                        reason: "Shares tags: \(entry.shared.sorted { rarity($0.lowercased()) > rarity($1.lowercased()) }.prefix(3).joined(separator: ", "))")
                }
            }
        }

        // 4. Few playable similar tracks: widen to similar artists, using a few of each one's most-played tracks.
        if primaryPlayable < artistFallbackBelow {
            let similarArtists = (try? await provider.similarArtists(artist: primary.artist)) ?? []
            for similar in similarArtists.sorted(by: { $0.match > $1.match }).prefix(similarArtistsUsed) {
                let candidates = library.trackIndexes(ofArtist: similar.name)
                let ranked = candidates.sorted {
                    let l = library.tracks[$0], r = library.tracks[$1]
                    let lLoved = lovedKeys.contains(l.key), rLoved = lovedKeys.contains(r.key)
                    if lLoved != rLoved { return lLoved }
                    return l.plays > r.plays
                }
                for index in ranked.prefix(tracksPerSimilarArtist) {
                    add(index, score: similar.match * 60, kind: .similarArtist, label: "Similar artist",
                        reason: "By \(library.tracks[index].artist), who Last.fm calls similar to \(primary.artist)")
                }
            }
        }

        // 5. Still thin: one more step out from the best few.
        if found.count < secondHopBelow {
            for best in found.values.sorted(by: { $0.score > $1.score }).prefix(3) {
                let track = library.tracks[best.trackIndex]
                let further = (try? await provider.similarTracks(artist: track.artist, track: track.name)) ?? []
                for s in further {
                    guard let index = library.index(artist: s.artist, track: s.name) else { continue }
                    add(index, score: s.match * 100 * 0.5 * (best.score / 100), kind: .viaStep, label: "Two steps away",
                        reason: "Similar to \(track.name), which is similar to \(primary.track)")
                }
            }
        }

        // 6. What each candidate says about itself: a close tempo, a favourite you've left alone.
        let primaryTempo = bpm.resolution(forKey: TextNormalization.lovedKey(artist: primary.artist, track: primary.track)).resolved?.bpm
        for (index, var candidate) in found {
            let track = library.tracks[index]
            if let primaryTempo, let theirs = bpm.resolution(forKey: track.key).resolved?.bpm, abs(theirs - primaryTempo) <= tempoWindow {
                candidate.score = min(100, candidate.score + 5)
                candidate.reasons.append(RabbitHoleReason(kind: .tempo, text: "Tempo \(Int(theirs.rounded())) BPM, near \(Int(primaryTempo.rounded()))"))
                candidate.sources.insert(.tempo)
            }
            if lovedKeys.contains(track.key) {
                let months = Int(now.timeIntervalSince(track.lastPlayed) / (30 * 86400))
                if months >= 12 {
                    candidate.reasons.append(RabbitHoleReason(kind: .forgotten, text: "A favourite you haven't played for \(months / 12 == 1 ? "a year" : "\(months / 12) years")"))
                } else {
                    candidate.reasons.append(RabbitHoleReason(kind: .loved, text: "One of your loved tracks"))
                }
            }
            // Offered by more than one kind of source is a stronger signal than any one of them.
            let independent = candidate.sources.subtracting([.tempo]).count
            if independent > 1 { candidate.score = min(100, candidate.score + Double(independent - 1) * 4) }
            found[index] = candidate
        }
        return found.values.sorted { $0.score != $1.score ? $0.score > $1.score : library.tracks[$0.trackIndex].plays > library.tracks[$1.trackIndex].plays }
    }
}
