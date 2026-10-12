import Foundation
import Observation
import OSLog
import SwiftData

/// Owns the popularity warmer and the latest calculated `PopularitySnapshot`.
///
/// Resolution follows the same shape as release dates/durations/images: a
/// background queue, rate-limited, cached in SwiftData, refreshed once stale
/// (~30 days) and on demand via Resync — never a live fetch triggered by
/// rendering a row. Unlike those lazily-enqueued fields, the WHOLE library is
/// seeded (see `seedPopularityWarmer`): every percentile is
/// relative to the rest of the library, so warming only what's on screen would
/// compare items against a tiny, arbitrary pool.
@MainActor
@Observable
final class PopularityStore {
    /// Latest calculation over everything resolved so far. Replaced wholesale;
    /// views read it, never mutate it.
    private(set) var snapshot = PopularitySnapshot.empty
    /// Targets still queued.
    private(set) var remaining = 0
    /// Targets that exhausted their retries THIS run — not cached (they'll be
    /// retried at the next launch/sync), so no false "no data" is recorded.
    private(set) var failedThisRun = 0
    private(set) var isWarming = false
    /// Targets queued since the current warm run began — the progress bar's
    /// denominator. Reset once the queue drains.
    private(set) var totalThisRun = 0
    private(set) var lastError: String?

    // Source: fetch concurrency 1, 1100ms between batches — ~4h for this
    // library's ~13k entities. 4-wide keeps Last.fm at ~3.6 req/s (under its
    // ~5/s ceiling) and Deezer at ~4/s (its limit is 50 per 5s), ~1h total.
    nonisolated private static let concurrency = 4
    nonisolated private static let batchDelay: Duration = .milliseconds(1100)
    nonisolated private static let maxRetries = 4
    nonisolated private static let persistEvery = 20
    /// How long the warm loop waits before rebuilding the tiers from every saved record. Rebuilding reads and ranks every record, which
    /// is cheap for a few thousand and costly for tens of thousands (a long history has records for every artist, album and track), so
    /// the wait grows with the record count: 15 s for small libraries, up to 5 minutes for very large ones.
    static func snapshotRefreshInterval(recordCount: Int) -> TimeInterval {
        min(300, max(15, Double(recordCount) / 400))
    }
    private var lastSnapshotRecordCount = 0

    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "Popularity")

    private var queue: [PopularityTarget] = []
    private var queued = Set<String>()
    private var dataStore: PopularityDataStore?
    private var warmTask: Task<Void, Never>?
    private var lastSnapshotAt = Date.distantPast
    private weak var work: BackgroundWorkStore?

    /// Loads whatever is already cached (so diamonds appear immediately on
    /// launch), then queues every library entity that is uncached or stale and
    /// starts warming. Safe to call repeatedly — at launch and after every sync.
    /// `warm: false` only loads what's already cached (no seeding, no network).
    func start(container: ModelContainer, work: BackgroundWorkStore, warm: Bool = true) async {
        self.work = work
        work.clearError(.popularity)
        let store = dataStore ?? PopularityDataStore(modelContainer: container)
        dataStore = store
        await reloadSnapshot()
        // Offline mode: show what's cached, queue nothing. Switching back online calls this again and re-seeds.
        guard warm, !ConnectivityGate.isOffline else { return }
        do {
            let staleBefore = Date().addingTimeInterval(-PopularityConstants.staleInterval)
            let seed = try await offMain { try await store.seedTargets(staleBefore: staleBefore) }
            let added = enqueue(seed.targets)
            Self.log.info("seeded: \(added) queued, \(seed.freshCount) fresh, \(seed.skippedWithoutArtist) skipped (no artist)")
            if seed.skippedWithoutArtist > 0 {
                Self.log.error("\(seed.skippedWithoutArtist) album/track rows have no artist and cannot get a popularity lookup")
            }
        } catch {
            fail("Couldn't seed popularity lookups: \(error)")
            return
        }
        startWarmingIfNeeded()
    }

    /// Re-fetches one artist/album/track now, ahead of the rest of the queue —
    /// the Resync action's popularity refresh. The previous value stays visible
    /// until the new one lands.
    func refresh(_ lookups: [PopularityLookup]) {
        guard dataStore != nil, !ConnectivityGate.isOffline else { return }
        for lookup in lookups.reversed() {
            let target = PopularityTarget(lookup: lookup)
            if queued.remove(target.key) != nil {
                queue.removeAll { $0.key == target.key }
            } else {
                totalThisRun += 1
            }
            queue.insert(target, at: 0)
            queued.insert(target.key)
        }
        remaining = queue.count
        work?.report(.popularity, remaining: remaining, total: totalThisRun, failed: failedThisRun)
        startWarmingIfNeeded()
    }

    // MARK: - Warmer

    @discardableResult
    private func enqueue(_ targets: [PopularityTarget]) -> Int {
        var added = 0
        for target in targets where queued.insert(target.key).inserted {
            queue.append(target)
            added += 1
        }
        totalThisRun += added
        remaining = queue.count
        if added > 0 { work?.report(.popularity, remaining: remaining, total: totalThisRun, failed: failedThisRun) }
        return added
    }

    private func startWarmingIfNeeded() {
        guard warmTask == nil, !queue.isEmpty, !ConnectivityGate.isOffline else { return }
        isWarming = true
        warmTask = Task { [weak self] in await self?.runWarmLoop() }
    }

    private func runWarmLoop() async {
        defer {
            warmTask = nil
            isWarming = false
            remaining = queue.count
            if queue.isEmpty {
                totalThisRun = 0
                work?.finish(.popularity, failed: failedThisRun)
            } else if ConnectivityGate.isOffline {
                // Paused by Offline mode: the rest stays queued (and is re-seeded when going online); nothing counts as failed.
                work?.finish(.popularity, failed: 0)
            }
            // Work enqueued while the loop was winding down.
            if !queue.isEmpty { startWarmingIfNeeded() }
        }
        guard let credentials = LastfmCredentialsStore.load() else {
            Self.log.notice("no Last.fm credentials — clearing \(self.queue.count) queued popularity lookups")
            queue.removeAll()
            queued.removeAll()
            return
        }
        guard let dataStore else { return }
        let lastfm = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        let deezer = DeezerAPIClient()
        failedThisRun = 0
        var unsaved: [(target: PopularityTarget, signals: PopularitySignals)] = []
        Self.log.info("warm loop started: \(self.queue.count) queued")

        while !queue.isEmpty, !Task.isCancelled, !ConnectivityGate.isOffline {
            let batch = Array(queue.prefix(Self.concurrency))
            queue.removeFirst(batch.count)
            for target in batch { queued.remove(target.key) }

            let results = await withTaskGroup(of: (PopularityTarget, Result<PopularitySignals, Error>).self) { group in
                for target in batch {
                    group.addTask { (target, await Self.resolve(target, lastfm: lastfm, deezer: deezer)) }
                }
                var collected: [(PopularityTarget, Result<PopularitySignals, Error>)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (target, result) in results {
                switch result {
                case .success(let signals):
                    unsaved.append((target, signals))
                case .failure(let error) where error is OfflineError:
                    // Switched to Offline mode mid-batch: put it back at the front, and don't call it a failure.
                    queue.insert(target, at: 0)
                    queued.insert(target.key)
                case .failure(let error):
                    failedThisRun += 1
                    Self.log.error("popularity lookup failed after retries for \(target.key, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            remaining = queue.count
            work?.report(.popularity, remaining: remaining, total: totalThisRun, failed: failedThisRun)

            if unsaved.count >= Self.persistEvery || queue.isEmpty {
                do {
                    let batch = unsaved
                    try await offMain { try await dataStore.save(batch) }
                    unsaved.removeAll()
                    if queue.isEmpty || Date().timeIntervalSince(lastSnapshotAt) >= Self.snapshotRefreshInterval(recordCount: lastSnapshotRecordCount) {
                        await reloadSnapshot()
                    }
                } catch {
                    fail("Couldn't save popularity data: \(error)")
                    return
                }
            }
            if !queue.isEmpty { try? await Task.sleep(for: Self.batchDelay) }
        }
        if !unsaved.isEmpty {
            let pending = unsaved
            try? await offMain { try await dataStore.save(pending) }
        }
        Self.log.info("warm loop finished: \(self.failedThisRun) failed this run")
    }

    private func reloadSnapshot() async {
        guard let dataStore else { return }
        do {
            let records = try await offMain { try await dataStore.loadRecords() }
            snapshot = await Task.detached(priority: .utility) { PopularitySnapshot(records: records) }.value
            lastSnapshotAt = Date()
            lastSnapshotRecordCount = records.count
        } catch {
            fail("Couldn't load popularity data: \(error)")
        }
    }

    private func fail(_ message: String) {
        lastError = message
        work?.fail(.popularity, message)
        Self.log.error("\(message, privacy: .public)")
    }

    // MARK: - Network

    nonisolated private static func resolve(
        _ target: PopularityTarget, lastfm: LastfmAPIClient, deezer: DeezerAPIClient
    ) async -> Result<PopularitySignals, Error> {
        var delay = 0.5
        for attempt in 0...maxRetries {
            do {
                return .success(try await fetchSignals(target, lastfm: lastfm, deezer: deezer))
            } catch {
                if error is OfflineError { return .failure(error) }
                if attempt == maxRetries || Task.isCancelled { return .failure(error) }
                try? await Task.sleep(for: .seconds(delay + Double.random(in: 0...0.25)))
                delay *= 2
            }
        }
        preconditionFailure("unreachable: the loop always returns on its last attempt")
    }

    /// Last.fm and Deezer queried together.
    /// A transient failure on EITHER throws, so a half-resolved entry is never
    /// cached as if the missing service simply had no data.
    nonisolated private static func fetchSignals(
        _ target: PopularityTarget, lastfm: LastfmAPIClient, deezer: DeezerAPIClient
    ) async throws -> PopularitySignals {
        let lookup = target.lookup
        switch lookup.kind {
        case .artist:
            async let stats = lastfm.fetchArtistPopularityStats(artist: lookup.artist)
            async let fans = deezer.fetchArtistFans(artist: lookup.artist)
            let (s, f) = try await (stats, fans)
            return PopularitySignals(lfmListeners: s?.listeners, lfmPlaycount: s?.playcount, deezerFans: f, deezerRank: nil)
        case .album:
            let album = lookup.queryAlbum ?? ""
            async let stats = lastfm.fetchAlbumPopularityStats(artist: lookup.artist, album: album)
            async let fans = deezer.fetchAlbumFans(artist: lookup.artist, album: album)
            let (s, f) = try await (stats, fans)
            return PopularitySignals(lfmListeners: s?.listeners, lfmPlaycount: s?.playcount, deezerFans: f, deezerRank: nil)
        case .track:
            let track = lookup.queryTrack ?? ""
            async let stats = lastfm.fetchTrackPopularityStats(artist: lookup.artist, track: track)
            async let rank = deezer.fetchTrackRank(artist: lookup.artist, track: track)
            let (s, r) = try await (stats, rank)
            return PopularitySignals(lfmListeners: s?.listeners, lfmPlaycount: s?.playcount, deezerFans: nil, deezerRank: r)
        }
    }
}
