import Foundation

/// Identity of one row in a query's universe. For an artist the `name` is the
/// artist; for an album, the album title (with its `artist`); for a track, the
/// track title (with its `artist`). Raw scrobble strings, matching how the
/// existing engines (Fading Favorites, Milestones…) already group — checked
/// against real data: raw and case-normalized grouping give the same 10,920
/// tracks.
struct QueryEntityID: Hashable, Sendable {
    let target: QueryTarget
    let artist: String
    let name: String
    /// A scrobble is one play: its time (seconds since 1970) is what tells two plays of the same track apart. 0 for every other target.
    var at: Double = 0
}

struct QueryEntity: Identifiable, Hashable, Sendable {
    let id: QueryEntityID
    var target: QueryTarget { id.target }
    var artist: String { id.artist }
    var name: String { id.name }
}

/// The read-only copies of background-resolved data a run reads (each built on
/// the main actor from the same stores the existing screens use). A field
/// answers `.pending` for anything its snapshot hasn't resolved yet.
/// Album groups (the fuzzy merge of an album's name variants) cost about a second to build for
/// a whole library, so they are built once per distinct scope and reused across runs. A scope
/// is a contiguous slice of one sorted library, so (count, first, last) identifies it.
final class TurnoverGroupCache: @unchecked Sendable {
    private let lock = NSLock()
    private var key: [Double]?
    private var separated: Set<String> = []
    private var cached: [String: [AlbumGroup]] = [:]

    /// `separating`: the editions counted on their own (`AlbumTurnoverEngine.Snapshot.separateEditions`).
    func groups(for scrobbles: [ScrobbleSnapshot], separating: Set<String> = []) -> [String: [AlbumGroup]] {
        lock.lock(); defer { lock.unlock() }
        let first: Double = scrobbles.first?.playedAt.timeIntervalSince1970 ?? 0
        let last: Double = scrobbles.last?.playedAt.timeIntervalSince1970 ?? 0
        let k: [Double] = [Double(scrobbles.count), first, last]
        if key == k, separated == separating { return cached }
        cached = AlbumTurnoverEngine.buildGroupsByArtist(scrobbles: scrobbles, separateEditions: separating)
        key = k
        separated = separating
        return cached
    }
}

struct QuerySnapshots: Sendable {
    var popularity: PopularitySnapshot = .empty
    var durations: DurationEngine.Snapshot = .empty
    var bpm: BPMEngine.Snapshot = .empty
    var releaseDates: ReleaseDateEngine.Snapshot = .empty
    var turnover: AlbumTurnoverEngine.Snapshot = .empty
    /// `lovedKey`s of every Last.fm-loved track (`LovedTracksEngine.lovedSet`).
    var lovedKeys: Set<String> = []
    /// Album-agnostic artist/track keys for every locally flagged track.
    var flaggedKeys: Set<String> = []
    var entityTags: EntityTagsSnapshot = .empty
    /// Saved Apple Music library status (Library Gaps); empty where nothing loads it.
    var libraryPresence: LibraryPresenceSnapshot = .empty
    /// The weather at each hour for the person's home place (Settings › Weather); empty while weather is off or not downloaded.
    var weather: WeatherSnapshot = .empty
    var images: ImageStatusSnapshot = .empty
    var turnoverGroups = TurnoverGroupCache()
    /// Last.fm similarity for a generated candidate pool (Similar Sounds); empty everywhere else.
    var similarity: SimilaritySnapshot = .empty

    static let empty = QuerySnapshots()
}

/// Everything one evaluation reads, plus a per-run memo so a whole-library
/// computation (fading stats at a given window, say) happens once even when a
/// condition, a sort and a column all use it.
///
/// Confined to a single evaluation on a single task, so the unchecked
/// `Sendable` is safe: the cache is never touched concurrently.
final class QueryRun: @unchecked Sendable {
    let target: QueryTarget
    /// "Now" for the run — relative fields (days since, fading windows) are
    /// evaluated at this instant, so a run is reproducible.
    let asOf: Date
    let calendar: Calendar
    /// Ascending by `playedAt` — the precondition the existing engines rely on.
    let scrobbles: [ScrobbleSnapshot]
    /// The whole library, ignoring the query's period — for fields that deliberately look past it.
    let allTimeScrobbles: [ScrobbleSnapshot]
    let snapshots: QuerySnapshots
    /// When set, only these entities are EVALUATED and returned — a pool a tool generated itself (Similar Sounds'
    /// candidates). Deliberately not applied to `universe`: ranks, popularity percentiles and every other
    /// whole-library field still compute against the full library, and the album/tag/image fields that walk the
    /// universe keep seeing it whole. nil = the whole universe.
    let entityScope: Set<QueryEntityID>?
    var popularity: PopularitySnapshot { snapshots.popularity }

    private var memo: [String: Any] = [:]
    private var cellCache: [String: [QueryEntityID: QueryCell]] = [:]

    init(target: QueryTarget, asOf: Date, calendar: Calendar = AppCalendars.listening,
         scrobbles: [ScrobbleSnapshot], allTimeScrobbles: [ScrobbleSnapshot]? = nil, snapshots: QuerySnapshots = .empty,
         entityScope: Set<QueryEntityID>? = nil) {
        self.target = target
        self.entityScope = entityScope
        self.asOf = asOf
        self.calendar = calendar
        self.scrobbles = scrobbles
        self.allTimeScrobbles = allTimeScrobbles ?? scrobbles
        self.snapshots = snapshots
    }

    func memoized<T>(_ key: String, _ build: () -> T) -> T {
        if let hit = memo[key] as? T { return hit }
        let value = build()
        memo[key] = value
        return value
    }

    // MARK: - Universe

    /// Which entity of the run's target a scrobble belongs to (nil when it has
    /// none — an album query skips album-less scrobbles). The ONE grouping rule.
    func entityID(for s: ScrobbleSnapshot) -> QueryEntityID? {
        switch target {
        case .artist: QueryEntityID(target: .artist, artist: s.artistName, name: s.artistName)
        case .album: s.albumName.isEmpty ? nil : QueryEntityID(target: .album, artist: s.artistName, name: s.albumName)
        case .track: QueryEntityID(target: .track, artist: s.artistName, name: s.trackName)
        case .scrobble: QueryEntityID(target: .scrobble, artist: s.artistName, name: s.trackName, at: s.playedAt.timeIntervalSince1970)
        }
    }

    /// Each entity's own in-scope scrobbles (ascending), for fields that wrap an
    /// engine which takes a scrobble list. Built once per run.
    var scrobblesByEntity: [QueryEntityID: [ScrobbleSnapshot]] {
        memoized("scrobblesByEntity") {
            var groups: [QueryEntityID: [ScrobbleSnapshot]] = [:]
            for s in scrobbles { if let id = entityID(for: s) { groups[id, default: []].append(s) } }
            return groups
        }
    }

    /// Every entity of the run's target that has at least one play in scope,
    /// plus the per-entity aggregates every core field reads. Built in ONE pass
    /// over the scrobbles and memoized.
    ///
    /// Grouping keys are the raw scrobble strings — the same grouping the
    /// existing engines use, so a field that wraps one (Fading Favorites) lines
    /// up entity-for-entity with the universe.
    struct Universe: Sendable {
        struct Aggregate: Sendable {
            var plays = 0
            var first: Date
            var last: Date
            /// First real (non-placeholder) artwork URL seen on any of its scrobbles.
            var imageURL: String?
            /// Tracks only: the album it was most often scrobbled under
            /// (alphabetically-first on a tie, so it never depends on iteration order).
            var album: String?
        }
        /// Sorted by (name, artist) so every run enumerates identically.
        let entities: [QueryEntity]
        let aggregates: [QueryEntityID: Aggregate]
    }

    var universe: Universe {
        memoized("universe") {
            let aggregates = buildAggregates(scrobbles)
            if target == .scrobble {
                // One entity per play, newest first: the order a list of plays is read in, and no name sort over every play.
                let ordered = scrobbles.reversed().compactMap { entityID(for: $0) }.map(QueryEntity.init(id:))
                return Universe(entities: ordered, aggregates: aggregates)
            }
            let entities = aggregates.keys
                .sorted { a, b in
                    let byName = a.name.localizedStandardCompare(b.name)
                    return byName != .orderedSame ? byName == .orderedAscending : a.artist.localizedStandardCompare(b.artist) == .orderedAscending
                }
                .map(QueryEntity.init(id:))
            return Universe(entities: entities, aggregates: aggregates)
        }
    }

    /// The entities a query is evaluated over: the whole universe, or just `entityScope`'s members of it.
    var evaluationEntities: [QueryEntity] {
        guard let entityScope else { return universe.entities }
        return memoized("evaluationEntities") { universe.entities.filter { entityScope.contains($0.id) } }
    }

    /// Per-entity aggregates over any set of scrobbles — the query's period (the universe) or a
    /// field's own scope. ONE pass, one rule.
    private func buildAggregates<S: Sequence>(_ source: S) -> [QueryEntityID: Universe.Aggregate] where S.Element == ScrobbleSnapshot {
        var aggregates: [QueryEntityID: Universe.Aggregate] = [:]
        if target == .scrobble {
            // One play per entity: its own time, picture and album, with none of the per-album tallying the other targets need (that
            // would allocate a dictionary for every play of a library of a hundred thousand).
            for s in source {
                guard let id = entityID(for: s) else { continue }
                let image = s.imageURL.flatMap { TextNormalization.isLastfmPlaceholderImage($0) ? nil : $0 }
                aggregates[id] = Universe.Aggregate(plays: 1, first: s.playedAt, last: s.playedAt, imageURL: image, album: s.albumName.isEmpty ? nil : s.albumName)
            }
            return aggregates
        }
        var albumCounts: [QueryEntityID: [String: Int]] = [:]
        for s in source {
            guard let id = entityID(for: s) else { continue }
            let image = s.imageURL.flatMap { TextNormalization.isLastfmPlaceholderImage($0) ? nil : $0 }
            if var a = aggregates[id] {
                a.plays += 1
                if s.playedAt < a.first { a.first = s.playedAt }
                if s.playedAt > a.last { a.last = s.playedAt }
                if a.imageURL == nil { a.imageURL = image }
                aggregates[id] = a
            } else {
                aggregates[id] = Universe.Aggregate(plays: 1, first: s.playedAt, last: s.playedAt, imageURL: image, album: nil)
            }
            if target == .track || target == .scrobble, !s.albumName.isEmpty { albumCounts[id, default: [:]][s.albumName, default: 0] += 1 }
        }
        for (id, counts) in albumCounts {
            aggregates[id]?.album = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
        }
        return aggregates
    }

    // MARK: - Items behind single plays

    /// For a query that finds single plays: each play by its entity id, in one pass (no array per play, as `scrobblesByEntity` would make).
    var playByEntity: [QueryEntityID: ScrobbleSnapshot] {
        memoized("playByEntity") {
            var plays: [QueryEntityID: ScrobbleSnapshot] = [:]
            plays.reserveCapacity(scrobbles.count)
            for s in scrobbles { if let id = entityID(for: s) { plays[id] = s } }
            return plays
        }
    }

    /// The artist, album or track a play (an entity of a single-play run) is of, as the entity of an ordinary run of that kind. nil for an
    /// album-less play at the album level.
    func itemID(_ level: QueryTarget, ofPlay play: QueryEntityID) -> QueryEntityID? {
        guard let s = playByEntity[play] else { return nil }
        switch level {
        case .artist: return QueryEntityID(target: .artist, artist: s.artistName, name: s.artistName)
        case .album: return s.albumName.isEmpty ? nil : QueryEntityID(target: .album, artist: s.artistName, name: s.albumName)
        case .track: return QueryEntityID(target: .track, artist: s.artistName, name: s.trackName)
        case .scrobble: return play
        }
    }

    /// An ordinary run of `level` over the same plays, library and snapshots: what a play's inherited fields are computed on.
    func itemRun(_ level: QueryTarget) -> QueryRun {
        memoized("itemRun.\(level.rawValue)") {
            QueryRun(target: level, asOf: asOf, calendar: calendar, scrobbles: scrobbles, allTimeScrobbles: allTimeScrobbles, snapshots: snapshots)
        }
    }

    // MARK: - Scopes

    /// The dates a scope means for THIS run ("now" = `asOf`). A scope reaching here was validated with
    /// its field, so an invalid one is a programming error, not user input.
    func resolve(_ scope: QueryScope) -> ResolvedScope {
        memoized("scope.\(scope.cacheKey)") {
            guard let range = try? scope.resolve(asOf: asOf, calendar: calendar) else {
                preconditionFailure("scope “\(scope.label)” reached the engine without being validated")
            }
            return range
        }
    }

    /// The library's scrobbles inside `range` (inclusive), a slice of the sorted whole — found by
    /// binary search, so any number of scopes cost almost nothing to cut.
    func scrobbles(in range: ResolvedScope) -> ArraySlice<ScrobbleSnapshot> {
        let all = allTimeScrobbles
        func firstIndex(where predicate: (ScrobbleSnapshot) -> Bool) -> Int {
            var lo = 0, hi = all.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if predicate(all[mid]) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
        let start = range.from.map { from in firstIndex { $0.playedAt >= from } } ?? 0
        let end = range.to.map { to in firstIndex { $0.playedAt > to } } ?? all.count
        return all[start..<max(start, end)]
    }

    /// The scrobbles a field with this scope reads: the query's period when nil, else the scope's
    /// range of the whole library.
    func scopedScrobbles(_ scope: QueryScope?) -> ArraySlice<ScrobbleSnapshot> {
        guard let scope else { return scrobbles[...] }
        return scrobbles(in: resolve(scope))
    }

    /// What an ENGINE-backed field (fading, climbing, milestones, turnover) sees under a scope: the
    /// library inside the scope's range, with "now" moved to the range's end — so "Up to a year
    /// ago" runs the engine exactly as it would have run on that day. nil = the query's period at
    /// the run's own "now".
    struct EngineView: Sendable {
        let scrobbles: [ScrobbleSnapshot]
        let asOf: Date
    }

    func engineView(_ scope: QueryScope?) -> EngineView {
        guard let scope else { return EngineView(scrobbles: scrobbles, asOf: asOf) }
        return memoized("engineView.\(scope.cacheKey)") {
            let range = resolve(scope)
            return EngineView(scrobbles: Array(scrobbles(in: range)), asOf: range.to ?? asOf)
        }
    }

    /// Per-entity aggregates over a scope. nil = the query's period (the universe's own).
    func scopedAggregates(_ scope: QueryScope?) -> [QueryEntityID: Universe.Aggregate] {
        guard let scope else { return universe.aggregates }
        return memoized("aggregates.\(scope.cacheKey)") { buildAggregates(scopedScrobbles(scope)) }
    }

    func scopedScrobblesByEntity(_ scope: QueryScope?) -> [QueryEntityID: [ScrobbleSnapshot]] {
        guard let scope else { return scrobblesByEntity }
        return memoized("byEntity.\(scope.cacheKey)") {
            var groups: [QueryEntityID: [ScrobbleSnapshot]] = [:]
            for s in scopedScrobbles(scope) { if let id = entityID(for: s) { groups[id, default: []].append(s) } }
            return groups
        }
    }

    // MARK: - Field cells

    /// Computes a field for any entities not already cached, and returns its
    /// cells for the requested ones. Each (field, parameters) is computed once
    /// per run no matter how many conditions, sorts and columns read it.
    func cells(for resolved: ResolvedField, entities: [QueryEntity]) -> [QueryEntityID: QueryCell] {
        var cache = cellCache[resolved.cacheKey] ?? [:]
        let missing = entities.filter { cache[$0.id] == nil }
        if !missing.isEmpty {
            let computed: [QueryEntityID: QueryCell]
            if let compared = resolved.field.comparedCompute, let baseline = resolved.baseline {
                computed = compared(self, resolved.parameters, resolved.scope, baseline, missing)
            } else if let scoped = resolved.field.scopedCompute {
                computed = scoped(self, resolved.parameters, resolved.scope, missing)
            } else {
                computed = resolved.field.compute(self, resolved.parameters, missing)
            }
            for entity in missing {
                if let cell = computed[entity.id] {
                    cache[entity.id] = cell
                } else {
                    // A field must answer for every entity it was asked about.
                    assertionFailure("Field “\(resolved.field.id)” returned no cell for \(entity.id)")
                    cache[entity.id] = .missing
                }
            }
            cellCache[resolved.cacheKey] = cache
        }
        return cache
    }
}
