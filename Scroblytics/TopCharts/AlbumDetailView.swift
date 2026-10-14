import SwiftUI
import SwiftData

@ModelActor
private actor AlbumDetailDataReader {
    func fetchArtistScrobbles(artist: String) throws -> [ScrobbleSnapshot] {
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate<Scrobble> { $0.artistName.localizedStandardContains(artist) },
            sortBy: [SortDescriptor(\.playedAt)]
        )
        return try modelContext.fetch(descriptor).filter { TextNormalization.artistIdentityKey($0.artistName) == artistKey }.map(\.snapshot)
    }
}

/// Album detail page — header, the album's own sortable track sub-list
/// (Phase 5), and Turnover status (Phase 7). Reached from Top Charts
/// today; Overview drill-down is a separate follow-up.
struct AlbumDetailView: View {
    let identity: AlbumIdentity
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
    @State private var turnover: AlbumTurnoverEngine.AlbumTurnover?
    @State private var isLoadingTurnover = false
    @State private var communityTags: TagsLoadState = .loading
    @State private var yourTags: TagsLoadState = .loading
    @State private var currentGroup: AlbumGroup?
    @State private var showingFixSheet = false
    @State private var timeListenedSeconds: Int?
    @State private var isLoadingTimeListened = false
    @State private var releaseDate: String?
    @State private var isLoadingReleaseDate = false
    @State private var showingReleaseDateEdit = false

    @AppStorage(DetailPageStyle.key) private var pageStyle = DetailPageStyle.classic.rawValue

    var body: some View {
        if DetailPageStyle.resolve(storedValue: pageStyle) == .new {
            DetailPagePlaceholder(navigation: navigation, artist: ArtistIdentity(name: identity.artist), album: nil, title: identity.name)
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailBreadcrumbBar(
                    navigation: navigation,
                    artist: ArtistIdentity(name: identity.artist), album: nil, current: identity.name
                )

                ChartControlsPanel(settings: settings, rangeOptions: rangeOptions, currentRange: range) {
                    EntityPresentationRow(selectorWidth: 100, isGridView: settings.binding(for: .track, context: .detail)) {
                        Text("Tracks").font(AppTypography.contentTitle).foregroundStyle(.secondary)
                    }
                }

                EntityStatsHeaderSection(
                    entity: .album, name: identity.name, subtitle: identity.artist, tertiary: nil,
                    imageURL: identity.imageURL, stats: stats, errorMessage: errorMessage, metric: metric,
                    onFixAlbumMatch: { showingFixSheet = true },
                    timeListenedSeconds: timeListenedSeconds,
                    yearlyTopRanks: yearlyTopRanks
                )

                releaseDateRow

                EntityTagsSectionView(
                    communityTags: communityTags, yourTags: yourTags, entity: .album,
                    artist: identity.artist, album: identity.name, track: nil,
                    modelContext: modelContext,
                    onTagsUpdated: { tags in yourTags = .loaded(EntityTagsResult(tags: tags, inherited: false)) }
                )

                if let turnover, turnover.applicable {
                    AlbumTurnoverSection(
                        turnover: turnover,
                        onFixAlbumMatch: { showingFixSheet = true }
                    )
                } else if isLoadingTurnover {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking turnover…").foregroundStyle(.secondary)
                    }
                    .font(AppTypography.compactMetadata)
                }

                EntitySubListView(
                    entity: .track, artist: identity.artist, album: identity.name,
                    range: range, compareRange: compareRange, metric: metric,
                    isGridView: settings.isGridView(for: .track, context: .detail), origin: navigation.origin
                )
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .navigationTitle(identity.name)
        .task(id: identity.id) {
            resetIdentityState()
            loadOldestScrobbleDate()
            await loadStats()
            guard !Task.isCancelled else { return }
            await loadYearlyTopRanks()
        }
        .onChange(of: settings.selectedRangeId) { reloadFilteredContent() }
        .onChange(of: settings.compareMode) { reloadFilteredContent() }
        .onChange(of: settings.compareCustomDate) { reloadFilteredContent() }
        .onChange(of: settings.metric) { reloadFilteredContent() }
        .task(id: "turnover|\(identity.id)") { await loadTurnover() }
        .task(id: "tags|\(identity.id)") { await loadTags() }
        .task(id: "time|\(identity.id)") { await loadTimeListened() }
        .task(id: "release|\(identity.id)") { await loadReleaseDate() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task { await refreshAfterSync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            Task { await loadTimeListened() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReleaseDateEngine.progressNotification)) { _ in
            Task { await loadReleaseDate() }
        }
        .sheet(isPresented: $showingFixSheet) {
            if let currentGroup {
                AlbumMatchFixView(
                    group: currentGroup, modelContext: modelContext, client: makeClient(),
                    onResolved: { Task { await loadTurnover() } }
                )
            }
        }
        .sheet(isPresented: $showingReleaseDateEdit) {
            ReleaseDateEditView(
                target: .album(artist: identity.artist, album: identity.name),
                detectedDate: currentReleaseDateOverride() == nil ? releaseDate : nil,
                currentOverride: currentReleaseDateOverride(),
                modelContext: modelContext,
                onSaved: { Task { await loadReleaseDate() } }
            )
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
        ReleaseDateEngine.albumRow(
            context: modelContext, artist: identity.artist, album: identity.name
        )?.releaseDateOverride
    }

    /// MusicBrainz needs no credentials (public API) — unlike `loadTags`,
    /// this never skips. Awaits resolution through `ReleaseDateEngine`'s
    /// shared rate-limited queue rather than fetching ad hoc.
    private func loadReleaseDate() async {
        guard !isLoadingReleaseDate else { return }
        let requestedIdentity = identity
        isLoadingReleaseDate = true
        let loadedDate = await ReleaseDateEngine.resolveAlbumDateAwaiting(
            context: modelContext, musicBrainz: MusicBrainzAPIClient(), deezer: DeezerAPIClient(),
            artist: requestedIdentity.artist, album: requestedIdentity.name
        )
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        releaseDate = loadedDate
        isLoadingReleaseDate = false
    }

    private func makeClient() -> LastfmAPIClient? {
        guard let credentials = LastfmCredentialsStore.load() else { return nil }
        return LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
    }

    /// Deezer needs no credentials — unlike `loadTags`, this never skips.
    private func loadTimeListened() async {
        guard !isLoadingTimeListened else { return }
        let requestedIdentity = identity
        let requestedRange = range
        isLoadingTimeListened = true
        let seconds = await EntityStatsEngine.fetchAlbumTimeListened(
            context: modelContext,
            client: DeezerAPIClient(),
            artist: requestedIdentity.artist,
            album: requestedIdentity.name,
            range: requestedRange
        )
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        timeListenedSeconds = seconds
        isLoadingTimeListened = false
    }

    private func refreshAfterSync() async {
        loadOldestScrobbleDate()
        await loadStats()
        await loadYearlyTopRanks()
        await loadTurnover()
        await loadTimeListened()
        await loadReleaseDate()
    }

    private func resetIdentityState() {
        stats = nil
        errorMessage = nil
        yearlyTopRanks = []
        turnover = nil
        currentGroup = nil
        isLoadingTurnover = false
        communityTags = .loading
        yourTags = .loading
        timeListenedSeconds = nil
        isLoadingTimeListened = false
        releaseDate = nil
        isLoadingReleaseDate = false
    }

    private func reloadFilteredContent() {
        Task {
            await loadStats()
            await loadTimeListened()
        }
    }

    private func loadOldestScrobbleDate() {
        var descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        descriptor.fetchLimit = 1
        oldestScrobbleDate = (try? modelContext.fetch(descriptor))?.first?.playedAt
    }

    private func loadStats() async {
        let requestedIdentity = identity
        let requestedRange = range
        let requestedRangeID = settings.selectedRangeId
        do {
            let loadedStats = try await EntityStatsEngine.fetchAlbumStats(
                container: modelContext.container,
                artist: requestedIdentity.artist,
                album: requestedIdentity.name,
                range: requestedRange
            )
            guard !Task.isCancelled,
                  identity.id == requestedIdentity.id,
                  settings.selectedRangeId == requestedRangeID else { return }
            stats = loadedStats
        } catch {
            guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
            errorMessage = "Failed to load stats: \(error)"
        }
    }

    /// Community tags need only the read API key; personal tags are also
    /// readable without write auth (Last.fm tags are public) — so both load
    /// regardless of whether Track Actions is connected, matching the
    /// approved Display-only scope.
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
            client: client, context: modelContext, entity: .album,
            artist: requestedIdentity.artist, album: requestedIdentity.name
        )
        let loadedPersonalTags = await EntityTagsEngine.fetchUserTags(
            client: client, context: modelContext, entity: .album,
            artist: requestedIdentity.artist, album: requestedIdentity.name
        )
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        communityTags = .loaded(loadedCommunityTags)
        yourTags = .loaded(loadedPersonalTags)
    }

    private func loadYearlyTopRanks() async {
        let requestedIdentity = identity
        let ranks = (try? await TopChartsEngine.fetchYearlyTopRanks(
            container: modelContext.container,
            entity: .album,
            name: requestedIdentity.name,
            artist: requestedIdentity.artist
        )) ?? []
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        yearlyTopRanks = ranks
    }

    /// Fire-and-forget and deliberately last of the three loads (lazy) —
    /// needs a live Last.fm call on a tracklist-cache miss, and skips
    /// gracefully with no saved credentials, matching the rest of this
    /// port's Album Turnover call sites. Reuses `resolveAlbumTurnover`
    /// directly against a single-artist `AlbumGroup` built just for this
    /// album, rather than the whole-library `fetchRankings` candidate scan
    /// Overview's own Turnover card runs.
    private func loadTurnover() async {
        let requestedIdentity = identity
        guard let credentials = LastfmCredentialsStore.load() else { return }
        isLoadingTurnover = true
        do {
            let artist = requestedIdentity.artist
            let container = modelContext.container
            let scrobbles = try await offMain { try await AlbumDetailDataReader(modelContainer: container).fetchArtistScrobbles(artist: artist) }
            guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
            let groups = AlbumTurnoverEngine.buildAlbumGroups(from: scrobbles)
            let targetNorm = TextNormalization.normalizeAlbumName(requestedIdentity.name)
            guard let group = groups.first(where: {
                $0.normalizedName == targetNorm || $0.variants.contains(requestedIdentity.name)
            }) else {
                guard identity.id == requestedIdentity.id else { return }
                isLoadingTurnover = false
                return
            }
            let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
            let resolution = AlbumTurnoverEngine.storedResolution(context: modelContext, group: group)
            let loadedTurnover = try await AlbumTurnoverEngine.resolveAlbumTurnover(
                context: modelContext, group: group, resolution: resolution, client: client
            )
            guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
            currentGroup = group
            turnover = loadedTurnover
        } catch {
            // Silent — Turnover is a bonus enrichment, not core page content.
        }
        guard identity.id == requestedIdentity.id else { return }
        isLoadingTurnover = false
    }
}

/// Turnover formatting plus a compact per-track
/// checklist, reusing `AlbumTurnoverEngine.AlbumTurnover.tracks` (already
/// computed by `resolveAlbumTurnover`) instead of Overview's simpler
/// "missing tracks" card, which doesn't carry rate/cycle detail.
private struct AlbumTurnoverSection: View {
    let turnover: AlbumTurnoverEngine.AlbumTurnover
    let onFixAlbumMatch: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "repeat").foregroundStyle(.secondary)
                Text(formatTurnoverRate(turnover.rateDays)).font(AppTypography.sectionTitle)
                // Covers both waterfall entry cases per the PRD: ambiguous
                // (Last.fm found a tracklist but confidence was low) and
                // noCanonicalMatch (Last.fm found nothing at all) — both are
                // "fix this" states, just worded differently for the user.
                if turnover.ambiguous {
                    fixBadge(label: "Uncertain match")
                } else if turnover.noCanonicalMatch {
                    fixBadge(label: "No match found")
                }
            }
            Text("Turnover (all-time)" + (turnover.cyclesCompleted > 0 ? " · \(turnover.cyclesCompleted) full cycle\(turnover.cyclesCompleted == 1 ? "" : "s")" : ""))
                .font(AppTypography.compactMetadata).foregroundStyle(.tertiary)

            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(AppTypography.supportingDense)
                    Text(formatInProgress(turnover)).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(turnover.tracks.enumerated()), id: \.offset) { index, track in
                        HStack(spacing: 6) {
                            // Numbered only for a canonical basis —
                            // an unresolved/observed-only album has no real
                            // "position 1, 2, 3…" to show, since its
                            // denominator is just whatever titles were
                            // scrobbled, not an actual ordered tracklist.
                            if turnover.basis == .canonical {
                                Text("\(index + 1)")
                                    .font(AppTypography.supportingDense).foregroundStyle(.tertiary)
                                    .frame(width: 16, alignment: .trailing)
                            }
                            Image(systemName: track.heardThisCycle ? "checkmark.circle.fill" : "circle")
                                .font(AppTypography.supportingDense)
                                .foregroundStyle(track.heardThisCycle ? Color.green : Color.secondary)
                            Text(track.title).font(AppTypography.compactMetadata).foregroundStyle(track.heardThisCycle ? .primary : .secondary)
                            TrackLovedIndicator(
                                artist: turnover.artist,
                                track: track.title,
                                initialValue: false,
                                font: AppTypography.supportingDense
                            )
                            PopularityMarker(
                                entity: .track,
                                name: track.title,
                                artist: turnover.artist,
                                font: AppTypography.supportingDense
                            )
                        }
                        .contentShape(Rectangle())
                        .entityContextMenu(
                            target: ImageTarget(
                                kind: .track,
                                artist: turnover.artist,
                                album: turnover.album,
                                track: track.title
                            ),
                            currentImageURL: turnover.imageURL
                        )
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private func fixBadge(label: String) -> some View {
        Button(action: onFixAlbumMatch) {
            Label(label, systemImage: "exclamationmark.triangle.fill")
                .font(AppTypography.supportingDense)
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Fix album match…")
        .accessibilityHint("Opens the Fix Album Match tool")
    }

    private func formatTurnoverRate(_ rateDays: Double?) -> String {
        AlbumTurnoverEngine.formatTurnoverRate(rateDays)
    }

    private func formatInProgress(_ t: AlbumTurnoverEngine.AlbumTurnover) -> String {
        if t.inProgressHeard == 0 {
            return t.cyclesCompleted > 0 ? "New cycle just starting" : "0 of \(t.inProgressTotal) heard"
        }
        return "\(t.inProgressHeard) of \(t.inProgressTotal) heard this cycle"
    }
}
