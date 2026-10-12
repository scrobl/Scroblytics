import SwiftUI
import SwiftData

/// Container width below which the list collapses This/Prev/Move/Peak back
/// to a single rank + combined change badge, mirroring the sidebar's own
/// icon-only narrow-width collapse rather than clipping four columns.
private let chartTableCompactBreakpoint: CGFloat = 660

private struct TopChartsCacheKey: Hashable {
    let entity: String
    let rangeID: String
    let compareMode: String
    let compareCustomDate: Date?
    let metric: String
    let rowLimit: Int
}

private struct TopChartsCacheValue {
    let entries: [TopChartEntry]
    let loadedAt: Date

    func isFresh(at date: Date) -> Bool {
        date.timeIntervalSince(loadedAt) < 5 * 60
    }
}

private enum TopChartsTableLayout {
    static let columnSpacing: CGFloat = 10
    static let currentRankWidth: CGFloat = 56
    static let previousRankWidth: CGFloat = 56
    static let movementWidth: CGFloat = 116
    static let peakRankWidth: CGFloat = 36
    static let artworkSize = AppArtworkSizing.thumbnail
    static let artworkTextSpacing: CGFloat = 20
    static func valueWidth(for metric: TopChartsMetric) -> CGFloat {
        metric == .timeListened ? 108 : 72
    }
}

struct TopChartsView: View {
    @Environment(\.modelContext) private var modelContext
    let modelContainer: ModelContainer
    let settings: ChartDateSettings
    @Binding var entity: TopChartsEntity
    let isActive: Bool

    @State private var navigation = DetailNavigationCoordinator(origin: .topCharts)
    @State private var displayedMetric: TopChartsMetric = .scrobbles
    @State private var oldestScrobbleDate: Date?
    @State private var entries: [TopChartEntry] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var latestRequestID = UUID()
    @State private var cache: [TopChartsCacheKey: TopChartsCacheValue] = [:]
    @State private var hasLoaded = false
    @State private var needsReload = false
    @State private var lastDurationRefreshAt = Date.distantPast
    @State private var showsSlowLoadingIndicator = false
    @State private var slowLoadingTask: Task<Void, Never>?
    @State private var showsChartRace = false

    private var rangeOptions: [DateRangeOption] {
        DateRangePresets.build(oldestScrobbleDate: oldestScrobbleDate)
    }
    private var currentRange: DateRange {
        (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).range()
    }
    private var compareRange: DateRange? {
        settings.resolveCompareRange(for: currentRange)
    }
    private var currentRowLimit: Int {
        settings.topChartsRowLimit(for: entity)
    }

    var body: some View {
        NavigationStack(path: Binding(
            get: { navigation.path },
            set: { navigation.path = $0 }
        )) {
            VStack(spacing: 0) {
                TopChartsHeader(
                    settings: settings,
                    rangeOptions: rangeOptions,
                    currentRange: currentRange,
                    entity: $entity,
                    isGridView: settings.binding(for: entity, context: .topCharts),
                    showsChartRace: $showsChartRace,
                    showsPlaylistExport: !entries.isEmpty,
                    playlistName: defaultPlaylistName,
                    playlistTracks: makePlaylistTracks
                )
                Divider()
                PartialDataNoteBar()
                content
                    .overlay {
                        if showsSlowLoadingIndicator {
                            slowLoadingIndicator
                        }
                    }
            }
            .navigationTitle("Top Charts")
            .navigationDestination(for: ArtistIdentity.self, destination: artistDetail)
            .navigationDestination(for: AlbumIdentity.self, destination: albumDetail)
            .navigationDestination(for: TrackIdentity.self, destination: trackDetail)
        }
        .task(id: "\(isActive)-\(currentRowLimit)") {
            if hasLoaded { needsReload = true }
            await loadIfNeeded()
        }
        .onChange(of: entity) { showsChartRace = false; requestReload() }
        .onChange(of: settings.metric) { showsChartRace = false; requestReload() }
        .onChange(of: settings.selectedRangeId) { showsChartRace = false; requestReload() }
        .onChange(of: settings.compareMode) { requestReload() }
        .onChange(of: settings.compareCustomDate) { requestReload() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            cache.removeAll()
            TopChartsEngine.invalidatePoolCache()
            ChartRaceEngine.invalidateCache()
            oldestScrobbleDate = nil
            requestReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { _ in
            cache.removeAll()
            ChartRaceEngine.invalidateCache()
            requestReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: modelContext)) { note in
            // Entity-filtered for the same reason as `LibraryView`'s
            // identical fix: ranking by Time Listened resolves durations
            // in-flight during `reload()` itself, and each resolution
            // writes a `TrackDurationCacheEntry` row — an unfiltered
            // listener here would invalidate `latestRequestID` in the
            // middle of the very request that triggered the write,
            // discarding its own results via the `guard latestRequestID
            // == requestID` check below and leaving `isLoading` stuck
            // true forever. `Track` IS included (unlike Library's
            // version) — a duration override edit changes Time Listened
            // ranking and must invalidate the cache.
            guard !ImageResolutionEngine.isBulkResolving,
                  didSaveTouchesRankingRelevantEntity(note) else { return }
            cache.removeAll()
            TopChartsEngine.invalidatePoolCache()
            ChartRaceEngine.invalidateCache()
            latestRequestID = UUID()
            if !isActive { needsReload = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            guard settings.metric == .timeListened else { return }
            // Track lengths arrive every few seconds during a long backlog; re-ranking everything each time kept a big library busy.
            guard Date().timeIntervalSince(lastDurationRefreshAt) >= 180 else { return }
            lastDurationRefreshAt = Date()
            cache = cache.filter { $0.key.metric != TopChartsMetric.timeListened.rawValue }
            ChartRaceEngine.invalidateCache()
            requestReload()
        }
    }

    private func loadIfNeeded() async {
        guard isActive, !hasLoaded || needsReload else { return }
        if oldestScrobbleDate == nil { await loadOldestScrobbleDate() }
        needsReload = false
        await reload()
        hasLoaded = true
    }

    private func requestReload() {
        needsReload = true
        if isActive { Task { await loadIfNeeded() } }
    }

    private var defaultPlaylistName: String {
        let range = currentRange
        let dates = "\(range.from.formatted(date: .abbreviated, time: .omitted)) – \(range.to.formatted(date: .abbreviated, time: .omitted))"
        return switch entity {
        case .artist: "Top Artists Tracks (\(dates))"
        case .album: "Top Albums Tracks (\(dates))"
        case .track: "Top Tracks (\(dates))"
        }
    }

    private func makePlaylistTracks() async throws -> [AppleMusicPlaylistTrack] {
        if entity == .track {
            return entries.compactMap { entry in
                guard let artist = entry.artist, !artist.isEmpty else { return nil }
                return AppleMusicPlaylistTrack(artist: artist, track: entry.name, album: entry.album ?? "")
            }
        }

        return try await AppleMusicPlaylistBuilder.tracks(
            for: entries,
            entity: entity,
            range: currentRange,
            metric: settings.metric,
            container: modelContainer,
            context: modelContext
        )
    }

    private func artistDetail(_ identity: ArtistIdentity) -> some View {
        ArtistDetailView(identity: identity, settings: settings, navigation: navigation)
    }

    private func albumDetail(_ identity: AlbumIdentity) -> some View {
        AlbumDetailView(identity: identity, settings: settings, navigation: navigation)
    }

    private func trackDetail(_ identity: TrackIdentity) -> some View {
        TrackDetailView(identity: identity, settings: settings, navigation: navigation)
    }

    private func didSaveTouchesRankingRelevantEntity(_ note: Notification) -> Bool {
        let relevantEntities: Set<String> = ["Scrobble", "Artist", "Album", "Track"]
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        for key in keys {
            guard let ids = note.userInfo?[key] as? [PersistentIdentifier] else { continue }
            if ids.contains(where: { relevantEntities.contains($0.entityName) }) { return true }
        }
        return false
    }

    @ViewBuilder
    private var content: some View {
        let maxValue = entries.lazy.map { $0.metricValue(for: displayedMetric) }.max() ?? 1
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            Text(errorMessage).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            HistoryEmptyState { Text("No scrobbles in this range yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        } else if showsChartRace {
            ChartRaceView(
                modelContainer: modelContainer,
                entity: entity,
                range: currentRange,
                metric: displayedMetric,
                onClose: { showsChartRace = false }
            )
        } else if settings.isGridView(for: entity, context: .topCharts) {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(
                            minimum: AppArtworkSizing.tileMinimum,
                            maximum: AppArtworkSizing.tileMaximum
                        ),
                        spacing: AppArtworkSizing.tileSpacing
                    )],
                    spacing: AppArtworkSizing.tileSpacing
                ) {
                    ForEach(entries) { entry in
                        drillLink(for: entry) {
                            TopChartGridCell(entity: entity, entry: entry, metric: displayedMetric)
                        }
                        .drillDownHighlight()
                    }
                }
                .padding()
            }
        } else {
            GeometryReader { geo in
                let compact = geo.size.width < chartTableCompactBreakpoint
                VStack(spacing: 0) {
                    if !compact {
                        TopChartsHeaderRow(metric: displayedMetric)
                        Divider()
                    }
                    List(entries) { entry in
                        drillLink(for: entry) {
                            TopChartRow(entity: entity, entry: entry, metric: displayedMetric, maxValue: maxValue, compact: compact)
                        }
                        .drillDownHighlight()
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    private var slowLoadingIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(settings.metric == .timeListened ? "Calculating Time Listened…" : "Updating charts…")
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8, y: 3)
        .allowsHitTesting(false)
    }

    /// Dispatches to the right identity type for `.navigationDestination(for:)`
    /// to match on, based on which entity tab is currently selected.
    @ViewBuilder
    private func drillLink<Content: View>(for entry: TopChartEntry, @ViewBuilder content: () -> Content) -> some View {
        switch entity {
        case .artist:
            NavigationLink(value: ArtistIdentity(from: entry)) { content() }
                .entityContextMenu(target: ImageTarget(kind: .artist, artist: entry.name, album: nil, track: nil), currentImageURL: entry.imageURL)
        case .album:
            NavigationLink(value: AlbumIdentity(from: entry)) { content() }
                .entityContextMenu(target: ImageTarget(kind: .album, artist: entry.artist ?? "", album: entry.name, track: nil), currentImageURL: entry.imageURL)
        case .track:
            NavigationLink(value: TrackIdentity(from: entry)) { content() }
                .entityContextMenu(target: ImageTarget(kind: .track, artist: entry.artist ?? "", album: entry.album, track: entry.name), currentImageURL: entry.imageURL)
        }
    }

    private func loadOldestScrobbleDate() async {
        oldestScrobbleDate = try? await TopChartsEngine.fetchOldestScrobbleDate(container: modelContainer)
    }

    private func reload() async {
        let requestID = UUID()
        latestRequestID = requestID
        beginSlowLoadingTimer(for: requestID)
        errorMessage = nil
        let requestedEntity = entity
        let requestedMetric = settings.metric
        let requestedRowLimit = settings.topChartsRowLimit(for: requestedEntity)
        let cacheKey = TopChartsCacheKey(
            entity: requestedEntity.rawValue,
            rangeID: settings.selectedRangeId,
            compareMode: settings.compareMode.rawValue,
            compareCustomDate: settings.compareCustomDate,
            metric: requestedMetric.rawValue,
            rowLimit: requestedRowLimit
        )

        if let cached = cache[cacheKey], cached.isFresh(at: Date()) {
            entries = cached.entries
            displayedMetric = requestedMetric
            isLoading = false
            finishSlowLoading(for: requestID)
            return
        }
        cache[cacheKey] = nil
        isLoading = entries.isEmpty

        let range = currentRange
        let requestedCompareRange = compareRange

        do {
            let result = try await TopChartsEngine.fetchRankings(
                container: modelContainer,
                durationContext: modelContext,
                entity: requestedEntity,
                range: range,
                compareRange: requestedCompareRange,
                limit: requestedRowLimit,
                metric: requestedMetric,
                sourceCacheKey: sourceCacheKey
            )
            guard latestRequestID == requestID else { return }
            cache[cacheKey] = TopChartsCacheValue(entries: result, loadedAt: Date())
            entries = result
            displayedMetric = requestedMetric
            finishSlowLoading(for: requestID)
        } catch {
            guard latestRequestID == requestID else { return }
            errorMessage = "Failed to load rankings: \(error)"
            entries = []
            finishSlowLoading(for: requestID)
        }
        isLoading = false
    }

    private func beginSlowLoadingTimer(for requestID: UUID) {
        slowLoadingTask?.cancel()
        showsSlowLoadingIndicator = false
        slowLoadingTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, latestRequestID == requestID else { return }
            showsSlowLoadingIndicator = true
        }
    }

    private func finishSlowLoading(for requestID: UUID) {
        guard latestRequestID == requestID else { return }
        slowLoadingTask?.cancel()
        slowLoadingTask = nil
        showsSlowLoadingIndicator = false
    }

    private var sourceCacheKey: String {
        let customDate = settings.compareCustomDate?.timeIntervalSinceReferenceDate.description ?? "none"
        return "\(settings.selectedRangeId)|\(settings.compareMode.rawValue)|\(customDate)"
    }
}

private struct TopChartsHeader: View {
    let settings: ChartDateSettings
    let rangeOptions: [DateRangeOption]
    let currentRange: DateRange
    @Binding var entity: TopChartsEntity
    @Binding var isGridView: Bool
    @Binding var showsChartRace: Bool
    let showsPlaylistExport: Bool
    let playlistName: String
    let playlistTracks: @MainActor () async throws -> [AppleMusicPlaylistTrack]

    var body: some View {
        PageSettingsHeader("Top Charts") {
            VStack(alignment: .leading, spacing: 10) {
                ChartFilterBar(
                    settings: settings,
                    rangeOptions: rangeOptions,
                    currentRange: currentRange,
                    usesTimelineMetricPicker: true
                )
                HStack(spacing: 12) {
                    Picker("Chart type", selection: $entity) {
                        ForEach(TopChartsEntity.allCases) { entity in
                            Text(entity.displayName).tag(entity)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)

                    Menu {
                        Picker("Rows", selection: settings.topChartsRowLimitBinding(for: entity)) {
                            ForEach(ChartDateSettings.topChartsRowLimitOptions, id: \.self) { limit in
                                Text(limit.formatted()).tag(limit)
                            }
                        }
                    } label: {
                        Label("Rows: \(settings.topChartsRowLimit(for: entity))", systemImage: "list.number")
                    }

                    Spacer(minLength: 12)

                    if showsPlaylistExport && !showsChartRace {
                        AppleMusicPlaylistExportButton(
                            defaultPlaylistName: playlistName,
                            tracks: playlistTracks
                        )
                    }

                    if !showsChartRace {
                        Button {
                            showsChartRace = true
                        } label: {
                            Label("Chart race", systemImage: "play.fill")
                        }

                        Picker("Presentation", selection: $isGridView) {
                            Label("List", systemImage: "list.bullet").tag(false)
                            Label("Grid", systemImage: "square.grid.2x2").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 112)
                    }
                }
            }
        }
        .padding()
    }
}

private struct TopChartsHeaderRow: View {
    let metric: TopChartsMetric

    var body: some View {
        HStack(spacing: TopChartsTableLayout.columnSpacing) {
            Text("This").frame(width: TopChartsTableLayout.currentRankWidth, alignment: .center)
            Text("Prev").frame(width: TopChartsTableLayout.previousRankWidth, alignment: .center)
            Text("Move").frame(width: TopChartsTableLayout.movementWidth, alignment: .leading)
            Text("Peak").frame(width: TopChartsTableLayout.peakRankWidth, alignment: .center)
            Color.clear.frame(width: TopChartsTableLayout.artworkSize, height: 1)
                .padding(.trailing, TopChartsTableLayout.artworkTextSpacing - TopChartsTableLayout.columnSpacing)
            Text("").frame(maxWidth: .infinity, alignment: .leading)
            Text(metric == .scrobbles ? "Plays" : "Time")
                .lineLimit(1)
                .frame(width: TopChartsTableLayout.valueWidth(for: metric), alignment: .trailing)
        }
        .font(AppTypography.tableHeading)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct TopChartRow: View {
    let entity: TopChartsEntity
    let entry: TopChartEntry
    let metric: TopChartsMetric
    let maxValue: Int
    let compact: Bool

    var body: some View {
        HStack(spacing: TopChartsTableLayout.columnSpacing) {
            Text("\(entry.rank)")
                .font(AppTypography.tableRank)
                .foregroundStyle(compact ? .secondary : .primary)
                .lineLimit(1)
                .frame(width: TopChartsTableLayout.currentRankWidth, alignment: .center)

            if !compact {
                Text(entry.previousRank.map { "\($0)" } ?? "–")
                    .font(AppTypography.tablePreviousValue)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: TopChartsTableLayout.previousRankWidth, alignment: .center)
                RankChangeBadge(
                    rank: entry.rank, previousRank: entry.previousRank, hasCompareRange: entry.hasCompareRange,
                    showDelta: true, newLabel: "Hot Shot Debut", newColor: .purple
                )
                .frame(width: TopChartsTableLayout.movementWidth, alignment: .leading)
                Text("\(entry.peakRank)")
                    .font(AppTypography.tablePreviousValue)
                    .foregroundStyle(.tertiary)
                    .frame(width: TopChartsTableLayout.peakRankWidth, alignment: .center)
            }

            HStack(spacing: TopChartsTableLayout.artworkTextSpacing) {
                EntityThumbnail(url: entry.imageURL, entity: entity)
                    .frame(width: TopChartsTableLayout.artworkSize, height: TopChartsTableLayout.artworkSize)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(entry.name)
                            .font(AppTypography.contentTitle)
                            .lineLimit(1)
                        TrackLovedIndicator(
                            artist: entry.artist ?? "", track: entry.name,
                            initialValue: entry.loved, font: AppTypography.metadata,
                            enabled: entity == .track
                        )
                        PopularityMarker(entity: entity, entry: entry)
                    }
                    if let subtitle = entry.artist {
                        Text(subtitle).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                    }
                    // Relative-magnitude bar vs. the list's top entry, by
                    // whichever value the list is currently ranked by.
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: geo.size.width * CGFloat(entry.metricValue(for: metric)) / CGFloat(max(maxValue, 1)), height: 3)
                    }
                    .frame(height: 3)
                }
            }

            Spacer()
            Text(metric == .scrobbles ? "\(entry.playcount)" : DurationEngine.formatTimeListened(entry.timeListenedSeconds ?? 0))
                .font(AppTypography.tableValue)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: TopChartsTableLayout.valueWidth(for: metric), alignment: .trailing)

            if compact {
                RankChangeBadge(
                    rank: entry.rank, previousRank: entry.previousRank, hasCompareRange: entry.hasCompareRange,
                    showDelta: false, newLabel: "New", newColor: .green
                )
            }
        }
        .padding(.vertical, 7)
    }
}

/// Rank-change indicator. The compact
/// combined badge uses generic defaults ("New"/green,
/// no delta — shows the previous rank number instead); the expanded Move
/// column explicitly reuses The Climb's "Hot Shot Debut"/purple wording and
/// shows the delta count.
struct RankChangeBadge: View {
    let rank: Int
    let previousRank: Int?
    let hasCompareRange: Bool
    var showDelta: Bool = false
    var newLabel: String = "New"
    var newColor: Color = .green

    var body: some View {
        if !hasCompareRange {
            Text("–").font(AppTypography.supporting).foregroundStyle(.tertiary)
        } else if let previousRank {
            if previousRank == rank {
                badge(text: nil, systemImage: "minus", color: .gray, foreground: .primary)
            } else {
                let improved = rank < previousRank
                let label = showDelta ? "\(abs(rank - previousRank))" : "\(previousRank)"
                badge(text: label, systemImage: improved ? "arrow.up" : "arrow.down", color: improved ? AppColors.positiveBadge : .red, foreground: .white)
            }
        } else {
            badge(text: newLabel, systemImage: "arrow.up", color: newColor, foreground: .white)
        }
    }

    private func badge(text: String?, systemImage: String, color: Color, foreground: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            if let text { Text(text) }
        }
        .font(AppTypography.badge)
        .foregroundStyle(foreground)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(foreground == .primary ? 0.2 : 1), in: Capsule())
        .fixedSize()
    }
}

private struct TopChartGridCell: View {
    let entity: TopChartsEntity
    let entry: TopChartEntry
    let metric: TopChartsMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                EntityThumbnail(url: entry.imageURL, entity: entity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("\(entry.rank)")
                    .font(AppTypography.badge)
                    .padding(4)
                    .background(.black.opacity(0.6), in: Circle())
                    .foregroundStyle(.white)
                    .padding(4)
            }
            HStack(spacing: 4) {
                Text(entry.name).font(AppTypography.compactTitle).lineLimit(1)
                TrackLovedIndicator(
                    artist: entry.artist ?? "", track: entry.name,
                    initialValue: entry.loved, font: AppTypography.supportingDense,
                    enabled: entity == .track
                )
                PopularityMarker(entity: entity, entry: entry)
            }
            if let subtitle = entry.artist {
                Text(subtitle).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(metric == .scrobbles ? "\(entry.playcount) plays" : DurationEngine.formatTimeListened(entry.timeListenedSeconds ?? 0))
                .font(AppTypography.supportingDense).foregroundStyle(.tertiary)
        }
    }
}

/// Internal (not private) — also reused by the entity detail page's own
/// sortable sub-list rows.
struct EntityThumbnail: View {
    let url: String?
    let entity: TopChartsEntity

    var body: some View {
        ArtworkImage(urlString: url, contentMode: .fill) {
            placeholder
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .overlay(Image(systemName: entity == .artist ? "person.fill" : "music.note").foregroundStyle(.secondary))
    }
}
