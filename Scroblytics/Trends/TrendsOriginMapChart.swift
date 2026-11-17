import SwiftUI

/// Trends › Taste & eras › Where your music is from: a world map of where the artists you played in the period are from. Countries are
/// shaded by how much of your listening comes from them and cities are dots sized by their share; a hollow dot stands at the middle of a
/// region or country because its city is not in the map's list. Hover for the details, click a country or dot to open its artists in
/// Query. Pinch or use the buttons to zoom, drag to move. Everything it draws is bundled with the app and nothing is sent anywhere.
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
    @State private var result: OriginMapResult?
    @State private var isLoading = true
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var gestureStartZoom: CGFloat?
    @State private var gestureStartPan: CGSize?
    @State private var hover: Hover?
    @State private var hoverPoint = CGPoint.zero
    @Environment(\.shareChartCapture) private var shareCapture

    init(inputs: Inputs, openQuery: @escaping (QuerySpec, String) -> Void, preset: OriginMapResult? = nil) {
        self.inputs = inputs
        self.openQuery = openQuery
        self.preset = preset
        _result = State(initialValue: preset)
    }

    private let world = WorldGeometry.bundled
    private var store: ArtistOriginStore { ArtistOriginStore.shared }
    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    private struct ComputeKey: Equatable { let metric: TrendsMetric; let inputs: Inputs }

    enum Hover: Equatable {
        case place(String)
        case country(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("Metric", selection: $metricRaw) {
                    ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .fixedSize()
                Spacer()
                if let result, result.mapped > 0 {
                    Text(summaryLine(result)).font(AppTypography.metadata).foregroundStyle(.secondary)
                }
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
        .task(id: ComputeKey(metric: metric, inputs: inputs), priority: .utility) { await recompute() }
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
                                hover = hit(at: point, size: size, result: result)
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
                                    let start = gestureStartZoom ?? zoom
                                    gestureStartZoom = start
                                    setZoom(start * value.magnification, size: size)
                                }
                                .onEnded { _ in gestureStartZoom = nil }
                        )
                        zoomControls(size: size)
                        if let hover, let tip = tooltip(for: hover, result: result, byCountry: byCountry) {
                            tip
                                .fixedSize()
                                .offset(x: min(hoverPoint.x + 14, max(0, size.width - 230)), y: max(0, min(hoverPoint.y + 14, size.height - 120)))
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
    private static let maxZoom: CGFloat = 12

    private func setZoom(_ value: CGFloat, size: CGSize) {
        zoom = min(max(value, Self.minZoom), Self.maxZoom)
        pan = clamped(pan, zoom: zoom, size: size)
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

    private func dotRadius(_ place: OriginMapResult.Place, max: Int) -> CGFloat {
        3.5 + 13 * CGFloat((Double(place.weight) / Double(Swift.max(max, 1))).squareRoot())
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
            if distance <= dotRadius(place, max: result.maxPlaceWeight) + 3, distance < (best?.distance ?? .infinity) { best = (place.id, distance) }
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
        for place in result.places.reversed() {
            let centre = screenPoint(place, size: size)
            let radius = dotRadius(place, max: result.maxPlaceWeight)
            let circle = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            if place.isApproximate {
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
            for place in result.places.prefix(12) {
                let centre = screenPoint(place, size: size)
                guard rect.insetBy(dx: 30, dy: 10).contains(centre) else { continue }
                let name = place.city ?? place.region ?? place.country
                context.draw(Text(name).font(.caption2).foregroundStyle(.primary), at: CGPoint(x: centre.x, y: centre.y - dotRadius(place, max: result.maxPlaceWeight) - 7))
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
                    HStack(spacing: 6) {
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

    private func recompute() async {
        guard preset == nil else { return }
        isLoading = true
        let (metric, inputs) = (self.metric, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            OriginMapEngine.compute(
                scrobbles: inputs.scrobbles, origins: inputs.snapshots.origins, durations: inputs.snapshots.durations, range: inputs.range,
                metric: metric, places: PlaceCoordinates.bundled
            )
        }
        guard !Task.isCancelled, let computed else { return }
        result = computed
        isLoading = false
        shareCapture?.summary = ShareChartSummary(
            headline: "Where my music is from",
            detail: "\(computed.places.count) places in \(computed.countries.count) countries · \(metric == .plays ? "by scrobbles" : "by time listened")",
            legend: []
        )
    }
}
