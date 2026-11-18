import SwiftUI

/// Trends › Taste & eras › Where your music is from: a world map of where the artists you played in the period are from. Countries are
/// shaded by how much of your listening comes from them and cities are dots sized by their share; a hollow dot stands at the middle of a
/// region or country because its city is not in the map's list. Hover for the details, click a country or dot to open its artists in
/// Query. A dot big enough shows its top artist's picture; hover for the top three artists, each with theirs. Pinch or use the buttons to zoom, drag to move. Everything it draws is bundled with the app and nothing is sent anywhere.
struct TrendsOriginMapChart: View {
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let snapshots: QuerySnapshots
        let range: DateRange
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.range == b.range && a.version == b.version }
    }

    let inputs: Inputs
    let openQuery: (QuerySpec, String) -> Void
    /// A result to show as it is, without working one out (layout snapshots).
    private let preset: OriginMapResult?

    @AppStorage("trends.originMap.metric") private var metricRaw = TrendsMetric.plays.rawValue
    /// 0 = every artist of the period, else only that many of the most played.
    @AppStorage("trends.originMap.top") private var topCount = 0
    @State private var result: OriginMapResult?
    @State private var isLoading = true
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var gestureStartZoom: CGFloat?
    @State private var gestureStartPan: CGSize?
    @State private var gestureStartZoomPan: CGSize?
    @State private var hover: Hover?
    @State private var hoverPoint = CGPoint.zero
    /// Pictures by artist name (square thumbnails), loaded in the background; an artist with none keeps a plain dot.
    @State private var artwork: [String: NSImage] = [:]
    @State private var artworkTried = Set<String>()
    @Environment(\.shareChartCapture) private var shareCapture

    init(inputs: Inputs, openQuery: @escaping (QuerySpec, String) -> Void, preset: OriginMapResult? = nil, presetArtwork: [String: NSImage] = [:]) {
        self.inputs = inputs
        self.openQuery = openQuery
        self.preset = preset
        _result = State(initialValue: preset)
        _artwork = State(initialValue: presetArtwork)
        _artworkTried = State(initialValue: Set(presetArtwork.keys))
    }

    /// A dot at least this big (points, radius) carries its top artist's picture; smaller ones are too small to recognise anyone in.
    private static let artworkMinimumRadius: CGFloat = 8
    /// How many of the biggest places get their top artist's picture loaded up front; the rest load when hovered.
    private static let artworkPreloadPlaces = 80

    private let world = WorldGeometry.bundled
    private var store: ArtistOriginStore { ArtistOriginStore.shared }
    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    private struct ComputeKey: Equatable { let metric: TrendsMetric; let top: Int; let inputs: Inputs }

    enum Hover: Equatable {
        case place(String)
        case country(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { controls; Spacer(); summary }
                VStack(alignment: .leading, spacing: 8) { HStack(spacing: 12) { controls }; summary }
            }
            if let result, result.mapped > 0 {
                map(result)
                lists(result)
                notes(result)
            } else if isLoading, result == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 260)
            } else {
                empty
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(metric: metric, top: topCount, inputs: inputs), priority: .utility) { await recompute() }
    }

    @ViewBuilder
    private var controls: some View {
        Picker("Metric", selection: $metricRaw) {
            ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .fixedSize()
        Picker("Show", selection: $topCount) {
            Text("All artists").tag(0)
            Text("Top 10").tag(10)
            Text("Top 25").tag(25)
            Text("Top 50").tag(50)
            Text("Top 100").tag(100)
        }
        .labelsHidden().fixedSize()
        .help("Map only the artists you played most in the period, or every artist.")
    }

    @ViewBuilder
    private var summary: some View {
        if let result, result.mapped > 0 {
            Text(summaryLine(result)).font(AppTypography.metadata).foregroundStyle(.secondary)
        }
    }

    // MARK: Map

    private func map(_ result: OriginMapResult) -> some View {
        let byCountry = Dictionary(uniqueKeysWithValues: result.countries.map { ($0.code, $0) })
        let steps = Self.shadingSteps(result.countries.map(\.weight))
        return Color.clear
            .aspectRatio(RobinsonProjection.aspect, contentMode: .fit)
            .frame(maxHeight: 560)
            .overlay {
                GeometryReader { geometry in
                    let size = geometry.size
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            draw(&context, size: size, result: result, byCountry: byCountry, steps: steps)
                        }
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                let target = hit(at: point, size: size, result: result)
                                if target != hover, case .place(let id)? = target, let place = result.places.first(where: { $0.id == id }) {
                                    loadArtwork(for: place.top.map(\.name))
                                }
                                hover = target
                                hoverPoint = point
                            case .ended:
                                hover = nil
                            }
                        }
                        .gesture(SpatialTapGesture().onEnded { value in
                            if let target = hit(at: value.location, size: size, result: result) { open(target, result: result) }
                        })
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    let start = gestureStartPan ?? pan
                                    gestureStartPan = start
                                    pan = clamped(CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height), zoom: zoom, size: size)
                                }
                                .onEnded { _ in gestureStartPan = nil }
                        )
                        .simultaneousGesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    // Zoom about the fingers' position, so what is under the cursor stays under it.
                                    let start = gestureStartZoom ?? zoom
                                    let startPan = gestureStartZoomPan ?? pan
                                    gestureStartZoom = start
                                    gestureStartZoomPan = startPan
                                    let anchor = CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
                                    setZoom(start * value.magnification, size: size, about: anchor, from: (start, startPan))
                                }
                                .onEnded { _ in gestureStartZoom = nil; gestureStartZoomPan = nil }
                        )
                        zoomControls(size: size)
                        if let hover, let tip = tooltip(for: hover, result: result, byCountry: byCountry) {
                            tip
                                .fixedSize()
                                .offset(x: min(hoverPoint.x + 14, max(0, size.width - 270)), y: max(0, min(hoverPoint.y + 14, size.height - 190)))
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shareChartArea()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Map of where your music is from")
            .accessibilityValue(result.countries.prefix(5).map { "\($0.name), \($0.artists) artists" }.joined(separator: "; "))
    }

    private func zoomControls(size: CGSize) -> some View {
        HStack(spacing: 2) {
            Button { setZoom(zoom * 1.5, size: size) } label: { Image(systemName: "plus") }
                .help("Zoom in")
            Button { setZoom(zoom / 1.5, size: size) } label: { Image(systemName: "minus") }
                .help("Zoom out")
            Button { zoom = 1; pan = .zero } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Show the whole world")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(.separator.opacity(0.5)) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(8)
    }

    private static let minZoom: CGFloat = 1
    private static let maxZoom: CGFloat = 80

    /// Sets the zoom. With an `anchor` (a point of the frame) the map is moved so the spot under it stays put: `start` is the zoom and
    /// pan the gesture began with. Without one it zooms about the middle.
    private func setZoom(_ value: CGFloat, size: CGSize, about anchor: CGPoint? = nil, from start: (zoom: CGFloat, pan: CGSize)? = nil) {
        let target = min(max(value, Self.minZoom), Self.maxZoom)
        guard let anchor else {
            zoom = target
            pan = clamped(pan, zoom: zoom, size: size)
            return
        }
        let origin = start ?? (zoom, pan)
        zoom = target
        pan = clamped(Self.anchoredPan(anchor: anchor, size: size, from: origin, toZoom: target), zoom: target, size: size)
    }

    /// The pan that keeps the map point under `anchor` where it is when the zoom goes from `start.zoom` to `toZoom` (before limiting the pan).
    /// A point lands at: middle of the frame + pan + zoom × (its place in the unzoomed frame − the middle).
    static func anchoredPan(anchor: CGPoint, size: CGSize, from start: (zoom: CGFloat, pan: CGSize), toZoom: CGFloat) -> CGSize {
        let ratio = toZoom / start.zoom
        return CGSize(
            width: (anchor.x - size.width / 2) * (1 - ratio) + start.pan.width * ratio,
            height: (anchor.y - size.height / 2) * (1 - ratio) + start.pan.height * ratio
        )
    }

    private func clamped(_ pan: CGSize, zoom: CGFloat, size: CGSize) -> CGSize {
        let limitX = size.width * (zoom - 1) / 2 + size.width * 0.1, limitY = size.height * (zoom - 1) / 2 + size.height * 0.1
        return CGSize(width: min(max(pan.width, -limitX), limitX), height: min(max(pan.height, -limitY), limitY))
    }

    /// Screen position of a map point: zoom about the middle of the frame, then move.
    private func transform(size: CGSize) -> CGAffineTransform {
        CGAffineTransform.identity
            .translatedBy(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
            .scaledBy(x: zoom, y: zoom)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }

    /// Dots shrink on a narrow map so the pictures do not pile onto each other, and grow a little as you zoom in, so a small place
    /// gains its picture when you zoom to it.
    private func dotRadius(_ place: OriginMapResult.Place, max: Int, size: CGSize) -> CGFloat {
        let scale = Swift.min(1, Swift.max(0.6, size.width / 1000)) * Self.dotZoomScale(zoom)
        return (3.5 + 17 * CGFloat((Double(place.weight) / Double(Swift.max(max, 1))).squareRoot())) * scale
    }

    /// How much the dots grow with zoom: up to 4× they grow a little (so a small place gains its picture), then they get smaller again, because
    /// the places keep moving apart as you zoom and dots that stayed big would cover their neighbours (the boroughs of one big city).
    static func dotZoomScale(_ zoom: CGFloat) -> CGFloat {
        if zoom <= 4 { return zoom.squareRoot() }
        return Swift.max(0.7, 2 * pow(4 / zoom, 0.4))
    }

    private func screenPoint(_ place: OriginMapResult.Place, size: CGSize) -> CGPoint {
        let projected = RobinsonProjection.project(longitude: place.longitude, latitude: place.latitude)
        return WorldGeometry.point(projected, in: CGRect(origin: .zero, size: size)).applying(transform(size: size))
    }

    private func hit(at point: CGPoint, size: CGSize, result: OriginMapResult) -> Hover? {
        var best: (id: String, distance: CGFloat)?
        for place in result.places {
            let centre = screenPoint(place, size: size)
            let distance = hypot(centre.x - point.x, centre.y - point.y)
            if distance <= dotRadius(place, max: result.maxPlaceWeight, size: size) + 3, distance < (best?.distance ?? .infinity) { best = (place.id, distance) }
        }
        if let best { return .place(best.id) }
        let base = point.applying(transform(size: size).inverted())
        return world.countryAt(WorldGeometry.projected(base, in: CGRect(origin: .zero, size: size))).map { .country($0) }
    }

    private func open(_ target: Hover, result: OriginMapResult) {
        switch target {
        case .place(let id):
            guard let place = result.places.first(where: { $0.id == id }) else { return }
            openQuery(OriginMapDrill.place(place, range: inputs.range), "Artists from \(place.label)")
        case .country(let code):
            let name = CountryNames.name(forCode: code) ?? code
            openQuery(OriginMapDrill.country(name: name, range: inputs.range), "Artists from \(name)")
        }
    }

    /// Quantile steps (up to five) so one huge country does not leave every other one the same pale colour.
    static func shadingSteps(_ weights: [Int]) -> [Int] {
        let sorted = weights.filter { $0 > 0 }.sorted()
        guard sorted.count > 1 else { return sorted }
        return (1..<5).map { sorted[min(sorted.count - 1, sorted.count * $0 / 5)] }
    }

    private func step(of weight: Int, steps: [Int]) -> Int { steps.filter { weight >= $0 }.count }

    private func draw(_ context: inout GraphicsContext, size: CGSize, result: OriginMapResult, byCountry: [String: OriginMapResult.CountryTotal], steps: [Int]) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .color(Color.secondary.opacity(0.07)))
        let t = transform(size: size)
        var hoveredCountry: String?
        if case .country(let code)? = hover { hoveredCountry = code } else if case .place(let id)? = hover { hoveredCountry = result.places.first { $0.id == id }?.countryCode }
        for country in world.countries {
            let path = world.path(for: country, in: rect).applying(t)
            if let total = byCountry[country.iso] {
                let level = step(of: total.weight, steps: steps)
                context.fill(path, with: .color(Color.accentColor.opacity(0.22 + 0.15 * Double(level))))
            } else {
                context.fill(path, with: .color(Color.secondary.opacity(0.16)))
            }
            context.stroke(path, with: .color(Color.primary.opacity(hoveredCountry == country.iso ? 0.7 : 0.2)), lineWidth: hoveredCountry == country.iso ? 1.4 : 0.5)
        }
        let selected: String? = { if case .place(let id)? = hover { id } else { nil } }()
        // Biggest first, so a small place next to a big one is drawn on top of it and stays visible; the hovered one goes last of all.
        let drawOrder = result.places.sorted { ($0.id == selected ? 1 : 0, -$0.weight) < ($1.id == selected ? 1 : 0, -$1.weight) }
        for place in drawOrder {
            let centre = screenPoint(place, size: size)
            let radius = dotRadius(place, max: result.maxPlaceWeight, size: size)
            let circle = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            if radius >= Self.artworkMinimumRadius, let name = place.top.first?.name, let image = artwork[name] {
                // The place's top artist, in a bubble: dashed ring when the place is only the middle of a region or country.
                context.fill(circle, with: .color(Color(nsColor: .windowBackgroundColor)))
                var layer = context
                layer.clip(to: circle)
                layer.opacity = place.isApproximate ? 0.75 : 1
                layer.draw(Image(nsImage: image), in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
                if place.isApproximate {
                    context.stroke(circle, with: .color(Color.orange), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                } else {
                    context.stroke(circle, with: .color(Color.orange), lineWidth: 2)
                }
            } else if place.isApproximate {
                context.fill(circle, with: .color(Color.orange.opacity(0.18)))
                context.stroke(circle, with: .color(Color.orange), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            } else {
                context.fill(circle, with: .color(Color.orange.opacity(0.85)))
                context.stroke(circle, with: .color(.white.opacity(0.9)), lineWidth: 1)
            }
            if place.id == selected { context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius - 3, y: centre.y - radius - 3, width: radius * 2 + 6, height: radius * 2 + 6)), with: .color(.primary), lineWidth: 1.5) }
        }
        // Label the few biggest dots when zoomed far enough that the names fit.
        if zoom >= 2 {
            // Zoomed in a long way, every place on screen is named (up to 40), so close neighbours can be told apart.
            let named = zoom >= 8 ? Array(result.places.filter { rect.insetBy(dx: 30, dy: 10).contains(screenPoint($0, size: size)) }.prefix(60)) : Array(result.places.prefix(12))
            var taken: [CGRect] = []
            for place in named {
                let centre = screenPoint(place, size: size)
                guard rect.insetBy(dx: 30, dy: 10).contains(centre) else { continue }
                let name = place.city ?? place.region ?? place.country
                let at = CGPoint(x: centre.x, y: centre.y - dotRadius(place, max: result.maxPlaceWeight, size: size) - 7)
                // Biggest first; a name that would print over one already placed is left out (hover still names it).
                let box = CGRect(x: at.x - CGFloat(name.count) * 3.6 - 3, y: at.y - 8, width: CGFloat(name.count) * 7.2 + 6, height: 16)
                guard !taken.contains(where: { $0.intersects(box) }) else { continue }
                taken.append(box)
                context.draw(Text(name).font(.caption2).foregroundStyle(.primary), at: at)
            }
        }
    }

    // MARK: Tooltip, lists and notes

    private func tooltip(for hover: Hover, result: OriginMapResult, byCountry: [String: OriginMapResult.CountryTotal]) -> AnyView? {
        switch hover {
        case .place(let id):
            guard let place = result.places.first(where: { $0.id == id }) else { return nil }
            return AnyView(card {
                Text(place.label).font(AppTypography.metadata.weight(.semibold)).lineLimit(2)
                Text("\(TrendsWeight.format(place.weight, metric: result.metric)) · \(place.artists) artist\(place.artists == 1 ? "" : "s")")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                ForEach(place.top, id: \.name) { top in
                    HStack(spacing: 8) {
                        artistPicture(top.name)
                        Text(top.name).font(AppTypography.compactMetadata).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(TrendsWeight.format(top.weight, metric: result.metric)).font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if place.isApproximate {
                    Text(place.level == .region ? "Placed at the middle of the region. Click for everyone from it." : "Placed at the middle of the country.")
                        .font(AppTypography.compactMetadata).foregroundStyle(.orange)
                }
            })
        case .country(let code):
            let name = CountryNames.name(forCode: code) ?? code
            guard let total = byCountry[code] else {
                return AnyView(card { Text(name).font(AppTypography.metadata.weight(.semibold)); Text("Nothing from here in this period").font(AppTypography.compactMetadata).foregroundStyle(.secondary) })
            }
            return AnyView(card {
                Text("\(CountryNames.flag(forCode: code)) \(name)").font(AppTypography.metadata.weight(.semibold))
                Text("\(TrendsWeight.format(total.weight, metric: result.metric)) · \(total.artists) artist\(total.artists == 1 ? "" : "s") · \(percent(total.weight, of: result.total)) of everything")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            })
        }
    }

    /// An artist's picture in the hover card; a plain tile with their initial until it loads (or when they have none).
    @ViewBuilder
    private func artistPicture(_ name: String) -> some View {
        Group {
            if let image = artwork[name] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.2).overlay { Text(String(name.prefix(1))).font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2, content: content)
            .padding(8).frame(minWidth: 170, maxWidth: 260)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)) }
    }

    private func lists(_ result: OriginMapResult) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                placeList(result).frame(maxWidth: .infinity, alignment: .topLeading)
                countryList(result).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 16) {
                placeList(result)
                countryList(result)
            }
        }
    }

    private func placeList(_ result: OriginMapResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top places").font(AppTypography.metadata.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(result.places.prefix(8).enumerated()), id: \.element.id) { index, place in
                Button { open(.place(place.id), result: result) } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                        Image(systemName: place.isApproximate ? "circle.dashed" : "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
                        Text(place.label).font(AppTypography.metadata).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(TrendsWeight.format(place.weight, metric: result.metric)).font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the artists from \(place.label) in Query")
            }
        }
    }

    private func countryList(_ result: OriginMapResult) -> some View {
        let most = max(result.countries.first?.weight ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Top countries").font(AppTypography.metadata.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(result.countries.prefix(8).enumerated()), id: \.element.id) { index, country in
                Button { open(.country(country.code), result: result) } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
                        Text(CountryNames.flag(forCode: country.code)).font(AppTypography.metadata)
                        Text(country.name).font(AppTypography.metadata).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(country.artists) artist\(country.artists == 1 ? "" : "s")").font(AppTypography.compactMetadata).foregroundStyle(.tertiary)
                        Text(percent(country.weight, of: result.total)).font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                    .background(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule().fill(Color.accentColor.opacity(0.12)).frame(width: geometry.size.width * CGFloat(country.weight) / CGFloat(most))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the artists from \(country.name) in Query")
            }
        }
    }

    @ViewBuilder
    private func notes(_ result: OriginMapResult) -> some View {
        if let top = result.topArtists {
            Label("Only your top \(top) artists of the period are on the map, and the percentages are of their listening. A click opens everyone from that place, most played first.", systemImage: "line.3.horizontal.decrease.circle")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        if result.unmapped > 0 {
            let parts = OriginMapResult.NotOnMap.allCases.compactMap { reason -> String? in
                guard let weight = result.notOnMap[reason], weight > 0 else { return nil }
                return "\(percent(weight, of: result.total)) by \(reason.label)"
            }
            Label("\(percent(result.unmapped, of: result.total)) of what you played isn’t on the map: \(parts.joined(separator: ", ")). Missing Data › Artist Origin lists them.", systemImage: "questionmark.circle")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        if result.pendingLength > 0 {
            Label("\(result.pendingLength.formatted()) plays are still waiting for a track length and aren’t counted yet.", systemImage: "hourglass")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        if result.places.contains(where: \.isApproximate) {
            Label("Dashed dots stand at the middle of a region or country, because the artist’s city isn’t in the map’s list of cities.", systemImage: "circle.dashed")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        Text("Click a country or a dot to see its artists. Drag to move, pinch or use the buttons to zoom.")
            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var empty: some View {
        let waiting = store.isWarming || store.remaining > 0
        if let result, result.total == 0 {
            ContentUnavailableView("Nothing played in this period", systemImage: "globe.europe.africa", description: Text("Try a wider date range."))
                .frame(minHeight: 220)
        } else if !store.enabled, store.knownCount == 0 {
            ContentUnavailableView("Looking up artists is off", systemImage: "globe.europe.africa", description: Text("Turn on Settings › Sync › Artist origins and this map fills in."))
                .frame(minHeight: 220)
        } else if waiting {
            ContentUnavailableView("Looking up where your artists are from", systemImage: "globe.europe.africa", description: Text("\(store.remaining.formatted()) artists left, most played first. The map fills in as they arrive."))
                .frame(minHeight: 220)
        } else {
            ContentUnavailableView("No artist here has a known origin yet", systemImage: "globe.europe.africa", description: Text("Missing Data › Artist Origin lists the artists with none."))
                .frame(minHeight: 220)
        }
    }

    private func percent(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        let value = Double(part) / Double(total) * 100
        return value < 1 && part > 0 ? "<1%" : value.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private func summaryLine(_ result: OriginMapResult) -> String {
        let places = result.places.count, countries = result.countries.count
        return "\(places) place\(places == 1 ? "" : "s") in \(countries) countr\(countries == 1 ? "y" : "ies")"
    }

    /// Loads the pictures saved for these artists (or reachable, when online; Offline mode never asks the network). The map draws at once
    /// and the pictures come in as they load; an artist with none is not asked for again.
    private func loadArtwork(for names: [String]) {
        guard preset == nil else { return }
        let wanted = names.filter { artwork[$0] == nil && !artworkTried.contains($0) }
        guard !wanted.isEmpty else { return }
        artworkTried.formUnion(wanted)
        let lookup = inputs.snapshots.images.lookup
        Task {
            var urls: [String: String] = [:]
            for name in wanted {
                let target = ImageTarget(kind: .artist, artist: name, album: nil, track: nil)
                if let url = ImageResolutionEngine.effectiveImageURL(for: target, lookup: lookup) { urls[name] = url }
            }
            let loaded = await ShareArtwork.load(Array(urls.values))
            for (name, url) in urls { if let image = loaded[url] { artwork[name] = ArtistMapArtwork.thumbnail(image) } }
        }
    }

    private func recompute() async {
        guard preset == nil else { return }
        isLoading = true
        let (metric, inputs, top) = (self.metric, self.inputs, self.topCount)
        let computed = await TrendsComputeGate.shared.run {
            OriginMapEngine.compute(
                scrobbles: inputs.scrobbles, origins: inputs.snapshots.origins, durations: inputs.snapshots.durations, range: inputs.range,
                metric: metric, places: PlaceCoordinates.bundled, topArtists: top > 0 ? top : nil
            )
        }
        guard !Task.isCancelled, let computed else { return }
        result = computed
        isLoading = false
        loadArtwork(for: computed.places.prefix(Self.artworkPreloadPlaces).compactMap { $0.top.first?.name })
        shareCapture?.summary = ShareChartSummary(
            headline: "Where my music is from",
            detail: "\(top > 0 ? "Top \(top) artists · " : "")\(computed.places.count) places in \(computed.countries.count) countries · \(metric == .plays ? "by scrobbles" : "by time listened")",
            legend: []
        )
    }
}
