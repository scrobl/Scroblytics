import SwiftUI
import SwiftData

/// "Fading Favorites": tracks that were once in heavy rotation and have since gone quiet — three ways to
/// look at that (biggest peak, steepest fade, or the blended "worth revisiting" rediscovery score), not a
/// single fixed ranking.
struct FadingFavoritesView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    /// Opens Query on `spec` (the "Advanced" escape hatch); `detail` is the breadcrumb tooltip, the third
    /// value defaults the Save As sheet if the user saves it from there.
    let openQuery: (QuerySpec, String, String?) -> Void

    /// This tool's own options, persisted via `ToolFilterSetting`. Deliberately no window-length control —
    /// the fixed 90-day default (the Field Registry's own `fadingWindow` default) is the whole point of
    /// staying "near-zero required controls," matching the Overview card's own no-adjustable-threshold feel.
    struct Options: Codable, Equatable {
        var minPeak: Int
        var sort: FadingFavoritesSort
        var rowLimit: Int

        init(minPeak: Int, sort: FadingFavoritesSort, rowLimit: Int) {
            self.minPeak = minPeak
            self.sort = sort
            self.rowLimit = rowLimit
        }

        private enum CodingKeys: String, CodingKey { case minPeak, sort, rowLimit }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            minPeak = try values.decode(Int.self, forKey: .minPeak)
            sort = try values.decode(FadingFavoritesSort.self, forKey: .sort)
            rowLimit = try values.decodeIfPresent(Int.self, forKey: .rowLimit) ?? 50
        }
    }
    private static let toolId = "fadingFavorites"
    private static let windowDays = 90
    private static let defaultOptions = Options(minPeak: FadingFavoritesEngine.minPeak, sort: .rediscoveryScore, rowLimit: 50)
    private static let minPeakChoices = [5, 10, 20, 30, 40, 50]
    private static let rowLimitChoices = [10, 25, 50, 100, 250, 500, 0]

    @Environment(\.modelContext) private var modelContext
    @State private var options = FadingFavoritesView.defaultOptions
    @State private var scrobbles: [ScrobbleSnapshot]?
    /// The expensive, sort-independent per-track metrics — cached across sort/limit changes so those only
    /// re-order and re-slice this array instead of re-running the whole-library scan. Only a `minPeak`
    /// change (or a scrobble sync, or the first load) invalidates and recomputes it.
    @State private var candidates: [FadingFavoriteCandidate]?
    @State private var data: FadingFavorites?
    @State private var imageURLs: [QueryEntityID: String] = [:]
    @State private var albums: [QueryEntityID: String] = [:]
    /// True while EITHER the expensive candidate scan or the cheap re-sort/slice is in flight. Shown as a
    /// small inline spinner even when `data` already has rows, so switching sort never looks like nothing
    /// is happening.
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Fading Favorites") { controls }
                if let data, let headline = data.headline {
                    headlineCallout(headline, data)
                }
                actionRow(data)
                if let data, !data.rows.isEmpty {
                    list(data)
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                } else if let errorMessage {
                    ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ContentUnavailableView(
                        "Nothing’s faded yet", systemImage: "waveform.path.ecg",
                        description: Text("Try a lower minimum peak, or check back once you’ve got more listening history.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .navigationTitle("Fading Favorites")
        .task {
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Self.defaultOptions)
            await recomputeCandidates()
        }
        .onChange(of: options) { oldValue, newValue in
            ToolFilterSettingsStore.save(newValue, toolId: Self.toolId, context: modelContext)
            // Only a minimum-peak change touches which tracks qualify at all — that needs the expensive
            // whole-library rescan. Sort and row limit just reorder/reslice what's already cached.
            if oldValue.minPeak != newValue.minPeak {
                Task { await recomputeCandidates() }
            } else {
                Task { await applySortAndSlice() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            scrobbles = nil
            candidates = nil
            Task { await recomputeCandidates() }
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { pickers }
            VStack(alignment: .leading, spacing: 10) { pickers }
        }
    }

    @ViewBuilder
    private var pickers: some View {
        Picker("Sort", selection: $options.sort) {
            ForEach(FadingFavoritesSort.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        Picker("Minimum peak", selection: $options.minPeak) {
            ForEach(Self.minPeakChoices, id: \.self) { Text("\($0)+ at peak").tag($0) }
        }
        .fixedSize()
        .help("A track has to have been a real favorite at its peak to count — anything below 5 isn’t a meaningful peak, it’s noise.")
        Picker("Limit", selection: $options.rowLimit) {
            ForEach(Self.rowLimitChoices, id: \.self) { limit in
                Text(limit == 0 ? "No Limit" : limit.formatted()).tag(limit)
            }
        }
        .fixedSize()
        if isLoading {
            ProgressView().controlSize(.small)
        }
    }

    private func headlineCallout(_ row: FadingFavoriteRow, _ data: FadingFavorites) -> some View {
        ToolHeadlineCard(eyebrow(for: data.sort)) {
            Text(text(for: row, sort: data.sort))
        }
    }

    private func eyebrow(for sort: FadingFavoritesSort) -> LocalizedStringKey {
        switch sort {
        case .peak: "Your biggest peak"
        case .fade: "Gone quietest"
        case .rediscoveryScore: "Your best rediscovery"
        }
    }

    private func text(for row: FadingFavoriteRow, sort: FadingFavoritesSort) -> String {
        let period = peakPeriodShortLabel(start: row.peakWindowStart, end: row.peakWindowEnd)
        switch sort {
        case .peak:
            return "\(row.title) — \(row.peakPlays.formatted()) plays at its peak (\(period)), now down to \(row.recentPlays.formatted())"
        case .fade:
            let percent = (row.decayRatio * 100).formatted(.number.precision(.fractionLength(0)))
            return "\(row.title) — once \(row.peakPlays.formatted()) plays at its peak (\(period)), now at \(percent)% of that"
        case .rediscoveryScore:
            let score = row.rediscoveryScore.formatted(.number.precision(.fractionLength(1)))
            return "\(row.title) — rediscovery score \(score) (\(row.peakPlays.formatted()) at its peak in \(period), gone quiet since)"
        }
    }

    private func list(_ data: FadingFavorites) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(data.rows) { row in
                Row(row: row, imageURL: imageURLs[row.id], album: albums[row.id]) {
                    navigation.goToTrack(TrackIdentity(artist: row.artist, name: row.title, album: albums[row.id], imageURL: imageURLs[row.id]))
                }
            }
        }
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private func actionRow(_ data: FadingFavorites?) -> some View {
        HStack {
            if let data {
                Text("\(data.rows.count.formatted()) \(data.rows.count == 1 ? "record" : "records")")
                    .font(AppTypography.metadata.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let data, !data.rows.isEmpty {
                AppleMusicPlaylistExportButton(
                    defaultPlaylistName: "Fading Favorites",
                    tracks: { playlistTracks(for: data.rows) }
                )
            }
            Button("Advanced") {
                let spec = FadingFavoritesEngineTool.spec(windowDays: Self.windowDays, minPeak: options.minPeak, sort: options.sort)
                let window = data?.windowDays ?? FadingFavoritesEngineTool.snappedWindow(forDays: Self.windowDays)
                openQuery(spec, "Fading Favorites · \(window) days, \(options.minPeak)+ at peak, \(options.sort.label.lowercased())", "Fading Favorites (from Tool)")
            }
            .buttonStyle(.bordered)
            .help("Open the equivalent conditions in Query, ready to add more.")
        }
    }

    private func playlistTracks(for rows: [FadingFavoriteRow]) -> [AppleMusicPlaylistTrack] {
        rows.map { row in
            AppleMusicPlaylistTrack(artist: row.artist, track: row.title, album: albums[row.id, default: ""])
        }
    }

    /// The expensive path: reload scrobbles if needed, then rescan the whole library for the current
    /// `minPeak`. Triggered by the first load, a `minPeak` change, or a scrobble sync — never by switching
    /// sort or the row limit alone.
    private func recomputeCandidates() async {
        isLoading = true
        errorMessage = nil
        do {
            let all: [ScrobbleSnapshot]
            if let scrobbles { all = scrobbles } else {
                let container = modelContainer
                let fetched = try await ScrobbleHistoryCache.shared.snapshots(container: container)
                all = QueryIdentity.canonicalizingArtists(fetched)
                scrobbles = all
            }
            let minPeak = options.minPeak
            let windowDays = Self.windowDays
            let result = await Task.detached(priority: .utility) {
                FadingFavoritesEngineTool.computeCandidates(scrobbles: all, windowDays: windowDays, minPeak: minPeak)
            }.value
            candidates = result?.candidates ?? []
            await applySortAndSlice()
        } catch {
            errorMessage = "\(error)"
            candidates = nil
            data = nil
            isLoading = false
        }
    }

    /// The cheap path: re-order the already-computed candidates, slice to the row limit, and only THEN
    /// build sparklines and resolve artwork — for whatever's actually going to be visible, not the whole
    /// qualifying set. No whole-library rescan.
    private func applySortAndSlice() async {
        guard let candidatesSnapshot = candidates else { isLoading = false; return }
        isLoading = true
        let sort = options.sort
        let minPeak = options.minPeak
        let rowLimit = options.rowLimit
        let windowDays = Self.windowDays
        let scrobblesSnapshot = scrobbles ?? []
        let sliced = await Task.detached(priority: .utility) {
            let ordered = FadingFavoritesEngineTool.sorted(candidatesSnapshot, by: sort)
            let limited = rowLimit == 0 ? ordered : Array(ordered.prefix(rowLimit))
            return FadingFavoritesEngineTool.rows(for: limited, scrobbles: scrobblesSnapshot)
        }.value
        if sliced.isEmpty {
            data = nil
        } else {
            data = FadingFavorites(rows: sliced, windowDays: windowDays, minPeak: minPeak, sort: sort)
            applyArtwork(to: sliced, from: scrobblesSnapshot)
        }
        isLoading = false
    }

    private func applyArtwork(to rows: [FadingFavoriteRow], from scrobbles: [ScrobbleSnapshot]) {
        let lookup = (try? ImageResolutionEngine.imageLookup(context: modelContext)) ?? [:]
        var newImageURLs: [QueryEntityID: String] = [:]
        var newAlbums: [QueryEntityID: String] = [:]
        for row in rows {
            let resolved = ImageResolutionEngine.resolvedTrackArtwork(artist: row.artist, track: row.title, scrobbles: scrobbles, lookup: lookup)
            newAlbums[row.id] = resolved.album ?? ""
            newImageURLs[row.id] = resolved.imageURL
        }
        albums = newAlbums
        imageURLs = newImageURLs
    }
}

/// "Mar '23" if the peak window's start and end fall in the same month, else "Jan–Mar '23" — compact for
/// inline display; `.help()` on the row shows the exact dates via `TrendsDrill.rangeLabel`.
private func peakPeriodShortLabel(start: Date, end: Date) -> String {
    let monthYear = Date.FormatStyle.dateTime.month(.abbreviated).year(.twoDigits)
    if Calendar.current.isDate(start, equalTo: end, toGranularity: .month) {
        return end.formatted(monthYear)
    }
    let month = Date.FormatStyle.dateTime.month(.abbreviated)
    return "\(start.formatted(month))–\(end.formatted(monthYear))"
}

private struct Row: View {
    let row: FadingFavoriteRow
    let imageURL: String?
    let album: String?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                EntityThumbnail(url: imageURL, entity: .track)
                    .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.title).font(AppTypography.contentTitle).lineLimit(1)
                        TrackLovedIndicator(artist: row.artist, track: row.title, initialValue: false, font: AppTypography.metadata)
                    }
                    Text(row.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                TrendSparkline(buckets: row.sparkline)
                    .frame(minWidth: 90, idealWidth: 180, maxWidth: 180, minHeight: 28, maxHeight: 28)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(row.peakPlays.formatted()) at peak").font(AppTypography.metadata.monospacedDigit())
                        .help("Peaked \(TrendsDrill.rangeLabel(from: row.peakWindowStart, to: row.peakWindowEnd))")
                    Text("\(row.recentPlays.formatted()) recently · \((row.decayRatio * 100).formatted(.number.precision(.fractionLength(0))))%")
                        .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                    Text("peaked \(peakPeriodShortLabel(start: row.peakWindowStart, end: row.peakWindowEnd)) · score \(row.rediscoveryScore.formatted(.number.precision(.fractionLength(1))))")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        .help("Rediscovery score: peak plays × how much it’s faded — \(row.peakPlays.formatted()) × (1 − \((row.decayRatio).formatted(.number.precision(.fractionLength(3))))) = \(row.rediscoveryScore.formatted(.number.precision(.fractionLength(1))))")
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .drillDownHighlight()
        .entityContextMenu(
            target: ImageTarget(kind: .track, artist: row.artist, album: album, track: row.title),
            currentImageURL: imageURL, onOpen: onOpen
        )
        Divider()
    }
}
