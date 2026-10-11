import SwiftUI
import SwiftData

/// "Most Recent, Most Often": tracks discovered within a recency window that are already being played a
/// lot — ranked by velocity (plays per day since discovery) by default, a genuinely different ordering
/// from raw play count that surfaces a sharp, fast-burst favorite over one with more total plays spread
/// thin over a longer window.
struct MostRecentMostOftenView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    /// Opens Query on `spec` (the "Advanced" escape hatch); `detail` is the breadcrumb tooltip, the third
    /// value defaults the Save As sheet if the user saves it from there.
    let openQuery: (QuerySpec, String, String?) -> Void

    /// The simple UI's own options — persisted via the shared `ToolFilterSetting` model (same shape the
    /// backup format already round-trips), keyed by the tool id.
    struct Options: Codable, Equatable {
        var windowDays: Int
        var minPlays: Int
        var sort: MostRecentMostOftenSort
        var rowLimit: Int

        init(windowDays: Int, minPlays: Int, sort: MostRecentMostOftenSort, rowLimit: Int) {
            self.windowDays = windowDays
            self.minPlays = minPlays
            self.sort = sort
            self.rowLimit = rowLimit
        }

        private enum CodingKeys: String, CodingKey { case windowDays, minPlays, sort, rowLimit }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            windowDays = try values.decode(Int.self, forKey: .windowDays)
            minPlays = try values.decode(Int.self, forKey: .minPlays)
            sort = try values.decode(MostRecentMostOftenSort.self, forKey: .sort)
            rowLimit = try values.decodeIfPresent(Int.self, forKey: .rowLimit) ?? 50
        }
    }
    private static let toolId = "recentmostoften"
    private static let defaultOptions = Options(windowDays: 90, minPlays: 5, sort: .velocity, rowLimit: 50)

    @Environment(\.modelContext) private var modelContext
    @State private var options = MostRecentMostOftenView.defaultOptions
    private var windowDays: Int { options.windowDays }
    private var minPlays: Int { options.minPlays }
    private var sort: MostRecentMostOftenSort { options.sort }

    @State private var scrobbles: [ScrobbleSnapshot]?
    @State private var data: MostRecentMostOften?
    @State private var imageURLs: [QueryEntityID: String] = [:]
    @State private var albums: [QueryEntityID: String] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?

    private static let windowChoices = [30, 60, 90, 180, 365]
    private static let minPlaysChoices = [1, 3, 5, 10, 20]
    private static let rowLimitChoices = [10, 25, 50, 100, 250, 500, 0]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Most Recent, Most Often") {
                    controls
                }
                if let data, let headline = data.headline {
                    headlineCallout(headline)
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
                        "Nothing qualifies yet", systemImage: "bolt.slash",
                        description: Text("Try a wider recency window or a lower minimum play count.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .navigationTitle("Most Recent, Most Often")
        .task {
            // Sequential, not reactive: loads once, then runs the first computation with those options —
            // no race with the onChange below, which only ever reacts to a LATER, user-driven edit.
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Self.defaultOptions)
            await recompute()
        }
        .onChange(of: options) { _, newValue in
            ToolFilterSettingsStore.save(newValue, toolId: Self.toolId, context: modelContext)
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
        Picker("Discovered within", selection: $options.windowDays) {
            ForEach(Self.windowChoices, id: \.self) { Text("Discovered in last \($0) days").tag($0) }
        }
        .fixedSize()
        Picker("Minimum plays", selection: $options.minPlays) {
            ForEach(Self.minPlaysChoices, id: \.self) { Text("\($0)+ plays").tag($0) }
        }
        .fixedSize()
        Picker("Sort", selection: $options.sort) {
            ForEach(MostRecentMostOftenSort.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        Picker("Limit", selection: $options.rowLimit) {
            ForEach(Self.rowLimitChoices, id: \.self) { limit in
                Text(limit == 0 ? "No Limit" : limit.formatted()).tag(limit)
            }
        }
        .fixedSize()
    }

    private func headlineCallout(_ row: MostRecentMostOftenRow) -> some View {
        ToolHeadlineCard("Your fastest new obsession") {
            Text("\(row.title) — \(row.plays.formatted()) plays in \(row.daysSinceFirstPlayed.formatted()) day\(row.daysSinceFirstPlayed == 1 ? "" : "s")")
        }
    }

    private func list(_ data: MostRecentMostOften) -> some View {
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

    private func actionRow(_ data: MostRecentMostOften?) -> some View {
        HStack {
            if let data {
                Text("\(data.rows.count.formatted()) \(data.rows.count == 1 ? "record" : "records")")
                    .font(AppTypography.metadata.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let data, !data.rows.isEmpty {
                AppleMusicPlaylistExportButton(
                    defaultPlaylistName: "Most Recent, Most Often",
                    tracks: { playlistTracks(for: data.rows) }
                )
            }
            Button("Advanced") {
                let spec = MostRecentMostOftenEngine.spec(recencyWindowDays: windowDays, minPlays: minPlays)
                openQuery(spec, "Most Recent, Most Often · discovered in last \(windowDays) days, \(minPlays)+ plays",
                          "Most Recent, Most Often (from Tool)")
            }
            .buttonStyle(.bordered)
            .help("Open the equivalent conditions in Query, ready to add more.")
        }
    }

    private func playlistTracks(for rows: [MostRecentMostOftenRow]) -> [AppleMusicPlaylistTrack] {
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
            }
            let (windowDays, minPlays, sort) = (self.windowDays, self.minPlays, self.sort)
            let computed = await Task.detached(priority: .utility) {
                MostRecentMostOftenEngine.compute(scrobbles: all, recencyWindowDays: windowDays, minPlays: minPlays, sort: sort)
            }.value
            if let computed {
                let rows = options.rowLimit == 0 ? computed.rows : Array(computed.rows.prefix(options.rowLimit))
                let limited = MostRecentMostOften(
                    rows: rows,
                    recencyWindowDays: computed.recencyWindowDays,
                    minPlays: computed.minPlays,
                    sort: computed.sort
                )
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

    private func applyArtwork(to rows: [MostRecentMostOftenRow], from scrobbles: [ScrobbleSnapshot]) {
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
    let row: MostRecentMostOftenRow
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
                    Text("\(row.plays.formatted()) plays").font(AppTypography.metadata.monospacedDigit())
                    Text("\(row.velocity.formatted(.number.precision(.fractionLength(1))))/day · discovered \(row.daysSinceFirstPlayed.formatted())d ago")
                        .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
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
