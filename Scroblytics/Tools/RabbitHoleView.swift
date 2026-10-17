import SwiftData
import SwiftUI

struct RabbitHoleView: View {
    struct Options: Codable, Equatable {
        var tree = RabbitHoleTree.empty
        var groups: [[QueryCondition]] = []
        var perArtist = 1
        var perAlbum = 0
        var knobs = RabbitHoleKnobs()
        var memory = RabbitHoleMemory()
        var walkLength = RabbitHoleWalkLength.minutes60
        /// The steps the last walk added, so it can be taken off again.
        var lastWalk: [UUID] = []
        /// Whether the Filters and Style sections above the path are open.
        var showFilters = false
        var showStyle = false

        init() {}

        /// Every field is optional on disk so a path saved by an earlier version still opens.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tree = try c.decodeIfPresent(RabbitHoleTree.self, forKey: .tree) ?? .empty
            groups = try c.decodeIfPresent([[QueryCondition]].self, forKey: .groups) ?? []
            perArtist = try c.decodeIfPresent(Int.self, forKey: .perArtist) ?? 1
            perAlbum = try c.decodeIfPresent(Int.self, forKey: .perAlbum) ?? 0
            knobs = try c.decodeIfPresent(RabbitHoleKnobs.self, forKey: .knobs) ?? RabbitHoleKnobs()
            memory = try c.decodeIfPresent(RabbitHoleMemory.self, forKey: .memory) ?? RabbitHoleMemory()
            walkLength = try c.decodeIfPresent(RabbitHoleWalkLength.self, forKey: .walkLength) ?? .minutes60
            lastWalk = try c.decodeIfPresent([UUID].self, forKey: .lastWalk) ?? []
            showFilters = try c.decodeIfPresent(Bool.self, forKey: .showFilters) ?? false
            showStyle = try c.decodeIfPresent(Bool.self, forKey: .showStyle) ?? false
        }
    }

    private static let toolID = "rabbitHole"
    private static let capChoices = [0, 1, 2, 3, 5]

    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @Environment(PopularityStore.self) private var popularityStore
    @State private var options = Options()
    @State private var scrobbles: [ScrobbleSnapshot]?
    @State private var library: RabbitHoleLibrary?
    @State private var poolSize: Int?
    @Environment(NowPlayingStore.self) private var nowPlayingStore: NowPlayingStore?
    @State private var isWalking = false
    @State private var showingWalkOptions = false
    @State private var isStarting = false
    @State private var walkProgress: RabbitHoleWalk.Progress?
    @State private var walkNote: String?
    @State private var walkTask: Task<Void, Never>?
    @State private var snapshots = QuerySnapshots()
    @State private var tagVocabulary: [QueryTagSuggestion] = []
    /// When `loadLibrary` last finished. The tool's `.task` runs again whenever its tab reappears; reading the whole library
    /// again for that took seconds and is only worth doing when what it read could have changed.
    @State private var libraryLoadedAt: Date?
    @State private var isSearching = false
    @State private var isGenerating = false
    @State private var totalBeforeConditions: Int?
    @State private var errorMessage: String?
    @State private var showingStartOverConfirmation = false
    @State private var treePanelHeight: CGFloat = 360
    /// After a choice (or a step back, or new suggestions) the page stays at its bottom, where the reasons are, instead of jumping to the top.
    @State private var scrollToBottomRequest = 0
    @State private var followAfterGeneration = false
    private static let bottomID = "rabbitHoleBottom"

    private var currentNode: RabbitHoleNode? {
        options.tree.currentID.flatMap { options.tree.nodes[$0] }
    }

    private var path: [RabbitHoleNode] {
        options.tree.path()
    }

    var body: some View {
        ScrollViewReader { proxy in
            pageContent
                .onChange(of: scrollToBottomRequest) {
                    // Give the new content a moment to lay out, so "bottom" is the new bottom.
                    Task {
                        try? await Task.sleep(for: .milliseconds(80))
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                        // Nothing is being generated, so there is no later scroll to wait for.
                        if !isGenerating { followAfterGeneration = false }
                    }
                }
        }
    }

    private func requestScrollToBottom() {
        followAfterGeneration = true
        scrollToBottomRequest += 1
    }

    private var pageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Rabbit Hole") {
                    headerControls
                }
                ToolHeadlineCard("FOLLOW ONE TRACK AT A TIME") {
                    Text("Pick a starting track, then choose from three recommendations in your library at each step. Backtrack at any time; only your current path is exported.")
                }

                if options.tree.rootID == nil {
                    emptyState
                } else {
                    filters
                    treeView
                    currentStep
                    candidatesView
                    whyThese
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
            }
            .padding(16)
        }
        .navigationTitle("Rabbit Hole")
        .overlay {
            if isSearching {
                GlobalSearchOverlay(
                    isPresented: $isSearching,
                    onSelect: selectSearchResult,
                    allowedKinds: [.track]
                )
            }
        }
        .task {
            options = ToolFilterSettingsStore.load(
                Options.self,
                toolId: Self.toolID,
                context: modelContext,
                default: Options()
            )
            await loadLibrary()
            if currentNode?.candidates == nil {
                await generateCandidates()
            }
        }
        .onChange(of: options) { _, value in
            ToolFilterSettingsStore.save(value, toolId: Self.toolID, context: modelContext)
        }
        .onChange(of: options.groups) {
            invalidateAndRegenerate()
        }
        .onChange(of: options.perArtist) {
            invalidateAndRegenerate()
        }
        .onChange(of: options.perAlbum) {
            invalidateAndRegenerate()
        }
        .onChange(of: options.knobs) {
            invalidateAndRegenerate()
        }
        .confirmationDialog("Start over?", isPresented: $showingStartOverConfirmation, titleVisibility: .visible) {
            Button("Start Over", role: .destructive) {
                options.tree = .empty
                options.lastWalk = []
                totalBeforeConditions = nil
                errorMessage = nil
                walkNote = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the current Rabbit Hole path and its explored branches.")
        }
    }

    private var headerControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { headerButtons }
            VStack(alignment: .leading, spacing: 8) { headerButtons }
        }
    }

    @ViewBuilder
    private var headerButtons: some View {
        if options.tree.rootID == nil {
            Button("Pick Starting Track", systemImage: "plus") {
                isSearching = true
            }
            .buttonStyle(.borderedProminent)
            startMenu
        } else {
            if path.count > 1 {
                AppleMusicPlaylistExportButton(defaultPlaylistName: "Rabbit Hole") {
                    path.map {
                        AppleMusicPlaylistTrack(
                            artist: $0.track.artist,
                            track: $0.track.track,
                            album: $0.track.album ?? ""
                        )
                    }
                }
            }
            Button("Add Track", systemImage: "magnifyingglass") {
                isSearching = true
            }
            Button("Start Over", systemImage: "arrow.counterclockwise") {
                showingStartOverConfirmation = true
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "Start down the rabbit hole",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Choose a track from your library and follow where Last.fm’s recommendations lead.")
            )
            HStack(spacing: 10) {
                Button("Pick a Starting Track", systemImage: "plus") {
                    isSearching = true
                }
                .buttonStyle(.borderedProminent)
                startMenu
            }
            if let errorMessage {
                Text(errorMessage).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            disclosureRow("Filters", summary: filtersSummary, isOpen: $options.showFilters)
            if options.showFilters {
                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { capPickers }
                        VStack(alignment: .leading, spacing: 8) { capPickers }
                    }
                    QueryConditionsEditor(
                        groups: $options.groups,
                        registry: .similarSounds,
                        target: .track,
                        tagVocabulary: tagVocabulary,
                        emptyText: "No conditions — every recommendation in your library can be offered."
                    )
                }
                .padding(.bottom, 4)
            }
            Divider()
            disclosureRow("Style", summary: styleSummary, isOpen: $options.showStyle)
            if options.showStyle {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { knobControls }
                    VStack(alignment: .leading, spacing: 8) { knobControls }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func disclosureRow(_ title: String, summary: String, isOpen: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(AppTypography.compactMetadata)
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                    .frame(width: 10)
                Text(title).font(AppTypography.sectionTitle)
                Text(summary).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(summary)")
        .accessibilityHint(isOpen.wrappedValue ? "Hides the settings" : "Shows the settings")
    }

    private var filtersSummary: String {
        var parts: [String] = []
        if options.perArtist > 0 { parts.append("\(options.perArtist) per artist") }
        if options.perAlbum > 0 { parts.append("\(options.perAlbum) per album") }
        let conditions = options.groups.reduce(0) { $0 + $1.count }
        if conditions > 0 { parts.append("\(conditions) \(conditions == 1 ? "condition" : "conditions")") }
        return parts.isEmpty ? "No limits" : parts.joined(separator: " · ")
    }

    private var styleSummary: String {
        let variety = ["Stay close", "Balanced", "Wander"][min(2, max(0, options.knobs.wander))]
        var parts = [variety]
        switch options.knobs.familiarity {
        case ...(-2): parts.append("mostly forgotten")
        case -1: parts.append("leaning forgotten")
        case 1: parts.append("leaning familiar")
        case 2...: parts.append("mostly familiar")
        default: break
        }
        if !options.knobs.avoidRepeats { parts.append("repeats allowed") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var capPickers: some View {
        Picker("Per artist", selection: $options.perArtist) {
            ForEach(Self.capChoices, id: \.self) {
                Text($0 == 0 ? "No artist limit" : "\($0) per artist").tag($0)
            }
        }
        .fixedSize()
        Picker("Per album", selection: $options.perAlbum) {
            ForEach(Self.capChoices, id: \.self) {
                Text($0 == 0 ? "No album limit" : "\($0) per album").tag($0)
            }
        }
        .fixedSize()
        .help("Filters and limits apply to the next three recommendations, never to tracks already on your path.")
    }

    @ViewBuilder
    private var knobControls: some View {
        HStack(spacing: 6) {
            Text("Lean toward")
            Text("Forgotten").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { Double(options.knobs.familiarity) }, set: { options.knobs.familiarity = Int($0.rounded()) }),
                in: -2...2, step: 1
            )
            .frame(width: 120)
            Text("Familiar").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        .help("Forgotten favours tracks you haven't played for a long time; familiar favours loved and often-played ones. The middle has no lean.")
        Picker("Variety", selection: $options.knobs.wander) {
            Text("Stay close").tag(0)
            Text("Balanced").tag(1)
            Text("Wander").tag(2)
        }
        .fixedSize()
        .help("Stay close favours the best matches; wander gives weaker matches a real chance. Steps taken for you follow it too.")
        Toggle("Avoid recent repeats", isOn: $options.knobs.avoidRepeats)
            .help("Makes tracks you were shown or chose in the last week less likely to come up again.")
    }

    private var currentStep: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                currentStepDescription
                Spacer()
                currentStepActions
            }
            VStack(alignment: .leading, spacing: 10) {
                currentStepDescription
                HStack(spacing: 8) { currentStepActions }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var currentStepDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Current step · \(path.count.formatted()) \(path.count == 1 ? "track" : "tracks") on this path")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
            if let currentNode {
                Text("\(currentNode.track.track) — \(currentNode.track.artist)")
                    .font(AppTypography.contentTitle)
            }
            if let walkProgress, isWalking {
                Text("Taking steps · step \(walkProgress.tracksAdded) · \(Self.minutesText(walkProgress.seconds)) so far\(walkProgress.approximate ? " (about)" : "")")
                    .font(AppTypography.compactMetadata)
                    .foregroundStyle(.secondary)
            } else if let walkNote {
                HStack(spacing: 6) {
                    Text(walkNote).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    if !options.lastWalk.isEmpty {
                        Button("Remove Last Walk") { removeLastWalk() }
                            .buttonStyle(.link)
                            .font(AppTypography.compactMetadata)
                            .help("Takes the steps the last walk added off the path again.")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var currentStepActions: some View {
        if let parentID = currentNode?.parentID {
            Button("Back One Step", systemImage: "arrow.uturn.backward") {
                options.tree.currentID = parentID
                totalBeforeConditions = nil
                requestScrollToBottom()
            }
            .disabled(isWalking)
        }
        Button("New Suggestions", systemImage: "arrow.clockwise") {
            invalidateAndRegenerate()
            requestScrollToBottom()
        }
        .disabled(isGenerating || isWalking)
        if isWalking {
            Button("Stop", systemImage: "stop.circle") { walkTask?.cancel() }
        } else {
            Button("Take Steps for Me…", systemImage: "figure.walk") { showingWalkOptions = true }
                .disabled(isGenerating || currentNode == nil)
                .popover(isPresented: $showingWalkOptions, arrowEdge: .bottom) { walkOptions }
                .help("Adds tracks to the path for you, one step at a time.")
        }
    }

    private var walkOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Take steps for me").font(AppTypography.sectionTitle)
            Picker("Length", selection: $options.walkLength) {
                ForEach(RabbitHoleWalkLength.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Text("Adds tracks to the path one suggestion at a time until the length is reached, following your Filters and Style. Every step stays in the tree, so you can step back, and the whole path can be exported as a playlist.")
                .font(AppTypography.compactMetadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showingWalkOptions = false }
                    .keyboardShortcut(.cancelAction)
                Button("Take Steps") {
                    showingWalkOptions = false
                    startWalk()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private var treeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Exploration Tree").font(AppTypography.sectionTitle)
                Spacer()
                Text("Solid cards are explored · dashed cards are suggestions")
                    .font(AppTypography.compactMetadata)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let layout = RabbitHoleTreeLayout.make(
                    tree: options.tree,
                    compact: proxy.size.width < 760
                )
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for edge in layout.edges {
                            var path = Path()
                            path.move(to: edge.start)
                            let midpointY = (edge.start.y + edge.end.y) / 2
                            path.addLine(to: CGPoint(x: edge.start.x, y: midpointY))
                            path.addLine(to: CGPoint(x: edge.end.x, y: midpointY))
                            path.addLine(to: edge.end)
                            context.stroke(
                                path,
                                with: .color(edge.isSuggestion ? .accentColor.opacity(0.45) : .accentColor),
                                style: StrokeStyle(
                                    lineWidth: edge.isSuggestion ? 1.5 : 2,
                                    dash: edge.isSuggestion ? [5, 5] : []
                                )
                            )
                        }
                    }

                    ForEach(layout.nodes) { placed in
                        Button {
                            options.tree.currentID = placed.node.id
                            totalBeforeConditions = nil
                            requestScrollToBottom()
                        } label: {
                            RabbitHoleTreeCard(
                                track: placed.node.track,
                                isCurrent: placed.node.id == options.tree.currentID,
                                isSuggestion: false,
                                actionHint: placed.isOnPath ? "Backtrack to this step" : "Explore this branch"
                            )
                        }
                        .buttonStyle(.plain)
                        .position(
                            x: placed.origin.x + RabbitHoleTreeLayout.cardSize.width / 2,
                            y: placed.origin.y + RabbitHoleTreeLayout.cardSize.height / 2
                        )
                        .entityContextMenu(
                            target: ImageTarget(
                                kind: .track,
                                artist: placed.node.track.artist,
                                album: placed.node.track.album,
                                track: placed.node.track.track
                            ),
                            currentImageURL: placed.node.track.imageURL,
                            onOpen: { open(placed.node.track) }
                        )
                    }

                    ForEach(layout.candidates) { placed in
                        Button {
                            choose(placed.track, from: placed.parentID)
                            requestScrollToBottom()
                        } label: {
                            RabbitHoleTreeCard(
                                track: placed.track,
                                isCurrent: false,
                                isSuggestion: true,
                                actionHint: "Follow this suggestion"
                            )
                        }
                        .buttonStyle(.plain)
                        .position(
                            x: placed.origin.x + RabbitHoleTreeLayout.cardSize.width / 2,
                            y: placed.origin.y + RabbitHoleTreeLayout.cardSize.height / 2
                        )
                        .entityContextMenu(
                            target: ImageTarget(
                                kind: .track,
                                artist: placed.track.artist,
                                album: placed.track.album,
                                track: placed.track.track
                            ),
                            currentImageURL: placed.track.imageURL,
                            onOpen: { open(placed.track) }
                        )
                    }
                    }
                    .frame(width: layout.size.width, height: layout.size.height)
                    .frame(
                        minWidth: proxy.size.width,
                        minHeight: treePanelHeight,
                        alignment: .top
                    )
                }
                .scrollIndicators(.hidden)
                .task(id: layout.size.height) {
                    treePanelHeight = max(360, layout.size.height)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: treePanelHeight,
                idealHeight: treePanelHeight,
                maxHeight: treePanelHeight
            )
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.5), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var candidatesView: some View {
        if isGenerating {
            ProgressView("Finding your next tracks…")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if let errorMessage {
            ContentUnavailableView(
                "Couldn’t load suggestions",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else if let candidates = currentNode?.candidates, candidates.isEmpty {
            ContentUnavailableView(
                totalBeforeConditions.map { $0 > 0 } == true ? "Your conditions excluded every suggestion" : "No more suggestions from here",
                systemImage: "arrow.triangle.branch",
                description: Text(totalBeforeConditions.map { $0 > 0 } == true
                    ? "Remove or loosen a condition, then try again."
                    : "Choose Add Track to continue manually, or backtrack to another step.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    // MARK: - Starting without searching

    private var startMenu: some View {
        Menu {
            ForEach(RabbitHoleStart.allCases) { kind in
                Button(kind.title, systemImage: kind.systemImage) { start(from: kind) }
            }
        } label: {
            Label(isStarting ? "Finding a track…" : "Start from…", systemImage: "sparkles")
        }
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(isStarting || library == nil)
        .help("Start from what's playing, a favourite you've left alone, one of your top tracks, or a surprise.")
    }

    private func start(from kind: RabbitHoleStart) {
        guard let library, !isStarting else { return }
        errorMessage = nil
        isStarting = true
        Task {
            defer { isStarting = false }
            if ConnectivityGate.isOffline { errorMessage = "Offline mode is on. Go online to start from a suggestion."; return }
            guard let credentials = LastfmCredentialsStore.load() else { errorMessage = "Connect Last.fm in Settings to start a Rabbit Hole."; return }
            var rng = SystemRandomNumberGenerator()
            let playing = nowPlayingStore?.track.map { (artist: $0.artist, track: $0.track) }
            let shortlist = RabbitHoleSeeds.shortlist(kind, library: library, lovedKeys: snapshots.lovedKeys, nowPlaying: playing, using: &rng)
            guard !shortlist.isEmpty else {
                errorMessage = kind == .nowPlaying
                    ? "Nothing is playing right now, or it isn't a track you've played before."
                    : "No suitable track was found this way. Try another, or search for one."
                return
            }
            let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
            let provider = LastfmSimilarityProvider(client: client, store: SimilarityCacheStore(modelContainer: modelContainer))
            let tags = snapshots.entityTags, bpm = snapshots.bpm, loved = snapshots.lovedKeys
            let index = await RabbitHoleSeeds.firstViable(shortlist, minimum: kind == .nowPlaying ? 1 : RabbitHoleSeeds.minimumPool) { candidate in
                let track = library.tracks[candidate]
                let pool = try? await RabbitHoleCandidates.build(
                    seeds: [RabbitHoleCandidates.Seed(artist: track.artist, track: track.name, weight: 1)], excluding: [], library: library,
                    tags: tags, bpm: bpm, lovedKeys: loved, provider: provider
                )
                return pool?.count ?? 0
            }
            guard let index else {
                errorMessage = "The tracks tried had too few similar tracks in your library. Try again, or search for one."
                return
            }
            let track = library.tracks[index]
            beginPath(with: RabbitHoleTrack(
                artist: track.artist, track: track.name, album: track.album, imageURL: track.imageURL, playCount: track.plays,
                lastPlayed: track.lastPlayed, matchScore: 0, source: kind.title
            ))
        }
    }

    // MARK: - Take steps for me

    private static func minutesText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private func startWalk() {
        guard !isWalking, !isGenerating, walkTask == nil else { return }
        errorMessage = nil
        walkNote = nil
        walkProgress = RabbitHoleWalk.Progress()
        isWalking = true
        walkTask = Task { await performWalk() }
    }

    private func removeLastWalk() {
        options.tree = RabbitHoleWalk.remove(walk: options.lastWalk, from: options.tree)
        options.lastWalk = []
        walkNote = "The last walk was taken off the path."
        totalBeforeConditions = nil
        invalidateAndRegenerate()
        requestScrollToBottom()
    }

    private func performWalk() async {
        defer {
            isWalking = false
            walkTask = nil
        }
        if ConnectivityGate.isOffline { errorMessage = "Offline mode is on. Go online to take steps."; return }
        guard let credentials = LastfmCredentialsStore.load() else { errorMessage = "Connect Last.fm in Settings to take steps."; return }
        await loadLibrary()
        guard let library, let scrobbles else { return }
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        let provider = LastfmSimilarityProvider(client: client, store: SimilarityCacheStore(modelContainer: modelContainer))
        let snapshots = snapshots
        let knobs = options.knobs
        let groups = options.groups, perArtist = options.perArtist, perAlbum = options.perAlbum
        var rng = SystemRandomNumberGenerator()
        do {
            let result = try await RabbitHoleWalk.run(
                length: options.walkLength, variety: options.knobs.wander, tree: options.tree, memory: options.memory,
                candidatesFor: { tree, node, memory in
                    try await RabbitHoleEngine.generate(
                        from: node.track, path: tree.path(to: node.id), groups: groups, perArtist: perArtist, perAlbum: perAlbum,
                        knobs: knobs, memory: memory, library: library, scrobbles: scrobbles, snapshots: snapshots, provider: provider
                    ).candidates
                },
                seconds: { track in
                    switch snapshots.durations.resolution(forKey: DurationEngine.cacheKey(artist: track.artist, track: track.track)) {
                    case .seconds(let value): Double(value)
                    default: nil
                    }
                },
                onProgress: { tree, progress in
                    options.tree = tree
                    walkProgress = progress
                    // Keep the newest steps in view while the walk goes on.
                    scrollToBottomRequest += 1
                },
                using: &rng
            )
            options.tree = result.tree
            options.memory = result.memory
            options.lastWalk = result.addedNodeIDs
            let about = result.progress.approximate ? "about " : ""
            let summary = "\(result.progress.tracksAdded) \(result.progress.tracksAdded == 1 ? "track" : "tracks") added, \(about)\(Self.minutesText(result.progress.seconds))."
            switch result.ending {
            case .reachedLength: walkNote = "Walk finished: \(summary)"
            case .stoppedByUser: walkNote = "Walk stopped: \(summary)"
            case .stepLimit: walkNote = "Walk stopped at the limit of \(RabbitHoleWalk.maxSteps) steps: \(summary)"
            case .deadEnd: walkNote = "Walk stopped: it ran out of new suggestions. \(summary)"
            case .failed(let message): walkNote = "Walk stopped: \(message) \(summary)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        // The last step has no suggestions yet; offer them with the page's own settings, and show them.
        if currentNode?.candidates == nil { await generateCandidates() }
        requestScrollToBottom()
    }

    /// Why the three suggestions were offered, in plain words, and how many options remain behind them.
    @ViewBuilder
    private var whyThese: some View {
        if !isGenerating, let candidates = currentNode?.candidates, !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Why these three").font(AppTypography.sectionTitle)
                    Spacer()
                    if let poolSize {
                        Text(poolSize > candidates.count ? "\((poolSize - candidates.count).formatted()) more options behind these" : "No more options behind these")
                            .font(AppTypography.compactMetadata)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(candidate.track) — \(candidate.artist)").font(AppTypography.contentTitle).lineLimit(1)
                        HStack(spacing: 6) {
                            ForEach(candidate.reasons ?? [], id: \.self) { reason in
                                Text(reason.text)
                                    .font(AppTypography.compactMetadata)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func loadLibrary() async {
        if scrobbles != nil, let libraryLoadedAt, Date().timeIntervalSince(libraryLoadedAt) < 300 { return }
        do {
            if scrobbles == nil {
                let fetched = try await offMain {
                    try await ScrobbleHistoryCache.shared.snapshots(container: modelContainer)
                }
                let canonical = QueryIdentity.canonicalizingArtists(fetched)
                scrobbles = canonical
                library = await offMain { RabbitHoleLibrary.build(scrobbles: canonical) }
            }
            let loaded = await QuerySnapshotReader.loadAll(container: modelContainer)
            snapshots = QuerySnapshots(
                popularity: popularityStore.snapshot,
                durations: loaded.durations,
                releaseDates: loaded.releaseDates,
                turnover: loaded.turnover,
                lovedKeys: loaded.lovedKeys,
                flaggedKeys: loaded.flaggedKeys,
                entityTags: loaded.entityTags,
                images: loaded.images
            )
            tagVocabulary = loaded.entityTags.vocabulary.map {
                QueryTagSuggestion(tag: $0.tag, items: $0.items)
            }
            libraryLoadedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectSearchResult(_ result: SearchResult) {
        guard let identity = result.track else {
            errorMessage = "Rabbit Hole starts and continues with tracks, not artists or albums."
            return
        }
        let selected = RabbitHoleTrack(
            artist: identity.artist,
            track: identity.name,
            album: identity.album,
            imageURL: result.imageURL,
            playCount: result.playCount,
            lastPlayed: nil,
            matchScore: 0,
            source: options.tree.rootID == nil ? "Starting track" : "Added manually"
        )
        if options.tree.rootID == nil {
            beginPath(with: selected)
        } else {
            choose(selected, from: options.tree.currentID)
        }
    }

    private func beginPath(with track: RabbitHoleTrack) {
        let id = UUID()
        options.tree = RabbitHoleTree(
            rootID: id,
            nodes: [id: RabbitHoleNode(id: id, track: track, parentID: nil, candidates: nil, childIDs: [])],
            currentID: id
        )
        options.lastWalk = []
        walkNote = nil
        Task { await generateCandidates() }
    }

    private func choose(_ track: RabbitHoleTrack, from requestedParentID: UUID? = nil) {
        guard let parentID = requestedParentID ?? options.tree.currentID else { return }
        options.tree.currentID = parentID
        if let existing = options.tree.nodes[parentID]?.childIDs
            .compactMap({ options.tree.nodes[$0] })
            .first(where: { $0.track.id == track.id }) {
            options.tree.currentID = existing.id
            if existing.candidates == nil { Task { await generateCandidates() } }
            return
        }

        options.memory.noteChosen(track.id)
        let id = UUID()
        options.tree.nodes[id] = RabbitHoleNode(
            id: id,
            track: track,
            parentID: parentID,
            candidates: nil,
            childIDs: []
        )
        options.tree.nodes[parentID]?.childIDs.append(id)
        options.tree.currentID = id
        totalBeforeConditions = nil
        Task { await generateCandidates() }
    }

    private func invalidateAndRegenerate() {
        guard let id = options.tree.currentID else { return }
        options.tree.nodes[id]?.candidates = nil
        Task { await generateCandidates() }
    }

    private func generateCandidates() async {
        guard !isGenerating,
              let id = options.tree.currentID,
              let node = options.tree.nodes[id],
              node.candidates == nil,
              let scrobbles else { return }
        if ConnectivityGate.isOffline {
            errorMessage = "Offline mode is on. Go online to generate recommendations."
            return
        }
        guard let credentials = LastfmCredentialsStore.load() else {
            errorMessage = "Connect Last.fm in Settings to generate recommendations."
            return
        }

        isGenerating = true
        errorMessage = nil
        defer {
            isGenerating = false
            if followAfterGeneration {
                followAfterGeneration = false
                scrollToBottomRequest += 1
            }
        }
        await loadLibrary()
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        guard let library else { return }
        let provider = LastfmSimilarityProvider(client: client, store: SimilarityCacheStore(modelContainer: modelContainer))

        do {
            let generated = try await RabbitHoleEngine.generate(
                from: node.track,
                path: options.tree.path(to: id),
                groups: options.groups,
                perArtist: options.perArtist,
                perAlbum: options.perAlbum,
                knobs: options.knobs,
                memory: options.memory,
                library: library,
                scrobbles: scrobbles,
                snapshots: snapshots,
                provider: provider
            )
            guard options.tree.currentID == id else { return }
            options.tree.nodes[id]?.candidates = generated.candidates
            totalBeforeConditions = generated.totalBeforeConditions
            poolSize = generated.poolSize
            options.memory.noteShown(generated.candidates.map(\.id))
        } catch {
            guard options.tree.currentID == id else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ track: RabbitHoleTrack) {
        navigation.goToTrack(TrackIdentity(
            artist: track.artist,
            name: track.track,
            album: track.album,
            imageURL: track.imageURL
        ))
    }
}

private struct RabbitHoleTreeCard: View {
    let track: RabbitHoleTrack
    let isCurrent: Bool
    let isSuggestion: Bool
    let actionHint: String

    var body: some View {
        HStack(spacing: 10) {
            EntityThumbnail(url: track.imageURL, entity: .track)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(track.track).font(AppTypography.contentTitle).lineLimit(1)
                    TrackLovedIndicator(
                        artist: track.artist,
                        track: track.track,
                        initialValue: false,
                        font: AppTypography.metadata
                    )
                    PopularityMarker(
                        entity: .track,
                        name: track.track,
                        artist: track.artist,
                        font: AppTypography.compactMetadata
                    )
                }
                Text([track.artist, track.album].compactMap { $0 }.joined(separator: " · "))
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if track.matchScore > 0 {
                    Text(track.reasons?.first.map { "\(track.matchScore)% · \($0.text)" } ?? "\(track.matchScore)% match · \(track.playCount.formatted()) plays")
                        .font(AppTypography.compactMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(([ "\(track.matchScore)% match · \(track.playCount.formatted()) plays" ] + (track.reasons ?? []).map(\.text)).joined(separator: "\n"))
                } else {
                    Text(track.source)
                        .font(AppTypography.compactMetadata)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(12)
        .frame(
            width: RabbitHoleTreeLayout.cardSize.width,
            height: RabbitHoleTreeLayout.cardSize.height,
            alignment: .leading
        )
        .background(
            isCurrent ? Color.accentColor.opacity(0.18) : Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isCurrent ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5),
                    style: StrokeStyle(lineWidth: isCurrent ? 2 : 1, dash: isSuggestion ? [6, 5] : [])
                )
        }
        .accessibilityLabel("\(track.track), by \(track.artist)")
        .accessibilityHint(actionHint)
    }
}
