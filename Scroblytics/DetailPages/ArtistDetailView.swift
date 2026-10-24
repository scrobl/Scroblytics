import SwiftData
import SwiftUI

/// Artist detail page: one header card (identity, trend, headline numbers, tags), then the artist's albums or tracks.
struct ArtistDetailView: View {
    let identity: ArtistIdentity
    let settings: ChartDateSettings
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @State private var model = ArtistDetailModel()
    @State private var subListEntity: TopChartsEntity = .album

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
                DetailBreadcrumbBar(navigation: navigation, artist: nil, album: nil, current: identity.name)

                ChartControlsPanel(settings: settings, rangeOptions: rangeOptions, currentRange: range) {
                    EntityPresentationRow(selectorWidth: 200, isGridView: settings.binding(for: subListEntity, context: .detail)) {
                        Picker("Content type", selection: $subListEntity) {
                            Text("Albums").tag(TopChartsEntity.album)
                            Text("Tracks").tag(TopChartsEntity.track)
                        }
                    }
                }

                DetailHeaderCard(
                    entity: .artist, name: identity.name, subtitle: nil, tertiary: nil,
                    imageURL: identity.imageURL, stats: model.stats, errorMessage: model.errorMessage, metric: settings.metric,
                    timeListenedSeconds: model.timeListenedSeconds, yearlyTopRanks: model.yearlyTopRanks,
                    facts: EntityWeatherLean.fact(for: model.weatherLean).map { [$0] } ?? [],
                    sharePeriodLabel: periodLabel
                ) {
                    EntityTagsSectionView(
                        communityTags: model.communityTags, yourTags: model.yourTags, entity: .artist,
                        artist: identity.name, album: nil, track: nil,
                        modelContext: modelContext,
                        onTagsUpdated: { model.tagsWereUpdated($0) }
                    )
                }

                EntitySubListView(
                    entity: subListEntity, artist: identity.name, album: nil,
                    range: range, compareRange: compareRange, metric: settings.metric,
                    isGridView: settings.isGridView(for: subListEntity, context: .detail), origin: navigation.origin
                )
                .id(subListEntity)
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
            model.loadStats(range: range)
            async let ranks: Void = model.loadYearlyTopRanks()
            async let tags: Void = model.loadTags()
            async let time: Void = model.loadTimeListened(range: range)
            async let lean: Void = model.loadWeatherLean(range: range)
            _ = await (ranks, tags, time, lean)
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
        .onReceive(NotificationCenter.default.publisher(for: .weatherDidUpdate)) { _ in
            Task { await model.loadWeatherLean(range: range) }
        }
    }

    private func reloadForRange() {
        let current = range
        model.loadStats(range: current)
        Task { await model.loadTimeListened(range: current) }
        Task { await model.loadWeatherLean(range: current) }
    }

    private func refreshAfterSync() async {
        model.loadOldestScrobbleDate()
        let current = range
        model.loadStats(range: current)
        await model.loadYearlyTopRanks()
        await model.loadTimeListened(range: current)
    }
}
