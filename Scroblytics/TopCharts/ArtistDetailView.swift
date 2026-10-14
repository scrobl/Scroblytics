import SwiftUI
import SwiftData

/// Artist detail page — header, then an Albums/Tracks toggle over the
/// artist's own sortable sub-list (Phase 5). Reached from Top Charts today;
/// Overview drill-down is a separate follow-up.
struct ArtistDetailView: View {
    let identity: ArtistIdentity
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
    @State private var subListEntity: TopChartsEntity = .album
    @State private var communityTags: TagsLoadState = .loading
    @State private var yourTags: TagsLoadState = .loading
    @State private var timeListenedSeconds: Int?

    @AppStorage(DetailPageStyle.key) private var pageStyle = DetailPageStyle.classic.rawValue

    var body: some View {
        if DetailPageStyle.resolve(storedValue: pageStyle) == .new {
            DetailPagePlaceholder(navigation: navigation, artist: nil, album: nil, title: identity.name)
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailBreadcrumbBar(navigation: navigation, artist: nil, album: nil, current: identity.name)

                ChartControlsPanel(settings: settings, rangeOptions: rangeOptions, currentRange: range) {
                    EntityPresentationRow(selectorWidth: 200, isGridView: settings.binding(for: subListEntity, context: .detail)) {
                        Picker("Content type", selection: $subListEntity) {
                            Text("Albums").tag(TopChartsEntity.album)
                            Text("Tracks").tag(TopChartsEntity.track)
                        }
                    }
                }

                EntityStatsHeaderSection(
                    entity: .artist, name: identity.name, subtitle: nil, tertiary: nil,
                    imageURL: identity.imageURL, stats: stats, errorMessage: errorMessage, metric: metric,
                    timeListenedSeconds: timeListenedSeconds,
                    yearlyTopRanks: yearlyTopRanks
                )

                EntityTagsSectionView(
                    communityTags: communityTags, yourTags: yourTags, entity: .artist,
                    artist: identity.name, album: nil, track: nil,
                    modelContext: modelContext,
                    onTagsUpdated: { tags in yourTags = .loaded(EntityTagsResult(tags: tags, inherited: false)) }
                )

                EntitySubListView(
                    entity: subListEntity, artist: identity.name, album: nil,
                    range: range, compareRange: compareRange, metric: metric,
                    isGridView: settings.isGridView(for: subListEntity, context: .detail), origin: navigation.origin
                )
                    .id(subListEntity)
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .navigationTitle(identity.name)
        .task(id: identity.id) {
            resetIdentityState()
            loadOldestScrobbleDate()
            loadStats()
        }
        .onChange(of: settings.selectedRangeId) { reloadFilteredContent() }
        .onChange(of: settings.compareMode) { reloadFilteredContent() }
        .onChange(of: settings.compareCustomDate) { reloadFilteredContent() }
        .onChange(of: settings.metric) { reloadFilteredContent() }
        .task(id: "yearly|\(identity.id)") { await loadYearlyTopRanks() }
        .task(id: "tags|\(identity.id)") { await loadTags() }
        .task(id: "time|\(identity.id)") { await loadTimeListened() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task { await refreshAfterSync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            Task { await loadTimeListened() }
        }
    }

    private func refreshAfterSync() async {
        loadOldestScrobbleDate()
        loadStats()
        await loadYearlyTopRanks()
        await loadTimeListened()
    }

    private func resetIdentityState() {
        stats = nil
        errorMessage = nil
        yearlyTopRanks = []
        communityTags = .loading
        yourTags = .loading
        timeListenedSeconds = nil
    }

    private func reloadFilteredContent() {
        loadStats()
        Task { await loadTimeListened() }
    }

    private func loadOldestScrobbleDate() {
        var descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        descriptor.fetchLimit = 1
        oldestScrobbleDate = (try? modelContext.fetch(descriptor))?.first?.playedAt
    }

    private func loadStats() {
        do {
            stats = try EntityStatsEngine.fetchArtistStats(context: modelContext, artist: identity.name, range: range)
        } catch {
            errorMessage = "Failed to load stats: \(error)"
        }
    }

    private func loadYearlyTopRanks() async {
        let requestedIdentity = identity
        let ranks = (try? await TopChartsEngine.fetchYearlyTopRanks(
            context: modelContext, entity: .artist,
            name: requestedIdentity.name, artist: nil
        )) ?? []
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        yearlyTopRanks = ranks
    }

    /// Community tags need only the read API key; personal tags are also
    /// readable without write auth (Last.fm tags are public) — so both load
    /// regardless of whether Track Actions is connected, matching the
    /// approved Display-only scope. No credentials at all means no API key
    /// to call with, so both sections settle on empty rather than loading
    /// forever.
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
            client: client, context: modelContext, entity: .artist,
            artist: requestedIdentity.name
        )
        let loadedPersonalTags = await EntityTagsEngine.fetchUserTags(
            client: client, context: modelContext, entity: .artist, artist: requestedIdentity.name
        )
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        communityTags = .loaded(loadedCommunityTags)
        yourTags = .loaded(loadedPersonalTags)
    }

    /// Deezer needs no credentials — unlike `loadTags`, this never skips.
    private func loadTimeListened() async {
        let requestedIdentity = identity
        let requestedRange = range
        let seconds = await EntityStatsEngine.fetchArtistTimeListened(
            context: modelContext, client: DeezerAPIClient(),
            artist: requestedIdentity.name, range: requestedRange
        )
        guard !Task.isCancelled, identity.id == requestedIdentity.id else { return }
        timeListenedSeconds = seconds
    }
}
