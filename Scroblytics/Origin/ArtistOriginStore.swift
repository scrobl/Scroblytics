import Foundation
import Observation
import OSLog
import SwiftData

extension Notification.Name {
    /// Posted (at most every few seconds while the sweep runs, and when it ends) when looked-up origins were saved, so pages and queries can reload.
    static let artistOriginDidUpdate = Notification.Name("ArtistOriginDidUpdate")
}

/// The background sweep for where artists are from: looks up every artist once, most-played first, then keeps up with whatever a sync
/// adds. Same shape as `TagStore`: a rate-limited queue, answers cached in SwiftData, progress on the shared status strip, a failed
/// lookup retried at the next launch or sync instead of being recorded, Offline mode pausing it. MusicBrainz allows about one request a
/// second and every lookup is one or more requests, so it runs one at a time at the shared pace (`MusicBrainzGate`).
///
/// A Settings switch turns every origin lookup off. A Query's Resolve button and an artist page hand the artists they are waiting on to
/// `prioritize`, so they come first, through this same queue.
@MainActor
@Observable
final class ArtistOriginStore {
    static let shared = ArtistOriginStore()

    private(set) var remaining = 0
    /// Artists whose lookup failed even after retries THIS run: not recorded, asked again at the next launch or sync.
    private(set) var failedThisRun = 0
    private(set) var isWarming = false
    private(set) var totalThisRun = 0
    private(set) var lastError: String?
    /// How many artists have a saved answer (found, guessed or recorded as unknown).
    private(set) var knownCount = 0

    private static let enabledKey = "origin.autoLookup"
    @ObservationIgnored private let defaults: UserDefaults
    /// Whether the sweep (and every other automatic origin lookup) may run. On by default.
    private(set) var enabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Attempts per artist in one sweep (the shared pace already waits between them, and longer after a 503).
    nonisolated static let maxAttempts = 3
    /// This many failures in a row mean MusicBrainz isn't answering: the sweep stops and says so.
    nonisolated static let failureStreakLimit = 8
    nonisolated private static let persistEvery = 5
    private static let notifyInterval: TimeInterval = 15

    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "Origins")

    struct Target: Hashable, Sendable {
        let name: String
        /// The MusicBrainz artist the person picked, if any.
        let chosenMBID: String?
        var key: String { TextNormalization.artistIdentityKey(name) }
    }

    private var queue: [Target] = []
    private var queued = Set<String>()
    private var dataStore: ArtistOriginDataStore?
    private var container: ModelContainer?
    private var warmTask: Task<Void, Never>?
    private var lastNotifyAt = Date.distantPast
    private weak var work: BackgroundWorkStore?
    /// Where MusicBrainz comes from; a check swaps in a stand-in.
    var makeFetcher: @Sendable () -> OriginFetching = { MusicBrainzAPIClient() }

    // MARK: Start, seed, prioritize

    /// Queues every artist without a current answer and starts the sweep. Safe to call repeatedly: at launch and after every sync.
    /// `warm: false` does nothing at all (no network).
    func start(container: ModelContainer, work: BackgroundWorkStore, warm: Bool = true) async {
        self.work = work
        self.container = container
        work.clearError(.origins)
        let store = dataStore ?? ArtistOriginDataStore(modelContainer: container)
        dataStore = store
        refreshKnownCount()
        guard warm, enabled, !ConnectivityGate.isOffline else { return }
        do {
            let targets = try await Self.seedTargets(container: container)
            let added = enqueue(targets)
            Self.log.info("seeded: \(added) artists queued")
        } catch {
            fail("Couldn’t read your artists to look up where they are from: \(error)")
            return
        }
        startWarmingIfNeeded()
    }

    /// The artists (most played first) that have no answer yet, an old one, or a pick the person made since.
    nonisolated static func seedTargets(container: ModelContainer, now: Date = Date()) async throws -> [Target] {
        let snapshots = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
        let ranked = await Task.detached(priority: .utility) {
            ArtistMapScope.top(snapshots: snapshots, count: Int.max).entries.sorted { ($0.plays, $1.name) > ($1.plays, $0.name) }
        }.value
        let saved = try await offMain { try await ArtistOriginDataStore(modelContainer: container).allSnapshots() }
        var targets: [Target] = []
        var seen = Set<String>()
        for entry in ranked {
            let key = TextNormalization.artistIdentityKey(entry.name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if ArtistOriginResolver.needsLookup(entry: saved.entries[key], edit: saved.edits[key], now: now) {
                targets.append(Target(name: entry.name, chosenMBID: saved.edits[key]?.chosenMBID))
            }
        }
        return targets
    }

    /// Moves the artists someone is waiting on to the front (the Resolve button, an artist page). `force` asks again even if an answer is
    /// saved: used after the person picks a different MusicBrainz artist. Does nothing when lookups are off or Offline mode is on.
    func prioritize(_ artists: [String], force: Bool = false) async {
        guard enabled, !ConnectivityGate.isOffline, let dataStore else { return }
        guard let saved = try? await offMain({ try await dataStore.snapshots(for: artists) }) else { return }
        var front: [Target] = []
        var seen = Set<String>()
        for name in artists {
            let key = TextNormalization.artistIdentityKey(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let pair = saved[key]
            guard force || ArtistOriginResolver.needsLookup(entry: pair?.entry, edit: pair?.edit) else { continue }
            front.append(Target(name: name, chosenMBID: pair?.edit?.chosenMBID))
        }
        guard !front.isEmpty else { return }
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

    // MARK: Switch and forget

    /// The Settings switch. Off stops the sweep and empties the queue at once; on starts it again.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            guard let container, let work else { return }
            Task { await start(container: container, work: work) }
        } else {
            warmTask?.cancel()
            queue.removeAll()
            queued.removeAll()
            remaining = 0
            totalThisRun = 0
            work?.finish(.origins, failed: 0)
        }
    }

    /// Deletes every looked-up place (the person's own corrections stay) and, if lookups are on, asks again.
    func forget() async {
        warmTask?.cancel()
        queue.removeAll()
        queued.removeAll()
        remaining = 0
        totalThisRun = 0
        work?.finish(.origins, failed: 0)
        if let dataStore { try? await offMain { try await dataStore.forgetLookups() } }
        refreshKnownCount()
        NotificationCenter.default.post(name: .artistOriginDidUpdate, object: nil)
        if let container, let work, enabled { await start(container: container, work: work) }
    }

    /// One line for Settings.
    var statusText: String {
        if !enabled { return "Off. Nothing is looked up." }
        if let lastError { return lastError }
        if isWarming || remaining > 0 {
            let left = remaining.formatted()
            return ConnectivityGate.isOffline ? "Paused while Offline mode is on. \(left) artists left." : "Looking up where artists are from, most played first. \(left) left."
        }
        return knownCount == 0 ? "Nothing looked up yet." : "\(knownCount.formatted()) artists looked up. Up to date."
    }

    private func refreshKnownCount() {
        guard let container else { return }
        knownCount = (try? container.mainContext.fetchCount(FetchDescriptor<ArtistOriginEntry>())) ?? knownCount
    }

    // MARK: Warmer

    @discardableResult
    private func enqueue(_ targets: [Target]) -> Int {
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
        if !queue.isEmpty { work?.report(.origins, remaining: queue.count, total: totalThisRun, failed: failedThisRun) }
    }

    private func startWarmingIfNeeded() {
        guard warmTask == nil, !queue.isEmpty, enabled, !ConnectivityGate.isOffline else { return }
        isWarming = true
        warmTask = Task { [weak self] in await self?.runWarmLoop() }
    }

    private func runWarmLoop() async {
        defer {
            warmTask = nil
            isWarming = false
            remaining = queue.count
            refreshKnownCount()
            if queue.isEmpty {
                totalThisRun = 0
                work?.finish(.origins, failed: failedThisRun)
                NotificationCenter.default.post(name: .artistOriginDidUpdate, object: nil)
            } else if ConnectivityGate.isOffline || !enabled {
                // Paused by Offline mode or switched off: the rest stays queued (Offline) or is dropped (off); nothing counts as failed.
                work?.finish(.origins, failed: 0)
            }
            // Work enqueued while the loop was winding down.
            if !queue.isEmpty { startWarmingIfNeeded() }
        }
        guard let dataStore else { return }
        let fetcher = makeFetcher()
        failedThisRun = 0
        var streak = 0
        var unsaved: [(artist: String, outcome: ArtistOriginLookup.Outcome)] = []
        Self.log.info("sweep started: \(self.queue.count) queued")

        while !queue.isEmpty, !Task.isCancelled, !ConnectivityGate.isOffline, enabled {
            let target = queue.removeFirst()
            queued.remove(target.key)
            let result = await Self.resolve(target, fetcher: fetcher, areas: dataStore)
            switch result {
            case .success(let outcome):
                streak = 0
                unsaved.append((target.name, outcome))
            case .failure(let error) where error is OfflineError:
                // Switched to Offline mode mid-lookup: back to the front, and not a failure.
                queue.insert(target, at: 0)
                queued.insert(target.key)
            case .failure(let error):
                failedThisRun += 1
                streak += 1
                Self.log.error("origin lookup failed after retries: \(String(describing: error), privacy: .public)")
            }
            remaining = queue.count
            report()

            if unsaved.count >= Self.persistEvery || queue.isEmpty || streak >= Self.failureStreakLimit {
                if await save(unsaved, to: dataStore) { unsaved.removeAll() } else { return }
            }
            if streak >= Self.failureStreakLimit {
                fail("MusicBrainz isn’t answering. Artist origins will try again at the next launch or sync.")
                queue.removeAll()
                queued.removeAll()
                return
            }
        }
        if !unsaved.isEmpty { _ = await save(unsaved, to: dataStore) }
        Self.log.info("sweep finished: \(self.failedThisRun) failed this run")
    }

    private func save(_ batch: [(artist: String, outcome: ArtistOriginLookup.Outcome)], to dataStore: ArtistOriginDataStore) async -> Bool {
        guard !batch.isEmpty else { return true }
        do {
            try await offMain { try await dataStore.save(batch) }
            refreshKnownCount()
            if queue.isEmpty || Date().timeIntervalSince(lastNotifyAt) >= Self.notifyInterval {
                lastNotifyAt = Date()
                NotificationCenter.default.post(name: .artistOriginDidUpdate, object: nil)
            }
            return true
        } catch {
            fail("Couldn’t save where artists are from: \(error)")
            return false
        }
    }

    private func fail(_ message: String) {
        lastError = message
        work?.fail(.origins, message)
        Self.log.error("\(message, privacy: .public)")
    }

    // MARK: Network

    /// One artist with retries. "MusicBrainz has no such artist" is an answer (recorded); anything else that fails is retried, then
    /// reported, never recorded.
    nonisolated static func resolve(_ target: Target, fetcher: OriginFetching, areas: OriginAreaProviding) async -> Result<ArtistOriginLookup.Outcome, Error> {
        for attempt in 1...maxAttempts {
            do {
                return .success(try await ArtistOriginLookup.resolve(artist: target.name, chosenMBID: target.chosenMBID, fetcher: fetcher, areas: areas))
            } catch {
                if error is OfflineError || Task.isCancelled || attempt == maxAttempts { return .failure(error) }
            }
        }
        preconditionFailure("unreachable: the loop always returns on its last attempt")
    }
}
