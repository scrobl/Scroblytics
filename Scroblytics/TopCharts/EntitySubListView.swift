import SwiftUI
import SwiftData

enum SubListSort: String, CaseIterable, Identifiable {
    case mostPlayed, alphabetical, recentlyPlayed, trackOrder, releaseYear
    var id: String { rawValue }

    var label: String {
        switch self {
        case .mostPlayed: return "Most played"
        case .alphabetical: return "A–Z"
        case .recentlyPlayed: return "Recently played"
        case .trackOrder: return "Track order"
        case .releaseYear: return "Release year"
        }
    }
}

/// Sortable list of an artist's own albums/tracks, or an album's own
/// tracks — the "Library"-mode half of the merged Top Charts/Library view
/// (Phase 5). One unified sort menu rather than a separate mode toggle.
/// The leading position column shows chart rank for "Most played" and the
/// album track number for "Track order"; the other browse modes omit it.
struct EntitySubListView: View {
    /// `.album` for an artist's own Albums tab; `.track` for an artist's
    /// own Tracks tab OR an album's own track list.
    let entity: TopChartsEntity
    let artist: String
    /// Set only when this is an ALBUM's own track list — enables Track
    /// order and scopes the ranking query to just that album. Nil for an
    /// artist's own Albums/Tracks tab (scoped to the artist's whole catalog).
    let album: String?
    let range: DateRange
    let compareRange: DateRange?
    let metric: TopChartsMetric
    let isGridView: Bool
    /// Where this page was reached from — drives the initial sort default
    /// only: Library's own Artist→Album grid defaults to Release year
    /// descending (the paused Phase 2 gap this closes), while every other
    /// origin (Top Charts, Overview) keeps defaulting to Most played. The
    /// user can still switch away from either default via the sort menu.
    let origin: DetailNavigationOrigin
    @Environment(\.modelContext) private var modelContext
    @State private var entries: [TopChartEntry] = []
    @State private var trackOrderIndex: [String: Int] = [:]
    @State private var sort: SubListSort
    /// nil means the sort's own starting direction (see `SubListSort.startsAscending`).
    @State private var ascendingOverride: Bool?
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(entity: TopChartsEntity, artist: String, album: String?, range: DateRange, compareRange: DateRange?, metric: TopChartsMetric, isGridView: Bool, origin: DetailNavigationOrigin) {
        self.entity = entity
        self.artist = artist
        self.album = album
        self.range = range
        self.compareRange = compareRange
        self.metric = metric
        self.isGridView = isGridView
        self.origin = origin
        _sort = State(initialValue: origin == .library && entity == .album ? .releaseYear : .mostPlayed)
    }

    private var filterID: String {
        [
            entity.rawValue,
            TextNormalization.artistIdentityKey(artist),
            album.map(TextNormalization.normalizeAlbumName) ?? "",
            String(Int(range.from.timeIntervalSinceReferenceDate / 86_400)),
            String(Int(range.to.timeIntervalSinceReferenceDate / 86_400)),
            String(Int((compareRange?.from.timeIntervalSinceReferenceDate ?? 0) / 86_400)),
            metric.rawValue
        ].joined(separator: "|")
    }

    private var availableSorts: [SubListSort] {
        if entity == .track && album != nil {
            return [.mostPlayed, .alphabetical, .recentlyPlayed, .trackOrder, .releaseYear]
        }
        return entity == .album || entity == .track
            ? [.mostPlayed, .alphabetical, .recentlyPlayed, .releaseYear]
            : [.mostPlayed, .alphabetical, .recentlyPlayed]
    }

    /// The entries in the chosen order and direction. The sorts below are written in their starting direction; a reversed one is that
    /// list backwards, except that dates nobody knows stay last in a release-year order, since "unknown" is neither oldest nor newest.
    private var sortedEntries: [TopChartEntry] {
        let natural = startingDirectionEntries
        guard let override = ascendingOverride, override != sort.startsAscending else { return natural }
        if sort == .releaseYear {
            let known = natural.filter { $0.releaseDate.flatMap(ReleaseDateEngine.year(of:)) != nil }
            let unknown = natural.filter { $0.releaseDate.flatMap(ReleaseDateEngine.year(of:)) == nil }
            return Array(known.reversed()) + unknown
        }
        return Array(natural.reversed())
    }

    private var startingDirectionEntries: [TopChartEntry] {
        switch sort {
        case .mostPlayed:
            return entries
        case .alphabetical:
            return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recentlyPlayed:
            return entries.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
        case .trackOrder:
            return entries.sorted { a, b in
                let ai = trackOrderIndex[TextNormalization.normalizeTrackTitle(a.name)] ?? Int.max
                let bi = trackOrderIndex[TextNormalization.normalizeTrackTitle(b.name)] ?? Int.max
                if ai != bi { return ai < bi }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .releaseYear:
            // Descending by year; unknown dates sort last regardless of
            // direction (an unresolved/unknown date isn't "oldest," it's
            // just not comparable) rather than clumping at year 0.
            return entries.sorted { a, b in
                let ay = a.releaseDate.flatMap(ReleaseDateEngine.year(of:))
                let by = b.releaseDate.flatMap(ReleaseDateEngine.year(of:))
                switch (ay, by) {
                case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
                case (nil, _): return false
                case (_, nil): return true
                case (let ay?, let by?):
                    if ay != by { return ay > by }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
        }
    }

    private var maxMetricValue: Int {
        entries.map { $0.metricValue(for: metric) }.max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entity == .album ? "Albums" : "Tracks").font(AppTypography.sectionTitle)
                Spacer()
                if entity == .track, !entries.isEmpty {
                    AppleMusicPlaylistExportButton(
                        defaultPlaylistName: defaultPlaylistName,
                        tracks: { playlistTracks }
                    )
                    .controlSize(.small)
                }
                Picker("Sort", selection: $sort) {
                    ForEach(availableSorts) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                let ascending = ascendingOverride ?? sort.startsAscending
                Button {
                    ascendingOverride = !ascending
                } label: {
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                }
                .help("\(sort.directionLabel(ascending: ascending)). Click to reverse.")
                .accessibilityLabel("Sort direction: \(sort.directionLabel(ascending: ascending))")
                .accessibilityHint("Reverses the order")
            }

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .center).padding()
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            } else if entries.isEmpty {
                Text("Nothing here yet.").foregroundStyle(.secondary)
            } else if isGridView {
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(
                            minimum: AppArtworkSizing.tileMinimum,
                            maximum: AppArtworkSizing.tileMaximum
                        ),
                        spacing: AppArtworkSizing.tileSpacing
                    )],
                    alignment: .leading,
                    spacing: AppArtworkSizing.tileSpacing
                ) {
                    ForEach(sortedEntries) { entry in
                        gridItem(for: entry)
                    }
                }
            } else {
                let maxValue = maxMetricValue
                VStack(spacing: 0) {
                    ForEach(sortedEntries) { entry in
                        row(for: entry, maxValue: maxValue)
                        if entry.id != sortedEntries.last?.id { Divider() }
                    }
                }
            }
        }
        .task(id: filterID) { await load() }
        .onChange(of: sort) {
            ascendingOverride = nil
            if sort == .trackOrder { Task { await loadTrackOrderIfNeeded() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { notification in
            guard imageChangeAffectsVisibleEntries(notification) else { return }
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            guard metric == .timeListened else { return }
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReleaseDateEngine.progressNotification)) { _ in
            guard sort == .releaseYear else { return }
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: modelContext)) { note in
            guard sort == .releaseYear, didSaveReleaseDateEntity(note) else { return }
            Task { await load() }
        }
    }

    private var defaultPlaylistName: String {
        let dates = "\(range.from.formatted(date: .abbreviated, time: .omitted)) – \(range.to.formatted(date: .abbreviated, time: .omitted))"
        if let album {
            return "\(artist) – \(album) Tracks (\(dates))"
        }
        return "\(artist) Tracks (\(dates))"
    }

    private var playlistTracks: [AppleMusicPlaylistTrack] {
        sortedEntries.compactMap { entry in
            let trackArtist = entry.artist ?? artist
            guard !trackArtist.isEmpty else { return nil }
            return AppleMusicPlaylistTrack(
                artist: trackArtist,
                track: entry.name,
                album: entry.album ?? album ?? ""
            )
        }
    }

    private func imageChangeAffectsVisibleEntries(_ notification: Notification) -> Bool {
        guard let target = notification.object as? ImageTarget else { return true }
        guard TextNormalization.artistIdentityKey(target.artist)
                == TextNormalization.artistIdentityKey(artist) else { return false }

        switch (entity, target.kind) {
        case (.album, .album):
            return true
        case (.track, .track):
            return album == nil || target.album == nil
                || TextNormalization.normalizeAlbumName(target.album ?? "")
                    == TextNormalization.normalizeAlbumName(album ?? "")
        case (.track, .album):
            return album == nil
                || TextNormalization.normalizeAlbumName(target.album ?? "")
                    == TextNormalization.normalizeAlbumName(album ?? "")
        default:
            return false
        }
    }

    private func didSaveReleaseDateEntity(_ note: Notification) -> Bool {
        let relevantEntities: Set<String> = ["Album", "Track"]
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        return keys.contains { key in
            guard let identifiers = note.userInfo?[key] as? [PersistentIdentifier] else { return false }
            return identifiers.contains { relevantEntities.contains($0.entityName) }
        }
    }

    @ViewBuilder
    private func gridItem(for entry: TopChartEntry) -> some View {
        switch entity {
        case .album:
            NavigationLink(value: AlbumIdentity(from: entry)) { gridContent(entry) }
                .drillDownHighlight()
                .entityContextMenu(target: imageTarget(for: entry), currentImageURL: entry.imageURL)
        case .track:
            NavigationLink(value: TrackIdentity(from: entry)) { gridContent(entry) }
                .drillDownHighlight()
                .entityContextMenu(target: imageTarget(for: entry), currentImageURL: entry.imageURL)
        case .artist:
            gridContent(entry)
        }
    }

    private func gridContent(_ entry: TopChartEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EntityThumbnail(url: entry.imageURL, entity: entity)
                .frame(maxWidth: .infinity)
                .frame(height: 120)

            HStack(spacing: 4) {
                Text(entry.name)
                    .font(AppTypography.compactTitle)
                    .lineLimit(2)
                TrackLovedIndicator(
                    artist: entry.artist ?? "", track: entry.name,
                    initialValue: entry.loved, font: AppTypography.compactMetadata,
                    enabled: entity == .track
                )
                PopularityMarker(entity: entity, entry: entry)
            }

            if entity == .track, album == nil, let albumName = entry.album {
                Text(albumName)
                    .font(AppTypography.compactMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                if sort == .releaseYear {
                    Text(releaseDateLabel(entry))
                        .font(AppTypography.compactMetadata)
                        .foregroundStyle(.secondary)
                } else {
                    Text(formattedMetric(entry))
                        .font(AppTypography.compactMetadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if sort == .mostPlayed, entry.hasCompareRange {
                    RankChangeBadge(
                        rank: entry.rank, previousRank: entry.previousRank, hasCompareRange: true,
                        showDelta: false, newLabel: "New", newColor: .purple
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func row(for entry: TopChartEntry, maxValue: Int) -> some View {
        switch entity {
        case .album:
            NavigationLink(value: AlbumIdentity(from: entry)) { rowContent(entry, maxValue: maxValue) }
                .drillDownHighlight()
                .entityContextMenu(target: imageTarget(for: entry), currentImageURL: entry.imageURL)
        case .track:
            NavigationLink(value: TrackIdentity(from: entry)) { rowContent(entry, maxValue: maxValue) }
                .drillDownHighlight()
                .entityContextMenu(target: imageTarget(for: entry), currentImageURL: entry.imageURL)
        case .artist:
            rowContent(entry, maxValue: maxValue)
        }
    }

    private func imageTarget(for entry: TopChartEntry) -> ImageTarget {
        switch entity {
        case .artist:
            return ImageTarget(kind: .artist, artist: entry.name, album: nil, track: nil)
        case .album:
            return ImageTarget(kind: .album, artist: entry.artist ?? artist, album: entry.name, track: nil)
        case .track:
            return ImageTarget(kind: .track, artist: entry.artist ?? artist, album: entry.album ?? album, track: entry.name)
        }
    }

    private func rowContent(_ entry: TopChartEntry, maxValue: Int) -> some View {
        HStack(spacing: 12) {
            if sort == .mostPlayed {
                positionLabel(entry.rank)
            } else if sort == .trackOrder {
                let normalizedTitle = TextNormalization.normalizeTrackTitle(entry.name)
                positionLabel(trackOrderIndex[normalizedTitle].map { $0 + 1 })
            } else if sort == .releaseYear {
                releaseYearPositionLabel(entry)
            }
            EntityThumbnail(url: entry.imageURL, entity: entity)
                .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name).font(AppTypography.contentTitle).lineLimit(1)
                    TrackLovedIndicator(
                        artist: entry.artist ?? "", track: entry.name,
                        initialValue: entry.loved, font: AppTypography.metadata,
                        enabled: entity == .track
                    )
                    PopularityMarker(entity: entity, entry: entry)
                }
                // An artist's own Tracks tab spans every album — show which
                // one. An album's own track list already has that context
                // from the page header, so this line would be redundant.
                if entity == .track, album == nil, let albumName = entry.album {
                    Text(albumName).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                }
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(
                            width: geometry.size.width
                                * CGFloat(entry.metricValue(for: metric))
                                / CGFloat(max(maxValue, 1)),
                            height: 3
                        )
                }
                .frame(height: 3)
            }
            Spacer()
            Text(formattedMetric(entry))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if sort == .mostPlayed, entry.hasCompareRange {
                RankChangeBadge(
                    rank: entry.rank, previousRank: entry.previousRank, hasCompareRange: true,
                    showDelta: false, newLabel: "New", newColor: .purple
                )
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func formattedMetric(_ entry: TopChartEntry) -> String {
        metric == .scrobbles
            ? entry.playcount.formatted()
            : DurationEngine.formatTimeListened(entry.timeListenedSeconds ?? 0)
    }

    private func releaseDateLabel(_ entry: TopChartEntry) -> String {
        switch entry.releaseDateResolution {
        case .pending: return "Pending…"
        case .unknown: return "Unknown"
        case .date(let releaseDate): return ReleaseDateEngine.formatYear(releaseDate)
        }
    }

    private func positionLabel(_ position: Int?) -> some View {
        Text(position.map(String.init) ?? "—")
            .font(AppTypography.tableRank)
            .foregroundStyle(.secondary)
            .frame(width: 24, alignment: .trailing)
    }

    private func releaseYearPositionLabel(_ entry: TopChartEntry) -> some View {
        Text(releaseDateLabel(entry))
            .font(AppTypography.tableRank)
            .foregroundStyle(.secondary)
            .frame(width: 64, alignment: .trailing)
    }

    private func load() async {
        let requestedFilterID = filterID
        isLoading = true
        errorMessage = nil
        do {
            let loadedEntries = try await TopChartsEngine.fetchScopedRankings(
                container: modelContext.container,
                durationContext: modelContext,
                entity: entity,
                artist: artist,
                album: album,
                range: range,
                compareRange: compareRange,
                metric: metric
            )
            guard !Task.isCancelled, filterID == requestedFilterID else { return }
            entries = loadedEntries
        } catch {
            guard !Task.isCancelled, filterID == requestedFilterID else { return }
            errorMessage = "Failed to load: \(error)"
        }
        guard filterID == requestedFilterID else { return }
        isLoading = false
    }

    /// Fire-and-forget: needs a live Last.fm call only on a cache miss, and
    /// skips gracefully with no saved credentials, like the other Album Turnover
    /// call sites.
    private func loadTrackOrderIfNeeded() async {
        guard trackOrderIndex.isEmpty, let album, let credentials = LastfmCredentialsStore.load() else { return }
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        guard let result = try? await AlbumTurnoverEngine.getCachedTracklist(context: modelContext, client: client, artist: artist, album: album),
              case .found(let tracklist) = result else { return }
        var index: [String: Int] = [:]
        for (i, title) in tracklist.tracks.enumerated() {
            index[TextNormalization.normalizeTrackTitle(title)] = i
        }
        trackOrderIndex = index
    }
}
