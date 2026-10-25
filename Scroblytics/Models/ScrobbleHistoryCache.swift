import Foundation
import SwiftData

/// Reads the whole listening history for the cache: all plays ascending, and a cheap "stamp" that changes when the history does.
@ModelActor
actor ScrobbleHistoryLoader {
    func load() throws -> (snapshots: [ScrobbleSnapshot], stamp: ScrobbleHistoryCache.Stamp) {
        let syncedAt = try modelContext.fetch(FetchDescriptor<SyncState>()).first?.lastSyncedAt
        let snapshots = try modelContext.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
        return (snapshots, ScrobbleHistoryCache.Stamp(count: snapshots.count, newest: snapshots.last?.playedAt, syncedAt: syncedAt))
    }

    func stamp() throws -> ScrobbleHistoryCache.Stamp {
        var newest = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt, order: .reverse)])
        newest.fetchLimit = 1
        return ScrobbleHistoryCache.Stamp(
            count: try modelContext.checkedCount(FetchDescriptor<Scrobble>()),
            newest: try modelContext.fetch(newest).first?.playedAt,
            syncedAt: try modelContext.fetch(FetchDescriptor<SyncState>()).first?.lastSyncedAt
        )
    }
}

/// The listening history, read once and shared. About forty places used to read every play themselves (each hydrating every row,
/// mapping it and, for most, merging artist spellings again), and each page kept its own copy: with a history of hundreds of
/// thousands of plays that was seconds of CPU per page and hundreds of megabytes. Here the plays are held once; arrays are values with
/// shared storage, so every page that asks gets the same buffer.
///
/// - Callers asking at the same moment share one load.
/// - Every request first compares a cheap stamp (row count and newest play) with the one the data was read under, and reads again if it
///   differs. The cache is also dropped when a sync announces progress or finishes, so a change that leaves the count alone can't stay stale.
actor ScrobbleHistoryCache {
    static let shared = ScrobbleHistoryCache()

    /// What the history looked like when it was read: how many plays, the newest one, and when the last sync finished. The sync time
    /// is what catches a sync that replaced plays (a track Last.fm corrected) without changing the count or the newest play.
    struct Stamp: Equatable, Sendable {
        var count: Int
        var newest: Date?
        var syncedAt: Date? = nil
    }

    typealias Loader = @Sendable (ModelContainer) async throws -> (snapshots: [ScrobbleSnapshot], stamp: Stamp)
    typealias StampReader = @Sendable (ModelContainer) async throws -> Stamp

    private let loader: Loader
    private let stampReader: StampReader
    private var generation = 0
    private var stamp: Stamp?
    private var sortedCache: [ScrobbleSnapshot]?
    private var canonicalCache: [ScrobbleSnapshot]?
    private var loading: Task<(snapshots: [ScrobbleSnapshot], stamp: Stamp), Error>?
    private var canonicalizing: Task<[ScrobbleSnapshot], Never>?

    init(
        loader: @escaping Loader = { try ScrobbleHistoryLoader(modelContainer: $0).load() },
        stampReader: @escaping StampReader = { try ScrobbleHistoryLoader(modelContainer: $0).stamp() }
    ) {
        self.loader = loader
        self.stampReader = stampReader
    }

    /// Every play, oldest first (what `ScrobbleSnapshotReader.fetchSortedSnapshots` returns).
    func snapshots(container: ModelContainer) async throws -> [ScrobbleSnapshot] {
        let current = try await stampReader(container)
        if let cached = sortedCache, stamp == current { return cached }
        if let loading {
            return try await loading.value.snapshots
        }
        let startedAt = generation
        let task = Task { try await loader(container) }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        // A sync that announced progress while this was reading has already dropped the cache; what was read may be older than that.
        if generation == startedAt {
            sortedCache = loaded.snapshots
            canonicalCache = nil
            stamp = loaded.stamp
        }
        return loaded.snapshots
    }

    /// The same plays with each artist in one spelling (`QueryIdentity.canonicalizingArtists`), worked out once and kept.
    func canonicalSnapshots(container: ModelContainer) async throws -> [ScrobbleSnapshot] {
        let sorted = try await snapshots(container: container)
        // `snapshots` has just checked the stamp, and a re-read clears this copy, so what is kept here belongs to `sorted`.
        if let canonicalCache { return canonicalCache }
        if let canonicalizing { return await canonicalizing.value }
        let startedAt = generation
        let task = Task.detached(priority: .userInitiated) { QueryIdentity.canonicalizingArtists(sorted) }
        canonicalizing = task
        let result = await task.value
        canonicalizing = nil
        if generation == startedAt { canonicalCache = result }
        return result
    }

    /// Forgets everything; the next request reads the history again.
    func invalidate() {
        generation += 1
        stamp = nil
        sortedCache = nil
        canonicalCache = nil
    }

    /// Drops the cache whenever the app announces that plays were added or changed.
    @MainActor
    static func observeHistoryChanges() {
        let names: [Notification.Name] = [
            .scrobbleSyncDidProgress, .scrobbleSyncDidComplete, .scrobbleSyncDidFinish, .targetedSyncDidFinish, .firstImportDidFinish,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { await ScrobbleHistoryCache.shared.invalidate() }
            }
        }
    }
}
