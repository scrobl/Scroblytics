import SwiftUI
import SwiftData

/// "The Climb": which tracks moved the most in the all-time ranking over the app-wide Chart comparison
/// period — either climbed (played before the window, ranked higher now) or debuted as a Hot Shot (no
/// plays before the window, now in the library's top quarter).
struct TheClimbView: View {
    let modelContainer: ModelContainer
    let settings: ChartDateSettings
    let navigation: DetailNavigationCoordinator
    /// Opens Query on `spec` (the "Advanced" escape hatch); `detail` is the breadcrumb tooltip, the third
    /// value defaults the Save As sheet if the user saves it from there.
    let openQuery: (QuerySpec, String, String?) -> Void

    /// This tool's own options — persisted via `ToolFilterSetting`. The comparison window itself is
    /// NOT one of them: it comes from the shared, app-wide `ChartDateSettings.compareMode`, not a
    /// per-tool copy. No sort choice — the list is always ranked by climb score, one scale for both
    /// climbers and Hot Shot Debuts (see `TheClimb.swift`); a debut is called out by its badge instead.
    struct Options: Codable, Equatable {
        var minPlaysNow: Int
        var rowLimit: Int
        /// The "Top N" gate: a track only qualifies if it's inside this all-time rank tier now and
        /// wasn't at the window's start — this is what keeps the list to genuinely competitive movement,
        /// not long-tail noise where a single play swings rank by hundreds of places.
        var topN: Int

        init(minPlaysNow: Int, rowLimit: Int, topN: Int) {
            self.minPlaysNow = minPlaysNow
            self.rowLimit = rowLimit
            self.topN = topN
        }

        private enum CodingKeys: String, CodingKey { case minPlaysNow, rowLimit, topN }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            minPlaysNow = try values.decode(Int.self, forKey: .minPlaysNow)
            rowLimit = try values.decodeIfPresent(Int.self, forKey: .rowLimit) ?? 50
            topN = try values.decodeIfPresent(Int.self, forKey: .topN) ?? 500
        }
    }
    private static let toolId = "climbers"
    private static let defaultOptions = Options(minPlaysNow: 5, rowLimit: 50, topN: 500)
    private static let minPlaysChoices = [0, 1, 3, 5, 10, 20]
    private static let rowLimitChoices = [10, 25, 50, 100, 250, 500, 0]
    private static let topNChoices = [100, 250, 500, 1000, 2000, 5000]

    @Environment(\.modelContext) private var modelContext
    @State private var options = TheClimbView.defaultOptions
    @State private var scrobbles: [ScrobbleSnapshot]?
    @State private var oldestScrobbleDate: Date?
    @State private var data: TheClimb?
    @State private var imageURLs: [QueryEntityID: String] = [:]
    @State private var albums: [QueryEntityID: String] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var rangeOptions: [DateRangeOption] { DateRangePresets.build(oldestScrobbleDate: oldestScrobbleDate) }
    private var currentRange: DateRange { (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).range() }
    /// How many days ago to compare against: the Chart comparison control's own preset day-count, or —
    /// for a custom date — the actual span to it. Snapped to the nearest climbing-field window
    /// (`TheClimbEngine.snappedWindow`) before it ever reaches the engine.
    private var compareDays: Int {
        if let days = settings.compareMode.days { return days }
        guard let customDate = settings.compareCustomDate else { return 90 }
        return max(1, Int(Date().timeIntervalSince(customDate) / 86400))
    }
    private struct ComputeKey: Equatable { let compareDays: Int; let options: Options }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("The Climb") { controls }
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
                        "Nothing qualifies yet", systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Try a wider comparison period or a lower minimum play count.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .navigationTitle("The Climb")
        .task {
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Self.defaultOptions)
            await recompute()
        }
        .onChange(of: ComputeKey(compareDays: compareDays, options: options)) { _, _ in
            ToolFilterSettingsStore.save(options, toolId: Self.toolId, context: modelContext)
            Task { await recompute() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            scrobbles = nil
            Task { await recompute() }
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
        ChartComparisonControl(settings: settings, currentRange: currentRange)
        Text("Climbing metrics update in steps — comparing to \(TheClimbEngine.snappedWindow(forDays: compareDays)) days ago.")
            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        Picker("Top", selection: $options.topN) {
            ForEach(Self.topNChoices, id: \.self) { Text("Top \($0.formatted())").tag($0) }
        }
        .fixedSize()
        .help("Only tracks that have broken into this all-time rank tier — and weren't in it at the window's start — qualify. This is what keeps the list to genuinely competitive movement instead of long-tail noise.")
        Picker("Minimum plays now", selection: $options.minPlaysNow) {
            ForEach(Self.minPlaysChoices, id: \.self) { Text($0 == 0 ? "No minimum" : "\($0)+ plays").tag($0) }
        }
        .fixedSize()
        .help("Leave out tracks with very few recent plays — a barely-played track can swing wildly in rank on a single new play.")
        Picker("Limit", selection: $options.rowLimit) {
            ForEach(Self.rowLimitChoices, id: \.self) { limit in
                Text(limit == 0 ? "No Limit" : limit.formatted()).tag(limit)
            }
        }
        .fixedSize()
    }

    private func headlineCallout(_ row: TheClimbRow, _ data: TheClimb) -> some View {
        ToolHeadlineCard(row.previousRank == nil ? "Your biggest debut" : "Your biggest climb") {
            Text(row.previousRank == nil
                 ? "\(row.title) — debuted at #\(row.currentRank.formatted()), inside the Top \(data.topN)"
                 : "\(row.title) — broke into the Top \(data.topN), up \((row.rankChange ?? 0).formatted()) spots in the last \(data.windowDays) days")
        }
    }

    private func list(_ data: TheClimb) -> some View {
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

    private func actionRow(_ data: TheClimb?) -> some View {
        HStack {
            if let data {
                Text("\(data.rows.count.formatted()) \(data.rows.count == 1 ? "record" : "records")")
                    .font(AppTypography.metadata.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let data, !data.rows.isEmpty {
                AppleMusicPlaylistExportButton(
                    defaultPlaylistName: "The Climb",
                    tracks: { playlistTracks(for: data.rows) }
                )
            }
            Button("Advanced") {
                let spec = TheClimbEngine.spec(compareDays: compareDays, minPlaysNow: options.minPlaysNow, topN: options.topN)
                let window = data?.windowDays ?? TheClimbEngine.snappedWindow(forDays: compareDays)
                openQuery(spec, "The Climb · Top \(options.topN), \(window) days, \(options.minPlaysNow)+ plays", "The Climb (from Tool)")
            }
            .buttonStyle(.bordered)
            .help("Open the equivalent conditions in Query, ready to add more.")
        }
    }

    private func playlistTracks(for rows: [TheClimbRow]) -> [AppleMusicPlaylistTrack] {
        rows.map { row in
            AppleMusicPlaylistTrack(artist: row.artist, track: row.title, album: albums[row.id, default: ""])
        }
    }

    private func recompute() async {
        isLoading = true
        errorMessage = nil
        do {
            let all: [ScrobbleSnapshot]
            if let scrobbles { all = scrobbles } else {
                let container = modelContainer
                let fetched = try await offMain { try await ScrobbleSnapshotReader(modelContainer: container).fetchSortedSnapshots() }
                all = QueryIdentity.canonicalizingArtists(fetched)
                scrobbles = all
                oldestScrobbleDate = all.first?.playedAt
            }
            let (compareDays, opts) = (self.compareDays, self.options)
            let computed = await Task.detached(priority: .utility) {
                TheClimbEngine.compute(scrobbles: all, compareDays: compareDays, minPlaysNow: opts.minPlaysNow, topN: opts.topN)
            }.value
            if let computed {
                let rows = options.rowLimit == 0 ? computed.rows : Array(computed.rows.prefix(options.rowLimit))
                let limited = TheClimb(rows: rows, windowDays: computed.windowDays, minPlaysNow: computed.minPlaysNow, topN: computed.topN)
                data = limited
                applyArtwork(to: rows, from: all)
            } else {
                data = nil
            }
        } catch {
            errorMessage = "\(error)"
        }
        isLoading = false
    }

    private func applyArtwork(to rows: [TheClimbRow], from scrobbles: [ScrobbleSnapshot]) {
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

private struct Row: View {
    let row: TheClimbRow
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
                        if row.isBreakout {
                            Text("Just broke out")
                                .font(AppTypography.denseBadge).foregroundStyle(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .help("Most of this climb happened very recently, not spread evenly across the whole comparison window.")
                        }
                    }
                    Text(row.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                RankTrajectorySparkline(trajectory: row.trajectory)
                    .frame(minWidth: 90, idealWidth: 180, maxWidth: 180, minHeight: 28, maxHeight: 28)
                RankChangeBadge(rank: row.currentRank, previousRank: row.previousRank, hasCompareRange: true, showDelta: true, newLabel: "Hot Shot Debut", newColor: .purple)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("#\(row.currentRank.formatted())").font(AppTypography.metadata.monospacedDigit())
                    Text("\(row.recentPlays.formatted()) recent plays").font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
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

/// A minimal rank-over-time line: lower rank (better) plots higher. Checkpoints with no value yet
/// (not played by that point) leave a gap rather than a false zero.
private struct RankTrajectorySparkline: View {
    let trajectory: [Int?]

    var body: some View {
        GeometryReader { geo in
            let known = trajectory.compactMap { $0 }
            if known.count < 2 {
                Color.clear
            } else {
                let maxRank = Double(known.max() ?? 1), minRank = Double(known.min() ?? 1)
                let span = max(1, maxRank - minRank)
                let stepX = trajectory.count > 1 ? geo.size.width / CGFloat(trajectory.count - 1) : 0
                let points: [CGPoint?] = trajectory.enumerated().map { index, rank in
                    guard let rank else { return nil }
                    // Inverted: a lower (better) rank draws higher on the sparkline.
                    let y = geo.size.height * CGFloat((Double(rank) - minRank) / span)
                    return CGPoint(x: CGFloat(index) * stepX, y: y)
                }
                Path { path in
                    var started = false
                    for point in points {
                        guard let point else { started = false; continue }
                        if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                    }
                }
                .stroke(Color.green, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let last = points.last ?? nil {
                    Circle().fill(Color.green).frame(width: 5, height: 5).position(last)
                }
            }
        }
    }
}
