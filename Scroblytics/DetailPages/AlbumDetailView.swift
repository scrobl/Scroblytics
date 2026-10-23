import SwiftData
import SwiftUI

/// Album detail page: one header card (identity, trend, headline numbers, release date, the album's listen-through, tags), then the
/// album's tracks.
struct AlbumDetailView: View {
    let identity: AlbumIdentity
    let settings: ChartDateSettings
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @State private var model = AlbumDetailModel()
    @State private var showingFixSheet = false
    @State private var showingReleaseDateEdit = false

    private var rangeOptions: [DateRangeOption] {
        DateRangePresets.build(oldestScrobbleDate: model.oldestScrobbleDate)
    }

    private var range: DateRange {
        (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).range()
    }

    private var compareRange: DateRange? { settings.resolveCompareRange(for: range) }

    /// The period the page is showing, as its picker words it; shared cards say it.
    private var periodLabel: String {
        (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).label
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailBreadcrumbBar(navigation: navigation, artist: ArtistIdentity(name: identity.artist), album: nil, current: identity.name)

                ChartControlsPanel(settings: settings, rangeOptions: rangeOptions, currentRange: range) {
                    // The table below carries its own "Tracks" heading; this row is only the list / grid switch.
                    EntityPresentationRow(selectorWidth: 0, isGridView: settings.binding(for: .track, context: .detail)) {
                        EmptyView()
                    }
                }

                DetailHeaderCard(
                    entity: .album, name: identity.name, subtitle: identity.artist, tertiary: nil,
                    imageURL: identity.imageURL, stats: model.stats, errorMessage: model.errorMessage, metric: settings.metric,
                    timeListenedSeconds: model.timeListenedSeconds, yearlyTopRanks: model.yearlyTopRanks,
                    onFixAlbumMatch: { showingFixSheet = true },
                    facts: model.facts(onEditReleaseDate: { showingReleaseDateEdit = true }, onFixAlbumMatch: { showingFixSheet = true })
                        + (EntityWeatherLean.fact(for: model.weatherLean).map { [$0] } ?? []),
                    sharePeriodLabel: periodLabel
                ) {
                    EntityTagsSectionView(
                        communityTags: model.communityTags, yourTags: model.yourTags, entity: .album,
                        artist: identity.artist, album: identity.name, track: nil,
                        modelContext: modelContext,
                        onTagsUpdated: { model.tagsWereUpdated($0) }
                    )
                }

                if settings.isGridView(for: .track, context: .detail) {
                    // The artwork grid is the same as before: only the tracks played in the period.
                    EntitySubListView(
                        entity: .track, artist: identity.artist, album: identity.name,
                        range: range, compareRange: compareRange, metric: settings.metric,
                        isGridView: true, origin: navigation.origin
                    )
                } else {
                    AlbumTrackTable(
                        artist: identity.artist, album: identity.name, range: range, compareRange: compareRange,
                        metric: settings.metric, turnover: model.turnoverState
                    )
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .navigationTitle(identity.name)
        .task(id: identity.id) {
            // Reappearing (a tab switched back to) is not a reason to blank the page and load it all again.
            if model.isLoaded(for: identity.id) { return }
            model.bind(identity: identity, context: modelContext)
            model.loadOldestScrobbleDate()
            let current = range
            let rangeID = settings.selectedRangeId
            // Everything starts at once. The listen-through goes first, since it fills the table's filter and Cycle column and the
            // turnover tiles; the rank-by-year chips are by far the slowest lookup and nothing waits for them.
            async let turnover: Void = model.loadTurnover()
            async let stats: Void = model.loadStats(range: current, rangeID: rangeID)
            async let tags: Void = model.loadTags()
            async let time: Void = model.loadTimeListened(range: current)
            async let release: Void = model.loadReleaseDate()
            async let ranks: Void = model.loadYearlyTopRanks()
            async let lean: Void = model.loadWeatherLean(range: current)
            _ = await (turnover, stats, tags, time, release, ranks, lean)
            if !Task.isCancelled { model.markLoaded(identity.id) }
        }
        .onChange(of: settings.selectedRangeId) { reloadForRange() }
        .onChange(of: settings.compareMode) { reloadForRange() }
        .onChange(of: settings.compareCustomDate) { reloadForRange() }
        .onChange(of: settings.metric) { reloadForRange() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task { await refreshAfterSync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            Task { await model.loadTimeListened(range: range) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReleaseDateEngine.progressNotification)) { _ in
            Task { await model.loadReleaseDate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .weatherDidUpdate)) { _ in
            Task { await model.loadWeatherLean(range: range) }
        }
        .sheet(isPresented: $showingFixSheet) {
            if let group = model.currentGroup {
                AlbumMatchFixView(
                    group: group, openedFrom: identity.name, modelContext: modelContext, client: model.makeClient(),
                    onResolved: { Task { await model.loadTurnover() } }
                )
            }
        }
        .sheet(isPresented: $showingReleaseDateEdit) {
            ReleaseDateEditView(
                target: .album(artist: identity.artist, album: identity.name),
                detectedDate: model.releaseDateOverride() == nil ? model.releaseDate : nil,
                currentOverride: model.releaseDateOverride(),
                modelContext: modelContext,
                onSaved: { Task { await model.loadReleaseDate() } }
            )
        }
    }

    private func reloadForRange() {
        let current = range
        let rangeID = settings.selectedRangeId
        Task {
            await model.loadStats(range: current, rangeID: rangeID)
            await model.loadTimeListened(range: current)
            await model.loadWeatherLean(range: current)
        }
    }

    private func refreshAfterSync() async {
        model.loadOldestScrobbleDate()
        let current = range
        let rangeID = settings.selectedRangeId
        async let turnover: Void = model.loadTurnover()
        async let stats: Void = model.loadStats(range: current, rangeID: rangeID)
        async let time: Void = model.loadTimeListened(range: current)
        async let release: Void = model.loadReleaseDate()
        async let ranks: Void = model.loadYearlyTopRanks()
        _ = await (turnover, stats, time, release, ranks)
    }
}
