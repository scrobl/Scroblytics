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
    private var rerunRequested = false

    /// Refreshes every enabled playlist. `trackProvider` replaces the real lists (for checks).
    func refreshAll(
        container: ModelContainer, reason: String, backend: PlaylistBackend = AppleMusicPlaylistBackend(), trackProvider: TrackProvider? = nil
    ) async {
        guard !isRefreshing else { rerunRequested = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            rerunRequested = false
            let context = container.mainContext
            let lists = (try? context.fetch(FetchDescriptor<AutoPlaylist>(sortBy: [SortDescriptor(\.createdAt)])))?.filter(\.isEnabled) ?? []
            guard !lists.isEmpty else { return }
            let provider = trackProvider ?? { [popularity] recipe in
                try await AutoPlaylistSources.tracks(for: recipe, container: container, popularity: popularity)
            }
            var tally = Tally()
            if !backend.isMusicRunning {
                for list in lists {
                    let outcome = AutoPlaylistOutcome(status: .musicNotRunning, playlistID: list.playlistPersistentID, cache: AutoPlaylistMatchCache.decode(list.matchCacheData))
                    list.record(outcome)
                    tally.add(outcome.status)
                }
            } else {
                for list in lists {
                    if Task.isCancelled { break }
                    let outcome = await Self.run(list, provider: provider, backend: backend)
                    list.record(outcome)
                    tally.add(outcome.status)
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
    func autoPlaylistRuntime(container: ModelContainer, popularity: PopularityStore) -> some View {
        onAppear { AutoPlaylistScheduler.shared.popularity = popularity }
            .onReceive(NotificationCenter.default.publisher(for: .lovedTracksSyncDidFinish)) { _ in
                #if DEBUG
                TestProfile.log("AUTOPLAYLISTS refresh requested")
                #endif
                Task { await AutoPlaylistScheduler.shared.refreshAll(container: container, reason: "after a sync") }
            }
    }
}
