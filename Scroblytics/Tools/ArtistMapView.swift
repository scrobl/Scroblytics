import SwiftUI
import SwiftData

// MARK: - Model

/// What the Artist Map screen shows and does: your top artists for a period, Last.fm's saved answers about who is similar to whom, the
/// lookups for the artists that have none, and the picture those make. The engine itself is in `ArtistMap.swift`.
@MainActor
@Observable
final class ArtistMapModel {
    struct Options: Codable, Equatable {
        enum Period: String, Codable, CaseIterable, Identifiable {
            case allTime, year, days90, days30
            var id: String { rawValue }
            var title: String {
                switch self {
                case .allTime: "All time"
                case .year: "Last year"
                case .days90: "Last 90 days"
                case .days30: "Last 30 days"
                }
            }

            func range(now: Date, calendar: Calendar = AppCalendars.listening) -> (from: Date?, to: Date?) {
                switch self {
                case .allTime: (nil, nil)
                case .year: (calendar.date(byAdding: .year, value: -1, to: now), nil)
                case .days90: (calendar.date(byAdding: .day, value: -90, to: now), nil)
                case .days30: (calendar.date(byAdding: .day, value: -30, to: now), nil)
                }
            }
        }

        var count = 100
        var period: Period = .allTime
        var minMatchPercent = 40
        var showGhosts = false

        init() {}

        private enum CodingKeys: String, CodingKey { case count, period, minMatchPercent, showGhosts }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 100
            period = try values.decodeIfPresent(Period.self, forKey: .period) ?? .allTime
            minMatchPercent = try values.decodeIfPresent(Int.self, forKey: .minMatchPercent) ?? 40
            showGhosts = try values.decodeIfPresent(Bool.self, forKey: .showGhosts) ?? false
        }
    }

    static let countChoices = [50, 100, 200]
    static let minMatchRange = 30...90

    /// One line of the side panel's "closest links".
    struct Link: Identifiable {
        let key: String
        let name: String
        let isGhost: Bool
        /// How strongly the selected artist's answer lists this one, and this one's answer lists the selected artist (0 = not listed).
        let outgoing: Double
        let incoming: Double
        var id: String { key }
        var weight: Double { max(outgoing, incoming) }
    }

    struct Selection {
        let node: ArtistMapGraph.Node
        let group: Int
        let groupName: String?
        let links: [Link]
    }

    var options = Options()
    var selectedKey: String?
    var hoveredKey: String?

    private(set) var shown = ArtistMapGraph()
    private(set) var groups = ArtistMapGroups()
    private(set) var positions: [CGPoint] = []
    private(set) var isLoadingHistory = true
    private(set) var hasHistory = true
    private(set) var scopeCount = 0
    private(set) var answeredCount = 0
    private(set) var isLookingUp = false
    private(set) var lookupDone = 0
    private(set) var lookupTotal = 0
    private(set) var lookupMessage: String?

    let container: ModelContainer
    private var snapshots: [ScrobbleSnapshot] = []
    private var scope: [ArtistMapEntry] = []
    private var libraryKeys = Set<String>()
    private var answers: [String: [SimilarArtist]] = [:]
    private var positionsByKey: [String: CGPoint] = [:]
    private var generation = 0
    private var rebuildTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var throttlePending = false
    /// The drawing area (the canvas less its margin), which the layout is worked out for.
    private(set) var canvasSize = ArtistMapLayout.defaultCanvas
    static let canvasPadding: CGFloat = 36
    /// Set by the offscreen snapshots, which show made-up data and must not read the history.
    private(set) var isSnapshotSample = false

    init(container: ModelContainer) { self.container = container }

    var missingCount: Int { max(0, scopeCount - answeredCount) }
    var maxPlays: Int { shown.nodes.map(\.plays).max() ?? 1 }

    /// The drawing area changed size: lay the map out again for the new shape (a small change is ignored).
    func canvasChanged(_ size: CGSize) {
        let usable = CGSize(width: size.width - Self.canvasPadding * 2, height: size.height - Self.canvasPadding * 2)
        guard usable.width > 150, usable.height > 150 else { return }
        let moved = abs(usable.width - canvasSize.width) / canvasSize.width > 0.08 || abs(usable.height - canvasSize.height) / canvasSize.height > 0.08
        guard moved else { return }
        canvasSize = usable
        if !shown.nodes.isEmpty { scheduleRebuild(delay: .milliseconds(250)) }
    }

    var statusText: String {
        guard scopeCount > 0 else { return "" }
        let shownArtists = shown.nodes.filter { !$0.isGhost }.count
        let ghosts = shown.nodes.count - shownArtists
        var parts = ["\(shownArtists) artists", "\(shown.edges.count) links"]
        if ghosts > 0 { parts.append("\(ghosts) you haven't played") }
        parts.append(missingCount == 0 ? "saved answers for all \(scopeCount)" : "saved answers for \(answeredCount) of \(scopeCount)")
        return parts.joined(separator: " · ")
    }

    // MARK: Loading

    func start() async {
        isLoadingHistory = true
        snapshots = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
        hasHistory = !snapshots.isEmpty
        isLoadingHistory = false
        await rescope()
    }

    /// The artists on the map changed (a different count or period): take the top artists again and read what is saved about them.
    func rescope() async {
        lookupTask?.cancel()
        let snaps = snapshots, count = options.count, range = options.period.range(now: Date())
        let top = await Task.detached(priority: .userInitiated) {
            ArtistMapScope.top(snapshots: snaps, count: count, from: range.from, to: range.to)
        }.value
        scope = top.entries
        libraryKeys = top.libraryKeys
        scopeCount = scope.count
        let provider = ArtistMapSavedProvider(store: SimilarityCacheStore(modelContainer: container))
        let saved = await ArtistMapLoader.load(artists: scope.map(\.name), provider: provider, fetchMissing: false, isOffline: { false }, onUpdate: { _ in })
        answers = saved.neighbors
        updateAnswered()
        await rebuild()
    }

    func optionsChanged(from old: Options) {
        if old.count != options.count || old.period != options.period {
            Task { await rescope() }
        } else {
            scheduleRebuild()
        }
    }

    private func updateAnswered() {
        answeredCount = scope.filter { answers[ArtistMapNames.key($0.name)] != nil }.count
    }

    // MARK: Drawing

    private func scheduleRebuild(delay: Duration = .milliseconds(150)) {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await rebuild()
        }
    }

    /// While lookups arrive the picture is redrawn at most once a second.
    private func scheduleThrottled() {
        guard !throttlePending else { return }
        throttlePending = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            throttlePending = false
            await rebuild()
        }
    }

    func rebuild() async {
        generation += 1
        let mine = generation
        let graph = ArtistMapGraph.build(scope: scope, libraryKeys: libraryKeys, neighbors: answers)
        let filtered = graph.filtered(minMatch: Double(options.minMatchPercent) / 100, showGhosts: options.showGhosts)
        let found = ArtistMapGroups.find(in: filtered)
        let previous = positionsByKey
        let canvas = canvasSize
        let top = filtered.nodes.map(\.plays).max() ?? 1
        let radii = filtered.nodes.map { Double(Self.radius(of: $0, maxPlays: top)) }
        let laidOut = await Task.detached(priority: .userInitiated) {
            ArtistMapLayout.force(graph: filtered, previous: previous, canvas: canvas, radii: radii)
        }.value
        guard mine == generation else { return }
        shown = filtered
        groups = found
        positions = laidOut
        for (index, node) in filtered.nodes.enumerated() { positionsByKey[node.key] = laidOut[index] }
        if let key = selectedKey, !filtered.nodes.contains(where: { $0.key == key }) { selectedKey = nil }
    }

    // MARK: Lookups

    func lookUpMissing() {
        guard !isLookingUp else { return }
        guard let credentials = LastfmCredentialsStore.load() else {
            lookupMessage = "Connect Last.fm in Settings to look up similar artists."
            return
        }
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        let provider = LastfmSimilarityProvider(client: client, store: SimilarityCacheStore(modelContainer: container))
        let names = scope.map(\.name)
        isLookingUp = true
        lookupMessage = nil
        lookupDone = answeredCount
        lookupTotal = names.count
        lookupTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream.makeStream(of: ArtistMapLoader.Update.self)
            let consumer = Task { @MainActor in
                for await update in stream { self?.apply(update) }
            }
            let result = await ArtistMapLoader.load(
                artists: names, provider: provider, fetchMissing: true,
                isOffline: { ConnectivityGate.isOffline }, onUpdate: { continuation.yield($0) }
            )
            continuation.finish()
            await consumer.value
            await self?.finishLookup(result.summary)
        }
    }

    func stopLookup() { lookupTask?.cancel() }

    private func apply(_ update: ArtistMapLoader.Update) {
        answers[update.key] = update.neighbors
        lookupDone = update.done
        lookupTotal = update.total
        updateAnswered()
        if !update.fromSaved { scheduleThrottled() }
    }

    private func finishLookup(_ summary: ArtistMapLoader.Summary) async {
        isLookingUp = false
        updateAnswered()
        switch summary.stopped {
        case .offline: lookupMessage = "Offline mode is on, so the rest wait until you go online."
        case .tooManyFailures: lookupMessage = "Last.fm isn't answering right now. Try again in a moment."
        case .cancelled: lookupMessage = nil
        case nil: lookupMessage = summary.failed > 0 ? "\(summary.failed) artists couldn't be looked up. Try again to fill them in." : nil
        }
        await rebuild()
    }

    // MARK: Selection

    func radius(of node: ArtistMapGraph.Node) -> CGFloat { Self.radius(of: node, maxPlays: maxPlays) }

    static func radius(of node: ArtistMapGraph.Node, maxPlays: Int) -> CGFloat {
        if node.isGhost { return 8 }
        let share = (Double(node.plays) / Double(max(maxPlays, 1))).squareRoot()
        return 5 + 13 * CGFloat(share)
    }

    func index(ofKey key: String?) -> Int? {
        guard let key else { return nil }
        return shown.nodes.firstIndex { $0.key == key }
    }

    /// The keys of the artists joined to `key` by a line on screen.
    func neighborKeys(of key: String) -> Set<String> {
        guard let i = index(ofKey: key) else { return [] }
        var out = Set<String>()
        for edge in shown.edges {
            if edge.a == i { out.insert(shown.nodes[edge.b].key) } else if edge.b == i { out.insert(shown.nodes[edge.a].key) }
        }
        return out
    }

    var selection: Selection? {
        guard let i = index(ofKey: selectedKey) else { return nil }
        var links: [Link] = []
        for edge in shown.edges {
            if edge.a == i {
                let other = shown.nodes[edge.b]
                links.append(Link(key: other.key, name: other.name, isGhost: other.isGhost, outgoing: edge.aToB, incoming: edge.bToA))
            } else if edge.b == i {
                let other = shown.nodes[edge.a]
                links.append(Link(key: other.key, name: other.name, isGhost: other.isGhost, outgoing: edge.bToA, incoming: edge.aToB))
            }
        }
        links.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.name < $1.name }
        let group = i < groups.groupOfNode.count ? groups.groupOfNode[i] : -1
        return Selection(node: shown.nodes[i], group: group, groupName: group >= 0 ? groups.names[group] : nil, links: links)
    }
}

// MARK: - Colors

enum ArtistMapPalette {
    private static let colors: [Color] = [.purple, .teal, .orange, .pink, .indigo, .mint, .brown, .cyan]

    static func color(group: Int) -> Color { group < 0 ? .gray : colors[group % colors.count] }
}

// MARK: - View

struct ArtistMapView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    let openQuery: (QuerySpec, String, String?) -> Void

    private static let toolId = "artistMap"

    @Environment(\.modelContext) private var modelContext
    @State private var model: ArtistMapModel

    init(
        modelContainer: ModelContainer, navigation: DetailNavigationCoordinator, openQuery: @escaping (QuerySpec, String, String?) -> Void,
        sample: ArtistMapModel? = nil
    ) {
        self.modelContainer = modelContainer
        self.navigation = navigation
        self.openQuery = openQuery
        _model = State(initialValue: sample ?? ArtistMapModel(container: modelContainer))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageSettingsHeader("Artist Map") { controls }
                if model.isLoadingHistory {
                    ProgressView("Reading your history…").frame(maxWidth: .infinity, minHeight: 240)
                } else if !model.hasHistory {
                    ContentUnavailableView("No scrobbles yet", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Once your history is imported, your artists appear here, joined by how similar Last.fm says they are."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    statusStrip
                    HStack(alignment: .top, spacing: 12) {
                        ArtistMapCanvas(model: model, onOpen: openArtist, onQuery: query)
                            .frame(minWidth: 360, minHeight: 520)
                        ArtistMapPanel(model: model, onOpen: openArtist, onQuery: query)
                            .frame(width: 250)
                    }
                    legend
                }
            }
            .padding(16)
        }
        .navigationTitle("Artist Map")
        .task {
            guard !model.isSnapshotSample else { return }
            model.options = ToolFilterSettingsStore.load(ArtistMapModel.Options.self, toolId: Self.toolId, context: modelContext, default: ArtistMapModel.Options())
            await model.start()
        }
        .onChange(of: model.options) { old, new in
            guard !model.isSnapshotSample else { return }
            ToolFilterSettingsStore.save(new, toolId: Self.toolId, context: modelContext)
            model.optionsChanged(from: old)
        }
    }

    // MARK: Controls

    private var controls: some View {
        ToolControlsFlow {
            Picker("Artists", selection: $model.options.count) {
                ForEach(ArtistMapModel.countChoices, id: \.self) { Text("\($0)").tag($0) }
            }
            .help("How many of your most played artists are on the map.")
            Picker("Period", selection: $model.options.period) {
                ForEach(ArtistMapModel.Options.Period.allCases) { Text($0.title).tag($0) }
            }
            .help("The period that ranks your artists and sizes the dots.")
            HStack(spacing: 8) {
                Text("Minimum match").font(AppTypography.metadata)
                Slider(value: minMatchBinding, in: Double(ArtistMapModel.minMatchRange.lowerBound)...Double(ArtistMapModel.minMatchRange.upperBound), step: 5)
                    .frame(width: 140)
                Text("\(model.options.minMatchPercent)%").font(AppTypography.metadata).monospacedDigit().frame(width: 36, alignment: .leading)
            }
            .help("Show only links at least this strong. Last.fm scores similarity from 0 to 100%.")
            Toggle("Show artists I haven't played", isOn: $model.options.showGhosts)
                .toggleStyle(.checkbox)
                .help("Also draw the artists Last.fm says are most similar to yours that you've never played, as dashed dots.")
        }
    }

    private var minMatchBinding: Binding<Double> {
        Binding(get: { Double(model.options.minMatchPercent) }, set: { model.options.minMatchPercent = Int($0.rounded()) })
    }

    // MARK: Status

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(model.statusText).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                if model.isLookingUp {
                    ProgressView(value: Double(model.lookupDone), total: Double(max(model.lookupTotal, 1))).frame(width: 140)
                    Text("\(model.lookupDone) of \(model.lookupTotal)").font(AppTypography.compactMetadata).monospacedDigit().foregroundStyle(.secondary)
                    Button("Stop") { model.stopLookup() }.controlSize(.small)
                } else if model.missingCount > 0 {
                    Button("Look up \(model.missingCount) artists") { model.lookUpMissing() }
                        .controlSize(.small)
                        .disabled(Connectivity.shared.isOffline)
                        .help(Connectivity.shared.isOffline
                              ? "Offline mode is on. Go online to look up similar artists."
                              : "Asks Last.fm which artists are similar to each of these, about four a second. The answers are saved for 30 days.")
                }
            }
            if let message = model.lookupMessage {
                Text(message).font(AppTypography.compactMetadata).foregroundStyle(.orange)
            } else if model.answeredCount == 0 && model.scopeCount > 0 && !model.isLookingUp {
                Text("No similar-artist answers are saved for these artists yet. Look them up to draw the links.")
                    .font(AppTypography.compactMetadata).foregroundStyle(.orange)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            Text("Dot size = plays").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            Text("Line thickness = match").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            Text("Color = a group of artists that point at each other").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            if model.options.showGhosts {
                Text("Dashed = not played").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func openArtist(_ name: String) { navigation.goToArtist(ArtistIdentity(name: name)) }

    private func query(_ name: String) {
        openQuery(ArtistMapLinks.querySpec(artist: name), "Artist Map · \(name)", "Tracks by \(name)")
    }
}

// MARK: - Canvas

private struct ArtistMapCanvas: View {
    @Bindable var model: ArtistMapModel
    let onOpen: (String) -> Void
    let onQuery: (String) -> Void

    @State private var scale: CGFloat = 1
    @State private var pinchBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private let padding = ArtistMapModel.canvasPadding

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in draw(&context, size: size) }
                ForEach(Array(model.shown.nodes.enumerated()), id: \.element.key) { index, node in
                    hitArea(index: index, node: node, size: geo.size)
                }
                zoomControls
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.canvasChanged($0) }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in offset = CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height) }
            )
            .gesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(5, max(0.6, pinchBase * value.magnification)) }
                    .onEnded { _ in pinchBase = scale }
            )
            .onTapGesture { model.selectedKey = nil }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Artist map with \(model.shown.nodes.count) artists")
    }

    private func screenPoint(_ index: Int, size: CGSize) -> CGPoint {
        guard index < model.positions.count else { return .zero }
        let p = model.positions[index]
        let usableW = max(size.width - padding * 2, 1), usableH = max(size.height - padding * 2, 1)
        return CGPoint(
            x: size.width / 2 + (p.x - 0.5) * usableW * scale + offset.width + drag.width,
            y: size.height / 2 + (p.y - 0.5) * usableH * scale + offset.height + drag.height
        )
    }

    private func displayRadius(_ node: ArtistMapGraph.Node) -> CGFloat { model.radius(of: node) * min(max(scale, 0.8).squareRoot(), 1.6) }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let nodes = model.shown.nodes
        guard nodes.count == model.positions.count else { return }
        let selected = model.selectedKey
        let selectedIndex = model.index(ofKey: selected)
        let linked = selected.map { model.neighborKeys(of: $0) } ?? []
        for edge in model.shown.edges {
            let a = screenPoint(edge.a, size: size), b = screenPoint(edge.b, size: size)
            let hot = selectedIndex == edge.a || selectedIndex == edge.b
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            let ghostLine = nodes[edge.a].isGhost || nodes[edge.b].isGhost
            let strength = edge.weight
            let color: Color = hot ? .accentColor : Color.secondary
            let opacity = hot ? 0.9 : (selected == nil ? 0.2 + strength * 0.4 : 0.08)
            context.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: 0.6 + strength * 4.2, lineCap: .round, dash: ghostLine ? [4, 4] : []))
        }
        var labelled: [(index: Int, priority: Int)] = []
        let byPlays = nodes.indices.sorted { nodes[$0].plays != nodes[$1].plays ? nodes[$0].plays > nodes[$1].plays : $0 < $1 }
        let topLinked = Set(model.selection?.links.prefix(8).map(\.key) ?? [])
        let everyone = scale >= 2.5
        for (index, node) in nodes.enumerated() {
            var priority = 99
            if node.key == selected { priority = 0 }
            else if node.key == model.hoveredKey { priority = 1 }
            else if topLinked.contains(node.key) { priority = 2 }
            else if everyone { priority = 4 }
            else if let rank = byPlays.firstIndex(of: index), rank < 14, !node.isGhost { priority = 3 + rank }
            if priority < 99 { labelled.append((index, priority)) }
        }
        labelled.sort { $0.priority != $1.priority ? $0.priority < $1.priority : $0.index < $1.index }
        var placed: [CGRect] = []
        var labelAt: [Int: CGPoint] = [:]
        for item in labelled {
            let node = nodes[item.index]
            let p = screenPoint(item.index, size: size)
            let r = displayRadius(node)
            let text = Self.shortName(node.name)
            let width = Self.estimatedWidth(text) + 6
            let frame = CGRect(x: p.x - width / 2, y: p.y + r + 2, width: width, height: 14)
            if item.priority > 1, placed.contains(where: { $0.intersects(frame) }) { continue }
            placed.append(frame)
            labelAt[item.index] = CGPoint(x: p.x, y: frame.midY)
        }
        for (index, node) in nodes.enumerated() {
            let p = screenPoint(index, size: size)
            let r = displayRadius(node)
            let isSelected = node.key == selected
            let dim = selected != nil && !isSelected && !linked.contains(node.key)
            let color = ArtistMapPalette.color(group: index < model.groups.groupOfNode.count ? model.groups.groupOfNode[index] : -1)
            let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            if node.isGhost {
                context.fill(circle, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(circle, with: .color(.secondary.opacity(dim ? 0.4 : 0.9)), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
            } else {
                context.fill(circle, with: .color(color.opacity(dim ? 0.3 : 0.85)))
                context.stroke(circle, with: .color(isSelected ? Color.primary : color), lineWidth: isSelected ? 2.5 : 1)
            }
        }
        for (index, point) in labelAt {
            let node = nodes[index]
            let isSelected = node.key == selected
            let dim = selected != nil && !isSelected && !linked.contains(node.key)
            let label = Text(Self.shortName(node.name)).font(.system(size: 11, weight: isSelected ? .semibold : .regular)).foregroundColor(dim ? .secondary : .primary)
            context.draw(context.resolve(label), at: point, anchor: .center)
        }
    }

    /// Long names are cut for the map; the side panel and the tooltip carry the whole name.
    private static func shortName(_ name: String) -> String { name.count > 26 ? String(name.prefix(25)) + "…" : name }

    /// About how wide a label is in 11-point type (characters in other scripts are wider).
    private static func estimatedWidth(_ text: String) -> CGFloat {
        text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 11.5 : 6.2) }
    }

    @ViewBuilder
    private func hitArea(index: Int, node: ArtistMapGraph.Node, size: CGSize) -> some View {
        let r = max(displayRadius(node), 12)
        let base = Color.clear
            .frame(width: r * 2, height: r * 2)
            .contentShape(Circle())
            .position(screenPoint(index, size: size))
            .onTapGesture { model.selectedKey = node.key }
            .onHover { inside in
                if inside { model.hoveredKey = node.key } else if model.hoveredKey == node.key { model.hoveredKey = nil }
            }
            .accessibilityElement()
            .accessibilityLabel(node.isGhost ? "\(node.name), not played" : "\(node.name), \(node.plays) plays")
            .accessibilityAddTraits(.isButton)
        if node.isGhost {
            base.contextMenu {
                Button("View on Last.fm") { if let url = ArtistMapLinks.lastfmURL(artist: node.name) { NSWorkspace.shared.open(url) } }
            }
        } else {
            base.entityContextMenu(target: ImageTarget(kind: .artist, artist: node.name, album: nil, track: nil), onOpen: { onOpen(node.name) })
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 4) {
            Button { zoom(by: 1.3) } label: { Image(systemName: "plus") }.help("Zoom in")
            Button { zoom(by: 1 / 1.3) } label: { Image(systemName: "minus") }.help("Zoom out")
            Button { scale = 1; pinchBase = 1; offset = .zero } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Fit the whole map")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
    }

    private func zoom(by factor: CGFloat) {
        scale = min(5, max(0.6, scale * factor))
        pinchBase = scale
    }
}

// MARK: - Panel

private struct ArtistMapPanel: View {
    let model: ArtistMapModel
    let onOpen: (String) -> Void
    let onQuery: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selection = model.selection {
                header(selection)
                Divider()
                links(selection)
                actions(selection)
            } else {
                Text("Select an artist to see who it is closest to.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func header(_ s: ArtistMapModel.Selection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.node.name).font(AppTypography.sectionTitle).lineLimit(2)
            if s.node.isGhost {
                Text("You haven't played this artist.").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(ArtistMapPalette.color(group: s.group)).frame(width: 10, height: 10)
                    Text(s.groupName.map { "\($0) and friends" } ?? "Not in a group").font(AppTypography.compactMetadata)
                }
                Text("\(s.node.plays.formatted()) plays in this period").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func links(_ s: ArtistMapModel.Selection) -> some View {
        Text("Closest links").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        if s.links.isEmpty {
            Text("No links at this minimum match.").font(AppTypography.supporting).foregroundStyle(.secondary)
        } else {
            ForEach(s.links.prefix(6)) { link in
                Button { model.selectedKey = link.key } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(link.name).font(AppTypography.supporting).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Int((link.weight * 100).rounded()))%").font(AppTypography.compactMetadata).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: link.weight).progressViewStyle(.linear).controlSize(.mini)
                    }
                }
                .buttonStyle(.plain)
                .help(Self.directionText(selected: s.node.name, link: link))
            }
            if let top = s.links.first, top.outgoing > 0, top.incoming > 0, abs(top.outgoing - top.incoming) >= 0.05 {
                Text("The line uses the higher of the two directions. \(Self.directionText(selected: s.node.name, link: top))")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ s: ArtistMapModel.Selection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if s.node.isGhost {
                Button { if let url = ArtistMapLinks.lastfmURL(artist: s.node.name) { NSWorkspace.shared.open(url) } } label: {
                    Label("View on Last.fm", systemImage: "safari").frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Button { onOpen(s.node.name) } label: { Label("Open artist page", systemImage: "person.crop.circle").frame(maxWidth: .infinity, alignment: .leading) }
                Button { onQuery(s.node.name) } label: { Label("Open in Query", systemImage: "tablecells").frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .controlSize(.small)
    }

    private static func directionText(selected: String, link: ArtistMapModel.Link) -> String {
        func pct(_ v: Double) -> String { v > 0 ? "\(Int((v * 100).rounded()))%" : "not listed" }
        return "\(selected) lists \(link.name) at \(pct(link.outgoing)); \(link.name) lists \(selected) at \(pct(link.incoming))."
    }
}

#if DEBUG
extension ArtistMapModel {
    /// A made-up map for the offscreen snapshots: three clusters of artists, a few bridges between them, some never-played dots and some
    /// awkward names (very long, another script).
    static func sample(container: ModelContainer, artists: Int = 60, showGhosts: Bool = true, minMatch: Int = 40, canvas: CGSize = ArtistMapLayout.defaultCanvas) -> ArtistMapModel {
        let model = ArtistMapModel(container: container)
        model.canvasSize = canvas
        var rng = SeededRandom(seed: 7)
        var scope: [ArtistMapEntry] = []
        var answers: [String: [SimilarArtist]] = [:]
        var firstOfCluster: [String] = []
        let clusters = ["Alpha", "Bravo", "Charlie"]
        for (c, cluster) in clusters.enumerated() {
            let names = (1...max(artists / 3, 4)).map { i -> String in
                switch i {
                case 3: "\(cluster) Band With A Very Long Name That Keeps Going"
                case 5: "日本のバンド \(cluster)"
                default: "\(cluster) \(i)"
                }
            }
            firstOfCluster.append(names[0])
            for (i, name) in names.enumerated() { scope.append(ArtistMapEntry(name: name, plays: max(20, 4000 / (i + 1) - c * 150))) }
            for (i, name) in names.enumerated() {
                var list: [SimilarArtist] = []
                for j in names.indices where j != i {
                    let r = Double(rng.next() % 1000) / 1000
                    if r < 0.28 { list.append(SimilarArtist(name: names[j], match: 0.35 + r * 2)) }
                }
                if i % 6 == 0 { list.append(SimilarArtist(name: "Never Played \(c)-\(i % 5)", match: 0.5 + Double(i % 4) * 0.1)) }
                answers[ArtistMapNames.key(name)] = list
            }
        }
        for c in clusters.indices {
            let from = ArtistMapNames.key(firstOfCluster[c]), to = firstOfCluster[(c + 1) % clusters.count]
            answers[from, default: []].append(SimilarArtist(name: to, match: 0.45))
        }
        model.scope = scope
        model.libraryKeys = Set(scope.map { ArtistMapNames.key($0.name) })
        model.answers = answers
        model.scopeCount = scope.count
        model.answeredCount = scope.count
        model.options.showGhosts = showGhosts
        model.options.minMatchPercent = minMatch
        let graph = ArtistMapGraph.build(scope: scope, libraryKeys: model.libraryKeys, neighbors: answers)
            .filtered(minMatch: Double(minMatch) / 100, showGhosts: showGhosts)
        model.shown = graph
        model.groups = ArtistMapGroups.find(in: graph)
        let top = graph.nodes.map(\.plays).max() ?? 1
        model.positions = ArtistMapLayout.force(graph: graph, canvas: canvas, radii: graph.nodes.map { Double(radius(of: $0, maxPlays: top)) })
        model.isLoadingHistory = false
        model.hasHistory = true
        model.isSnapshotSample = true
        model.selectedKey = graph.nodes.first { $0.name.hasPrefix("Bravo 2") }?.key ?? graph.nodes.first?.key
        return model
    }
}
#endif
