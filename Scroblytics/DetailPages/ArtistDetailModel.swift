import Foundation
import Observation
import SwiftData

/// Everything the Artist page shows, and the loading of it, through the same engines the rest of the app uses.
@MainActor
@Observable
final class ArtistDetailModel {
    private(set) var identity = ArtistIdentity(name: "")
    private var context: ModelContext?
    /// See `DetailLoadMemo`: the view skips its loads when it only reappears.
    @ObservationIgnored private(set) var loadMemo = DetailLoadMemo()

    func isLoaded(for id: String) -> Bool { loadMemo.isFresh(for: id) }
    func markLoaded(_ id: String) { loadMemo.record(id) }

    var oldestScrobbleDate: Date?
    var stats: EntityStats?
    var errorMessage: String?
    var yearlyTopRanks: [TopChartsEngine.YearlyRank] = []
    var communityTags: TagsLoadState = .loading
    var yourTags: TagsLoadState = .loading
    var timeListenedSeconds: Int?
    /// What weather this artist is played in more than usual (Settings › Weather); no tile unless there is something to say.
    var weatherLean = EntityWeatherLean.Result.unavailable

    func loadWeatherLean(range: DateRange) async {
        guard let context else { return }
        let requested = identity
        let result = await EntityWeatherLeanLoader.artist(container: context.container, name: requested.name, range: range)
        guard !Task.isCancelled, identity.id == requested.id else { return }
        weatherLean = result
    }

    func bind(identity: ArtistIdentity, context: ModelContext) {
        self.identity = identity
        self.context = context
        stats = nil
        errorMessage = nil
        yearlyTopRanks = []
        communityTags = .loading
        yourTags = .loading
        timeListenedSeconds = nil
        weatherLean = .unavailable
    }

    func loadOldestScrobbleDate() {
        guard let context else { return }
        var descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        descriptor.fetchLimit = 1
        oldestScrobbleDate = (try? context.fetch(descriptor))?.first?.playedAt
    }

    func loadStats(range: DateRange) {
        guard let context else { return }
        do {
            stats = try EntityStatsEngine.fetchArtistStats(context: context, artist: identity.name, range: range)
        } catch {
            errorMessage = "Failed to load stats: \(error)"
        }
    }

    func loadYearlyTopRanks() async {
        guard let context else { return }
        let requested = identity
        let ranks = (try? await TopChartsEngine.fetchYearlyTopRanks(container: context.container, entity: .artist, name: requested.name, artist: nil)) ?? []
        guard !Task.isCancelled, identity.id == requested.id else { return }
        yearlyTopRanks = ranks
    }

    /// Community tags need only the read key, and a person's own tags are public too, so both load whether or not Track Actions is
    /// connected. With no account at all both settle on empty rather than loading forever.
    func loadTags() async {
        guard let context else { return }
        let requested = identity
        guard let credentials = LastfmCredentialsStore.load() else {
            guard identity.id == requested.id else { return }
            communityTags = .loaded(EntityTagsResult(tags: [], inherited: false))
            yourTags = .loaded(EntityTagsResult(tags: [], inherited: false))
            return
        }
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        let community = await EntityTagsEngine.fetchCommunityTags(client: client, context: context, entity: .artist, artist: requested.name)
        let personal = await EntityTagsEngine.fetchUserTags(client: client, context: context, entity: .artist, artist: requested.name)
        guard !Task.isCancelled, identity.id == requested.id else { return }
        communityTags = .loaded(community)
        yourTags = .loaded(personal)
    }

    func tagsWereUpdated(_ tags: [String]) {
        yourTags = .loaded(EntityTagsResult(tags: tags, inherited: false))
    }

    /// Deezer needs no credentials, so this never skips.
    func loadTimeListened(range: DateRange) async {
        guard let context else { return }
        let requested = identity
        let seconds = await EntityStatsEngine.fetchArtistTimeListened(context: context, client: DeezerAPIClient(), artist: requested.name, range: range)
        guard !Task.isCancelled, identity.id == requested.id else { return }
        timeListenedSeconds = seconds
    }
}
