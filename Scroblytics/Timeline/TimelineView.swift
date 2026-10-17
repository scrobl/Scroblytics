import SwiftUI
import SwiftData

private struct TimelineDataSnapshot: Sendable {
    let scrobbles: [ScrobbleSnapshot]
    let lovedSet: Set<String>
    let imageLookup: [String: String]
}

private struct TimelineResponsiveLayout {
    let isCompact: Bool
    let tileColumnCount: Int
    let pagePadding: CGFloat

    init(width: CGFloat) {
        if width < 700 {
            isCompact = true
            tileColumnCount = 1
            pagePadding = 16
        } else if width < 1_100 {
            isCompact = false
            tileColumnCount = 2
            pagePadding = 24
        } else {
            isCompact = false
            tileColumnCount = 3
            pagePadding = 24
        }
    }
}

/// Every scrobble as a `Sendable` snapshot, sorted ascending by `playedAt`,
/// fetched off the main actor — shared by Timeline and Milestones.
@ModelActor
actor ScrobbleSnapshotReader {
    func fetchSortedSnapshots() throws -> [ScrobbleSnapshot] {
        try modelContext.fetch(
            FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        ).map(\.snapshot)
    }

    /// The same, with each artist in one spelling (the library's most-played), as Query, Trends, Timeline and the Tools
    /// read it — so a screen that uses this agrees with them about what counts as one artist.
    func fetchCanonicalSnapshots() throws -> [ScrobbleSnapshot] {
        QueryIdentity.canonicalizingArtists(try fetchSortedSnapshots())
    }
}

/// The top artist, album, and track for every
/// month (newest first), each month's weeks nested beneath it. Uses the
/// app-wide Metric (it shares `settings.metric` like every other page).
struct TimelineView: View {
    let modelContainer: ModelContainer
    @Bindable var settings: ChartDateSettings
    let isActive: Bool

    @Environment(\.modelContext) private var modelContext
    @State private var navigation = DetailNavigationCoordinator(origin: .timeline)
    @State private var result: TimelineResult?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var needsReload = false
    @State private var lastDurationReloadAt = Date.distantPast
    @State private var durationReloadTask: Task<Void, Never>?
    @State private var latestRequestID = UUID()
    @State private var reloadDebounceTask: Task<Void, Never>?

    private var months: [TimelineMonth] { result?.months ?? [] }

    /// The most recent month in each year, newest year first — same order as
    /// the timeline itself.
    private var yearJumpTargets: [(year: Int, monthStart: Date)] {
        var seen = Set<Int>()
        var targets: [(year: Int, monthStart: Date)] = []
        for month in months {
            let year = AppCalendars.listening.component(.year, from: month.monthStart)
            if seen.insert(year).inserted { targets.append((year, month.monthStart)) }
        }
        return targets
    }

    var body: some View {
        NavigationStack(path: Binding(
            get: { navigation.path },
            set: { navigation.path = $0 }
        )) {
            GeometryReader { geometry in
                let layout = TimelineResponsiveLayout(width: geometry.size.width)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            header(layout: layout) { monthStart in
                                withAnimation { proxy.scrollTo(monthStart, anchor: .top) }
                            }
                            content(layout: layout)
                        }
                        .padding(layout.pagePadding)
                        .padding(.trailing, !layout.isCompact && yearJumpTargets.count > 1 ? 24 : 0)
                    }
                    .overlay(alignment: .trailing) {
                        if !layout.isCompact && yearJumpTargets.count > 1 {
                            YearJumpStrip(targets: yearJumpTargets) { monthStart in
                                withAnimation { proxy.scrollTo(monthStart, anchor: .top) }
                            }
                            .padding(.trailing, 4)
                        }
                    }
                }
            }
            .navigationTitle("Timeline")
            .navigationDestination(for: ArtistIdentity.self) { ArtistDetailView(identity: $0, settings: settings, navigation: navigation) }
            .navigationDestination(for: AlbumIdentity.self) { AlbumDetailView(identity: $0, settings: settings, navigation: navigation) }
            .navigationDestination(for: TrackIdentity.self) { TrackDetailView(identity: $0, settings: settings, navigation: navigation) }
        }
        .task(id: isActive) { await loadIfNeeded() }
        .onChange(of: settings.metric) { requestReload() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in requestReload() }
        .onReceive(NotificationCenter.default.publisher(for: .weekStartDidChange)) { _ in requestReload() }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { _ in requestReload() }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            guard settings.metric == .timeListened else { return }
            // Track lengths are announced every few seconds during a long backlog, and each reload reads and ranks the whole history.
            let wait = 180 - Date().timeIntervalSince(lastDurationReloadAt)
            if wait <= 0 {
                requestReload()
            } else if durationReloadTask == nil {
                // Catch up once the interval has passed, so lengths that resolved meanwhile still show.
                durationReloadTask = Task {
                    try? await Task.sleep(for: .seconds(wait))
                    durationReloadTask = nil
                    guard !Task.isCancelled, settings.metric == .timeListened else { return }
                    requestReload()
                }
            }
        }
    }

    private func header(layout: TimelineResponsiveLayout, onJump: @escaping (Date) -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                headerTitle
                Spacer()
                headerControls(layout: layout, onJump: onJump)
            }
            VStack(alignment: .leading, spacing: 12) {
                headerTitle
                headerControls(layout: layout, onJump: onJump)
            }
        }
    }

    private var headerTitle: some View {
        Text("Timeline")
            .font(AppTypography.pageTitle)
    }

    private func headerControls(layout: TimelineResponsiveLayout, onJump: @escaping (Date) -> Void) -> some View {
        HStack {
            Picker("Metric", selection: $settings.metric) {
                ForEach(TopChartsMetric.allCases) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            if layout.isCompact && yearJumpTargets.count > 1 {
                Menu("Jump to Year") {
                    ForEach(yearJumpTargets, id: \.year) { target in
                        Button(String(target.year)) {
                            onJump(target.monthStart)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(layout: TimelineResponsiveLayout) -> some View {
        if let errorMessage, result == nil {
            ContentUnavailableView("Failed to load Timeline", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if result == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if months.isEmpty {
            HistoryEmptyState {
                ContentUnavailableView(
                    "No listening history yet", systemImage: "calendar",
                    description: Text("Sync your Last.fm history to see your weekly and monthly top picks.")
                )
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(months) { month in
                    TimelineMonthPanel(
                        month: month,
                        metric: result?.metric ?? .scrobbles,
                        layout: layout
                    )
                    .id(month.monthStart)
                }
            }
        }
    }

    private func loadIfNeeded() async {
        guard isActive, !hasLoaded || needsReload else { return }
        needsReload = false
        await reload()
        hasLoaded = true
    }

    private func requestReload() {
        guard isActive else {
            needsReload = true
            return
        }
        reloadDebounceTask?.cancel()
        reloadDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private func reload() async {
        let requestID = UUID()
        latestRequestID = requestID
        lastDurationReloadAt = Date()
        isLoading = true
        defer { if latestRequestID == requestID { isLoading = false } }
        let metric = settings.metric
        do {
            let container = modelContainer
            let scrobbles = try await ScrobbleHistoryCache.shared.snapshots(container: container)
            // Both helpers are main-actor isolated, so they run here rather than
            // inside the background reader.
            let snapshot = TimelineDataSnapshot(
                scrobbles: scrobbles,
                lovedSet: LovedTracksEngine.lovedSet(context: modelContext),
                imageLookup: try ImageResolutionEngine.imageLookup(context: modelContext)
            )
            guard latestRequestID == requestID else { return }
            let durationLookup = metric == .timeListened
                ? await DurationEngine.resolveDurationLookup(context: modelContext, client: DeezerAPIClient(), scrobbles: snapshot.scrobbles)
                : [:]
            guard latestRequestID == requestID else { return }
            let computed = await Task.detached(priority: .utility) {
                TimelineEngine.fetch(
                    scrobbles: snapshot.scrobbles, metric: metric, durationLookup: durationLookup,
                    lovedSet: snapshot.lovedSet, imageLookup: snapshot.imageLookup
                )
            }.value
            guard latestRequestID == requestID else { return }
            result = computed
            errorMessage = nil
            #if DEBUG
            TimelineDebugDump.writeIfRequested(computed)
            #endif
        } catch {
            guard latestRequestID == requestID else { return }
            errorMessage = "\(error)"
        }
    }
}

private struct TimelineMonthPanel: View {
    let month: TimelineMonth
    let metric: TopChartsMetric
    let layout: TimelineResponsiveLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(month.monthStart.formatted(.dateTime.month(.wide).year()))
                    .font(AppTypography.entityTitle)
                Spacer()
                ShareButton(card: { ShareCards.timelineMonth(month, metric: metric) })
            }
            TimelineMonthTotalsBar(
                totals: month.totals,
                milestones: month.milestones,
                isCompact: layout.isCompact
            )
            TimelinePeriodTilesRow(
                top: month.top,
                metric: metric,
                columnCount: layout.tileColumnCount
            )
            if !month.weeks.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(month.weeks) { week in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Week of \(Self.weekLabel(week.weekStart))")
                                .font(AppTypography.sectionTitle)
                                .foregroundStyle(.secondary)
                            TimelinePeriodTilesRow(
                                top: week.top,
                                metric: metric,
                                columnCount: layout.tileColumnCount
                            )
                        }
                    }
                }
                .padding(.vertical, 16)
                .padding(.leading, 24)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.2))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 2)
                }
                .padding(.horizontal, -20)
                .padding(.bottom, -20)
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Same color wash as the Overview hero and entity headers, so each
            // month reads as its own distinct panel rather than a text divider.
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.5))
                ColorWashView(imageURLs: month.top.items.compactMap(\.imageURL), strength: 0.62)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// "Sep 1 – 7", or "Aug 31 – Sep 6" when the week crosses a month.
    static func weekLabel(_ start: Date) -> String {
        let calendar = AppCalendars.listening
        let end = calendar.date(byAdding: .day, value: 6, to: start)!
        let startString = start.formatted(.dateTime.month(.abbreviated).day())
        let endString = calendar.component(.month, from: start) == calendar.component(.month, from: end)
            ? end.formatted(.dateTime.day())
            : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startString) – \(endString)"
    }
}

private struct TimelineMonthTotalsBar: View {
    let totals: TimelineMonthTotals
    let milestones: [TimelineMilestone]
    let isCompact: Bool

    /// Grouped by kind (Total, Artist, Album, Track), biggest first within a kind.
    private var sortedMilestones: [TimelineMilestone] {
        milestones.sorted { a, b in
            a.kind != b.kind ? a.kind.rawValue < b.kind.rawValue : a.milestone > b.milestone
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCompact {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 2),
                    spacing: 1
                ) {
                    statistics
                }
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 1) {
                    statistics
                }
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !sortedMilestones.isEmpty {
                TagFlowLayout(spacing: 6) {
                    Text("Milestones:").font(AppTypography.supporting).foregroundStyle(.secondary)
                    ForEach(Array(sortedMilestones.enumerated()), id: \.offset) { _, m in
                        milestoneBadge(m)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statistics: some View {
        stat("Plays", totals.plays)
        stat("Artists", totals.artists)
        stat("Albums", totals.albums)
        stat("Tracks", totals.tracks)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(AppTypography.statLabel).foregroundStyle(.secondary)
            Text(value.formatted()).font(AppTypography.contentTitle.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
    }

    private func milestoneBadge(_ m: TimelineMilestone) -> some View {
        let color = MilestoneFormatting.milestoneColor(m.milestone)
        let name = m.name.count > 30 ? "\(m.name.prefix(30))…" : m.name
        let byArtist = m.artist.map { " — \($0)" } ?? ""
        return HStack(spacing: 4) {
            Image(systemName: "trophy.fill").font(AppTypography.supportingDense)
            Text(MilestoneFormatting.formatMilestone(m.milestone)).font(AppTypography.badge).monospacedDigit()
            if !isCompact {
                Text(name).font(AppTypography.supportingDense).opacity(0.7)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(MilestoneFormatting.isPrestigeMilestone(m.milestone) ? Color.accentColor : .clear, lineWidth: 1))
        .help("\(m.kind.label) · \(m.name)\(byArtist) reached \(m.milestone.formatted()) scrobbles — \(m.achievedAt.formatted(date: .abbreviated, time: .omitted))")
    }
}

private struct TimelinePeriodTilesRow: View {
    let top: TimelinePeriodTop
    let metric: TopChartsMetric
    let columnCount: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 20),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : columnCount
        )
    }

    var body: some View {
        if !top.items.isEmpty {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(top.items, id: \.entity) { item in
                    TimelineTile(item: item, metric: metric)
                }
            }
        }
    }
}

private struct TimelineTile: View {
    let item: TimelineTopItem
    let metric: TopChartsMetric

    private var roleLabel: String {
        switch item.entity {
        case .artist: return "Top Artist"
        case .album: return "Top Album"
        case .track: return "Top Track"
        }
    }

    private var valueLabel: String {
        if metric == .timeListened { return DurationEngine.formatTimeListened(item.timeListenedSeconds ?? 0) }
        return "\(item.playcount.formatted()) \(item.playcount == 1 ? "play" : "plays")"
    }

    private var imageTarget: ImageTarget {
        switch item.entity {
        case .artist: return ImageTarget(kind: .artist, artist: item.name, album: nil, track: nil)
        case .album: return ImageTarget(kind: .album, artist: item.artist ?? "", album: item.name, track: nil)
        case .track: return ImageTarget(kind: .track, artist: item.artist ?? "", album: item.album, track: item.name)
        }
    }

    var body: some View {
        link {
            HStack(spacing: 12) {
                EntityThumbnail(url: item.imageURL, entity: item.entity)
                    .frame(width: 112, height: 112)
                    .overlay(alignment: .bottomTrailing) {
                        Text(valueLabel)
                            .font(AppTypography.denseBadge.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(4)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(roleLabel).font(AppTypography.metadata).foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        Text(item.name).font(AppTypography.contentTitle).lineLimit(1)
                        TrackLovedIndicator(
                            artist: item.artist ?? "", track: item.name,
                            initialValue: item.loved, font: AppTypography.metadata,
                            enabled: item.entity == .track
                        )
                    }
                    if let artist = item.artist {
                        Text(artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .drillDownHighlight()
        .entityContextMenu(target: imageTarget, currentImageURL: item.imageURL)
    }

    @ViewBuilder
    private func link<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        switch item.entity {
        case .artist:
            NavigationLink(value: ArtistIdentity(name: item.name, imageURL: item.imageURL)) { content() }
        case .album:
            NavigationLink(value: AlbumIdentity(artist: item.artist ?? "", name: item.name, imageURL: item.imageURL)) { content() }
        case .track:
            NavigationLink(value: TrackIdentity(artist: item.artist ?? "", name: item.name, album: item.album, imageURL: item.imageURL)) { content() }
        }
    }
}

/// Same pattern as Library's A–Z strip, but jumps to the most recent month in
/// each year rather than an alphabetic section.
private struct YearJumpStrip: View {
    let targets: [(year: Int, monthStart: Date)]
    let onSelect: (Date) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(targets, id: \.year) { target in
                Button {
                    onSelect(target.monthStart)
                } label: {
                    Text(String(target.year))
                        .font(AppTypography.indexStrip.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 15)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .help("Jump to \(String(target.year))")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .background(.regularMaterial, in: Capsule())
    }
}

#if DEBUG
/// Real-data verification hook: set `SCROBLYTICS_TIMELINE_DUMP=/path.json` to
/// write the computed timeline in the same shape `timeline_ref.py` produces.
enum TimelineDebugDump {
    /// With `SCROBLYTICS_TIMELINE_DUMP` set, computes both metrics against the
    /// real store at launch, writes the dumps, and quits — no UI needed.
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_TIMELINE_DUMP"] != nil else { return }
        Task { @MainActor in
            let context = container.mainContext
            let scrobbles = try context.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
            let lovedSet = LovedTracksEngine.lovedSet(context: context)
            let imageLookup = try ImageResolutionEngine.imageLookup(context: context)
            let started = Date()
            writeIfRequested(TimelineEngine.fetch(scrobbles: scrobbles, metric: .scrobbles, lovedSet: lovedSet, imageLookup: imageLookup))
            print("[TimelineDebugDump] scrobbles metric computed in \(Date().timeIntervalSince(started))s")
            let durations = await DurationEngine.resolveDurationLookup(context: context, client: DeezerAPIClient(), scrobbles: scrobbles)
            print("[TimelineDebugDump] duration lookup: \(durations.count) tracks resolved")
            writeIfRequested(TimelineEngine.fetch(scrobbles: scrobbles, metric: .timeListened, durationLookup: durations, lovedSet: lovedSet, imageLookup: imageLookup))
            writeMilestonesSummary(MilestonesEngine.fetch(scrobbles: scrobbles))
            // Simulated sync: everything before the last 30 days as the baseline.
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            let before = SyncEventsEngine.countEntities(scrobbles.filter { $0.playedAt < cutoff })
            let after = SyncEventsEngine.countEntities(scrobbles)
            let newMilestones = SyncEventsEngine.findNewMilestones(before: before, after: after)
            let lines = newMilestones.map { "\($0.kind.rawValue)|\($0.artist ?? "")|\($0.name)|\($0.milestone)" }
            try? ([String(cutoff.timeIntervalSince1970)] + lines).joined(separator: "\n")
                .write(toFile: (ProcessInfo.processInfo.environment["SCROBLYTICS_TIMELINE_DUMP"] ?? "") + ".newmilestones", atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    /// Counts + ordering the Milestones page renders, for `milestones_ref.py`.
    static func writeMilestonesSummary(_ result: MilestonesResult) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_TIMELINE_DUMP"] else { return }
        func category(_ c: MilestoneCategory) -> [String: Any] {
            [
                "upcoming": c.upcoming.count,
                "achieved": c.achieved.count,
                "upcomingFirst": c.upcoming.prefix(5).map { [$0.name, $0.current, $0.next] as [Any] },
                "achievedByMilestone": Dictionary(grouping: c.achieved, by: { String($0.milestone) }).mapValues(\.count),
            ]
        }
        let out: [String: Any] = [
            "total": ["current": result.total.current, "next": result.total.upcoming?.next ?? 0,
                      "achieved": result.total.achieved.map(\.milestone)],
            "artists": category(result.artists), "albums": category(result.albums), "tracks": category(result.tracks),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path + ".milestones"))
        }
    }

    static func writeIfRequested(_ result: TimelineResult) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_TIMELINE_DUMP"] else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        func top(_ t: TimelinePeriodTop) -> [Any] {
            [t.artist, t.album, t.track].map { item -> Any in
                guard let item else { return NSNull() }
                return [item.name, result.metric == .scrobbles ? item.playcount : (item.timeListenedSeconds ?? 0)] as [Any]
            }
        }
        var out: [String: Any] = [:]
        for month in result.months {
            var weeks: [String: Any] = [:]
            for week in month.weeks { weeks[formatter.string(from: week.weekStart)] = top(week.top) }
            out[formatter.string(from: month.monthStart)] = [
                "top": top(month.top),
                "totals": [month.totals.plays, month.totals.artists, month.totals.albums, month.totals.tracks],
                "milestones": month.milestones.count,
                "weeks": weeks,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path + "." + result.metric.rawValue))
        }
    }
}
#endif
