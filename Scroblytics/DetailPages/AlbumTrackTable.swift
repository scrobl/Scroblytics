import SwiftData
import SwiftUI

/// The new Album page's track table: the album's whole tracklist in order (tracks not played in the chosen period are dimmed),
/// whether each counts toward the current listen-through, and its plays in the period. With no known tracklist it is the
/// period's played tracks, as before.
struct AlbumTrackTable: View {
    let artist: String
    let album: String
    let range: DateRange
    let compareRange: DateRange?
    let metric: TopChartsMetric
    let turnover: AlbumTurnoverState
    /// Plays to show instead of loading them (the layout snapshots use this; the page never does).
    var seedEntries: [TopChartEntry]? = nil
    var seedDurations: [String: Int]? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var entries: [TopChartEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var chosenSort: AlbumTrackSort?
    /// nil means the chosen sort's own starting direction; the button flips it, and choosing another sort puts it back.
    @State private var chosenAscending: Bool?
    @State private var filter = AlbumTrackFilter.all
    @State private var width: CGFloat = 900
    /// Saved lengths by key (see `AlbumTrackDurations`); a track with none shows a dash.
    @State private var durations: [String: Int] = [:]
    /// How the listening history spells this album's tracks, so a track not played in the period still opens its own page.
    @State private var playedNames: [String: PlayedName] = [:]

    /// Column widths. The plays and last-played columns grow with the window, and "Last played" is the first to go in a narrow one.
    private enum Column {
        static let position: CGFloat = 28
    }

    private static let showsLastPlayedFrom: CGFloat = 640
    private static let showsLengthFrom: CGFloat = 560
    private static let lengthWidth: CGFloat = 52

    private var cycleWidth: CGFloat { width >= 900 ? 56 : 40 }
    private var playsWidth: CGFloat { min(300, max(100, width * 0.24)) }
    private var lastPlayedWidth: CGFloat { min(150, max(92, width * 0.11)) }
    /// The longest bar: what is left of the plays column after its number.
    private var barLimit: CGFloat { max(30, playsWidth - 52) }

    private var tracklist: [AlbumTrackRows.ListedTrack]? { AlbumTrackRows.tracklist(from: turnover) }
    private var hasTracklist: Bool { tracklist != nil }
    private var hasCycle: Bool { tracklist?.contains { $0.heardThisCycle != nil } == true }
    private var showsLastPlayed: Bool { width >= Self.showsLastPlayedFrom }
    private var showsLength: Bool { width >= Self.showsLengthFrom }

    /// Changes when the set of tracks does, so the lengths are read again only then.
    private var lengthKeys: [String: String] { AlbumTrackDurations.keys(for: allRows, albumArtist: artist, playedNames: playedNames) }

    private var availableSorts: [AlbumTrackSort] {
        hasTracklist ? AlbumTrackSort.allCases : AlbumTrackSort.allCases.filter { $0 != .trackOrder }
    }

    private var sort: AlbumTrackSort {
        if let chosenSort, availableSorts.contains(chosenSort) { return chosenSort }
        return hasTracklist ? .trackOrder : .mostPlayed
    }

    private var ascending: Bool { chosenAscending ?? sort.startsAscending }

    private var allRows: [AlbumTrackRow] { AlbumTrackRows.merge(tracklist: tracklist, entries: entries) }

    private var visibleRows: [AlbumTrackRow] {
        let activeFilter = hasTracklist ? filter : .all
        return AlbumTrackRows.sorted(AlbumTrackRows.filtered(allRows, by: activeFilter), by: sort, metric: metric, ascending: ascending)
    }

    private var filterID: String {
        [
            TextNormalization.artistIdentityKey(artist), TextNormalization.normalizeAlbumName(album),
            String(Int(range.from.timeIntervalSinceReferenceDate / 86_400)), String(Int(range.to.timeIntervalSinceReferenceDate / 86_400)),
            String(Int((compareRange?.from.timeIntervalSinceReferenceDate ?? 0) / 86_400)), metric.rawValue,
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .center).padding()
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            } else if allRows.isEmpty {
                Text("Nothing here yet.").foregroundStyle(.secondary)
            } else {
                table
            }
            if case .loading = turnover, !isLoading {
                Text("Looking up the album's tracklist…").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: filterID) { await load() }
        .task(id: "\(artist)|\(album)") { await loadPlayedNames() }
        .task(id: "\(allRows.map(\.id))|\(playedNames.count)") { await loadLengths() }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            Task { await loadLengths() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            guard metric == .timeListened else { return }
            Task { await load() }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { title; Spacer(minLength: 8); filterPicker; trailingControls }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) { title; Spacer(minLength: 8); trailingControls }
                filterPicker
            }
        }
    }

    private var title: some View {
        Text("Tracks").font(AppTypography.sectionTitle)
    }

    @ViewBuilder
    private var filterPicker: some View {
        if hasTracklist {
            Picker("Show", selection: $filter) {
                Text("All tracks").tag(AlbumTrackFilter.all)
                Text("Played in period").tag(AlbumTrackFilter.playedInPeriod)
                if hasCycle {
                    Text("Not heard this cycle (\(AlbumTrackRows.notHeardCount(allRows)))").tag(AlbumTrackFilter.notHeardThisCycle)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        if !entries.isEmpty {
            AppleMusicPlaylistExportButton(defaultPlaylistName: defaultPlaylistName, tracks: { playlistTracks })
                .controlSize(.small)
        }
        Picker("Sort", selection: Binding(get: { sort }, set: { chosenSort = $0; chosenAscending = nil })) {
            ForEach(availableSorts) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        Button {
            chosenAscending = !ascending
        } label: {
            Image(systemName: ascending ? "arrow.up" : "arrow.down")
        }
        .help("\(sort.directionLabel(ascending: ascending)). Click to reverse.")
        .accessibilityLabel("Sort direction: \(sort.directionLabel(ascending: ascending))")
        .accessibilityHint("Reverses the order")
    }

    // MARK: - Table

    private var table: some View {
        let rows = visibleRows
        let maxValue = max(1, entries.map { $0.metricValue(for: metric) }.max() ?? 1)
        let firstExtra = rows.firstIndex { $0.kind == .extra }
        return VStack(spacing: 0) {
            headerRow
            Divider()
            if rows.isEmpty {
                Text(filter == .notHeardThisCycle ? "Every track has been heard this cycle." : "No tracks to show.")
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // With a tracklist and the natural order, the unmatched plays are set apart under their own heading.
                if hasTracklist, sort == .trackOrder, index == firstExtra {
                    Text("Other tracks played, not matched to the tracklist")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(.quaternary.opacity(0.4))
                }
                rowView(row, maxValue: maxValue)
                if index < rows.count - 1 { Divider() }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("#").frame(width: Column.position, alignment: .trailing)
            Text("Track").frame(maxWidth: .infinity, alignment: .leading)
            if hasCycle { Text("Cycle").frame(width: cycleWidth) }
            Text(metric == .scrobbles ? "Plays in period" : "Time in period").frame(width: playsWidth, alignment: .trailing)
            if showsLastPlayed { Text("Last played").frame(width: lastPlayedWidth, alignment: .trailing) }
            if showsLength { Text("Length").frame(width: Self.lengthWidth, alignment: .trailing) }
        }
        .font(AppTypography.compactMetadata)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.vertical, 4)
    }

    /// Every row opens its track's page, played in the period or not: the page shows that track's plays for whatever period is chosen.
    private func rowView(_ row: AlbumTrackRow, maxValue: Int) -> some View {
        let who = AlbumTrackRows.identity(for: row, albumArtist: artist, playedNames: playedNames)
        let destination = row.entry.map { TrackIdentity(from: $0) } ?? TrackIdentity(artist: who.artist, name: who.name, album: album)
        return NavigationLink(value: destination) { rowContent(row, maxValue: maxValue) }
            .drillDownHighlight()
            .entityContextMenu(
                target: ImageTarget(kind: .track, artist: who.artist, album: row.entry?.album ?? album, track: who.name),
                currentImageURL: row.entry?.imageURL
            )
            .help(row.entry == nil ? "Not played in this period. Click to open the track." : "")
    }

    private func rowContent(_ row: AlbumTrackRow, maxValue: Int) -> some View {
        let played = row.entry != nil
        let who = AlbumTrackRows.identity(for: row, albumArtist: artist, playedNames: playedNames)
        return HStack(spacing: 10) {
            Text(row.position.map(String.init) ?? "·")
                .font(AppTypography.tableRank).foregroundStyle(.secondary)
                .frame(width: Column.position, alignment: .trailing)
            // The loved, flagged and "not in your library" marks belong to the track, not to its plays, so a dimmed row shows them too
            // (under the names its page opens with, which are the names a flag or love is saved under).
            HStack(spacing: 4) {
                Text(row.title).font(AppTypography.contentTitle).lineLimit(1)
                TrackLovedIndicator(artist: who.artist, track: who.name, initialValue: row.entry?.loved ?? false, font: AppTypography.metadata, enabled: true)
                if let entry = row.entry {
                    PopularityMarker(entity: .track, entry: entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hasCycle {
                cycleMark(row.heardThisCycle).frame(width: cycleWidth)
            }
            playsCell(row.entry, maxValue: maxValue).frame(width: playsWidth, alignment: .trailing)
            if showsLastPlayed {
                Text(row.entry.map { Self.relative($0.lastPlayedAt) } ?? "—")
                    .font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: lastPlayedWidth, alignment: .trailing)
            }
            if showsLength {
                Text(AlbumTrackDurations.text(seconds: durations[AlbumTrackDurations.key(for: row, albumArtist: artist, playedNames: playedNames)]))
                    .font(AppTypography.metadata).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: Self.lengthWidth, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .opacity(played ? 1 : 0.5)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cycleMark(_ heard: Bool?) -> some View {
        switch heard {
        case true?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).help("Heard this cycle")
        case false?:
            Image(systemName: "circle").foregroundStyle(.secondary).help("Not heard yet this cycle")
        case nil:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// The plays as a number with a small bar before it, on one line, so rows stay tight.
    private func playsCell(_ entry: TopChartEntry?, maxValue: Int) -> some View {
        HStack(spacing: 8) {
            if let entry {
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(2, barLimit * CGFloat(entry.metricValue(for: metric)) / CGFloat(maxValue)), height: 5)
                Text(metric == .scrobbles ? entry.playcount.formatted() : DurationEngine.formatTimeListened(entry.timeListenedSeconds ?? 0))
                    .monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("0").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Playlist

    private var defaultPlaylistName: String {
        let dates = "\(range.from.formatted(date: .abbreviated, time: .omitted)) – \(range.to.formatted(date: .abbreviated, time: .omitted))"
        return "\(artist) – \(album) Tracks (\(dates))"
    }

    /// Only tracks that were played: a track nobody listened to in the period may not even be in the library.
    private var playlistTracks: [AppleMusicPlaylistTrack] {
        visibleRows.compactMap { row in
            guard let entry = row.entry else { return nil }
            let trackArtist = entry.artist ?? artist
            guard !trackArtist.isEmpty else { return nil }
            return AppleMusicPlaylistTrack(artist: trackArtist, track: entry.name, album: entry.album ?? album)
        }
    }

    // MARK: - Loading

    /// Every spelling this album's tracks have in the whole history (not just the period), from the shared history copy.
    private func loadPlayedNames() async {
        let container = modelContext.container
        let artist = artist, album = album
        let names: [String: PlayedName] = (try? await offMain {
            let plays = try await ScrobbleHistoryCache.shared.snapshots(container: container)
            return AlbumTrackRows.playedNames(from: plays, artist: artist, album: album)
        }) ?? [:]
        guard !Task.isCancelled else { return }
        playedNames = names
    }

    private func loadLengths() async {
        if let seedDurations {
            durations = seedDurations
            return
        }
        let keys = Array(Set(lengthKeys.values))
        let container = modelContext.container
        let found = await AlbumTrackDurations.seconds(forKeys: keys, container: container)
        guard !Task.isCancelled else { return }
        durations = found
    }

    private func load() async {
        if let seedEntries {
            entries = seedEntries
            isLoading = false
            return
        }
        let requested = filterID
        isLoading = entries.isEmpty
        errorMessage = nil
        do {
            let loaded = try await TopChartsEngine.fetchScopedRankings(
                container: modelContext.container, durationContext: modelContext, entity: .track, artist: artist, album: album,
                range: range, compareRange: compareRange, metric: metric
            )
            guard !Task.isCancelled, filterID == requested else { return }
            entries = loaded
        } catch {
            guard !Task.isCancelled, filterID == requested else { return }
            errorMessage = "Failed to load: \(error)"
        }
        guard filterID == requested else { return }
        isLoading = false
    }
}
