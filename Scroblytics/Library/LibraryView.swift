import SwiftUI
import SwiftData

/// Library's own tab set — Artists/Albums only. There is deliberately no Tracks
/// tab: loading the full list of tracks is slow, and most people browse by
/// Artist or Album and drill down. A Tags tab is deferred alongside Tags
/// Browsing/Writing.
enum LibraryTab: String, CaseIterable, Identifiable {
    case artist, album
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .artist: return "Artists"
        case .album: return "Albums"
        }
    }
    var chartsEntity: TopChartsEntity {
        switch self {
        case .artist: return .artist
        case .album: return .album
        }
    }
}

/// New top-level page for all-time library browsing (Phase 1 of a staged
/// build: basic A-Z tabs/list/grid here; the A-Z jump strip and origin-
/// aware detail-page sort defaults land in later passes on this same
/// foundation). The mini-overview row (Last played/Recently added/Long
/// term relationships/Turnover spotlight) is deliberately NOT built yet —
/// held back pending a further design pass, not an oversight.
///
/// All-time, independent of the toolbar Date range — matches
/// library-page-prompt.md's explicit scope ("same category as Milestones/
/// Tools, not Top Charts/Trends"). Reuses `TopChartsEngine.fetchRankings`
/// for entity identity/artwork/album-merge handling (its ranking is
/// discarded here — Library re-sorts alphabetically instead), and drills
/// into the SAME `ArtistDetailView`/`AlbumDetailView` Top Charts already
/// uses. The shared drill-down detail page is the one piece Library and Top
/// Charts genuinely have in common; the tab/list-grid browsing surface itself
/// is not shared, so Library has its own top-level browsing view.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    let modelContainer: ModelContainer
    let settings: ChartDateSettings
    let isActive: Bool
    let navigation: DetailNavigationCoordinator
    @State private var oldestScrobbleDate: Date?
    @State private var tab: LibraryTab = .artist
    @State private var entries: [TopChartEntry] = []
    @State private var sections: [LibrarySection] = []
    @State private var availableSectionLetters: Set<String> = []
    @State private var firstEntryIDBySection: [String: UUID] = [:]
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var latestRequestID = UUID()
    @State private var reloadDebounceTask: Task<Void, Never>?
    @State private var hasLoaded = false
    @State private var needsReload = false

    private var rangeOptions: [DateRangeOption] {
        DateRangePresets.build(oldestScrobbleDate: oldestScrobbleDate)
    }
    private var currentRange: DateRange {
        (rangeOptions.first { $0.id == settings.selectedRangeId } ?? rangeOptions[0]).range()
    }
    private var compareRange: DateRange? { settings.resolveCompareRange(for: currentRange) }

    var body: some View {
        NavigationStack(path: Binding(
            get: { navigation.path },
            set: { navigation.path = $0 }
        )) {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .overlay(alignment: .topTrailing) {
                if isLoading, !entries.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                } else if let errorMessage, !entries.isEmpty {
                    Text(errorMessage)
                        .font(AppTypography.compactMetadata)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: ArtistIdentity.self) { ArtistDetailView(identity: $0, settings: settings, navigation: navigation) }
            .navigationDestination(for: AlbumIdentity.self) { AlbumDetailView(identity: $0, settings: settings, navigation: navigation) }
            .navigationDestination(for: TrackIdentity.self) { TrackDetailView(identity: $0, settings: settings, navigation: navigation) }
        }
        .task(id: isActive) { await loadIfNeeded() }
        .onChange(of: tab) { requestReload() }
        .onChange(of: settings.selectedRangeId) { requestReload() }
        .onChange(of: settings.compareMode) { requestReload() }
        .onChange(of: settings.compareCustomDate) { requestReload() }
        .onChange(of: settings.metric) { requestReload() }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            oldestScrobbleDate = nil
            requestReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { _ in
            requestReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: modelContext)) { note in
            // `didSave` fires for EVERY write anywhere in the app — including
            // ones with nothing to do with what Library shows, like a
            // turnover-classifier tracklist getting cached in the background
            // (`AlbumTracklistCacheEntry`) or a Fix UI match-resolution save.
            // Confirmed directly: with a cold tracklist cache, those saves
            // can fire every ~100ms-1s while it warms up, and a naive
            // reload-on-every-save (even debounced) never let the expensive
            // full-library re-rank (`fetchRankings`, up to `Int.max` albums)
            // finish before the next save superseded it — the page looked
            // permanently stuck loading, most visibly right after a scroll
            // re-render. The real fix is to only reload for entity types
            // Library actually displays; everything else is ignored outright
            // rather than merely delayed.
            guard !ImageResolutionEngine.isBulkResolving,
                  didSaveTouchesLibraryRelevantEntity(note) else { return }
            guard isActive else {
                needsReload = true
                return
            }
            reloadDebounceTask?.cancel()
            reloadDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
    }

    private func loadIfNeeded() async {
        guard isActive, !hasLoaded || needsReload else { return }
        if oldestScrobbleDate == nil {
            oldestScrobbleDate = try? await TopChartsEngine.fetchOldestScrobbleDate(container: modelContainer)
        }
        needsReload = false
        await reload()
        hasLoaded = true
    }

    private func requestReload() {
        needsReload = true
        if isActive { Task { await loadIfNeeded() } }
    }

    private var header: some View {
        PageSettingsHeader("Library") {
            VStack(alignment: .leading, spacing: 10) {
                ChartFilterBar(
                    settings: settings,
                    rangeOptions: rangeOptions,
                    currentRange: currentRange,
                    usesTimelineMetricPicker: true
                )
                EntityPresentationRow(selectorWidth: 200, isGridView: settings.binding(for: tab.chartsEntity, context: .library)) {
                    Picker("Library section", selection: $tab) {
                        ForEach(LibraryTab.allCases) { tab in
                            Text(tab.displayName).tag(tab)
                        }
                    }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, entries.isEmpty {
            Text(errorMessage).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            HistoryEmptyState { Text("No scrobbles yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        } else {
            ScrollViewReader { proxy in
                // A `ZStack` overlay, not an `HStack` sibling — verified
                // directly that an `HStack`-adjacent jump strip silently
                // failed to receive clicks specifically next to the grid's
                // `ScrollView` (never reproduced next to `List`, and
                // spacing/z-order tweaks didn't fix it). Floating the strip
                // on top sidesteps whatever hit-testing conflict that was.
                ZStack(alignment: .topTrailing) {
                    Group {
                        if settings.isGridView(for: tab.chartsEntity, context: .library) {
                            ScrollView {
                                LazyVGrid(
                                    columns: [GridItem(
                                        .adaptive(
                                            minimum: AppArtworkSizing.tileMinimum,
                                            maximum: AppArtworkSizing.tileMaximum
                                        ),
                                        spacing: AppArtworkSizing.tileSpacing
                                    )],
                                    alignment: .leading,
                                    spacing: AppArtworkSizing.tileSpacing,
                                    pinnedViews: [.sectionHeaders]
                                ) {
                                    ForEach(sections) { section in
                                        Section {
                                            ForEach(section.entries) { entry in
                                                drillLink(for: entry) {
                                                    LibraryGridCell(entity: tab.chartsEntity, entry: entry)
                                                }
                                                .drillDownHighlight()
                                                .id(entry.id)
                                            }
                                        } header: {
                                            sectionHeader(section.letter)
                                                .id(section.letter)
                                        }
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical)
                                .padding(.trailing, 30)
                            }
                        } else {
                            List {
                                ForEach(sections) { section in
                                    Section {
                                        ForEach(section.entries) { entry in
                                            drillLink(for: entry) {
                                                LibraryRow(entity: tab.chartsEntity, entry: entry)
                                            }
                                            .drillDownHighlight()
                                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                            .id(entry.id)
                                        }
                                    } header: {
                                        sectionHeader(section.letter)
                                    }
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // The two layouts need different `ScrollViewReader`
                    // targets — verified directly, not assumed identical:
                    // `List`'s own Section-level `.id()` didn't reliably
                    // scroll on macOS (its first ROW id does), while the
                    // grid's plain `LazyVStack`+`Section` header DOES scroll
                    // correctly by its own `.id()` (unlike a `List` Section).
                    AZJumpStrip(availableLetters: availableSectionLetters) { letter in
                        if settings.isGridView(for: tab.chartsEntity, context: .library) {
                            proxy.scrollTo(letter, anchor: .top)
                        } else if let firstID = firstEntryIDBySection[letter] {
                            proxy.scrollTo(firstID, anchor: .top)
                        }
                    }
                    .background(.background)
                }
            }
        }
    }

    /// Library's ranking (`TopChartsEngine.fetchRankings`) is derived purely
    /// from `Scrobble`/`Artist`/`Album` rows — nothing else it reads can
    /// change what this page shows. `ModelContext.didSave`'s `userInfo`
    /// carries `PersistentIdentifier`s (not full model objects) precisely so
    /// a listener CAN check `entityName` without touching the database again.
    private func didSaveTouchesLibraryRelevantEntity(_ note: Notification) -> Bool {
        let relevantEntities: Set<String> = ["Scrobble", "Artist", "Album"]
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        for key in keys {
            guard let ids = note.userInfo?[key] as? [PersistentIdentifier] else { continue }
            if ids.contains(where: { relevantEntities.contains($0.entityName) }) { return true }
        }
        return false
    }

    private func sectionHeader(_ letter: String) -> some View {
        Text(letter)
            .font(AppTypography.sectionTitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.regularMaterial)
    }

    @ViewBuilder
    private func drillLink<Content: View>(for entry: TopChartEntry, @ViewBuilder content: () -> Content) -> some View {
        switch tab {
        case .artist:
            NavigationLink(value: ArtistIdentity(from: entry)) { content() }
                .entityContextMenu(target: ImageTarget(kind: .artist, artist: entry.name, album: nil, track: nil), currentImageURL: entry.imageURL)
        case .album:
            NavigationLink(value: AlbumIdentity(from: entry)) { content() }
                .entityContextMenu(target: ImageTarget(kind: .album, artist: entry.artist ?? "", album: entry.name, track: nil), currentImageURL: entry.imageURL)
        }
    }

    /// All-time, `includePeak: false`, `limit: .max` — same "rank the whole
    /// library, discard what we don't need" shape as `fetchYearlyTopRanks`/
    /// `fetchScopedRankings` already use elsewhere; the heavy grouping pass
    /// still runs off the main actor inside `fetchRankings` itself.
    private func reload() async {
        let requestID = UUID()
        latestRequestID = requestID
        errorMessage = nil
        isLoading = true
        let requestedTab = tab
        let requestedRange = currentRange
        let requestedCompareRange = compareRange
        let requestedMetric = settings.metric
        do {
            let ranked = try await TopChartsEngine.fetchRankings(
                container: modelContainer, durationContext: modelContext,
                entity: requestedTab.chartsEntity, range: requestedRange,
                compareRange: requestedCompareRange, limit: Int.max, includePeak: false,
                metric: requestedMetric
            )
            guard latestRequestID == requestID else { return }
            let prepared = await Task.detached(priority: .utility) {
                LibraryPreparedContent(entries: ranked)
            }.value
            entries = prepared.entries
            sections = prepared.sections
            availableSectionLetters = prepared.availableLetters
            firstEntryIDBySection = prepared.firstEntryIDBySection
        } catch {
            guard latestRequestID == requestID else { return }
            errorMessage = "Failed to load library: \(error)"
            if entries.isEmpty {
                sections = []
                availableSectionLetters = []
                firstEntryIDBySection = [:]
            }
        }
        isLoading = false
    }
}

private struct LibrarySection: Identifiable, Sendable {
    let letter: String
    let entries: [TopChartEntry]
    var id: String { letter }
}

private struct LibraryPreparedContent: Sendable {
    let entries: [TopChartEntry]
    let sections: [LibrarySection]
    let availableLetters: Set<String>
    let firstEntryIDBySection: [String: UUID]

    init(entries unsortedEntries: [TopChartEntry]) {
        let entries = unsortedEntries.sorted {
            TextNormalization.sortableName($0.name).localizedStandardCompare(TextNormalization.sortableName($1.name)) == .orderedAscending
        }
        var order: [String] = []
        var entriesByLetter: [String: [TopChartEntry]] = [:]
        for entry in entries {
            let letter = TextNormalization.sectionLetter(TextNormalization.sortableName(entry.name))
            if entriesByLetter[letter] == nil {
                order.append(letter)
            }
            entriesByLetter[letter, default: []].append(entry)
        }

        let sections = order.map { LibrarySection(letter: $0, entries: entriesByLetter[$0] ?? []) }
        self.entries = entries
        self.sections = sections
        availableLetters = Set(order)
        firstEntryIDBySection = Dictionary(uniqueKeysWithValues: sections.compactMap { section in
            section.entries.first.map { (section.letter, $0.id) }
        })
    }
}

/// Genuinely new — confirmed against real source that no shared "A-Z jump
/// strip" component exists even there; Library's own list view, its grid
/// view, and an unrelated Timeline feature each roll their own version of
/// this idea independently. A-Z only (no "#" bucket letters beyond that
/// single catch-all), disabled/dimmed for any letter with nothing in it.
private struct AZJumpStrip: View {
    let availableLetters: Set<String>
    let onSelect: (String) -> Void

    private static let letters: [String] = (0..<26).map { String(UnicodeScalar(65 + $0)!) } + ["#"]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Self.letters, id: \.self) { letter in
                let isAvailable = availableLetters.contains(letter)
                Button {
                    onSelect(letter)
                } label: {
                    Text(letter)
                        .font(AppTypography.indexStrip)
                        .foregroundStyle(isAvailable ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 18, height: 15)
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }
}

/// Deliberately no rank number, progress bar, or playcount — the PRD's
/// "NOT included (v1): stat/play-count number on tile" applies to every
/// Library row/tile, unlike Top Charts' own `TopChartRow`.
private struct LibraryRow: View {
    let entity: TopChartsEntity
    let entry: TopChartEntry

    var body: some View {
        HStack(spacing: 12) {
            EntityThumbnail(url: entry.imageURL, entity: entity)
                .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name).font(AppTypography.contentTitle).lineLimit(1)
                    PopularityMarker(entity: entity, entry: entry)
                    if entity == .track {
                        TrackFlaggedIndicator(
                            artist: entry.artist ?? "",
                            track: entry.name,
                            font: AppTypography.metadata
                        )
                    }
                }
                if let subtitle = entry.artist {
                    Text(subtitle).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

private struct LibraryGridCell: View {
    let entity: TopChartsEntity
    let entry: TopChartEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EntityThumbnail(url: entry.imageURL, entity: entity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 4) {
                Text(entry.name).font(AppTypography.compactTitle).lineLimit(1)
                PopularityMarker(entity: entity, entry: entry)
                if entity == .track {
                    TrackFlaggedIndicator(
                        artist: entry.artist ?? "",
                        track: entry.name,
                        font: AppTypography.compactMetadata
                    )
                }
            }
            if let subtitle = entry.artist {
                Text(subtitle).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
