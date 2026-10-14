import SwiftData
import SwiftUI

/// The new Album page: one header card (identity, trend, headline numbers, release date, the album's listen-through, tags), then the
/// album's tracks.
struct NewAlbumDetailPage: View {
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
                        isGridView: true, origin: navigation.origin, allowsDirection: true
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
            model.bind(identity: identity, context: modelContext)
            model.loadOldestScrobbleDate()
            await model.loadStats(range: range, rangeID: settings.selectedRangeId)
            guard !Task.isCancelled else { return }
            await model.loadYearlyTopRanks()
            let current = range
            async let tags: Void = model.loadTags()
            async let time: Void = model.loadTimeListened(range: current)
            async let release: Void = model.loadReleaseDate()
            async let turnover: Void = model.loadTurnover()
            _ = await (tags, time, release, turnover)
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
        .sheet(isPresented: $showingFixSheet) {
            if let group = model.currentGroup {
                AlbumMatchFixView(
                    group: group, modelContext: modelContext, client: model.makeClient(),
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
        }
    }

    private func refreshAfterSync() async {
        model.loadOldestScrobbleDate()
        let current = range
        await model.loadStats(range: current, rangeID: settings.selectedRangeId)
        await model.loadYearlyTopRanks()
        await model.loadTurnover()
        await model.loadTimeListened(range: current)
        await model.loadReleaseDate()
    }
}
