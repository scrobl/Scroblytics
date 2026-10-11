import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct CollageGeneratorView: View {
    struct Options: Codable, Equatable {
        var grid = CollageGrid.three
        var source = CollageSource.top
        var entityRawValue = TopChartsEntity.album.rawValue
        var metricRawValue = TopChartsMetric.scrobbles.rawValue
        var period = CollagePeriod.year
        var rangeID = "last365"
        var customFrom = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        var customTo = Date()
        var showTitles = true
        var showStats = true
        var showPeriod = true
    }

    private static let toolID = "collageGenerator"
    private static let defaults = Options()

    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    @Environment(\.modelContext) private var modelContext
    @State private var options = defaults
    @State private var items: [CollageItem] = []
    @State private var images: [String: NSImage] = [:]
    @State private var rangeOptions: [DateRangeOption] = []
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var hasLoadedOptions = false
    @State private var zoom = 1.0

    private var entity: TopChartsEntity {
        TopChartsEntity(rawValue: options.entityRawValue) ?? .album
    }

    private var metric: TopChartsMetric {
        TopChartsMetric(rawValue: options.metricRawValue) ?? .scrobbles
    }

    private var selectedRange: DateRange {
        if options.rangeID == "custom" {
            return DateRange(from: min(options.customFrom, options.customTo), to: max(options.customFrom, options.customTo))
        }
        return rangeOptions.first { $0.id == options.rangeID }?.range()
            ?? DateRange(from: Date().addingTimeInterval(-365 * 86_400), to: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Collage Generator") {
                    CollagePrimaryControls(
                        grid: $options.grid,
                        source: $options.source,
                        entityRawValue: $options.entityRawValue,
                        metricRawValue: $options.metricRawValue,
                        period: $options.period,
                        rangeID: $options.rangeID,
                        customFrom: $options.customFrom,
                        customTo: $options.customTo,
                        rangeOptions: rangeOptions,
                        isLoading: isLoading,
                        onRefresh: { Task { await reload() } }
                    )
                }

                ToolHeadlineCard("TURN YOUR LISTENING INTO ART") {
                    Text("Build a shareable collage from your top artists, albums, or tracks. Release-period mode picks one favorite from each era of your library.")
                }

                CollageDisplayControls(
                    showTitles: $options.showTitles,
                    showStats: $options.showStats,
                    showPeriod: $options.showPeriod,
                    periodAvailable: options.source == .period,
                    zoom: $zoom,
                    canExport: !items.isEmpty && !isLoading && !isExporting,
                    isExporting: isExporting,
                    onExport: export
                )

                content
            }
            .padding(16)
        }
        .navigationTitle("Collage Generator")
        .task {
            let oldest = try? await TopChartsEngine.fetchOldestScrobbleDate(container: modelContainer)
            rangeOptions = DateRangePresets.build(oldestScrobbleDate: oldest)
            options = ToolFilterSettingsStore.load(
                Options.self,
                toolId: Self.toolID,
                context: modelContext,
                default: Self.defaults
            )
            await reload()
            hasLoadedOptions = true
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .scrobbleSyncDidComplete) {
                await reload()
            }
        }
        .onChange(of: options) { _, newValue in
            guard hasLoadedOptions else { return }
            ToolFilterSettingsStore.save(newValue, toolId: Self.toolID, context: modelContext)
            Task { await reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, items.isEmpty {
            ProgressView("Building collage…")
                .frame(maxWidth: .infinity, minHeight: 360)
        } else if let errorMessage, items.isEmpty {
            ContentUnavailableView(
                "Couldn’t build collage",
                systemImage: "square.grid.3x3",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, minHeight: 360)
        } else if items.isEmpty {
            ContentUnavailableView(
                "Nothing to place yet",
                systemImage: "square.grid.3x3",
                description: Text(emptyDescription)
            )
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(items.count.formatted()) of \(options.grid.tileCount.formatted()) tiles")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isLoading { ProgressView().controlSize(.small) }
                }

                GeometryReader { proxy in
                    let baseWidth = min(proxy.size.width, 960)
                    let collageWidth = baseWidth * zoom
                    let dimensions = options.grid.dimensions
                    let collageHeight = collageWidth
                        * CGFloat(dimensions.rows)
                        / CGFloat(dimensions.columns)
                    CollageCanvas(
                        items: items,
                        images: images,
                        grid: options.grid,
                        metric: metric,
                        showTitles: options.showTitles,
                        showStats: options.showStats,
                        showPeriod: options.showPeriod,
                        onSelect: open
                    )
                    .frame(width: collageWidth, height: collageHeight)
                    .position(x: proxy.size.width / 2, y: 12 + collageHeight / 2)
                }
                .aspectRatio(
                    CGFloat(options.grid.dimensions.columns) / CGFloat(options.grid.dimensions.rows),
                    contentMode: .fit
                )
                .frame(minHeight: 300)
                .clipped()
                .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.separator.opacity(0.55), lineWidth: 1)
                }
            }
        }
    }

    private var emptyDescription: String {
        if options.source == .period {
            return "This view needs resolved release dates. Try another entity or period, or resolve missing dates in Missing Data."
        }
        return "No listening history falls within the selected date range."
    }

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded: [CollageItem]
            if options.source == .top {
                let entries = try await TopChartsEngine.fetchRankings(
                    container: modelContainer,
                    durationContext: modelContext,
                    entity: entity,
                    range: selectedRange,
                    limit: options.grid.tileCount,
                    includePeak: false,
                    metric: metric
                )
                loaded = entries.map {
                    CollageItem(
                        id: $0.id.uuidString,
                        name: $0.name,
                        artist: $0.artist ?? $0.name,
                        album: $0.album ?? (entity == .album ? $0.name : nil),
                        metricValue: $0.metricValue(for: metric),
                        imageURL: $0.imageURL,
                        periodLabel: nil
                    )
                }
            } else {
                loaded = try await CollagePeriodReader(modelContainer: modelContainer).load(
                    entity: entity,
                    metric: metric,
                    period: options.period,
                    limit: options.grid.tileCount
                )
            }
            items = loaded
            images = await loadImages(for: loaded)
        } catch {
            errorMessage = error.localizedDescription
            items = []
            images = [:]
        }
        isLoading = false
    }

    @MainActor
    private func loadImages(for items: [CollageItem]) async -> [String: NSImage] {
        let pairs = await withTaskGroup(of: (String, Data)?.self) { group in
            for item in items {
                guard let raw = item.imageURL, let url = URL(string: raw) else { continue }
                group.addTask {
                    do {
                        let data: Data
                        if url.isFileURL {
                            data = try Data(contentsOf: url)
                        } else {
                            try ConnectivityGate.check(host: url.host)
                            data = try await URLSession.shared.data(from: url).0
                        }
                        return (item.id, data)
                    } catch {
                        return nil
                    }
                }
            }
            var values: [(String, Data)] = []
            for await value in group {
                if let value { values.append(value) }
            }
            return values
        }
        return Dictionary(uniqueKeysWithValues: pairs.compactMap { id, data in
            NSImage(data: data).map { (id, $0) }
        })
    }

    @MainActor
    private func export() {
        isExporting = true
        let dimensions = options.grid.dimensions
        let size: CGSize
        if dimensions.columns == dimensions.rows {
            size = CGSize(width: 3600, height: 3600)
        } else {
            size = CGSize(width: 3600, height: 3600 * CGFloat(dimensions.rows) / CGFloat(dimensions.columns))
        }

        let canvas = CollageCanvas(
            items: items,
            images: images,
            grid: options.grid,
            metric: metric,
            showTitles: options.showTitles,
            showStats: options.showStats,
            showPeriod: options.showPeriod,
            onSelect: nil
        )
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: canvas)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            errorMessage = "The collage could not be rendered."
            isExporting = false
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Scroblytics Collage.png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        isExporting = false
    }

    private func open(_ item: CollageItem) {
        switch entity {
        case .artist:
            navigation.goToArtist(ArtistIdentity(name: item.artist))
        case .album:
            navigation.goToAlbum(AlbumIdentity(artist: item.artist, name: item.name))
        case .track:
            navigation.goToTrack(TrackIdentity(artist: item.artist, name: item.name))
        }
    }
}

private struct CollagePrimaryControls: View {
    @Binding var grid: CollageGrid
    @Binding var source: CollageSource
    @Binding var entityRawValue: String
    @Binding var metricRawValue: String
    @Binding var period: CollagePeriod
    @Binding var rangeID: String
    @Binding var customFrom: Date
    @Binding var customTo: Date
    let rangeOptions: [DateRangeOption]
    let isLoading: Bool
    let onRefresh: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            labeled("Layout") {
                Picker("Layout", selection: $grid) {
                    ForEach(CollageGrid.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            labeled("Source") {
                Picker("Source", selection: $source) {
                    ForEach(CollageSource.allCases) { Text($0.label).tag($0) }
                }
            }
            labeled("Content") {
                Picker("Content", selection: $entityRawValue) {
                    ForEach(TopChartsEntity.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            labeled("Rank by") {
                Picker("Rank by", selection: $metricRawValue) {
                    ForEach(TopChartsMetric.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            if source == .top {
                labeled("Listening period") {
                    Picker("Listening period", selection: $rangeID) {
                        ForEach(rangeOptions) { Text($0.label).tag($0.id) }
                        Divider()
                        Text("Custom…").tag("custom")
                    }
                }
            } else {
                labeled("Release period") {
                    Picker("Release period", selection: $period) {
                        ForEach(CollagePeriod.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
        }

        if source == .top, rangeID == "custom" {
            HStack {
                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                DatePicker("To", selection: $customTo, displayedComponents: .date)
            }
            .fixedSize()
        }

        Button(action: onRefresh) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(isLoading)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(AppTypography.supporting).foregroundStyle(.secondary)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CollageDisplayControls: View {
    @Binding var showTitles: Bool
    @Binding var showStats: Bool
    @Binding var showPeriod: Bool
    let periodAvailable: Bool
    @Binding var zoom: Double
    let canExport: Bool
    let isExporting: Bool
    let onExport: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { controls }
            VStack(alignment: .leading, spacing: 12) { controls }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)) }
    }

    @ViewBuilder
    private var controls: some View {
        Toggle("Titles", isOn: $showTitles)
        Toggle("Stats", isOn: $showStats)
        Toggle("Period labels", isOn: $showPeriod)
            .disabled(!periodAvailable)
        HStack {
            Image(systemName: "minus.magnifyingglass")
            Slider(value: $zoom, in: 0.5...2, step: 0.1)
                .frame(width: 140)
            Image(systemName: "plus.magnifyingglass")
            Button("Fit") { zoom = 1 }
        }
        Spacer(minLength: 0)
        Button(action: onExport) {
            if isExporting {
                ProgressView().controlSize(.small)
            } else {
                Label("Save PNG", systemImage: "square.and.arrow.down")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canExport)
    }
}

private struct CollageCanvas: View {
    let items: [CollageItem]
    let images: [String: NSImage]
    let grid: CollageGrid
    let metric: TopChartsMetric
    let showTitles: Bool
    let showStats: Bool
    let showPeriod: Bool
    let onSelect: ((CollageItem) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let dimensions = grid.dimensions
            let availableTileWidth = proxy.size.width / CGFloat(dimensions.columns)
            let availableTileHeight = proxy.size.height / CGFloat(dimensions.rows)
            let gap = max(1, min(availableTileWidth, availableTileHeight) * 0.02)
            let tileSize = min(
                (proxy.size.width - gap * CGFloat(dimensions.columns - 1)) / CGFloat(dimensions.columns),
                (proxy.size.height - gap * CGFloat(dimensions.rows - 1)) / CGFloat(dimensions.rows)
            )
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(tileSize), spacing: gap), count: dimensions.columns),
                spacing: gap
            ) {
                ForEach(0..<grid.tileCount, id: \.self) { index in
                    Group {
                        if items.indices.contains(index) {
                            tile(items[index], scale: tileSize / 160)
                        } else {
                            Color(white: 0.08)
                        }
                    }
                    .frame(width: tileSize, height: tileSize)
                    .clipped()
                }
            }
            .frame(
                width: tileSize * CGFloat(dimensions.columns) + gap * CGFloat(dimensions.columns - 1),
                height: tileSize * CGFloat(dimensions.rows) + gap * CGFloat(dimensions.rows - 1)
            )
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Music collage with \(items.count) items")
    }

    @ViewBuilder
    private func tile(_ item: CollageItem, scale: CGFloat) -> some View {
        let tile = CollageTile(
            item: item,
            image: images[item.id],
            metric: metric,
            showTitle: showTitles,
            showStat: showStats,
            showPeriod: showPeriod,
            typographyScale: scale
        )
        if let onSelect {
            Button { onSelect(item) } label: { tile }
                .buttonStyle(.plain)
        } else {
            tile
        }
    }
}

private struct CollageTile: View {
    let item: CollageItem
    let image: NSImage?
    let metric: TopChartsMetric
    let showTitle: Bool
    let showStat: Bool
    let showPeriod: Bool
    let typographyScale: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.11)
                    Image(systemName: "music.note")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white.opacity(0.32))
                }
            }

            if showTitle {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.92)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    Text(item.name)
                        .font(.system(size: 14 * typographyScale, weight: .semibold))
                        .lineLimit(2)
                    if item.artist != item.name {
                        Text(item.artist)
                            .font(.system(size: 11 * typographyScale))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                }
                .padding(8 * typographyScale)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack {
                HStack {
                    if showPeriod, let period = item.periodLabel {
                        badge(period)
                    }
                    Spacer()
                    if showStat {
                        badge(statText)
                    }
                }
                Spacer()
            }
            .padding(6 * typographyScale)
        }
        .foregroundStyle(.white)
        .accessibilityLabel("\(item.name), \(item.artist), \(statText)")
    }

    private var statText: String {
        if metric == .scrobbles {
            return "\(item.metricValue.formatted()) plays"
        }
        return Duration.seconds(item.metricValue).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10 * typographyScale, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6 * typographyScale)
            .padding(.vertical, 4 * typographyScale)
            .background(.black.opacity(0.72), in: Capsule())
    }
}
