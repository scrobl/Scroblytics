import SwiftUI
import SwiftData

/// "Similar Sounds": pick up to 10 seeds from your library, ask Last.fm what's similar, and see the library tracks
/// it found — scored and attributed. The candidate pool is shown in the shared Query results table, and refined with
/// real Field Registry conditions evaluated against ONLY that pool.
struct SimilarSoundsView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    var incomingSeeds: [SimilarSeed] = []

    struct Options: Codable, Equatable {
        var seeds: [SimilarSeed]
        var sort: SimilarSoundsSort
        /// 0 = no cap, for all three counts.
        var songLimit: Int
        var perArtist: Int
        var perAlbum: Int
        /// Also look for tracks Last.fm calls similar that you haven't played.
        var includeNew: Bool

        init(seeds: [SimilarSeed] = [], sort: SimilarSoundsSort = .matchScore, songLimit: Int = 50, perArtist: Int = 0, perAlbum: Int = 0, includeNew: Bool = false) {
            self.seeds = seeds
            self.sort = sort
            self.songLimit = songLimit
            self.perArtist = perArtist
            self.perAlbum = perAlbum
            self.includeNew = includeNew
        }

        private enum CodingKeys: String, CodingKey { case seeds, sort, songLimit, perArtist, perAlbum, includeNew }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            seeds = try values.decodeIfPresent([SimilarSeed].self, forKey: .seeds) ?? []
            sort = try values.decodeIfPresent(SimilarSoundsSort.self, forKey: .sort) ?? .matchScore
            songLimit = try values.decodeIfPresent(Int.self, forKey: .songLimit) ?? 50
            perArtist = try values.decodeIfPresent(Int.self, forKey: .perArtist) ?? 0
            perAlbum = try values.decodeIfPresent(Int.self, forKey: .perAlbum) ?? 0
            includeNew = try values.decodeIfPresent(Bool.self, forKey: .includeNew) ?? false
        }
    }
    private static let baseSongLimitChoices = [10, 25, 50, 100, 250, 500]
    /// The usual choices, plus the current count if Ask set one that isn't among them ("find 30 songs …").
    private var songLimitChoices: [Int] { Set(Self.baseSongLimitChoices + (songLimit > 0 ? [songLimit] : [])).sorted() }
    private static let capChoices = [1, 2, 3, 5, 10]
    private static let toolId = "similarSounds"

    @Environment(\.modelContext) private var modelContext
    @Environment(PopularityStore.self) private var popularityStore
    @Environment(AskSimilarRouter.self) private var askRouter
    @State private var seeds: [SimilarSeed] = []
    @State private var sort: SimilarSoundsSort = .matchScore
    @State private var songLimit = 50
    @State private var perArtist = 0
    @State private var perAlbum = 0
    @State private var includeNew = false
    /// How many of the rows shown are new music, and how many were left out because conditions are set.
    @State private var newShown = 0
    @State private var newHidden = 0
    @State private var shuffleSeed: UInt64 = 1
    @State private var showingSeedSearch = false
    @State private var scrobbles: [ScrobbleSnapshot]?
    @State private var snapshots = QuerySnapshots()
    @State private var tagVocabulary: [QueryTagSuggestion] = []
    @State private var pool: SimilarSoundsPool?
    /// The seeds the current pool was generated from — so a changed seed list can say the pool is stale.
    @State private var poolSeedIDs: [String] = []
    @State private var groups: [[QueryCondition]] = []
    @State private var columns: [QueryFieldRef] = SimilarSoundsTool.defaultColumns
    @State private var result: QueryResult?
    @State private var displayRows: [QueryDisplayRow] = []
    @State private var isGenerating = false
    @State private var isRefining = false
    @State private var notice: String?
    @State private var refineError: String?

    private var saved: Options { Options(seeds: seeds, sort: sort, songLimit: songLimit, perArtist: perArtist, perAlbum: perAlbum, includeNew: includeNew) }
    /// New music is switched on but the pool on screen was found without looking for it.
    private var needsRefreshForNew: Bool { includeNew && pool != nil && pool?.searchedNewMusic == false }
    private var arrangement: SimilarSoundsArrangement {
        SimilarSoundsArrangement(
            sort: sort, shuffleSeed: shuffleSeed,
            songLimit: songLimit > 0 ? songLimit : nil, perArtist: perArtist > 0 ? perArtist : nil, perAlbum: perAlbum > 0 ? perAlbum : nil
        )
    }
    private var poolIsStale: Bool { pool != nil && poolSeedIDs != seeds.map(\.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Similar Sounds") { seedBar }
                if let notice { Text(notice).font(AppTypography.supporting).foregroundStyle(.orange) }
                if let pool {
                    coverageCallout(pool)
                    refinement(pool)
                    results(pool)
                } else if isGenerating {
                    ProgressView("Asking Last.fm…").frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ContentUnavailableView(
                        "Pick a few things you love", systemImage: "waveform.badge.magnifyingglass",
                        description: Text("Add up to \(SimilarSoundsTool.seedLimit) artists, albums or tracks, then Find Similar. You'll see what Last.fm says sounds like them from your library, and with Include new music, tracks you haven't played too.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .navigationTitle("Similar Sounds")
        .overlay {
            if showingSeedSearch {
                GlobalSearchOverlay(isPresented: $showingSeedSearch, onSelect: addSeed)
            }
        }
        .task {
            let loaded = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Options())
            (seeds, sort, songLimit, perArtist, perAlbum, includeNew) = (
                incomingSeeds.isEmpty ? loaded.seeds : incomingSeeds,
                loaded.sort,
                loaded.songLimit,
                loaded.perArtist,
                loaded.perAlbum,
                loaded.includeNew
            )
            await loadLibrary()
            if incomingSeeds.isEmpty {
                await applyAskedSimilar()
            } else {
                await findSimilar()
            }
        }
        .onChange(of: askRouter.pending?.id) { Task { await applyAskedSimilar() } }
        .onChange(of: saved) { _, newValue in
            ToolFilterSettingsStore.save(newValue, toolId: Self.toolId, context: modelContext)
        }
        .onChange(of: arrangement) { _, _ in Task { await refine() } }
        .onChange(of: groups) { _, _ in Task { await refine() } }
        .onChange(of: columns) { _, _ in Task { await refine() } }
        .onChange(of: includeNew) { _, _ in Task { await refine() } }
    }

    // MARK: - Seeds

    private var seedBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if seeds.isEmpty {
                Text("No seeds yet.").font(AppTypography.supporting).foregroundStyle(.secondary)
            } else {
                AskFlowLayout(spacing: 8) {
                    ForEach(seeds) { seed in seedChip(seed) }
                }
            }
            HStack(spacing: 10) {
                Button { showingSeedSearch = true } label: { Label("Add seed", systemImage: "plus") }
                    .disabled(seeds.count >= SimilarSoundsTool.seedLimit)
                    .help(seeds.count >= SimilarSoundsTool.seedLimit
                          ? "A search takes up to \(SimilarSoundsTool.seedLimit) seeds."
                          : "Search your library for an artist, album or track to seed the search.")
                Button { Task { await findSimilar() } } label: { Label(pool == nil ? "Find Similar" : "Refresh", systemImage: "sparkle.magnifyingglass") }
                    .buttonStyle(.borderedProminent)
                    .disabled(seeds.isEmpty || isGenerating || scrobbles == nil || Connectivity.shared.isOffline)
                    .help(Connectivity.shared.isOffline ? "Offline mode is on. Go online to look up similar music." : "Asks Last.fm for what's similar to each seed. This is the only step that uses the network.")
                Toggle("Include new music", isOn: $includeNew)
                    .toggleStyle(.checkbox)
                    .help("Also offer tracks Last.fm calls similar that you haven't played, marked New. They are placed by match score; conditions describe your own listening, so they hide new tracks.")
                if isGenerating { ProgressView().controlSize(.small) }
                if needsRefreshForNew {
                    Text("Refresh to look for new music.").font(AppTypography.compactMetadata).foregroundStyle(.orange)
                }
                if poolIsStale {
                    Text("Seeds changed — Refresh to update the results.").font(AppTypography.compactMetadata).foregroundStyle(.orange)
                }
            }
            arrangementControls
        }
    }

    /// Simple controls over what comes back: order, how many songs, and at most how many per artist / album.
    private var arrangementControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { arrangementPickers }
            VStack(alignment: .leading, spacing: 8) { arrangementPickers }
        }
    }

    @ViewBuilder
    private var arrangementPickers: some View {
        Picker("Sort", selection: $sort) {
            ForEach(SimilarSoundsSort.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
        .help("What order the songs come back in.")
        if sort == .shuffled {
            Button { shuffleSeed = UInt64.random(in: 1...UInt64.max) } label: { Label("Reshuffle", systemImage: "shuffle") }
                .help("Pick a new random order.")
        }
        Picker("Songs", selection: $songLimit) {
            Text("All songs").tag(0)
            ForEach(songLimitChoices, id: \.self) { Text("\($0) songs").tag($0) }
        }
        .fixedSize()
        .help("How many songs to show, after the order and per-artist / per-album limits.")
        Picker("Per artist", selection: $perArtist) {
            Text("No artist limit").tag(0)
            ForEach(Self.capChoices, id: \.self) { Text("\($0) per artist").tag($0) }
        }
        .fixedSize()
        .help("At most this many songs from any one artist — the first ones in the chosen order.")
        Picker("Per album", selection: $perAlbum) {
            Text("No album limit").tag(0)
            ForEach(Self.capChoices, id: \.self) { Text("\($0) per album").tag($0) }
        }
        .fixedSize()
        .help("At most this many songs from any one album — the first ones in the chosen order.")
    }

    private func seedChip(_ seed: SimilarSeed) -> some View {
        HStack(spacing: 5) {
            Image(systemName: seed.kind == .artist ? "person.fill" : seed.kind == .album ? "square.stack.fill" : "music.note")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            Text(seed.label).font(AppTypography.metadata).lineLimit(1)
            Button { seeds.removeAll { $0.id == seed.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain).help("Remove this seed")
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help(seed.kind == .album ? "Last.fm has no album-level similarity, so an album seed looks up its artist." : seed.label)
    }

    private func addSeed(_ result: SearchResult) {
        guard let seed = SimilarSeed(result), seeds.count < SimilarSoundsTool.seedLimit, !seeds.contains(where: { $0.id == seed.id }) else { return }
        seeds.append(seed)
    }

    // MARK: - Coverage + refinement + results

    private func coverageCallout(_ pool: SimilarSoundsPool) -> some View {
        ToolHeadlineCard("Seed coverage") {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(pool.seedsWithData) of \(pool.seedResults.count) seed\(pool.seedResults.count == 1 ? "" : "s") had similarity data in your library")
                ForEach(pool.seedResults, id: \.label) { seed in
                    Text("\(seed.label): Last.fm found \(seed.similarFound.formatted()), \(seed.inLibrary.formatted()) track\(seed.inLibrary == 1 ? "" : "s") in your library"
                         + (pool.searchedNewMusic ? ", \(seed.newFound.formatted()) new to you" : ""))
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refinement(_ pool: SimilarSoundsPool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            QueryConditionsEditor(
                groups: $groups, registry: .similarSounds, target: .track, tagVocabulary: tagVocabulary,
                emptyText: "No conditions — showing every candidate. Add one to narrow within these \(pool.candidates.count.formatted()) tracks."
            )
            if let refineError { Text(refineError).font(AppTypography.compactMetadata).foregroundStyle(.red) }
        }
    }

    private func results(_ pool: SimilarSoundsPool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(resultsSummary(pool))
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
                if isRefining { ProgressView().controlSize(.small) }
                Spacer()
                if !displayRows.isEmpty {
                    AppleMusicPlaylistExportButton(defaultPlaylistName: "Similar Sounds", tracks: { playlistTracks })
                        .controlSize(.small)
                }
            }
            if let result, !displayRows.isEmpty {
                QueryResultsTable(
                    rows: displayRows, columns: result.columns, identityTitle: "Track",
                    onMoveColumn: { moveColumn($0, before: $1) }, onOpen: open
                )
                .frame(height: 460)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5), lineWidth: 1) }
                if !result.pending.isEmpty {
                    Text(result.pending.map { "\($0.count.formatted()) still resolving “\($0.field)”" }.joined(separator: " · ")
                         + " — those candidates can’t match a condition on it yet.")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            } else if !isRefining {
                ContentUnavailableView("Nothing matches", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text(pool.candidates.isEmpty
                                                         ? "Last.fm had nothing similar to these seeds in your library."
                                                         : "Loosen or remove a condition."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
    }

    private func resultsSummary(_ pool: SimilarSoundsPool) -> String {
        guard let result else { return "\(pool.candidates.count.formatted()) candidates" }
        let shown = result.rows.count, matched = result.matchedCount
        var text: String
        if shown < matched { text = "Showing \(shown.formatted()) of \(matched.formatted()) matching · \(pool.candidates.count.formatted()) candidates" }
        else { text = "\(matched.formatted()) of \(pool.candidates.count.formatted()) candidates" }
        if includeNew {
            if newShown > 0 { text += " · \(newShown.formatted()) new to you" }
            if newHidden > 0 { text += " · \(newHidden.formatted()) new hidden by your conditions" }
        }
        return text
    }

    private var playlistTracks: [AppleMusicPlaylistTrack] {
        displayRows.compactMap { row in
            guard row.entity.target == .track, !row.entity.artist.isEmpty else { return nil }
            return AppleMusicPlaylistTrack(artist: row.entity.artist, track: row.entity.name, album: result?.entityInfo[row.entityID]?.album ?? "")
        }
    }

    private func open(_ row: QueryDisplayRow) {
        // A track you haven't played has no page here; its Last.fm page is the place to hear what it is.
        if row.isNewMusic { NewMusic.openInLastfm(artist: row.entity.artist, track: row.entity.name); return }
        navigation.goToTrack(TrackIdentity(artist: row.entity.artist, name: row.entity.name, album: result?.entityInfo[row.entityID]?.album, imageURL: row.imageURL))
    }

    private func moveColumn(_ movingKey: String, before targetKey: String) {
        guard let result, movingKey != targetKey,
              let from = result.columns.firstIndex(where: { $0.cacheKey == movingKey }),
              let to = result.columns.firstIndex(where: { $0.cacheKey == targetKey }),
              columns.indices.contains(from), columns.indices.contains(to) else { return }
        var reordered = columns
        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: from < to ? to - 1 : to)
        columns = reordered
    }

    // MARK: - Work

    /// The library as Query sees it (artist-canonicalized) plus the snapshots the refinement fields read.
    private func loadLibrary() async {
        do {
            if scrobbles == nil {
                let container = modelContainer
                let fetched = try await ScrobbleHistoryCache.shared.snapshots(container: container)
                scrobbles = QueryIdentity.canonicalizingArtists(fetched)
            }
            let loaded = await QuerySnapshotReader.loadAll(container: modelContainer)
            snapshots = QuerySnapshots(
                popularity: popularityStore.snapshot, durations: loaded.durations, releaseDates: loaded.releaseDates,
                turnover: loaded.turnover, lovedKeys: loaded.lovedKeys, flaggedKeys: loaded.flaggedKeys, entityTags: loaded.entityTags,
                libraryPresence: loaded.libraryPresence, weather: loaded.weather, images: loaded.images
            )
            tagVocabulary = loaded.entityTags.vocabulary.map { QueryTagSuggestion(tag: $0.tag, items: $0.items) }
        } catch {
            notice = "Couldn't read your library: \(error)"
        }
    }

    /// A "find similar" from the Ask box: use its seed and count, and run the search straight away.
    private func applyAskedSimilar() async {
        guard let request = askRouter.pending, scrobbles != nil else { return }
        askRouter.pending = nil
        seeds = [request.seed]
        songLimit = request.limit
        pool = nil
        await findSimilar()
    }

    private func findSimilar() async {
        if ConnectivityGate.isOffline {
            notice = "Offline mode is on. Go online to look up similar music."
            return
        }
        guard let credentials = LastfmCredentialsStore.load() else {
            notice = "Connect Last.fm in Settings to look up similar music."
            return
        }
        guard let scrobbles, !seeds.isEmpty else { return }
        notice = nil
        isGenerating = true
        defer { isGenerating = false }
        await loadLibrary()
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        do {
            let generated = try await SimilarSoundsTool.generate(seeds: seeds, scrobbles: scrobbles, client: client, includeNewMusic: includeNew)
            pool = generated
            poolSeedIDs = seeds.map(\.id)
            await refine()
        } catch {
            notice = "Couldn't look up similar music: \(error)"
        }
    }

    /// Evaluates the current conditions over the pool — local only, never the network.
    private func refine() async {
        guard let pool, let scrobbles else { return }
        isRefining = true
        defer { isRefining = false }
        let (currentGroups, currentColumns, currentSnapshots, currentArrangement, currentIncludeNew) = (groups, columns, snapshots, arrangement, includeNew)
        let evaluated = await Task.detached(priority: .userInitiated) {
            Result { try SimilarSoundsTool.evaluate(pool: pool, groups: currentGroups, columns: currentColumns, scrobbles: scrobbles, snapshots: currentSnapshots, arrangement: currentArrangement) }
        }.value
        switch evaluated {
        case .success(let value):
            refineError = nil
            result = value
            let libraryRows = QueryDisplayRow.make(from: value, imageLookup: currentSnapshots.images.lookup)
            if currentIncludeNew {
                let blended = SimilarSoundsBlend.blend(
                    library: libraryRows, result: value, newMusic: pool.newMusic, scores: pool.snapshot,
                    hasConditions: currentGroups.contains { !$0.isEmpty }, arrangement: currentArrangement,
                    imageLookup: currentSnapshots.images.lookup
                )
                displayRows = blended.rows
                (newShown, newHidden) = (blended.shown, blended.hiddenByConditions)
            } else {
                displayRows = libraryRows
                (newShown, newHidden) = (0, 0)
            }
        case .failure(let error):
            // Keep the last good result on screen; say what's wrong with the conditions.
            refineError = "\(error)"
        }
    }
}
