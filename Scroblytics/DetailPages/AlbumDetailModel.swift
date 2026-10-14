import Foundation
import Observation
import SwiftData

/// One artist's plays, read off the main thread (turnover needs them all to group an album's variants).
@ModelActor
private actor AlbumScrobbleReader {
    func fetchArtistScrobbles(artist: String) throws -> [ScrobbleSnapshot] {
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate<Scrobble> { $0.artistName.localizedStandardContains(artist) },
            sortBy: [SortDescriptor(\.playedAt)]
        )
        return try modelContext.fetch(descriptor).filter { TextNormalization.artistIdentityKey($0.artistName) == artistKey }.map(\.snapshot)
    }
}

/// Where the album's listen-through (turnover) lookup stands.
enum AlbumTurnoverState {
    /// No Last.fm account, or the album can't be matched to a tracklist at all: no turnover tiles.
    case unavailable
    case loading
    case ready(AlbumTurnoverEngine.AlbumTurnover)
}

/// Everything the new Album page shows, and the loading of it. It calls the same engines the classic Album page calls, so both
/// pages agree; it is separate only so the classic page stays as it was.
@MainActor
@Observable
final class AlbumDetailModel {
    private(set) var identity = AlbumIdentity(artist: "", name: "")
    private var context: ModelContext?
    private var latestRangeID = ""
    /// Whether a Last.fm account is saved. A seam so a check can run without touching the Keychain.
    var hasCredentials: () -> Bool = { LastfmCredentialsStore.load() != nil }

    var oldestScrobbleDate: Date?
    var stats: EntityStats?
    var errorMessage: String?
    var yearlyTopRanks: [TopChartsEngine.YearlyRank] = []
    var communityTags: TagsLoadState = .loading
    var yourTags: TagsLoadState = .loading
    var timeListenedSeconds: Int?
    var isLoadingTimeListened = false
    var releaseDate: String?
    var isLoadingReleaseDate = false
    var turnoverState = AlbumTurnoverState.unavailable
    var currentGroup: AlbumGroup?

    func bind(identity: AlbumIdentity, context: ModelContext) {
        self.identity = identity
        self.context = context
        stats = nil
        errorMessage = nil
        yearlyTopRanks = []
        communityTags = .loading
        yourTags = .loading
        timeListenedSeconds = nil
        isLoadingTimeListened = false
        releaseDate = nil
        isLoadingReleaseDate = false
        currentGroup = nil
        // The tiles are there from the first frame when a lookup is on its way.
        turnoverState = hasCredentials() ? .loading : .unavailable
    }

    func makeClient() -> LastfmAPIClient? {
        guard let credentials = LastfmCredentialsStore.load() else { return nil }
        return LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
    }

    // MARK: - Loading

    func loadOldestScrobbleDate() {
        guard let context else { return }
        var descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        descriptor.fetchLimit = 1
        oldestScrobbleDate = (try? context.fetch(descriptor))?.first?.playedAt
    }

    func loadStats(range: DateRange, rangeID: String) async {
        guard let context else { return }
        let requested = identity
        latestRangeID = rangeID
        do {
            let loaded = try await EntityStatsEngine.fetchAlbumStats(container: context.container, artist: requested.artist, album: requested.name, range: range)
            guard !Task.isCancelled, identity.id == requested.id, latestRangeID == rangeID else { return }
            stats = loaded
        } catch {
            guard !Task.isCancelled, identity.id == requested.id else { return }
            errorMessage = "Failed to load stats: \(error)"
        }
    }

    /// Deezer needs no credentials, so this never skips.
    func loadTimeListened(range: DateRange) async {
        guard let context, !isLoadingTimeListened else { return }
        let requested = identity
        isLoadingTimeListened = true
        let seconds = await EntityStatsEngine.fetchAlbumTimeListened(
            context: context, client: DeezerAPIClient(), artist: requested.artist, album: requested.name, range: range
        )
        guard !Task.isCancelled, identity.id == requested.id else { return }
        timeListenedSeconds = seconds
        isLoadingTimeListened = false
    }

    func loadYearlyTopRanks() async {
        guard let context else { return }
        let requested = identity
        let ranks = (try? await TopChartsEngine.fetchYearlyTopRanks(container: context.container, entity: .album, name: requested.name, artist: requested.artist)) ?? []
        guard !Task.isCancelled, identity.id == requested.id else { return }
        yearlyTopRanks = ranks
    }

    func loadTags() async {
        guard let context else { return }
        let requested = identity
        guard let client = makeClient() else {
            guard identity.id == requested.id else { return }
            communityTags = .loaded(EntityTagsResult(tags: [], inherited: false))
            yourTags = .loaded(EntityTagsResult(tags: [], inherited: false))
            return
        }
        let community = await EntityTagsEngine.fetchCommunityTags(client: client, context: context, entity: .album, artist: requested.artist, album: requested.name)
        let personal = await EntityTagsEngine.fetchUserTags(client: client, context: context, entity: .album, artist: requested.artist, album: requested.name)
        guard !Task.isCancelled, identity.id == requested.id else { return }
        communityTags = .loaded(community)
        yourTags = .loaded(personal)
    }

    func tagsWereUpdated(_ tags: [String]) {
        yourTags = .loaded(EntityTagsResult(tags: tags, inherited: false))
    }

    /// Awaits resolution through the release-date engine's shared rate-limited queue.
    func loadReleaseDate() async {
        guard let context, !isLoadingReleaseDate else { return }
        let requested = identity
        isLoadingReleaseDate = true
        let date = await ReleaseDateEngine.resolveAlbumDateAwaiting(
            context: context, musicBrainz: MusicBrainzAPIClient(), deezer: DeezerAPIClient(), artist: requested.artist, album: requested.name
        )
        guard !Task.isCancelled, identity.id == requested.id else { return }
        releaseDate = date
        isLoadingReleaseDate = false
    }

    func releaseDateOverride() -> String? {
        guard let context else { return nil }
        return ReleaseDateEngine.albumRow(context: context, artist: identity.artist, album: identity.name)?.releaseDateOverride
    }

    /// Lazy, and last: it needs a Last.fm call on a tracklist-cache miss, and is skipped without an account. It resolves this one
    /// album from a group built just for it, not from a scan of the whole library.
    func loadTurnover() async {
        guard let context else { return }
        let requested = identity
        guard hasCredentials(), let client = makeClient() else {
            turnoverState = .unavailable
            return
        }
        turnoverState = .loading
        do {
            let artist = requested.artist
            let container = context.container
            let scrobbles = try await offMain { try await AlbumScrobbleReader(modelContainer: container).fetchArtistScrobbles(artist: artist) }
            guard !Task.isCancelled, identity.id == requested.id else { return }
            let groups = AlbumTurnoverEngine.buildAlbumGroups(from: scrobbles)
            let targetNorm = TextNormalization.normalizeAlbumName(requested.name)
            guard let group = groups.first(where: { $0.normalizedName == targetNorm || $0.variants.contains(requested.name) }) else {
                turnoverState = .unavailable
                return
            }
            let resolution = AlbumTurnoverEngine.storedResolution(context: context, group: group)
            let loaded = try await AlbumTurnoverEngine.resolveAlbumTurnover(context: context, group: group, resolution: resolution, client: client)
            guard !Task.isCancelled, identity.id == requested.id else { return }
            currentGroup = group
            turnoverState = .ready(loaded)
        } catch {
            // Turnover is an extra, not core page content: a failure just leaves the tiles out.
            guard identity.id == requested.id else { return }
            turnoverState = .unavailable
        }
    }

    // MARK: - Facts

    /// The page's own facts: when it came out, and the album's listen-through: how many tracks, how often it turns over, how many
    /// full cycles, how far through the current one.
    func facts(onEditReleaseDate: @escaping () -> Void, onFixAlbumMatch: @escaping () -> Void) -> [DetailFact] {
        let release: DetailFact.Value = isLoadingReleaseDate && releaseDate == nil ? .loading
            : (releaseDate.map { .text(ReleaseDateEngine.formatDate($0)) } ?? .unknown)
        let released = DetailFact(
            id: "released", label: "Released", value: release, corrected: releaseDate != nil && releaseDateOverride() != nil,
            systemImage: "calendar", onEdit: onEditReleaseDate
        )
        return [released] + Self.turnoverFacts(turnoverState, onFixAlbumMatch: onFixAlbumMatch)
    }

    static func turnoverFacts(_ state: AlbumTurnoverState, onFixAlbumMatch: @escaping () -> Void) -> [DetailFact] {
        switch state {
        case .unavailable:
            return []
        case .loading:
            return [
                DetailFact(id: "tracks", label: "Tracks", value: .loading, systemImage: "music.note.list"),
                DetailFact(id: "turnover", label: "Turnover", value: .loading, mayHaveDetail: true, systemImage: "repeat"),
                DetailFact(id: "cycles", label: "Full cycles", value: .loading, systemImage: "checkmark.circle"),
                DetailFact(id: "cycle", label: "This cycle", value: .loading, mayHaveDetail: true, systemImage: "circle.dashed"),
            ]
        case .ready(let turnover):
            // Not every album has a listen-through (a compilation, or one with no usable tracklist): then there is nothing to show.
            guard turnover.applicable else { return [] }
            var facts: [DetailFact] = []
            if turnover.basis == .canonical {
                facts.append(DetailFact(id: "tracks", label: "Tracks", value: .text(turnover.trackCount.formatted()), systemImage: "music.note.list"))
            }
            // The turnover rate is the number that depends on the album match, so this tile carries the way to fix it, always. An
            // uncertain or missing match also outlines the tile and swaps the pencil for a warning.
            let matchNote: String? = turnover.ambiguous ? "Uncertain match" : (turnover.noCanonicalMatch ? "No match found" : nil)
            var rate = DetailFact(
                id: "turnover", label: "Turnover", value: .text(AlbumTurnoverEngine.formatTurnoverRate(turnover.rateDays)),
                detail: matchNote, mayHaveDetail: true, systemImage: "repeat"
            )
            rate.onEdit = onFixAlbumMatch
            rate.editHelp = "Fix album match…"
            if matchNote != nil {
                rate.attention = true
                rate.editImage = "exclamationmark.triangle.fill"
            }
            facts.append(rate)
            facts.append(DetailFact(id: "cycles", label: "Full cycles", value: .text(turnover.cyclesCompleted.formatted()), systemImage: "checkmark.circle"))
            let fresh = turnover.inProgressHeard == 0 && turnover.cyclesCompleted > 0
            facts.append(DetailFact(
                id: "cycle", label: "This cycle", value: .text("\(turnover.inProgressHeard) of \(turnover.inProgressTotal)"),
                detail: fresh ? "New cycle just starting" : nil, mayHaveDetail: true, systemImage: "circle.dashed"
            ))
            return facts
        }
    }
}
