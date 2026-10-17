import SwiftData
import SwiftUI

struct MultiAlbumTracksView: View {
    struct Options: Codable, Equatable {
        var matchMode = MultiAlbumTrackMatchMode.exact
        var relatedAlbumsOnly = false
        var includesSingleOnly = false
        var minimumAlbums = 2
        var sort = MultiAlbumTracksSort.mostPlayed
    }

    private static let toolID = "multiAlbumTracks"
    private static let defaults = Options()

    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @State private var options = defaults
    @State private var searchText = ""
    @State private var groups: [MultiAlbumTrackGroup] = []
    @State private var visibleGroups: [MultiAlbumTrackGroup] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoadedOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Multi-Album Tracks") {
                    MultiAlbumTracksControls(
                        searchText: $searchText,
                        matchMode: $options.matchMode,
                        sort: $options.sort,
                        isLoading: isLoading,
                        onRefresh: { Task { await reload() } }
                    )
                }

                ToolHeadlineCard("DUPLICATE RELEASE FINDER") {
                    Text("Find a song by the same artist across multiple album names. Exact mode keeps title variants separate; Edition-aware mode safely joins remasters, mono or stereo labels, and similar edition notes.")
                }

                MultiAlbumTracksFilters(
                    relatedAlbumsOnly: $options.relatedAlbumsOnly,
                    includesSingleOnly: $options.includesSingleOnly,
                    minimumAlbums: $options.minimumAlbums
                )

                MultiAlbumTracksSummary(
                    groupCount: visibleGroups.count,
                    occurrenceCount: visibleGroups.reduce(0) { $0 + $1.albums.count },
                    isLoading: isLoading
                )

                MultiAlbumTracksContent(
                    groups: visibleGroups,
                    matchMode: options.matchMode,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    onOpen: open
                )
            }
            .padding(16)
        }
        .navigationTitle("Multi-Album Tracks")
        .task {
            options = ToolFilterSettingsStore.load(
                Options.self,
                toolId: Self.toolID,
                context: modelContext,
                default: Self.defaults
            )
            await reload()
            hasLoadedOptions = true
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .scrobbleSyncDidComplete) {
                await reload()
            }
        }
        .onChange(of: searchText) { _, _ in
            applyFilters()
        }
        .onChange(of: options) { oldValue, newValue in
            guard hasLoadedOptions else { return }
            ToolFilterSettingsStore.save(newValue, toolId: Self.toolID, context: modelContext)
            if oldValue.matchMode != newValue.matchMode {
                Task { await reload() }
            } else {
                applyFilters()
            }
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = nil
        // The closure must touch no view state (that would pull it onto the main actor, and the whole read with it): copies first.
        let container = modelContainer
        let mode = options.matchMode
        do {
            groups = try await offMain {
                try await MultiAlbumTracksReader(modelContainer: container).load(mode: mode)
            }
            applyFilters()
        } catch {
            groups = []
            visibleGroups = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func applyFilters() {
        visibleGroups = MultiAlbumTracksEngine.filteredAndSorted(
            groups,
            searchText: searchText,
            minimumAlbums: options.minimumAlbums,
            relatedAlbumsOnly: options.relatedAlbumsOnly,
            includesSingleOnly: options.includesSingleOnly,
            sort: options.sort
        )
    }

    private func open(_ group: MultiAlbumTrackGroup, occurrence: MultiAlbumTrackOccurrence?) {
        navigation.goToTrack(TrackIdentity(
            artist: group.artist,
            name: occurrence?.trackTitle ?? group.trackTitle,
            album: occurrence?.album,
            imageURL: occurrence?.imageURL
        ))
    }
}

private struct MultiAlbumTracksControls: View {
    @Binding var searchText: String
    @Binding var matchMode: MultiAlbumTrackMatchMode
    @Binding var sort: MultiAlbumTracksSort
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        TextField("Filter multi-album tracks…", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 190, maxWidth: 520)

        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260, maximum: 440), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            control("Match") {
                Picker("Match", selection: $matchMode) {
                    ForEach(MultiAlbumTrackMatchMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            control("Sort") {
                Picker("Sort", selection: $sort) {
                    ForEach(MultiAlbumTracksSort.allCases) { sort in
                        Text(sort.label).tag(sort)
                    }
                }
            }
        }

        Button(action: onRefresh) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(isLoading)
    }

    private func control<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MultiAlbumTracksFilters: View {
    @Binding var relatedAlbumsOnly: Bool
    @Binding var includesSingleOnly: Bool
    @Binding var minimumAlbums: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filters")
                .font(AppTypography.contentTitle)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260, maximum: 440), spacing: 16)],
                alignment: .leading,
                spacing: 12
            ) {
                Toggle("Related album editions only", isOn: $relatedAlbumsOnly)
                    .help("Only show tracks whose album names resolve to the same underlying album title.")

                Toggle("Includes a single", isOn: $includesSingleOnly)
                    .help("Only show tracks with at least one album name containing “single”.")

                HStack(spacing: 10) {
                    Text("Minimum albums")
                    Picker("Minimum albums", selection: $minimumAlbums) {
                        ForEach(2...5, id: \.self) { count in
                            Text(count == 5 ? "5+" : count.formatted()).tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct MultiAlbumTracksSummary: View {
    let groupCount: Int
    let occurrenceCount: Int
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(groupCount.formatted()) tracks · \(occurrenceCount.formatted()) album appearances")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private struct MultiAlbumTracksContent: View {
    let groups: [MultiAlbumTrackGroup]
    let matchMode: MultiAlbumTrackMatchMode
    let isLoading: Bool
    let errorMessage: String?
    let onOpen: (MultiAlbumTrackGroup, MultiAlbumTrackOccurrence?) -> Void

    var body: some View {
        if isLoading, groups.isEmpty {
            ProgressView("Finding tracks on multiple albums…")
                .frame(maxWidth: .infinity, minHeight: 280)
        } else if let errorMessage, groups.isEmpty {
            ContentUnavailableView(
                "Couldn’t analyze multi-album tracks",
                systemImage: "square.stack.3d.up",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, minHeight: 280)
        } else if groups.isEmpty {
            ContentUnavailableView(
                "No multi-album tracks found",
                systemImage: "square.stack.3d.up",
                description: Text("Try lowering the minimum album count, turning off a filter, or using Edition-aware matching.")
            )
            .frame(maxWidth: .infinity, minHeight: 280)
        } else {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(groups) { group in
                    MultiAlbumTrackSection(
                        group: group,
                        showRawTitles: matchMode == .editionAware,
                        onOpen: onOpen
                    )
                }
            }
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.45), lineWidth: 1)
            }
        }
    }
}

private struct MultiAlbumTrackSection: View {
    let group: MultiAlbumTrackGroup
    let showRawTitles: Bool
    let onOpen: (MultiAlbumTrackGroup, MultiAlbumTrackOccurrence?) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(group.albums) { occurrence in
                    MultiAlbumOccurrenceRow(
                        group: group,
                        occurrence: occurrence,
                        showRawTitle: showRawTitles,
                        onOpen: onOpen
                    )
                }
            }
            .padding(.bottom, 6)
        } label: {
            MultiAlbumGroupLabel(group: group)
                .contentShape(Rectangle())
                .entityContextMenu(
                    target: ImageTarget(
                        kind: .track,
                        artist: group.artist,
                        album: nil,
                        track: group.trackTitle
                    ),
                    currentImageURL: group.albums.first?.imageURL,
                    onOpen: { onOpen(group, nil) }
                )
        }
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.55)
        }
    }
}

private struct MultiAlbumGroupLabel: View {
    let group: MultiAlbumTrackGroup

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 8)
                MultiAlbumTrackMarkers(group: group, occurrence: nil)
                stats
            }

            VStack(alignment: .leading, spacing: 6) {
                title
                HStack(spacing: 10) {
                    MultiAlbumTrackMarkers(group: group, occurrence: nil)
                    stats
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.trailing, 4)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.trackTitle)
                .font(AppTypography.contentTitle)
                .lineLimit(1)
            Text(group.artist)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var stats: some View {
        Text("\(group.albums.count.formatted()) albums · \(group.playCount.formatted()) plays")
            .font(AppTypography.tableValue)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct MultiAlbumOccurrenceRow: View {
    let group: MultiAlbumTrackGroup
    let occurrence: MultiAlbumTrackOccurrence
    let showRawTitle: Bool
    let onOpen: (MultiAlbumTrackGroup, MultiAlbumTrackOccurrence?) -> Void

    var body: some View {
        Button {
            onOpen(group, occurrence)
        } label: {
            HStack(spacing: 10) {
                EntityThumbnail(url: occurrence.imageURL, entity: .album)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(occurrence.album)
                        .font(AppTypography.entitySubtitle.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if showRawTitle, occurrence.trackTitle != group.trackTitle || occurrence.titleVariants.count > 1 {
                        Text(occurrence.titleVariants.formatted(.list(type: .and)))
                            .font(AppTypography.supporting)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
                MultiAlbumTrackMarkers(group: group, occurrence: occurrence)
                Text("\(occurrence.playCount.formatted()) plays")
                    .font(AppTypography.tablePreviousValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 24)
            .padding(.trailing, 4)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .entityContextMenu(
            target: ImageTarget(
                kind: .track,
                artist: group.artist,
                album: occurrence.album,
                track: occurrence.trackTitle
            ),
            currentImageURL: occurrence.imageURL,
            onOpen: { onOpen(group, occurrence) }
        )
    }
}

private struct MultiAlbumTrackMarkers: View {
    @Environment(LovedTracksStore.self) private var lovedTracksStore
    @Environment(FlaggedTracksStore.self) private var flaggedTracksStore

    let group: MultiAlbumTrackGroup
    let occurrence: MultiAlbumTrackOccurrence?

    private var titles: [String] {
        occurrence?.titleVariants ?? group.titleVariants
    }

    private var isLoved: Bool {
        titles.contains { lovedTracksStore.isLoved(artist: group.artist, track: $0) }
    }

    private var isFlagged: Bool {
        if let occurrence {
            return titles.contains {
                flaggedTracksStore.isFlagged(artist: group.artist, track: $0, album: occurrence.album)
                    || flaggedTracksStore.isFlagged(artist: group.artist, track: $0, album: nil)
            }
        }
        return titles.contains { flaggedTracksStore.isFlagged(artist: group.artist, track: $0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            if isLoved {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Loved")
            }
            if isFlagged {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Flagged")
            }
        }
        .font(AppTypography.supporting)
    }
}
