import SwiftData
import SwiftUI

/// The new Track page: one header card (identity, trend, headline numbers, release date, length, tempo, tags), then the plays.
struct NewTrackDetailPage: View {
    let identity: TrackIdentity
    let settings: ChartDateSettings
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @State private var model = TrackDetailModel()
    @State private var showingDurationEdit = false
    @State private var showingBPMEdit = false
    @State private var showingReleaseDateEdit = false

    private var rangeOptions: [DateRangeOption] {
        DateRangePresets.build(oldestScrobbleDate: model.oldestScrobbleDate)
    }

    private var range: DateRange {
        (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).range()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailBreadcrumbBar(
                    navigation: navigation,
                    artist: ArtistIdentity(name: identity.artist),
                    album: identity.album.map { AlbumIdentity(artist: identity.artist, name: $0) },
                    current: identity.name
                )

                ChartFilterBarSection(settings: settings, rangeOptions: rangeOptions, currentRange: range)

                DetailHeaderCard(
                    entity: .track, name: identity.name, subtitle: identity.artist, tertiary: identity.album,
                    imageURL: identity.imageURL, stats: model.stats, errorMessage: model.errorMessage, metric: settings.metric,
                    // A single track's time listened is its length times its plays; no separate lookup is needed.
                    timeListenedSeconds: model.resolvedDuration.map { $0 * (model.stats?.plays ?? 0) },
                    yearlyTopRanks: model.yearlyTopRanks,
                    onToggleLoved: { Task { await model.toggleLoved(range: range) } },
                    isTogglingLoved: model.isTogglingLoved,
                    facts: model.facts(
                        onEditReleaseDate: { showingReleaseDateEdit = true },
                        onEditDuration: { showingDurationEdit = true },
                        onEditTempo: { showingBPMEdit = true }
                    )
                ) {
                    EntityTagsSectionView(
                        communityTags: model.communityTags, yourTags: model.yourTags, entity: .track,
                        artist: identity.artist, album: identity.album, track: identity.name,
                        modelContext: modelContext,
                        onTagsUpdated: { model.tagsWereUpdated($0) }
                    )
                }

                if let lovedError = model.lovedError {
                    Text(lovedError).font(AppTypography.compactMetadata).foregroundStyle(.red)
                }

                if !model.scrobbleHistory.isEmpty {
                    scrobbleHistorySection
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .navigationTitle(identity.name)
        .task(id: identity.id) {
            model.bind(identity: identity, context: modelContext)
            model.loadOldestScrobbleDate()
            let current = range
            model.loadStats(range: current)
            model.loadScrobbleHistory(range: current)
            model.loadBPM()
            async let ranks: Void = model.loadYearlyTopRanks()
            async let tags: Void = model.loadTags()
            async let duration: Void = model.loadDuration()
            async let release: Void = model.loadReleaseDate()
            _ = await (ranks, tags, duration, release)
        }
        .onChange(of: settings.selectedRangeId) { reloadForRange() }
        .onChange(of: settings.compareMode) { reloadForRange() }
        .onChange(of: settings.compareCustomDate) { reloadForRange() }
        .onChange(of: settings.metric) { reloadForRange() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task { await refreshAfterSync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: BPMEngine.progressNotification)) { _ in model.loadBPM() }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            Task { await model.loadDuration() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReleaseDateEngine.progressNotification)) { _ in
            Task { await model.loadReleaseDate() }
        }
        .sheet(isPresented: $showingBPMEdit) {
            TrackBPMEditView(
                artist: identity.artist, track: identity.name,
                detected: model.overrideBPM == nil ? model.resolvedBPM : nil, currentOverride: model.overrideBPM,
                modelContext: modelContext, onSaved: { model.loadBPM() }
            )
        }
        .sheet(isPresented: $showingDurationEdit) {
            TrackDurationEditView(
                artist: identity.artist, track: identity.name, album: model.primaryAlbum ?? identity.album,
                detectedSeconds: model.overrideSeconds == nil ? model.resolvedDuration : nil,
                currentOverrideSeconds: model.overrideSeconds, modelContext: modelContext,
                onSaved: { Task { await model.loadDuration() } }
            )
        }
        .sheet(isPresented: $showingReleaseDateEdit) {
            ReleaseDateEditView(
                target: .track(artist: identity.artist, track: identity.name),
                detectedDate: model.releaseDateOverride() == nil ? model.releaseDate : nil,
                currentOverride: model.releaseDateOverride(),
                modelContext: modelContext,
                onSaved: { Task { await model.loadReleaseDate() } }
            )
        }
    }

    private func reloadForRange() {
        let current = range
        model.loadStats(range: current)
        model.loadScrobbleHistory(range: current)
    }

    private func refreshAfterSync() async {
        model.loadOldestScrobbleDate()
        reloadForRange()
        await model.loadYearlyTopRanks()
        await model.loadReleaseDate()
    }

    // MARK: - Plays

    private var scrobbleHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.scrobbleHistory.count.formatted()) plays").font(AppTypography.sectionTitle)
            VStack(spacing: 0) {
                ForEach(model.scrobbleHistory) { entry in
                    scrobbleRow(entry)
                    if entry.id != model.scrobbleHistory.last?.id { Divider() }
                }
            }
        }
    }

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
}
