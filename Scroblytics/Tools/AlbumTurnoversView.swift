import SwiftData
import SwiftUI

struct AlbumTurnoversView: View {
    struct Options: Codable, Equatable {
        var sort: Sort = .fastest
        var candidateLimit = 150
        var includeCompilations = false
        var showNeverTurnedOver = false
        var onlyCloseToTurnover = false
    }

    enum Sort: String, Codable, CaseIterable, Identifiable {
        case fastest
        case slowest
        case most
        case fewest
        case recent
        case stale

        var id: Self { self }

        var label: String {
            switch self {
            case .fastest: "Fastest turnover"
            case .slowest: "Slowest turnover"
            case .most: "Most turnovers"
            case .fewest: "Fewest turnovers"
            case .recent: "Most recent turnovers"
            case .stale: "Least recent turnovers"
            }
        }
    }

    private static let toolID = "albumTurnovers"
    private static let defaultOptions = Options()
    private static let candidateLimits = [50, 100, 150, 200, 250, 0]

    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @State private var options = defaultOptions
    @State private var turnovers: [AlbumTurnoverEngine.AlbumTurnover] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoadedOptions = false

    private var sortedTurnovers: [AlbumTurnoverEngine.AlbumTurnover] {
        Self.sorted(turnovers, by: options.sort)
    }

    private var visibleTurnovers: [AlbumTurnoverEngine.AlbumTurnover] {
        sortedTurnovers.filter { turnover in
            if options.onlyCloseToTurnover {
                let remaining = turnover.inProgressTotal - turnover.inProgressHeard
                return remaining == 1 || remaining == 2
            }
            return options.showNeverTurnedOver || turnover.cyclesCompleted > 0
        }
    }

    private var closeCount: Int {
        turnovers.count { turnover in
            let remaining = turnover.inProgressTotal - turnover.inProgressHeard
            return remaining == 1 || remaining == 2
        }
    }

    private var neverCount: Int {
        turnovers.count { $0.cyclesCompleted == 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Album Turnovers") {
                    AlbumTurnoversHeaderControls(
                        sort: $options.sort,
                        candidateLimit: $options.candidateLimit,
                        isLoading: isLoading,
                        onRefresh: { Task { await reload(using: options) } }
                    )
                }

                ToolHeadlineCard("FULL-ALBUM LISTENING") {
                    Text("See how often you complete an album’s full tracklist and what remains in the cycle you’re listening through now.")
                }

                AlbumTurnoversFilters(
                    includeCompilations: $options.includeCompilations,
                    showNeverTurnedOver: $options.showNeverTurnedOver,
                    onlyCloseToTurnover: $options.onlyCloseToTurnover,
                    neverCount: neverCount,
                    closeCount: closeCount
                )

                AlbumTurnoversStatus(
                    visibleCount: visibleTurnovers.count,
                    candidateLimit: options.candidateLimit,
                    sort: options.sort,
                    onlyCloseToTurnover: options.onlyCloseToTurnover,
                    isLoading: isLoading
                )

                content
            }
            .padding(16)
        }
        .navigationTitle("Album Turnovers")
        .task {
            let loaded = ToolFilterSettingsStore.load(
                Options.self,
                toolId: Self.toolID,
                context: modelContext,
                default: Self.defaultOptions
            )
            options = loaded
            await reload(using: loaded)
            hasLoadedOptions = true
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .scrobbleSyncDidComplete) {
                await reload(using: options)
            }
        }
        .onChange(of: options) { oldValue, newValue in
            guard hasLoadedOptions else { return }
            ToolFilterSettingsStore.save(newValue, toolId: Self.toolID, context: modelContext)
            if oldValue.includeCompilations != newValue.includeCompilations
                || oldValue.candidateLimit != newValue.candidateLimit {
                Task { await reload(using: newValue) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, turnovers.isEmpty {
            ProgressView("Analyzing album cycles…")
                .frame(maxWidth: .infinity, minHeight: 260)
        } else if let errorMessage, turnovers.isEmpty {
            ContentUnavailableView(
                "Couldn’t analyze albums",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else if visibleTurnovers.isEmpty {
            ContentUnavailableView(
                options.onlyCloseToTurnover ? "No albums close to turnover" : "No completed album cycles yet",
                systemImage: "repeat",
                description: Text(emptyDescription)
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(visibleTurnovers, id: \.groupKey) { turnover in
                    AlbumTurnoverRow(turnover: turnover) {
                        navigation.goToAlbum(AlbumIdentity(artist: turnover.artist, name: turnover.album))
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.4), lineWidth: 1)
            }
        }
    }

    private var emptyDescription: String {
        if options.onlyCloseToTurnover {
            return "No album is one or two tracks from completing its current cycle."
        }
        if !options.showNeverTurnedOver, neverCount > 0 {
            return "Turn on “Show albums that haven’t turned over yet” to include in-progress albums."
        }
        return "No albums have enough plays across a full tracklist to measure turnover. Keep listening, or include compilation albums."
    }

    private func reload(using requestedOptions: Options) async {
        isLoading = true
        errorMessage = nil
        guard let credentials = LastfmCredentialsStore.load() else {
            turnovers = []
            errorMessage = "Connect Last.fm in Settings to look up album tracklists."
            isLoading = false
            return
        }

        do {
            let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
            let limit = requestedOptions.candidateLimit == 0 ? Int.max : requestedOptions.candidateLimit
            let loaded = try await AlbumTurnoverEngine.fetchRankings(
                context: modelContext,
                client: client,
                sort: .fastest,
                includeCompilations: requestedOptions.includeCompilations,
                limit: limit
            )
            guard requestedOptions.includeCompilations == options.includeCompilations,
                  requestedOptions.candidateLimit == options.candidateLimit else { return }
            turnovers = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private static func sorted(
        _ values: [AlbumTurnoverEngine.AlbumTurnover],
        by sort: Sort
    ) -> [AlbumTurnoverEngine.AlbumTurnover] {
        values.sorted { first, second in
            switch sort {
            case .most:
                if first.cyclesCompleted != second.cyclesCompleted {
                    return first.cyclesCompleted > second.cyclesCompleted
                }
            case .fewest:
                if first.cyclesCompleted != second.cyclesCompleted {
                    return first.cyclesCompleted < second.cyclesCompleted
                }
            case .recent:
                if first.lastTurnoverDate != second.lastTurnoverDate {
                    return (first.lastTurnoverDate ?? .distantPast) > (second.lastTurnoverDate ?? .distantPast)
                }
            case .stale:
                if first.lastTurnoverDate != second.lastTurnoverDate {
                    if first.lastTurnoverDate == nil { return false }
                    if second.lastTurnoverDate == nil { return true }
                    return first.lastTurnoverDate! < second.lastTurnoverDate!
                }
            case .fastest:
                if first.rateDays != second.rateDays {
                    if first.rateDays == nil { return false }
                    if second.rateDays == nil { return true }
                    return first.rateDays! < second.rateDays!
                }
            case .slowest:
                if first.rateDays != second.rateDays {
                    if first.rateDays == nil { return true }
                    if second.rateDays == nil { return false }
                    return first.rateDays! > second.rateDays!
                }
            }
            return first.album.localizedCaseInsensitiveCompare(second.album) == .orderedAscending
        }
    }
}

private struct AlbumTurnoversHeaderControls: View {
    @Binding var sort: AlbumTurnoversView.Sort
    @Binding var candidateLimit: Int
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { controls }
            VStack(alignment: .leading, spacing: 8) { controls }
        }
    }

    @ViewBuilder
    private var controls: some View {
        Picker("Sort", selection: $sort) {
            ForEach(AlbumTurnoversView.Sort.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .fixedSize()

        Picker("Albums to evaluate", selection: $candidateLimit) {
            Text("Top 50 by plays").tag(50)
            Text("Top 100 by plays").tag(100)
            Text("Top 150 by plays").tag(150)
            Text("Top 200 by plays").tag(200)
            Text("Top 250 by plays").tag(250)
            Text("All albums").tag(0)
        }
        .fixedSize()

        Button("Rescan Albums", systemImage: "arrow.clockwise", action: onRefresh)
            .labelStyle(.iconOnly)
            .disabled(isLoading)
            .help("Rescan albums")
    }
}

private struct AlbumTurnoversFilters: View {
    @Binding var includeCompilations: Bool
    @Binding var showNeverTurnedOver: Bool
    @Binding var onlyCloseToTurnover: Bool
    let neverCount: Int
    let closeCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterRow(
                title: "Include compilation albums",
                detail: "Various-artists and soundtrack albums are excluded by default.",
                value: $includeCompilations
            )
            Divider()
            filterRow(
                title: "Show albums that haven’t turned over yet",
                detail: "Include albums with no completed cycle\(neverCount > 0 ? " (\(neverCount.formatted()))" : "").",
                value: $showNeverTurnedOver
            )
            Divider()
            filterRow(
                title: "Only show albums close to turnover",
                detail: "Albums one or two tracks from completing their current cycle\(closeCount > 0 ? " (\(closeCount.formatted()))" : "").",
                value: $onlyCloseToTurnover
            )
        }
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func filterRow(
        title: LocalizedStringKey,
        detail: String,
        value: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppTypography.contentTitle)
                Text(detail)
                    .font(AppTypography.compactMetadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: value)
                .labelsHidden()
        }
        .padding(.vertical, 12)
    }
}

private struct AlbumTurnoversStatus: View {
    let visibleCount: Int
    let candidateLimit: Int
    let sort: AlbumTurnoversView.Sort
    let onlyCloseToTurnover: Bool
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(visibleCount.formatted()) \(visibleCount == 1 ? "record" : "records")")
                .font(AppTypography.metadata.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(onlyCloseToTurnover ? "Close to turnover" : sort.label)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
            if candidateLimit > 0 {
                Text("· Top \(candidateLimit.formatted()) albums by plays evaluated")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
            }
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
    }
}

private struct AlbumTurnoverRow: View {
    let turnover: AlbumTurnoverEngine.AlbumTurnover
    let onOpen: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                ViewThatFits(in: .horizontal) {
                    regularHeader
                    compactHeader
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .entityContextMenu(
                target: ImageTarget(kind: .album, artist: turnover.artist, album: turnover.album, track: nil),
                currentImageURL: turnover.imageURL,
                onOpen: onOpen
            )

            if expanded {
                AlbumTurnoverTrackList(turnover: turnover)
                    .padding(.leading, 56)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }

            Divider()
        }
    }

    private var regularHeader: some View {
        HStack(spacing: 12) {
            chevron
            artwork
            identity
            Spacer(minLength: 16)
            metrics
        }
    }

    private var compactHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            chevron
            artwork
            VStack(alignment: .leading, spacing: 8) {
                identity
                metrics
            }
            Spacer(minLength: 0)
        }
    }

    private var chevron: some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(AppTypography.supportingDense)
            .foregroundStyle(.secondary)
            .frame(width: 12)
    }

    private var artwork: some View {
        EntityThumbnail(url: turnover.imageURL, entity: .album)
            .frame(width: 42, height: 42)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(turnover.album)
                    .font(AppTypography.contentTitle)
                    .lineLimit(1)
                PopularityMarker(entity: .album, name: turnover.album, artist: turnover.artist, font: AppTypography.metadata)
                if turnover.ambiguous {
                    matchBadge("Uncertain")
                } else if turnover.noCanonicalMatch {
                    matchBadge("No catalog match")
                }
            }
            Text("\(turnover.artist) · \(progressText)")
                .font(AppTypography.compactMetadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var metrics: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(AlbumTurnoverEngine.formatTurnoverRate(turnover.rateDays))
                .font(AppTypography.contentTitle)
                .lineLimit(1)
            Text(turnover.cyclesCompleted > 0
                 ? "\(turnover.cyclesCompleted.formatted()) full \(turnover.cyclesCompleted == 1 ? "cycle" : "cycles")"
                 : "\(turnover.trackCount.formatted()) tracks")
                .font(AppTypography.compactMetadata.monospacedDigit())
                .foregroundStyle(.secondary)
            if let last = turnover.lastTurnoverDate {
                Text("Last completed \(last.formatted(date: .abbreviated, time: .omitted))")
                    .font(AppTypography.compactMetadata)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var progressText: String {
        if turnover.inProgressHeard == 0, turnover.cyclesCompleted > 0 {
            return "New cycle just starting"
        }
        let basis = turnover.basis == .canonical ? "canonical tracklist" : "tracks you’ve played"
        return "\(turnover.inProgressHeard) of \(turnover.inProgressTotal) heard · \(basis)"
    }

    private func matchBadge(_ label: LocalizedStringKey) -> some View {
        Label(label, systemImage: "exclamationmark.triangle.fill")
            .font(AppTypography.supportingDense)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: Capsule())
    }
}

private struct AlbumTurnoverTrackList: View {
    let turnover: AlbumTurnoverEngine.AlbumTurnover

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(turnover.inProgressHeard) of \(turnover.inProgressTotal) heard this cycle")
                .font(AppTypography.compactMetadata)
                .foregroundStyle(.tertiary)

            ForEach(Array(turnover.tracks.enumerated()), id: \.offset) { index, track in
                HStack(spacing: 7) {
                    if turnover.basis == .canonical {
                        Text("\(index + 1)")
                            .font(AppTypography.supportingDense.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .trailing)
                    }
                    Image(systemName: track.heardThisCycle ? "checkmark.circle.fill" : "circle")
                        .font(AppTypography.supportingDense)
                        .foregroundStyle(track.heardThisCycle ? Color.green : Color.secondary)
                    Text(track.title)
                        .font(AppTypography.compactMetadata)
                        .foregroundStyle(track.heardThisCycle ? .primary : .secondary)
                        .lineLimit(1)
                    // Draws the loved heart, the flag and the "not in your library" mark together, so no separate flag indicator here.
                    TrackLovedIndicator(
                        artist: turnover.artist,
                        track: track.title,
                        initialValue: false,
                        font: AppTypography.supportingDense
                    )
                    PopularityMarker(
                        entity: .track,
                        name: track.title,
                        artist: turnover.artist,
                        font: AppTypography.supportingDense
                    )
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .entityContextMenu(
                    target: ImageTarget(
                        kind: .track,
                        artist: turnover.artist,
                        album: turnover.album,
                        track: track.title
                    ),
                    currentImageURL: turnover.imageURL
                )
            }
        }
    }
}
