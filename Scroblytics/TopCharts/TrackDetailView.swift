import SwiftUI
import SwiftData

/// Track detail page — header, then the flat scrobble-history list
/// (Phase 6). A track is a leaf in the drill chain — nothing to drill into
/// further, and this is the ONLY place raw individual play events are
/// shown anywhere in the app, matching the user's confirmed decision that
/// scrobble history is track-level only. Reached from Top Charts today;
/// Overview drill-down is a separate follow-up.
struct TrackDetailView: View {
    let identity: TrackIdentity
    let settings: ChartDateSettings
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @State private var oldestScrobbleDate: Date?

    private var rangeOptions: [DateRangeOption] {
        DateRangePresets.build(oldestScrobbleDate: oldestScrobbleDate)
    }
    private var range: DateRange {
        (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).range()
    }
    private var compareRange: DateRange? { settings.resolveCompareRange(for: range) }
    private var metric: TopChartsMetric { settings.metric }
    @State private var stats: EntityStats?
    @State private var errorMessage: String?
    @State private var yearlyTopRanks: [TopChartsEngine.YearlyRank] = []
    @State private var scrobbleHistory: [ScrobbleHistoryEntry] = []
    @State private var communityTags: TagsLoadState = .loading
    @State private var yourTags: TagsLoadState = .loading
    @State private var resolvedDuration: Int?
    @State private var overrideSeconds: Int?
    @State private var isLoadingDuration = false
    @State private var showingDurationEdit = false
    @State private var resolvedBPM: BPMEngine.Resolved?
    @State private var overrideBPM: Double?
    @State private var isLoadingBPM = false
    @State private var showingBPMEdit = false
    @State private var isTogglingLoved = false
    @State private var lovedError: String?
    @State private var releaseDate: String?
    @State private var primaryAlbum: String?
    @State private var isLoadingReleaseDate = false
    @State private var showingReleaseDateEdit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailBreadcrumbBar(
                    navigation: navigation,
                    artist: ArtistIdentity(name: identity.artist),
                    album: identity.album.map { AlbumIdentity(artist: identity.artist, name: $0) },
                    current: identity.name
                )

                ChartFilterBarSection(settings: settings, rangeOptions: rangeOptions, currentRange: range)

                EntityStatsHeaderSection(
                    entity: .track, name: identity.name, subtitle: identity.artist, tertiary: identity.album,
                    imageURL: identity.imageURL, stats: stats, errorMessage: errorMessage, metric: metric,
                    // Derived directly from the single-track duration this
                    // page already resolves for `durationRow` × play count —
                    // no separate `EntityStatsEngine.fetchTrackTimeListened`
                    // call needed (that path is for Artist/Album, which span
                    // many distinct tracks and have no single duration to
                    // multiply).
                    timeListenedSeconds: resolvedDuration.map { $0 * (stats?.plays ?? 0) },
                    yearlyTopRanks: yearlyTopRanks,
                    onToggleLoved: { Task { await toggleLoved() } },
                    isTogglingLoved: isTogglingLoved
                )

                if let lovedError {
                    Text(lovedError).font(AppTypography.compactMetadata).foregroundStyle(.red)
                }

                durationRow
                bpmRow
                releaseDateRow

                EntityTagsSectionView(
                    communityTags: communityTags, yourTags: yourTags, entity: .track,
                    artist: identity.artist, album: identity.album, track: identity.name,
                    modelContext: modelContext,
                    onTagsUpdated: { tags in yourTags = .loaded(EntityTagsResult(tags: tags, inherited: false)) }
                )

                if !scrobbleHistory.isEmpty {
                    scrobbleHistorySection
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .navigationTitle(identity.name)
        .task(id: identity.id) {
            resetIdentityState()
            loadOldestScrobbleDate()
            loadStats()
            loadScrobbleHistory()
        }
        .onChange(of: settings.selectedRangeId) { reloadFilteredContent() }
        .onChange(of: settings.compareMode) { reloadFilteredContent() }
        .onChange(of: settings.compareCustomDate) { reloadFilteredContent() }
        .onChange(of: settings.metric) { reloadFilteredContent() }
        .task(id: "yearly|\(identity.id)") { await loadYearlyTopRanks() }
        .task(id: "tags|\(identity.id)") { await loadTags() }
        .task(id: "duration|\(identity.id)") { await loadDuration() }
        .task(id: "bpm|\(identity.id)") { loadBPM() }
        .onReceive(NotificationCenter.default.publisher(for: BPMEngine.progressNotification)) { _ in loadBPM() }
        .sheet(isPresented: $showingBPMEdit) {
            TrackBPMEditView(
                artist: identity.artist, track: identity.name,
                detected: overrideBPM == nil ? resolvedBPM : nil, currentOverride: overrideBPM,
                modelContext: modelContext, onSaved: { loadBPM() }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task { await refreshAfterSync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            Task { await loadDuration() }
        }
        .sheet(isPresented: $showingDurationEdit) {
            TrackDurationEditView(
                artist: identity.artist, track: identity.name, album: primaryAlbum ?? identity.album,
                detectedSeconds: overrideSeconds == nil ? resolvedDuration : nil,
                currentOverrideSeconds: overrideSeconds, modelContext: modelContext,
                onSaved: { Task { await loadDuration() } }
            )
        }
        .task(id: "release|\(identity.id)") { await loadReleaseDate() }
        .onReceive(NotificationCenter.default.publisher(for: ReleaseDateEngine.progressNotification)) { _ in
            Task { await loadReleaseDate() }
        }
        .sheet(isPresented: $showingReleaseDateEdit) {
            ReleaseDateEditView(
                target: .track(artist: identity.artist, track: identity.name),
                detectedDate: currentReleaseDateOverride() == nil ? releaseDate : nil,
                currentOverride: currentReleaseDateOverride(),
                modelContext: modelContext,
                onSaved: { Task { await loadReleaseDate() } }
            )
        }
    }

    @ViewBuilder
    private var durationRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(AppTypography.supporting).foregroundStyle(.secondary)
            if isLoadingDuration, resolvedDuration == nil {
                Text("Checking duration…").font(AppTypography.metadata).foregroundStyle(.secondary)
            } else if let resolvedDuration {
                Text("Duration: \(DurationEngine.formatDuration(resolvedDuration))")
                    .font(AppTypography.metadata)
                if overrideSeconds != nil {
                    Text("(corrected)").font(AppTypography.supportingDense).foregroundStyle(.secondary)
                }
            } else {
                Text("Duration unknown").font(AppTypography.metadata).foregroundStyle(.secondary)
            }
            Button {
                showingDurationEdit = true
            } label: {
                Image(systemName: "pencil.circle")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var bpmRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "metronome").font(AppTypography.supporting).foregroundStyle(.secondary)
            if isLoadingBPM, resolvedBPM == nil {
                Text("Checking tempo…").font(AppTypography.metadata).foregroundStyle(.secondary)
            } else if let resolvedBPM {
                Text("Tempo: \(BPMEngine.format(resolvedBPM.bpm)) BPM")
                    .font(AppTypography.metadata)
                    .help("From \(resolvedBPM.source.label)")
                if overrideBPM != nil {
                    Text("(corrected)").font(AppTypography.supportingDense).foregroundStyle(.secondary)
                }
                let details = [resolvedBPM.timeSignature, resolvedBPM.musicalKey].compactMap { $0 }
                if !details.isEmpty {
                    Text("· " + details.joined(separator: " · ")).font(AppTypography.supportingDense).foregroundStyle(.secondary)
                }
            } else {
                Text("Tempo unknown").font(AppTypography.metadata).foregroundStyle(.secondary)
            }
            Button {
                showingBPMEdit = true
            } label: {
                Image(systemName: "pencil.circle")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var releaseDateRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").font(AppTypography.supporting).foregroundStyle(.secondary)
            if isLoadingReleaseDate, releaseDate == nil {
                Text("Checking release date…").font(AppTypography.metadata).foregroundStyle(.secondary)
            } else if let releaseDate {
                Text("Released: \(ReleaseDateEngine.formatDate(releaseDate))").font(AppTypography.metadata)
                if currentReleaseDateOverride() != nil {
                    Text("(corrected)").font(AppTypography.supportingDense).foregroundStyle(.secondary)
                }
            } else {
                Text("Release date unknown").font(AppTypography.metadata).foregroundStyle(.secondary)
            }
            Button {
                showingReleaseDateEdit = true
            } label: {
                Image(systemName: "pencil.circle")
            }
            .buttonStyle(.plain)
        }
    }

    private func currentReleaseDateOverride() -> String? {
        let key = TextNormalization.lovedKey(artist: identity.artist, track: identity.name)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.identityKey == key })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).first)?.releaseDateOverride
    }

    /// A track's release date is, in the vast majority of cases, its own
    /// most-scrobbled ("primary") album's resolved date — so the primary
    /// album is computed first, from this track's own scrobble history,
    /// before resolution (mirrors `ReleaseDateEngine`'s own precedence:
    /// track override, then primary album's own override-aware date, and
    /// only a direct per-track Deezer lookup when no primary album exists
    /// at all). MusicBrainz needs no credentials (public API) — unlike
    /// `loadTags`, this never skips.
    private func loadReleaseDate() async {
        let requestedIdentity = identity
        isLoadingReleaseDate = true
        let artist = requestedIdentity.artist
        let track = requestedIdentity.name
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate<Scrobble> { $0.artistName.localizedStandardContains(artist) && $0.trackName == track }
        )
        let scrobbles = (try? modelContext.fetch(descriptor).filter { TextNormalization.artistIdentityKey($0.artistName) == artistKey }.map(\.snapshot)) ?? []
        let loadedPrimaryAlbum = ReleaseDateEngine.primaryAlbum(scrobbles: scrobbles)
        let loadedDate = await ReleaseDateEngine.resolveTrackDateAwaiting(
            context: modelContext, musicBrainz: MusicBrainzAPIClient(), deezer: DeezerAPIClient(),
            artist: artist, track: track, primaryAlbum: loadedPrimaryAlbum
        )
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        primaryAlbum = loadedPrimaryAlbum
        releaseDate = loadedDate
        isLoadingReleaseDate = false
    }

    private var scrobbleHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(scrobbleHistory.count.formatted()) plays").font(AppTypography.sectionTitle)
            VStack(spacing: 0) {
                ForEach(scrobbleHistory) { entry in
                    scrobbleRow(entry)
                    if entry.id != scrobbleHistory.last?.id { Divider() }
                }
            }
        }
    }

    /// A scrobble row: clock icon, date (plus
    /// the album that play happened under, if any — a track's history can
    /// span several albums), and the time of day trailing.
    private func scrobbleRow(_ entry: ScrobbleHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock").font(AppTypography.supporting).foregroundStyle(.tertiary)
            Text(entry.playedAt.formatted(date: .abbreviated, time: .omitted) + (entry.album.map { " · \($0)" } ?? ""))
                .lineLimit(1)
            Spacer()
            Text(entry.playedAt.formatted(date: .omitted, time: .shortened))
                .font(AppTypography.metadata).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 6)
    }

    private func refreshAfterSync() async {
        loadOldestScrobbleDate()
        loadStats()
        loadScrobbleHistory()
        await loadYearlyTopRanks()
        await loadReleaseDate()
    }

    private func resetIdentityState() {
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

    private func reloadFilteredContent() {
        loadStats()
        loadScrobbleHistory()
    }

    private func loadOldestScrobbleDate() {
        var descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        descriptor.fetchLimit = 1
        oldestScrobbleDate = (try? modelContext.fetch(descriptor))?.first?.playedAt
    }

    private func loadStats() {
        do {
            stats = try EntityStatsEngine.fetchTrackStats(context: modelContext, artist: identity.artist, track: identity.name, range: range)
        } catch {
            errorMessage = "Failed to load stats: \(error)"
        }
    }

    /// Real, consequential write against the real account — surfaces a
    /// visible error rather than failing silently (e.g. not connected, or a
    /// transient Last.fm error), unlike the read-only loads elsewhere on
    /// this page. Re-runs `loadStats()` on success rather than patching
    /// `stats.loved` locally, since that's already a cheap, all-local read
    /// once `LovedTracksEngine.toggle` has patched the synced set.
    private func toggleLoved() async {
        guard let stats, !isTogglingLoved else { return }
        isTogglingLoved = true
        lovedError = nil
        do {
            try await LovedTracksEngine.toggle(context: modelContext, artist: identity.artist, track: identity.name, loved: stats.loved)
            loadStats()
        } catch {
            lovedError = "Failed to update loved status: \(describeSyncError(error))"
        }
        isTogglingLoved = false
    }

    private func loadYearlyTopRanks() async {
        let requestedIdentity = identity
        let ranks = (try? await TopChartsEngine.fetchYearlyTopRanks(
            context: modelContext, entity: .track,
            name: requestedIdentity.name, artist: requestedIdentity.artist
        )) ?? []
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        yearlyTopRanks = ranks
    }

    private func loadScrobbleHistory() {
        scrobbleHistory = (try? EntityStatsEngine.fetchTrackScrobbleHistory(context: modelContext, artist: identity.artist, track: identity.name, range: range)) ?? []
    }

    /// Community tags need only the read API key; personal tags are also
    /// readable without write auth (Last.fm tags are public) — so both load
    /// regardless of whether Track Actions is connected, matching the
    /// approved Display-only scope. No album param: `track.getTopTags`/
    /// `track.getTags` are scoped to (artist, track) only, matching the same
    /// Last.fm limitation the PRD calls out for tag writes.
    private func loadTags() async {
        let requestedIdentity = identity
        guard let credentials = LastfmCredentialsStore.load() else {
            guard identity.id == requestedIdentity.id else { return }
            communityTags = .loaded(EntityTagsResult(tags: [], inherited: false))
            yourTags = .loaded(EntityTagsResult(tags: [], inherited: false))
            return
        }
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        let loadedCommunityTags = await EntityTagsEngine.fetchCommunityTags(
            client: client, context: modelContext, entity: .track,
            artist: requestedIdentity.artist, track: requestedIdentity.name
        )
        let loadedPersonalTags = await EntityTagsEngine.fetchUserTags(
            client: client, context: modelContext, entity: .track,
            artist: requestedIdentity.artist, track: requestedIdentity.name
        )
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        communityTags = .loaded(loadedCommunityTags)
        yourTags = .loaded(loadedPersonalTags)
    }

    /// Deezer needs no credentials (public API) — unlike `loadTags`, this
    /// never skips. Loads the override directly (for the "(corrected)" label
    /// and the edit sheet's current-value prefill) alongside the full
    /// override-aware resolution (for the displayed duration itself).
    /// Reads the saved tempo (a correction, else the cached lookup) and, when there is none yet, queues the lookup;
    /// the result arrives through `BPMEngine.progressNotification`.
    private func loadBPM() {
        let requested = identity
        let key = BPMEngine.cacheKey(artist: requested.artist, track: requested.name)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.identityKey == key })
        descriptor.fetchLimit = 1
        overrideBPM = (try? modelContext.fetch(descriptor).first)?.bpmOverride
        var state = BPMEngine.resolution(context: modelContext, key: key)
        if state == .pending {
            let snapshot = ScrobbleSnapshot(
                artistName: requested.artist, albumName: requested.album ?? "", trackName: requested.name,
                imageURL: requested.imageURL, playedAt: .distantPast
            )
            _ = BPMEngine.resolveBPMLookup(context: modelContext, scrobbles: [snapshot])
            state = BPMEngine.resolution(context: modelContext, key: key)
        }
        resolvedBPM = state.resolved
        isLoadingBPM = state == .pending && !ConnectivityGate.isOffline
    }

    private func loadDuration() async {
        let requestedIdentity = identity
        isLoadingDuration = true
        let key = DurationEngine.cacheKey(artist: requestedIdentity.artist, track: requestedIdentity.name)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.identityKey == key })
        descriptor.fetchLimit = 1
        let loadedOverride = (try? modelContext.fetch(descriptor).first)?.durationOverrideSeconds
        let snapshot = ScrobbleSnapshot(
            artistName: requestedIdentity.artist,
            albumName: requestedIdentity.album ?? "",
            trackName: requestedIdentity.name,
            imageURL: requestedIdentity.imageURL,
            playedAt: .distantPast
        )
        let lookup = await DurationEngine.resolveDurationLookup(
            context: modelContext, client: DeezerAPIClient(), scrobbles: [snapshot]
        )
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        overrideSeconds = loadedOverride
        resolvedDuration = lookup[key]
        isLoadingDuration = false
    }
}
