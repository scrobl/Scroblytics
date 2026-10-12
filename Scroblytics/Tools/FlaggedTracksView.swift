import SwiftData
import SwiftUI

struct FlaggedTracksView: View {
    struct Options: Codable, Equatable {
        var sort = FlaggedTracksSort.recentlyFlagged
        var rowLimit = 50
        var lovedOnly = false
    }

    private static let toolId = "flagged"
    private static let defaults = Options()
    private static let limits = [10, 25, 50, 100, 250, 500, 0]

    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(FlaggedTracksStore.self) private var flaggedTracksStore
    @Environment(LovedTracksStore.self) private var lovedTracksStore
    @State private var options = Self.defaults
    @State private var rows: [FlaggedTrackRow] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isConfirmingClear = false
    @State private var errorMessage: String?

    private var visibleRows: [FlaggedTrackRow] {
        let filtered = rows.filter {
            (searchText.isEmpty
                || $0.track.localizedCaseInsensitiveContains(searchText)
                || $0.artist.localizedCaseInsensitiveContains(searchText)
                || ($0.album?.localizedCaseInsensitiveContains(searchText) ?? false))
                && (!options.lovedOnly || lovedTracksStore.isLoved(artist: $0.artist, track: $0.track))
        }
        let sorted = FlaggedTracksEngine.sorted(filtered, by: options.sort)
        return options.rowLimit == 0 ? sorted : Array(sorted.prefix(options.rowLimit))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Flagged Tracks") { controls }
                ToolHeadlineCard("YOUR HAND-PICKED COLLECTION") {
                    Text("Right-click any track and choose Flag Track to save it here for filtering, sorting, and export.")
                }
                actionRow
                content
            }
            .padding(16)
        }
        .navigationTitle("Flagged Tracks")
        .task {
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Self.defaults)
            await reload()
        }
        .onChange(of: options) { _, value in
            ToolFilterSettingsStore.save(value, toolId: Self.toolId, context: modelContext)
        }
        .onChange(of: flaggedTracksStore.revision) { Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { _ in Task { await reload() } }
        .confirmationDialog("Clear all flagged tracks?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear All", role: .destructive, action: clearAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every track from Flagged Tracks. This cannot be undone.")
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { pickers }
            VStack(alignment: .leading, spacing: 10) { pickers }
        }
    }

    @ViewBuilder private var pickers: some View {
        TextField("Filter flagged tracks…", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 190)
        Picker("Sort", selection: $options.sort) {
            ForEach(FlaggedTracksSort.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
        Picker("Limit", selection: $options.rowLimit) {
            ForEach(Self.limits, id: \.self) { Text($0 == 0 ? "No Limit" : $0.formatted()).tag($0) }
        }
        .fixedSize()
        Toggle("Loved only", isOn: $options.lovedOnly).toggleStyle(.checkbox).fixedSize()
    }

    @ViewBuilder private var content: some View {
        if !visibleRows.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(visibleRows) { row in
                    FlaggedTrackListRow(
                        row: row,
                        onOpen: { navigation.goToTrack(TrackIdentity(artist: row.artist, name: row.track, album: row.album, imageURL: row.imageURL)) },
                        onRemove: { remove(row) }
                    )
                }
            }
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else if let errorMessage {
            ContentUnavailableView("Couldn't load flagged tracks", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            ContentUnavailableView("No flagged tracks yet", systemImage: "flag", description: Text("Right-click a track anywhere in Scroblytics and choose Flag Track."))
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private var actionRow: some View {
        HStack {
            Text("\(visibleRows.count.formatted()) of \(rows.count.formatted()) flagged tracks")
                .font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if !visibleRows.isEmpty {
                AppleMusicPlaylistExportButton(defaultPlaylistName: "Flagged Tracks") {
                    visibleRows.map { AppleMusicPlaylistTrack(artist: $0.artist, track: $0.track, album: $0.album ?? "") }
                }
            }
            Button("Clear All", role: .destructive) { isConfirmingClear = true }.disabled(rows.isEmpty)
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                .labelStyle(.iconOnly).help("Refresh")
        }
    }

    private func reload() async {
        isLoading = true
        await flaggedTracksStore.load(container: modelContainer, force: true)
        do {
            let scrobbles = try await ScrobbleHistoryCache.shared.snapshots(container: modelContainer)
            let flags = flaggedTracksStore.snapshots
            let computedRows = await Task.detached(priority: .utility) {
                FlaggedTracksEngine.rows(flags: flags, scrobbles: scrobbles)
            }.value
            let imageLookup = try ImageResolutionEngine.imageLookup(context: modelContext)
            rows = resolvedArtworkRows(computedRows, scrobbles: scrobbles, lookup: imageLookup)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    private func resolvedArtworkRows(
        _ rows: [FlaggedTrackRow],
        scrobbles: [ScrobbleSnapshot],
        lookup: [String: String]
    ) -> [FlaggedTrackRow] {
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        return rows.map { row in
            let fallback = TextNormalization.firstNonPlaceholderImage(
                scrobbles.lazy.filter { scrobble in
                    normalized(scrobble.artistName) == normalized(row.artist)
                        && normalized(scrobble.trackName) == normalized(row.track)
                        && row.album.map { album in normalized(album) == normalized(scrobble.albumName) } ?? true
                }.map(\.imageURL)
            )
            let target = ImageTarget(
                kind: .track,
                artist: row.artist,
                album: row.album,
                track: row.track
            )
            return FlaggedTrackRow(
                id: row.id,
                artist: row.artist,
                track: row.track,
                album: row.album,
                flaggedAt: row.flaggedAt,
                playCount: row.playCount,
                lastPlayed: row.lastPlayed,
                imageURL: ImageResolutionEngine.effectiveImageURL(
                    for: target,
                    lookup: lookup,
                    fallbackURL: fallback
                )
            )
        }
    }

    private func remove(_ row: FlaggedTrackRow) {
        do { try flaggedTracksStore.remove(context: modelContext, id: row.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func clearAll() {
        do { try flaggedTracksStore.removeAll(context: modelContext) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct FlaggedTrackListRow: View {
    let row: FlaggedTrackRow
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                EntityThumbnail(url: row.imageURL, entity: .track)
                    .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.track).font(AppTypography.contentTitle).lineLimit(1)
                        TrackLovedIndicator(artist: row.artist, track: row.track, initialValue: false, font: AppTypography.metadata)
                    }
                    Text([row.artist, row.album].compactMap { $0 }.joined(separator: " · "))
                        .font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(row.playCount.formatted()) plays").font(AppTypography.metadata.monospacedDigit())
                    Text(row.lastPlayed.map { "Last played \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Not in listening history")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
                Button("Remove Flag", systemImage: "xmark", action: onRemove)
                    .buttonStyle(.borderless).labelStyle(.iconOnly).help("Remove from Flagged Tracks")
            }
            .padding(.vertical, 10).padding(.horizontal, 4).contentShape(Rectangle())
        }
        .drillDownHighlight()
        .entityContextMenu(
            target: ImageTarget(kind: .track, artist: row.artist, album: row.album, track: row.track),
            currentImageURL: row.imageURL,
            onOpen: onOpen
        )
        Divider()
    }
}
