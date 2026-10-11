import Foundation
import SwiftData

/// Track duration resolution + the "Time Listened" metric derived from it.
/// Time Listened is NOT a second resolution pipeline — it's just
/// `Σ (plays × resolved duration)` over already-resolved durations, per the
/// PRD's explicit scope note. The resolution shape itself (cache-or-fetch,
/// resolved lazily on demand by whichever view needs it, cached indefinitely,
/// a 120ms politeness delay after every LIVE fetch only) is a direct copy of
/// `AlbumTurnoverEngine.getCachedTracklist`; `BPMEngine` follows the same shape.
@MainActor
enum DurationEngine {
    struct Progress: Sendable {
        let remaining: Int
        let isComplete: Bool
    }

    static let progressNotification = Notification.Name("DurationEngineProgress")

    private struct PendingTrack: Sendable {
        let artist: String
        let track: String
        let album: String?
    }

    private struct FetchResult: Sendable {
        let key: String
        let seconds: Int?
        let succeeded: Bool
        /// Stopped because Offline mode is on: not a failure, and the key stays queued.
        var paused = false
    }

    private static let fetchConcurrency = 8
    private static let persistEvery = 200
    private static let batchDelayNanoseconds: UInt64 = 450_000_000
    private static var pending: [String: PendingTrack] = [:]
    private static var warmerTask: Task<Void, Never>?
    /// Failed rounds (each already several attempts) per pending key, so an unreachable lookup is dropped, not looped on.
    private static var failedRounds: [String: Int] = [:]
    private static let maxFailedRounds = 3
    /// A track's resolved runtime is unbounded on the override side (a live
    /// recording/DJ mix/podcast can legitimately run long, matching
    /// `Track.durationOverrideSeconds`'s own doc comment) but Deezer-resolved
    /// values are trusted as-is too — no cap applied.
    nonisolated static func cacheKey(artist: String, track: String) -> String {
        TextNormalization.lovedKey(artist: artist, track: track)
    }

    /// Cache-or-fetch for the Deezer-resolved value ONLY — does not consult
    /// any override. Mirrors `AlbumTurnoverEngine.getCachedTracklist` exactly:
    /// a cache row (found or confirmed miss) is inserted for both outcomes; a
    /// transient failure is never persisted, so the next lookup retries
    /// instead of freezing a network blip as a permanent "no duration." The
    /// 120ms delay follows every LIVE fetch attempt, never a cache hit.
    static func getCachedDeezerDuration(
        context: ModelContext, client: DeezerAPIClient, artist: String, track: String, album: String?
    ) async throws -> Int? {
        let key = cacheKey(artist: artist, track: track)
        var descriptor = FetchDescriptor<TrackDurationCacheEntry>(predicate: #Predicate { $0.cacheKey == key })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing.seconds
        }

        do {
            let fetched = try await client.fetchTrackDuration(artist: artist, track: track, album: album)
            context.insert(TrackDurationCacheEntry(cacheKey: key, seconds: fetched, cachedAt: Date()))
            try context.save()
            try? await Task.sleep(nanoseconds: 120_000_000)
            return fetched
        } catch {
            try? await Task.sleep(nanoseconds: 120_000_000)
            throw error
        }
    }

    /// The full precedence chain every overridable field in this app follows:
    /// a user's override always wins over a freshly-resolved value, even when
    /// they disagree — real duration overrides in this library exist
    /// specifically to correct bad Deezer data, so a disagreement is the
    /// override doing its job, not a bug. Looks the `Track` row up by the
    /// same `identityKey` (`TextNormalization.lovedKey`) every other resolver
    /// in this codebase uses, so it finds exactly the row a manual edit or
    /// backup restore wrote to.
    static func resolvedDuration(
        context: ModelContext, client: DeezerAPIClient, artist: String, track: String, album: String?
    ) async throws -> Int? {
        let key = cacheKey(artist: artist, track: track)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == key })
        descriptor.fetchLimit = 1
        if let existingTrack = try context.fetch(descriptor).first, let override = existingTrack.durationOverrideSeconds {
            return override
        }
        return try await getCachedDeezerDuration(context: context, client: client, artist: artist, track: track, album: album)
    }

    /// Where one track's runtime stands.
    enum Resolution: Sendable, Equatable {
        case seconds(Int)
        /// A cached genuine miss — Deezer has no match and there's no override.
        case noMatch
        /// Neither an override nor a cache row yet: not resolved.
        case pending
    }

    /// An immutable, read-only copy of everything duration resolution reads, so
    /// the precedence rule below can run off the main actor (the query engine) as
    /// well as inside `resolveDurationLookup`. There is ONE precedence rule.
    struct Snapshot: Sendable {
        /// `cacheKey` → cached Deezer seconds.
        var cachedSeconds: [String: Int] = [:]
        /// `cacheKey`s whose cache row is a confirmed miss.
        var cachedMisses: Set<String> = []
        /// `cacheKey` → user override (`Track.durationOverrideSeconds`).
        var overrides: [String: Int] = [:]

        nonisolated static let empty = Snapshot()

        /// Override > cached Deezer value > cached miss > pending — the same
        /// chain `resolvedDuration` documents.
        nonisolated func resolution(forKey key: String) -> Resolution {
            if let override = overrides[key] { return .seconds(override) }
            if let seconds = cachedSeconds[key] { return .seconds(seconds) }
            if cachedMisses.contains(key) { return .noMatch }
            return .pending
        }

        /// Every key with a usable runtime — the lookup `timeListenedSeconds` sums over.
        nonisolated var secondsLookup: [String: Int] {
            cachedSeconds.merging(overrides) { _, override in override }
        }
    }

    /// Read-only: never enqueues and never starts the warmer.
    nonisolated static func loadSnapshot(context: ModelContext) -> Snapshot {
        var snapshot = Snapshot()
        for entry in (try? context.fetch(FetchDescriptor<TrackDurationCacheEntry>())) ?? [] {
            if let seconds = entry.seconds { snapshot.cachedSeconds[entry.cacheKey] = seconds } else { snapshot.cachedMisses.insert(entry.cacheKey) }
        }
        for track in (try? context.fetch(FetchDescriptor<Track>())) ?? [] {
            if let seconds = track.durationOverrideSeconds { snapshot.overrides[track.identityKey] = seconds }
        }
        return snapshot
    }

    /// One (artist, track, album) identity worth resolving a duration for —
    /// `album` is only ever used as tier-5 search context (see
    /// `DeezerAPIClient.fetchTrackDuration`), never part of the cache key.
    struct TrackIdentity: Hashable {
        let artist: String
        let track: String
        let album: String?

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.artist == rhs.artist && lhs.track == rhs.track }
        func hash(into hasher: inout Hasher) { hasher.combine(artist); hasher.combine(track) }
    }

    /// Total seconds listened across a set of scrobbles — resolves each
    /// DISTINCT (artist, track) identity's duration once (cache-first, so an
    /// already-warm cache costs nothing extra), then multiplies by how many
    /// times that identity appears. A track whose duration genuinely can't be
    /// resolved (cached miss, or a transient failure mid-resolution) simply
    /// contributes 0 — Time Listened is a best-effort sum over what's
    /// resolvable, not an all-or-nothing computation; a single unresolvable
    /// track must not blank out an entire chart entry's total.
    static func timeListenedSeconds(
        context: ModelContext, client: DeezerAPIClient, scrobbles: [ScrobbleSnapshot]
    ) async -> Int {
        let lookup = await resolveDurationLookup(context: context, client: client, scrobbles: scrobbles)
        return timeListenedSeconds(scrobbles: scrobbles, lookup: lookup)
    }

    /// The pure sum behind Time Listened: each DISTINCT (artist, track) identity's
    /// runtime × how many times it appears. A track with no usable runtime
    /// contributes 0.
    nonisolated static func timeListenedSeconds(scrobbles: [ScrobbleSnapshot], lookup: [String: Int]) -> Int {
        var counts: [TrackIdentity: Int] = [:]
        var order: [TrackIdentity] = []
        for s in scrobbles {
            guard !s.trackName.isEmpty else { continue }
            let identity = TrackIdentity(artist: s.artistName, track: s.trackName, album: s.albumName.isEmpty ? nil : s.albumName)
            if counts[identity] == nil { order.append(identity) }
            counts[identity, default: 0] += 1
        }
        return order.reduce(0) { total, identity in
            total + (lookup[cacheKey(artist: identity.artist, track: identity.track)] ?? 0) * (counts[identity] ?? 0)
        }
    }

    /// Resolves the override-aware duration for every distinct (artist,
    /// track) identity found in `scrobbles`, returning a lookup keyed by
    /// `cacheKey` — the same per-identity resolution `timeListenedSeconds`
    /// does internally, just returned as a dictionary instead of pre-summed.
    /// For callers (Top Charts' per-group ranking, Overview's Top Picks)
    /// that need to attribute duration back to individual scrobbles rather
    /// than a single running total.
    static func resolveDurationLookup(
        context: ModelContext, client: DeezerAPIClient, scrobbles: [ScrobbleSnapshot]
    ) async -> [String: Int] {
        var targets: [String: PendingTrack] = [:]
        for s in scrobbles {
            guard !s.trackName.isEmpty else { continue }
            let key = cacheKey(artist: s.artistName, track: s.trackName)
            targets[key] = PendingTrack(
                artist: s.artistName, track: s.trackName,
                album: s.albumName.isEmpty ? nil : s.albumName
            )
        }

        let snapshot = loadSnapshot(context: context)
        var lookup: [String: Int] = [:]
        for (key, target) in targets {
            switch snapshot.resolution(forKey: key) {
            case .seconds(let seconds): lookup[key] = seconds
            case .noMatch: break
            case .pending: pending[key] = target
            }
        }
        if !pending.isEmpty, warmerTask == nil, !ConnectivityGate.isOffline {
            postProgress(isComplete: false)
            startWarmer(context: context, client: client)
        }
        return lookup
    }

    private static func startWarmer(context: ModelContext, client: DeezerAPIClient) {
        warmerTask = Task { @MainActor in
            var resolvedSinceSave = 0
            while !pending.isEmpty, !Task.isCancelled, !ConnectivityGate.isOffline {
                let batch = Array(pending.prefix(fetchConcurrency))
                let results = await withTaskGroup(of: FetchResult.self, returning: [FetchResult].self) { group in
                    for (key, target) in batch {
                        group.addTask {
                            await fetchWithRetry(key: key, target: target, client: client)
                        }
                    }
                    var values: [FetchResult] = []
                    for await value in group { values.append(value) }
                    return values
                }

                for result in results {
                    if result.paused { continue }
                    if result.succeeded {
                        context.insert(TrackDurationCacheEntry(cacheKey: result.key, seconds: result.seconds, cachedAt: Date()))
                        pending.removeValue(forKey: result.key)
                        failedRounds.removeValue(forKey: result.key)
                        resolvedSinceSave += 1
                    } else {
                        // A key that keeps failing is dropped for now (it is not cached, so a screen asks again later)
                        // instead of being retried in a loop that never ends.
                        failedRounds[result.key, default: 0] += 1
                        if (failedRounds[result.key] ?? 0) >= maxFailedRounds {
                            pending.removeValue(forKey: result.key)
                            failedRounds.removeValue(forKey: result.key)
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
            postProgress(isComplete: pending.isEmpty || ConnectivityGate.isOffline)
            if !pending.isEmpty, !ConnectivityGate.isOffline { startWarmer(context: context, client: client) }
        }
    }

    nonisolated private static func fetchWithRetry(
        key: String, target: PendingTrack, client: DeezerAPIClient
    ) async -> FetchResult {
        var delay: UInt64 = 500_000_000
        for attempt in 0...4 {
            do {
                let seconds = try await client.fetchTrackDuration(
                    artist: target.artist, track: target.track, album: target.album
                )
                return FetchResult(key: key, seconds: seconds, succeeded: true)
            } catch {
                if error is OfflineError { return FetchResult(key: key, seconds: nil, succeeded: false, paused: true) }
                if attempt == 4 { return FetchResult(key: key, seconds: nil, succeeded: false) }
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        return FetchResult(key: key, seconds: nil, succeeded: false)
    }

    private static func postProgress(isComplete: Bool) {
        NotificationCenter.default.post(
            name: progressNotification,
            object: Progress(remaining: pending.count, isComplete: isComplete)
        )
    }

    /// `"3:45"` under an hour, `"1:03:45"` at/above one hour.
    static func formatDuration(_ totalSeconds: Int) -> String {
        let seconds = max(0, totalSeconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Aggregate listening time, expressed as calendar-like duration units
    /// instead of the clock notation used for an individual track runtime.
    static func formatTimeListened(_ totalSeconds: Int) -> String {
        let total = max(0, totalSeconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        var components: [String] = []
        if days > 0 { components.append("\(days)d") }
        if hours > 0 || days > 0 { components.append("\(hours)h") }
        if minutes > 0 || hours > 0 || days > 0 { components.append("\(minutes)m") }
        components.append("\(seconds)s")
        return components.joined(separator: " ")
    }

    /// Parses a user-entered `m:ss` or `h:mm:ss` string into seconds, or nil
    /// if it isn't a valid duration. Used by the manual override field and (loosely)
    /// by the pasted-tracklist trailing-duration stripper in the Album
    /// Matching Fix UI.
    static func parseDuration(_ input: String) -> Int? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        if numbers.count == 2 {
            let (m, s) = (numbers[0], numbers[1])
            guard s < 60 else { return nil }
            return m * 60 + s
        } else {
            let (h, m, s) = (numbers[0], numbers[1], numbers[2])
            guard m < 60, s < 60 else { return nil }
            return h * 3600 + m * 60 + s
        }
    }
}
