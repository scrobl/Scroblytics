import SwiftUI
import SwiftData
import Charts

enum TrendsFocus: String, Sendable {
    case listening
    case longTail
    case topTags
}

/// Trends: how listening changes over time, grouped by the question each chart answers. Every chart is built on
/// the same engines and data the other pages use, and clicking it opens Query on exactly what was clicked, with
/// a breadcrumb back (Trends › Query › Artist › Album › Track).
struct TrendsView: View {
    let modelContainer: ModelContainer
    @Bindable var settings: ChartDateSettings
    @Bindable var trends: TrendsSettings
    let isActive: Bool
    @Binding var overviewFocus: TrendsFocus?
    /// Opens Query on `spec`; the string says what was clicked (it becomes the breadcrumb's tooltip).
    let openQuery: (QuerySpec, String) -> Void

    @State private var scrobbles: [ScrobbleSnapshot]?
    @State private var hasAnyPlaysInRange: Bool?
    @State private var volumeInputs: TrendsVolumeChart.Inputs?
    @State private var heatmapInputs: TrendsHeatmapChart.Inputs?
    @State private var tagsInputs: TrendsTagsChart.Inputs?
    @State private var discoveryInputs: TrendsDiscoveryChart.Inputs?
    @State private var canonicalScrobbles: [ScrobbleSnapshot]?
    @State private var querySnapshots: QuerySnapshots?
    @State private var longTailInputs: TrendsLongTailChart.Inputs?
    @State private var rankBumpInputs: TrendsRankBumpChart.Inputs?
    @State private var decadeInputs: TrendsDecadeRiverChart.Inputs?
    @State private var loyaltyInputs: TrendsLoyaltyChart.Inputs?
    @State private var flowInputs: TrendsFlowChart.Inputs?
    @State private var navigation = DetailNavigationCoordinator(origin: .trends)
    @State private var dataVersion = 0
    @State private var oldestScrobbleDate: Date?
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var needsReload = false
    @State private var latestRequestID = UUID()
    @State private var reloadDebounceTask: Task<Void, Never>?
    @State private var lastFullReloadAt = Date.distantPast
    @State private var backgroundDataIsNewer = false
    @State private var trailingRefreshTask: Task<Void, Never>?

    private var rangeOptions: [DateRangeOption] { DateRangePresets.build(oldestScrobbleDate: oldestScrobbleDate) }
    /// What a chart's shared card says it covers.
    private var shareInfo: TrendsShareInfo {
        let range = currentRange
        let period = (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).label
        let compare = trends.resolve(for: range).map { "Compared with " + TrendsDrill.rangeLabel(from: $0.from, to: $0.to) }
        return TrendsShareInfo(period: period, compare: compare)
    }

    private var currentRange: DateRange { (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).range() }

    var body: some View {
        NavigationStack(path: Binding(get: { navigation.path }, set: { navigation.path = $0 })) {
            page
                .partialDataNote()
                .navigationTitle("Trends")
                .navigationDestination(for: ArtistIdentity.self) { ArtistDetailView(identity: $0, settings: settings, navigation: navigation) }
                .navigationDestination(for: AlbumIdentity.self) { AlbumDetailView(identity: $0, settings: settings, navigation: navigation) }
                .navigationDestination(for: TrackIdentity.self) { TrackDetailView(identity: $0, settings: settings, navigation: navigation) }
        }
    }

    /// Opens an artist, album or track's own page, with a "Trends ›" breadcrumb back.
    private func openEntity(_ item: LoyaltyItem) {
        switch item.id.target {
        case .artist: navigation.goToArtist(ArtistIdentity(name: item.id.artist))
        case .album: navigation.goToAlbum(AlbumIdentity(artist: item.id.artist, name: item.id.name))
        case .track: navigation.goToTrack(TrackIdentity(artist: item.id.artist, name: item.id.name))
        }
    }

    /// The page is split into four groups, one shown at a time: it keeps each screen short, and only the charts on
    /// screen are computed, so opening Trends does the work of one group rather than of all ten charts.
    private enum Group: String, CaseIterable, Identifiable {
        case listening = "Listening", taste = "Taste & eras", habits = "Habits", sequence = "Rankings & flow"
        var id: String { rawValue }
    }
    @AppStorage("trends.group") private var groupRaw = Group.listening.rawValue
    private var group: Group { Group(rawValue: groupRaw) ?? .listening }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageSettingsHeader("Trends") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            DateRangeMenu(settings: settings, rangeOptions: rangeOptions)
                            Divider().frame(height: 22)
                            TrendsCompareControl(settings: trends, currentRange: currentRange)
                            Spacer(minLength: 0)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            DateRangeMenu(settings: settings, rangeOptions: rangeOptions)
                            TrendsCompareControl(settings: trends, currentRange: currentRange)
                        }
                    }
                }
                Picker("Show", selection: $groupRaw) {
                    ForEach(Group.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Trends is split into four groups so each screen stays short and only what you’re looking at is calculated.")
                if let errorMessage, hasAnyPlaysInRange == nil {
                    ContentUnavailableView("Failed to load Trends", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if let hasAnyPlaysInRange {
                    if !hasAnyPlaysInRange {
                        HistoryEmptyState {
                            ContentUnavailableView("No listening in this period", systemImage: "chart.line.uptrend.xyaxis",
                                                   description: Text("Pick a wider date range, or sync your Last.fm history."))
                        }
                    } else {
                        if group == .listening, let volumeInputs {
                            TrendsSection(title: "Volume over time", subtitle: "How much you listened, and when", comparison: true) {
                                TrendsVolumeChart(inputs: volumeInputs, openQuery: openQuery)
                            }
                        }
                        if group == .listening, let heatmapInputs {
                            TrendsSection(title: "When you listen", subtitle: "Scrobbles by day of the week and hour of the day, in your local time", comparison: true) {
                                TrendsHeatmapChart(inputs: heatmapInputs, openQuery: openQuery)
                            }
                        }
                        if group == .listening, let discoveryInputs {
                            TrendsSection(title: "Discovery", subtitle: "How much of what you play is new to you", comparison: true) {
                                TrendsDiscoveryChart(inputs: discoveryInputs, openQuery: openQuery)
                            }
                        }
                        if group == .sequence, let rankBumpInputs {
                            TrendsSection(title: "Rankings", subtitle: "How the leaders of this period rose and fell") {
                                TrendsRankBumpChart(inputs: rankBumpInputs, openQuery: openQuery)
                            }
                        }
                        if group == .habits, let longTailInputs {
                            TrendsSection(title: "Long tail", subtitle: "How your listening is spread across everything you play") {
                                TrendsLongTailChart(inputs: longTailInputs, openQuery: openQuery)
                            }
                        }
                        if group == .sequence, let flowInputs {
                            TrendsSection(title: "Listening flow", subtitle: "What you tend to play right after what, within one sitting", comparison: true) {
                                TrendsFlowChart(inputs: flowInputs, openArtist: { navigation.goToArtist(ArtistIdentity(name: $0)) }, openQuery: openQuery)
                            }
                        }
                        if group == .habits, let loyaltyInputs {
                            TrendsSection(title: "Loyalty", subtitle: "Which things you keep coming back to, and which were a passing phase", comparison: true) {
                                TrendsLoyaltyChart(inputs: loyaltyInputs, openQuery: openQuery, openEntity: openEntity)
                            }
                        }
                        if group == .taste, let decadeInputs {
                            TrendsSection(title: "Eras", subtitle: "Which decades your listening comes from", comparison: true) {
                                TrendsDecadeRiverChart(inputs: decadeInputs, openQuery: openQuery)
                            }
                        }
                        if group == .taste, let tagsInputs {
                            TrendsSection(title: "Taste", subtitle: "The genres and tags your listening falls under", comparison: true) {
                                TrendsTagsChart(inputs: tagsInputs, openQuery: openQuery)
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .task(id: isActive) {
            applyOverviewFocus()
            await loadIfNeeded()
        }
        .onChange(of: overviewFocus) {
            applyOverviewFocus()
        }
        .environment(\.trendsShareInfo, shareInfo)
        .onChange(of: settings.selectedRangeId) { requestReload() }
        .onChange(of: groupRaw) { requestReload() }
        .onChange(of: trends.compareMode) { requestReload() }
        .onChange(of: trends.customFrom) { requestReload() }
        .onChange(of: trends.customTo) { requestReload() }
        .onReceive(NotificationCenter.default.publisher(for: .weekStartDidChange)) { _ in requestReload() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            oldestScrobbleDate = nil
            scrobbles = nil
            canonicalScrobbles = nil
            querySnapshots = nil
            requestReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: EntityTagsEngine.progressNotification)) { _ in backgroundDataMoved() }
        .onReceive(NotificationCenter.default.publisher(for: ReleaseDateEngine.progressNotification)) { _ in backgroundDataMoved() }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in backgroundDataMoved() }
    }

    private func applyOverviewFocus() {
        guard let overviewFocus else { return }
        switch overviewFocus {
        case .listening: groupRaw = Group.listening.rawValue
        case .longTail: groupRaw = Group.habits.rawValue
        case .topTags: groupRaw = Group.taste.rawValue
        }
    }

    // MARK: - Loading

    private func loadIfNeeded() async {
        if isActive, backgroundDataIsNewer, hasLoaded {
            // The background lookups moved on while this page wasn't showing.
            querySnapshots = nil
            needsReload = true
        }
        guard isActive, !hasLoaded || needsReload else { return }
        needsReload = false
        await reload()
        hasLoaded = true
    }

    /// While a long backlog of lookups (tags, track lengths, release dates) is worked through, they announce progress every few seconds.
    /// Recalculating every chart each time kept the page loading and the Mac busy, so the page refreshes for them at most once in
    /// `backgroundRefreshInterval`, and otherwise when it is next opened.
    static let backgroundRefreshInterval: TimeInterval = 180

    private func backgroundDataMoved() {
        backgroundDataIsNewer = true
        guard isActive, hasLoaded else { return }
        let wait = Self.backgroundRefreshInterval - Date().timeIntervalSince(lastFullReloadAt)
        if wait <= 0 {
            querySnapshots = nil
            requestReload()
        } else if trailingRefreshTask == nil {
            // Not yet: catch up once the interval has passed, so what resolved meanwhile still shows without opening the page again.
            trailingRefreshTask = Task {
                try? await Task.sleep(for: .seconds(wait))
                trailingRefreshTask = nil
                guard !Task.isCancelled, isActive, backgroundDataIsNewer else { return }
                querySnapshots = nil
                requestReload()
            }
        }
    }

    private func requestReload() {
        guard isActive else { needsReload = true; return }
        reloadDebounceTask?.cancel()
        reloadDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private func reload() async {
        let requestID = UUID()
        latestRequestID = requestID
        lastFullReloadAt = Date()
        backgroundDataIsNewer = false
        do {
            let all: [ScrobbleSnapshot]
            if let scrobbles { all = scrobbles } else {
                let container = modelContainer
                all = try await ScrobbleHistoryCache.shared.snapshots(container: container)
                guard latestRequestID == requestID else { return }
                scrobbles = all
                oldestScrobbleDate = all.first?.playedAt
            }
            let range = currentRange
            let compareRange = trends.resolve(for: range)
            let container = modelContainer
            let snapshots: QuerySnapshots
            if let querySnapshots { snapshots = querySnapshots } else {
                let loaded = await QuerySnapshotReader.loadAll(container: container)
                guard latestRequestID == requestID else { return }
                snapshots = QuerySnapshots(
                    durations: loaded.durations, releaseDates: loaded.releaseDates, turnover: loaded.turnover,
                    lovedKeys: loaded.lovedKeys, entityTags: loaded.entityTags, images: loaded.images
                )
                querySnapshots = snapshots
                dataVersion += 1
            }
            // Track identity here is the same one Query uses (artist spellings merged) — every chart below reads it. It is worked
            // out once for the whole app (`ScrobbleHistoryCache`), not again for this page.
            let canonical: [ScrobbleSnapshot]
            if let cachedCanonical = canonicalScrobbles { canonical = cachedCanonical } else {
                canonical = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
                guard latestRequestID == requestID else { return }
            }
            let anyPlays = await Task.detached(priority: .utility) {
                all.contains { $0.playedAt >= range.from && $0.playedAt <= range.to }
                    || (compareRange.map { c in all.contains { $0.playedAt >= c.from && $0.playedAt <= c.to } } ?? false)
            }.value
            canonicalScrobbles = canonical
            volumeInputs = TrendsVolumeChart.Inputs(scrobbles: all, durations: snapshots.durations, range: range, compareRange: compareRange, version: dataVersion)
            heatmapInputs = TrendsHeatmapChart.Inputs(scrobbles: all, durations: snapshots.durations, range: range, compareRange: compareRange, version: dataVersion)
            discoveryInputs = TrendsDiscoveryChart.Inputs(scrobbles: canonical, durations: snapshots.durations, range: range, compareRange: compareRange, version: dataVersion)
            tagsInputs = TrendsTagsChart.Inputs(scrobbles: canonical, snapshots: snapshots, range: range, compareRange: compareRange, version: dataVersion)
            flowInputs = TrendsFlowChart.Inputs(scrobbles: canonical, snapshots: snapshots, range: range, compareRange: compareRange, version: dataVersion)
            loyaltyInputs = TrendsLoyaltyChart.Inputs(scrobbles: canonical, durations: snapshots.durations, range: range, compareRange: compareRange, version: dataVersion)
            decadeInputs = TrendsDecadeRiverChart.Inputs(scrobbles: canonical, snapshots: snapshots, range: range, compareRange: compareRange, version: dataVersion)
            rankBumpInputs = TrendsRankBumpChart.Inputs(scrobbles: canonical, durations: snapshots.durations, range: range, version: dataVersion)
            longTailInputs = TrendsLongTailChart.Inputs(scrobbles: canonical, snapshots: snapshots, range: range, version: dataVersion)
            guard latestRequestID == requestID else { return }
            hasAnyPlaysInRange = anyPlays
            errorMessage = nil
        } catch {
            guard latestRequestID == requestID else { return }
            errorMessage = "\(error)"
        }
    }
}

/// A titled group of related charts.
struct TrendsSection<Content: View>: View {
    let title: String
    let subtitle: String
    /// Whether the chart shows a comparison period when one is chosen (so its card says what it is compared with).
    var comparison = false
    @ViewBuilder let content: Content

    @Environment(\.trendsShareInfo) private var shareInfo
    /// Where the chart inside registers the part of itself a shared card shows.
    @State private var capture = ShareChartCapture()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppTypography.sectionTitle)
                    Text(subtitle).font(AppTypography.metadata).foregroundStyle(.secondary)
                }
                Spacer()
                ShareButton(card: { makeShareCard() }, isEnabled: capture.hasChart)
                    .controlSize(.small)
            }
            content
                .environment(\.shareChartCapture, capture)
        }
    }

    /// A card of the chart as it is drawn now, with the period (and what it is compared with) it covers.
    private func makeShareCard() -> ShareCard? {
        guard let image = capture.image() else { return nil }
        // A chart that states its own comparison with the number carries it there; otherwise the card names what it is compared with.
        let summary = capture.summary
        let measure = summary?.change != nil ? "" : (comparison ? (shareInfo.compare ?? "") : "")
        return ShareCard(
            title: title, period: shareInfo.period, measure: measure, rows: [], valueLabel: "", hasMovement: false,
            kindID: "trends." + title.lowercased().replacingOccurrences(of: " ", with: "-"), snapshot: ShareSnapshot(image: image), chartSummary: summary
        )
    }
}

/// The period Trends is showing and what it is compared with, for the card a chart's Share button makes.
struct TrendsShareInfo: Equatable {
    var period = ""
    var compare: String?
}

private struct TrendsShareInfoKey: EnvironmentKey {
    static let defaultValue = TrendsShareInfo()
}

extension EnvironmentValues {
    var trendsShareInfo: TrendsShareInfo {
        get { self[TrendsShareInfoKey.self] }
        set { self[TrendsShareInfoKey.self] = newValue }
    }
}
