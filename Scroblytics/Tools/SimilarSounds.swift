import Foundation
import SwiftData

/// One seed the user picked — an artist, album or track from their own library. Codable so the seed list persists
/// with the tool's other options.
struct SimilarSeed: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case artist, album, track }
    let kind: Kind
    let artist: String
    let album: String?
    let track: String?

    var id: String { "\(kind.rawValue)\u{0}\(artist)\u{0}\(album ?? "")\u{0}\(track ?? "")" }

    /// Matches `SimilarSoundsEngine`'s own seed label, so a seed result and the attribution it produced line up.
    var label: String {
        switch kind {
        case .track: "\(track ?? "") — \(artist)"
        case .album: "\(album ?? "") — \(artist)"
        case .artist: artist
        }
    }

    var recommendationSeed: RecommendationSeed {
        switch kind {
        case .artist: .artist(artist)
        case .album: RecommendationSeed(kind: .album, artist: artist, album: album, track: nil)
        case .track: RecommendationSeed(kind: .track, artist: artist, album: nil, track: track)
        }
    }

    /// A search hit → a seed. An album seed keeps its artist, which is what the lookup actually uses (Last.fm has
    /// no album-level similarity).
    init?(_ result: SearchResult) {
        if let identity = result.artist { self.init(kind: .artist, artist: identity.name, album: nil, track: nil) }
        else if let identity = result.album { self.init(kind: .album, artist: identity.artist, album: identity.name, track: nil) }
        else if let identity = result.track { self.init(kind: .track, artist: identity.artist, album: nil, track: identity.name) }
        else { return nil }
    }

    init(kind: Kind, artist: String, album: String?, track: String?) {
        self.kind = kind
        self.artist = artist
        self.album = album
        self.track = track
    }
}

/// The generated candidate pool: what the Last.fm lookup found, in library terms, ready to hand to the query engine.
struct SimilarSoundsPool: Sendable {
    let candidates: [RecommendedCandidate]
    let seedResults: [RecommendationSeedResult]
    /// Score + attribution per candidate, as the `similarScore`/`similarBecause` fields read it.
    let snapshot: SimilaritySnapshot
    /// The pool's entities — the scope the refinement is evaluated within.
    let ids: Set<QueryEntityID>

    /// Seeds Last.fm had similarity data for AND that landed on at least one library track.
    var seedsWithData: Int { seedResults.filter { $0.inLibrary > 0 }.count }
}

/// Wraps `SimilarSoundsEngine` (the lookup, the library filter and the match scoring are all its) for this tool:
/// shapes its candidates into a pool the query engine can evaluate, and evaluates real Field Registry conditions
/// against that pool. Nothing about similarity is recomputed here.
@MainActor
enum SimilarSoundsTool {
    /// The PRD's limit; the engine's own safety cap is higher.
    static let seedLimit = 10

    /// `scrobbles` must be the artist-canonicalized library (`QueryIdentity.canonicalizingArtists`) — the same one
    /// Query evaluates — so a candidate's spelling is exactly the entity Query knows.
    static func generate(seeds: [SimilarSeed], scrobbles: [ScrobbleSnapshot], client: LastfmAPIClient) async throws -> SimilarSoundsPool {
        let result = try await SimilarSoundsEngine.run(seeds: seeds.prefix(seedLimit).map(\.recommendationSeed), scrobbles: scrobbles, client: client)
        return pool(candidates: result.candidates, seedResults: result.seedResults)
    }

    static func pool(candidates: [RecommendedCandidate], seedResults: [RecommendationSeedResult]) -> SimilarSoundsPool {
        var snapshot = SimilaritySnapshot()
        var ids = Set<QueryEntityID>()
        for c in candidates {
            let id = QueryEntityID(target: .track, artist: c.artist, name: c.track)
            // `sources` comes out of a Set, so its order is arbitrary: best match first, the rest alphabetical.
            let rest = c.sources.filter { $0 != c.topSource }.sorted()
            snapshot.byID[id] = .init(score: c.matchScore, sources: [c.topSource] + rest)
            ids.insert(id)
        }
        return SimilarSoundsPool(candidates: candidates, seedResults: seedResults, snapshot: snapshot, ids: ids)
    }

    /// The columns a result shows unless the user reorders them.
    static let defaultColumns: [QueryFieldRef] = ["similarScore", "similarBecause", "loved", "popular", "plays", "lastPlayed"].map { QueryFieldRef($0) }

    /// Evaluates `groups` (real Field Registry conditions) over the pool via `QueryEngine.evaluate` — the pool is
    /// the engine's entity scope, so every whole-library field still computes against the full library. The order
    /// and the caps are the engine's own too (`sorts`, `groupLimit`, `limit`), not a second implementation.
    nonisolated static func evaluate(
        pool: SimilarSoundsPool, groups: [[QueryCondition]], columns: [QueryFieldRef],
        scrobbles: [ScrobbleSnapshot], snapshots: QuerySnapshots, now: Date = Date(),
        arrangement: SimilarSoundsArrangement = SimilarSoundsArrangement()
    ) throws -> QueryResult {
        var spec = QuerySpec(target: .track)
        spec.asOf = now
        spec.groups = groups
        spec.columns = columns
        func descending(_ id: String) -> QuerySort { QuerySort(key: .field(QueryFieldRef(id)), direction: .descending) }
        switch arrangement.sort {
        case .matchScore: spec.sorts = [descending("similarScore"), descending("plays")]
        case .shuffled: spec.sorts = [QuerySort(key: .shuffle(seed: arrangement.shuffleSeed))]
        case .plays: spec.sorts = [descending("plays"), descending("similarScore")]
        case .lastPlayed: spec.sorts = [descending("lastPlayed"), descending("similarScore")]
        }
        // Applied after the sort and before the overall limit — "at most 2 per artist, 25 songs" keeps the best 2 per
        // artist in this order, then the first 25 of what's left.
        if arrangement.perArtist != nil || arrangement.perAlbum != nil {
            spec.groupLimit = QueryGroupLimit(perArtist: arrangement.perArtist, perAlbum: arrangement.perAlbum)
        }
        spec.limit = arrangement.songLimit
        let validated = try spec.validate(against: .similarSounds)
        var withSimilarity = snapshots
        withSimilarity.similarity = pool.snapshot
        let run = QueryRun(
            target: .track, asOf: now, scrobbles: scrobbles, allTimeScrobbles: scrobbles,
            snapshots: withSimilarity, entityScope: pool.ids
        )
        return QueryEngine.evaluate(validated, run: run)
    }
}

enum SimilarSoundsSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case matchScore, shuffled, plays, lastPlayed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .matchScore: "Match score"
        case .shuffled: "Shuffled"
        case .plays: "Play count"
        case .lastPlayed: "Last played"
        }
    }
}

/// The simple controls over what comes back: how many songs, at most how many per artist / per album, and in what
/// order. nil caps mean "no cap".
struct SimilarSoundsArrangement: Sendable, Equatable {
    var sort: SimilarSoundsSort = .matchScore
    /// A fixed seed, so re-running with a changed condition doesn't reshuffle; "Reshuffle" picks a new one.
    var shuffleSeed: UInt64 = 1
    var songLimit: Int?
    var perArtist: Int?
    var perAlbum: Int?
}

#if DEBUG
/// Verification hook. `SCROBLYTICS_SIMILAR_DUMP=/path/out.txt` plus one of:
/// - `SCROBLYTICS_SIMILAR_SEEDS="artist:Name;track:Artist|Title;album:Artist|Album"` — runs the LIVE lookup (needs
///   Last.fm credentials) and dumps seed coverage, the pool, and the raw similar-artist list per artist seed.
/// - `SCROBLYTICS_SIMILAR_FIXEDPOOL=1` — no network: a fixed pool of library tracks with synthetic scores, evaluated
///   with a `loved` condition, to verify the scoped evaluation itself.
enum SimilarSoundsDebugEval {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_SIMILAR_DUMP"] else { return }
        Task { @MainActor in
            var out: [String] = []
            do {
                let raw = try container.mainContext.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
                let scrobbles = QueryIdentity.canonicalizingArtists(raw)
                let loaded = await QuerySnapshotReader.loadAll(container: container)
                let snapshots = QuerySnapshots(
                    durations: loaded.durations, releaseDates: loaded.releaseDates, turnover: loaded.turnover,
                    lovedKeys: loaded.lovedKeys, entityTags: loaded.entityTags, images: loaded.images
                )
                let env = ProcessInfo.processInfo.environment
                if let seedSpec = env["SCROBLYTICS_SIMILAR_SEEDS"] {
                    guard let credentials = LastfmCredentialsStore.load() else { throw NSError(domain: "similar", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Last.fm credentials"]) }
                    let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
                    let seeds: [SimilarSeed] = seedSpec.split(separator: ";").compactMap { part in
                        let bits = part.split(separator: ":", maxSplits: 1).map(String.init)
                        guard bits.count == 2 else { return nil }
                        let fields = bits[1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                        switch bits[0] {
                        case "artist": return SimilarSeed(kind: .artist, artist: fields[0], album: nil, track: nil)
                        case "album": return fields.count > 1 ? SimilarSeed(kind: .album, artist: fields[0], album: fields[1], track: nil) : nil
                        case "track": return fields.count > 1 ? SimilarSeed(kind: .track, artist: fields[0], album: nil, track: fields[1]) : nil
                        default: return nil
                        }
                    }
                    for seed in seeds where seed.kind != .track {
                        let raw = await client.fetchSimilarArtists(artist: seed.artist, limit: 30)
                        out.append("RAW similar artists for \(seed.artist) (\(raw.count)): " + raw.map { "\($0.name)=\($0.match)" }.joined(separator: "; "))
                    }
                    let pool = try await SimilarSoundsTool.generate(seeds: seeds, scrobbles: scrobbles, client: client)
                    out.append("SEEDS WITH DATA: \(pool.seedsWithData) of \(seeds.count)")
                    for r in pool.seedResults { out.append("  seed \(r.label): similarFound=\(r.similarFound) inLibrary=\(r.inLibrary)") }
                    out.append("POOL: \(pool.candidates.count) tracks")
                    for c in pool.candidates {
                        out.append("  \(c.matchScore)\t\(c.artist)\t\(c.track)\tplays=\(c.totalPlaycount)\ttop=\(c.topSource)\tsources=\(pool.snapshot.byID[QueryEntityID(target: .track, artist: c.artist, name: c.track)]?.sources ?? [])")
                    }
                    let popularityStore = PopularityStore()
                    await popularityStore.start(container: container, work: BackgroundWorkStore(), warm: false)
                    var refinedSnapshots = snapshots
                    refinedSnapshots.popularity = popularityStore.snapshot
                    let firstSeed = seeds.first?.label ?? ""
                    let conditionSets: [(String, [[QueryCondition]])] = [
                        ("no conditions", []),
                        ("score >= 50", [[QueryCondition(QueryFieldRef("similarScore"), .greaterThanOrEqual, [.number(50)])]]),
                        ("loved", [[QueryCondition(QueryFieldRef("loved"), .isTrue, [])]]),
                        ("daysSinceLastPlayed >= 365", [[QueryCondition(QueryFieldRef("daysSinceLastPlayed"), .greaterThanOrEqual, [.number(365)])]]),
                        ("because contains first seed", [[QueryCondition(QueryFieldRef("similarBecause"), .contains, [.text(firstSeed)])]]),
                        ("popular", [[QueryCondition(QueryFieldRef("popular"), .isTrue, [])]]),
                        ("score >= 50 AND loved", [[QueryCondition(QueryFieldRef("similarScore"), .greaterThanOrEqual, [.number(50)]), QueryCondition(QueryFieldRef("loved"), .isTrue, [])]]),
                    ]
                    let arrangements: [(String, SimilarSoundsArrangement)] = [
                        ("A score limit25 perArtist2", SimilarSoundsArrangement(sort: .matchScore, songLimit: 25, perArtist: 2)),
                        ("B plays limit25 perAlbum1", SimilarSoundsArrangement(sort: .plays, songLimit: 25, perAlbum: 1)),
                        ("C lastPlayed limit20", SimilarSoundsArrangement(sort: .lastPlayed, songLimit: 20)),
                        ("D shuffle7 limit20", SimilarSoundsArrangement(sort: .shuffled, shuffleSeed: 7, songLimit: 20)),
                        ("E shuffle7 again", SimilarSoundsArrangement(sort: .shuffled, shuffleSeed: 7, songLimit: 20)),
                        ("F shuffle8 limit20", SimilarSoundsArrangement(sort: .shuffled, shuffleSeed: 8, songLimit: 20)),
                    ]
                    for (label, arrangement) in arrangements {
                        let result = try SimilarSoundsTool.evaluate(pool: pool, groups: [], columns: SimilarSoundsTool.defaultColumns, scrobbles: scrobbles, snapshots: snapshots, arrangement: arrangement)
                        func key(_ id: String) -> String? { result.columns.first { $0.field.id == id }?.cacheKey }
                        out.append("ARRANGE \(label): rows=\(result.rows.count) matched=\(result.matchedCount)")
                        for row in result.rows {
                            var score = "", plays = "", last = ""
                            if let k = key("similarScore"), case .value(.number(let n))? = row.cells[k] { score = String(Int(n)) }
                            if let k = key("plays"), case .value(.number(let n))? = row.cells[k] { plays = String(Int(n)) }
                            if let k = key("lastPlayed"), case .value(.date(let d))? = row.cells[k] { last = String(d.timeIntervalSince1970) }
                            out.append("   ARR[\(label)]\t\(row.entity.artist)\t\(row.entity.name)\t\(score)\t\(plays)\t\(last)\t\(result.entityInfo[row.id]?.album ?? "")")
                        }
                    }
                    out.append("ASOF \(Date().timeIntervalSince1970)")
                    for (label, groups) in conditionSets {
                        let result = try SimilarSoundsTool.evaluate(pool: pool, groups: groups, columns: SimilarSoundsTool.defaultColumns, scrobbles: scrobbles, snapshots: refinedSnapshots)
                        out.append("EVALUATE \(label): rows=\(result.rows.count) universeCount=\(result.universeCount) pending=\(result.pending.map { "\($0.field)=\($0.count)" })")
                        for row in result.rows { out.append("   ROW[\(label)]\t\(row.entity.artist)\t\(row.entity.name)") }
                    }
                } else if env["SCROBLYTICS_SIMILAR_FIXEDPOOL"] != nil {
                    // A deterministic pool: the 60 most-played tracks plus every 250th other distinct track.
                    var plays: [String: (artist: String, track: String, n: Int)] = [:]
                    for s in scrobbles { let k = "\(s.artistName)\u{0}\(s.trackName)"; plays[k, default: (s.artistName, s.trackName, 0)].n += 1 }
                    let ordered = plays.values.sorted { ($0.n, $0.track) > ($1.n, $1.track) }
                    let chosen = Array(ordered.prefix(60)) + ordered.dropFirst(60).enumerated().filter { $0.offset % 250 == 0 }.map(\.element)
                    let candidates = chosen.enumerated().map { i, t in
                        RecommendedCandidate(track: t.track, artist: t.artist, album: nil, totalPlaycount: t.n, lastPlayed: Date(), matchScore: max(1, 100 - i), sources: ["Seed A"], topSource: "Seed A", imageURL: nil)
                    }
                    let pool = SimilarSoundsTool.pool(candidates: candidates, seedResults: [])
                    let columns = SimilarSoundsTool.defaultColumns + [QueryFieldRef("playRank"), QueryFieldRef("loved")]
                    let lovedOnly = [[QueryCondition(QueryFieldRef("loved"), .isTrue, [])]]
                    for (label, groups) in [("no conditions", []), ("loved", lovedOnly)] as [(String, [[QueryCondition]])] {
                        let result = try SimilarSoundsTool.evaluate(pool: pool, groups: groups, columns: columns, scrobbles: scrobbles, snapshots: snapshots)
                        out.append("== \(label): rows=\(result.rows.count) matched=\(result.matchedCount) universeCount=\(result.universeCount) poolSize=\(pool.ids.count)")
                        func key(_ id: String) -> String? { result.columns.first { $0.field.id == id }?.cacheKey }
                        for row in result.rows {
                            let rank: String = { if let k = key("playRank"), case .value(.number(let n))? = row.cells[k] { return String(Int(n)) } else { return "?" } }()
                            out.append("   \(row.entity.artist)\t\(row.entity.name)\trank=\(rank)")
                        }
                    }
                }
            } catch {
                out.append("ERROR: \(error)")
            }
            try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif
