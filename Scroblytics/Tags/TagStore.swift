import Foundation
import Observation
import OSLog
import SwiftData

/// The background tag sweep: fills the tag caches for the whole library, once, then keeps up with
/// whatever a sync adds. Same shape as `PopularityStore` — a rate-limited queue, cached in SwiftData,
/// progress on the shared status strip, failures retried at the next launch/sync rather than cached.
///
/// Two jobs, in order:
/// 1. **Your personal tags** — one complete pull (`EntityTagsEngine.syncPersonalTags`), when it has
///    never been done or is over a month old. After that the detail pages and tag edits keep it current.
/// 2. **Community tags** for every artist, album and track without them. An entity Last.fm has no
///    tags for is recorded as such (never asked again); a transient failure is not.
///
/// The query tool's Resolve button hands its candidates to `prioritize`, so a query gets its answer
/// without waiting for the whole sweep — through this same queue, never a second fetch path.
@MainActor
@Observable
final class TagStore {
    private(set) var remaining = 0
    /// Lookups that exhausted their retries THIS run — not cached, retried next launch/sync.
    private(set) var failedThisRun = 0
    private(set) var isWarming = false
    private(set) var totalThisRun = 0
    private(set) var lastError: String?

    // One Last.fm call per target. 3-wide with 1.1s between batches is ~2.7 req/s — under Last.fm's
    // ~5/s ceiling even with the popularity warmer running beside it. About 13k targets → ~75 minutes
    // the first time; afterwards only what a sync adds.
    nonisolated private static let concurrency = 3
    nonisolated private static let batchDelay: Duration = .milliseconds(1100)
    nonisolated private static let maxRetries = 4
    nonisolated private static let persistEvery = 30
    private static let notifyInterval: TimeInterval = 15
    private static let personalRefreshInterval: TimeInterval = 30 * 24 * 60 * 60

    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "Tags")

    private var queue: [TagTarget] = []
    private var queued = Set<String>()
    private var dataStore: TagDataStore?
    private var container: ModelContainer?
    private var warmTask: Task<Void, Never>?
    private var needsPersonalSync = false
    private var lastNotifyAt = Date.distantPast
    private weak var work: BackgroundWorkStore?

    /// Seeds every library entity that has no cached tags and starts the sweep. Safe to call
    /// repeatedly — at launch and after every sync. `warm: false` does nothing at all (no network).
    func start(container: ModelContainer, work: BackgroundWorkStore, warm: Bool = true) async {
        self.work = work
        self.container = container
        work.clearError(.tags)
        let store = dataStore ?? TagDataStore(modelContainer: container)
        dataStore = store
        guard warm, !ConnectivityGate.isOffline, let credentials = LastfmCredentialsStore.load() else { return }

        if let syncedAt = EntityTagsEngine.personalTagsSyncedAt(context: container.mainContext, username: credentials.username) {
            needsPersonalSync = Date().timeIntervalSince(syncedAt) > Self.personalRefreshInterval
        } else {
            needsPersonalSync = true
        }
        do {
            let seed = try await offMain { try await TagDataStore(modelContainer: container).seedTargets() }
            let added = enqueue(seed.targets)
            Self.log.info("seeded: \(added) queued, \(seed.cachedCount) cached, \(seed.skippedWithoutArtist) skipped (no artist)")
        } catch {
            fail("Couldn't seed tag lookups: \(error)")
            return
        }
        startWarmingIfNeeded()
    }

    /// Moves what a query is waiting on to the front of the queue (and makes sure your personal tags
    /// get synced) — the Resolve button. Returns immediately; the sweep does the work and reports on
    /// the status strip.
    func prioritize(_ entities: [QueryEntityID]) async {
        guard !ConnectivityGate.isOffline, let dataStore, let container, let credentials = LastfmCredentialsStore.load() else { return }
        if EntityTagsEngine.personalTagsSyncedAt(context: container.mainContext, username: credentials.username) == nil {
            needsPersonalSync = true
        }
        let wanted = entities.map { entity -> TagTarget in
            switch entity.target {
            case .artist: TagTarget(kind: .artist, artist: entity.artist, name: nil)
            case .album: TagTarget(kind: .album, artist: entity.artist, name: entity.name)
            case .track: TagTarget(kind: .track, artist: entity.artist, name: entity.name)
            }
        }
        guard let missing = try? await offMain({ try await dataStore.uncached(wanted) }) else { return }
        var front: [TagTarget] = []
        var seenFront = Set<String>()
        for target in missing where seenFront.insert(target.key).inserted { front.append(target) }
        for target in front where queued.remove(target.key) != nil {
            queue.removeAll { $0.key == target.key }
        }
        totalThisRun += front.count
        queue.insert(contentsOf: front, at: 0)
        for target in front { queued.insert(target.key) }
        remaining = queue.count
        report()
        startWarmingIfNeeded()
    }

    // MARK: - Warmer

    @discardableResult
    private func enqueue(_ targets: [TagTarget]) -> Int {
        var added = 0
        for target in targets where queued.insert(target.key).inserted {
            queue.append(target)
            added += 1
        }
        totalThisRun += added
        remaining = queue.count
        if added > 0 { report() }
        return added
    }

    private func report() {
        // The personal sync counts as one unit of work so the strip shows the job while it runs.
        let pending = queue.count + (needsPersonalSync ? 1 : 0)
        if pending > 0 { work?.report(.tags, remaining: pending, total: totalThisRun + (needsPersonalSync ? 1 : 0), failed: failedThisRun) }
    }

    private func startWarmingIfNeeded() {
        guard warmTask == nil, !queue.isEmpty || needsPersonalSync, !ConnectivityGate.isOffline else { return }
        isWarming = true
        warmTask = Task { [weak self] in await self?.runWarmLoop() }
    }

    private func runWarmLoop() async {
        defer {
            warmTask = nil
            isWarming = false
            remaining = queue.count
            if queue.isEmpty && !needsPersonalSync {
                totalThisRun = 0
                work?.finish(.tags, failed: failedThisRun)
                NotificationCenter.default.post(name: EntityTagsEngine.progressNotification, object: nil)
            } else if ConnectivityGate.isOffline {
                // Paused by Offline mode: the rest stays queued (and is re-seeded when going online); nothing counts as failed.
                work?.finish(.tags, failed: 0)
            }
            // Work enqueued while the loop was winding down.
            if !queue.isEmpty || needsPersonalSync { startWarmingIfNeeded() }
        }
        guard let credentials = LastfmCredentialsStore.load() else {
            Self.log.notice("no Last.fm credentials — clearing \(self.queue.count) queued tag lookups")
            queue.removeAll()
            queued.removeAll()
            needsPersonalSync = false
            return
        }
        guard let dataStore, let container else { return }
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        failedThisRun = 0

        if needsPersonalSync {
            do {
                try await EntityTagsEngine.syncPersonalTags(client: client, context: container.mainContext)
                needsPersonalSync = false
                NotificationCenter.default.post(name: EntityTagsEngine.progressNotification, object: nil)
            } catch is OfflineError {
                // Switched to Offline mode: leave it flagged so going online syncs it.
                return
            } catch {
                // Leave it flagged so the next launch/sync tries again; the community sweep carries on.
                needsPersonalSync = false
                fail("Couldn’t sync your tags: \(describeSyncError(error))")
            }
            report()
        }

        var unsaved: [(target: TagTarget, tags: [String])] = []
        Self.log.info("warm loop started: \(self.queue.count) queued")

        while !queue.isEmpty, !Task.isCancelled, !ConnectivityGate.isOffline {
            let batch = Array(queue.prefix(Self.concurrency))
            queue.removeFirst(batch.count)
            for target in batch { queued.remove(target.key) }

            let results = await withTaskGroup(of: (TagTarget, Result<[String], Error>).self) { group in
                for target in batch {
                    group.addTask { (target, await Self.resolve(target, client: client)) }
                }
                var collected: [(TagTarget, Result<[String], Error>)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (target, result) in results {
                switch result {
                case .success(let tags):
                    unsaved.append((target, tags))
                case .failure(let error) where error is OfflineError:
                    // Switched to Offline mode mid-batch: put it back at the front, and don't call it a failure.
                    queue.insert(target, at: 0)
                    queued.insert(target.key)
                case .failure(let error):
                    failedThisRun += 1
                    Self.log.error("tag lookup failed after retries for \(target.key, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            remaining = queue.count
            report()

            if unsaved.count >= Self.persistEvery || queue.isEmpty {
                do {
                    let batch = unsaved
                    try await offMain { try await dataStore.save(batch) }
                    unsaved.removeAll()
                    if queue.isEmpty || Date().timeIntervalSince(lastNotifyAt) >= Self.notifyInterval {
                        lastNotifyAt = Date()
                        NotificationCenter.default.post(name: EntityTagsEngine.progressNotification, object: nil)
                    }
                } catch {
                    fail("Couldn't save tags: \(error)")
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

    private func fail(_ message: String) {
        lastError = message
        work?.fail(.tags, message)
        Self.log.error("\(message, privacy: .public)")
    }

    // MARK: - Network

    /// One lookup with retries. A Last.fm "not found" is a real answer (no tags of its own) and is
    /// returned as an empty list to be cached; anything else that fails is retried, then reported.
    nonisolated private static func resolve(_ target: TagTarget, client: LastfmAPIClient) async -> Result<[String], Error> {
        var delay = 0.5
        for attempt in 0...maxRetries {
            do {
                switch target.kind {
                case .artist: return .success(try await client.fetchArtistTopTags(artist: target.artist))
                case .album: return .success(try await client.fetchAlbumTopTags(artist: target.artist, album: target.name ?? ""))
                case .track: return .success(try await client.fetchTrackTopTags(artist: target.artist, track: target.name ?? ""))
                }
            } catch {
                if EntityTagsEngine.isGenuineMiss(error) { return .success([]) }
                if error is OfflineError { return .failure(error) }
                if attempt == maxRetries || Task.isCancelled { return .failure(error) }
                try? await Task.sleep(for: .seconds(delay + Double.random(in: 0...0.25)))
                delay *= 2
            }
        }
        preconditionFailure("unreachable: the loop always returns on its last attempt")
    }
}
