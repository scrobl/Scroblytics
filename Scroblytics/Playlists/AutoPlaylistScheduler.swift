import Foundation
import Observation
import SwiftData
import SwiftUI

extension Notification.Name {
    /// Posted after a round of refreshes, so a list of playlists can reload.
    static let autoPlaylistsDidRefresh = Notification.Name("AutoPlaylistsDidRefresh")
    /// Posted when the loved-tracks check that follows a sync has ended, whether it found anything, failed or was cut short. It is the end
    /// of a sync's work, so the automatic playlists (some of which depend on loved tracks) are refreshed on it.
    static let lovedTracksSyncDidFinish = Notification.Name("LovedTracksSyncDidFinish")
}

/// Refreshes the automatic playlists: after each sync, and when a person asks. One round at a time (a sync that finishes while a
/// round is running asks for one more round afterwards), nothing at all when there are no playlists, and nothing computed when Music
/// isn't open. The lists are run again with the same engines as the screens they came from; the work happens off the main actor.
@MainActor
@Observable
final class AutoPlaylistScheduler {
    static let shared = AutoPlaylistScheduler()

    typealias TrackProvider = @MainActor (AutoPlaylistRecipe) async throws -> [AppleMusicPlaylistTrack]

    private(set) var isRefreshing = false
    /// The Popularity store a Query's popularity fields read; set once by the app window.
    var popularity: PopularityStore?
    /// The status line under the toolbar, where a round of refreshes shows how many playlists are left; set once by the app window.
    var work: BackgroundWorkStore?
    private var rerunRequested = false
    /// What has changed since the last round started: the plays (a sync added or removed some) and the loved tracks.
    private var scrobblesChanged = false
    private var lovedChanged = false
    /// A value a list can be made from changed (popularity, tags, lengths, tempos, release dates, flags, edits…), apart from the plays.
    private var lookupsChanged = false
    /// A sync (or its loved-tracks check) is under way; a round for changed lookups waits for it, since the sync starts its own.
    var syncIsRunning = false
    /// How long the lookups stay quiet before a round for them starts: a first warm of a big library saves every few seconds for an hour.
    var lookupQuietPeriod: Duration = .seconds(120)
    private var quietTask: Task<Void, Never>?

    /// The kinds of stored data a list can depend on, besides the plays.
    static let lookupEntities: Set<String> = [
        "TrackDurationCacheEntry", "TrackBPMCacheEntry", "TrackReleaseDateCacheEntry", "PopularityCacheEntry", "EntityCommunityTagCacheEntry",
        "UserEntityTagCacheEntry", "FlaggedTrack", "LovedTrackEntry", "Track", "Album", "AlbumEditionMatch", "LibraryPresenceEntry",
    ]

    /// Whether a save of the database touched stored data a list can depend on.
    static func isRelevantSave(_ note: Notification) -> Bool {
        // The lists of changed records sit under the keys "inserted", "updated" and "deleted", which are plain strings in the notification:
        // looking them up with `ModelContext.NotificationKey` finds nothing.
        let names: Set<String> = ["inserted", "updated", "deleted"]
        return (note.userInfo ?? [:]).contains { key, value in
            guard let name = (key.base as? String) ?? (key.base as? ModelContext.NotificationKey)?.rawValue, names.contains(name) else { return false }
            return (value as? [PersistentIdentifier])?.contains { lookupEntities.contains($0.entityName) } ?? false
        }
    }

    /// Records that a sync changed the plays and/or the loved tracks, for the next round to take into account.
    func noteChanges(scrobbles: Bool = false, loved: Bool = false) {
        scrobblesChanged = scrobblesChanged || scrobbles
        lovedChanged = lovedChanged || loved
    }

    /// Stored data a list may depend on was saved. Once it has been quiet for a while, and no sync is running, the playlists whose lists
    /// changed are refreshed. Saves made by a round itself (a ranking by time listened saves the lengths it works out) don't count.
    func lookupsDidChange(container: ModelContainer, backend: PlaylistBackend = AppleMusicPlaylistBackend(), trackProvider: TrackProvider? = nil) {
        guard !isRefreshing else { return }
        guard ((try? container.mainContext.fetchCount(FetchDescriptor<AutoPlaylist>())) ?? 0) > 0 else { return }
        lookupsChanged = true
        quietTask?.cancel()
        let quiet = lookupQuietPeriod
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled, let self else { return }
            // A sync that is running ends with a round of its own, which takes these changes along.
            guard !self.syncIsRunning else { return }
            await self.refreshAll(container: container, reason: "after lookups", backend: backend, trackProvider: trackProvider)
        }
    }

    /// Whether a playlist's list could give a different answer than at its last refresh: the plays or the loved tracks changed, or a day
    /// has gone by (a list of the last 30 days, or of tracks first played in a window, moves on without any new plays), or the last
    /// refresh didn't go through (Music was closed) or never happened. Anything else would only find the same list and the same playlist.
    static func needsRefresh(
        _ list: AutoPlaylist, scrobblesChanged: Bool, lovedChanged: Bool, lookupsChanged: Bool = false, now: Date, calendar: Calendar = .current
    ) -> Bool {
        if scrobblesChanged || lovedChanged || lookupsChanged { return true }
        guard let last = list.lastRefreshAt else { return true }
        if list.status.isProblem || list.status == .neverRun { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    /// Refreshes the enabled playlists whose list could have changed (all of them when `everything`, as when a person asks).
    /// `trackProvider` replaces the real lists (for checks).
    func refreshAll(
        container: ModelContainer, reason: String, everything: Bool = false, now: Date = Date(),
        backend: PlaylistBackend = AppleMusicPlaylistBackend(), trackProvider: TrackProvider? = nil
    ) async {
        guard !isRefreshing else { rerunRequested = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            rerunRequested = false
            let (plays, loved, lookups) = (scrobblesChanged, lovedChanged, lookupsChanged)
            scrobblesChanged = false
            lovedChanged = false
            lookupsChanged = false
            let context = container.mainContext
            let enabled = (try? context.fetch(FetchDescriptor<AutoPlaylist>(sortBy: [SortDescriptor(\.createdAt)])))?.filter(\.isEnabled) ?? []
            let lists = everything ? enabled : enabled.filter { Self.needsRefresh($0, scrobblesChanged: plays, lovedChanged: loved, lookupsChanged: lookups, now: now) }
            guard !lists.isEmpty else { return }
            let provider = trackProvider ?? { [popularity] recipe in
                try await AutoPlaylistSources.tracks(for: recipe, container: container, popularity: popularity)
            }
            var tally = Tally()
            if !backend.isMusicRunning {
                for list in lists {
                    let outcome = AutoPlaylistOutcome(status: .musicNotRunning, playlistID: list.playlistPersistentID, cache: AutoPlaylistMatchCache.decode(list.matchCacheData))
                    list.record(outcome, at: now)
                    tally.add(outcome.status)
                }
            } else {
                defer { work?.finish(.playlists) }
                work?.report(.playlists, remaining: lists.count, total: lists.count)
                for (index, list) in lists.enumerated() {
                    if Task.isCancelled { break }
                    let outcome = await Self.run(list, provider: provider, backend: backend)
                    list.record(outcome, at: now)
                    tally.add(outcome.status)
                    work?.report(.playlists, remaining: lists.count - index - 1, total: lists.count)
                }
            }
            try? context.save()
            ActivityLog.record(.playlists, "Automatic playlists refreshed (\(reason)): \(tally.summary)")
            NotificationCenter.default.post(name: .autoPlaylistsDidRefresh, object: nil)
        } while rerunRequested && !Task.isCancelled
    }

    /// Refreshes one playlist now (a person pressed Refresh Now), whether or not it is switched on.
    func refresh(
        _ list: AutoPlaylist, container: ModelContainer, backend: PlaylistBackend = AppleMusicPlaylistBackend(), trackProvider: TrackProvider? = nil
    ) async {
        let provider = trackProvider ?? { [popularity] recipe in
            try await AutoPlaylistSources.tracks(for: recipe, container: container, popularity: popularity)
        }
        let outcome: AutoPlaylistOutcome
        if backend.isMusicRunning {
            work?.report(.playlists, remaining: 1, total: 1)
            defer { work?.finish(.playlists) }
            outcome = await Self.run(list, provider: provider, backend: backend)
        } else {
            outcome = AutoPlaylistOutcome(status: .musicNotRunning, playlistID: list.playlistPersistentID, cache: AutoPlaylistMatchCache.decode(list.matchCacheData))
        }
        list.record(outcome)
        try? container.mainContext.save()
        NotificationCenter.default.post(name: .autoPlaylistsDidRefresh, object: nil)
    }

    /// One playlist: run its list, then make the playlist match.
    private static func run(_ list: AutoPlaylist, provider: TrackProvider, backend: PlaylistBackend) async -> AutoPlaylistOutcome {
        let cache = AutoPlaylistMatchCache.decode(list.matchCacheData)
        func failed(_ message: String) -> AutoPlaylistOutcome {
            AutoPlaylistOutcome(status: .failed, playlistID: list.playlistPersistentID, cache: cache, message: message)
        }
        guard let recipe = AutoPlaylistRecipe(playlist: list) else { return failed(AutoPlaylistSources.SourceError.unreadableRecipe.localizedDescription) }
        let tracks: [AppleMusicPlaylistTrack]
        do { tracks = try await provider(recipe) } catch { return failed(error.localizedDescription) }
        let request = AutoPlaylistRequest(
            name: list.name, playlistID: list.playlistPersistentID.isEmpty ? nil : list.playlistPersistentID, tracks: tracks, cache: cache
        )
        return await AutoPlaylistRunner.shared.refresh(request, backend: backend)
    }

    /// How a round went, in words that carry no names.
    struct Tally {
        var updated = 0, upToDate = 0, attention = 0
        mutating func add(_ status: AutoPlaylistStatus) {
            switch status {
            case .created, .updated: updated += 1
            case .upToDate: upToDate += 1
            case .neverRun: break
            default: attention += 1
            }
        }
        var summary: String {
            var parts: [String] = []
            if updated > 0 { parts.append("\(updated) updated") }
            if upToDate > 0 { parts.append("\(upToDate) already up to date") }
            if attention > 0 { parts.append("\(attention) need attention") }
            return parts.isEmpty ? "nothing to do" : parts.joined(separator: ", ")
        }
    }
}

/// Makes a playlist for a list (or takes over one that is there) and saves it as an automatic playlist.
@MainActor
enum AutoPlaylistCreator {
    /// `takeOverID` is the persistent ID of an existing playlist whose contents are to be replaced; nil makes a new one. The list is
    /// saved only when the playlist was made or matched, so a failure leaves nothing behind that would try again by itself.
    static func create(
        name: String, recipe: AutoPlaylistRecipe, summary: String, tracks: [AppleMusicPlaylistTrack], takeOverID: String?,
        context: ModelContext, backend: PlaylistBackend = AppleMusicPlaylistBackend()
    ) async throws -> (list: AutoPlaylist?, outcome: AutoPlaylistOutcome) {
        let request = AutoPlaylistRequest(name: name, playlistID: takeOverID, tracks: tracks)
        let outcome = await AutoPlaylistRunner.shared.refresh(request, backend: backend)
        switch outcome.status {
        case .created, .updated, .upToDate:
            guard let playlistID = outcome.playlistID, !playlistID.isEmpty else { return (nil, outcome) }
            let list = AutoPlaylist(
                name: name, playlistPersistentID: playlistID, recipeKind: recipe.kind, recipeData: try recipe.encodedData(), sourceSummary: summary
            )
            list.record(outcome)
            context.insert(list)
            try context.save()
            ActivityLog.record(.playlists, "An automatic playlist was set up")
            NotificationCenter.default.post(name: .autoPlaylistsDidRefresh, object: nil)
            return (list, outcome)
        default:
            return (nil, outcome)
        }
    }
}

extension View {
    /// Refreshes the automatic playlists after each sync, once its loved-tracks check has ended too (a goal's playlist reads the loved
    /// tracks). One modifier so `ContentView`'s chain stays short.
    func autoPlaylistRuntime(container: ModelContainer, popularity: PopularityStore, work: BackgroundWorkStore) -> some View {
        onAppear {
            AutoPlaylistScheduler.shared.popularity = popularity
            AutoPlaylistScheduler.shared.work = work
        }
            .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
                // Posted only when the sync changed the plays.
                AutoPlaylistScheduler.shared.noteChanges(scrobbles: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidStart)) { _ in AutoPlaylistScheduler.shared.syncIsRunning = true }
            .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidStop)) { _ in AutoPlaylistScheduler.shared.syncIsRunning = false }
            .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidFail)) { _ in AutoPlaylistScheduler.shared.syncIsRunning = false }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { note in
                guard AutoPlaylistScheduler.isRelevantSave(note) else { return }
                AutoPlaylistScheduler.shared.lookupsDidChange(container: container)
            }
            .onReceive(NotificationCenter.default.publisher(for: .lovedTracksSyncDidFinish)) { note in
                AutoPlaylistScheduler.shared.syncIsRunning = false
                AutoPlaylistScheduler.shared.noteChanges(loved: (note.object as? Bool) ?? false)
                #if DEBUG
                TestProfile.log("AUTOPLAYLISTS refresh requested")
                #endif
                Task { await AutoPlaylistScheduler.shared.refreshAll(container: container, reason: "after a sync") }
            }
    }
}
