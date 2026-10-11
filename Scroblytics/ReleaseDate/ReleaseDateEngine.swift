import Foundation
import SwiftData

/// Release date resolution + override — the original template this
/// project's whole "background queue, indefinite cache, override wins"
/// pattern was copied from for Duration/BPM/Album Turnover. Cascade:
///
/// - **Album**: MusicBrainz release-group search (`first-release-date`, the
///   canonical earliest date) first; Deezer's `/album/{id}` only as a
///   fallback on a genuine MusicBrainz miss.
/// - **Track**: a track's date is almost always its own most-scrobbled
///   ("primary") album's resolved date, NOT an independent lookup —
///   MusicBrainz's recording search isn't reliable for picking the
///   canonical studio release. Only when a track has no locally-observed
///   album at all does it fall through to a direct Deezer track lookup.
/// - A **track-level override** always wins over the album default; an
///   **album-level override** (checked while resolving the primary album)
///   wins over any freshly-resolved album value. So a track with no
///   override still reflects an album-level correction.
///
/// Unlike Deezer (Duration's sole source), MusicBrainz enforces a real
/// ~1 request/second unauthenticated rate limit — the warmer here is
/// deliberately serialized (`fetchConcurrency = 1`) rather than reusing
/// Duration's newer 8-wide concurrent warmer, and EVERY resolution
/// (single-entity or bulk) funnels through the same queue so a burst of
/// detail-page visits can never exceed that limit either.
@MainActor
enum ReleaseDateEngine {
    struct Progress: Sendable {
        let remaining: Int
        let isComplete: Bool
    }

    enum Resolution: Sendable, Hashable {
        case pending
        case unknown
        case date(String)

        var date: String? {
            guard case .date(let value) = self else { return nil }
            return value
        }

        /// THE album precedence rule: override > detected > (already looked up, found
        /// nothing → unknown) > not resolved yet. Used by the bulk lookup below and by
        /// `Snapshot`, so the two can never drift.
        nonisolated static func classify(override: String?, detected: String?, resolved: Bool) -> Resolution {
            if let override { return .date(override) }
            if let detected { return .date(detected) }
            return resolved ? .unknown : .pending
        }
    }

    /// An immutable, read-only copy of every row release-date resolution reads, so the
    /// precedence rules can run off the main actor (the query engine). Never enqueues.
    struct Snapshot: Sendable {
        struct AlbumInfo: Sendable {
            let artistKey: String
            let override: String?
            let detected: String?
            let resolved: Bool
        }
        /// By the row's own `identityKey`.
        var albumsByIdentityKey: [String: AlbumInfo] = [:]
        /// The fallback `albumRow` uses: same normalized title, same artist across casing variants.
        var albumsByNormalizedTitle: [String: [AlbumInfo]] = [:]
        /// `lovedKey` → `Track.releaseDateOverride`.
        var trackOverrides: [String: String] = [:]
        /// `TrackReleaseDateCacheEntry` rows: `lovedKey` → date, or nil for a cached miss.
        var trackCache: [String: String?] = [:]

        nonisolated static let empty = Snapshot()

        /// Mirrors `albumRow(context:artist:album:)` (exact identity key, then the
        /// case-variant fallback) followed by `Resolution.classify`. A missing row is
        /// `.pending`, exactly as `resolveAlbumDateLookup` reports it.
        nonisolated func albumResolution(artist: String, album: String) -> Resolution {
            var info = albumsByIdentityKey[TextNormalization.albumIdentityKey(artist: artist, album: album)]
            if info == nil {
                let artistKey = TextNormalization.artistIdentityKey(artist)
                info = albumsByNormalizedTitle[TextNormalization.normalizeAlbumName(album)]?.first { $0.artistKey == artistKey }
            }
            guard let info else { return .pending }
            return .classify(override: info.override, detected: info.detected, resolved: info.resolved)
        }

        /// Mirrors `cachedTrackDate`: track override > the primary album's resolution >
        /// (no album at all) the track's own cache row.
        nonisolated func trackResolution(artist: String, track: String, primaryAlbum: String?) -> Resolution {
            let key = TextNormalization.lovedKey(artist: artist, track: track)
            if let override = trackOverrides[key] { return .date(override) }
            if let primaryAlbum { return albumResolution(artist: artist, album: primaryAlbum) }
            if let cached = trackCache[key] { return cached.map { .date($0) } ?? .unknown }
            return .pending
        }
    }

    /// Read-only: never enqueues and never starts the warmer.
    nonisolated static func loadSnapshot(context: ModelContext) -> Snapshot {
        var snapshot = Snapshot()
        for album in (try? context.fetch(FetchDescriptor<Album>())) ?? [] {
            let info = Snapshot.AlbumInfo(
                artistKey: album.artist.map { TextNormalization.artistIdentityKey($0.name) } ?? "",
                override: album.releaseDateOverride, detected: album.releaseDateDetected,
                resolved: album.releaseDateResolvedAt != nil
            )
            snapshot.albumsByIdentityKey[album.identityKey] = info
            snapshot.albumsByNormalizedTitle[album.normalizedTitle, default: []].append(info)
        }
        for track in (try? context.fetch(FetchDescriptor<Track>())) ?? [] {
            if let override = track.releaseDateOverride { snapshot.trackOverrides[track.identityKey] = override }
        }
        for entry in (try? context.fetch(FetchDescriptor<TrackReleaseDateCacheEntry>())) ?? [] {
            snapshot.trackCache[entry.cacheKey] = .some(entry.date)
        }
        return snapshot
    }

    static let progressNotification = Notification.Name("ReleaseDateEngineProgress")

    private enum TargetKind { case album, track }
    private struct PendingTarget: Sendable {
        let kind: TargetKind
        let artist: String
        let name: String
    }
    private struct FetchResult: Sendable {
        let key: String
        let kind: TargetKind
        let date: String?
        let succeeded: Bool
        /// Stopped because Offline mode is on: not a failure, and the target stays queued.
        var paused = false
    }

    /// MusicBrainz's unauthenticated rate limit (~1 req/sec) governs the
    /// whole queue, even though most Deezer-fallback/track-direct requests
    /// individually could go faster — one shared, conservative pace is
    /// simpler and safer than tracking two different budgets.
    private static let fetchConcurrency = 1
    private static let batchDelayNanoseconds: UInt64 = 1_100_000_000
    nonisolated private static let maxRetries = 4
    private static let persistEvery = 20
    private static var pending: [String: PendingTarget] = [:]
    /// The order pending targets are fetched in. Anything a screen is waiting on goes to the FRONT, the
    /// library-wide sweep queues at the BACK — opening an album page never waits behind the sweep.
    private static var pendingOrder: [String] = []
    /// Failed rounds (each already `maxRetries` attempts) per pending key.
    private static var failedRounds: [String: Int] = [:]
    private static let maxFailedRounds = 3
    /// MusicBrainz answers 503 (or 429) when asked too fast — ask again only after a real pause.
    nonisolated private static let rateLimitedPause: UInt64 = 30_000_000_000
    private static var warmerTask: Task<Void, Never>?

    // MARK: - Album resolution

    /// Override > cached-detected > `nil` (and enqueues for the background
    /// warmer when neither is known yet). Never blocks — matches
    /// `DurationEngine.resolveDurationLookup`'s lazy, non-blocking contract.
    /// Use `resolveAlbumDateAwaiting` when a single entity must be resolved
    /// right now (a detail page) rather than filled in via the progress
    /// notification later.
    static func cachedAlbumDate(context: ModelContext, artist: String, album: String) -> String? {
        guard let row = albumRow(context: context, artist: artist, album: album) else { return nil }
        if let override = row.releaseDateOverride { return override }
        if row.releaseDateResolvedAt != nil { return row.releaseDateDetected }
        enqueue(context: context, kind: .album, artist: artist, name: album, key: row.identityKey)
        return nil
    }

    /// Shared by `QueryBuilderModel.resolvePending()` (Query's own "Resolve" button, scoped to a whole
    /// query's pending set) and the Missing Data tool (scoped to its own filtered rows): given a set of
    /// scrobbles and a snapshot of what's already resolved, finds every distinct (artist, album) pair and
    /// every album-less track that's still `.pending` and pushes it through the existing rate-limited
    /// queue — the exact branching a track defers to its primary album's resolution requires (see
    /// `Snapshot.trackResolution`). Non-blocking; never enqueues something already known.
    static func resolvePending(
        context: ModelContext, musicBrainz: MusicBrainzAPIClient, deezer: DeezerAPIClient,
        scrobbles: [ScrobbleSnapshot], snapshot: Snapshot
    ) {
        var albums: [(artist: String, album: String)] = []
        var seen = Set<String>()
        for s in scrobbles where !s.albumName.isEmpty {
            let key = "\(s.artistName)\u{0}\(s.albumName)"
            if seen.insert(key).inserted, snapshot.albumResolution(artist: s.artistName, album: s.albumName) == .pending {
                albums.append((s.artistName, s.albumName))
            }
        }
        var byTrack: [String: [ScrobbleSnapshot]] = [:]
        for s in scrobbles where s.albumName.isEmpty && !s.trackName.isEmpty {
            byTrack["\(s.artistName)\u{0}\(s.trackName)", default: []].append(s)
        }
        for (_, group) in byTrack {
            let s = group[0]
            if snapshot.trackResolution(artist: s.artistName, track: s.trackName, primaryAlbum: nil) == .pending {
                _ = cachedTrackDate(context: context, artist: s.artistName, track: s.trackName, primaryAlbum: nil)
            }
        }
        _ = resolveAlbumDateLookup(context: context, musicBrainz: musicBrainz, deezer: deezer, albums: albums)
    }

    /// Bulk, non-blocking lookup for every (artist, album) pair given —
    /// returns whatever's already known and enqueues the rest, same shape as
    /// `DurationEngine.resolveDurationLookup`. Callers re-render as more
    /// resolve via `progressNotification`.
    static func resolveAlbumDateLookup(
        context: ModelContext, musicBrainz: MusicBrainzAPIClient, deezer: DeezerAPIClient,
        albums: [(artist: String, album: String)]
    ) -> [String: Resolution] {
        var lookup: [String: Resolution] = [:]
        for (artist, album) in albums {
            let lookupKey = TextNormalization.albumIdentityKey(artist: artist, album: album)
            guard let row = albumRow(context: context, artist: artist, album: album) else {
                lookup[lookupKey] = .pending
                continue
            }
            let resolution = Resolution.classify(
                override: row.releaseDateOverride, detected: row.releaseDateDetected, resolved: row.releaseDateResolvedAt != nil
            )
            if resolution == .pending {
                enqueue(context: context, kind: .album, artist: row.artist?.name ?? artist, name: row.title, key: row.identityKey)
            }
            lookup[lookupKey] = resolution
        }
        startWarmerIfNeeded(context: context, musicBrainz: musicBrainz, deezer: deezer)
        return lookup
    }

    /// Single-entity blocking resolve for a detail page — enqueues (if not
    /// already known) and awaits that SPECIFIC entry's resolution through the
    /// same rate-limited queue every other caller uses, rather than issuing
    /// its own ad-hoc request that could burst past MusicBrainz's limit.
    static func resolveAlbumDateAwaiting(
        context: ModelContext, musicBrainz: MusicBrainzAPIClient, deezer: DeezerAPIClient,
        artist: String, album: String
    ) async -> String? {
        if let known = cachedAlbumDate(context: context, artist: artist, album: album) {
            return known
        }
        guard let row = albumRow(context: context, artist: artist, album: album) else { return nil }
        if row.releaseDateResolvedAt != nil { return row.releaseDateDetected }
        startWarmerIfNeeded(context: context, musicBrainz: musicBrainz, deezer: deezer)
        // Stop waiting if Offline mode pauses the queue (nothing will resolve it), or the caller goes away.
        while pending[row.identityKey] != nil, !ConnectivityGate.isOffline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return cachedAlbumDate(context: context, artist: artist, album: album)
    }

    // MARK: - Track resolution

    /// A track's own most-scrobbled album (plain play-count majority, no fuzzy
    /// matching). Computed fresh from the track's own scrobbles each call;
    /// cheap, purely local.
    nonisolated static func primaryAlbum(scrobbles: [ScrobbleSnapshot]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for s in scrobbles where !s.albumName.isEmpty {
            if counts[s.albumName] == nil { order.append(s.albumName) }
            counts[s.albumName, default: 0] += 1
        }
        var best: String?
        var bestCount = 0
        for name in order where counts[name]! > bestCount {
            bestCount = counts[name]!
            best = name
        }
        return best
    }

    /// Track override > primary album's date (which itself checks the
    /// album's own override first) > direct Deezer track lookup, only when
    /// no primary album is known at all. Never blocks for the album/no-album
    /// paths (matches `cachedAlbumDate`'s lazy contract); the rare direct
    /// track case also enqueues rather than fetching inline.
    static func cachedTrackDate(context: ModelContext, artist: String, track: String, primaryAlbum: String?) -> String? {
        let trackKey = TextNormalization.lovedKey(artist: artist, track: track)
        if let trackRow = fetchTrackRow(context: context, identityKey: trackKey), let override = trackRow.releaseDateOverride {
            return override
        }
        if let primaryAlbum {
            return cachedAlbumDate(context: context, artist: artist, album: primaryAlbum)
        }
        var descriptor = FetchDescriptor<TrackReleaseDateCacheEntry>(predicate: #Predicate { $0.cacheKey == trackKey })
        descriptor.fetchLimit = 1
        if let cached = try? context.fetch(descriptor).first {
            return cached.date
        }
        enqueue(context: context, kind: .track, artist: artist, name: track, key: trackKey)
        return nil
    }

    /// Single-entity blocking resolve for a track detail page — same
    /// queue-awaiting shape as `resolveAlbumDateAwaiting`. Track override is
    /// checked FIRST, before the primary-album path, matching
    /// `cachedTrackDate`'s precedence — a track override must win even when
    /// a primary album exists (the common case).
    static func resolveTrackDateAwaiting(
        context: ModelContext, musicBrainz: MusicBrainzAPIClient, deezer: DeezerAPIClient,
        artist: String, track: String, primaryAlbum: String?
    ) async -> String? {
        let trackKey = TextNormalization.lovedKey(artist: artist, track: track)
        if let trackRow = fetchTrackRow(context: context, identityKey: trackKey), let override = trackRow.releaseDateOverride {
            return override
        }
        if let primaryAlbum {
            return await resolveAlbumDateAwaiting(context: context, musicBrainz: musicBrainz, deezer: deezer, artist: artist, album: primaryAlbum)
        }
        var descriptor = FetchDescriptor<TrackReleaseDateCacheEntry>(predicate: #Predicate { $0.cacheKey == trackKey })
        descriptor.fetchLimit = 1
        if let cached = try? context.fetch(descriptor).first {
            return cached.date
        }
        enqueue(context: context, kind: .track, artist: artist, name: track, key: trackKey)
        startWarmerIfNeeded(context: context, musicBrainz: musicBrainz, deezer: deezer)
        while pending[trackKey] != nil, !ConnectivityGate.isOffline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.date
    }

    // MARK: - Warmer

    private static func enqueue(context: ModelContext, kind: TargetKind, artist: String, name: String, key: String, priority: Bool = true) {
        if pending[key] != nil {
            // Already queued (perhaps by the sweep); something is waiting on it now, so move it up.
            if priority, let index = pendingOrder.firstIndex(of: key), index > 0 {
                pendingOrder.remove(at: index)
                pendingOrder.insert(key, at: 0)
            }
            return
        }
        pending[key] = PendingTarget(kind: kind, artist: artist, name: name)
        if priority { pendingOrder.insert(key, at: 0) } else { pendingOrder.append(key) }
    }

    /// The library-wide sweep: queues every album that has never been looked up (no override, no
    /// detected date, never resolved — a genuine "not found" is recorded and never asked again) at the
    /// back of the queue and starts the warmer. Runs through the ONE shared queue, so it inherits its
    /// pace (one request every ~1.1 s, within MusicBrainz's 1 request/second limit) and its retry,
    /// back-off and caching. Safe to call repeatedly — at launch and after every sync. Returns how many
    /// albums it queued. Never blocks: the lookups happen in the background.
    @discardableResult
    static func seedUnresolvedAlbums(context: ModelContext, musicBrainz: MusicBrainzAPIClient, deezer: DeezerAPIClient) async -> Int {
        guard !ConnectivityGate.isOffline else { return 0 }
        // The candidates come from a background read (a first launch has every album unresolved);
        // only the queue itself is touched here.
        let container = context.container
        let unresolved = (try? await offMain { try await ReleaseDateSeedReader(modelContainer: container).fetchUnresolvedAlbums() }) ?? []
        var queued = 0
        for album in unresolved where pending[album.key] == nil {
            enqueue(context: context, kind: .album, artist: album.artist, name: album.title, key: album.key, priority: false)
            queued += 1
        }
        startWarmerIfNeeded(context: context, musicBrainz: musicBrainz, deezer: deezer)
        return queued
    }

    private static func startWarmerIfNeeded(context: ModelContext, musicBrainz: MusicBrainzAPIClient, deezer: DeezerAPIClient) {
        guard !pending.isEmpty, warmerTask == nil, !ConnectivityGate.isOffline else { return }
        postProgress(isComplete: false)
        warmerTask = Task { @MainActor in
            var resolvedSinceSave = 0
            while !pending.isEmpty, !Task.isCancelled, !ConnectivityGate.isOffline {
                let batch = pendingOrder.prefix(fetchConcurrency).compactMap { key in pending[key].map { (key, $0) } }
                var results: [FetchResult] = []
                for (key, target) in batch {
                    results.append(await fetchWithRetry(key: key, target: target, musicBrainz: musicBrainz, deezer: deezer))
                }

                for result in results {
                    if result.paused { continue }
                    if result.succeeded {
                        persist(context: context, result: result)
                        finish(result.key)
                        resolvedSinceSave += 1
                    } else {
                        // Rotate a failing target to the back so it can't block the rest; after a few
                        // failed rounds give up on it for now (it isn't cached, so the next launch or
                        // sync tries again) — and stop anyone still waiting on it.
                        failedRounds[result.key, default: 0] += 1
                        if (failedRounds[result.key] ?? 0) >= maxFailedRounds {
                            finish(result.key)
                        } else if let index = pendingOrder.firstIndex(of: result.key) {
                            pendingOrder.remove(at: index)
                            pendingOrder.append(result.key)
                        }
                    }
                }
                if resolvedSinceSave >= persistEvery || pending.isEmpty {
                    try? context.save()
                    resolvedSinceSave = 0
                    if !pending.isEmpty { postProgress(isComplete: false) }
                }
                if !pending.isEmpty {
                    try? await Task.sleep(nanoseconds: batchDelayNanoseconds)
                }
            }
            if resolvedSinceSave > 0 { try? context.save() }
            warmerTask = nil
            // Paused by Offline mode counts as "nothing running" for the status strip; the queue is kept.
            postProgress(isComplete: pending.isEmpty || ConnectivityGate.isOffline)
            if !pending.isEmpty { startWarmerIfNeeded(context: context, musicBrainz: musicBrainz, deezer: deezer) }
        }
    }

    private static func finish(_ key: String) {
        pending.removeValue(forKey: key)
        failedRounds.removeValue(forKey: key)
        if let index = pendingOrder.firstIndex(of: key) { pendingOrder.remove(at: index) }
    }

    private static func persist(context: ModelContext, result: FetchResult) {
        switch result.kind {
        case .album:
            if let row = fetchAlbumRow(context: context, identityKey: result.key) {
                row.releaseDateDetected = result.date
                row.releaseDateResolvedAt = Date()
            }
        case .track:
            context.insert(TrackReleaseDateCacheEntry(cacheKey: result.key, date: result.date, cachedAt: Date()))
        }
    }

    nonisolated private static func fetchWithRetry(
        key: String, target: PendingTarget, musicBrainz: MusicBrainzAPIClient, deezer: DeezerAPIClient
    ) async -> FetchResult {
        var delay: UInt64 = 500_000_000
        for attempt in 0...maxRetries {
            do {
                let date: String?
                switch target.kind {
                case .album:
                    date = try await resolveAlbumDate(artist: target.artist, album: target.name, musicBrainz: musicBrainz, deezer: deezer)
                case .track:
                    date = try await deezer.fetchTrackReleaseDate(artist: target.artist, track: target.name)
                }
                return FetchResult(key: key, kind: target.kind, date: date, succeeded: true)
            } catch {
                if error is OfflineError { return FetchResult(key: key, kind: target.kind, date: nil, succeeded: false, paused: true) }
                if attempt == maxRetries { return FetchResult(key: key, kind: target.kind, date: nil, succeeded: false) }
                var pause = delay
                if case MusicBrainzAPIError.http(let status) = error, status == 503 || status == 429 { pause = max(pause, rateLimitedPause) }
                try? await Task.sleep(nanoseconds: pause)
                delay *= 2
            }
        }
        return FetchResult(key: key, kind: target.kind, date: nil, succeeded: false)
    }

    /// MusicBrainz first (edition-stripped query + nickname hints pulled out
    /// separately), Deezer only on a genuine MusicBrainz miss. A MusicBrainz
    /// THROW (rate limit, network) fails the whole attempt for retry — it
    /// does NOT fall through to Deezer, matching source: only a confirmed
    /// "no match" (return value `nil`) does.
    nonisolated private static func resolveAlbumDate(
        artist: String, album: String, musicBrainz: MusicBrainzAPIClient, deezer: DeezerAPIClient
    ) async throws -> String? {
        let queryAlbum = TextNormalization.stripEditionSuffix(album)
        let (mbQueryAlbum, mbHints) = TextNormalization.extractQueryHints(album)
        if let mbDate = try await musicBrainz.fetchAlbumReleaseDate(artist: artist, album: mbQueryAlbum, hints: mbHints) {
            return mbDate
        }
        return try await deezer.fetchAlbumReleaseDate(artist: artist, album: queryAlbum)
    }

    private static func postProgress(isComplete: Bool) {
        NotificationCenter.default.post(name: progressNotification, object: Progress(remaining: pending.count, isComplete: isComplete))
    }

    // MARK: - Row lookups

    /// Finds an album across case-only artist variants. Album identity keys in
    /// existing stores preserve the artist casing that first created the row,
    /// while charts use the most-played casing for display.
    static func albumRow(context: ModelContext, artist: String, album: String) -> Album? {
        let key = TextNormalization.albumIdentityKey(artist: artist, album: album)
        if let exact = fetchAlbumRow(context: context, identityKey: key) { return exact }

        let normalizedAlbum = TextNormalization.normalizeAlbumName(album)
        let descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.normalizedTitle == normalizedAlbum })
        let artistKey = TextNormalization.artistIdentityKey(artist)
        return (try? context.fetch(descriptor))?.first {
            guard let candidateArtist = $0.artist else { return false }
            return TextNormalization.artistIdentityKey(candidateArtist.name) == artistKey
        }
    }

    private static func fetchAlbumRow(context: ModelContext, identityKey: String) -> Album? {
        var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.identityKey == identityKey })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchTrackRow(context: ModelContext, identityKey: String) -> Track? {
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == identityKey })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Formatting

    /// Renders "YYYY", "YYYY-MM", or "YYYY-MM-DD" as a human date string,
    /// matching whatever precision was actually resolved rather than
    /// fabricating a day/month that was never known.
    static func formatDate(_ raw: String) -> String {
        let parts = raw.split(separator: "-").map(String.init)
        switch parts.count {
        case 1:
            return parts[0]
        case 2:
            guard let month = Int(parts[1]), (1...12).contains(month) else { return raw }
            return "\(monthName(month)) \(parts[0])"
        case 3:
            guard let month = Int(parts[1]), (1...12).contains(month), let day = Int(parts[2]) else { return raw }
            return "\(monthName(month)) \(day), \(parts[0])"
        default:
            return raw
        }
    }

    /// Renders just the 4-digit year string ("YYYY") for library/list views.
    static func formatYear(_ raw: String) -> String {
        guard let y = year(of: raw) else { return raw }
        return String(y)
    }

    /// The year alone, for sorting/grouping — the leading 4 digits of
    /// whatever precision was resolved.
    nonisolated static func year(of raw: String) -> Int? {
        Int(raw.prefix(4))
    }

    /// The first day of the period a "YYYY" / "YYYY-MM" / "YYYY-MM-DD" string covers
    /// (a year-only date is January 1), in `calendar`. Nil for anything malformed.
    nonisolated static func periodStart(of raw: String, calendar: Calendar = AppCalendars.releaseDates) -> Date? {
        let parts = raw.split(separator: "-").map(String.init)
        guard (1...3).contains(parts.count), let year = Int(parts[0]) else { return nil }
        var components = DateComponents(year: year, month: 1, day: 1)
        if parts.count >= 2 { guard let month = Int(parts[1]) else { return nil }; components.month = month }
        if parts.count == 3 { guard let day = Int(parts[2]) else { return nil }; components.day = day }
        return calendar.date(from: components)
    }

    private static func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.monthSymbols[month - 1]
    }

    /// Validates a user-entered "YYYY" | "YYYY-MM" | "YYYY-MM-DD" string —
    /// used by the manual override field. Rejects anything else rather than
    /// silently accepting a malformed date that would then fail to parse
    /// everywhere this value is displayed/sorted.
    static func parseDate(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "-").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        guard let yearValue = Int(parts[0]), parts[0].count == 4, yearValue > 0 else { return nil }
        if parts.count >= 2 {
            guard let month = Int(parts[1]), parts[1].count == 2, (1...12).contains(month) else { return nil }
        }
        if parts.count == 3 {
            guard let day = Int(parts[2]), parts[2].count == 2, (1...31).contains(day) else { return nil }
        }
        return trimmed
    }
}

@ModelActor
private actor ReleaseDateSeedReader {
    struct UnresolvedAlbum: Sendable {
        let key: String
        let artist: String
        let title: String
    }

    /// Albums that have never been looked up: no override, no detected date, never resolved.
    func fetchUnresolvedAlbums() throws -> [UnresolvedAlbum] {
        let descriptor = FetchDescriptor<Album>(predicate: #Predicate {
            $0.releaseDateOverride == nil && $0.releaseDateDetected == nil && $0.releaseDateResolvedAt == nil
        })
        return try modelContext.fetch(descriptor).compactMap { album in
            guard let artist = album.artist?.name else { return nil }
            return UnresolvedAlbum(key: album.identityKey, artist: artist, title: album.title)
        }
    }
}
