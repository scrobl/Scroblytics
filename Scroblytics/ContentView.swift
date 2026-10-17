import SwiftUI
import SwiftData
import Observation

@MainActor
@Observable
private final class SyncProgressState {
    private(set) var progress: SyncProgress?
    private var lastPublishedAt = Date.distantPast
    /// When timing began (the first page that landed) and how much had been checked then, for the time-left estimate.
    private var pace: (at: Date, processed: Int)?

    /// How often, during a full-history sync, the pages are told that more of the library has landed.
    private static let dataArrivedInterval: TimeInterval = 30
    private var lastDataArrivedAt = Date.distantPast

    func publish(_ newProgress: SyncProgress) {
        let now = Date()
        let phaseChanged = progress?.phase != newProgress.phase
        let modeChanged = progress?.mode != newProgress.mode
        let reachedEnd = newProgress.progressTotal > 0
            && newProgress.processedScrobbles >= newProgress.progressTotal
        let waitChanged = progress?.waitingSeconds != newProgress.waitingSeconds
        guard phaseChanged || modeChanged || reachedEnd || waitChanged || now.timeIntervalSince(lastPublishedAt) >= 0.1 else { return }
        #if DEBUG
        if waitChanged {
            TestProfile.log(newProgress.waitingSeconds.map { "SYNC waiting \($0)s for Last.fm's rate limit" } ?? "SYNC rate-limit wait over; carrying on")
        }
        #endif
        progress = newProgress
        lastPublishedAt = now
        if pace == nil, newProgress.phase == .scrobbles, newProgress.processedScrobbles > 0 {
            pace = (now, newProgress.processedScrobbles)
        }
        // A first sync walks ~10 minutes of history newest→oldest; instead of an empty Overview
        // until the end, let the page fill in as data lands (it refreshes on the notification the
        // way it does after a sync — off the main thread, and only while it is showing).
        if newProgress.mode.isFullHistory, newProgress.phase == .scrobbles, newProgress.processedScrobbles > 0,
           now.timeIntervalSince(lastDataArrivedAt) >= Self.dataArrivedInterval {
            lastDataArrivedAt = now
            NotificationCenter.default.post(name: .scrobbleSyncDidProgress, object: nil)
        }
    }

    /// "about 6 min left", once the pace has settled; nil before that.
    var remainingText: String? {
        guard let progress, progress.mode.isFullHistory, progress.phase == .scrobbles, let pace else { return nil }
        return ImportEstimate.remainingText(
            processed: progress.processedScrobbles, total: progress.progressTotal,
            baselineProcessed: pace.processed, elapsed: Date().timeIntervalSince(pace.at)
        )
    }

    func reset() {
        progress = nil
        pace = nil
        lastPublishedAt = .distantPast
        lastDataArrivedAt = .distantPast
    }
}

struct ContentView: View {
    private enum Tab: Hashable {
        case overview, library, topCharts, trends, tools, milestones, timeline
    }

    let modelContainer: ModelContainer
    let nowPlayingStore: NowPlayingStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(NowPlayingPreference.showsShelfKey) private var showsNowPlayingShelf = true
    /// Date range + Chart comparison period — shared identically by Overview
    /// and Top Charts (and persisted across launches), matching the real
    /// app's single top-level range/compare state.
    @State private var chartDateSettings = ChartDateSettings()
    @State private var trendsSettings = TrendsSettings()
    @State private var lovedTracksStore = LovedTracksStore()
    @State private var flaggedTracksStore = FlaggedTracksStore()
    @State private var libraryGapBadgeStore = LibraryGapBadgeStore()
    @State private var tagWriteRunner = TagWriteRunner()
    @State private var popularityStore = PopularityStore()
    @State private var tagStore = TagStore()
    @State private var backgroundWork = BackgroundWorkStore()
    @State private var pendingSyncEvents = PendingSyncEventsStore()
    @State private var selectedTab: Tab = .overview
    @State private var selectedTopChartsEntity: TopChartsEntity = .artist
    @State private var overviewToolRequest: ToolDescriptor.Kind?
    @State private var overviewSimilarSeeds: [SimilarSeed] = []
    @State private var overviewTrendsFocus: TrendsFocus?
    @State private var hasOverviewReturn = false
    @State private var imageResolutionError: String?
    @State private var libraryNavigation = DetailNavigationCoordinator(origin: .library)
    @State private var showingSearch = false
    @State private var showingAsk = false
    @State private var ask = AskModel()
    @State private var askQueryRequest: AskQueryRequest?
    @State private var askSimilarRouter = AskSimilarRouter()
    @State private var askSuggestions = AskSuggestionStore()
    @State private var staleReview = StaleRecordReviewModel()
    @State private var showingStaleReview = false
    @State private var isSyncing = false
    /// The running sync, so Stop can cancel it; and whether this run is the very first import.
    @State private var syncTask: Task<SyncSummary, Error>?
    @State private var userStoppedSync = false
    @State private var isFirstImport = false

    /// Fires when a sync completes, or when Offline mode is switched off (the same background work restarts either way).
    private static let syncOrResume = NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)
        .merge(with: NotificationCenter.default.publisher(for: .connectivityDidResume))
    @State private var syncProgressState = SyncProgressState()
    @State private var targetedSyncActivity: TargetedSyncActivity?
    @State private var syncError: String?
    @State private var windowID = UUID()
    @State private var windowCommands = WindowCommandState()

    var body: some View {
        // The welcome screen stands in for the app until there is a Last.fm account (or history).
        FirstRunGate(modelContainer: modelContainer) { mainContent }
            .focusedSceneValue(\.windowCommands, windowCommands)
            .onChange(of: windowCommands.request) { handle(windowCommands.command) }
    }

    private var mainContent: some View {
        TabView(selection: $selectedTab) {
            OverviewView(
                settings: chartDateSettings,
                isActive: selectedTab == .overview,
                openTopCharts: { entity in
                    beginOverviewRoute(to: .topCharts)
                    selectedTopChartsEntity = entity
                },
                openTool: { kind in
                    overviewToolRequest = kind
                    beginOverviewRoute(to: .tools)
                },
                openSimilarSounds: { seeds in
                    overviewSimilarSeeds = seeds
                    overviewToolRequest = .similarSounds
                    beginOverviewRoute(to: .tools)
                },
                openTrends: { focus in
                    overviewTrendsFocus = focus
                    beginOverviewRoute(to: .trends)
                },
                openMilestones: { beginOverviewRoute(to: .milestones) },
                openQuery: { spec, detail in
                    beginOverviewRoute(to: .tools)
                    askQueryRequest = QueryHandoff.request(spec: spec, source: "Overview", detail: detail, action: .run, onReturn: { returnToOverview() })
                }
            )
                .tabItem { Label("Overview", systemImage: "square.grid.2x2") }
                .tag(Tab.overview)
            LibraryView(modelContainer: modelContainer, settings: chartDateSettings, isActive: selectedTab == .library, navigation: libraryNavigation)
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(Tab.library)
            TopChartsView(modelContainer: modelContainer, settings: chartDateSettings, entity: $selectedTopChartsEntity, isActive: selectedTab == .topCharts)
                .tabItem { Label("Top Charts", systemImage: "chart.bar.fill") }
                .tag(Tab.topCharts)
            TrendsView(
                modelContainer: modelContainer,
                settings: chartDateSettings,
                trends: trendsSettings,
                isActive: selectedTab == .trends,
                overviewFocus: $overviewTrendsFocus,
                openQuery: { spec, detail in
                    selectedTab = .tools
                    askQueryRequest = QueryHandoff.request(spec: spec, source: "Trends", detail: detail, action: .run, onReturn: { selectedTab = .trends })
                }
            )
                .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(Tab.trends)
            MilestonesView(modelContainer: modelContainer, settings: chartDateSettings, isActive: selectedTab == .milestones)
                .tabItem { Label("Milestones", systemImage: "trophy.fill") }
                .tag(Tab.milestones)
            TimelineView(modelContainer: modelContainer, settings: chartDateSettings, isActive: selectedTab == .timeline)
                .tabItem { Label("Timeline", systemImage: "calendar") }
                .tag(Tab.timeline)
            ToolsView(
                modelContainer: modelContainer,
                settings: chartDateSettings,
                askRequest: $askQueryRequest,
                overviewToolRequest: $overviewToolRequest,
                overviewSimilarSeeds: $overviewSimilarSeeds,
                openQuery: { spec, detail, suggestedName in
                    selectedTab = .tools
                    askQueryRequest = QueryHandoff.request(spec: spec, source: "Tools", detail: detail, action: .edit, suggestedName: suggestedName, onReturn: { selectedTab = .tools })
                }
            )
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.tools)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                #if DEBUG
                TestProfileStrip()
                TestProfilesLaunchTrigger()
                tourDriver
                #endif
                if isSyncing || targetedSyncActivity != nil {
                    SyncProgressBanner(
                        state: syncProgressState,
                        targetedTitle: targetedSyncActivity?.title,
                        isFirstImport: isFirstImport,
                        onStop: { NotificationCenter.default.post(name: .syncStopRequested, object: nil) }
                    )
                }
                CredentialsProblemStrip()
                ImportStatusStrips(container: modelContainer, isSyncing: isSyncing, onResume: { startSync(full: false) })
                OfflineStrip()
                UpdateStrip()
                CrashNoticeStrip()
                BackgroundWorkStrip(store: backgroundWork)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if showsNowPlayingShelf, let track = nowPlayingStore.track {
                    NowPlayingShelf(track: track) {
                        openNowPlaying(track)
                    } onDismiss: {
                        showsNowPlayingShelf = false
                    }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: nowPlayingStore.track?.id)
        }
        .toolbar {
            if hasOverviewReturn, selectedTab != .overview {
                ToolbarItem(placement: .navigation) {
                    Button("Overview", systemImage: "chevron.left", action: returnToOverview)
                        .help("Back to Overview")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Search", systemImage: "magnifyingglass") {
                    showingSearch = true
                }
                .labelStyle(.iconOnly)
                .help("Search")

                Button("Ask", systemImage: "sparkles") {
                    showingAsk = true
                }
                .labelStyle(.iconOnly)
                .help("Ask your library")
                .popover(isPresented: $showingAsk, arrowEdge: .bottom) {
                    AskPopoverContent(
                        ask: ask,
                        registry: .standard,
                        context: askContext,
                        onRun: { routeAsked($0, action: .run) },
                        onEdit: { routeAsked($0, action: .edit) },
                        onSave: { routeAsked($0, action: .save) }
                    )
                }

                OfflineToggleButton()

                Menu {
                    Button("Full Resync", systemImage: "arrow.clockwise") {
                        startSync(full: true)
                    }
                    .disabled(syncMenuDisabled)
                    Divider()
                    Button("Review Stale Records…", systemImage: "arrow.triangle.merge") {
                        showingStaleReview = true
                        Task { await staleReview.refresh(container: modelContainer) }
                    }
                } label: {
                    Label(isSyncing ? "Syncing…" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                } primaryAction: {
                    startSync(full: false)
                }
                .labelStyle(.iconOnly)
                .help(syncMenuHelp)
                .disabled(syncMenuDisabled || isSyncing || targetedSyncActivity != nil)
            }
        }
        .environment(lovedTracksStore)
        .environment(flaggedTracksStore)
        .toolRuntime(
            gapBadges: libraryGapBadgeStore, tagWriter: tagWriteRunner, work: backgroundWork, container: modelContainer,
            askRouter: askSimilarRouter, askSuggestions: askSuggestions, nowPlaying: nowPlayingStore, onAskSimilar: { showingAsk = false; selectedTab = .tools },
            onAccountConnected: { startSync(full: false) },
            onStopRequested: { stopSync() }
        )
        .environment(popularityStore)
        .environment(tagStore)
        .environment(pendingSyncEvents)
        .task {
            nowPlayingStore.setWindow(windowID, isActive: scenePhase == .active)
            await lovedTracksStore.load(container: modelContainer)
            await flaggedTracksStore.load(container: modelContainer)
            await libraryGapBadgeStore.load(container: modelContainer)
            await popularityStore.start(container: modelContainer, work: backgroundWork, warm: !DebugFlags.offline && !ConnectivityGate.isOffline)
            await tagStore.start(container: modelContainer, work: backgroundWork, warm: (!DebugFlags.offline || DebugFlags.tagSweep) && !ConnectivityGate.isOffline)
            await seedReleaseDates()
            await seedTempos()
            if DebugFlags.offline || ConnectivityGate.isOffline { return }
            if LastfmCredentialsStore.load() != nil {
                await runSync(full: false, reportMissingCredentials: false)
            }
            await resolveMissingImages()
        }
        .onChange(of: scenePhase) { _, newPhase in
            nowPlayingStore.setWindow(windowID, isActive: newPhase == .active)
        }
        .onDisappear {
            nowPlayingStore.removeWindow(windowID)
        }
        .onReceive(Self.syncOrResume) { note in restartBackgroundWork(after: note) }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            // Corrections made on Last.fm sync as NEW rows and strand whatever was saved on the old ones; offer to
            // move it, but only when there's something new to say (a dismissed review stays dismissed).
            guard !DebugFlags.offline else { return }
            Task {
                await staleReview.refresh(container: modelContainer)
                if staleReview.shouldAutoPresent { showingStaleReview = true }
            }
        }
        .sheet(isPresented: $showingStaleReview) {
            StaleRecordReviewView(model: staleReview, modelContainer: modelContainer) { showingStaleReview = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { notification in
            guard let progress = notification.object as? DurationEngine.Progress else { return }
            backgroundWork.report(.durations, remaining: progress.isComplete ? 0 : progress.remaining)
        }
        .onReceive(NotificationCenter.default.publisher(for: BPMEngine.progressNotification)) { notification in
            guard let progress = notification.object as? BPMEngine.Progress else { return }
            backgroundWork.report(.tempos, remaining: progress.isComplete ? 0 : progress.remaining)
        }
        .onReceive(NotificationCenter.default.publisher(for: ReleaseDateEngine.progressNotification)) { notification in
            guard let progress = notification.object as? ReleaseDateEngine.Progress else { return }
            backgroundWork.report(.releaseDates, remaining: progress.isComplete ? 0 : progress.remaining)
        }
        .onReceive(NotificationCenter.default.publisher(for: .targetedSyncDidStart)) { notification in
            if let activity = notification.object as? TargetedSyncActivity {
                targetedSyncActivity = activity
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .targetedSyncDidFinish)) { notification in
            guard let activity = notification.object as? TargetedSyncActivity,
                  activity.id == targetedSyncActivity?.id else { return }
            targetedSyncActivity = nil
        }
        .overlay {
            if showingSearch {
                GlobalSearchOverlay(isPresented: $showingSearch, onSelect: handleSearchSelection)
                    .environment(lovedTracksStore)
                    .environment(flaggedTracksStore)
                    .environment(libraryGapBadgeStore)
                    .environment(popularityStore)
            }
        }
        .modifier(ContentViewAlerts(imageResolutionError: $imageResolutionError, syncError: $syncError))
    }

    private func beginOverviewRoute(to tab: Tab) {
        hasOverviewReturn = true
        selectedTab = tab
    }

    private func navigate(to destination: WindowCommandState.Destination) {
        hasOverviewReturn = false
        switch destination {
        case .overview: selectedTab = .overview
        case .library: selectedTab = .library
        case .topCharts: selectedTab = .topCharts
        case .trends: selectedTab = .trends
        case .milestones: selectedTab = .milestones
        case .timeline: selectedTab = .timeline
        case .tools: selectedTab = .tools
        }
    }

    private func handle(_ command: WindowCommandState.Command) {
        switch command {
        case .search:
            showingSearch = true
        case .ask:
            showingAsk = true
        case .sync:
            startSync(full: false)
        case .fullResync:
            startSync(full: true)
        case .staleRecordReview:
            showingStaleReview = true
            Task { await staleReview.refresh(container: modelContainer) }
        case .navigate(let destination):
            navigate(to: destination)
        }
    }

    private func returnToOverview() {
        overviewToolRequest = nil
        overviewSimilarSeeds = []
        overviewTrendsFocus = nil
        hasOverviewReturn = false
        selectedTab = .overview
    }

    private func startSync(full: Bool) {
        guard !isSyncing else { return }
        Task { await runSync(full: full) }
    }

    private func askContext() -> AskContext {
        let context = modelContainer.mainContext
        let vocabulary = EntityTagsEngine.loadSnapshot(context: context).vocabulary.map(\.tag)
        var oldest = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        oldest.fetchLimit = 1
        let earliest = try? context.fetch(oldest).first?.playedAt
        let artistNames = (try? context.fetch(FetchDescriptor<Artist>()))?.map(\.name) ?? []
        return AskContext(
            tags: Array(vocabulary.prefix(AskContext.tagLimit)),
            knownTags: Set(vocabulary),
            knownArtists: Set(artistNames),
            earliest: earliest,
            container: modelContainer
        )
    }

    private func routeAsked(_ spec: QuerySpec, action: AskQueryRequest.Action) {
        showingAsk = false
        selectedTab = .tools
        askQueryRequest = AskQueryRequest(spec: spec, action: action, question: ask.pendingQuestion)
    }

    @MainActor
    private func runSync(full: Bool, reportMissingCredentials: Bool = true) async {
        if ConnectivityGate.isOffline {
            if reportMissingCredentials { syncError = "Offline mode is on. Go online to sync." }
            return
        }
        guard let credentials = LastfmCredentialsStore.load() else {
            if reportMissingCredentials {
                syncError = LastfmCredentialsStore.lastProblem != nil
                    ? CredentialsProblemText.syncError
                    : "Set up your Last.fm account in Settings before syncing."
            }
            return
        }

        isSyncing = true
        windowCommands.setSyncing(true)
        syncProgressState.reset()
        syncError = nil
        userStoppedSync = false
        defer {
            isSyncing = false
            windowCommands.setSyncing(false)
            syncProgressState.reset()
        }

        do {
            // Baseline for the post-sync milestone/turnover diff — skipped on
            // the very first sync (no prior state to diff).
            let context = modelContainer.mainContext
            let previousSyncAt = try context.fetch(FetchDescriptor<SyncState>()).first?.lastSyncedAt
            isFirstImport = previousSyncAt == nil
            NotificationCenter.default.post(name: .scrobbleSyncDidStart, object: nil, userInfo: ["first": previousSyncAt == nil])
            let container = modelContainer
            let beforeCounts: SyncEventsEngine.EntityCounts?
            if previousSyncAt != nil {
                let before = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
                beforeCounts = await Task.detached(priority: .utility) { SyncEventsEngine.countEntities(before) }.value
            } else {
                beforeCounts = nil
            }

            let engine = SyncEngine(modelContainer: modelContainer)
            let task = Task.detached(priority: .utility) {
                try await engine.sync(credentials: credentials, full: full) { progress in
                    Task { @MainActor in
                        syncProgressState.publish(progress)
                    }
                }
            }
            syncTask = task
            defer { syncTask = nil }
            let summary = try await task.value
            #if DEBUG
            TestProfile.log("SYNC finished added=\(summary.added) complete=\(summary.isComplete) firstImport=\(previousSyncAt == nil)")
            #endif
            if summary.dataChanged {
                NotificationCenter.default.post(name: .scrobbleSyncDidComplete, object: summary)
            }
            if previousSyncAt == nil, summary.isComplete {
                NotificationCenter.default.post(name: .firstImportDidFinish, object: nil)
            }
            NotificationCenter.default.post(name: .scrobbleSyncDidFinish, object: nil)
            startLovedTracksSync(credentials: credentials)
            if let beforeCounts, let previousSyncAt, summary.added > 0 {
                await recordSyncEvents(before: beforeCounts, since: previousSyncAt, credentials: credentials)
            }
        } catch {
            // Stop keeps everything imported and the cursor, so it is an ordinary pause: no alert.
            if userStoppedSync || error is CancellationError {
                #if DEBUG
                TestProfile.log("SYNC stopped by the user; imported scrobbles and the resume point are kept")
                #endif
                NotificationCenter.default.post(name: .scrobbleSyncDidStop, object: nil)
                return
            }
            if await connectivityPromptWillHandle(error) {
                // The "switch to Offline mode?" prompt (or Offline mode itself) answers this; the import is just paused.
                NotificationCenter.default.post(name: .scrobbleSyncDidStop, object: nil)
                return
            }
            #if DEBUG
            TestProfile.log("SYNC failed: \(describeSyncError(error))")
            #endif
            NotificationCenter.default.post(name: .scrobbleSyncDidFail, object: HistoryStatus.Failure(error: error))
            // The first import reports its failure in a strip (and on empty pages) with a Retry; other syncs keep the alert.
            if !isFirstImport { syncError = describeSyncError(error) }
        }
    }

    /// Stops the running sync after the page in flight. What is imported stays, and the sync can be resumed.
    private func stopSync() {
        guard isSyncing else { return }
        userStoppedSync = true
        syncTask?.cancel()
    }

    /// A failure to connect is answered by the "switch to Offline mode?" prompt (or by Offline mode being on), so it
    /// shouldn't also raise its own alert. Gives the prompt a moment to appear before deciding.
    private var syncMenuDisabled: Bool { Connectivity.shared.isOffline }

    private var syncMenuHelp: String {
        if Connectivity.shared.isOffline { return "Offline mode is on" }
        return isSyncing ? "Syncing…" : "Sync"
    }

    /// After a sync lands, or after going back online: reload the loved list, then (a few seconds later, behind the
    /// visible work) restart the hour-long warmers, and when it was Offline mode ending, catch up with Last.fm.
    private func restartBackgroundWork(after note: Notification) {
        Task {
            await lovedTracksStore.load(container: modelContainer, force: true)
            // The pages refresh on this same notification; let that visible work read the
            // store first, then start the hour-long warmers behind it.
            try? await Task.sleep(for: .seconds(3))
            await popularityStore.start(container: modelContainer, work: backgroundWork)
            await tagStore.start(container: modelContainer, work: backgroundWork)
            await seedReleaseDates()
            await seedTempos()
            await resolveMissingImages()
            // Back online after Offline mode: catch up with Last.fm (one window does it, not each).
            if note.name == .connectivityDidResume, Connectivity.shared.claimResumeSync() {
                await runSync(full: false, reportMissingCredentials: false)
            }
        }
    }

    private func connectivityPromptWillHandle(_ error: Error) async -> Bool {
        if error is OfflineError { return true }
        guard ConnectivityGate.isConnectivityError(error) else { return false }
        try? await Task.sleep(for: .milliseconds(600))
        return Connectivity.shared.promptPending || ConnectivityGate.isOffline
    }

    private func startLovedTracksSync(credentials: LastfmCredentials) {
        guard backgroundWork.active[.lovedTracks] == nil else { return }

        backgroundWork.report(.lovedTracks, remaining: 1, total: 1)
        let engine = SyncEngine(modelContainer: modelContainer)
        Task.detached(priority: .utility) {
            let changed = await engine.syncLovedTracks(credentials: credentials) { remaining, total in
                Task { @MainActor in
                    backgroundWork.report(.lovedTracks, remaining: remaining, total: total)
                }
            }
            await MainActor.run {
                backgroundWork.finish(.lovedTracks)
            }
            if changed {
                await lovedTracksStore.load(container: modelContainer, force: true)
            }
        }
    }

    /// The post-sync new-milestones/new-turnovers pass. Milestones are recorded even if the turnover pass (which may need
    /// network tracklist lookups) fails; that failure is surfaced, not swallowed.
    private func recordSyncEvents(
        before: SyncEventsEngine.EntityCounts, since: Date, credentials: LastfmCredentials
    ) async {
        do {
            let container = modelContainer
            let after = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            let afterCounts = await Task.detached(priority: .utility) { SyncEventsEngine.countEntities(after) }.value
            let milestones = SyncEventsEngine.findNewMilestones(before: before, after: afterCounts)
            pendingSyncEvents.append(milestones: milestones, turnovers: [])

            let touched = SyncEventsEngine.touchedArtists(before: before, after: afterCounts)
            guard !touched.isEmpty else { return }
            let turnovers = try await SyncEventsEngine.findNewAlbumTurnovers(
                context: modelContainer.mainContext,
                client: LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username),
                scrobbles: after, touchedArtists: touched, since: since
            )
            pendingSyncEvents.append(milestones: [], turnovers: turnovers)
        } catch {
            if await connectivityPromptWillHandle(error) { return }
            syncError = "Couldn't check for new milestones/album turnovers: \(describeSyncError(error))"
        }
    }

    /// Search always lands in Library — the "browse everything" tab, with no
    /// chart-range/metric context a jump-to-entity shouldn't need to imply.
    private func handleSearchSelection(_ result: SearchResult) {
        selectedTab = .library
        switch result.kind {
        case .artist:
            if let artist = result.artist { libraryNavigation.goToArtist(artist) }
        case .album:
            if let album = result.album { libraryNavigation.goToAlbum(album) }
        case .track:
            if let track = result.track { libraryNavigation.goToTrack(track) }
        }
    }

    #if DEBUG
    /// The self-driving tour for the macOS 15 test (`Tour`); nothing here exists in a release build.
    private var tourDriver: some View {
        Color.clear.frame(height: 0).task {
            guard let minutes = Tour.minutes else { return }
            await runTour(minutes: minutes)
        }
    }

    private func runTour(minutes: Double) async {
        Tour.log("TOUR start, \(minutes) minutes")
        let monitor = Tour.StallMonitor()
        monitor.start()
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        // The most played artist, album and track in the copy, to open.
        let history = (try? await ScrobbleHistoryCache.shared.snapshots(container: modelContainer)) ?? []
        var albums: [String: (artist: String, album: String, track: String, count: Int)] = [:]
        for play in history where !play.albumName.isEmpty && !play.trackName.isEmpty {
            let key = play.artistName + "\u{0}" + play.albumName
            let current = albums[key] ?? (play.artistName, play.albumName, play.trackName, 0)
            albums[key] = (current.artist, current.album, current.track, current.count + 1)
        }
        guard let top = albums.values.max(by: { $0.count < $1.count }) else { Tour.log("TOUR no albums in the copy"); exit(3) }
        Tour.log("TOUR plays \(history.count), opening the busiest album's artist, album and track")
        let deadline = Date().addingTimeInterval(minutes * 60)
        var round = 0
        let tabs: [(String, Tab)] = [("overview", .overview), ("library", .library), ("topCharts", .topCharts), ("trends", .trends), ("milestones", .milestones), ("timeline", .timeline), ("tools", .tools)]
        while Date() < deadline {
            round += 1
            for (name, tab) in tabs {
                monitor.phase = "round \(round): \(name) tab"
                selectedTab = tab
                await pause(5)
            }
            monitor.phase = "round \(round): open artist, album, track in Library"
            selectedTab = .library
            await pause(2)
            libraryNavigation.goToArtist(ArtistIdentity(name: top.artist)); await pause(5)
            libraryNavigation.goToAlbum(AlbumIdentity(artist: top.artist, name: top.album)); await pause(6)
            libraryNavigation.goToTrack(TrackIdentity(artist: top.artist, name: top.track, album: top.album)); await pause(5)
            for visit in 1...3 {
                monitor.phase = "round \(round): leave Library stack (\(visit))"
                selectedTab = .overview; await pause(4)
                monitor.phase = "round \(round): return to Library stack (\(visit))"
                selectedTab = .library; await pause(5)
            }
            libraryNavigation.path = NavigationPath()
            for kind in [ToolDescriptor.Kind.rabbitHole, .missingData, .albumTurnovers, .multiAlbumTracks, .similarSounds] {
                monitor.phase = "round \(round): open tool \(kind)"
                overviewToolRequest = nil
                await pause(0.5)
                overviewToolRequest = kind
                selectedTab = .tools
                await pause(10)
                monitor.phase = "round \(round): leave tool \(kind)"
                selectedTab = .overview; await pause(3)
                monitor.phase = "round \(round): return to tool \(kind)"
                selectedTab = .tools; await pause(6)
            }
            overviewToolRequest = nil
            monitor.phase = "round \(round): overview, idle"
            selectedTab = .overview
            await pause(20)
        }
        monitor.stop()
        let result = monitor.snapshot
        for (phase, ms) in result.worst.sorted(by: { $0.value > $1.value }).prefix(12) {
            Tour.log("TOUR worst main-thread delay \(String(format: "%.0f", ms)) ms in \(phase)")
        }
        Tour.log("TOUR stalls of 500 ms or more: \(result.stalls.count)" + (result.stalls.isEmpty ? "" : "; longest \(String(format: "%.0f", result.stalls.map(\.ms).max() ?? 0)) ms"))
        Tour.log("TOUR done after \(round) round(s)")
        exit(0)
    }
    #endif

    private func openNowPlaying(_ track: NowPlayingTrack) {
        selectedTab = .library
        libraryNavigation.goToTrack(TrackIdentity(
            artist: track.artist,
            name: track.track,
            album: track.album.isEmpty ? nil : track.album,
            imageURL: track.imageURL
        ))
    }

    @MainActor
    /// Queues every album whose release date has never been looked up on the shared, rate-limited
    /// release-date queue (see `ReleaseDateEngine.seedUnresolvedAlbums`). Background work; progress shows on
    /// the status strip like the other sweeps.
    private func seedReleaseDates() async {
        guard (!DebugFlags.offline || DebugFlags.releaseSweep), !ConnectivityGate.isOffline else { return }
        await ReleaseDateEngine.seedUnresolvedAlbums(context: modelContainer.mainContext, musicBrainz: MusicBrainzAPIClient(), deezer: DeezerAPIClient())
    }

    /// Slowly looks up tempos for the most-played tracks, unless the user turned that off in Settings › Tempo.
    private func seedTempos() async {
        guard !DebugFlags.offline else { return }
        await BPMEngine.seedMostPlayedUnresolved(context: modelContainer.mainContext)
    }

    private func resolveMissingImages() async {
        do {
            try await ImageResolutionEngine.resolveAllUnresolved(container: modelContainer) { remaining, failed in
                backgroundWork.report(.artwork, remaining: remaining, failed: failed)
            }
        } catch is CancellationError {
            backgroundWork.finish(.artwork)
            return
        } catch {
            backgroundWork.finish(.artwork)
            if await connectivityPromptWillHandle(error) { return }
            imageResolutionError = error.localizedDescription
        }
    }
}

/// The window's two error alerts as one modifier (the window's modifier chain is at the compiler's limit).
private struct ContentViewAlerts: ViewModifier {
    @Binding var imageResolutionError: String?
    @Binding var syncError: String?

    func body(content: Content) -> some View {
        content
            .alert("Image Resolution Stopped", isPresented: Binding(
                get: { imageResolutionError != nil },
                set: { if !$0 { imageResolutionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(imageResolutionError ?? "")
            }
            .alert("Sync Failed", isPresented: Binding(
                get: { syncError != nil },
                set: { if !$0 { syncError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(syncError ?? "")
            }
    }
}

private struct SyncProgressBanner: View {
    let state: SyncProgressState
    let targetedTitle: String?
    let isFirstImport: Bool
    let onStop: () -> Void

    private var progress: SyncProgress? { state.progress }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Label {
                    statusText
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                    .fontWeight(.medium)
                Spacer(minLength: 12)
                if let progress {
                    Text(progressDetail(progress))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if targetedTitle == nil {
                    Button("Stop", action: onStop)
                        .help("Stop after this page. What has been imported is kept, and you can resume later.")
                }
            }

            if let progress, progress.phase == .scrobbles,
               let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if isFirstImport, targetedTitle == nil {
                Text("You can keep using the app while this runs. If you quit, the import picks up where it stopped.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusText: some View {
        if let seconds = progress?.waitingSeconds {
            Text("Last.fm asked the app to slow down. Waiting \(seconds) s, then it carries on.")
        } else if let targetedTitle {
            Text(targetedTitle)
        } else if isFirstImport, progress?.mode.isFullHistory ?? true, progress?.phase != .lovedTracks {
            Text(progress?.phase == .scrobbles ? "Importing your history…" : "Preparing to import your history…")
        } else {
        switch progress?.phase {
        case .scrobbles:
            switch progress?.mode {
            case .full:
                Text("Full resync in progress…")
            case .resumedBackfill:
                Text("Resuming full resync…")
            case .reconciliationBackfill:
                Text("Change detected · Reconciling full history…")
            case .incremental, .none:
                Text("Syncing scrobbles…")
            }
        case .lovedTracks:
            if progress?.mode.isFullHistory == true {
                Text("Full history checked · Updating loved tracks…")
            } else if let newScrobbles = progress?.newScrobbles, newScrobbles > 0 {
                if newScrobbles == 1 {
                    Text("1 new scrobble synced · Updating loved tracks…")
                } else {
                    Text("\(newScrobbles.formatted()) new scrobbles synced · Updating loved tracks…")
                }
            } else {
                Text("Scrobbles up to date · Updating loved tracks…")
            }
        case .preparing:
            switch progress?.mode {
            case .full:
                Text("Preparing full resync…")
            case .resumedBackfill:
                Text("Preparing to resume full resync…")
            case .reconciliationBackfill, .incremental, .none:
                Text("Preparing sync…")
            }
        case .none:
            Text("Preparing sync…")
        }
        }
    }

    private func progressDetail(_ progress: SyncProgress) -> String {
        guard progress.mode.isFullHistory else {
            return "\(progress.totalScrobbles.formatted()) total · \(progress.newScrobbles.formatted()) new"
        }
        if progress.phase == .preparing || progress.processedScrobbles == 0 {
            return "\(progress.totalScrobbles.formatted()) scrobbles to check"
        }
        let checked = min(progress.processedScrobbles, progress.totalScrobbles)
        if isFirstImport {
            let base = "\(checked.formatted()) of \(progress.totalScrobbles.formatted()) scrobbles"
            return state.remainingText.map { "\(base) · \($0)" } ?? base
        }
        let base = "\(checked.formatted()) of \(progress.totalScrobbles.formatted()) checked"
        return state.remainingText.map { "\(base) · \($0)" } ?? base
    }
}
