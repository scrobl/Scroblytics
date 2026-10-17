import SwiftUI
import SwiftData

/// Sendable bundle of every purely-local Overview card's computed result —
/// crosses back from `computeOverviewLocals`'s background task in one hop
/// instead of assigning ten separate `@State` vars mid-computation.
private struct OverviewLocalResult: Sendable {
    let last24HourSlots: [(date: Date, hour: Int, count: Int)]
    let streakResult: ListeningStreakResult
    let totals: OverviewTotals
    let topArtistTrend: [TrendBucket]
    let topAlbumTrend: [TrendBucket]
    let topTrackTrend: [TrendBucket]
    let recentScrobbles: [RecentScrobbleEntry]
    let onThisDayEntries: [OnThisDayEntry]
    let longTailStats: LongTailStats?
    let recentMostOftenEntries: [OverviewRecentMostOftenDisplay]
    let climbingEntries: [OverviewClimbingDisplay]
    let fadingFavoritesEntries: [FadingFavoriteEntry]
    let milestoneEntries: [MilestoneUpcoming]
    let almostMilestones: [MilestoneUpcoming]
}

private struct OverviewMetricCacheKey: Hashable {
    let rangeID: String
    let compareMode: String
    let compareCustomDate: Date?
    let metric: String
}

private struct OverviewMetricResult {
    let totals: OverviewTotals
    let topArtistTrend: [TrendBucket]
    let topAlbumTrend: [TrendBucket]
    let topTrackTrend: [TrendBucket]
    let recentScrobbles: [RecentScrobbleEntry]
    let longTailStats: LongTailStats?
    let timeListenedSeconds: Int?
}

/// Runs every local (non-network) Overview engine and bundles the results.
/// Deliberately a free function rather than a method on `OverviewView` —
/// SwiftUI's `View` protocol carries implicit `@MainActor` isolation, which
/// would propagate to a method and force it back onto the main actor even
/// when called from `Task.detached`, defeating the whole point of detaching.
private func overviewMilestoneWithResolvedImage(
    _ milestone: MilestoneUpcoming,
    lookup: [String: String]
) -> MilestoneUpcoming {
    let target: ImageTarget
    switch milestone.entity {
    case .artist:
        target = ImageTarget(kind: .artist, artist: milestone.name, album: nil, track: nil)
    case .album:
        target = ImageTarget(kind: .album, artist: milestone.artist ?? "", album: milestone.name, track: nil)
    case .track:
        target = ImageTarget(kind: .track, artist: milestone.artist ?? "", album: milestone.album, track: milestone.name)
    }

    return MilestoneUpcoming(
        entity: milestone.entity,
        artist: milestone.artist,
        name: milestone.name,
        album: milestone.album,
        imageURL: ImageResolutionEngine.effectiveImageURL(
            for: target,
            lookup: lookup,
            fallbackURL: milestone.imageURL
        ),
        current: milestone.current,
        next: milestone.next,
        remaining: milestone.remaining,
        etaDays: milestone.etaDays
    )
}

private func computeOverviewLocals(
    scrobbles allScrobbles: [ScrobbleSnapshot], range: DateRange, compareRange: DateRange?,
    metric: TopChartsMetric = .scrobbles, durationLookup: [String: Int] = [:], lovedSet: Set<String> = [],
    imageLookup: [String: String] = [:]
) -> OverviewLocalResult {
    // Both independent of the page's date range (fixed rolling 24h window /
    // fixed trailing 30-day window) and computed entirely
    // locally over already-synced data — no caching concern, no network calls.
    let last24HourSlots = HeatmapEngine.rollingLast24Hours(scrobbles: allScrobbles, anchor: Date())
    let streakResult = ListeningStreakEngine.fetch(scrobbles: allScrobbles)

    let totals = OverviewTotalsEngine.fetch(scrobbles: allScrobbles, range: range, compareRange: compareRange, metric: metric, durationLookup: durationLookup, lovedSet: lovedSet, imageLookup: imageLookup)

    // Top Picks' sparklines — scoped per kind: artist-
    // only for Top artist, artist+album for Top album, artist+track (no
    // album) for Top track. Purely local, so these run unconditionally
    // alongside totals rather than needing their own caching or credential gate.
    let topArtistTrend = totals.topArtist.map {
        TrendEngine.fetch(scrobbles: allScrobbles, artist: $0.name, album: nil, track: nil, range: range)
    } ?? []
    let topAlbumTrend = totals.topAlbum.map {
        TrendEngine.fetch(scrobbles: allScrobbles, artist: $0.artist, album: $0.name, track: nil, range: range)
    } ?? []
    let topTrackTrend = totals.topTrack.map {
        TrendEngine.fetch(scrobbles: allScrobbles, artist: $0.artist, album: nil, track: $0.name, range: range)
    } ?? []

    // Bottom-of-page recent-scrobbles table — purely local, same compare
    // window as Listening Totals/Top Picks.
    let recentScrobbles = RecentScrobblesEngine.fetch(
        scrobbles: allScrobbles, range: range, compareRange: compareRange,
        metric: metric, durationLookup: durationLookup, lovedSet: lovedSet,
        imageLookup: imageLookup
    )

    // On this day is always "today, every year" — independent of the
    // toolbar range, by design. The
    // card itself only surfaces *previous* years (never today's own
    // scrobbles) and randomly samples 3 from the full qualifying pool on
    // each load — by design, not just a backend ranking.
    let onThisDayPool = OnThisDayEngine.excludingCurrentYear(OnThisDayEngine.fetch(scrobbles: allScrobbles)).map { entry in
        let target = ImageTarget(
            kind: .track,
            artist: entry.artist,
            album: entry.album,
            track: entry.track
        )
        let imageURL = ImageResolutionEngine.effectiveImageURL(
            for: target,
            lookup: imageLookup,
            fallbackURL: entry.imageURL
        )
        return OnThisDayEntry(
            track: entry.track,
            artist: entry.artist,
            album: entry.album,
            imageURL: imageURL,
            playcount: entry.playcount,
            years: entry.years,
            lastPlayed: entry.lastPlayed
        )
    }
    let onThisDayEntries = OverviewRandomSample.pickThree(from: onThisDayPool)

    let longTailStats = LongTailEngine.fetch(
        scrobbles: allScrobbles, range: range, metric: metric, durationLookup: durationLookup
    )

    // Own fixed 90-day discovery window, independent of the page's date range
    // — matches the card's own standalone behavior. Randomly samples 3 from
    // the full qualifying pool on each load. Same engine and defaults as the
    // Tools page's own Most Recent, Most Often — one definition of "recent
    // discovery, already played a lot" (a velocity, not two raw thresholds),
    // not a second one that quietly drifts from it.
    let recentMostOftenPool = MostRecentMostOftenEngine.compute(
        scrobbles: allScrobbles, recencyWindowDays: 90, minPlays: 5, sort: .velocity
    )?.rows ?? []
    let recentMostOftenEntries = OverviewRandomSample.pickThree(from: recentMostOftenPool).map { row in
        let art = ImageResolutionEngine.resolvedTrackArtwork(artist: row.artist, track: row.title, scrobbles: allScrobbles, lookup: imageLookup)
        return OverviewRecentMostOftenDisplay(row: row, album: art.album, imageURL: art.imageURL)
    }

    // Own fixed 90-day comparison window, independent of the page's date
    // range — matches the card's own standalone behavior. Randomly samples 3
    // from the full qualifying pool on each load. Same engine and defaults as
    // the Tools page's own The Climb — a track only qualifies once it's
    // broken into a genuinely competitive rank tier, not just moved a large
    // raw distance somewhere in the long tail where that's mostly noise.
    let climbingPool = TheClimbEngine.compute(
        scrobbles: allScrobbles, compareDays: 90, minPlaysNow: 5, topN: 500
    )?.rows ?? []
    let climbingEntries = OverviewRandomSample.pickThree(from: climbingPool).map { row in
        let art = ImageResolutionEngine.resolvedTrackArtwork(artist: row.artist, track: row.title, scrobbles: allScrobbles, lookup: imageLookup)
        return OverviewClimbingDisplay(row: row, album: art.album, imageURL: art.imageURL)
    }

    // Range-scoped (unlike the three above) — snaps the page's date range to
    // the nearest allowed window and evaluates relative to the range's end.
    // Randomly samples 3 from the full
    // qualifying pool on each load.
    let fadingFavoritesEntries = OverviewRandomSample.pickThree(from: FadingFavoritesEngine.fetch(scrobbles: allScrobbles, range: range))

    // All-time, independent of the page's date range (milestones
    // track lifetime totals, not a windowed metric). Randomly
    // samples 3 from the mixed artist/album/track upcoming pool on each load.
    let milestonesResult = MilestonesEngine.fetch(scrobbles: allScrobbles)
    let milestoneCandidates = MilestonesEngine.overviewCandidates(from: milestonesResult).map {
        overviewMilestoneWithResolvedImage($0, lookup: imageLookup)
    }
    let milestoneEntries = OverviewRandomSample.pickThree(from: milestoneCandidates)
    // "Almost there": one scrobble from the next milestone, the closest 6 (three columns by two rows at full width).
    let almostMilestones = MilestonesEngine.almostThere(from: milestoneCandidates, limit: AlmostMilestonesSection.maxCards)

    return OverviewLocalResult(
        last24HourSlots: last24HourSlots, streakResult: streakResult, totals: totals,
        topArtistTrend: topArtistTrend, topAlbumTrend: topAlbumTrend, topTrackTrend: topTrackTrend,
        recentScrobbles: recentScrobbles, onThisDayEntries: onThisDayEntries, longTailStats: longTailStats,
        recentMostOftenEntries: recentMostOftenEntries, climbingEntries: climbingEntries,
        fadingFavoritesEntries: fadingFavoritesEntries, milestoneEntries: milestoneEntries,
        almostMilestones: almostMilestones
    )
}

private struct OverviewResponsiveLayout {
    private static let compactBreakpoint: CGFloat = 440
    private static let wideBreakpoint: CGFloat = 900
    private static let rhythmBreakpoint: CGFloat = 640
    private static let recentTableBreakpoint: CGFloat = 760
    private static let recentCompactBreakpoint: CGFloat = 500

    let width: CGFloat

    var listeningTotalsColumnCount: Int {
        if width >= Self.wideBreakpoint { return 4 }
        if width >= Self.compactBreakpoint { return 2 }
        return 1
    }
    var featureColumnCount: Int { width >= Self.wideBreakpoint ? 3 : 1 }
    var rhythmColumnCount: Int { width >= Self.rhythmBreakpoint ? 2 : 1 }
    var almostColumnCount: Int { AlmostMilestonesSection.columnCount(forWidth: width) }
    var recentScrobblesMode: RecentScrobblesLayoutMode {
        if width >= Self.recentTableBreakpoint { return .full }
        if width >= Self.recentCompactBreakpoint { return .condensed }
        return .compact
    }

    var featureColumns: [GridItem] {
        columns(count: featureColumnCount, spacing: 16)
    }

    var rhythmColumns: [GridItem] {
        columns(count: rhythmColumnCount, spacing: 16)
    }

    private func columns(count: Int, spacing: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }
}

private struct OverviewDataSnapshot: Sendable {
    let scrobbles: [ScrobbleSnapshot]
    let lovedSet: Set<String>
    let imageLookup: [String: String]
}

@ModelActor
private actor OverviewDataReader {
    func fetchSnapshot() async throws -> OverviewDataSnapshot {
        // The history is read once for every page (`ScrobbleHistoryCache`), already with artist spellings merged.
        let scrobbles = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: modelContainer)
        let lovedSet = Set(try modelContext.fetch(FetchDescriptor<LovedTrackEntry>()).map(\.cacheKey))
        var imageLookup: [String: String] = [:]

        for artist in try modelContext.fetch(FetchDescriptor<Artist>()) {
            let target = ImageTarget(kind: .artist, artist: artist.name, album: nil, track: nil)
            if let filename = artist.customImageFilename,
               let url = ImageStore.localCustomFileURL(for: filename) {
                imageLookup[ImageResolutionEngine.lookupKey(for: target)] = url.absoluteString
            } else if let filename = artist.detectedImageFilename,
                      let url = ImageStore.localCachedFileURL(for: filename) {
                imageLookup[ImageResolutionEngine.lookupKey(for: target)] = url.absoluteString
            }
        }

        for album in try modelContext.fetch(FetchDescriptor<Album>()) {
            guard let artistName = album.artist?.name else { continue }
            let target = ImageTarget(kind: .album, artist: artistName, album: album.title, track: nil)
            if let filename = album.customImageFilename,
               let url = ImageStore.localCustomFileURL(for: filename) {
                imageLookup[ImageResolutionEngine.lookupKey(for: target)] = url.absoluteString
            } else if let filename = album.detectedImageFilename,
                      let url = ImageStore.localCachedFileURL(for: filename) {
                imageLookup[ImageResolutionEngine.lookupKey(for: target)] = url.absoluteString
            }
        }

        for imageOverride in try modelContext.fetch(FetchDescriptor<AlbumImageOverride>()) {
            if let url = ImageStore.localCustomFileURL(for: imageOverride.filename) {
                imageLookup[ImageResolutionEngine.customAlbumLookupKey(
                    artist: imageOverride.artist,
                    album: imageOverride.album
                )] = url.absoluteString
            }
        }

        for track in try modelContext.fetch(FetchDescriptor<Track>()) {
            guard let artistName = track.artist?.name,
                  let filename = track.customImageFilename,
                  let url = ImageStore.localCustomFileURL(for: filename) else { continue }
            let target = ImageTarget(kind: .track, artist: artistName, album: nil, track: track.title)
            imageLookup[ImageResolutionEngine.lookupKey(for: target)] = url.absoluteString
        }

        return OverviewDataSnapshot(scrobbles: scrobbles, lovedSet: lovedSet, imageLookup: imageLookup)
    }

    func fetchOldestScrobbleDate() throws -> Date? {
        var descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.playedAt
    }
}

struct OverviewView: View {
    @Environment(\.modelContext) private var modelContext
    let settings: ChartDateSettings
    let isActive: Bool
    let openTopCharts: (TopChartsEntity) -> Void
    let openTool: (ToolDescriptor.Kind) -> Void
    let openSimilarSounds: ([SimilarSeed]) -> Void
    let openTrends: (TrendsFocus) -> Void
    let openMilestones: () -> Void
    /// Opens Query on a spec (a clicked hour or day of the strips below), with a name for it.
    let openQuery: (QuerySpec, String) -> Void

    @State private var navigation = DetailNavigationCoordinator(origin: .overview)
    @State private var oldestScrobbleDate: Date?
    @State private var onThisDayEntries: [OnThisDayEntry] = []
    @State private var longTailStats: LongTailStats?
    @State private var recentMostOftenEntries: [OverviewRecentMostOftenDisplay] = []
    @State private var climbingEntries: [OverviewClimbingDisplay] = []
    @State private var fadingFavoritesEntries: [FadingFavoriteEntry] = []
    @State private var milestoneEntries: [MilestoneUpcoming] = []
    @State private var almostMilestones: [MilestoneUpcoming] = []
    @State private var topTags: [TopTagEntry] = []
    @State private var topTagsLoading = false
    /// A refresh arrived while a Top Tags run was going; run once more when it ends.
    @State private var topTagsRerunRequested = false
    @State private var albumTurnoverEntries: [AlbumTurnoverEngine.AlbumTurnoverOverviewEntry] = []
    @State private var albumTurnoverLoading = false
    @State private var reverbPicks: [ReverbRow] = []
    @State private var reverbLoading = false
    @State private var totals: OverviewTotals?
    @State private var turnedOverCount: Int?
    @State private var turnedOverLoading = false
    private var overviewMetric: TopChartsMetric { settings.metric }
    @State private var timeListenedSeconds: Int?
    @State private var timeListenedLoading = false
    @State private var durationRemaining: Int?
    /// Cached from the last full `reload()` so a metric-only toggle (no
    /// range/compare change) can re-derive Top Picks/Listening Totals
    /// without re-fetching the whole scrobble table.
    @State private var allScrobbleSnapshots: [ScrobbleSnapshot] = []
    @State private var metricCache: [OverviewMetricCacheKey: OverviewMetricResult] = [:]
    @State private var topArtistTrend: [TrendBucket] = []
    @State private var topAlbumTrend: [TrendBucket] = []
    @State private var topTrackTrend: [TrendBucket] = []
    @State private var recentScrobbles: [RecentScrobbleEntry] = []
    @State private var last24HourSlots: [(date: Date, hour: Int, count: Int)] = []
    @State private var streakResult: ListeningStreakResult?
    @Environment(HistoryStatus.self) private var history: HistoryStatus?
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var needsReload = false

    /// Fires when synced data, the week-start setting or the Last.fm account changes: the page must recompute.
    private static let dataChanged = NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)
        .merge(with: NotificationCenter.default.publisher(for: .weekStartDidChange))
        .merge(with: NotificationCenter.default.publisher(for: .lastfmCredentialsDidChange))
    @State private var isReloading = false

    private var rangeOptions: [DateRangeOption] {
        DateRangePresets.build(oldestScrobbleDate: oldestScrobbleDate)
    }
    private var currentRange: DateRange {
        (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).range()
    }

    /// A recap of the period on screen, from the totals the page holds. Nil until they have loaded (and, by time listened, until the
    /// track lengths have).
    private func makeRecapCard() -> ShareCard? {
        guard let totals else { return nil }
        let option = rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]
        let isAllTime = option.id == "alltime"
        var compareLabel: String?
        if !isAllTime, settings.resolveCompareRange(for: currentRange) != nil {
            compareLabel = settings.compareMode == .custom
                ? settings.compareCustomDate.map { $0.formatted(date: .abbreviated, time: .omitted) }
                : settings.compareMode.label
        }
        return ShareCards.overviewRecap(ShareCards.OverviewRecapInput(
            totals: totals, metric: overviewMetric, timeListenedSeconds: timeListenedSeconds, periodLabel: option.label, isAllTime: isAllTime,
            compareLabel: compareLabel, firstScrobble: oldestScrobbleDate, currentStreak: streakResult?.currentStreak
        ))
    }

    private var similarSoundSeeds: [SimilarSeed] {
        var seen = Set<String>()
        return reverbPicks.compactMap { row in
            let artist = row.attributionSeed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, seen.insert(artist.lowercased()).inserted else { return nil }
            return SimilarSeed(kind: .artist, artist: artist, album: nil, track: nil)
        }
        .prefix(SimilarSoundsTool.seedLimit)
        .map { $0 }
    }

    private var colorWashImageURLs: [String] {
        [
            totals?.topArtist?.imageURL,
            totals?.topAlbum?.imageURL,
            totals?.topTrack?.imageURL
        ].compactMap { $0 }
    }

    var body: some View {
        NavigationStack(path: Binding(
            get: { navigation.path },
            set: { navigation.path = $0 }
        )) {
            GeometryReader { geometry in
                let layout = OverviewResponsiveLayout(width: geometry.size.width - 32)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        OverviewHeader(
                            settings: settings,
                            rangeOptions: rangeOptions,
                            currentRange: currentRange
                        )
                        .overlay(alignment: .topTrailing) {
                            ShareButton(card: { makeRecapCard() }, isEnabled: makeRecapCard() != nil)
                                .padding(.top, 6)
                        }
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(.secondary)
                        }
                        if history?.emptyReason != nil {
                            HistoryEmptyState { EmptyView() }
                                .frame(minHeight: 360)
                        } else {
                            PendingSyncEventBanners()
                            AlmostMilestonesSection(
                                milestones: almostMilestones,
                                columnCount: layout.almostColumnCount
                            )
                            ListeningTotalsSection(
                                totals: totals,
                                turnedOverCount: turnedOverCount,
                                turnedOverLoading: turnedOverLoading,
                                metric: overviewMetric,
                                timeListenedSeconds: timeListenedSeconds,
                                timeListenedLoading: timeListenedLoading,
                                durationRemaining: durationRemaining,
                                columnCount: layout.listeningTotalsColumnCount,
                                openTopCharts: openTopCharts,
                                openTrends: { openTrends(.listening) }
                            )
                            TopPicksSection(
                                topArtist: totals?.topArtist, topAlbum: totals?.topAlbum, topTrack: totals?.topTrack,
                                artistTrend: topArtistTrend, albumTrend: topAlbumTrend, trackTrend: topTrackTrend,
                                metric: overviewMetric,
                                columnCount: layout.featureColumnCount
                            )
                            LazyVGrid(columns: layout.rhythmColumns, alignment: .leading, spacing: 16) {
                                Last24HoursCard(
                                    slots: last24HourSlots, onOpen: { openTrends(.listening) },
                                    onSelectHour: { date, hour in
                                        let drill = OverviewDrill.hour(slotDate: date, hour: hour)
                                        openQuery(drill.spec, drill.detail)
                                    }
                                )
                                CurrentStreakCard(
                                    result: streakResult, onOpen: { openTrends(.listening) },
                                    onSelectDay: { key in
                                        guard let drill = OverviewDrill.day(key: key) else { return }
                                        openQuery(drill.spec, drill.detail)
                                    }
                                )
                            }
                            LazyVGrid(columns: layout.featureColumns, alignment: .leading, spacing: 16) {
                                OnThisDayCard(entries: onThisDayEntries, onOpen: { openTool(.timeMachine) })
                                MilestonesCard(entries: milestoneEntries, onOpen: openMilestones)
                                AlbumTurnoverCard(entries: albumTurnoverEntries, loading: albumTurnoverLoading, onOpen: { openTool(.albumTurnovers) })
                                RecentMostOftenCard(entries: recentMostOftenEntries, onOpen: { openTool(.mostRecentMostOften) })
                                ClimbingCard(entries: climbingEntries, onOpen: { openTool(.theClimb) })
                                FadingFavoritesCard(entries: fadingFavoritesEntries, onOpen: { openTool(.fadingFavorites) })
                                SimilarSoundsCard(
                                    picks: reverbPicks,
                                    loading: reverbLoading,
                                    onOpen: { openSimilarSounds(similarSoundSeeds) }
                                )
                                LongTailCard(stats: longTailStats, onOpen: { openTrends(.longTail) })
                                TopTagsCard(tags: topTags, loading: topTagsLoading, onOpen: { openTrends(.topTags) })
                            }
                            RecentScrobblesSection(entries: recentScrobbles, layoutMode: layout.recentScrobblesMode)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .environment(\.overviewIsLoading, !hasLoaded || isReloading)
                #if DEBUG
                .onChange(of: !hasLoaded || isReloading, initial: true) { _, loading in TestProfile.log("OVERVIEW loading=\(loading)") }
                #endif
            }
            .background {
                ColorWashView(imageURLs: colorWashImageURLs, strength: 0.62)
                    .ignoresSafeArea()
            }
            .partialDataNote()
            .navigationTitle("Overview")
            .overlay(alignment: .topTrailing) {
                if isReloading && hasLoaded {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing…")
                            .font(.callout)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .allowsHitTesting(false)
                }
            }
            .navigationDestination(for: ArtistIdentity.self) { ArtistDetailView(identity: $0, settings: settings, navigation: navigation) }
            .navigationDestination(for: AlbumIdentity.self) { AlbumDetailView(identity: $0, settings: settings, navigation: navigation) }
            .navigationDestination(for: TrackIdentity.self) { TrackDetailView(identity: $0, settings: settings, navigation: navigation) }
            .navigationDestination(for: ScrobbleHistoryRoute.self) { _ in
                ScrobbleHistoryView(modelContainer: modelContext.container)
            }
        }
        .task(id: isActive) { await loadIfNeeded() }
        .onChange(of: settings.selectedRangeId) { requestReload() }
        .onChange(of: settings.compareMode) { requestReload() }
        .onChange(of: settings.compareCustomDate) { requestReload() }
        .onChange(of: settings.metric) {
            if isActive { refreshMetricDependentPicks() } else { needsReload = true }
        }
        .onReceive(Self.dataChanged) { _ in
            oldestScrobbleDate = nil
            requestReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidProgress)) { _ in
            oldestScrobbleDate = nil
            requestReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { _ in
            requestReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { notification in
            guard let progress = notification.object as? DurationEngine.Progress else { return }
            durationRemaining = progress.isComplete ? nil : progress.remaining
            metricCache = metricCache.filter { $0.key.metric != TopChartsMetric.timeListened.rawValue }
            if overviewMetric == .timeListened {
                if isActive { refreshMetricDependentPicks() } else { needsReload = true }
            }
        }
    }

    private func loadIfNeeded() async {
        guard isActive, !isReloading, !hasLoaded || needsReload else { return }
        isReloading = true
        defer { isReloading = false }

        repeat {
            needsReload = false
            if oldestScrobbleDate == nil { await loadOldestScrobbleDate() }
            await reload()
            hasLoaded = true
        } while isActive && needsReload
    }

    private func requestReload() {
        needsReload = true
        if isActive { Task { await loadIfNeeded() } }
    }

    private func loadOldestScrobbleDate() async {
        let container = modelContext.container
        oldestScrobbleDate = try? await offMain { try await OverviewDataReader(modelContainer: container).fetchOldestScrobbleDate() }
    }

    private func reload() async {
        errorMessage = nil
        metricCache.removeAll()
        let range = currentRange
        // Shared with Top Charts via ChartDateSettings — same control, same
        // persisted value, so both pages' compare badges always agree on
        // what "the comparison period" means.
        let compareRange = settings.resolveCompareRange(for: range)
        let metric = overviewMetric
        do {
            // One shared fetch for every purely-local card below, instead of
            // each engine independently re-fetching and re-materializing the
            // whole Scrobble table. On a six-figure-scrobble library this was the
            // dominant cost of an Overview load (~11s across ~10 redundant
            // fetches, measured directly) — far more than any single card's
            // own computation.
            // Materializing the library and related lookup tables is itself
            // expensive at six-figure scrobble counts. Read and project them
            // through a dedicated SwiftData model actor so a post-sync refresh
            // never monopolizes the main actor before computation begins.
            let container = modelContext.container
            let dataSnapshot = try await offMain { try await OverviewDataReader(modelContainer: container).fetchSnapshot() }
            let snapshots = dataSnapshot.scrobbles
            allScrobbleSnapshots = snapshots

            // Duration resolution needs `DurationEngine`'s MainActor-bound
            // `ModelContext`, so (like `TopChartsEngine.fetchRankings`) it
            // happens here, BEFORE detaching for the pure, Sendable-only
            // local-cards pass, which just consumes a plain `[String: Int]`
            // lookup instead of resolving anything itself.
            let durationLookup: [String: Int]
            if metric == .timeListened {
                timeListenedLoading = true
                let inRange = snapshots.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
                durationLookup = await DurationEngine.resolveDurationLookup(context: modelContext, client: DeezerAPIClient(), scrobbles: inRange)
            } else {
                durationLookup = [:]
            }

            let lovedSet = dataSnapshot.lovedSet
            let imageLookup = dataSnapshot.imageLookup
            let result = await Task.detached(priority: .utility) {
                computeOverviewLocals(scrobbles: snapshots, range: range, compareRange: compareRange, metric: metric, durationLookup: durationLookup, lovedSet: lovedSet, imageLookup: imageLookup)
            }.value

            last24HourSlots = result.last24HourSlots
            streakResult = result.streakResult
            totals = result.totals
            // The "turned over" sub-stat is NOT included above — it needs a
            // live Last.fm call per never-before-seen album and can take
            // minutes on a cold cache (see AlbumTurnoverEngine.
            // fetchAllCompletions), so it's fetched as its own separate,
            // non-blocking task, separate from the fast Overview query.
            loadTurnedOverCount()
            if metric == .timeListened {
                let inRange = snapshots.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
                timeListenedSeconds = sumTimeListened(inRange, lookup: durationLookup)
                timeListenedLoading = false
            } else {
                timeListenedSeconds = nil
            }
            topArtistTrend = result.topArtistTrend
            topAlbumTrend = result.topAlbumTrend
            topTrackTrend = result.topTrackTrend
            recentScrobbles = result.recentScrobbles
            onThisDayEntries = result.onThisDayEntries
            longTailStats = result.longTailStats
            recentMostOftenEntries = result.recentMostOftenEntries
            climbingEntries = result.climbingEntries
            fadingFavoritesEntries = result.fadingFavoritesEntries
            milestoneEntries = result.milestoneEntries
            almostMilestones = result.almostMilestones
            metricCache[metricCacheKey(for: metric)] = OverviewMetricResult(
                totals: result.totals,
                topArtistTrend: result.topArtistTrend,
                topAlbumTrend: result.topAlbumTrend,
                topTrackTrend: result.topTrackTrend,
                recentScrobbles: result.recentScrobbles,
                longTailStats: result.longTailStats,
                timeListenedSeconds: timeListenedSeconds
            )
        } catch {
            errorMessage = "Failed to load Overview: \(error)"
        }

        // The three network-backed cards below each run as their own
        // fire-and-forget task rather than being awaited here, so a slow (or
        // stalled) Last.fm call never delays the fast local cards above —
        // same "renders immediately, fills in independently" pattern
        // already used for the turnover-count sub-stat. Each card shows its
        // own loading state and degrades to empty on failure instead of
        // blanking the whole page's error state.
        loadTopTags()
        loadAlbumTurnover()
        loadReverb()
    }

    /// Fire-and-forget: needs a live Last.fm call for any artist not yet
    /// tag-cached. Skips gracefully (empty) with no saved credentials.
    private func loadTopTags() {
        guard let credentials = LastfmCredentialsStore.load() else {
            topTags = []
            return
        }
        // One run at a time: every refresh used to start another run that looked up the same artists again. A refresh that
        // arrives while a run is going is remembered and run once when it ends, so the card still ends up current.
        if topTagsLoading {
            topTagsRerunRequested = true
            return
        }
        let range = currentRange
        topTagsLoading = true
        Task {
            // Offline mode: use only the tags already cached (no credentials means no lookups).
            topTags = (try? await TopTagsEngine.fetch(context: modelContext, range: range, credentials: ConnectivityGate.isOffline ? nil : credentials)) ?? []
            topTagsLoading = false
            if topTagsRerunRequested {
                topTagsRerunRequested = false
                loadTopTags()
            }
        }
    }

    /// Fire-and-forget: all-time, independent of the page's date range
    /// (turnover cycles are a lifetime listening
    /// pattern, not a windowed metric). Needs a live Last.fm call per
    /// evaluated album (up to 150, sequentially — see AlbumTurnoverEngine's
    /// own note), so this is the slowest of the three; skips gracefully
    /// with no saved credentials.
    private func loadAlbumTurnover() {
        guard let credentials = LastfmCredentialsStore.load() else {
            albumTurnoverEntries = []
            return
        }
        albumTurnoverLoading = true
        Task {
            let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
            if let turnovers = try? await AlbumTurnoverEngine.fetchRankings(context: modelContext, client: client) {
                albumTurnoverEntries = OverviewRandomSample.pickThree(from: AlbumTurnoverEngine.overviewCandidates(from: turnovers))
            } else {
                albumTurnoverEntries = []
            }
            albumTurnoverLoading = false
        }
    }

    /// Fire-and-forget: the candidate pool is the expensive part (external
    /// Last.fm calls per seed) and is cached per sync inside ReverbEngine —
    /// this call is a cache hit (near-instant) except right after a new
    /// sync. Independent of the page's date range (a
    /// fixed 14-day recent-listening window, not the global range filter).
    /// Each row's pick is its own fresh weighted-random draw, re-rolled on
    /// every load, per the PRD.
    private func loadReverb() {
        guard let credentials = LastfmCredentialsStore.load() else {
            reverbPicks = []
            return
        }
        reverbLoading = true
        Task {
            let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
            if let pool = try? await ReverbEngine.fetch(context: modelContext, client: client) {
                reverbPicks = [
                    ReverbEngine.weightedPick(pool.artists),
                    ReverbEngine.weightedPick(pool.albums),
                    ReverbEngine.weightedPick(pool.tracks),
                ].compactMap { $0 }
            } else {
                reverbPicks = []
            }
            reverbLoading = false
        }
    }

    /// Fire-and-forget: computes/reads the cached whole-library turnover
    /// completion map and filters it to the current range. Deliberately not
    /// awaited by `reload()` — a cold cache here can take minutes (whole
    /// library, not the 150-candidate cap the Overview Turnover card uses),
    /// so the rest of the page renders immediately while this fills in.
    private func loadTurnedOverCount() {
        guard let credentials = LastfmCredentialsStore.load() else {
            turnedOverCount = nil
            return
        }
        let range = currentRange
        turnedOverLoading = true
        Task {
            let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
            if let completions = try? await AlbumTurnoverEngine.fetchAllCompletions(context: modelContext, client: client) {
                turnedOverCount = AlbumTurnoverEngine.completedCount(in: completions, from: range.from, to: range.to)
            }
            turnedOverLoading = false
        }
    }

    /// Fire-and-forget, only attempted when the Metric toggle is actually
    /// switched to Time Listened — matches the on-demand-only philosophy
    /// every other resolver in this app follows (nothing pays the
    /// cold-cache Deezer cost until the value is actually requested). Deezer
    /// needs no credentials (public API), unlike the other network cards
    /// here, so this never skips for that reason — only re-entry is guarded.
    /// Re-derives all metric-dependent Overview values from the cached
    /// snapshots. Duration resolution remains on-demand, while switching back
    /// to Scrobbles is a network-free local computation.
    private func refreshMetricDependentPicks() {
        let metric = overviewMetric
        let cacheKey = metricCacheKey(for: metric)
        if let cached = metricCache[cacheKey] {
            applyMetricResult(cached)
            return
        }
        let range = currentRange
        let compareRange = settings.resolveCompareRange(for: range)
        let snapshots = allScrobbleSnapshots
        Task {
            let lookup: [String: Int]
            if metric == .timeListened {
                timeListenedLoading = true
                let inRange = snapshots.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
                lookup = await DurationEngine.resolveDurationLookup(
                    context: modelContext, client: DeezerAPIClient(), scrobbles: inRange
                )
                timeListenedSeconds = sumTimeListened(inRange, lookup: lookup)
                timeListenedLoading = false
            } else {
                lookup = [:]
                timeListenedSeconds = nil
            }

            let lovedSet = LovedTracksEngine.lovedSet(context: modelContext)
            let imageLookup = (try? ImageResolutionEngine.imageLookup(context: modelContext)) ?? [:]
            let result = await Task.detached(priority: .utility) {
                let totals = OverviewTotalsEngine.fetch(
                    scrobbles: snapshots, range: range, compareRange: compareRange,
                    metric: metric, durationLookup: lookup, lovedSet: lovedSet, imageLookup: imageLookup
                )
                let longTail = LongTailEngine.fetch(
                    scrobbles: snapshots, range: range, metric: metric, durationLookup: lookup
                )
                let recent = RecentScrobblesEngine.fetch(
                    scrobbles: snapshots, range: range, compareRange: compareRange,
                    metric: metric, durationLookup: lookup, lovedSet: lovedSet,
                    imageLookup: imageLookup
                )
                return (totals, longTail, recent)
            }.value
            guard overviewMetric == metric else { return }
            let artistTrend = result.0.topArtist.map {
                TrendEngine.fetch(scrobbles: snapshots, artist: $0.name, album: nil, track: nil, range: range)
            } ?? []
            let albumTrend = result.0.topAlbum.map {
                TrendEngine.fetch(scrobbles: snapshots, artist: $0.artist, album: $0.name, track: nil, range: range)
            } ?? []
            let trackTrend = result.0.topTrack.map {
                TrendEngine.fetch(scrobbles: snapshots, artist: $0.artist, album: nil, track: $0.name, range: range)
            } ?? []
            let cached = OverviewMetricResult(
                totals: result.0,
                topArtistTrend: artistTrend,
                topAlbumTrend: albumTrend,
                topTrackTrend: trackTrend,
                recentScrobbles: result.2,
                longTailStats: result.1,
                timeListenedSeconds: timeListenedSeconds
            )
            metricCache[cacheKey] = cached
            applyMetricResult(cached)
        }
    }

    private func metricCacheKey(for metric: TopChartsMetric) -> OverviewMetricCacheKey {
        OverviewMetricCacheKey(
            rangeID: settings.selectedRangeId,
            compareMode: settings.compareMode.rawValue,
            compareCustomDate: settings.compareCustomDate,
            metric: metric.rawValue
        )
    }

    private func applyMetricResult(_ result: OverviewMetricResult) {
        totals = result.totals
        topArtistTrend = result.topArtistTrend
        topAlbumTrend = result.topAlbumTrend
        topTrackTrend = result.topTrackTrend
        recentScrobbles = result.recentScrobbles
        longTailStats = result.longTailStats
        timeListenedSeconds = result.timeListenedSeconds
        timeListenedLoading = false
    }

    private func sumTimeListened(_ scrobbles: [ScrobbleSnapshot], lookup: [String: Int]) -> Int {
        scrobbles.reduce(0) { total, s in
            guard !s.trackName.isEmpty else { return total }
            return total + (lookup[TextNormalization.lovedKey(artist: s.artistName, track: s.trackName)] ?? 0)
        }
    }
}

private struct OverviewHeader: View {
    let settings: ChartDateSettings
    let rangeOptions: [DateRangeOption]
    let currentRange: DateRange

    var body: some View {
        PageSettingsHeader("Overview") {
            ChartFilterBar(
                settings: settings,
                rangeOptions: rangeOptions,
                currentRange: currentRange,
                usesTimelineMetricPicker: true
            )
        }
    }
}

// MARK: - Overview value chips

struct OverviewValueChip: View {
    let text: String
    var systemImage: String?
    var tint: Color?

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(AppTypography.badge.monospacedDigit())
        .foregroundStyle(tint ?? Color.primary.opacity(0.65))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            tint?.opacity(0.15) ?? Color.primary.opacity(0.1),
            in: Capsule()
        )
    }
}

/// The quiet "why is this here" affordance: an info icon whose tooltip names the seed(s) behind a recommendation.
/// Shared by Reverb ("Because you've listened to …") and Similar Sounds ("Because you like …") so the two read alike.
struct BecauseYouLikeInfo: View {
    let attribution: String
    var verb = "you like"

    var body: some View {
        Image(systemName: "info.circle")
            .font(AppTypography.metadata)
            .foregroundStyle(.tertiary)
            .help("Because \(verb) \(attribution)")
    }
}

/// A small bar plus the number for a 0–100 similarity match.
struct SimilarScoreBar: View {
    let score: Double

    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(Color.primary.opacity(0.1)).frame(width: 52, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor.opacity(0.8)).frame(width: 52 * max(0, min(1, score / 100)), height: 6)
                }
            Text(Int(score.rounded()).formatted()).monospacedDigit().frame(width: 26, alignment: .trailing)
        }
        .help("Last.fm match: \(Int(score.rounded())) / 100")
    }
}

// MARK: - On This Day

/// Whether the Overview's local data is still being computed. While it is, a card with nothing to show says it is loading
/// instead of claiming there is nothing ("No milestones approaching", "Nothing climbing right now", …).
private struct OverviewIsLoadingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    fileprivate var overviewIsLoading: Bool {
        get { self[OverviewIsLoadingKey.self] }
        set { self[OverviewIsLoadingKey.self] = newValue }
    }
}

/// A card's "nothing here" message, which reads "Loading…" (with a spinner) until the page has finished loading.
struct OverviewEmptyText: View {
    let message: String
    var font: Font = AppTypography.contentTitle
    @Environment(\.overviewIsLoading) private var loading

    init(_ message: String, font: Font = AppTypography.contentTitle) {
        self.message = message
        self.font = font
    }

    /// What is shown: the loading text while loading, the message once loaded.
    nonisolated static func text(message: String, loading: Bool) -> String { loading ? "Loading…" : message }

    var body: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            Text(Self.text(message: message, loading: loading)).font(font).foregroundStyle(.secondary)
        }
    }
}

private struct OnThisDayCard: View {
    let entries: [OnThisDayEntry]
    let onOpen: () -> Void

    var body: some View {
        OverviewCardContainer(title: "On This Day", systemImage: "calendar.circle.fill", onOpen: onOpen) {
            if entries.isEmpty {
                OverviewEmptyText("Nothing scrobbled on this day yet.", font: AppTypography.contentTitle)
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        NavigationLink(value: TrackIdentity(artist: entry.artist, name: entry.track, album: entry.album, imageURL: entry.imageURL)) {
                            HStack(spacing: 10) {
                            OverviewThumbnail(url: entry.imageURL)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(entry.track).font(AppTypography.contentTitle).lineLimit(1)
                                    TrackFlaggedIndicator(artist: entry.artist, track: entry.track, font: AppTypography.metadata)
                                }
                                Text(entry.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            OverviewValueChip(
                                text: entry.years.map(String.init).joined(separator: ", ")
                            )
                            }
                            .drillDownLabel()
                        }
                        .drillDownHighlight()
                        .entityContextMenu(
                            target: ImageTarget(kind: .track, artist: entry.artist, album: entry.album, track: entry.track),
                            currentImageURL: entry.imageURL
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Most Recent, Most Often

/// A Most Recent, Most Often row plus the artwork/album resolved for it — the row itself (shared with
/// the Tools page) carries neither, since that's a view-layer concern there too.
struct OverviewRecentMostOftenDisplay: Identifiable, Sendable {
    let row: MostRecentMostOftenRow
    let album: String?
    let imageURL: String?
    var id: QueryEntityID { row.id }
}

private struct RecentMostOftenCard: View {
    let entries: [OverviewRecentMostOftenDisplay]
    let onOpen: () -> Void

    var body: some View {
        OverviewCardContainer(title: "Most Recent, Most Often", systemImage: "sparkles", onOpen: onOpen) {
            if entries.isEmpty {
                OverviewEmptyText("No recent discoveries yet.", font: AppTypography.contentTitle)
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        let row = entry.row
                        NavigationLink(value: TrackIdentity(artist: row.artist, name: row.title, album: entry.album, imageURL: entry.imageURL)) {
                            HStack(spacing: 10) {
                            OverviewThumbnail(url: entry.imageURL)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(row.title).font(AppTypography.contentTitle).lineLimit(1)
                                    TrackFlaggedIndicator(artist: row.artist, track: row.title, font: AppTypography.metadata)
                                }
                                Text(row.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            OverviewValueChip(text: "\(row.plays) plays")
                            }
                            .drillDownLabel()
                        }
                        .drillDownHighlight()
                        .entityContextMenu(
                            target: ImageTarget(kind: .track, artist: row.artist, album: entry.album, track: row.title),
                            currentImageURL: entry.imageURL
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Climbing

/// A Climb row plus the artwork/album resolved for it — the row itself (shared with the Tools page)
/// carries neither, since that's a view-layer concern there too.
struct OverviewClimbingDisplay: Identifiable, Sendable {
    let row: TheClimbRow
    let album: String?
    let imageURL: String?
    var id: QueryEntityID { row.id }
}

private struct ClimbingCard: View {
    let entries: [OverviewClimbingDisplay]
    let onOpen: () -> Void

    var body: some View {
        OverviewCardContainer(title: "Climbing", systemImage: "arrow.up.right", onOpen: onOpen) {
            if entries.isEmpty {
                OverviewEmptyText("Nothing climbing right now.", font: AppTypography.contentTitle)
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        let row = entry.row
                        NavigationLink(value: TrackIdentity(artist: row.artist, name: row.title, album: entry.album, imageURL: entry.imageURL)) {
                            HStack(spacing: 10) {
                            OverviewThumbnail(url: entry.imageURL)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(row.title).font(AppTypography.contentTitle).lineLimit(1)
                                    TrackFlaggedIndicator(artist: row.artist, track: row.title, font: AppTypography.metadata)
                                }
                                Text(row.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            RankChangeBadge(rank: row.currentRank, previousRank: row.previousRank, hasCompareRange: true, showDelta: true, newLabel: "Hot Shot Debut", newColor: .purple)
                            }
                            .drillDownLabel()
                        }
                        .drillDownHighlight()
                        .entityContextMenu(
                            target: ImageTarget(kind: .track, artist: row.artist, album: entry.album, track: row.title),
                            currentImageURL: entry.imageURL
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Fading Favorites

private struct FadingFavoritesCard: View {
    let entries: [FadingFavoriteEntry]
    let onOpen: () -> Void

    var body: some View {
        OverviewCardContainer(title: "Fading Favorites", systemImage: "clock.arrow.circlepath", onOpen: onOpen) {
            if entries.isEmpty {
                OverviewEmptyText("Nothing fading right now.", font: AppTypography.contentTitle)
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        NavigationLink(value: TrackIdentity(artist: entry.artist, name: entry.track, album: entry.album, imageURL: entry.imageURL)) {
                            HStack(spacing: 10) {
                            OverviewThumbnail(url: entry.imageURL)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(entry.track).font(AppTypography.contentTitle).lineLimit(1)
                                    TrackFlaggedIndicator(artist: entry.artist, track: entry.track, font: AppTypography.metadata)
                                }
                                Text(entry.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            OverviewValueChip(text: "\(entry.peakPlaycount) at peak")
                            }
                            .drillDownLabel()
                        }
                        .drillDownHighlight()
                        .entityContextMenu(
                            target: ImageTarget(kind: .track, artist: entry.artist, album: entry.album, track: entry.track),
                            currentImageURL: entry.imageURL
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Milestones

private struct MilestonesCard: View {
    let entries: [MilestoneUpcoming]
    let onOpen: () -> Void

    var body: some View {
        OverviewCardContainer(title: "Milestones", systemImage: "trophy.fill", onOpen: onOpen) {
            if entries.isEmpty {
                OverviewEmptyText("No milestones approaching.", font: AppTypography.contentTitle)
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        milestoneLink(for: entry) {
                            HStack(spacing: 10) {
                                OverviewThumbnail(url: entry.imageURL)
                                    .frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(entry.name).font(AppTypography.contentTitle).lineLimit(1)
                                        if entry.entity == .track {
                                            TrackFlaggedIndicator(
                                                artist: entry.artist ?? "",
                                                track: entry.name,
                                                font: AppTypography.metadata
                                            )
                                        }
                                    }
                                    Text(entry.artist ?? "Artist").font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                MilestoneRemainingBadge(
                                    remaining: entry.remaining,
                                    next: entry.next
                                )
                            }
                            .drillDownLabel()
                        }
                        .drillDownHighlight()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func milestoneLink<Content: View>(for entry: MilestoneUpcoming, @ViewBuilder content: () -> Content) -> some View {
        switch entry.entity {
        case .artist:
            NavigationLink(value: ArtistIdentity(name: entry.name, imageURL: entry.imageURL)) { content() }
                .entityContextMenu(
                    target: ImageTarget(kind: .artist, artist: entry.name, album: nil, track: nil),
                    currentImageURL: entry.imageURL
                )
        case .album:
            NavigationLink(value: AlbumIdentity(artist: entry.artist ?? "", name: entry.name, imageURL: entry.imageURL)) { content() }
                .entityContextMenu(
                    target: ImageTarget(kind: .album, artist: entry.artist ?? "", album: entry.name, track: nil),
                    currentImageURL: entry.imageURL
                )
        case .track:
            NavigationLink(value: TrackIdentity(artist: entry.artist ?? "", name: entry.name, album: entry.album, imageURL: entry.imageURL)) { content() }
                .entityContextMenu(
                    target: ImageTarget(kind: .track, artist: entry.artist ?? "", album: entry.album, track: entry.name),
                    currentImageURL: entry.imageURL
                )
        }
    }
}

// MARK: - Top Tags

private struct TopTagsCard: View {
    let tags: [TopTagEntry]
    let loading: Bool
    let onOpen: () -> Void

    var body: some View {
        OverviewCardContainer(title: "Top Tags", systemImage: "tag.fill", onOpen: onOpen) {
            if loading, tags.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Resolving tags…").font(AppTypography.contentTitle).foregroundStyle(.secondary)
                }
            } else if tags.isEmpty {
                OverviewEmptyText("No tags resolved yet.", font: AppTypography.contentTitle)
            } else {
                // Chips scale by rank (size + saturation), not uniform pills —
                // the exact regression the PRD calls out from the first build.
                TagFlowLayout(spacing: 6) {
                    ForEach(Array(tags.prefix(8).enumerated()), id: \.offset) { index, entry in
                        let weight = tags.count > 1 ? 1 - (Double(index) / Double(tags.count - 1)) : 1
                        Text(entry.tag)
                            .font(AppTypography.contentTitle)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.55 + weight * 0.25), in: Capsule())
                            .foregroundStyle(Color.white.opacity(0.88 + weight * 0.12))
                            .help("\(entry.tag): \(entry.weight.formatted()) plays")
                    }
                }
            }
        }
    }
}

/// Minimal wrapping flow layout for tag chips (SwiftUI has no built-in one).
/// Internal (not private) — also reused by the Top Charts entity detail
/// header's milestone badge row, another small set of wrapping chips.
struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Album Turnover

private struct AlbumTurnoverCard: View {
    let entries: [AlbumTurnoverEngine.AlbumTurnoverOverviewEntry]
    let loading: Bool
    let onOpen: () -> Void

    var body: some View {
        OverviewCardContainer(title: "Album Turnovers", systemImage: "repeat", onOpen: onOpen) {
            if loading, entries.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking turnovers…").font(AppTypography.contentTitle).foregroundStyle(.secondary)
                }
            } else if entries.isEmpty {
                OverviewEmptyText("No albums close to a turnover right now.", font: AppTypography.contentTitle)
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        NavigationLink(value: AlbumIdentity(artist: entry.artist, name: entry.album, imageURL: entry.imageURL)) {
                            HStack(spacing: 10) {
                            OverviewThumbnail(url: entry.imageURL)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.album).font(AppTypography.contentTitle).lineLimit(1)
                                Text(entry.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(entry.missingCount) track\(entry.missingCount == 1 ? "" : "s") to go")
                                .font(AppTypography.badge)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            }
                            .drillDownLabel()
                        }
                        .drillDownHighlight()
                        .entityContextMenu(
                            target: ImageTarget(kind: .album, artist: entry.artist, album: entry.album, track: nil),
                            currentImageURL: entry.imageURL
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Listening Totals

private struct ListeningTotalsSection: View {
    let totals: OverviewTotals?
    let turnedOverCount: Int?
    let turnedOverLoading: Bool
    let metric: TopChartsMetric
    let timeListenedSeconds: Int?
    let timeListenedLoading: Bool
    let durationRemaining: Int?
    let columnCount: Int
    @Environment(LovedTracksStore.self) private var lovedTracksStore
    let openTopCharts: (TopChartsEntity) -> Void
    let openTrends: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Listening totals", systemImage: "chart.bar.xaxis").font(AppTypography.sectionTitle)
            if let totals {
                let turnedOverSub: String = {
                    if turnedOverLoading, turnedOverCount == nil { return "Turnover…" }
                    return "\((turnedOverCount ?? 0).formatted()) turned over"
                }()
                let firstTile: (label: String, value: String, sub: String) = {
                    if metric == .timeListened {
                        let value = timeListenedLoading && timeListenedSeconds == nil ? "…" : DurationEngine.formatTimeListened(timeListenedSeconds ?? 0)
                        let sub = durationRemaining.map { "\($0.formatted()) track lengths remaining" }
                            ?? "\(totals.scrobbles.formatted()) scrobbles"
                        return ("Time Listened", value, sub)
                    }
                    return ("Scrobbles", totals.scrobbles.formatted(), "\(String(format: "%.1f", totals.perDay)) / day")
                }()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: columnCount), spacing: 1) {
                    Button(action: openTrends) {
                        ListeningTotalTile(
                            label: firstTile.label, value: firstTile.value,
                            sub: firstTile.sub,
                            // The period-over-period badge is Scrobbles-based
                            // (no compare-range Time Listened total is computed —
                            // that would double the resolution cost for a
                            // secondary number) — suppressed rather than shown
                            // misleadingly against a Time Listened value.
                            current: totals.scrobbles, previous: metric == .scrobbles ? totals.compare?.scrobbles : nil
                        )
                    }
                    .drillDownHighlight()
                    topChartsButton(entity: .artist) {
                        ListeningTotalTile(
                            label: "Artists", value: totals.artists.formatted(),
                            sub: "\(totals.newArtists.formatted()) new",
                            current: totals.artists, previous: totals.compare?.artists
                        )
                    }
                    topChartsButton(entity: .album) {
                        ListeningTotalTile(
                            label: "Albums", value: totals.albums.formatted(), sub: turnedOverSub,
                            current: totals.albums, previous: totals.compare?.albums
                        )
                    }
                    topChartsButton(entity: .track) {
                        ListeningTotalTile(
                            // How many of the tracks played in the range are loved right now (the live loved list, so
                            // loving or unloving updates it at once).
                            label: "Tracks", value: totals.tracks.formatted(),
                            sub: "\(totals.trackKeys.intersection(lovedTracksStore.keys).count.formatted()) loved",
                            current: totals.tracks, previous: totals.compare?.tracks
                        )
                    }
                }
            } else {
                OverviewEmptyText("Not enough data yet.", font: AppTypography.metadata)
            }
        }
    }

    private func topChartsButton<Content: View>(entity: TopChartsEntity, @ViewBuilder content: () -> Content) -> some View {
        Button {
            openTopCharts(entity)
        } label: {
            content()
        }
        .drillDownHighlight()
    }
}

private struct ListeningTotalTile: View {
    let label: String
    let value: String
    let sub: String
    let current: Int
    let previous: Int?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(AppTypography.statLabel).foregroundStyle(.secondary)
                Text(value).font(AppTypography.statValue)
                Text(sub).font(AppTypography.metadata).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            ChangeIndicatorView(current: current, previous: previous)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
    }
}

/// Period-over-period
/// badge vs. the prior equivalent range. Nil `previous` (range too short to
/// compare) renders nothing.
private struct ChangeIndicatorView: View {
    let current: Int
    let previous: Int?

    var body: some View {
        if let previous {
            if previous == 0, current == 0 {
                EmptyView()
            } else if previous == 0 {
                badge(text: "New", systemImage: "arrow.up", color: AppColors.positiveBadge, foreground: .white)
            } else {
                let pct = OverviewTotalsEngine.percentChange(current: current, previous: previous) ?? 0
                if pct == 0 {
                    badge(text: "0%", systemImage: "minus", color: .gray, foreground: .primary)
                } else {
                badge(text: "\(abs(pct))%", systemImage: pct > 0 ? "arrow.up" : "arrow.down", color: pct > 0 ? AppColors.positiveBadge : .red, foreground: .white)
                }
            }
        }
    }

    private func badge(text: String, systemImage: String, color: Color, foreground: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(AppTypography.badge)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(foreground == .primary ? 0.2 : 1), in: Capsule())
    }
}

// MARK: - Top Picks

/// The "Top picks" row, minus the
/// colorwash-tinted background — that's shared with Reverb/Now Playing's
/// pipeline and deliberately deferred to be built once, not per-section.
private struct TopPicksSection: View {
    let topArtist: OverviewTopEntry?
    let topAlbum: OverviewTopEntry?
    let topTrack: OverviewTopEntry?
    let artistTrend: [TrendBucket]
    let albumTrend: [TrendBucket]
    let trackTrend: [TrendBucket]
    /// Same toggle Listening Totals uses — which entity wins each "Top
    /// artist/album/track" slot, and the number shown under it, both follow
    /// this rather than always ranking by plays.
    let metric: TopChartsMetric
    let columnCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Top picks", systemImage: "person.fill").font(AppTypography.sectionTitle)
            if topArtist == nil, topAlbum == nil, topTrack == nil {
                OverviewEmptyText("Not enough data yet.", font: AppTypography.metadata)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: columnCount), alignment: .leading, spacing: 1) {
                    if let topArtist {
                        NavigationLink(value: ArtistIdentity(name: topArtist.name, imageURL: topArtist.imageURL)) {
                            TopPickTile(role: "Top artist", entry: topArtist, trend: artistTrend, metric: metric, showsLovedStatus: false)
                        }
                        .drillDownHighlight()
                        .entityContextMenu(
                            target: ImageTarget(kind: .artist, artist: topArtist.name, album: nil, track: nil),
                            currentImageURL: topArtist.imageURL
                        )
                    }
                    if let topAlbum, let artist = topAlbum.artist {
                        NavigationLink(value: AlbumIdentity(artist: artist, name: topAlbum.name, imageURL: topAlbum.imageURL)) {
                            TopPickTile(role: "Top album", entry: topAlbum, trend: albumTrend, metric: metric, showsLovedStatus: false)
                        }
                        .drillDownHighlight()
                        .entityContextMenu(
                            target: ImageTarget(kind: .album, artist: artist, album: topAlbum.name, track: nil),
                            currentImageURL: topAlbum.imageURL
                        )
                    }
                    if let topTrack, let artist = topTrack.artist {
                        NavigationLink(value: TrackIdentity(artist: artist, name: topTrack.name, album: topTrack.album, imageURL: topTrack.imageURL)) {
                            TopPickTile(role: "Top track", entry: topTrack, trend: trackTrend, metric: metric, showsLovedStatus: true)
                        }
                        .drillDownHighlight()
                        .entityContextMenu(
                            target: ImageTarget(kind: .track, artist: artist, album: topTrack.album, track: topTrack.name),
                            currentImageURL: topTrack.imageURL
                        )
                    }
                }
            }
        }
    }
}

/// Reports the text side's rendered height so the artwork square beside it
/// can match, since SwiftUI's HStack doesn't stretch siblings to a common
/// height on its own.
private struct TileHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 72
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TopPickTile: View {
    let role: String
    let entry: OverviewTopEntry
    let trend: [TrendBucket]
    let metric: TopChartsMetric
    let showsLovedStatus: Bool
    @State private var contentHeight: CGFloat = 72

    private var metricLabel: String {
        if metric == .timeListened, let seconds = entry.timeListenedSeconds {
            return DurationEngine.formatTimeListened(seconds)
        }
        return "\(entry.playcount.formatted()) plays"
    }

    var body: some View {
        // Artwork sits flush against the tile's top-left corner (no padding,
        // no rounding — the one card
        // whose artwork isn't inset like the 48x48 thumbnails elsewhere).
        // Only the text side is padded. The artwork is square and matches
        // the text column's full height (measured via TileHeightKey) —
        // scaled to fit within that square (not cropped or stretched), so a
        // non-square source image letterboxes instead of losing content.
        HStack(alignment: .top, spacing: 12) {
            OverviewThumbnail(url: entry.imageURL, cornerRadius: 0, contentMode: .fit)
                .frame(width: contentHeight, height: contentHeight)
            VStack(alignment: .leading, spacing: 2) {
                Text(role).font(AppTypography.metadata).foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    Text(entry.name).font(AppTypography.contentTitle).lineLimit(1)
                    TrackLovedIndicator(
                        artist: entry.artist ?? "", track: entry.name,
                        initialValue: entry.loved, font: AppTypography.metadata,
                        enabled: showsLovedStatus
                    )
                }
                // Always reserve this line's height, even when there's no
                // artist to show (Top artist itself), so all three tiles
                // stay the same height rather than Top artist running one
                // line short.
                Text(entry.artist ?? " ")
                    .font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                    .opacity(entry.artist == nil ? 0 : 1)
                Text(metricLabel).font(AppTypography.metadata).foregroundStyle(.tertiary)
                TrendSparkline(buckets: trend)
                    .frame(height: 28)
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TileHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .onPreferenceChange(TileHeightKey.self) { contentHeight = $0 }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.3))
    }
}

/// Gradient-filled area sparkline —
/// straight segments between buckets rather than a monotone curve, with a
/// shared mouse-over tooltip for inspecting each bucket.
/// Internal (not private) — also reused by the Top Charts entity detail
/// header, which shows the same kind of inline trend indicator.
struct TrendSparkline: View {
    let buckets: [TrendBucket]

    @State private var hoveredIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let counts = buckets.map(\.count)
            if counts.count < 2 || counts.allSatisfy({ $0 == 0 }) {
                Color.clear
            } else {
                let maxValue = max(counts.max() ?? 0, 1)
                let stepX = counts.count > 1 ? geo.size.width / CGFloat(counts.count - 1) : 0
                let points: [CGPoint] = counts.enumerated().map { index, count in
                    let x = CGFloat(index) * stepX
                    let y = geo.size.height - (CGFloat(count) / CGFloat(maxValue)) * geo.size.height
                    return CGPoint(x: x, y: y)
                }
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(Color.accentColor, lineWidth: 1.5)

                    if let hoveredIndex {
                        let point = points[hoveredIndex]

                        Path { path in
                            path.move(to: CGPoint(x: point.x, y: 0))
                            path.addLine(to: CGPoint(x: point.x, y: geo.size.height))
                        }
                        .stroke(.secondary.opacity(0.55), lineWidth: 1)

                        Circle()
                            .fill(Color.accentColor)
                            .stroke(.background, lineWidth: 2)
                            .frame(width: 8, height: 8)
                            .position(point)

                        TrendSparklineTooltip(bucket: buckets[hoveredIndex])
                            .fixedSize()
                            .position(
                                x: min(max(point.x, 64), max(64, geo.size.width - 64)),
                                y: -36
                            )
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let progress = min(max(location.x / max(geo.size.width, 1), 0), 1)
                        hoveredIndex = Int((progress * CGFloat(buckets.count - 1)).rounded())
                    case .ended:
                        hoveredIndex = nil
                    }
                }
                .zIndex(hoveredIndex == nil ? 0 : 1)
            }
        }
    }
}

private struct TrendSparklineTooltip: View {
    let bucket: TrendBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(bucket.start, format: .dateTime.month(.abbreviated).day().year())
                .font(AppTypography.compactTitle)
            Text("Scrobbles: \(bucket.count.formatted())")
                .font(AppTypography.metadata)
                .foregroundStyle(Color.accentColor)
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }
}

// MARK: - Last 24 Hours

private struct Last24HoursCard: View {
    let slots: [(date: Date, hour: Int, count: Int)]
    let onOpen: () -> Void
    /// A click on an hour that has plays: the hour's day and its hour of the day.
    let onSelectHour: (Date, Int) -> Void

    private static let tooltipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEha")
        return formatter
    }()

    var body: some View {
        OverviewCardContainer(title: "Last 24 Hours", systemImage: "waveform.path.ecg", minHeight: nil, onOpen: onOpen) {
            if slots.isEmpty || slots.allSatisfy({ $0.count == 0 }) {
                OverviewEmptyText("No plays in the last 24 hours.", font: AppTypography.metadata)
            } else {
                let thresholds = HeatColorScale.computeThresholds(slots.map(\.count))
                HoverHeatStrip(items: slots.enumerated().map { index, slot in
                    HeatStripItem(
                        axisLabel: index % 3 == 0 ? "\(slot.hour)" : nil,
                        tooltip: "\(Self.tooltipFormatter.string(from: slot.date)) · \(slot.count.formatted()) \(slot.count == 1 ? "scrobble" : "scrobbles")",
                        color: HeatColorScale.cellColor(count: slot.count, thresholds: thresholds, hour: slot.hour),
                        onSelect: slot.count > 0 ? { onSelectHour(slot.date, slot.hour) } : nil
                    )
                })
            }
        }
    }
}

// MARK: - Current Streak

private struct CurrentStreakCard: View {
    let result: ListeningStreakResult?
    let onOpen: () -> Void
    /// A click on a day that has plays: the day's local date, "YYYY-MM-DD".
    let onSelectDay: (String) -> Void

    private static var utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let tooltipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = utcCalendar
        formatter.timeZone = utcCalendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d yyyy")
        return formatter
    }()

    var body: some View {
        let title = result.map {
            "Current streak: \($0.currentStreak) day\($0.currentStreak == 1 ? "" : "s") · Longest: \($0.longestStreak) day\($0.longestStreak == 1 ? "" : "s")"
        } ?? "Current streak"

        OverviewCardContainer(title: title, systemImage: "flame.fill", minHeight: nil, onOpen: onOpen) {
            if let result, !result.days.isEmpty {
                let thresholds = HeatColorScale.computeThresholds(result.days.map(\.count))
                HoverHeatStrip(items: result.days.enumerated().map { index, day in
                    HeatStripItem(
                        axisLabel: index % 5 == 0 ? "\(Self.utcCalendar.component(.day, from: day.utcDate))" : nil,
                        tooltip: "\(Self.tooltipFormatter.string(from: day.utcDate)) · \(day.count.formatted()) \(day.count == 1 ? "play" : "plays")",
                        color: HeatColorScale.cellColor(count: day.count, thresholds: thresholds, hour: 12, override: .purple),
                        onSelect: day.count > 0 ? { onSelectDay(day.date) } : nil
                    )
                })
            } else {
                OverviewEmptyText("Not enough data yet.", font: AppTypography.metadata)
            }
        }
    }
}

private struct HeatStripItem {
    let axisLabel: String?
    let tooltip: String
    let color: Color
    /// Makes the cell a button (a cell with nothing behind it has none).
    var onSelect: (() -> Void)? = nil
}

private struct HoverHeatStrip: View {
    let items: [HeatStripItem]

    @State private var hoveredIndex: Int?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item.axisLabel ?? "")
                        .font(AppTypography.chartAxis)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.color)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .overlay {
                            if hoveredIndex == index {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            hoveredIndex = isHovering ? index : nil
                        }
                        .onTapGesture { item.onSelect?() }
                        .pointerStyle(item.onSelect != nil ? .link : .default)
                        .accessibilityLabel(item.tooltip)
                        .accessibilityAddTraits(item.onSelect != nil ? .isButton : [])
                        .accessibilityHint(item.onSelect != nil ? "Opens this period in Query" : "")
                        .zIndex(hoveredIndex == index ? 1 : 0)
                }
            }
            .overlay {
                GeometryReader { geometry in
                    if let hoveredIndex, items.indices.contains(hoveredIndex) {
                        let spacing = CGFloat(max(items.count - 1, 0)) * 2
                        let cellWidth = (geometry.size.width - spacing) / CGFloat(items.count)
                        let cellCenter = CGFloat(hoveredIndex) * (cellWidth + 2) + cellWidth / 2
                        let tooltipHalfWidth = min(140, max(0, geometry.size.width / 2 - 8))
                        let tooltipCenter = min(
                            max(cellCenter, tooltipHalfWidth + 8),
                            geometry.size.width - tooltipHalfWidth - 8
                        )

                        Text(items[hoveredIndex].tooltip)
                            .font(AppTypography.compactTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .frame(maxWidth: min(280, geometry.size.width - 16))
                            .background(.regularMaterial, in: Capsule())
                            .overlay { Capsule().stroke(.separator.opacity(0.7), lineWidth: 1) }
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                            .position(x: tooltipCenter, y: -18)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

// MARK: - Similar Sounds

private struct SimilarSoundsCard: View {
    let picks: [ReverbRow]
    let loading: Bool
    let onOpen: () -> Void

    var body: some View {
        OverviewCardContainer(title: "Similar Sounds", systemImage: "dot.radiowaves.left.and.right", onOpen: onOpen) {
            if loading, picks.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finding picks…").font(AppTypography.contentTitle).foregroundStyle(.secondary)
                }
            } else if picks.isEmpty {
                OverviewEmptyText("Nothing to suggest yet.", font: AppTypography.contentTitle)
            } else {
                VStack(spacing: 8) {
                    ForEach(picks) { row in
                        drillLink(for: row) {
                            rowContent(row)
                        }
                        .drillDownHighlight()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func drillLink<Content: View>(for row: ReverbRow, @ViewBuilder content: () -> Content) -> some View {
        switch row.type {
        case .artist:
            NavigationLink(value: ArtistIdentity(name: row.name, imageURL: row.imageURL)) { content() }
                .entityContextMenu(
                    target: ImageTarget(kind: .artist, artist: row.name, album: nil, track: nil),
                    currentImageURL: row.imageURL
                )
        case .album:
            NavigationLink(value: AlbumIdentity(artist: row.artist, name: row.name, imageURL: row.imageURL)) { content() }
                .entityContextMenu(
                    target: ImageTarget(kind: .album, artist: row.artist, album: row.name, track: nil),
                    currentImageURL: row.imageURL
                )
        case .track:
            NavigationLink(value: TrackIdentity(artist: row.artist, name: row.name, album: row.album, imageURL: row.imageURL)) { content() }
                .entityContextMenu(
                    target: ImageTarget(kind: .track, artist: row.artist, album: row.album, track: row.name),
                    currentImageURL: row.imageURL
                )
        }
    }

    private func rowContent(_ row: ReverbRow) -> some View {
        let attribution = row.attributionSeed.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 8) {
            OverviewThumbnail(url: row.imageURL)
                .frame(width: 48, height: 48)
            Text(roleLabel(row.type))
                .font(AppTypography.metadata)
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(AppTypography.contentTitle).lineLimit(1)
                if row.artist != row.name {
                    Text(row.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !attribution.isEmpty {
                BecauseYouLikeInfo(attribution: attribution, verb: "you've listened to")
            }
            OverviewValueChip(
                text: ReverbEngine.formatStaleness(days: row.daysSinceLastPlayed)
            )
        }
        .drillDownLabel()
    }

    private func roleLabel(_ type: ReverbRowType) -> String {
        switch type {
        case .artist: return "Artist"
        case .album: return "Album"
        case .track: return "Track"
        }
    }
}

// MARK: - The Long Tail

private struct LongTailCard: View {
    let stats: LongTailStats?
    let onOpen: () -> Void

    var body: some View {
        OverviewCardContainer(title: "The Long Tail", systemImage: "chart.bar.xaxis", onOpen: onOpen) {
            if let stats {
                VStack(alignment: .leading, spacing: 10) {
                    sentence(stats)
                    statRow(stats)
                    Spacer(minLength: 0)
                    histogram(stats)
                }
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            } else {
                OverviewEmptyText("Not enough data yet.", font: AppTypography.contentTitle)
            }
        }
    }

    /// One complete sentence with the percentage emphasized inline — never a
    /// bare number pulled onto its own line (the exact regression the PRD
    /// calls out from the first build).
    private func sentence(_ stats: LongTailStats) -> some View {
        let entityWord = stats.entity == .artist ? "artists" : stats.entity == .album ? "albums" : "tracks"
        let percentString = String(format: "%.1f", stats.concentrationPercent)
        return (
            Text("Your top \(stats.topPercent)% of \(entityWord) account for ")
                .font(AppTypography.contentTitle)
            + Text("\(percentString)%")
                .font(AppTypography.contentTitle.bold())
                .foregroundColor(.accentColor)
            + Text(stats.metric == .scrobbles ? " of your plays." : " of your listening time.")
                .font(AppTypography.contentTitle)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private func statRow(_ stats: LongTailStats) -> some View {
        HStack(spacing: 16) {
            statTile("Mean", formattedValue(stats.mean, metric: stats.metric, decimals: true))
            statTile("Median", formattedValue(stats.median, metric: stats.metric))
            statTile("Max", formattedValue(Double(stats.max), metric: stats.metric))
        }
    }

    private func statTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(AppTypography.metadata).foregroundStyle(.secondary)
            Text(value).font(AppTypography.contentTitle.monospacedDigit())
        }
    }

    private func histogram(_ stats: LongTailStats) -> some View {
        let chartHeight: CGFloat = 76
        let minimumBarHeight: CGFloat = 3
        let minBin = stats.histogram.min() ?? 0
        let maxBin = stats.histogram.max() ?? 0
        let binRange = maxBin - minBin

        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(stats.histogram.enumerated()), id: \.offset) { index, count in
                let normalizedHeight = binRange > 0
                    ? CGFloat(count - minBin) / CGFloat(binRange)
                    : 1
                let valueRange = histogramValueRange(index: index, binCount: stats.histogram.count, maximum: stats.max)
                let entityName = stats.entity == .artist ? "artist" : stats.entity == .album ? "album" : "track"
                let rangeLabel = stats.metric == .scrobbles
                    ? "\(valueRange.lowerBound.formatted())–\(valueRange.upperBound.formatted()) plays"
                    : "\(DurationEngine.formatTimeListened(valueRange.lowerBound))–\(DurationEngine.formatTimeListened(valueRange.upperBound))"

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(height: minimumBarHeight + normalizedHeight * (chartHeight - minimumBarHeight))
                    .help(
                        "\(rangeLabel): "
                        + "\(count.formatted()) \(entityName)\(count == 1 ? "" : "s")"
                    )
            }
        }
        .frame(height: chartHeight, alignment: .bottom)
    }

    private func formattedValue(_ value: Double, metric: TopChartsMetric, decimals: Bool = false) -> String {
        if metric == .timeListened {
            return DurationEngine.formatTimeListened(Int(value.rounded()))
        }
        return String(format: decimals ? "%.1f" : "%.0f", value)
    }

    private func histogramValueRange(index: Int, binCount: Int, maximum: Int) -> ClosedRange<Int> {
        guard binCount > 0, maximum > 0 else { return 0...0 }
        let logMax = log(Double(maximum) + 1)
        let lowerBoundary = exp(logMax * Double(index) / Double(binCount)) - 1
        let upperBoundary = exp(logMax * Double(index + 1) / Double(binCount)) - 1
        let lower = max(1, Int(ceil(lowerBoundary)))
        let upper = index == binCount - 1
            ? maximum
            : max(lower, Int(ceil(upperBoundary)) - 1)
        return lower...upper
    }
}

// MARK: - Most Recent (recent scrobbles chart table)

private enum RecentScrobblesTableLayout {
    static let columnSpacing: CGFloat = 10
    static let currentRankWidth: CGFloat = 56
    static let previousRankWidth: CGFloat = 56
    static let movementWidth: CGFloat = 116
    static let artworkSize = AppArtworkSizing.thumbnail
    static let artworkTextSpacing: CGFloat = 20
    static let playedWidth: CGFloat = 120
    static let condensedRankWidth: CGFloat = 132
}

private enum RecentScrobblesLayoutMode {
    case full
    case condensed
    case compact
}

/// The bottom-of-page "Most recent" table
/// (`RecentScrobblesTableHeader`/`RecentScrobbleRow`) — the last section on
/// the Overview page. There is no "More…" link to a full Recent Scrobbles page. Rows show the loved heart.
private struct RecentScrobblesSection: View {
    let entries: [RecentScrobbleEntry]
    let layoutMode: RecentScrobblesLayoutMode

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Most recent", systemImage: "clock")
                        .font(AppTypography.sectionTitle)
                    Spacer()
                    NavigationLink(value: ScrobbleHistoryRoute()) {
                        HStack(spacing: 4) {
                            Text("View all")
                            Image(systemName: "chevron.right")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if layoutMode != .compact {
                        RecentScrobblesHeaderRow(layoutMode: layoutMode)
                        Divider()
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        NavigationLink(
                            value: TrackIdentity(
                                artist: entry.artist,
                                name: entry.track,
                                album: entry.album,
                                imageURL: entry.imageURL
                            )
                        ) {
                            RecentScrobbleRow(entry: entry, layoutMode: layoutMode)
                        }
                        .drillDownHighlight()
                        .entityContextMenu(
                            target: ImageTarget(kind: .track, artist: entry.artist, album: entry.album, track: entry.track),
                            currentImageURL: entry.imageURL
                        )
                        if index < entries.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct RecentScrobblesHeaderRow: View {
    let layoutMode: RecentScrobblesLayoutMode

    var body: some View {
        Group {
            if layoutMode == .full {
                HStack(spacing: RecentScrobblesTableLayout.columnSpacing) {
                    Text("This").frame(width: RecentScrobblesTableLayout.currentRankWidth, alignment: .center)
                    Text("Prev").frame(width: RecentScrobblesTableLayout.previousRankWidth, alignment: .center)
                    Text("Move").frame(width: RecentScrobblesTableLayout.movementWidth, alignment: .leading)
                    Color.clear.frame(width: RecentScrobblesTableLayout.artworkSize, height: 1)
                        .padding(.trailing, RecentScrobblesTableLayout.artworkTextSpacing - RecentScrobblesTableLayout.columnSpacing)
                    Text("Track").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Played").frame(width: RecentScrobblesTableLayout.playedWidth, alignment: .trailing)
                }
            } else {
                HStack(spacing: RecentScrobblesTableLayout.columnSpacing) {
                    Text("Rank").frame(width: RecentScrobblesTableLayout.condensedRankWidth, alignment: .leading)
                    Text("Track").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Played").frame(width: RecentScrobblesTableLayout.playedWidth, alignment: .trailing)
                }
            }
        }
        .font(AppTypography.tableHeading)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
    }
}

private struct RecentScrobbleRow: View {
    let entry: RecentScrobbleEntry
    let layoutMode: RecentScrobblesLayoutMode

    var body: some View {
        Group {
            switch layoutMode {
            case .full:
                fullRow
            case .condensed:
                condensedRow
            case .compact:
                compactRow
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var fullRow: some View {
        HStack(spacing: RecentScrobblesTableLayout.columnSpacing) {
            Text("\(entry.rank)")
                .font(AppTypography.tableRank)
                .lineLimit(1)
                .frame(width: RecentScrobblesTableLayout.currentRankWidth, alignment: .center)
            Text(entry.previousRank.map { "\($0)" } ?? "–")
                .font(AppTypography.tablePreviousValue)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: RecentScrobblesTableLayout.previousRankWidth, alignment: .center)
            RankMovementBadge(rank: entry.rank, previousRank: entry.previousRank, hasCompareRange: entry.hasCompareRange)
                .frame(width: RecentScrobblesTableLayout.movementWidth, alignment: .leading)
            trackIdentity
            playedText
                .frame(width: RecentScrobblesTableLayout.playedWidth, alignment: .trailing)
        }
    }

    private var condensedRow: some View {
        HStack(spacing: RecentScrobblesTableLayout.columnSpacing) {
            HStack(spacing: 6) {
                rankText
                RankMovementBadge(rank: entry.rank, previousRank: entry.previousRank, hasCompareRange: entry.hasCompareRange)
            }
            .frame(width: RecentScrobblesTableLayout.condensedRankWidth, alignment: .leading)
            trackIdentity
            playedText
                .frame(width: RecentScrobblesTableLayout.playedWidth, alignment: .trailing)
        }
    }

    private var compactRow: some View {
        HStack(alignment: .top, spacing: 12) {
            OverviewThumbnail(url: entry.imageURL, cornerRadius: 0)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(entry.track)
                        .font(AppTypography.contentTitle)
                        .lineLimit(2)
                    TrackLovedIndicator(
                        artist: entry.artist, track: entry.track,
                        initialValue: entry.loved, font: AppTypography.metadata
                    )
                }
                Text(entry.album.map { "\(entry.artist) · \($0)" } ?? entry.artist)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        compactMetadata
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            rankText
                            RankMovementBadge(rank: entry.rank, previousRank: entry.previousRank, hasCompareRange: entry.hasCompareRange)
                        }
                        playedText
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var compactMetadata: some View {
        rankText
        RankMovementBadge(rank: entry.rank, previousRank: entry.previousRank, hasCompareRange: entry.hasCompareRange)
        Spacer(minLength: 4)
        playedText
    }

    private var rankText: some View {
        Text("#\(entry.rank)")
            .font(AppTypography.tableValue)
            .lineLimit(1)
    }

    private var trackIdentity: some View {
        HStack(spacing: RecentScrobblesTableLayout.artworkTextSpacing) {
            OverviewThumbnail(url: entry.imageURL, cornerRadius: 0)
                .frame(width: RecentScrobblesTableLayout.artworkSize, height: RecentScrobblesTableLayout.artworkSize)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(entry.track)
                        .font(AppTypography.contentTitle)
                        .lineLimit(1)
                    TrackLovedIndicator(
                        artist: entry.artist, track: entry.track,
                        initialValue: entry.loved, font: AppTypography.metadata
                    )
                }
                Text(entry.album.map { "\(entry.artist) · \($0)" } ?? entry.artist)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playedText: some View {
        Text(AppDateFormatting.recentPlay.string(from: entry.playedAt))
            .font(AppTypography.metadata)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Rank-change indicator with the delta shown and the "Hot Shot Debut" label
/// in purple for new entries.
private struct RankMovementBadge: View {
    let rank: Int
    let previousRank: Int?
    let hasCompareRange: Bool

    var body: some View {
        if !hasCompareRange {
            Text("–").font(AppTypography.metadata).foregroundStyle(.tertiary)
        } else if let previousRank {
            if previousRank == rank {
                badge(text: nil, systemImage: "minus", color: .gray, foreground: .primary)
            } else {
                let improved = rank < previousRank
                badge(text: "\(abs(rank - previousRank))", systemImage: improved ? "arrow.up" : "arrow.down", color: improved ? AppColors.positiveBadge : .red, foreground: .white)
            }
        } else {
            badge(text: "Hot Shot Debut", systemImage: "arrow.up", color: .purple, foreground: .white)
        }
    }

    private func badge(text: String?, systemImage: String, color: Color, foreground: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            if let text { Text(text) }
        }
        .font(AppTypography.badge)
        .foregroundStyle(foreground)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(foreground == .primary ? 0.2 : 1), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Shared row interaction

struct DrillDownHighlightModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.clear)
            .contentShape(.interaction, Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.primary.opacity(isHovering ? 0.1 : 0))
                    .allowsHitTesting(false)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    func drillDownLabel() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.interaction, Rectangle())
    }

    func drillDownHighlight() -> some View {
        modifier(DrillDownHighlightModifier())
    }
}

// MARK: - Shared card chrome

private struct OverviewCardContainer<Content: View>: View {
    let title: String
    let systemImage: String
    /// The 3x3 Discover grid needs every card the same height; the header
    /// row cards (heatmap/streak strips, totals, top picks) size to their
    /// own content instead, so `nil` opts out.
    var minHeight: CGFloat? = 240
    var onOpen: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let onOpen {
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Label(title, systemImage: systemImage)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(AppTypography.compactMetadata)
                            .foregroundStyle(.tertiary)
                    }
                    .font(AppTypography.sectionTitle)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(title)")
            } else {
                Label(title, systemImage: systemImage).font(AppTypography.sectionTitle)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct OverviewThumbnail: View {
    let url: String?
    var cornerRadius: CGFloat = 4
    var contentMode: ContentMode = .fill

    var body: some View {
        ArtworkImage(urlString: url, contentMode: contentMode) {
            Color.clear.overlay(.quaternary)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
