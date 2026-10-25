import SwiftUI
import SwiftData

/// The Tools landing page: a grid of small, purpose-built utilities, each its own real page with its own
/// chrome — never a form embedded in Query. Every tool's "Advanced" escape hatch routes into Query with an
/// equivalent condition set pre-loaded (`QueryHandoff`), rather than opening a second, embedded
/// condition-builder instance. `ToolDescriptor.all` is the whole landing grid; adding the next Category A
/// tool (Fading Favorites, Climbing, …) is one more descriptor plus one more `destination` case, not new
/// landing-page chrome.
struct ToolsView: View {
    let modelContainer: ModelContainer
    let settings: ChartDateSettings
    @Binding var askRequest: AskQueryRequest?
    @Binding var overviewToolRequest: ToolDescriptor.Kind?
    /// A tool another screen (Settings, a Trends card) asks to open; unlike an Overview route it keeps the Back button to the Tools page.
    @Binding var openToolRequest: ToolDescriptor.Kind?
    @Binding var overviewSimilarSeeds: [SimilarSeed]
    /// Opens Query on `spec`; `detail` becomes the breadcrumb's tooltip, `suggestedName` (if any) defaults
    /// the Save As sheet if the user saves it from there.
    let openQuery: (QuerySpec, String, String?) -> Void

    @State private var navigation = DetailNavigationCoordinator(origin: .tools)
    @Environment(AskSimilarRouter.self) private var similarRouter
    @State private var searchText = ""
    @State private var selectedCategory: String?

    var body: some View {
        NavigationStack(path: Binding(get: { navigation.path }, set: { navigation.path = $0 })) {
            grid
                .navigationTitle("Tools")
                .navigationDestination(for: ToolDescriptor.self) { descriptor in
                    destination(for: descriptor)
                        // Drill-downs (artist/album/track) must return to THIS tool, not the landing grid:
                        // make the tool the origin the breadcrumb and back button unwind to. Query manages
                        // its own origin.
                        .onAppear { if descriptor.id != .query { navigation.setOrigin(.tools, label: descriptor.name) } }
                        // Query provides a context-aware parent breadcrumb. Hiding the generic stack button
                        // prevents a Trends handoff from accidentally returning to the Tools landing page.
                        .navigationBarBackButtonHidden(descriptor.id == .query || overviewToolRequest == descriptor.id)
                }
                .navigationDestination(for: ArtistIdentity.self) { ArtistDetailView(identity: $0, settings: settings, navigation: navigation) }
                .navigationDestination(for: AlbumIdentity.self) { AlbumDetailView(identity: $0, settings: settings, navigation: navigation) }
                .navigationDestination(for: TrackIdentity.self) { TrackDetailView(identity: $0, settings: settings, navigation: navigation) }
        }
        .onChange(of: askRequest?.id) {
            guard askRequest != nil else { return }
            navigation.path.append(ToolDescriptor.query)
        }
        .onChange(of: overviewToolRequest) { routeOverviewTool() }
        .onChange(of: openToolRequest) { routeOpenTool() }
        .onChange(of: similarRouter.pending?.id) { routeSimilarRequest() }
        .onAppear { routeOverviewTool(); routeSimilarRequest(); routeOpenTool() }
    }

    private func routeOpenTool() {
        guard let requested = openToolRequest, let descriptor = ToolDescriptor.all.first(where: { $0.id == requested }) else { return }
        openToolRequest = nil
        navigation.path = NavigationPath()
        navigation.path.append(descriptor)
    }

    private func routeOverviewTool() {
        guard let requested = overviewToolRequest,
              let descriptor = ToolDescriptor.all.first(where: { $0.id == requested }) else { return }
        navigation.path = NavigationPath()
        navigation.path.append(descriptor)
    }

    /// "Find similar" from the Ask box: open Similar Sounds fresh; the tool itself picks up the request and runs it.
    private func routeSimilarRequest() {
        guard similarRouter.pending != nil else { return }
        navigation.path = NavigationPath()
        navigation.path.append(ToolDescriptor.all.first { $0.id == .similarSounds }!)
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tools")
                        .font(AppTypography.pageTitle)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search tools by name, description, or category…", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: 550, minHeight: 44)
                    .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.separator.opacity(0.75), lineWidth: 1)
                    }

                    categoryPicker
                }

                if filteredTools.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 360, maximum: 640), spacing: 20)],
                        alignment: .leading,
                        spacing: 20
                    ) {
                        ForEach(filteredTools) { descriptor in
                            Button {
                                navigation.path.append(descriptor)
                            } label: {
                                ToolCard(descriptor: descriptor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { navigation.setOrigin(.tools, label: nil) }
    }

    private var filteredTools: [ToolDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolDescriptor.all.filter {
            let matchesCategory = selectedCategory == nil || $0.category == selectedCategory
            let matchesQuery = query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.category.localizedCaseInsensitiveContains(query)
            return matchesCategory && matchesQuery
        }
    }

    private var categories: [String] {
        ["Discover", "Analyze", "Create", "Organize"].filter { category in
            ToolDescriptor.all.contains { $0.category == category }
        }
    }

    private var categoryPicker: some View {
        HStack(spacing: 4) {
            categoryButton(title: "All", count: ToolDescriptor.all.count, category: nil)
            ForEach(categories, id: \.self) { category in
                categoryButton(
                    title: category,
                    count: ToolDescriptor.all.count { $0.category == category },
                    category: category
                )
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.35), in: Capsule())
        .fixedSize()
    }

    private func categoryButton(title: String, count: Int, category: String?) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(AppTypography.compactTitle)
                Text(count.formatted())
                    .font(AppTypography.badge)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(isSelected ? .white.opacity(0.15) : Color.primary.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(isSelected ? Color.accentColor : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func destination(for descriptor: ToolDescriptor) -> some View {
        switch descriptor.id {
        case .mostRecentMostOften:
            MostRecentMostOftenView(modelContainer: modelContainer, navigation: navigation, openQuery: openQuery)
        case .theClimb:
            TheClimbView(modelContainer: modelContainer, settings: settings, navigation: navigation, openQuery: openQuery)
        case .fadingFavorites:
            FadingFavoritesView(modelContainer: modelContainer, navigation: navigation, openQuery: openQuery)
        case .missingData:
            MissingDataView(modelContainer: modelContainer, navigation: navigation, openQuery: openQuery)
        case .lovedStatusAudit:
            LovedStatusAuditView(modelContainer: modelContainer, navigation: navigation)
        case .libraryGaps:
            LibraryGapsView(modelContainer: modelContainer, navigation: navigation)
        case .tagManagement:
            TagManagementView(modelContainer: modelContainer, navigation: navigation)
        case .similarSounds:
            SimilarSoundsView(
                modelContainer: modelContainer,
                navigation: navigation,
                incomingSeeds: overviewToolRequest == .similarSounds ? overviewSimilarSeeds : []
            )
        case .flaggedTracks:
            FlaggedTracksView(modelContainer: modelContainer, navigation: navigation)
        case .rabbitHole:
            RabbitHoleView(modelContainer: modelContainer, navigation: navigation)
        case .albumTurnovers:
            AlbumTurnoversView(modelContainer: modelContainer, navigation: navigation)
        case .collageGenerator:
            CollageGeneratorView(modelContainer: modelContainer, navigation: navigation)
        case .chartToppers:
            ChartToppersView(modelContainer: modelContainer, navigation: navigation)
        case .multiAlbumTracks:
            MultiAlbumTracksView(modelContainer: modelContainer, navigation: navigation)
        case .timeMachine:
            TimeMachineView(modelContainer: modelContainer, navigation: navigation)
        case .trips:
            TripsView(modelContainer: modelContainer, navigation: navigation, openQuery: openQuery)
        case .query:
            QueryView(modelContainer: modelContainer, settings: settings, isActive: true, askRequest: $askRequest, navigation: navigation)
        }
    }
}

/// One card on the landing grid.
struct ToolDescriptor: Identifiable, Hashable {
    enum Kind: Hashable { case mostRecentMostOften, theClimb, fadingFavorites, missingData, lovedStatusAudit, libraryGaps, tagManagement, similarSounds, flaggedTracks, rabbitHole, albumTurnovers, collageGenerator, chartToppers, multiAlbumTracks, timeMachine, trips, query }
    let id: Kind
    let name: String
    let summary: String
    let systemImage: String
    let category: String

    static let query = ToolDescriptor(
        id: .query, name: "Query",
        summary: "Build custom filters to explore exactly the listening history you want.",
        systemImage: "line.3.horizontal.decrease.circle", category: "Analyze"
    )

    static let all: [ToolDescriptor] = [
        query,
        ToolDescriptor(
            id: .mostRecentMostOften, name: "Most Recent, Most Often",
            summary: "Songs you discovered recently that you're already playing on repeat.",
            systemImage: "chart.line.uptrend.xyaxis", category: "Discover"
        ),
        ToolDescriptor(
            id: .theClimb, name: "The Climb",
            summary: "Songs moving up your charts fastest, including new Hot Shot debuts.",
            systemImage: "arrow.up.right", category: "Discover"
        ),
        ToolDescriptor(
            id: .fadingFavorites, name: "Fading Favorites",
            summary: "Former favorites that peaked hard and have since gone quiet — worth a revisit.",
            systemImage: "waveform.path.ecg", category: "Discover"
        ),
        ToolDescriptor(
            id: .missingData, name: "Missing Data",
            summary: "Find and fix gaps in release dates, artwork, and track durations.",
            systemImage: "questionmark.circle", category: "Organize"
        ),
        ToolDescriptor(
            id: .lovedStatusAudit, name: "Loved Status Audit",
            summary: "See where your loved tracks on Last.fm and favorites in Apple Music disagree.",
            systemImage: "heart.text.square", category: "Organize"
        ),
        ToolDescriptor(
            id: .libraryGaps, name: "Library Gaps",
            summary: "Songs you’ve scrobbled that aren’t in your Apple Music library — or were, and no longer are.",
            systemImage: "music.note.list", category: "Organize"
        ),
        ToolDescriptor(
            id: .tagManagement, name: "Tag Management",
            summary: "Bulk add or remove Last.fm tags — turn an Apple Music playlist or a saved query into a tag.",
            systemImage: "tag", category: "Organize"
        ),
        ToolDescriptor(
            id: .trips, name: "Trips",
            summary: "Record where you were and when, and see what you listened to on each trip, with or without weather.",
            systemImage: "airplane", category: "Organize"
        ),
        ToolDescriptor(
            id: .flaggedTracks, name: "Flagged Tracks",
            summary: "Keep a hand-picked collection of tracks to filter, sort, and export.",
            systemImage: "flag.fill", category: "Organize"
        ),
        ToolDescriptor(
            id: .similarSounds, name: "Similar Sounds",
            summary: "Pick a few favorites and find what in your library sounds like them.",
            systemImage: "waveform.badge.magnifyingglass", category: "Discover"
        ),
        ToolDescriptor(
            id: .rabbitHole, name: "Rabbit Hole",
            summary: "Start with one track and follow a branching path of recommendations through your library.",
            systemImage: "point.3.connected.trianglepath.dotted", category: "Discover"
        ),
        ToolDescriptor(
            id: .albumTurnovers, name: "Album Turnovers",
            summary: "Rank albums by how often you complete their full tracklists and see what remains in each cycle.",
            systemImage: "repeat", category: "Analyze"
        ),
        ToolDescriptor(
            id: .collageGenerator, name: "Collage Generator",
            summary: "Turn your top artists, albums, or tracks into a shareable image.",
            systemImage: "square.grid.3x3.fill", category: "Create"
        ),
        ToolDescriptor(
            id: .chartToppers, name: "Chart Toppers",
            summary: "See each release period’s number one artist, album, or track—and expand the complete top 10.",
            systemImage: "trophy.fill", category: "Analyze"
        ),
        ToolDescriptor(
            id: .multiAlbumTracks, name: "Multi-Album Tracks",
            summary: "Find tracks by the same artist that appear across multiple albums and editions.",
            systemImage: "square.stack.3d.up.fill", category: "Organize"
        ),
        ToolDescriptor(
            id: .timeMachine, name: "Time Machine",
            summary: "Revisit what you played on this date, week, or month across your listening history.",
            systemImage: "calendar.badge.clock", category: "Discover"
        ),
    ].sorted { first, second in
        first.name.localizedStandardCompare(second.name) == .orderedAscending
    }
}

private struct ToolCard: View {
    let descriptor: ToolDescriptor

    private var accent: Color {
        switch descriptor.category {
        case "Analyze": .orange
        case "Create": .purple
        case "Organize": .green
        default: .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: descriptor.systemImage)
                    .font(AppTypography.navigationIcon)
                    .foregroundStyle(accent)
                    .frame(width: 46, height: 46)
                    .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer()
                Text(descriptor.category)
                    .font(AppTypography.badge)
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(descriptor.name)
                    .font(AppTypography.contentTitle)
                    .foregroundStyle(.primary)
                Text(descriptor.summary)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 174, alignment: .topLeading)
        .background(accent.opacity(0.095), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.32), lineWidth: 1)
        }
    }
}

struct ToolHeadlineCard<Content: View>: View {
    let eyebrow: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ eyebrow: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow)
                .font(AppTypography.badge)
                .foregroundStyle(.orange)
            content
                .font(AppTypography.entitySubtitle.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.orange.opacity(0.2), lineWidth: 1) }
    }
}
