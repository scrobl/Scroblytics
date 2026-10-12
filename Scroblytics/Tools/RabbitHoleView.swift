import SwiftData
import SwiftUI

struct RabbitHoleView: View {
    struct Options: Codable, Equatable {
        var tree = RabbitHoleTree.empty
        var groups: [[QueryCondition]] = []
        var perArtist = 1
        var perAlbum = 0
    }

    private static let toolID = "rabbitHole"
    private static let capChoices = [0, 1, 2, 3, 5]

    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @Environment(PopularityStore.self) private var popularityStore
    @State private var options = Options()
    @State private var scrobbles: [ScrobbleSnapshot]?
    @State private var snapshots = QuerySnapshots()
    @State private var tagVocabulary: [QueryTagSuggestion] = []
    @State private var isSearching = false
    @State private var isGenerating = false
    @State private var totalBeforeConditions: Int?
    @State private var errorMessage: String?
    @State private var showingStartOverConfirmation = false
    @State private var treePanelHeight: CGFloat = 360

    private var currentNode: RabbitHoleNode? {
        options.tree.currentID.flatMap { options.tree.nodes[$0] }
    }

    private var path: [RabbitHoleNode] {
        options.tree.path()
    }

    var body: some View {
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
                    currentStep
                    treeView
                    candidatesView
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
        .confirmationDialog("Start over?", isPresented: $showingStartOverConfirmation, titleVisibility: .visible) {
            Button("Start Over", role: .destructive) {
                options.tree = .empty
                totalBeforeConditions = nil
                errorMessage = nil
                isSearching = true
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
            Button("Pick a Starting Track", systemImage: "plus") {
                isSearching = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var filters: some View {
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
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        Text("Conditions affect the next three recommendations, never tracks already on your path.")
            .font(AppTypography.compactMetadata)
            .foregroundStyle(.secondary)
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
        }
    }

    @ViewBuilder
    private var currentStepActions: some View {
        if let parentID = currentNode?.parentID {
            Button("Back One Step", systemImage: "arrow.uturn.backward") {
                options.tree.currentID = parentID
                totalBeforeConditions = nil
            }
        }
        Button("New Suggestions", systemImage: "arrow.clockwise") {
            invalidateAndRegenerate()
        }
        .disabled(isGenerating)
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

    private func loadLibrary() async {
        do {
            if scrobbles == nil {
                let fetched = try await offMain {
                    try await ScrobbleHistoryCache.shared.snapshots(container: modelContainer)
                }
                scrobbles = QueryIdentity.canonicalizingArtists(fetched)
            }
            let loaded = await QuerySnapshotReader(modelContainer: modelContainer).loadAll()
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
            let id = UUID()
            options.tree = RabbitHoleTree(
                rootID: id,
                nodes: [id: RabbitHoleNode(
                    id: id,
                    track: selected,
                    parentID: nil,
                    candidates: nil,
                    childIDs: []
                )],
                currentID: id
            )
            Task { await generateCandidates() }
        } else {
            choose(selected, from: options.tree.currentID)
        }
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
        defer { isGenerating = false }
        await loadLibrary()
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)

        do {
            let generated = try await RabbitHoleEngine.generate(
                from: node.track,
                path: options.tree.path(to: id),
                groups: options.groups,
                perArtist: options.perArtist,
                perAlbum: options.perAlbum,
                scrobbles: scrobbles,
                snapshots: snapshots,
                client: client
            )
            guard options.tree.currentID == id else { return }
            options.tree.nodes[id]?.candidates = generated.candidates
            totalBeforeConditions = generated.totalBeforeConditions
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
                    Text("\(track.matchScore)% match · \(track.playCount.formatted()) plays")
                        .font(AppTypography.compactMetadata.monospacedDigit())
                        .foregroundStyle(.secondary)
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
