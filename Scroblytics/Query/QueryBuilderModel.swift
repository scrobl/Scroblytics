import Foundation
import Observation
import SwiftData

/// A row's identity in the table: the entity, and the year when the results are broken down by year (an entity then has a row per year).
struct QueryRowKey: Hashable, Sendable {
    let entity: QueryEntityID
    let period: Int?
}

/// A result row plus what the table needs to draw the pinned identity cell.
struct QueryDisplayRow: Identifiable, Sendable {
    let row: QueryRow
    let imageURL: String?
    /// The calendar year, when the results are broken down by year.
    var period: Int? { row.period }
    /// Context line under the name: the artist for albums/tracks, plus the
    /// album for tracks.
    let subtitle: String?
    var id: QueryRowKey { QueryRowKey(entity: row.id, period: row.period) }
    /// The entity's own id (what the result's per-entity info is keyed by).
    var entityID: QueryEntityID { row.id }
    var entity: QueryEntity { row.entity }

    /// Resolves each row's artwork the same way Top Charts does (custom overrides first, then the scrobble's own
    /// art) and builds its context line. Shared by the Query tab and any tool that draws a result in the same table.
    static func make(from result: QueryResult, imageLookup lookup: [String: String]) -> [QueryDisplayRow] {
        // The universe's per-entity artwork/album, from the same single pass the fields read.
        result.rows.map { row in
            let info = result.entityInfo[row.id]
            let target: ImageTarget
            switch row.entity.target {
            case .artist: target = ImageTarget(kind: .artist, artist: row.entity.artist, album: nil, track: nil)
            case .album: target = ImageTarget(kind: .album, artist: row.entity.artist, album: row.entity.name, track: nil)
            case .track: target = ImageTarget(kind: .track, artist: row.entity.artist, album: info?.album, track: row.entity.name)
            }
            let subtitle: String? = switch row.entity.target {
            case .artist: nil
            case .album: row.entity.artist
            case .track: [row.entity.artist, info?.album].compactMap { $0 }.joined(separator: " · ")
            }
            return QueryDisplayRow(
                row: row,
                imageURL: ImageResolutionEngine.effectiveImageURL(for: target, lookup: lookup, fallbackURL: info?.imageURL),
                subtitle: subtitle
            )
        }
    }
}

/// A sentence put to Ask and the query it became. It describes the results only while the query is unchanged: once a filter, sort or
/// limit is edited it no longer says what is on screen. (Reordering the columns doesn't change what was asked.)
struct AskedQuestion: Equatable, Sendable {
    let text: String
    let spec: QuerySpec

    func text(whenQueryIs current: QuerySpec) -> String? {
        var a = spec, b = current
        a.columns = []
        b.columns = []
        return a == b ? text : nil
    }
}

/// One autocomplete suggestion in the tag picker: a tag and how many cached items carry it.
struct QueryTagSuggestion: Identifiable, Hashable, Sendable {
    let tag: String
    let items: Int
    var id: String { tag }
}

/// Drives the condition builder: owns the working `QuerySpec` (persisted on
/// every change, so it survives relaunch), runs it in the background, and
/// holds the result the generic table renders.
@MainActor
@Observable
final class QueryBuilderModel {
    static let workingSpecKey = "query.builder.workingSpec.v1"

    let registry = QueryFieldRegistry.standard
    let container: ModelContainer

    var spec: QuerySpec {
        didSet {
            guard spec != oldValue else { return }
            persistWorkingSpec()
            scheduleRun()
        }
    }

    private(set) var displayRows: [QueryDisplayRow] = []
    private(set) var result: QueryResult?
    private(set) var validationError: String?
    private(set) var runError: String?
    private(set) var isRunning = false
    private(set) var isLoadingScrobbles = true
    private(set) var lastRunSeconds: Double?
    /// One-shot notes ("Removed 2 conditions that don't apply to albums").
    private(set) var notice: String?
    /// The sentence put to Ask that produced the query now on screen, with the query as it was then.
    private(set) var asked: AskedQuestion?

    /// Remembers the question behind `spec` (nil forgets it). Call after the spec is loaded.
    func rememberQuestion(_ question: String?, for spec: QuerySpec) {
        asked = question.map { AskedQuestion(text: $0, spec: spec) }
    }

    /// The question, while the query still is what it asked for.
    var currentQuestion: String? { asked?.text(whenQueryIs: spec) }

    /// The saved set currently loaded, if any (Save updates it in place).
    var loadedSetID: UUID?
    private(set) var oldestScrobbleDate: Date?

    private var scrobbles: [ScrobbleSnapshot] = []
    private var runTask: Task<Void, Never>?
    private var popularity: PopularityStore?
    private var tagStore: TagStore?
    /// Read-only copy of the duration cache + overrides, refreshed on the main actor.
    private var durations = DurationEngine.Snapshot.empty
    private var bpm = BPMEngine.Snapshot.empty
    private var releaseDates = ReleaseDateEngine.Snapshot.empty
    private var turnover = AlbumTurnoverEngine.Snapshot.empty
    private var lovedKeys: Set<String> = []
    private var flaggedKeys: Set<String> = []
    private var entityTags = EntityTagsSnapshot.empty
    private var images = ImageStatusSnapshot.empty
    private var libraryPresence = LibraryPresenceSnapshot.empty
    private var weather = WeatherSnapshot.empty
    private var snapshotsRefreshTask: Task<Void, Never>?
    /// Every tag that exists in the library, most common first — the tag picker's suggestions.
    private(set) var tagVocabulary: [QueryTagSuggestion] = []
    /// Every artist name in the library (already canonicalized), for Ask to validate a "by <artist>" against.
    var knownArtists: Set<String> { Set(scrobbles.map(\.artistName)) }
    private let turnoverGroups = TurnoverGroupCache()
    private(set) var isResolving = false
    /// "12 of 40" while a tracklist lookup is running.
    private(set) var resolveProgress: String?

    static func defaultSpec(target: QueryTarget = .track) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.columns = [QueryFieldRef("plays"), QueryFieldRef("lastPlayed")]
        spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
        spec.limit = 100
        return spec
    }

    init(container: ModelContainer) {
        self.container = container
        #if DEBUG
        // Verification hook: start from a spec file and leave the saved working spec alone.
        if let path = ProcessInfo.processInfo.environment["SCROBLYTICS_QUERY_SPEC"] {
            do { spec = try QuerySpec.decode(Data(contentsOf: URL(fileURLWithPath: path))) } catch {
                fatalError("SCROBLYTICS_QUERY_SPEC could not be read: \(error)")
            }
            return
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: Self.workingSpecKey),
           let restored = try? QuerySpec.decode(data) {
            spec = restored
        } else {
            spec = Self.defaultSpec()
        }
    }

    // MARK: - Data

    func attach(popularity: PopularityStore) { self.popularity = popularity }
    func attach(tags: TagStore) { self.tagStore = tags }

    /// Rebuilds the background-resolved snapshots (read-only) and re-runs. Called when a warmer
    /// reports progress, so a query fills in as data arrives. The reads run on a background reader
    /// and bursts of progress reports are coalesced into one refresh.
    /// While a long backlog of lookups is worked through they announce progress every few seconds; re-reading every snapshot and re-running
    /// the query each time kept a big library busy. A background announcement refreshes at most once in `backgroundRefreshInterval`;
    /// coming back to the tab still refreshes at once.
    static let backgroundRefreshInterval: TimeInterval = 120
    private var lastBackgroundRefreshAt = Date.distantPast

    private var trailingBackgroundRefresh: Task<Void, Never>?

    func refreshSnapshotsForBackgroundProgress() {
        let wait = Self.backgroundRefreshInterval - Date().timeIntervalSince(lastBackgroundRefreshAt)
        if wait <= 0 {
            lastBackgroundRefreshAt = Date()
            refreshSnapshots()
        } else if trailingBackgroundRefresh == nil {
            // Catch up once the interval has passed, so what resolved meanwhile still shows.
            trailingBackgroundRefresh = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self else { return }
                self.trailingBackgroundRefresh = nil
                guard !Task.isCancelled else { return }
                self.lastBackgroundRefreshAt = Date()
                self.refreshSnapshots()
            }
        }
    }

    func refreshSnapshots() {
        // Nothing to refresh until the tab has loaded once (`loadScrobbles` loads every snapshot itself).
        guard !scrobbles.isEmpty else { return }
        snapshotsRefreshTask?.cancel()
        snapshotsRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.reloadSnapshots()
            guard !Task.isCancelled else { return }
            self.scheduleRun()
        }
    }

    private func reloadSnapshots() async {
        let container = container
        let loaded = await QuerySnapshotReader.loadAll(container: container)
        durations = loaded.durations
        bpm = loaded.bpm
        releaseDates = loaded.releaseDates
        turnover = loaded.turnover
        lovedKeys = loaded.lovedKeys
        flaggedKeys = loaded.flaggedKeys
        images = loaded.images
        libraryPresence = loaded.libraryPresence
        weather = loaded.weather
        entityTags = loaded.entityTags
        tagVocabulary = entityTags.vocabulary.map { QueryTagSuggestion(tag: $0.tag, items: $0.items) }
    }

    /// Starts the EXISTING resolvers for the unresolved values a result reported —
    /// through the same rate-limited queues (and background-work strip) the rest of
    /// the app uses. Never automatic: a whole-library query would otherwise queue
    /// thousands of lookups nobody asked for.
    func resolvePending() async {
        guard let result, !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        defer { resolveProgress = nil }
        let kinds = Set(result.pending.compactMap(\.resolver))
        if kinds.contains(.duration) {
            let unresolved = scrobbles.filter { s in
                !s.trackName.isEmpty
                    && durations.resolution(forKey: DurationEngine.cacheKey(artist: s.artistName, track: s.trackName)) == .pending
            }
            _ = await DurationEngine.resolveDurationLookup(context: container.mainContext, client: DeezerAPIClient(), scrobbles: unresolved)
        }
        if kinds.contains(.bpm) {
            let wanted = result.pendingEntities[.bpm] ?? []
            let unresolved = scrobbles.filter { s in
                !s.trackName.isEmpty
                    && wanted.contains(QueryEntityID(target: .track, artist: s.artistName, name: s.trackName))
                    && bpm.resolution(forKey: BPMEngine.cacheKey(artist: s.artistName, track: s.trackName)) == .pending
            }
            _ = BPMEngine.resolveBPMLookup(context: container.mainContext, scrobbles: unresolved)
        }
        if kinds.contains(.albumTracklists) { await resolveTracklists() }
        if kinds.contains(.tags) { await resolveTags(for: result.pendingEntities[.tags] ?? []) }
        if kinds.contains(.releaseDate) {
            ReleaseDateEngine.resolvePending(
                context: container.mainContext, musicBrainz: MusicBrainzAPIClient(), deezer: DeezerAPIClient(),
                scrobbles: scrobbles, snapshot: releaseDates
            )
        }
    }

    func loadScrobbles() async {
        isLoadingScrobbles = true
        defer { isLoadingScrobbles = false }
        do {
            let container = container
            scrobbles = try await offMain {
                try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            }
            oldestScrobbleDate = scrobbles.first?.playedAt
        } catch {
            runError = "Couldn’t load your scrobbles: \(error)"
            return
        }
        await reloadSnapshots()
        scheduleRun(immediately: true)
    }

    // MARK: - Running

    func scheduleRun(immediately: Bool = false) {
        runTask?.cancel()
        guard !scrobbles.isEmpty else { return }
        let validated: ValidatedQuery
        do {
            validated = try spec.validate(against: registry)
            validationError = nil
        } catch {
            validationError = "\(error)"
            isRunning = false
            return
        }
        isRunning = true
        let scrobbles = scrobbles
        let snapshots = QuerySnapshots(
            popularity: popularity?.snapshot ?? .empty, durations: durations, bpm: bpm, releaseDates: releaseDates,
            turnover: turnover, lovedKeys: lovedKeys, flaggedKeys: flaggedKeys,
            entityTags: entityTags, libraryPresence: libraryPresence, weather: weather, images: images, turnoverGroups: turnoverGroups
        )
        runTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let started = Date()
            let asOf = validated.spec.asOf ?? Date()
            let result = await Task.detached(priority: .userInitiated) { () -> QueryResult in
                let inScope = validated.spec.countedPlays(scrobbles)
                let run = QueryRun(target: validated.spec.target, asOf: asOf, scrobbles: inScope, allTimeScrobbles: scrobbles, snapshots: snapshots)
                return QueryEngine.evaluate(validated, run: run)
            }.value
            guard !Task.isCancelled, let self else { return }
            let display = self.makeDisplayRows(result)
            self.result = result
            self.displayRows = display
            #if DEBUG
            Self.debugDump(display)
            #endif
            self.lastRunSeconds = Date().timeIntervalSince(started)
            self.runError = nil
            self.isRunning = false
        }
    }

    #if DEBUG
    /// Verification hook: writes exactly the rows the table is given (id, title, first column
    /// value) so the app's wiring can be diffed against an independent harness run.
    private static func debugDump(_ rows: [QueryDisplayRow]) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_QUERY_DUMP"] else { return }
        let lines = rows.map { r -> String in
            let cells = r.row.cells.keys.sorted().map { key -> String in
                if case .value(let v)? = r.row.cells[key] { return "\(key)=\(v)" }
                return "\(key)=∅"
            }
            return "\(r.entity.artist)\t\(r.entity.name)\t\(cells.joined(separator: ";"))"
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
    #endif

    private func makeDisplayRows(_ result: QueryResult) -> [QueryDisplayRow] {
        QueryDisplayRow.make(from: result, imageLookup: images.lookup)
    }

    // MARK: - Editing helpers

    /// Switching target removes anything that doesn't apply to the new one —
    /// and says so — rather than leaving conditions that could never run.
    func setTarget(_ target: QueryTarget) {
        guard target != spec.target else { return }
        let (next, removed) = Self.switching(spec, to: target, registry: registry)
        notice = removed > 0
            ? "Removed \(removed) item\(removed == 1 ? "" : "s") that don’t apply to \(target.rawValue)s."
            : nil
        spec = next
    }

    /// `spec` for another target, minus what doesn't apply to it, and how many things that was.
    nonisolated static func switching(_ spec: QuerySpec, to target: QueryTarget, registry: QueryFieldRegistry) -> (spec: QuerySpec, removed: Int) {
        var next = spec
        next.target = target
        let applicable = Set(registry.fields(for: target).map(\.id))
        var removed = 0
        next.groups = next.groups.map { group in
            group.filter { let keep = applicable.contains($0.field.id); if !keep { removed += 1 }; return keep }
        }.filter { !$0.isEmpty }
        next.sorts = next.sorts.filter { sort in
            if case .field(let ref) = sort.key, !applicable.contains(ref.id) { removed += 1; return false }
            return true
        }
        if let shown = next.resultSorts {
            let kept = shown.filter { sort in
                if case .field(let ref) = sort.key, !applicable.contains(ref.id) { removed += 1; return false }
                return true
            }
            next.resultSorts = kept.isEmpty ? nil : kept
        }
        next.columns = next.columns.filter { let keep = applicable.contains($0.id); if !keep { removed += 1 }; return keep }
        if next.columns.isEmpty { next.columns = [QueryFieldRef("plays"), QueryFieldRef("lastPlayed")] }
        if var groupLimit = next.groupLimit {
            if groupLimit.perArtist != nil, target == .artist { groupLimit.perArtist = nil; removed += 1 }
            if groupLimit.perAlbum != nil, target != .track { groupLimit.perAlbum = nil; removed += 1 }
            if groupLimit.perReleaseYear != nil, target == .artist { groupLimit.perReleaseYear = nil; removed += 1 }
            next.groupLimit = groupLimit.isEmpty ? nil : groupLimit
        }
        return (next, removed)
    }

    func dismissNotice() { notice = nil }

    func moveColumn(_ movingKey: String, before targetKey: String) {
        guard movingKey != targetKey,
              let from = try? spec.columns.firstIndex(where: { try registry.resolve($0, target: spec.target).cacheKey == movingKey }),
              let to = try? spec.columns.firstIndex(where: { try registry.resolve($0, target: spec.target).cacheKey == targetKey })
        else { return }
        var columns = spec.columns
        let moved = columns.remove(at: from)
        // Insert before the drop target; removing `from` first shifts later indices down by one.
        columns.insert(moved, at: from < to ? to - 1 : to)
        spec.columns = columns
    }

    // MARK: - Fading Favorites template

    /// The condition set that reproduces the Overview Fading Favorites card for
    /// the given Overview range: peak ≥ 5, fade ≤ 25%, ranked by rediscovery
    /// score. It is NOT special machinery — three registry fields, two
    /// thresholds and a three-key sort.
    func fadingFavoritesSpec(for range: DateRange) -> QuerySpec {
        let window = QueryValue.number(Double(FadingFavoritesEngine.snappedRecentDays(for: range)))
        func ref(_ id: String) -> QueryFieldRef { QueryFieldRef(id, parameters: ["windowDays": window]) }
        var spec = QuerySpec(target: .track)
        spec.asOf = range.to
        spec.period = QueryPeriod(from: .distantPast, to: range.to)
        spec.groups = [[
            QueryCondition(ref("fadingPeak"), .greaterThanOrEqual, [.number(Double(FadingFavoritesEngine.minPeak))]),
            QueryCondition(ref("fadingDecay"), .lessThanOrEqual, [.number(FadingFavoritesEngine.maxDecay)]),
        ]]
        spec.sorts = [
            QuerySort(key: .field(ref("rediscoveryScore")), direction: .descending),
            QuerySort(key: .field(ref("fadingPeak")), direction: .descending),
            QuerySort(key: .field(QueryFieldRef("lastPlayed")), direction: .ascending),
        ]
        spec.limit = 100
        spec.columns = [ref("fadingPeak"), ref("fadingRecent"), ref("fadingDecay"), ref("rediscoveryScore"), QueryFieldRef("lastPlayed"), QueryFieldRef("plays")]
        return spec
    }

    /// The condition set that selects exactly the tracks the Overview Climbing card and The Climb tool select: in the
    /// all-time top 500 now, outside it (or unranked) 90 days ago, with at least 5 plays in those 90 days. It is
    /// `TheClimbEngine.spec`, so the template and the tool can't drift apart. Ranks are over the plays the query counts, so
    /// the template matches the card only while no period or days/hours filter is set.
    func climbingSpec() -> QuerySpec {
        var spec = TheClimbEngine.spec(compareDays: 90, minPlaysNow: 5, topN: 500)
        spec.limit = 100
        return spec
    }

    /// Hands what a tag query is waiting on to the background tag sweep, ahead of the rest of its queue
    /// (it also syncs your personal tags first if that hasn't happened). Returns at once — the sweep
    /// reports on the status strip and the query refreshes as results land.
    private func resolveTags(for pending: Set<QueryEntityID>) async {
        guard LastfmCredentialsStore.load() != nil else {
            notice = "Connect Last.fm in Settings to look up tags."
            return
        }
        await tagStore?.prioritize(Array(pending))
    }

    /// Fetches the Last.fm tracklists the last result reported as missing, one at a time
    /// through the engine's own cached, rate-limited lookup, refreshing as they land.
    private func resolveTracklists() async {
        guard let credentials = LastfmCredentialsStore.load() else {
            notice = "Connect Last.fm in Settings to look up album tracklists."
            return
        }
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        let scope = scrobbles
        let scopedSpec = spec
        let snapshot = turnover
        let cache = turnoverGroups
        let requests: [AlbumTurnoverEngine.TracklistRequest] = await Task.detached(priority: .userInitiated) {
            let inScope = scopedSpec.countedPlays(scope)
            var seen = Set<String>()
            return cache.groups(for: inScope, separating: snapshot.separateEditions).values.flatMap { $0 }.compactMap { snapshot.missingRequest(for: $0) }
                .filter { seen.insert(AlbumTurnoverEngine.tracklistCacheKey(artist: $0.artist, album: $0.album)).inserted }
        }.value
        for (index, request) in requests.enumerated() {
            resolveProgress = "\(index + 1) of \(requests.count)"
            // A transient failure is never cached by the engine, so a later Resolve retries it.
            _ = try? await AlbumTurnoverEngine.getCachedTracklist(context: container.mainContext, client: client, artist: request.artist, album: request.album)
            if index % 10 == 9 { refreshSnapshots() }
        }
        refreshSnapshots()
    }

    /// The Overview / Milestones "upcoming" list for one kind of entity: closest to the next
    /// milestone first, ties alphabetical, capped at the card's 60.
    func upcomingMilestonesSpec(target: QueryTarget) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.sorts = [
            QuerySort(key: .field(QueryFieldRef("toNextMilestone")), direction: .ascending),
            QuerySort(key: .field(QueryFieldRef("name")), direction: .ascending),
        ]
        spec.limit = 60
        spec.columns = [QueryFieldRef("plays"), QueryFieldRef("nextMilestone"), QueryFieldRef("toNextMilestone"), QueryFieldRef("milestoneEta")]
        return spec
    }

    // MARK: - Saved sets

    func load(_ saved: SavedConditionSet) {
        do {
            let loaded = try QuerySpec.decode(saved.specJSON)
            loadedSetID = saved.id
            notice = nil
            spec = loaded          // even if it no longer validates: the user's set survives and the error is shown
        } catch {
            runError = "“\(saved.name)” couldn’t be opened: \(error)"
        }
    }

    func save(as name: String, context: ModelContext, updating existing: SavedConditionSet?) throws {
        let data = try spec.encoded()
        if let existing {
            existing.name = name
            existing.specJSON = data
            existing.updatedAt = Date()
            loadedSetID = existing.id
        } else {
            let saved = SavedConditionSet(name: name, specJSON: data)
            context.insert(saved)
            loadedSetID = saved.id
        }
        try context.save()
    }

    func delete(_ saved: SavedConditionSet, context: ModelContext) throws {
        if loadedSetID == saved.id { loadedSetID = nil }
        context.delete(saved)
        try context.save()
    }

    func newQuery() {
        loadedSetID = nil
        notice = nil
        spec = Self.defaultSpec(target: spec.target)
    }

    private func persistWorkingSpec() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SCROBLYTICS_QUERY_SPEC"] != nil { return }
        #endif
        if let data = try? spec.encoded() { UserDefaults.standard.set(data, forKey: Self.workingSpecKey) }
    }
}

/// Reads every background-resolved snapshot the query tool consumes, on its own context — one
/// trip off the main thread instead of five full-table reads on it.
@ModelActor
actor QuerySnapshotReader {
    struct Loaded: Sendable {
        let durations: DurationEngine.Snapshot
        let bpm: BPMEngine.Snapshot
        let releaseDates: ReleaseDateEngine.Snapshot
        let turnover: AlbumTurnoverEngine.Snapshot
        let lovedKeys: Set<String>
        let flaggedKeys: Set<String>
        let images: ImageStatusSnapshot
        let entityTags: EntityTagsSnapshot
        let libraryPresence: LibraryPresenceSnapshot
        let weather: WeatherSnapshot
    }

    /// The snapshots, read on a background thread. Use this rather than creating the reader and awaiting `loadAll()`
    /// from main-actor code: a model actor awaited from there runs on the main thread (see `offMain`), which froze the
    /// window for seconds on a large library.
    static func loadAll(container: ModelContainer) async -> Loaded {
        await offMain { await QuerySnapshotReader(modelContainer: container).loadAll() }
    }

    func loadAll() -> Loaded {
        Loaded(
            durations: DurationEngine.loadSnapshot(context: modelContext),
            bpm: BPMEngine.loadSnapshot(context: modelContext),
            releaseDates: ReleaseDateEngine.loadSnapshot(context: modelContext),
            turnover: AlbumTurnoverEngine.loadSnapshot(context: modelContext),
            lovedKeys: LovedTracksEngine.lovedSet(context: modelContext),
            flaggedKeys: Set(((try? modelContext.fetch(FetchDescriptor<FlaggedTrack>())) ?? []).map {
                TextNormalization.lovedKey(artist: $0.artist, track: $0.track)
            }),
            images: ImageStatusSnapshot.load(context: modelContext),
            entityTags: EntityTagsEngine.loadSnapshot(context: modelContext),
            libraryPresence: LibraryPresenceSnapshot.load(context: modelContext),
            weather: WeatherSnapshot.load()
        )
    }
}
