import SwiftData
import SwiftUI

/// Track detail page: one header card (identity, trend, headline numbers, release date, length, tempo, tags), then the plays.
struct TrackDetailView: View {
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

    /// The period the page is showing, as its picker words it; shared cards say it.
    private var periodLabel: String {
        (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).label
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

                // Opened from an album's track list: that album's plays, with a way to every album's.
                if let album = identity.scopedAlbum {
                    TrackAlbumScopeBar(
                        album: album, song: identity.name, onlyThisAlbum: $model.onlyThisAlbum,
                        plays: model.stats?.plays ?? 0, otherAlbums: model.otherAlbumPlays
                    )
                }

                DetailHeaderCard(
                    entity: .track, name: identity.name, subtitle: identity.artist, tertiary: identity.album,
                    imageURL: identity.imageURL, stats: model.stats, errorMessage: model.errorMessage, metric: settings.metric,
                    // A single track's time listened is its length times its plays; no separate lookup is needed.
                    timeListenedSeconds: model.resolvedDuration.map { $0 * (model.stats?.plays ?? 0) },
                    // The yearly ranks are the song's across every album, so they step aside while one album is shown.
                    yearlyTopRanks: model.activeAlbum == nil ? model.yearlyTopRanks : [],
                    onToggleLoved: { Task { await model.toggleLoved(range: range) } },
                    isTogglingLoved: model.isTogglingLoved,
                    facts: model.facts(
                        onEditReleaseDate: { showingReleaseDateEdit = true },
                        onEditDuration: { showingDurationEdit = true },
                        onEditTempo: { showingBPMEdit = true }
                    ),
                    shareWeather: model.activeAlbum == nil ? EntityWeatherLean.fact(for: model.weatherLean) : nil,
                    sharePeriodLabel: periodLabel
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
                    TrackPlaysList(history: model.scrobbleHistory, weather: model.weather, unit: WeatherSettings.temperatureUnit())
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .navigationTitle(identity.name)
        .task(id: identity.id) {
            // Reappearing (a tab switched back to) is not a reason to blank the page and load it all again.
            // The weather may have changed meanwhile (a trip added, a download finished): that alone is read again.
            if model.isLoaded(for: identity.id) { await model.loadWeather(); await model.loadWeatherLean(range: range); await model.loadAppleMusic(); return }
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
            async let weather: Void = model.loadWeather()
            async let lean: Void = model.loadWeatherLean(range: current)
            async let music: Void = model.loadAppleMusic()
            _ = await (ranks, tags, duration, release, weather, lean, music)
            if !Task.isCancelled { model.markLoaded(identity.id) }
        }
        .onChange(of: settings.selectedRangeId) { reloadForRange() }
        .onChange(of: settings.compareMode) { reloadForRange() }
        .onChange(of: settings.compareCustomDate) { reloadForRange() }
        .onChange(of: settings.metric) { reloadForRange() }
        .onChange(of: model.onlyThisAlbum) { reloadForRange() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task { await refreshAfterSync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .weatherDidUpdate)) { _ in Task { await model.loadWeather(); await model.loadWeatherLean(range: range) } }
        .onReceive(NotificationCenter.default.publisher(for: BPMEngine.progressNotification)) { _ in model.loadBPM() }
        .onReceive(NotificationCenter.default.publisher(for: .appleMusicDetailsDidUpdate)) { _ in Task { await model.loadAppleMusic(); model.loadBPM() } }
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
        Task { await model.loadWeatherLean(range: current) }
    }

    private func refreshAfterSync() async {
        model.loadOldestScrobbleDate()
        reloadForRange()
        await model.loadYearlyTopRanks()
        await model.loadReleaseDate()
    }
}

/// The switch and the line under it on a Track page opened from an album's track list.
struct TrackAlbumScopeBar: View {
    let album: String
    let song: String
    @Binding var onlyThisAlbum: Bool
    /// The plays shown (on this album, or every album, as the switch says) and where the song's other plays are.
    let plays: Int
    let otherAlbums: [(album: String, plays: Int)]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Picker("Plays", selection: $onlyThisAlbum) {
                Text("This album").tag(true)
                Text("All albums").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show only the plays of this song on \(album), or every play of it on every album it is on.")
            Text(Self.caption(album: album, song: song, onlyThisAlbum: onlyThisAlbum, plays: plays, otherAlbums: otherAlbums))
                .font(AppTypography.compactMetadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// What the line says. With one album shown it says where the rest are, so a song you have never played on this album isn't a mystery.
    static func caption(album: String, song: String, onlyThisAlbum: Bool, plays: Int, otherAlbums: [(album: String, plays: Int)]) -> String {
        let others = otherAlbums.reduce(0) { $0 + $1.plays }
        let named = otherAlbums.prefix(3).map { "\($0.album) (\($0.plays.formatted()))" }.joined(separator: ", ")
        let more = otherAlbums.count > 3 ? ", and \(otherAlbums.count - 3) more" : ""
        guard onlyThisAlbum else {
            return others == 0 ? "Every play of this song, on every album: all of them are on \(album)."
                : "Every play of this song, on every album. The plays on other albums: \(named)\(more)."
        }
        if plays == 0, others > 0 { return "No plays of “\(song)” on \(album) in this period. It is played on \(named)\(more)." }
        if plays == 0 { return "No plays of “\(song)” on \(album) in this period." }
        return others > 0 ? "Only plays on \(album). \(others.formatted()) more on \(named)\(more)." : "Only plays on \(album)."
    }
}
