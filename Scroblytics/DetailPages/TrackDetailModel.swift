import Foundation
import Observation
import SwiftData

/// Everything the Track page shows, and the loading of it, through the same engines the rest of the app uses.
@MainActor
@Observable
final class TrackDetailModel {
    private(set) var identity = TrackIdentity(artist: "", name: "")
    private var context: ModelContext?
    /// See `DetailLoadMemo`: the view skips its loads when it only reappears.
    @ObservationIgnored private(set) var loadMemo = DetailLoadMemo()

    func isLoaded(for id: String) -> Bool { loadMemo.isFresh(for: id) }
    func markLoaded(_ id: String) { loadMemo.record(id) }

    var oldestScrobbleDate: Date?
    var stats: EntityStats?
    var errorMessage: String?
    var yearlyTopRanks: [TopChartsEngine.YearlyRank] = []
    var scrobbleHistory: [ScrobbleHistoryEntry] = []
    var communityTags: TagsLoadState = .loading
    var yourTags: TagsLoadState = .loading
    var resolvedDuration: Int?
    var overrideSeconds: Int?
    var isLoadingDuration = false
    var resolvedBPM: BPMEngine.Resolved?
    var overrideBPM: Double?
    var isLoadingBPM = false
    var releaseDate: String?
    var primaryAlbum: String?
    var isLoadingReleaseDate = false
    var isTogglingLoved = false
    var lovedError: String?

    /// Points the model at a track and clears what belonged to the previous one.
    func bind(identity: TrackIdentity, context: ModelContext) {
        self.identity = identity
        self.context = context
        stats = nil
        errorMessage = nil
        yearlyTopRanks = []
        scrobbleHistory = []
        communityTags = .loading
        yourTags = .loading
        resolvedDuration = nil
        overrideSeconds = nil
        isLoadingDuration = false
        resolvedBPM = nil
        overrideBPM = nil
        isLoadingBPM = false
        releaseDate = nil
        primaryAlbum = nil
        isLoadingReleaseDate = false
        lovedError = nil
    }

    // MARK: - Loading

    func loadOldestScrobbleDate() {
        guard let context else { return }
        var descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        descriptor.fetchLimit = 1
        oldestScrobbleDate = (try? context.fetch(descriptor))?.first?.playedAt
    }

    func loadStats(range: DateRange) {
        guard let context else { return }
        do {
            stats = try EntityStatsEngine.fetchTrackStats(context: context, artist: identity.artist, track: identity.name, range: range)
        } catch {
            errorMessage = "Failed to load stats: \(error)"
        }
    }

    func loadScrobbleHistory(range: DateRange) {
        guard let context else { return }
        scrobbleHistory = (try? EntityStatsEngine.fetchTrackScrobbleHistory(context: context, artist: identity.artist, track: identity.name, range: range)) ?? []
    }

    func loadYearlyTopRanks() async {
        guard let context else { return }
        let requested = identity
        let ranks = (try? await TopChartsEngine.fetchYearlyTopRanks(context: context, entity: .track, name: requested.name, artist: requested.artist)) ?? []
        guard !Task.isCancelled, identity.id == requested.id else { return }
        yearlyTopRanks = ranks
    }

    /// Community tags need only the read key, and a person's own tags are public too, so both load whether or not Track Actions is
    /// connected.
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
        let community = await EntityTagsEngine.fetchCommunityTags(client: client, context: context, entity: .track, artist: requested.artist, track: requested.name)
        let personal = await EntityTagsEngine.fetchUserTags(client: client, context: context, entity: .track, artist: requested.artist, track: requested.name)
        guard !Task.isCancelled, identity.id == requested.id else { return }
        communityTags = .loaded(community)
        yourTags = .loaded(personal)
    }

    func tagsWereUpdated(_ tags: [String]) {
        yourTags = .loaded(EntityTagsResult(tags: tags, inherited: false))
    }

    func loadDuration() async {
        guard let context else { return }
        let requested = identity
        isLoadingDuration = true
        let key = DurationEngine.cacheKey(artist: requested.artist, track: requested.name)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.identityKey == key })
        descriptor.fetchLimit = 1
        let loadedOverride = (try? context.fetch(descriptor).first)?.durationOverrideSeconds
        let snapshot = ScrobbleSnapshot(
            artistName: requested.artist, albumName: requested.album ?? "", trackName: requested.name,
            imageURL: requested.imageURL, playedAt: .distantPast
        )
        let lookup = await DurationEngine.resolveDurationLookup(context: context, client: DeezerAPIClient(), scrobbles: [snapshot])
        guard !Task.isCancelled, identity.id == requested.id else { return }
        overrideSeconds = loadedOverride
        resolvedDuration = lookup[key]
        isLoadingDuration = false
    }

    /// Reads the saved tempo (a correction, else the cached lookup) and, when there is none yet, queues the lookup; the result
    /// arrives through `BPMEngine.progressNotification`.
    func loadBPM() {
        guard let context else { return }
        let requested = identity
        let key = BPMEngine.cacheKey(artist: requested.artist, track: requested.name)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.identityKey == key })
        descriptor.fetchLimit = 1
        overrideBPM = (try? context.fetch(descriptor).first)?.bpmOverride
        var state = BPMEngine.resolution(context: context, key: key)
        if state == .pending {
            let snapshot = ScrobbleSnapshot(
                artistName: requested.artist, albumName: requested.album ?? "", trackName: requested.name,
                imageURL: requested.imageURL, playedAt: .distantPast
            )
            _ = BPMEngine.resolveBPMLookup(context: context, scrobbles: [snapshot])
            state = BPMEngine.resolution(context: context, key: key)
        }
        resolvedBPM = state.resolved
        isLoadingBPM = state == .pending && !ConnectivityGate.isOffline
    }

    /// A track's release date is, nearly always, its own most-scrobbled ("primary") album's resolved date, so that album is found
    /// first from this track's own plays (the engine's own precedence: track correction, then the primary album's date, and a
    /// direct per-track lookup only when there is no album).
    func loadReleaseDate() async {
        guard let context else { return }
        let requested = identity
        isLoadingReleaseDate = true
        let artist = requested.artist
        let track = requested.name
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate<Scrobble> { $0.artistName.localizedStandardContains(artist) && $0.trackName == track }
        )
        let scrobbles = (try? context.fetch(descriptor).filter { TextNormalization.artistIdentityKey($0.artistName) == artistKey }.map(\.snapshot)) ?? []
        let album = ReleaseDateEngine.primaryAlbum(scrobbles: scrobbles)
        let date = await ReleaseDateEngine.resolveTrackDateAwaiting(
            context: context, musicBrainz: MusicBrainzAPIClient(), deezer: DeezerAPIClient(),
            artist: artist, track: track, primaryAlbum: album
        )
        guard !Task.isCancelled, identity.id == requested.id else { return }
        primaryAlbum = album
        releaseDate = date
        isLoadingReleaseDate = false
    }

    func releaseDateOverride() -> String? {
        guard let context else { return nil }
        let key = TextNormalization.lovedKey(artist: identity.artist, track: identity.name)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.identityKey == key })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.releaseDateOverride
    }

    /// A real write to the person's Last.fm account, so a failure is shown rather than swallowed.
    func toggleLoved(range: DateRange) async {
        guard let context, let stats, !isTogglingLoved else { return }
        isTogglingLoved = true
        lovedError = nil
        do {
            try await LovedTracksEngine.toggle(context: context, artist: identity.artist, track: identity.name, loved: stats.loved)
            loadStats(range: range)
        } catch {
            lovedError = "Failed to update loved status: \(describeSyncError(error))"
        }
        isTogglingLoved = false
    }

    // MARK: - Facts

    /// The page's own facts: when it came out, how long it is, how fast it goes.
    func facts(onEditReleaseDate: @escaping () -> Void, onEditDuration: @escaping () -> Void, onEditTempo: @escaping () -> Void) -> [DetailFact] {
        let release: DetailFact.Value = isLoadingReleaseDate && releaseDate == nil ? .loading
            : (releaseDate.map { .text(ReleaseDateEngine.formatDate($0)) } ?? .unknown)
        let length: DetailFact.Value = isLoadingDuration && resolvedDuration == nil ? .loading
            : (resolvedDuration.map { .text(DurationEngine.formatDuration($0)) } ?? .unknown)
        let tempo: DetailFact.Value = isLoadingBPM && resolvedBPM == nil ? .loading
            : (resolvedBPM.map { .text("\(BPMEngine.format($0.bpm)) BPM") } ?? .unknown)
        let tempoDetail = [resolvedBPM?.timeSignature, resolvedBPM?.musicalKey].compactMap { $0 }.joined(separator: " · ")
        return [
            DetailFact(
                id: "released", label: "Released", value: release, corrected: releaseDate != nil && releaseDateOverride() != nil,
                systemImage: "calendar", onEdit: onEditReleaseDate
            ),
            DetailFact(
                id: "length", label: "Length", value: length, corrected: resolvedDuration != nil && overrideSeconds != nil,
                systemImage: "clock", onEdit: onEditDuration
            ),
            DetailFact(
                id: "tempo", label: "Tempo", value: tempo, detail: tempoDetail.isEmpty ? nil : tempoDetail, mayHaveDetail: true,
                corrected: resolvedBPM != nil && overrideBPM != nil, systemImage: "metronome",
                help: resolvedBPM.map { "From \($0.source.label)" }, onEdit: onEditTempo
            ),
        ]
    }
}
