import SwiftData
import SwiftUI

struct ChartToppersView: View {
    struct Options: Codable, Equatable {
        var entityRawValue = TopChartsEntity.track.rawValue
        var period = CollagePeriod.year
        var metricRawValue = TopChartsMetric.scrobbles.rawValue
        var yearRange = 0
    }

    private static let toolID = "chartToppers"
    private static let defaults = Options()

    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @State private var options = defaults
    @State private var periods: [ChartTopperPeriod] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoadedOptions = false

    private var entity: TopChartsEntity {
        TopChartsEntity(rawValue: options.entityRawValue) ?? .track
    }

    private var metric: TopChartsMetric {
        TopChartsMetric(rawValue: options.metricRawValue) ?? .scrobbles
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Chart Toppers") {
                    ChartToppersControls(
                        entityRawValue: $options.entityRawValue,
                        period: $options.period,
                        metricRawValue: $options.metricRawValue,
                        yearRange: $options.yearRange,
                        isLoading: isLoading,
                        onRefresh: { Task { await reload() } }
                    )
                }

                ChartToppersIntroduction(entity: entity, period: options.period, metric: metric)

                ChartToppersSummary(
                    periodCount: periods.count,
                    period: options.period,
                    isLoading: isLoading,
                    playlistName: defaultPlaylistName,
                    playlistTracks: playlistTracks
                )

                ChartToppersContent(
                    periods: periods,
                    entity: entity,
                    metric: metric,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    onOpen: open
                )
            }
            .padding(16)
        }
        .navigationTitle("Chart Toppers")
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
        .onChange(of: options) { _, newValue in
            guard hasLoadedOptions else { return }
            ToolFilterSettingsStore.save(newValue, toolId: Self.toolID, context: modelContext)
            Task { await reload() }
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            periods = try await ChartToppersReader(modelContainer: modelContainer).load(
                entity: entity,
                metric: metric,
                period: options.period,
                yearRange: options.period == .year ? options.yearRange : 0
            )
        } catch {
            periods = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var playlistTracks: [AppleMusicPlaylistTrack] {
        var seen = Set<String>()
        return periods.compactMap { $0.entries.first?.exportTrack }.filter { track in
            seen.insert(TextNormalization.lovedKey(artist: track.artist, track: track.track)).inserted
        }
    }

    private var defaultPlaylistName: String {
        let noun = entity == .artist ? "Artists" : entity == .album ? "Albums" : "Tracks"
        return "My #1 \(noun) by \(options.period.rawValue.capitalized)"
    }

    private func open(_ entry: ChartTopperEntry) {
        switch entity {
        case .artist:
            navigation.goToArtist(ArtistIdentity(name: entry.name, imageURL: entry.imageURL))
        case .album:
            navigation.goToAlbum(AlbumIdentity(artist: entry.artist, name: entry.name, imageURL: entry.imageURL))
        case .track:
            navigation.goToTrack(TrackIdentity(
                artist: entry.artist,
                name: entry.name,
                album: entry.album,
                imageURL: entry.imageURL
            ))
        }
    }
}

private struct ChartToppersControls: View {
    @Binding var entityRawValue: String
    @Binding var period: CollagePeriod
    @Binding var metricRawValue: String
    @Binding var yearRange: Int
    let isLoading: Bool
    let onRefresh: () -> Void

    private let yearRanges = [
        (0, "All years"),
        (5, "Last 5 years"),
        (10, "Last 10 years"),
        (20, "Last 20 years"),
        (25, "Last 25 years"),
        (50, "Last 50 years")
    ]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 360, maximum: 520), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            control("Show") {
                Picker("Show", selection: $entityRawValue) {
                    ForEach(TopChartsEntity.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }

            control("Period") {
                Picker("Period", selection: $period) {
                    ForEach(CollagePeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            control("Metric") {
                ChartMetricToggle(metric: Binding(
                    get: { TopChartsMetric(rawValue: metricRawValue) ?? .scrobbles },
                    set: { metricRawValue = $0.rawValue }
                ))
                .frame(maxWidth: 280)
            }

            if period == .year {
                control("Range") {
                    Picker("Range", selection: $yearRange) {
                        ForEach(yearRanges, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
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

private struct ChartToppersIntroduction: View {
    let entity: TopChartsEntity
    let period: CollagePeriod
    let metric: TopChartsMetric

    var body: some View {
        ToolHeadlineCard("RELEASE-DATE RETROSPECTIVE") {
            Text("Your top \(noun) from every release \(period.rawValue), ranked by \(metric.displayName.lowercased()). Expand a period to see the complete top 10. Music with no known release date is left out.")
        }
    }

    private var noun: String {
        switch entity {
        case .artist: "artist"
        case .album: "album"
        case .track: "track"
        }
    }
}

private struct ChartToppersSummary: View {
    let periodCount: Int
    let period: CollagePeriod
    let isLoading: Bool
    let playlistName: String
    let playlistTracks: [AppleMusicPlaylistTrack]

    var body: some View {
        HStack(spacing: 12) {
            Text("\(periodCount.formatted()) \(period.rawValue)\(periodCount == 1 ? "" : "s")")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if !playlistTracks.isEmpty {
                AppleMusicPlaylistExportButton(defaultPlaylistName: playlistName) {
                    playlistTracks
                }
            }
        }
    }
}

private struct ChartToppersContent: View {
    let periods: [ChartTopperPeriod]
    let entity: TopChartsEntity
    let metric: TopChartsMetric
    let isLoading: Bool
    let errorMessage: String?
    let onOpen: (ChartTopperEntry) -> Void

    var body: some View {
        if isLoading, periods.isEmpty {
            ProgressView("Analyzing release periods…")
                .frame(maxWidth: .infinity, minHeight: 280)
        } else if let errorMessage, periods.isEmpty {
            ContentUnavailableView(
                "Couldn’t analyze chart toppers",
                systemImage: "trophy",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, minHeight: 280)
        } else if periods.isEmpty {
            ContentUnavailableView(
                "No chart toppers yet",
                systemImage: "trophy",
                description: Text("Release dates are still filling in. Resolve missing dates in Missing Data, then try again.")
            )
            .frame(maxWidth: .infinity, minHeight: 280)
        } else {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(periods) { period in
                    ChartTopperPeriodSection(
                        period: period,
                        entity: entity,
                        metric: metric,
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

private struct ChartTopperPeriodSection: View {
    let period: ChartTopperPeriod
    let entity: TopChartsEntity
    let metric: TopChartsMetric
    let onOpen: (ChartTopperEntry) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(period.entries.dropFirst()) { entry in
                    ChartTopperEntryRow(
                        entry: entry,
                        entity: entity,
                        metric: metric,
                        isWinner: false,
                        onOpen: onOpen
                    )
                }

                if period.entries.count == 1 {
                    Text("No other \(pluralNoun) released in \(period.label).")
                        .font(AppTypography.supporting)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 78)
                        .padding(.vertical, 10)
                }
            }
            .padding(.bottom, 6)
        } label: {
            if let winner = period.entries.first {
                ChartTopperWinnerRow(
                    periodLabel: period.label,
                    entry: winner,
                    entity: entity,
                    metric: metric,
                    onOpen: onOpen
                )
            }
        }
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.55)
        }
    }

    private var pluralNoun: String {
        switch entity {
        case .artist: "artists"
        case .album: "albums"
        case .track: "tracks"
        }
    }
}

private struct ChartTopperWinnerRow: View {
    let periodLabel: String
    let entry: ChartTopperEntry
    let entity: TopChartsEntity
    let metric: TopChartsMetric
    let onOpen: (ChartTopperEntry) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(periodLabel)
                .font(AppTypography.contentTitle.weight(.semibold).monospacedDigit())
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)

            EntityThumbnail(url: entry.imageURL, entity: entity)
                .frame(width: 44, height: 44)

            ChartTopperEntryTitle(entry: entry, entity: entity, prominent: true)

            Spacer(minLength: 8)

            ChartTopperTrackMarkers(entry: entry, entity: entity)
            Text(ChartToppersFormatting.stat(entry.metricValue, metric: metric))
                .font(AppTypography.tableValue)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .entityContextMenu(
            target: ChartToppersFormatting.imageTarget(entry: entry, entity: entity),
            currentImageURL: entry.imageURL,
            onOpen: { onOpen(entry) }
        )
    }
}

private struct ChartTopperEntryRow: View {
    let entry: ChartTopperEntry
    let entity: TopChartsEntity
    let metric: TopChartsMetric
    let isWinner: Bool
    let onOpen: (ChartTopperEntry) -> Void

    var body: some View {
        Button { onOpen(entry) } label: {
            HStack(spacing: 10) {
                Text(entry.rank.formatted())
                    .font(AppTypography.supporting.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 24)

                EntityThumbnail(url: entry.imageURL, entity: entity)
                    .frame(width: 36, height: 36)

                ChartTopperEntryTitle(entry: entry, entity: entity, prominent: false)

                Spacer(minLength: 8)

                ChartTopperTrackMarkers(entry: entry, entity: entity)
                Text(ChartToppersFormatting.stat(entry.metricValue, metric: metric))
                    .font(AppTypography.tablePreviousValue)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.leading, 104)
            .padding(.trailing, 2)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .entityContextMenu(
            target: ChartToppersFormatting.imageTarget(entry: entry, entity: entity),
            currentImageURL: entry.imageURL,
            onOpen: { onOpen(entry) }
        )
    }
}

private struct ChartTopperEntryTitle: View {
    let entry: ChartTopperEntry
    let entity: TopChartsEntity
    let prominent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
                .font(prominent ? AppTypography.contentTitle : AppTypography.metadata)
                .lineLimit(1)
            if entity != .artist {
                Text(entry.artist)
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChartTopperTrackMarkers: View {
    let entry: ChartTopperEntry
    let entity: TopChartsEntity

    var body: some View {
        if entity == .track {
            TrackLovedIndicator(
                artist: entry.artist,
                track: entry.name,
                initialValue: entry.loved,
                font: AppTypography.supporting
            )
        }
    }
}

@MainActor
private enum ChartToppersFormatting {
    static func stat(_ value: Int, metric: TopChartsMetric) -> String {
        metric == .scrobbles
            ? "\(value.formatted()) \(value == 1 ? "play" : "plays")"
            : DurationEngine.formatTimeListened(value)
    }

    static func imageTarget(entry: ChartTopperEntry, entity: TopChartsEntity) -> ImageTarget {
        switch entity {
        case .artist:
            ImageTarget(kind: .artist, artist: entry.name, album: nil, track: nil)
        case .album:
            ImageTarget(kind: .album, artist: entry.artist, album: entry.name, track: nil)
        case .track:
            ImageTarget(kind: .track, artist: entry.artist, album: entry.album, track: entry.name)
        }
    }
}
