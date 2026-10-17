import Foundation
import SwiftData

enum TopChartsEntity: String, CaseIterable, Identifiable {
    case artist, album, track
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .artist: return "Artists"
        case .album: return "Albums"
        case .track: return "Tracks"
        }
    }
}

/// What the Chart comparison control's This/Prev/Move/Peak columns compare
/// the current chart against. Independent of any Overview compare setting;
/// this is Top Charts' own local control.
enum ChartCompareMode: String, CaseIterable, Identifiable {
    case yesterday, last7, last30, last90, last365, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .yesterday: return "Yesterday"
        case .last7: return "7 days ago"
        case .last30: return "30 days ago"
        case .last90: return "90 days ago"
        case .last365: return "365 days ago"
        case .custom: return "Custom date…"
        }
    }

    /// Nil for `.custom`, which is a manual date pick, not a fixed offset.
    var days: Int? {
        switch self {
        case .yesterday: return 1
        case .last7: return 7
        case .last30: return 30
        case .last90: return 90
        case .last365: return 365
        case .custom: return nil
        }
    }

    /// Comparing to a window as wide as (or wider than) the selected range
    /// is meaningless, so a preset only offers itself when the range spans
    /// more than that many days. `.custom` is exempt — it's filtered
    /// separately by callers.
    static func validPresets(rangeDays: Double) -> [ChartCompareMode] {
        allCases.filter { mode in
            guard let days = mode.days else { return false }
            return Double(days) < rangeDays
        }
    }
}

/// Which value ranks and displays — Scrobbles (play count, always available)
/// or Time Listened (derived from resolved track durations, per
/// `DurationEngine` — never a second resolution pipeline of its own).
enum TopChartsMetric: String, CaseIterable, Identifiable {
    case scrobbles, timeListened
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .scrobbles: return "Scrobbles"
        case .timeListened: return "Time Listened"
        }
    }
}

struct TopChartEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let rank: Int
    let name: String
    /// nil for the artist entity; the (possibly merged/compilation) artist for album/track.
    let artist: String?
    /// Set only for the track entity, when known.
    let album: String?
    let playcount: Int
    /// Only populated when ranked by `.timeListened` — computing this needs
    /// resolving every distinct track's duration first (network on a cold
    /// cache), so it's skipped entirely when the metric wasn't requested.
    let timeListenedSeconds: Int?
    let imageURL: String?
    /// False when no Chart comparison range exists at all for the current
    /// selection (e.g. every preset is wider than the selected range and no
    /// custom date is set) — Prev/Move show "–" rather than a "new" badge.
    let hasCompareRange: Bool
    /// This entity's rank within the FULL comparison-range universe (not
    /// just its own top N) — nil either because there's no compare range at
    /// all, or because the entity wasn't charted there (a genuine new entry).
    let previousRank: Int?
    /// Best (lowest) rank this entity held at any point within the
    /// currently selected Date range — never worse than `rank` itself,
    /// since the last checkpoint always lands exactly on the range's end.
    let peakRank: Int
    /// Most recent scrobble in the ranked pool — unused by Top Charts' own
    /// This/Prev/Move/Peak table, but feeds a detail page's own sub-list's
    /// "Recently played" sort (Phase 5).
    let lastPlayedAt: Date
    /// Track-only (Last.fm loves are track-scoped) — reads from a
    /// pre-resolved `lovedSet` snapshot, never a live lookup. Always `false`
    /// for artist/album entries.
    let loved: Bool
    /// Album/track release-date state. Pending means the background lookup has
    /// not completed; unknown means both online sources were checked and had
    /// no date. Artist entries use `.unknown` because they have no album date.
    let releaseDateResolution: ReleaseDateEngine.Resolution
    var releaseDate: String? { releaseDateResolution.date }

    /// The value this entry was actually ranked/displayed by, for the given
    /// metric — `playcount` for `.scrobbles`, `timeListenedSeconds` (or 0 if
    /// somehow unpopulated) for `.timeListened`.
    func metricValue(for metric: TopChartsMetric) -> Int {
        metric == .scrobbles ? playcount : (timeListenedSeconds ?? 0)
    }
}

/// Lightweight projection of a `Scrobble` used for ranking — avoids holding
/// full model objects (and their SwiftData faulting overhead) across a
/// potentially large in-memory grouping pass. Also what makes the ranking
/// pass itself safe to run on a detached background task.
private struct RankableScrobble: Sendable {
    let artist: String
    let album: String
    let track: String
    let imageURL: String?
    let playedAt: Date
}

private struct RankedGroup {
    let key: String
    let scrobbles: [RankableScrobble]
    let value: Int
}

@ModelActor
private actor TopChartsDataReader {
    func fetchPool(range: DateRange) throws -> [RankableScrobble] {
        let from = range.from
        let to = range.to
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate<Scrobble> { $0.playedAt >= from && $0.playedAt <= to },
            sortBy: [SortDescriptor(\.playedAt)]
        )
        return try modelContext.fetch(descriptor).map {
            RankableScrobble(
                artist: $0.artistName,
                album: $0.albumName,
                track: $0.trackName,
                imageURL: $0.imageURL,
                playedAt: $0.playedAt
            )
        }
    }

    func fetchOldestScrobbleDate() throws -> Date? {
        var descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.playedAt
    }

    func fetchAllPool() throws -> [RankableScrobble] {
        try modelContext.fetch(
            FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        ).map {
            RankableScrobble(
                artist: $0.artistName,
                album: $0.albumName,
                track: $0.trackName,
                imageURL: $0.imageURL,
                playedAt: $0.playedAt
            )
        }
    }

    func fetchScopedPool(
        range: DateRange,
        artist: String,
        album: String?
    ) throws -> [RankableScrobble] {
        let from = range.from
        let to = range.to
        let rows: [Scrobble]
        if let album {
            let descriptor = FetchDescriptor<Scrobble>(
                predicate: #Predicate<Scrobble> {
                    $0.albumName == album && $0.playedAt >= from && $0.playedAt <= to
                },
                sortBy: [SortDescriptor(\.playedAt)]
            )
            rows = try modelContext.fetch(descriptor).filter {
                TextNormalization.trackMatchesArtistContext(trackArtist: $0.artistName, context: artist)
            }
        } else {
            let artistKey = TextNormalization.artistIdentityKey(artist)
            let descriptor = FetchDescriptor<Scrobble>(
                predicate: #Predicate<Scrobble> {
                    $0.artistName.localizedStandardContains(artist) && $0.playedAt >= from && $0.playedAt <= to
                },
                sortBy: [SortDescriptor(\.playedAt)]
            )
            rows = try modelContext.fetch(descriptor).filter { TextNormalization.artistIdentityKey($0.artistName) == artistKey }
        }
        return rows.map {
            RankableScrobble(
                artist: $0.artistName,
                album: $0.albumName,
                track: $0.trackName,
                imageURL: $0.imageURL,
                playedAt: $0.playedAt
            )
        }
    }

    func fetchPresentationLookups(includeLoved: Bool) throws -> (Set<String>, [String: String]) {
        let lovedSet = includeLoved
            ? Set(try modelContext.fetch(FetchDescriptor<LovedTrackEntry>()).map(\.cacheKey))
            : []
        var imageLookup: [String: String] = [:]

        for artist in try modelContext.fetch(FetchDescriptor<Artist>()) {
            let target = ImageTarget(kind: .artist, artist: artist.name, album: nil, track: nil)
            if let filename = artist.customImageFilename,
               let url = ImageStore.localCustomFileURL(for: filename) {
                imageLookup[ImageResolutionEngine.lookupKey(for: target)] = url.absoluteString
            } else if let filename = artist.detectedImageFilename,
                      let url = ImageStore.localCachedFileURL(for: filename) {
                imageLookup[ImageResolutionEngine.lookupKey(for: target)] = url.absoluteString
            }
        }
        for album in try modelContext.fetch(FetchDescriptor<Album>()) {
            guard let artistName = album.artist?.name else { continue }
            let target = ImageTarget(kind: .album, artist: artistName, album: album.title, track: nil)
            if let filename = album.customImageFilename,
               let url = ImageStore.localCustomFileURL(for: filename) {
                imageLookup[ImageResolutionEngine.lookupKey(for: target)] = url.absoluteString
            } else if let filename = album.detectedImageFilename,
                      let url = ImageStore.localCachedFileURL(for: filename) {
                imageLookup[ImageResolutionEngine.lookupKey(for: target)] = url.absoluteString
            }
        }
        for imageOverride in try modelContext.fetch(FetchDescriptor<AlbumImageOverride>()) {
            if let url = ImageStore.localCustomFileURL(for: imageOverride.filename) {
                imageLookup[ImageResolutionEngine.customAlbumLookupKey(
                    artist: imageOverride.artist,
                    album: imageOverride.album
                )] = url.absoluteString
            }
        }
        for track in try modelContext.fetch(FetchDescriptor<Track>()) {
            guard let artistName = track.artist?.name,
                  let filename = track.customImageFilename,
                  let url = ImageStore.localCustomFileURL(for: filename) else { continue }
            let target = ImageTarget(kind: .track, artist: artistName, album: nil, track: track.title)
            imageLookup[ImageResolutionEngine.lookupKey(for: target)] = url.absoluteString
        }
        return (lovedSet, imageLookup)
    }
}

/// The Top Charts ranking algorithm — grouping, tie-break rules, album-merge
/// handling, period-over-period rank comparison, and the Peak-rank checkpoint
/// sampler. This/Prev/Move/Peak only need a second ranking pass over
/// already-available local scrobble data.
enum TopChartsEngine {
    private struct PoolCacheValue {
        let current: [RankableScrobble]
        let compare: [RankableScrobble]?
    }

    @MainActor private static var poolCache: [String: PoolCacheValue] = [:]

    @MainActor
    static func invalidatePoolCache() {
        poolCache.removeAll()
    }

    /// DB-side date-predicate fetch per range — used by Top Charts' own page,
    /// which only ranks once per reload, so a narrow per-range fetch is
    /// already efficient (no redundant-fetch problem to avoid here). The
    /// fetch itself has to happen on the main actor (SwiftData's
    /// `ModelContext`/`Scrobble` are tied to it), but `RankableScrobble` is a
    /// plain Sendable struct, so the actual grouping/sorting/peak-sampling —
    /// the genuinely expensive part for a wide "All time" range — runs on a
    /// detached background task instead of blocking the UI.
    @MainActor
    static func fetchRankings(
        container: ModelContainer, durationContext: ModelContext? = nil,
        entity: TopChartsEntity, range: DateRange, compareRange: DateRange? = nil,
        limit: Int = 100, includePeak: Bool = true, metric: TopChartsMetric = .scrobbles,
        sourceCacheKey: String? = nil
    ) async throws -> [TopChartEntry] {
        let currentPool: [RankableScrobble]
        let comparePool: [RankableScrobble]?
        if let sourceCacheKey, let cached = poolCache[sourceCacheKey] {
            currentPool = cached.current
            comparePool = cached.compare
        } else {
            currentPool = try await offMain { try await TopChartsDataReader(modelContainer: container).fetchPool(range: range) }
            if let compareRange {
                comparePool = try await offMain { try await TopChartsDataReader(modelContainer: container).fetchPool(range: compareRange) }
            } else {
                comparePool = nil
            }
            if let sourceCacheKey {
                poolCache[sourceCacheKey] = PoolCacheValue(current: currentPool, compare: comparePool)
            }
        }
        // Duration resolution needs `DurationEngine`'s MainActor-bound
        // `ModelContext`, so it happens here, BEFORE detaching for the pure,
        // Sendable-only `rank` pass — `rank` itself stays synchronous and
        // network-free either way, just consuming a plain `[String: Int]`
        // lookup instead of resolving anything itself.
        let durationLookup: [String: Int]
        if metric == .timeListened {
            durationLookup = await resolveDurationLookup(
                context: durationContext ?? container.mainContext,
                pool: currentPool + (comparePool ?? [])
            )
        } else {
            durationLookup = [:]
        }
        let (lovedSet, imageLookup) = try await offMain { try await TopChartsDataReader(modelContainer: container).fetchPresentationLookups(includeLoved: entity == .track) }
        return await Task.detached(priority: .utility) {
            rank(currentPool: currentPool, comparePool: comparePool, entity: entity, range: range, limit: limit, includePeak: includePeak, metric: metric, durationLookup: durationLookup, lovedSet: lovedSet, imageLookup: imageLookup)
        }.value
    }

    /// Reads every currently cached duration and enqueues cold misses in the
    /// shared background warmer. Rankings return immediately with partial data
    /// and are refreshed as the warmer persists additional batches.
    @MainActor
    private static func resolveDurationLookup(context: ModelContext, pool: [RankableScrobble]) async -> [String: Int] {
        let snapshots = pool.map {
            ScrobbleSnapshot(
                artistName: $0.artist, albumName: $0.album, trackName: $0.track,
                imageURL: $0.imageURL, playedAt: $0.playedAt
            )
        }
        return await DurationEngine.resolveDurationLookup(
            context: context, client: DeezerAPIClient(), scrobbles: snapshots
        )
    }

    static func fetchOldestScrobbleDate(container: ModelContainer) async throws -> Date? {
        return try await offMain { try await TopChartsDataReader(modelContainer: container).fetchOldestScrobbleDate() }
    }

    /// Main-context variant retained for detail-page computations that already
    /// execute on the main actor. The Top Charts tab uses the container-based
    /// overload above so its database read doesn't block tab animations.
    @MainActor
    static func fetchRankings(
        context: ModelContext, entity: TopChartsEntity, range: DateRange, compareRange: DateRange? = nil,
        limit: Int = 100, includePeak: Bool = true
    ) async throws -> [TopChartEntry] {
        let currentPool = try fetchPool(context: context, range: range)
        let comparePool = try compareRange.map { try fetchPool(context: context, range: $0) }
        let imageLookup = try ImageResolutionEngine.imageLookup(context: context)
        return await Task.detached(priority: .utility) {
            rank(currentPool: currentPool, comparePool: comparePool, entity: entity, range: range, limit: limit, includePeak: includePeak, imageLookup: imageLookup)
        }.value
    }

    /// In-memory variant over an already-fetched, already-Sendable scrobble
    /// snapshot array — used by Overview's LongTailEngine, which shares one
    /// whole-library fetch across ~10 engines rather than each hitting the
    /// DB separately. Overview's caller already runs this from within its
    /// own background task, so no additional detaching happens here.
    static func fetchRankings(
        scrobbles: [ScrobbleSnapshot], entity: TopChartsEntity, range: DateRange, compareRange: DateRange? = nil,
        limit: Int = 100, includePeak: Bool = true, metric: TopChartsMetric = .scrobbles,
        durationLookup: [String: Int] = [:]
    ) -> [TopChartEntry] {
        let currentPool = project(scrobbles, range: range)
        let comparePool = compareRange.map { project(scrobbles, range: $0) }
        return rank(
            currentPool: currentPool, comparePool: comparePool, entity: entity, range: range,
            limit: limit, includePeak: includePeak, metric: metric, durationLookup: durationLookup
        )
    }

    /// Artist- or album-scoped ranking for a detail page's sortable sub-list.
    /// Uses the same range, comparison period, and metric as the parent chart.
    /// Database reads use a dedicated model actor and apply the entity scope in
    /// the fetch predicate, keeping navigation and scrolling on the main actor.
    @MainActor
    static func fetchScopedRankings(
        container: ModelContainer,
        durationContext: ModelContext,
        entity: TopChartsEntity,
        artist: String,
        album: String? = nil,
        range: DateRange,
        compareRange: DateRange?,
        metric: TopChartsMetric
    ) async throws -> [TopChartEntry] {
        let currentPool = try await offMain { try await TopChartsDataReader(modelContainer: container).fetchScopedPool(range: range, artist: artist, album: album) }
        let comparePool: [RankableScrobble]?
        if let compareRange {
            comparePool = try await offMain { try await TopChartsDataReader(modelContainer: container).fetchScopedPool(range: compareRange, artist: artist, album: album) }
        } else {
            comparePool = nil
        }
        let durationLookup = metric == .timeListened
            ? await resolveDurationLookup(context: durationContext, pool: currentPool + (comparePool ?? []))
            : [:]
        let (lovedSet, imageLookup) = try await offMain { try await TopChartsDataReader(modelContainer: container).fetchPresentationLookups(includeLoved: entity == .track) }
        let releaseDateLookup: [String: ReleaseDateEngine.Resolution]
        if entity == .album || entity == .track {
            var albumPairs: [String: (artist: String, album: String)] = [:]
            for scrobble in currentPool where !scrobble.album.isEmpty {
                let key = TextNormalization.albumIdentityKey(artist: scrobble.artist, album: scrobble.album)
                if albumPairs[key] == nil {
                    albumPairs[key] = (artist: scrobble.artist, album: scrobble.album)
                }
            }
            releaseDateLookup = ReleaseDateEngine.resolveAlbumDateLookup(
                context: durationContext,
                musicBrainz: MusicBrainzAPIClient(),
                deezer: DeezerAPIClient(),
                albums: Array(albumPairs.values)
            )
        } else {
            releaseDateLookup = [:]
        }
        return await Task.detached(priority: .userInitiated) {
            rank(
                currentPool: currentPool,
                comparePool: comparePool,
                entity: entity,
                range: range,
                limit: Int.max,
                includePeak: false,
                metric: metric,
                durationLookup: durationLookup,
                lovedSet: lovedSet,
                releaseDateLookup: releaseDateLookup,
                imageLookup: imageLookup
            )
        }.value
    }

    @MainActor
    static func fetchScopedRankings(
        context: ModelContext, entity: TopChartsEntity, artist: String, album: String? = nil,
        range: DateRange, compareRange: DateRange?, metric: TopChartsMetric
    ) async throws -> [TopChartEntry] {
        func scoped(_ pool: [RankableScrobble]) -> [RankableScrobble] {
            pool.filter { scrobble in
                let matchesArtist = album == nil
                    ? scrobble.artist == artist
                    : TextNormalization.trackMatchesArtistContext(trackArtist: scrobble.artist, context: artist)
                guard matchesArtist else { return false }
                return album.map { scrobble.album == $0 } ?? true
            }
        }

        let currentPool = scoped(try fetchPool(context: context, range: range))
        let comparePool = try compareRange.map { scoped(try fetchPool(context: context, range: $0)) }
        let durationLookup = metric == .timeListened
            ? await resolveDurationLookup(context: context, pool: currentPool + (comparePool ?? []))
            : [:]
        let lovedSet: Set<String> = entity == .track ? LovedTracksEngine.lovedSet(context: context) : []
        let imageLookup = try ImageResolutionEngine.imageLookup(context: context)
        let releaseDateLookup: [String: ReleaseDateEngine.Resolution]
        if entity == .album || entity == .track {
            var albumPairs: [String: (artist: String, album: String)] = [:]
            for s in currentPool where !s.album.isEmpty {
                let key = TextNormalization.albumIdentityKey(artist: s.artist, album: s.album)
                if albumPairs[key] == nil { albumPairs[key] = (artist: s.artist, album: s.album) }
            }
            releaseDateLookup = ReleaseDateEngine.resolveAlbumDateLookup(
                context: context, musicBrainz: MusicBrainzAPIClient(), deezer: DeezerAPIClient(),
                albums: Array(albumPairs.values)
            )
        } else {
            releaseDateLookup = [:]
        }
        return await Task.detached(priority: .utility) {
            rank(
                currentPool: currentPool, comparePool: comparePool, entity: entity, range: range,
                limit: Int.max, includePeak: false, metric: metric, durationLookup: durationLookup, lovedSet: lovedSet,
                releaseDateLookup: releaseDateLookup, imageLookup: imageLookup
            )
        }.value
    }

    struct YearlyRank: Identifiable, Hashable, Sendable {
        var id: Int { year }
        let year: Int
        let rank: Int
    }

    /// Yearly top ranks: for every
    /// past calendar year (the current, still-in-progress year is always
    /// excluded), where did this entity place among everything of its kind
    /// that year? Reuses `fetchRankings` itself once per year rather than a
    /// bespoke grouping pass — a handful of full-library ranking passes ranks
    /// the whole year (not just a pre-filtered slice), expressed as N calls to
    /// the existing primitive instead of new grouping code.
    static func fetchYearlyTopRanks(
        container: ModelContainer,
        entity: TopChartsEntity,
        name: String,
        artist: String?
    ) async throws -> [YearlyRank] {
        let pool = try await offMain { try await TopChartsDataReader(modelContainer: container).fetchAllPool() }
        return await Task.detached(priority: .utility) {
            guard let firstDate = pool.first?.playedAt else { return [] }
            let calendar = AppCalendars.listening
            let firstYear = calendar.component(.year, from: firstDate)
            let currentYear = calendar.component(.year, from: Date())
            guard firstYear < currentYear else { return [] }

            var poolsByYear: [Int: [RankableScrobble]] = [:]
            for scrobble in pool {
                let year = calendar.component(.year, from: scrobble.playedAt)
                if year < currentYear {
                    poolsByYear[year, default: []].append(scrobble)
                }
            }

            var results: [YearlyRank] = []
            for year in firstYear..<currentYear {
                guard let yearPool = poolsByYear[year], !yearPool.isEmpty else { continue }
                var components = DateComponents(year: year, month: 1, day: 1)
                guard let start = calendar.date(from: components) else { continue }
                components.year = year + 1
                guard let nextStart = calendar.date(from: components) else { continue }
                let range = DateRange(from: start, to: nextStart.addingTimeInterval(-1))
                let entries = rank(
                    currentPool: yearPool,
                    comparePool: nil,
                    entity: entity,
                    range: range,
                    limit: Int.max,
                    includePeak: false
                )
                if let match = entries.first(where: { $0.name == name && $0.artist == artist }),
                   match.rank <= 25 {
                    results.append(YearlyRank(year: year, rank: match.rank))
                }
            }
            return results.sorted { $0.year > $1.year }
        }.value
    }

    /// The same answer as the background version above, computed year by year on the main context. Nothing in the app calls it any
    /// more (it keeps the main thread busy for seconds on a large library); the real-data check compares the two.
    @MainActor
    static func fetchYearlyTopRanksOnMainContext(
        context: ModelContext, entity: TopChartsEntity, name: String, artist: String?
    ) async throws -> [YearlyRank] {
        var oldest = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        oldest.fetchLimit = 1
        guard let firstScrobble = try context.fetch(oldest).first?.playedAt else { return [] }

        let calendar = AppCalendars.listening
        let firstYear = calendar.component(.year, from: firstScrobble)
        let currentYear = calendar.component(.year, from: Date())
        guard firstYear < currentYear else { return [] }

        var results: [YearlyRank] = []
        for year in firstYear..<currentYear {
            var components = DateComponents(year: year, month: 1, day: 1)
            let start = calendar.date(from: components)!
            components.year = year + 1
            let end = calendar.date(from: components)!.addingTimeInterval(-1)
            let range = DateRange(from: start, to: end)

            let entries = try await fetchRankings(context: context, entity: entity, range: range, limit: Int.max, includePeak: false)
            guard let match = entries.first(where: { $0.name == name && $0.artist == artist }), match.rank <= 25 else { continue }
            results.append(YearlyRank(year: year, rank: match.rank))
        }
        return results.sorted { $0.year > $1.year }
    }

    private static func rank(
        currentPool: [RankableScrobble], comparePool: [RankableScrobble]?, entity: TopChartsEntity, range: DateRange,
        limit: Int, includePeak: Bool, metric: TopChartsMetric = .scrobbles, durationLookup: [String: Int] = [:],
        lovedSet: Set<String> = [], releaseDateLookup: [String: ReleaseDateEngine.Resolution] = [:], imageLookup: [String: String] = [:]
    ) -> [TopChartEntry] {
        // A group's Time Listened value: each scrobble contributes its own
        // track's resolved duration once (not the group's — for an album or
        // artist entity, `group` spans many distinct tracks). Missing/
        // unresolved durations contribute 0, matching `DurationEngine`'s own
        // best-effort-sum semantics.
        func metricContribution(_ scrobble: RankableScrobble) -> Int {
            if metric == .scrobbles { return 1 }
            return durationLookup[TextNormalization.lovedKey(artist: scrobble.artist, track: scrobble.track)] ?? 0
        }
        // Last.fm may return casing variants of one artist as separate raw
        // strings. Canonicalize the current and comparison pools together so
        // grouping, comparison ranks, and peak ranks all share one identity.
        let canonicalArtistNames = TextNormalization.canonicalArtistNames(
            (currentPool + (comparePool ?? [])).map(\.artist)
        )
        func canonicalized(_ pool: [RankableScrobble]) -> [RankableScrobble] {
            pool.map { scrobble in
                let key = TextNormalization.artistIdentityKey(scrobble.artist)
                return RankableScrobble(
                    artist: canonicalArtistNames[key] ?? scrobble.artist.trimmingCharacters(in: .whitespacesAndNewlines),
                    album: scrobble.album,
                    track: scrobble.track,
                    imageURL: scrobble.imageURL,
                    playedAt: scrobble.playedAt
                )
            }
        }
        let canonicalCurrentPool = canonicalized(currentPool)
        let canonicalComparePool = comparePool.map(canonicalized)
        let pool = entity == .album ? canonicalCurrentPool.filter { !$0.album.isEmpty } : canonicalCurrentPool

        // Album-merge decisions are computed once from the CURRENT range's
        // pool and reused unchanged for the compare-range grouping and the
        // peak checkpoint sampler, so a merged row's identity stays
        // consistent across all three.
        let albumMerges: [String: TextNormalization.AlbumMergeDecision]? =
            entity == .album ? TextNormalization.detectAlbumMerges(pool.map { ($0.artist, $0.album) }) : nil

        func key(_ s: RankableScrobble) -> String {
            switch entity {
            case .artist:
                return s.artist
            case .album:
                let norm = TextNormalization.normalizeAlbumName(s.album)
                if let decision = albumMerges?[norm] {
                    switch decision {
                    case .compilation: return "\u{0}VA\u{0}\(norm)"
                    case .primaryArtist: return "\u{0}PA\u{0}\(norm)"
                    }
                }
                return "\(s.artist)\u{0}\(s.album)"
            case .track:
                return "\(s.artist)\u{0}\(s.track)"
            }
        }

        // Value desc (play count, or Time Listened when that's the selected
        // metric), ties by artist name, then (tracks only) by track name —
        // matches `makeGroupRankComparator` exactly for the Scrobbles case;
        // Time Listened reuses the identical tie-break rules, just swapping
        // the primary comparison value.
        func isBetterRanked(_ a: RankedGroup, _ b: RankedGroup) -> Bool {
            if a.value != b.value { return a.value > b.value }
            if a.scrobbles[0].artist != b.scrobbles[0].artist {
                return a.scrobbles[0].artist < b.scrobbles[0].artist
            }
            if entity == .track { return a.scrobbles[0].track < b.scrobbles[0].track }
            return false
        }

        // Groups preserve first-seen (earliest-scrobbled) order within each
        // bucket, since `pool` is fetched sorted ascending by playedAt and
        // array append preserves that — explicit "Ordered" bookkeeping since
        // Swift's Dictionary iteration order isn't insertion order, so ties beyond the
        // explicit rules fall back to first-scrobbled order.
        var groups: [String: [RankableScrobble]] = [:]
        var groupValues: [String: Int] = [:]
        var groupOrder: [String] = []
        for s in pool {
            let k = key(s)
            if groups[k] == nil { groupOrder.append(k) }
            groups[k, default: []].append(s)
            groupValues[k, default: 0] += metricContribution(s)
        }
        let ranked = groupOrder
            .map { RankedGroup(key: $0, scrobbles: groups[$0]!, value: groupValues[$0]!) }
            .sorted(by: isBetterRanked)
        let top = Array(ranked.prefix(limit))

        var previousRanks: [String: Int]? = nil
        if let canonicalComparePool {
            let compareFiltered = entity == .album ? canonicalComparePool.filter { !$0.album.isEmpty } : canonicalComparePool
            var compareGroups: [String: [RankableScrobble]] = [:]
            var compareValues: [String: Int] = [:]
            var compareOrder: [String] = []
            for s in compareFiltered {
                let k = key(s)
                if compareGroups[k] == nil { compareOrder.append(k) }
                compareGroups[k, default: []].append(s)
                compareValues[k, default: 0] += metricContribution(s)
            }
            let compareRanked = compareOrder
                .map { RankedGroup(key: $0, scrobbles: compareGroups[$0]!, value: compareValues[$0]!) }
                .sorted(by: isBetterRanked)
            var ranks: [String: Int] = [:]
            for (index, entry) in compareRanked.enumerated() { ranks[entry.key] = index + 1 }
            previousRanks = ranks
        }

        // The checkpoint sampler re-ranks every wanted entity at up to ~60
        // points — cheap for the table's usual top-100, but callers that
        // rank the FULL library (like LongTailEngine's `limit: .max`) can
        // opt out since they only need playcount, not a peak rank.
        let peakRanks: [String: Int]
        if includePeak {
            let wantedKeys = Set(top.map(\.key))
            peakRanks = computePeakRanks(
                pool: pool, from: range.from, to: range.to, key: key,
                metricContribution: metricContribution, isBetterRanked: isBetterRanked,
                wantedKeys: wantedKeys
            )
        } else {
            peakRanks = [:]
        }

        var entries: [TopChartEntry] = []
        for (index, entry) in top.enumerated() {
            let group = entry.scrobbles
            let sample = group[0]
            let name: String
            let artistDisplay: String?
            var albumDisplay: String? = nil
            switch entity {
            case .artist:
                name = sample.artist
                artistDisplay = nil
            case .album:
                name = sample.album
                let norm = TextNormalization.normalizeAlbumName(sample.album)
                switch albumMerges?[norm] {
                case .compilation: artistDisplay = TextNormalization.variousArtistsLabel
                case .primaryArtist(let artist): artistDisplay = artist
                case nil: artistDisplay = sample.artist
                }
            case .track:
                name = sample.track
                artistDisplay = sample.artist
                albumDisplay = sample.album.isEmpty ? nil : sample.album
            }
            let rank = index + 1
            let loved = entity == .track && lovedSet.contains(TextNormalization.lovedKey(artist: sample.artist, track: sample.track))
            // Album entities look up their own release date directly; track
            // entities use their (sample) album as a practical stand-in for
            // the true most-played primary album this bulk-ranking pass
            // doesn't otherwise group by — good enough for list display, not
            // used for the single-track detail page's own resolution, which
            // computes the real primary album from that track's full
            // scrobble history instead (see `ReleaseDateEngine.primaryAlbum`).
            var releaseDateResolution: ReleaseDateEngine.Resolution = .unknown
            switch entity {
            case .album:
                releaseDateResolution = releaseDateLookup[
                    TextNormalization.albumIdentityKey(artist: sample.artist, album: name)
                ] ?? .pending
            case .track:
                if let albumDisplay {
                    releaseDateResolution = releaseDateLookup[
                        TextNormalization.albumIdentityKey(artist: sample.artist, album: albumDisplay)
                    ] ?? .pending
                }
            case .artist:
                break
            }
            let imageTarget = ImageTarget(
                kind: entity == .artist ? .artist : (entity == .album ? .album : .track),
                artist: sample.artist,
                album: entity == .album ? name : albumDisplay,
                track: entity == .track ? name : nil
            )
            let fallbackImage = TextNormalization.firstNonPlaceholderImage(group.map(\.imageURL))
            entries.append(TopChartEntry(
                rank: rank, name: name, artist: artistDisplay, album: albumDisplay,
                playcount: group.count, timeListenedSeconds: metric == .timeListened ? entry.value : nil,
                imageURL: ImageResolutionEngine.effectiveImageURL(for: imageTarget, lookup: imageLookup, fallbackURL: fallbackImage),
                hasCompareRange: previousRanks != nil,
                previousRank: previousRanks?[entry.key],
                peakRank: peakRanks[entry.key] ?? rank,
                lastPlayedAt: group.map(\.playedAt).max()!,
                loved: loved, releaseDateResolution: releaseDateResolution
            ))
        }
        return entries
    }

    private static func fetchPool(context: ModelContext, range: DateRange) throws -> [RankableScrobble] {
        let from = range.from
        let to = range.to
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate<Scrobble> { $0.playedAt >= from && $0.playedAt <= to },
            sortBy: [SortDescriptor(\.playedAt)]
        )
        let scrobbles = try context.fetch(descriptor)
        return scrobbles.map {
            RankableScrobble(artist: $0.artistName, album: $0.albumName, track: $0.trackName, imageURL: $0.imageURL, playedAt: $0.playedAt)
        }
    }

    /// In-memory equivalent of `fetchPool` — filters an already-fetched
    /// array instead of hitting the DB. `scrobbles` must be ascending by
    /// `playedAt` (the shared Overview fetch already guarantees this) so the
    /// "Ordered" group bookkeeping and the peak sampler's forward scan stay
    /// correct.
    private static func project(_ scrobbles: [ScrobbleSnapshot], range: DateRange) -> [RankableScrobble] {
        scrobbles
            .filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
            .map { RankableScrobble(artist: $0.artistName, album: $0.albumName, track: $0.trackName, imageURL: $0.imageURL, playedAt: $0.playedAt) }
    }

    /// Best (lowest) rank an entity held at any point within `[from, to]` —
    /// modeled as periodic cumulative-plays checkpoints through the range
    /// (day/week/month cadence depending on span), capped at ~60 checkpoints so a wide
    /// "All time" range doesn't re-rank the whole universe hundreds of
    /// times. The last checkpoint always lands exactly on `to`, so an
    /// entity's peak is never worse than its current rank. Only computed
    /// for `wantedKeys` (the current top-N), matching source — no need to
    /// rank entities that aren't even shown.
    private static func computePeakRanks(
        pool: [RankableScrobble], from: Date, to: Date,
        key: (RankableScrobble) -> String,
        metricContribution: (RankableScrobble) -> Int,
        isBetterRanked: (RankedGroup, RankedGroup) -> Bool,
        wantedKeys: Set<String>
    ) -> [String: Int] {
        let span = max(to.timeIntervalSince(from), 1)
        let days = span / 86400
        let baseInterval: TimeInterval = days <= 92 ? 86400 : (days <= 730 ? 7 * 86400 : 30 * 86400)
        let interval = max(baseInterval, span / 60)

        // `pool` is already sorted ascending by playedAt (carried over from
        // the FetchDescriptor's sort).
        let sorted = pool

        var checkpoints: [Date] = []
        var t = from.addingTimeInterval(interval)
        while t < to {
            checkpoints.append(t)
            t = t.addingTimeInterval(interval)
        }
        checkpoints.append(to)

        var peaks: [String: Int] = [:]
        var cumulative: [String: [RankableScrobble]] = [:]
        var cumulativeValues: [String: Int] = [:]
        var cumulativeOrder: [String] = []
        var cursor = 0

        for checkpoint in checkpoints {
            while cursor < sorted.count, sorted[cursor].playedAt <= checkpoint {
                let s = sorted[cursor]
                let k = key(s)
                if cumulative[k] == nil { cumulativeOrder.append(k) }
                cumulative[k, default: []].append(s)
                cumulativeValues[k, default: 0] += metricContribution(s)
                cursor += 1
            }
            if cumulative.isEmpty { continue }
            let rankedAtCheckpoint = cumulativeOrder
                .map { RankedGroup(key: $0, scrobbles: cumulative[$0]!, value: cumulativeValues[$0]!) }
                .sorted(by: isBetterRanked)
            for (index, entry) in rankedAtCheckpoint.enumerated() {
                guard wantedKeys.contains(entry.key) else { continue }
                let rank = index + 1
                if let best = peaks[entry.key] {
                    if rank < best { peaks[entry.key] = rank }
                } else {
                    peaks[entry.key] = rank
                }
            }
        }
        return peaks
    }
}
