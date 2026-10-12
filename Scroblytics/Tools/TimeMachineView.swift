import SwiftData
import SwiftUI

enum TimeMachineSort: String, CaseIterable, Codable, Identifiable {
    case mostPlayed
    case mostYears
    case recentlyPlayed
    case artist
    case track

    var id: Self { self }
    var label: String {
        switch self {
        case .mostPlayed: "Most Played"
        case .mostYears: "Most Years"
        case .recentlyPlayed: "Recently Played"
        case .artist: "Artist"
        case .track: "Track"
        }
    }
}

enum TimeMachineTrackFilter: String, CaseIterable, Codable, Identifiable {
    case all
    case loved
    case flagged

    var id: Self { self }
    var label: String {
        switch self {
        case .all: "All Tracks"
        case .loved: "Loved"
        case .flagged: "Flagged"
        }
    }
}

struct TimeMachineView: View {
    struct Options: Codable, Equatable {
        var period = TimeMachinePeriod.day
        var year: Int?
        var sort = TimeMachineSort.mostPlayed
        var minPlays = 1
        var minYears = 1
        var trackFilter = TimeMachineTrackFilter.all
        var perArtist = 0
        var perAlbum = 0
        var rowLimit = 100

        private enum CodingKeys: String, CodingKey {
            case period, year, sort, minPlays, minYears, trackFilter, perArtist, perAlbum, rowLimit, lovedOnly
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            period = try values.decodeIfPresent(TimeMachinePeriod.self, forKey: .period) ?? .day
            year = try values.decodeIfPresent(Int.self, forKey: .year)
            sort = try values.decodeIfPresent(TimeMachineSort.self, forKey: .sort) ?? .mostPlayed
            minPlays = try values.decodeIfPresent(Int.self, forKey: .minPlays) ?? 1
            minYears = try values.decodeIfPresent(Int.self, forKey: .minYears) ?? 1
            if let savedFilter = try values.decodeIfPresent(TimeMachineTrackFilter.self, forKey: .trackFilter) {
                trackFilter = savedFilter
            } else {
                trackFilter = (try values.decodeIfPresent(Bool.self, forKey: .lovedOnly) ?? false) ? .loved : .all
            }
            perArtist = try values.decodeIfPresent(Int.self, forKey: .perArtist) ?? 0
            perAlbum = try values.decodeIfPresent(Int.self, forKey: .perAlbum) ?? 0
            rowLimit = try values.decodeIfPresent(Int.self, forKey: .rowLimit) ?? 100
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(period, forKey: .period)
            try values.encodeIfPresent(year, forKey: .year)
            try values.encode(sort, forKey: .sort)
            try values.encode(minPlays, forKey: .minPlays)
            try values.encode(minYears, forKey: .minYears)
            try values.encode(trackFilter, forKey: .trackFilter)
            try values.encode(perArtist, forKey: .perArtist)
            try values.encode(perAlbum, forKey: .perAlbum)
            try values.encode(rowLimit, forKey: .rowLimit)
        }
    }

    private static let toolId = "onthisday"
    private static let defaults = Options()
    private static let minimumPlayChoices = [1, 2, 3, 5, 10, 20]
    private static let minimumYearChoices = [1, 2, 3, 5, 10]
    private static let groupLimitChoices = [1, 2, 3, 5, 10, 20]
    private static let limits = [25, 50, 100, 250, 500, 0]

    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @Environment(LovedTracksStore.self) private var lovedTracksStore
    @Environment(FlaggedTracksStore.self) private var flaggedTracksStore
    @State private var options = Self.defaults
    @State private var selectedDate = Date()
    @State private var searchText = ""
    @State private var scrobbles: [ScrobbleSnapshot]?
    @State private var result: TimeMachineResult?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var visibleEntries: [OnThisDayEntry] {
        guard let entries = result?.entries else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = entries.filter { entry in
            let matchesSearch = query.isEmpty
                || entry.track.localizedCaseInsensitiveContains(query)
                || entry.artist.localizedCaseInsensitiveContains(query)
                || (entry.album?.localizedCaseInsensitiveContains(query) ?? false)
            let matchesStatus: Bool = switch options.trackFilter {
            case .all: true
            case .loved: lovedTracksStore.isLoved(artist: entry.artist, track: entry.track)
            case .flagged: flaggedTracksStore.isFlagged(artist: entry.artist, track: entry.track)
            }
            let matchesYears = options.year != nil || entry.years.count >= options.minYears
            return matchesSearch && matchesStatus && matchesYears && entry.playcount >= options.minPlays
        }
        let sorted = filtered.sorted(by: isOrderedBefore)
        let diversified = applyingGroupLimits(to: sorted)
        return options.rowLimit == 0 ? diversified : Array(diversified.prefix(options.rowLimit))
    }

    private var yearChoices: [Int] {
        var values = Set(result?.availableYears ?? [])
        if let year = options.year { values.insert(year) }
        return values.sorted(by: >)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Time Machine") { controls }
                if let result, !result.entries.isEmpty { headline(result) }
                actionRow
                content
            }
            .padding(16)
        }
        .navigationTitle("Time Machine")
        .task {
            options = ToolFilterSettingsStore.load(
                Options.self,
                toolId: Self.toolId,
                context: modelContext,
                default: Self.defaults
            )
            await recompute()
        }
        .onChange(of: options) { oldValue, newValue in
            ToolFilterSettingsStore.save(newValue, toolId: Self.toolId, context: modelContext)
            if oldValue.period != newValue.period || oldValue.year != newValue.year {
                Task { await recompute() }
            }
        }
        .onChange(of: selectedDate) { Task { await recompute() } }
        .onReceive(NotificationCenter.default.publisher(for: .weekStartDidChange)) { _ in Task { await recompute() } }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            scrobbles = nil
            Task { await recompute() }
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { controlItems }
            VStack(alignment: .leading, spacing: 10) { controlItems }
        }
    }

    @ViewBuilder
    private var controlItems: some View {
        Picker("Period", selection: $options.period) {
            ForEach(TimeMachinePeriod.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()

        DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
            .fixedSize()

        Picker("Year", selection: $options.year) {
            Text("All years").tag(nil as Int?)
            ForEach(yearChoices, id: \.self) { year in
                Text(String(year)).tag(year as Int?)
            }
        }
        .fixedSize()

        Picker("Sort", selection: $options.sort) {
            ForEach(TimeMachineSort.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()

        Picker("Minimum plays", selection: $options.minPlays) {
            ForEach(Self.minimumPlayChoices, id: \.self) { count in
                Text(count == 1 ? "Any play count" : "\(count)+ plays").tag(count)
            }
        }
        .fixedSize()

        Picker("Minimum years", selection: $options.minYears) {
            ForEach(Self.minimumYearChoices, id: \.self) { count in
                Text(count == 1 ? "Any year count" : "\(count)+ years").tag(count)
            }
        }
        .fixedSize()
        .disabled(options.year != nil)
        .help(options.year == nil ? "Only include tracks heard in at least this many different years." : "Year count is only available when showing All years.")

        Picker("Tracks", selection: $options.trackFilter) {
            ForEach(TimeMachineTrackFilter.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()

        Picker("Per artist", selection: $options.perArtist) {
            Text("No artist limit").tag(0)
            ForEach(Self.groupLimitChoices, id: \.self) { count in
                Text("\(count) per artist").tag(count)
            }
        }
        .fixedSize()
        .help("At most this many tracks from any one artist, keeping the first tracks in the selected sort order.")

        Picker("Per album", selection: $options.perAlbum) {
            Text("No album limit").tag(0)
            ForEach(Self.groupLimitChoices, id: \.self) { count in
                Text("\(count) per album").tag(count)
            }
        }
        .fixedSize()
        .help("At most this many tracks from any one album, keeping the first tracks in the selected sort order.")

        Picker("Limit", selection: $options.rowLimit) {
            ForEach(Self.limits, id: \.self) { limit in
                Text(limit == 0 ? "No Limit" : limit.formatted()).tag(limit)
            }
        }
        .fixedSize()
    }

    private func headline(_ result: TimeMachineResult) -> some View {
        ToolHeadlineCard("FROM YOUR LISTENING HISTORY") {
            Text(headlineText(result))
        }
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                recordCount
                Spacer()
                actions
            }
            VStack(alignment: .leading, spacing: 10) {
                recordCount
                actions
            }
        }
    }

    private var recordCount: some View {
        Text("\(visibleEntries.count.formatted()) of \((result?.entries.count ?? 0).formatted()) tracks")
            .font(AppTypography.metadata.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            TextField("Filter tracks…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
            if !visibleEntries.isEmpty {
                AppleMusicPlaylistExportButton(defaultPlaylistName: playlistName) {
                    visibleEntries.map {
                        AppleMusicPlaylistTrack(artist: $0.artist, track: $0.track, album: $0.album ?? "")
                    }
                }
            }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                .labelStyle(.iconOnly)
                .help("Refresh")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !visibleEntries.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(visibleEntries) { entry in
                    TimeMachineRow(entry: entry) {
                        navigation.goToTrack(
                            TrackIdentity(
                                artist: entry.artist,
                                name: entry.track,
                                album: entry.album,
                                imageURL: entry.imageURL
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.4), lineWidth: 1)
            }
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else if let errorMessage {
            ContentUnavailableView(
                "Couldn't load Time Machine",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if let result, !result.entries.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            ContentUnavailableView(
                "No listening history for this period",
                systemImage: "calendar.badge.clock",
                description: Text("Try another date, a wider period, or All years.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private func applyingGroupLimits(to entries: [OnThisDayEntry]) -> [OnThisDayEntry] {
        guard options.perArtist > 0 || options.perAlbum > 0 else { return entries }
        var artistCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]
        var kept: [OnThisDayEntry] = []
        kept.reserveCapacity(entries.count)

        for entry in entries {
            let artistKey = entry.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let albumKey = entry.album?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if options.perArtist > 0, artistCounts[artistKey, default: 0] >= options.perArtist { continue }
            if options.perAlbum > 0, let albumKey, !albumKey.isEmpty,
               albumCounts[albumKey, default: 0] >= options.perAlbum { continue }

            if options.perArtist > 0 { artistCounts[artistKey, default: 0] += 1 }
            if options.perAlbum > 0, let albumKey, !albumKey.isEmpty {
                albumCounts[albumKey, default: 0] += 1
            }
            kept.append(entry)
        }
        return kept
    }

    private func isOrderedBefore(_ first: OnThisDayEntry, _ second: OnThisDayEntry) -> Bool {
        switch options.sort {
        case .mostPlayed:
            if first.playcount != second.playcount { return first.playcount > second.playcount }
            if first.years.count != second.years.count { return first.years.count > second.years.count }
        case .mostYears:
            if first.years.count != second.years.count { return first.years.count > second.years.count }
            if first.playcount != second.playcount { return first.playcount > second.playcount }
        case .recentlyPlayed:
            if first.lastPlayed != second.lastPlayed { return first.lastPlayed > second.lastPlayed }
        case .artist:
            let artistOrder = first.artist.localizedStandardCompare(second.artist)
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
        case .track:
            let trackOrder = first.track.localizedStandardCompare(second.track)
            if trackOrder != .orderedSame { return trackOrder == .orderedAscending }
        }
        let artistOrder = first.artist.localizedStandardCompare(second.artist)
        if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
        return first.track.localizedStandardCompare(second.track) == .orderedAscending
    }

    private var playlistName: String {
        "Time Machine (\(selectedDate.formatted(date: .abbreviated, time: .omitted)))"
    }

    private func headlineText(_ result: TimeMachineResult) -> String {
        let periodText: String
        switch options.period {
        case .day:
            periodText = selectedDate.formatted(.dateTime.month(.wide).day())
        case .week:
            // The week's first day, per the week-start setting, not the picked date itself.
            let calendar = AppCalendars.listening
            let offset = (calendar.component(.weekday, from: selectedDate) - calendar.firstWeekday + 7) % 7
            let weekStart = calendar.date(byAdding: .day, value: -offset, to: selectedDate) ?? selectedDate
            periodText = "the week of \(weekStart.formatted(date: .abbreviated, time: .omitted))"
        case .month:
            periodText = selectedDate.formatted(.dateTime.month(.wide))
        }

        if let year = options.year {
            return "You scrobbled \(result.matchedScrobbleCount.formatted()) times during \(periodText) in \(year)."
        }
        guard let newest = result.availableYears.first, let oldest = result.availableYears.last else {
            return "No scrobbles during \(periodText)."
        }
        let yearCount = result.availableYears.count
        let span = yearCount == 1 ? String(newest) : "\(oldest)–\(newest)"
        return "You scrobbled \(result.matchedScrobbleCount.formatted()) times during \(periodText) across \(yearCount.formatted()) \(yearCount == 1 ? "year" : "years") (\(span))."
    }

    private func reload() async {
        scrobbles = nil
        await recompute()
    }

    private func recompute() async {
        isLoading = true
        errorMessage = nil
        do {
            let all: [ScrobbleSnapshot]
            if let scrobbles {
                all = scrobbles
            } else {
                let container = modelContainer
                let fetched = try await offMain {
                    try await ScrobbleHistoryCache.shared.snapshots(container: container)
                }
                all = QueryIdentity.canonicalizingArtists(fetched)
                scrobbles = all
            }
            let date = selectedDate
            let period = options.period
            let year = options.year
            result = await Task.detached(priority: .utility) {
                OnThisDayEngine.timeMachine(
                    scrobbles: all,
                    referenceDate: date,
                    period: period,
                    year: year
                )
            }.value
        } catch {
            errorMessage = error.localizedDescription
            result = nil
        }
        isLoading = false
    }
}

private struct TimeMachineRow: View {
    let entry: OnThisDayEntry
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    identity
                    Spacer(minLength: 12)
                    metrics
                }
                VStack(alignment: .leading, spacing: 8) {
                    identity
                    metrics
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .drillDownHighlight()
        .entityContextMenu(
            target: ImageTarget(kind: .track, artist: entry.artist, album: entry.album, track: entry.track),
            currentImageURL: entry.imageURL,
            onOpen: onOpen
        )
        Divider()
    }

    private var identity: some View {
        HStack(spacing: 12) {
            EntityThumbnail(url: entry.imageURL, entity: .track)
                .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.track)
                        .font(AppTypography.contentTitle)
                        .lineLimit(1)
                    TrackLovedIndicator(
                        artist: entry.artist,
                        track: entry.track,
                        initialValue: false,
                        font: AppTypography.metadata
                    )
                }
                Text([entry.artist, entry.album].compactMap { $0 }.joined(separator: " · "))
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var metrics: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(entry.playcount.formatted()) \(entry.playcount == 1 ? "play" : "plays")")
                .font(AppTypography.metadata.monospacedDigit())
                .foregroundStyle(.primary)
            Text(yearSummary)
                .font(AppTypography.compactMetadata.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var yearSummary: String {
        guard entry.years.count > 1 else { return entry.years.first.map(String.init) ?? "" }
        return "\(entry.years.count.formatted()) years · \(entry.years.reversed().map(String.init).joined(separator: ", "))"
    }
}
