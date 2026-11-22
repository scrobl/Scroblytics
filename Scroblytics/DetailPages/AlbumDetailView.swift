import SwiftData
import SwiftUI

/// Album detail page: one header card (identity, trend, headline numbers, release date, the album's listen-through, tags), then the
/// album's tracks.
struct AlbumDetailView: View {
    let identity: AlbumIdentity
    let settings: ChartDateSettings
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    /// Bumped when the person's name corrections change, so the page shows and loads under the new spelling.
    @State private var nameRevision = 0
    @State private var renamedTo: String?
    @State private var correctingName = false
    private var shown: AlbumIdentity {
        _ = nameRevision
        var current = NameCorrections.current.corrected(identity)
        if let renamedTo { current = AlbumIdentity(artist: current.artist, name: renamedTo, imageURL: current.imageURL) }
        return current
    }
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
                DetailBreadcrumbBar(navigation: navigation, artist: ArtistIdentity(name: shown.artist), album: nil, current: shown.name)

                ChartControlsPanel(settings: settings, rangeOptions: rangeOptions, currentRange: range) {
                    // The table below carries its own "Tracks" heading; this row is only the list / grid switch.
                    EntityPresentationRow(selectorWidth: 0, isGridView: settings.binding(for: .track, context: .detail)) {
                        EmptyView()
                    }
                }

                DetailHeaderCard(
                    entity: .album, name: shown.name, subtitle: shown.artist, tertiary: nil,
                    imageURL: shown.imageURL, stats: model.stats, errorMessage: model.errorMessage, metric: settings.metric,
                    timeListenedSeconds: model.timeListenedSeconds, yearlyTopRanks: model.yearlyTopRanks,
                    // Only offered once the album's match group exists: it is built from this album's scrobbles, so an album
                    // with none (or one whose turnover is still loading) has nothing to fix yet.
                    onFixAlbumMatch: model.currentGroup == nil ? nil : { showingFixSheet = true },
                    onCorrectName: { correctingName = true },
                    facts: model.facts(onEditReleaseDate: { showingReleaseDateEdit = true }, onFixAlbumMatch: { showingFixSheet = true })
                        + AppleMusicDetailsLookup.facts(model.appleMusic, entity: "album")
                        + (EntityWeatherLean.fact(for: model.weatherLean).map { [$0] } ?? []),
                    sharePeriodLabel: periodLabel
                ) {
                    EntityTagsSectionView(
                        communityTags: model.communityTags, yourTags: model.yourTags, entity: .album,
                        artist: shown.artist, album: shown.name, track: nil,
                        modelContext: modelContext,
                        onTagsUpdated: { model.tagsWereUpdated($0) }
                    )
                }

                if settings.isGridView(for: .track, context: .detail) {
                    // The artwork grid is the same as before: only the tracks played in the period.
                    EntitySubListView(
                        entity: .track, artist: shown.artist, album: shown.name,
                        range: range, compareRange: compareRange, metric: settings.metric,
                        isGridView: true, origin: navigation.origin, rangeID: settings.selectedRangeId
                    )
                } else {
                    AlbumTrackTable(
                        artist: shown.artist, album: shown.name, range: range, compareRange: compareRange,
                        metric: settings.metric, turnover: model.turnoverState, albumReleaseDate: model.releaseDate
                    )
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .navigationTitle(shown.name)
        .onReceive(NotificationCenter.default.publisher(for: .nameCorrectionsDidChange)) { _ in nameRevision += 1 }
        .sheet(isPresented: $correctingName) {
            NameCorrectionSheet(subject: NameCorrectionSubject(kind: .album, artist: shown.artist, name: shown.name)) { renamedTo = $0; nameRevision += 1 }
        }
        .task(id: "\(identity.id)#\(nameRevision)") {
            let loadID = "\(identity.id)#\(nameRevision)"
            // Reappearing (a tab switched back to) is not a reason to blank the page and load it all again.
            if model.isLoaded(for: loadID) { await model.loadAppleMusic(); return }
            model.bind(identity: shown, context: modelContext)
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
            async let music: Void = model.loadAppleMusic()
            _ = await (turnover, stats, tags, time, release, ranks, lean, music)
            if !Task.isCancelled { model.markLoaded(loadID) }
        }
        .onChange(of: settings.selectedRangeId) { reloadForRange() }
        .onChange(of: settings.compareMode) { reloadForRange() }
        .onChange(of: settings.compareCustomDate) { reloadForRange() }
        .onChange(of: settings.metric) { reloadForRange() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task { await refreshAfterSync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appleMusicDetailsDidUpdate)) { _ in Task { await model.loadAppleMusic() } }
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
                    group: group, openedFrom: shown.name, modelContext: modelContext, client: model.makeClient(),
                    onResolved: { Task { await model.loadTurnover() } }
                )
            } else {
                // Never an empty sheet: if the group isn't there (it went away while the sheet was opening), say so and offer a way out.
                VStack(spacing: 12) {
                    Text("Nothing to fix yet").font(AppTypography.sectionTitle)
                    Text("This album has no scrobbles, so there is no match to fix.")
                        .font(AppTypography.supporting).foregroundStyle(.secondary)
                    Button("Close") { showingFixSheet = false }.keyboardShortcut(.defaultAction)
                }
                .padding(32)
                .frame(minWidth: 320)
            }
        }
        .sheet(isPresented: $showingReleaseDateEdit) {
            ReleaseDateEditView(
                target: .album(artist: shown.artist, album: shown.name),
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
