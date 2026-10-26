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
    /// Set when the collage is made from a Query's results (the Query tool's Collage button) instead of the tool's own choices.
    @State private var queryPayload: CollageQueryPayload?
    @State private var accountName: String?
    @State private var avatar: Data?
    /// The caption under the collage (what it shows and when) and the two identity lines. Kept in the app's preferences, not in the
    /// saved tool options, so options saved by earlier versions still load. The two identity switches are the Share popover's.
    @AppStorage("collage.showsDetails") private var showsDetails = false
    @AppStorage(ShareSettings.showsNameKey) private var showsName = false
    @AppStorage(ShareSettings.showsAvatarKey) private var showsAvatar = false
    @AppStorage(ShareSettings.showsFooterKey) private var showsTag = false
    @AppStorage(ShareSettings.logoKey) private var logoRaw = LastfmLogoStyle.circle.rawValue

    private var entity: TopChartsEntity {
        queryPayload?.entity ?? TopChartsEntity(rawValue: options.entityRawValue) ?? .album
    }

    private var metric: TopChartsMetric {
        TopChartsMetric(rawValue: options.metricRawValue) ?? .scrobbles
    }

    /// What the caption under the collage says, from the current choices.
    private var footer: CollageFooter {
        CollageFooter(
            details: showsDetails ? (queryPayload?.caption ?? CollageCaption.make(
                source: options.source, entity: entity, metric: metric, period: options.period, rangeLabel: rangeLabel
            )).text(date: Date()) : nil,
            identity: ShareIdentity(name: showsName ? accountName : nil, showsFooter: showsTag, logo: LastfmLogoStyle(rawValue: logoRaw) ?? .circle, avatar: showsName && showsAvatar ? avatar : nil)
        )
    }

    /// The saved picture straight away, then a refresh from Last.fm if it is missing or about a week old (only while the picture is on).
    private func refreshAvatar() async {
        guard showsName, showsAvatar, let name = accountName else { avatar = nil; return }
        avatar = ShareAvatar.cached(username: name)?.data
        avatar = await ShareAvatar.loadFromLastfm(username: name) ?? avatar
    }

    private var rangeLabel: String {
        if options.rangeID == "custom" { return ShareCards.rangeLabel(selectedRange) }
        return rangeOptions.first { $0.id == options.rangeID }?.label ?? ShareCards.rangeLabel(selectedRange)
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
                        fromQuery: queryPayload.map { FromQuery(title: $0.title, shown: min($0.items.count, options.grid.tileCount), total: $0.totalRows) },
                        onUseTopItems: { queryPayload = nil; Task { await reload() } },
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
                    showsDetails: $showsDetails,
                    showsName: $showsName,
                    showsAvatar: $showsAvatar,
                    showsTag: $showsTag,
                    accountName: accountName,
                    periodAvailable: options.source == .period || (queryPayload?.hasPeriodLabels ?? false),
                    zoom: $zoom,
                    canExport: !items.isEmpty && !isLoading && !isExporting,
                    isExporting: isExporting,
                    onExport: export,
                    onCopy: copyImage,
                    shareImage: ShareCardImage(render: { [items, images, grid = options.grid, metric, titles = options.showTitles, stats = options.showStats, period = options.showPeriod, footer] in
                        Self.renderPNG(items: items, images: images, grid: grid, metric: metric, showTitles: titles, showStats: stats, showPeriod: period, footer: footer)
                    })
                )

                content
            }
            .padding(16)
        }
        .navigationTitle("Collage Generator")
        .task {
            accountName = ShareSettings.accountName(context: modelContext)
            Task { await refreshAvatar() }
            let oldest = try? await TopChartsEngine.fetchOldestScrobbleDate(container: modelContainer)
            rangeOptions = DateRangePresets.build(oldestScrobbleDate: oldest)
            options = ToolFilterSettingsStore.load(
                Options.self,
                toolId: Self.toolID,
                context: modelContext,
                default: Self.defaults
            )
            if let payload = CollageHandoff.shared.take() { useQueryResults(payload) }
            await reload()
            hasLoadedOptions = true
        }
        .onChange(of: CollageHandoff.shared.pending?.id) {
            guard hasLoadedOptions, let payload = CollageHandoff.shared.take() else { return }
            useQueryResults(payload)
            Task { await reload() }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .scrobbleSyncDidComplete) {
                await reload()
            }
        }
        .onChange(of: showsName) { Task { await refreshAvatar() } }
        .onChange(of: showsAvatar) { Task { await refreshAvatar() } }
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
                    let collageHeight = collageWidth * CollageCanvas.heightRatio(grid: options.grid, footer: footer)
                    CollageCanvas(
                        items: items,
                        images: images,
                        grid: options.grid,
                        metric: metric,
                        showTitles: options.showTitles,
                        showStats: options.showStats,
                        showPeriod: options.showPeriod,
                        footer: footer,
                        onSelect: open
                    )
                    .frame(width: collageWidth, height: collageHeight)
                    .position(x: proxy.size.width / 2, y: 12 + collageHeight / 2)
                }
                .aspectRatio(1 / CollageCanvas.heightRatio(grid: options.grid, footer: footer), contentMode: .fit)
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
            if let queryPayload {
                loaded = Array(queryPayload.items.prefix(options.grid.tileCount))
            } else if options.source == .top {
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

    /// Makes the collage from a Query's results, in a grid just big enough for them (change it if you like).
    private func useQueryResults(_ payload: CollageQueryPayload) {
        queryPayload = payload
        options.grid = CollageQuerySource.suggestedGrid(count: payload.items.count)
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

    /// The collage as PNG data at full size (3600 px wide, or tall for the widescreen grid).
    @MainActor
    static func renderPNG(
        items: [CollageItem], images: [String: NSImage], grid: CollageGrid, metric: TopChartsMetric,
        showTitles: Bool, showStats: Bool, showPeriod: Bool, footer: CollageFooter = .none
    ) -> Data? {
        let size = CGSize(width: 3600, height: 3600 * CollageCanvas.heightRatio(grid: grid, footer: footer))

        let canvas = CollageCanvas(
            items: items,
            images: images,
            grid: grid,
            metric: metric,
            showTitles: showTitles,
            showStats: showStats,
            showPeriod: showPeriod,
            footer: footer,
            onSelect: nil
        )
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: canvas)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1

        // Straight from the renderer's bitmap (a round trip through an NSImage's TIFF kept a copy of the picture alive for every export).
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    @MainActor
    private func currentPNG() -> Data? {
        Self.renderPNG(
            items: items, images: images, grid: options.grid, metric: metric,
            showTitles: options.showTitles, showStats: options.showStats, showPeriod: options.showPeriod, footer: footer
        )
    }

    @MainActor
    private func export() {
        isExporting = true
        guard let data = currentPNG() else {
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

    /// Puts the collage on the clipboard, to paste into a post or a message.
    @MainActor
    private func copyImage() {
        isExporting = true
        defer { isExporting = false }
        guard let data = currentPNG() else {
            errorMessage = "The collage could not be rendered."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        if let image = NSImage(data: data) { pasteboard.writeObjects([image]) }
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

/// What the collage tool says about the query a collage was made from.
private struct FromQuery: Equatable {
    var title: String
    var shown: Int
    var total: Int
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
    let fromQuery: FromQuery?
    let onUseTopItems: () -> Void
    let onRefresh: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]

    var body: some View {
        if let fromQuery {
            queryControls(fromQuery)
        } else {
            ownControls
        }
    }

    /// A collage made from a Query's results: only the layout is the tool's to choose; which items, and their order, are the query's.
    @ViewBuilder
    private func queryControls(_ fromQuery: FromQuery) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                labeled("Layout") {
                    Picker("Layout", selection: $grid) {
                        ForEach(CollageGrid.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 150)
                }
                .fixedSize()
                Button(action: onUseTopItems) { Label("Use Top Items Instead", systemImage: "arrow.uturn.backward") }
                    .help("Leave the query’s results and choose a listening period and what to rank by here")
            }
            VStack(alignment: .leading, spacing: 2) {
                Label("From Query: \(fromQuery.title)", systemImage: "magnifyingglass").lineLimit(2)
                Text(fromQuery.total > fromQuery.shown
                     ? "The first \(fromQuery.shown.formatted()) of \(fromQuery.total.formatted()) results, in the order the query put them."
                     : "All \(fromQuery.total.formatted()) results, in the order the query put them.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var ownControls: some View {
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
    @Binding var showsDetails: Bool
    @Binding var showsName: Bool
    @Binding var showsAvatar: Bool
    @Binding var showsTag: Bool
    let accountName: String?
    let periodAvailable: Bool
    @Binding var zoom: Double
    let canExport: Bool
    let isExporting: Bool
    let onExport: () -> Void
    let onCopy: () -> Void
    let shareImage: ShareCardImage

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
        Toggle("What and when", isOn: $showsDetails)
            .help("A caption under the collage: what it shows, the period and today’s date")
        Toggle("My Last.fm name", isOn: $showsName)
            .disabled(accountName == nil)
            .help(accountName.map { "Adds “\($0)” under the collage" } ?? "No Last.fm account is saved")
        Toggle("My picture", isOn: $showsAvatar)
            .disabled(accountName == nil || !showsName)
            .help("Adds your Last.fm profile picture in front of your name (turn on “My Last.fm name” first)")
        Toggle("Scroblytics", isOn: $showsTag)
            .help("Adds “Scroblytics” under the collage")
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
        Button(action: onCopy) {
            Label("Copy Image", systemImage: "doc.on.doc")
        }
        .disabled(!canExport)
        .help("Copy the collage to paste into a post or message")
        ShareLink(item: shareImage, preview: SharePreview("Scroblytics Collage")) {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
        .disabled(!canExport)
    }
}

struct CollageCanvas: View {
    let items: [CollageItem]
    let images: [String: NSImage]
    let grid: CollageGrid
    let metric: TopChartsMetric
    let showTitles: Bool
    let showStats: Bool
    let showPeriod: Bool
    var footer: CollageFooter = .none
    let onSelect: ((CollageItem) -> Void)?

    /// The caption strip's height as a fraction of the collage's width.
    static let footerFraction: CGFloat = 0.07

    /// Height over width of the whole collage: the grid, plus the caption strip when there is one.
    static func heightRatio(grid: CollageGrid, footer: CollageFooter) -> CGFloat {
        let dimensions = grid.dimensions
        return CGFloat(dimensions.rows) / CGFloat(dimensions.columns) + (footer.isEmpty ? 0 : footerFraction)
    }

    var body: some View {
        GeometryReader { proxy in
            let dimensions = grid.dimensions
            let footerHeight = footer.isEmpty ? 0 : proxy.size.width * Self.footerFraction
            let area = CGSize(width: proxy.size.width, height: proxy.size.height - footerHeight)
            let availableTileWidth = area.width / CGFloat(dimensions.columns)
            let availableTileHeight = area.height / CGFloat(dimensions.rows)
            let gap = max(1, min(availableTileWidth, availableTileHeight) * 0.02)
            let tileSize = min(
                (area.width - gap * CGFloat(dimensions.columns - 1)) / CGFloat(dimensions.columns),
                (area.height - gap * CGFloat(dimensions.rows - 1)) / CGFloat(dimensions.rows)
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
            .position(x: area.width / 2, y: area.height / 2)
            if !footer.isEmpty {
                CollageFooterView(footer: footer, width: proxy.size.width)
                    .frame(width: proxy.size.width, height: footerHeight)
                    .position(x: proxy.size.width / 2, y: area.height + footerHeight / 2)
            }
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
                    if showStat, !statText.isEmpty {
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
        if let valueText = item.valueText { return valueText }
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


/// The line under a collage: what it shows and when, and the person's name and the app's name, each only when chosen.
struct CollageFooter: Equatable {
    var details: String?
    var identity: ShareIdentity

    static let none = CollageFooter(details: nil, identity: .anonymous)

    var isEmpty: Bool { details == nil && !ShareCardFooter.isShown(identity) }
}

/// What a collage shows, in words: "Top Albums · Last 365 days · Ranked by scrobbles · Oct 17, 2026".
struct CollageCaption: Equatable {
    var title: String
    var period: String
    var measure: String

    static func make(source: CollageSource, entity: TopChartsEntity, metric: TopChartsMetric, period: CollagePeriod, rangeLabel: String) -> CollageCaption {
        let measure = metric == .scrobbles ? "Ranked by scrobbles" : "Ranked by time listened"
        switch source {
        case .top:
            return CollageCaption(title: "Top \(entity.displayName)", period: rangeLabel, measure: measure)
        case .period:
            return CollageCaption(title: "Top \(entity.displayName)", period: "One favorite per release \(period.rawValue)", measure: measure)
        }
    }

    func text(date: Date) -> String {
        [title, period, measure, date.formatted(date: .abbreviated, time: .omitted)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct CollageFooterView: View {
    let footer: CollageFooter
    /// The collage's width, which everything here scales with (the same strip at 960 pt on screen and 3600 px saved).
    let width: CGFloat

    var body: some View {
        let font = width * 0.022
        HStack(spacing: font) {
            if let details = footer.details {
                Text(details)
                    .font(.system(size: font, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            Spacer(minLength: 0)
            if let name = footer.identity.name, !name.isEmpty {
                HStack(spacing: font * 0.45) {
                    if let avatar = footer.identity.avatar { ShareAvatarView(data: avatar, size: font * 1.6) }
                    LastfmMark(size: font * 1.25, style: footer.identity.logo)
                    Text(name)
                        .font(.system(size: font, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            if footer.identity.showsFooter {
                Text("Scroblytics")
                    .font(.system(size: font, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, font * 1.2)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.06))
        .environment(\.colorScheme, .dark)
    }
}
