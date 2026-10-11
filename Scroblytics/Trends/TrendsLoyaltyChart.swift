import SwiftUI
import Charts

/// Each artist / album / track as a dot: how much you played it (across, log scale) against how spread out those plays
/// were (up: different days, weeks or months). The two medians split the map into four kinds of listening.
///
/// Built to be readable rather than complete. Thousands of dots are unreadable, so the whole library is drawn as a
/// density (each cell shaded by how many are in it, and it opens in Query when clicked), and only a handful of
/// notable dots per quadrant are drawn and named on top. Hovering a dot picks it out and fades the rest, and a quadrant
/// can be focused (or opened in Query) from the key below the map. With a comparison on, only the biggest movers show
/// where they were before — a line from the old position to the new — instead of a second cloud.
struct TrendsLoyaltyChart: View {
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let durations: DurationEngine.Snapshot
        let range: DateRange
        let compareRange: DateRange?
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.range == b.range && a.compareRange == b.compareRange && a.version == b.version }
    }

    enum CompareView: String, CaseIterable, Identifiable {
        case movers = "Biggest movers", all = "Everything", off = "Off"
        var id: String { rawValue }
    }

    let inputs: Inputs
    let openQuery: (QuerySpec, String) -> Void
    let openEntity: (LoyaltyItem) -> Void

    @AppStorage("trends.loyalty.entity") private var entityRaw = QueryTarget.track.rawValue
    @AppStorage("trends.loyalty.spread") private var spreadRaw = LoyaltySpread.span.rawValue
    @AppStorage("trends.loyalty.minPlays") private var minPlays = 3
    @AppStorage("trends.loyalty.perQuadrant") private var perQuadrant = 5
    @AppStorage("trends.loyalty.compareView") private var compareViewRaw = CompareView.movers.rawValue
    @AppStorage("trends.loyalty.metric") private var metricRaw = TrendsMetric.plays.rawValue
    @State private var data: TrendsLoyalty?
    @State private var isLoading = true
    @State private var hovered: LoyaltyItem?
    @State private var hoveredCell: Cell?
    /// Which side of the map the pointer is on, so the tooltip sits on the other.
    @State private var pointerOnRight = true
    @State private var focus: LoyaltyQuadrant?

    private var entity: QueryTarget { QueryTarget(rawValue: entityRaw) ?? .track }
    private var spread: LoyaltySpread { LoyaltySpread(rawValue: spreadRaw) ?? .span }
    private var compareView: CompareView { CompareView(rawValue: compareViewRaw) ?? .movers }
    private var metric: TrendsMetric { TrendsMetric(rawValue: metricRaw) ?? .plays }
    private var noun: String { entity.rawValue + "s" }
    private struct ComputeKey: Equatable { let entity: QueryTarget; let spread: LoyaltySpread; let metric: TrendsMetric; let inputs: Inputs }

    private static let quadrantColors: [LoyaltyQuadrant: Color] = [.lifers: .green, .obsessions: .red, .background: .blue, .passing: .purple]
    private func color(_ q: LoyaltyQuadrant) -> Color { Self.quadrantColors[q] ?? .gray }
    private static let moverCount = 6
    private static let labelCount = 5

    // MARK: - What is drawn

    /// One shaded region of the density: a range of plays by a range of spread, and how many items are in it.
    private struct Cell: Identifiable {
        let id: Int
        let x0: Double, x1: Double, y0: Double, y1: Double
        let count: Int
        let quadrant: LoyaltyQuadrant
    }

    /// Everything the chart needs, derived from the data and the controls.
    private struct Derived {
        var population: [LoyaltyItem]
        var previousPopulation: [LoyaltyItem]
        /// The dots drawn: the most-played few in each quadrant, plus the movers.
        var dots: [LoyaltyItem]
        var notables: Set<QueryEntityID>
        var previousByID: [QueryEntityID: LoyaltyItem]
        var movers: [QueryEntityID]
        var xMedian: Double
        var yMedian: Double
        var xDomain: ClosedRange<Double>
        var yDomain: ClosedRange<Double>
        var cells: [Cell]
        var maxCell: Int
        var counts: [LoyaltyQuadrant: Int]
        var tops: [LoyaltyQuadrant: [LoyaltyItem]]

        func quadrant(_ item: LoyaltyItem) -> LoyaltyQuadrant { .of(plays: Double(item.value), spread: Double(item.spread), xMedian: xMedian, yMedian: yMedian) }
    }

    private static let binsX = 30
    private static let binsY = 18

    private func derive(_ data: TrendsLoyalty) -> Derived {
        // minPlays is a noise floor on the raw play count, whichever metric is plotted.
        let population = data.current.filter { $0.plays >= minPlays }
        let previousPopulation = (data.previous ?? []).filter { $0.plays >= minPlays }
        let comparing = data.previous != nil && compareView != .off
        // With a comparison on, the dividing lines come from both periods together, so a dot can be seen to cross one.
        let basis = population + (comparing ? previousPopulation : [])
        let xMedian = TrendsLoyaltyEngine.median(basis.map { Double($0.value) })
        let yMedian = TrendsLoyaltyEngine.median(basis.map { Double($0.spread) })
        let previousByID = Dictionary(uniqueKeysWithValues: previousPopulation.map { ($0.id, $0) })

        var counts: [LoyaltyQuadrant: Int] = [:]
        var tops: [LoyaltyQuadrant: [LoyaltyItem]] = [:]
        for item in population {   // already sorted highest-value first
            let q = LoyaltyQuadrant.of(plays: Double(item.value), spread: Double(item.spread), xMedian: xMedian, yMedian: yMedian)
            counts[q, default: 0] += 1
            if tops[q, default: []].count < perQuadrant { tops[q, default: []].append(item) }
        }
        let notables = Set(tops.values.flatMap { $0 }.map(\.id))

        var movers: [QueryEntityID] = []
        if comparing, compareView == .movers {
            let currentByID = Dictionary(uniqueKeysWithValues: population.map { ($0.id, $0) })
            // Things in both periods that changed most; the things that are new this period are ringed instead.
            let candidates = Set(currentByID.keys).intersection(previousByID.keys)
            movers = candidates
                .map { id in (id, abs((currentByID[id]?.value ?? 0) - (previousByID[id]?.value ?? 0))) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
                .prefix(Self.moverCount).map(\.0)
        }
        let byID = Dictionary(uniqueKeysWithValues: population.map { ($0.id, $0) })
        let dots = population.filter { notables.contains($0.id) } + movers.compactMap { id in notables.contains(id) ? nil : byID[id] }

        let all = population + (comparing ? previousPopulation : [])
        let maxValue = Double(all.map(\.value).max() ?? 1)
        let minValue = Double(all.map(\.value).min() ?? 1)
        let maxSpread = Double(all.map(\.spread).max() ?? 2)
        let xLow = max(1, minValue * 0.9)
        let xDomain = xLow...max((maxValue + 1) * 1.02, xLow * 2)
        let yDomain = 0...max(maxSpread * 1.06, 2)

        // The density: bins that are whole numbers of the axis value (a bar per value while the counts are small,
        // wider further out), so a value never falls between two bins, and even steps up the spread.
        var edges: [Double] = []
        let lowEdge = xLow, highEdge = max(lowEdge + 1, (maxValue + 1).rounded(.up))
        let logLow = log(lowEdge), logStep = (log(highEdge) - logLow) / Double(Self.binsX)
        for i in 0...Self.binsX {
            let e = (i == Self.binsX ? highEdge : exp(logLow + Double(i) * logStep).rounded())
            if edges.isEmpty || e > edges.last! { edges.append(e) }
        }
        let yStep = (yDomain.upperBound - yDomain.lowerBound) / Double(Self.binsY)
        var grid: [Int: Int] = [:]
        for item in population {
            let bx = max(0, (edges.lastIndex { Double(item.value) >= $0 } ?? 0).clamped(to: 0...(edges.count - 2)))
            let by = min(Self.binsY - 1, max(0, Int(Double(item.spread) / yStep)))
            grid[by * edges.count + bx, default: 0] += 1
        }
        let cells = grid.map { key, count -> Cell in
            let bx = key % edges.count, by = key / edges.count
            let x0 = edges[bx], x1 = edges[bx + 1]
            let y0 = Double(by) * yStep, y1 = Double(by + 1) * yStep
            let mid = (x: (x0 + x1 - 1) / 2, y: (y0 + y1) / 2)
            return Cell(id: key, x0: x0, x1: x1, y0: y0, y1: y1, count: count, quadrant: .of(plays: mid.x, spread: mid.y, xMedian: xMedian, yMedian: yMedian))
        }
        return Derived(population: population, previousPopulation: previousPopulation, dots: dots, notables: notables, previousByID: previousByID, movers: movers,
                       xMedian: xMedian, yMedian: yMedian, xDomain: xDomain, yDomain: yDomain, cells: cells, maxCell: grid.values.max() ?? 1, counts: counts, tops: tops)
    }

    /// A small, repeatable nudge per item so dots with identical numbers separate; the same for both periods.
    private func nudge(_ id: QueryEntityID) -> (x: Double, y: Double) {
        var h: UInt64 = 14695981039346656037
        for byte in (id.artist + "\u{0}" + id.name).utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        let a = Double(h % 1000) / 1000, b = Double((h / 1000) % 1000) / 1000
        return (1 + (a - 0.5) * 0.10, (b - 0.5) * 0.6)
    }

    private func position(_ item: LoyaltyItem) -> (x: Double, y: Double) {
        let n = nudge(item.id)
        return (Double(item.value) * n.x, Double(item.spread) + n.y)
    }

    private func size(_ value: Int, max maxValue: Int) -> CGFloat {
        CGFloat(30 + sqrt(Double(min(value, maxValue)) / Double(max(1, maxValue))) * 130)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if let data {
                let d = derive(data)
                if d.population.count < 8 {
                    ContentUnavailableView("Too few \(noun) to map", systemImage: "chart.dots.scatter",
                                           description: Text("Only \(d.population.count) \(noun) have at least \(minPlays) plays in this period. Lower the minimum, or pick a wider period."))
                        .frame(minHeight: 220)
                } else {
                    chart(data, d).frame(height: 420)
                    if metric == .timeListened, data.pending > 0 {
                        Label("\(data.pending.formatted()) \(noun) left out — their track lengths are still being looked up, so this fills in as they arrive.", systemImage: "hourglass")
                            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    }
                    key(data, d)
                    footnote(data, d)
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 320)
            } else {
                ContentUnavailableView("No listening in this period", systemImage: "chart.dots.scatter").frame(minHeight: 220)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(entity: entity, spread: spread, metric: metric, inputs: inputs)) { await recompute() }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                primaryControls
                Spacer()
                comparisonControl
            }
            VStack(alignment: .leading, spacing: 10) {
                AskFlowLayout(spacing: 12) {
                    primaryControls
                }
                comparisonControl
            }
        }
    }

    @ViewBuilder
    private var primaryControls: some View {
            Picker("Kind", selection: Binding(get: { entity }, set: { entityRaw = $0.rawValue })) {
                Text("Artists").tag(QueryTarget.artist)
                Text("Albums").tag(QueryTarget.album)
                Text("Tracks").tag(QueryTarget.track)
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("Metric", selection: $metricRaw) {
                ForEach(TrendsMetric.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .help("What the horizontal axis measures: how many times it was played, or how much time that came to.")
            Picker("Spread", selection: Binding(get: { spread }, set: { spreadRaw = $0.rawValue })) {
                ForEach(LoyaltySpread.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .help("What the vertical axis counts: how many different days, weeks or months it was played in. Weeks suits most periods.")
            Picker("Minimum plays", selection: $minPlays) {
                ForEach([1, 3, 5, 10, 20], id: \.self) { Text("\($0)+ plays").tag($0) }
            }
            .fixedSize()
            .help("Leave out \(noun) played fewer times than this, whichever metric is plotted. It also sets the medians that divide the map.")
            Picker("Named dots", selection: $perQuadrant) {
                ForEach([3, 5, 8], id: \.self) { Text("\($0) per corner").tag($0) }
            }
            .fixedSize()
            .help("How many of the most-played dots to draw and name in each of the four corners. The shading underneath is everything.")
    }

    @ViewBuilder
    private var comparisonControl: some View {
        if data?.previous != nil {
            Picker("Previous period", selection: Binding(get: { compareView }, set: { compareViewRaw = $0.rawValue })) {
                ForEach(CompareView.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            .help("How to show the comparison period: lines from where the biggest movers were before, every dot’s old position, or not at all.")
        }
    }

    // MARK: - Chart

    private func chart(_ data: TrendsLoyalty, _ d: Derived) -> some View {
        let maxValue = d.population.map(\.value).max() ?? 1
        let byID = Dictionary(uniqueKeysWithValues: d.population.map { ($0.id, $0) })
        // The previous position of each thing that is drawn as a mover (or, in "Everything", of every dot drawn).
        let previousDrawn: [LoyaltyItem] = compareView == .all
            ? d.dots.compactMap { d.previousByID[$0.id] }
            : d.movers.compactMap { d.previousByID[$0] }
        let comparing = data.previous != nil && compareView != .off
        let labeled = Set(d.dots.filter { d.notables.contains($0.id) }.prefix(Self.labelCount * 4).map(\.id))
            .filter { id in d.tops.values.contains { $0.first?.id == id } }
        let maxCell = Double(max(1, d.maxCell))

        return Chart {
            ForEach(LoyaltyQuadrant.allCases) { q in quadrantBackground(q, d) }
            ForEach(d.cells) { cell in
                RectangleMark(xStart: .value("x0", cell.x0), xEnd: .value("x1", cell.x1), yStart: .value("y0", cell.y0), yEnd: .value("y1", cell.y1))
                    .foregroundStyle(color(cell.quadrant).opacity(cellOpacity(cell, maxCell: maxCell)))
            }
            RuleMark(x: .value("Median plays", d.xMedian)).foregroundStyle(Color.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("Median spread", d.yMedian)).foregroundStyle(Color.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            if comparing {
                ForEach(previousDrawn) { previous in
                    if let current = byID[previous.id] {
                        let a = position(previous), b = position(current)
                        let tint = color(d.quadrant(current))
                        LineMark(x: .value("Plays", a.x), y: .value("Spread", a.y), series: .value("Pair", "\(previous.id.artist)\u{0}\(previous.id.name)"))
                            .foregroundStyle(tint.opacity(dim(previous.id, base: 0.4)))
                            .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [3, 3]))
                        LineMark(x: .value("Plays", b.x), y: .value("Spread", b.y), series: .value("Pair", "\(previous.id.artist)\u{0}\(previous.id.name)"))
                            .foregroundStyle(tint.opacity(dim(previous.id, base: 0.4)))
                            .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [3, 3]))
                    }
                    let p = position(previous)
                    PointMark(x: .value("Plays", p.x), y: .value("Spread", p.y))
                        .symbol { Circle().strokeBorder(color(d.quadrant(previous)).opacity(dim(previous.id, base: 0.95)), lineWidth: 1.8).frame(width: 10, height: 10) }
                }
            }

            ForEach(d.dots) { item in
                let p = position(item)
                let q = d.quadrant(item)
                PointMark(x: .value("Plays", p.x), y: .value("Spread", p.y))
                    .symbolSize(size(item.value, max: maxValue))
                    .foregroundStyle(color(q).opacity(dim(item.id, base: 0.95, quadrant: q)))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        if labeled.contains(item.id) && hovered == nil { Text(item.title).font(AppTypography.chartAxis.weight(.medium)).lineLimit(1).foregroundStyle(.primary.opacity(0.9)) }
                    }
            }

            if let hovered {
                let p = position(hovered)
                PointMark(x: .value("Plays", p.x), y: .value("Spread", p.y))
                    .symbol { Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 20, height: 20) }
                if let previous = d.previousByID[hovered.id], comparing {
                    let a = position(previous)
                    PointMark(x: .value("Plays", a.x), y: .value("Spread", a.y))
                        .symbol { Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 14, height: 14) }
                }
            }
            if let hoveredCell {
                RectangleMark(xStart: .value("x0", hoveredCell.x0), xEnd: .value("x1", hoveredCell.x1), yStart: .value("y0", hoveredCell.y0), yEnd: .value("y1", hoveredCell.y1))
                    .foregroundStyle(Color.clear)
                    .annotation(position: .overlay) { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.9), lineWidth: 1.5) }
            }
        }
        .chartXScale(domain: d.xDomain, type: .log)
        .chartYScale(domain: d.yDomain)
        .chartXAxis {
            AxisMarks(values: logTicks(d.xDomain)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Double.self) { Text(TrendsWeight.format(Int(v.rounded()), metric: metric)) } }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
        .chartXAxisLabel("\(metric.label) in the period  →", alignment: .trailing)
        .chartYAxisLabel("\(spread.axis)  →", position: .leading, alignment: .top)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hovered = nearest(location, proxy: proxy, geo: geo, items: d.dots)
                            // Put the tooltip on the side away from the hovered dot and where it used to be.
                            var xs = [location.x]
                            if let hovered, let previous = d.previousByID[hovered.id], data.previous != nil {
                                let p = position(previous)
                                if let point = proxy.position(for: (x: p.x, y: p.y)), let plot = proxy.plotFrame { xs.append(point.x + geo[plot].origin.x) }
                            }
                            pointerOnRight = xs.reduce(0, +) / Double(xs.count) > geo.size.width / 2
                            hoveredCell = hovered == nil ? cell(at: location, proxy: proxy, geo: geo, d: d) : nil
                        case .ended: hovered = nil; hoveredCell = nil
                        }
                    }
                    .onTapGesture { location in
                        if let item = nearest(location, proxy: proxy, geo: geo, items: d.dots) { openEntity(item); return }
                        if let cell = cell(at: location, proxy: proxy, geo: geo, d: d) {
                            openQuery(
                                TrendsDrill.loyaltyRegion(target: data.target, spread: data.spread, x: cell.x0..<cell.x1, y: cell.y0..<cell.y1, isLastRow: cell.y1 >= d.yDomain.upperBound - 0.0001, isLastColumn: cell.x1 >= d.xDomain.upperBound - 0.0001, minPlays: minPlays, range: data.range, metric: metric),
                                "\(cell.count.formatted()) \(noun) · \(regionLabel(cell)) · " + TrendsDrill.rangeLabel(from: data.range.from, to: data.range.to)
                            )
                        }
                    }
                if let hovered { tooltip(hovered, data, d).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pointerOnRight ? .topLeading : .topTrailing).allowsHitTesting(false) }
                else if let hoveredCell { cellTooltip(hoveredCell, d).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pointerOnRight ? .topLeading : .topTrailing).allowsHitTesting(false) }
            }
        }
    }

    /// "Nice" 1-2-5 tick values within a log-scaled domain, so a seconds-wide axis reads as sensibly as a plays one.
    private func logTicks(_ domain: ClosedRange<Double>) -> [Double] {
        guard domain.lowerBound > 0 else { return [] }
        var ticks: [Double] = []
        let start = Int(floor(log10(domain.lowerBound))), end = Int(ceil(log10(domain.upperBound)))
        for e in start...end {
            for m in [1.0, 2.0, 5.0] {
                let v = (m * pow(10, Double(e))).rounded()
                if v >= domain.lowerBound * 0.999 && v <= domain.upperBound { ticks.append(v) }
            }
        }
        return ticks
    }

    /// Shading strength: log-scaled so a few crowded cells don't wash out the rest; dimmed outside a focused quadrant.
    private func cellOpacity(_ cell: Cell, maxCell: Double) -> Double {
        let base = 0.10 + 0.42 * log1p(Double(cell.count)) / log1p(maxCell)
        if hovered != nil { return base * 0.35 }
        if let focus { return cell.quadrant == focus ? base : base * 0.25 }
        return base
    }

    private func cell(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, d: Derived) -> Cell? {
        guard let plot = proxy.plotFrame else { return nil }
        let origin = geo[plot].origin
        guard let x: Double = proxy.value(atX: location.x - origin.x), let y: Double = proxy.value(atY: location.y - origin.y) else { return nil }
        return d.cells.first { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 }
    }

    private func regionLabel(_ cell: Cell) -> String {
        let lo = Int(cell.x0), hi = Int(cell.x1) - 1
        let word = metric == .plays ? " plays" : ""
        let x = lo >= hi ? "\(TrendsWeight.format(lo, metric: metric))\(word)" : "\(TrendsWeight.format(lo, metric: metric))–\(TrendsWeight.format(hi, metric: metric))\(word)"
        let ylo = Int(cell.y0.rounded(.up)), yhi = max(ylo, Int(cell.y1.rounded(.up)) - 1)
        return x + ", " + (ylo == yhi ? "\(ylo)" : "\(ylo)–\(yhi)") + " \(spread.unit)s"
    }

    private func cellTooltip(_ cell: Cell, _ d: Derived) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(cell.count.formatted()) \(cell.count == 1 ? String(noun.dropLast()) : noun)").font(AppTypography.metadata.weight(.semibold))
            Text(regionLabel(cell)).font(AppTypography.compactMetadata.monospacedDigit())
            HStack(spacing: 5) { Circle().fill(color(cell.quadrant)).frame(width: 7, height: 7); Text(cell.quadrant.label).font(AppTypography.compactMetadata) }
            Text("Click to list them in Query").font(AppTypography.denseBadge).foregroundStyle(.tertiary)
        }
        .padding(10).frame(maxWidth: 260, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)) }
    }

    /// Opacity for something belonging to `id`: full for the hovered pair, faded for the rest while hovering, faded when
    /// outside a focused quadrant.
    private func dim(_ id: QueryEntityID, base: Double, quadrant: LoyaltyQuadrant? = nil) -> Double {
        if let hovered { return hovered.id == id ? 1 : 0.1 }
        if let focus, let quadrant { return quadrant == focus ? base : 0.1 }
        return base
    }

    @ChartContentBuilder
    private func quadrantBackground(_ q: LoyaltyQuadrant, _ d: Derived) -> some ChartContent {
        let left = q == .background || q == .passing
        let top = q == .lifers || q == .background
        RectangleMark(
            xStart: .value("x0", left ? d.xDomain.lowerBound : d.xMedian), xEnd: .value("x1", left ? d.xMedian : d.xDomain.upperBound),
            yStart: .value("y0", top ? d.yMedian : d.yDomain.lowerBound), yEnd: .value("y1", top ? d.yDomain.upperBound : d.yMedian)
        )
        .foregroundStyle(color(q).opacity(focus == q ? 0.12 : 0.05))
        .annotation(position: .overlay, alignment: left ? (top ? .topLeading : .bottomLeading) : (top ? .topTrailing : .bottomTrailing), spacing: 6) {
            Text("\(q.label) · \((d.counts[q] ?? 0).formatted())")
                .font(AppTypography.chartAxis.weight(.semibold)).foregroundStyle(color(q).opacity(0.95))
        }
    }

    private func nearest(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, items: [LoyaltyItem]) -> LoyaltyItem? {
        guard let plot = proxy.plotFrame else { return nil }
        let origin = geo[plot].origin
        var best: (LoyaltyItem, CGFloat)?
        for item in items {
            let p = position(item)
            guard let point = proxy.position(for: (x: p.x, y: p.y)) else { continue }
            let distance = hypot(point.x + origin.x - location.x, point.y + origin.y - location.y)
            if distance < (best?.1 ?? 14) { best = (item, distance) }
        }
        return best?.0
    }

    private func tooltip(_ item: LoyaltyItem, _ data: TrendsLoyalty, _ d: Derived) -> some View {
        let q = d.quadrant(item)
        let previous = d.previousByID[item.id]
        return VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(AppTypography.metadata.weight(.semibold)).lineLimit(2)
            if let subtitle = item.subtitle { Text(subtitle).font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
            Text(metric == .plays
                 ? "\(item.plays.formatted()) plays · \(item.spread.formatted()) \(spread.unit)\(item.spread == 1 ? "" : "s") played"
                 : "\(TrendsWeight.format(item.value, metric: .timeListened)) · \(item.plays.formatted()) plays · \(item.spread.formatted()) \(spread.unit)\(item.spread == 1 ? "" : "s") played")
                .font(AppTypography.compactMetadata.monospacedDigit())
            HStack(spacing: 5) { Circle().fill(color(q)).frame(width: 7, height: 7); Text(q.label).font(AppTypography.compactMetadata) }
            if data.previous != nil {
                if let previous {
                    let pq = d.quadrant(previous)
                    let delta = item.value - previous.value
                    Text("Before: \(TrendsWeight.format(previous.value, metric: metric))\(metric == .plays ? " plays" : "") (\(delta >= 0 ? "+" : "-")\(TrendsWeight.format(abs(delta), metric: metric)))" + (pq != q ? " · was \(pq.label)" : ""))
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                } else {
                    Text("New this period").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            }
            Text("Click to open").font(AppTypography.denseBadge).foregroundStyle(.tertiary)
        }
        .padding(10).frame(maxWidth: 260, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)) }
    }

    // MARK: - Key and notes

    private func key(_ data: TrendsLoyalty, _ d: Derived) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
            ForEach(LoyaltyQuadrant.allCases) { q in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(color(q)).frame(width: 9, height: 9)
                        Text(q.label).font(AppTypography.metadata.weight(.semibold))
                        Text((d.counts[q] ?? 0).formatted()).font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            openQuery(
                                TrendsDrill.loyaltyQuadrant(target: data.target, spread: data.spread, quadrant: q, xMedian: d.xMedian, yMedian: d.yMedian, minPlays: minPlays, range: data.range, metric: metric),
                                "\(q.label) · \(spread.label.lowercased()) · " + TrendsDrill.rangeLabel(from: data.range.from, to: data.range.to)
                            )
                        } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless)
                        .help("Open all \((d.counts[q] ?? 0).formatted()) \(noun) in \(q.label) in Query")
                    }
                    Text(q.summary).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    Text((d.tops[q] ?? []).map(\.title).joined(separator: " · ")).font(AppTypography.compactMetadata).foregroundStyle(.tertiary).lineLimit(1)
                }
                .padding(10)
                .background(color(q).opacity(focus == q ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay { if focus == q { RoundedRectangle(cornerRadius: 8).stroke(color(q).opacity(0.7)) } }
                .contentShape(Rectangle())
                .onTapGesture { focus = focus == q ? nil : q }
                .help("Click to highlight only \(q.label) on the map")
            }
        }
    }

    private func footnote(_ data: TrendsLoyalty, _ d: Derived) -> some View {
        let xWord = metric == .plays ? " plays" : ""
        let median = "\(TrendsWeight.format(Int(d.xMedian.rounded()), metric: metric))\(xWord) and \(d.yMedian.formatted(.number.precision(.fractionLength(0...1)))) \(spread.unit)s"
        return VStack(alignment: .leading, spacing: 3) {
            Text("The shading is all \(d.population.count.formatted()) \(noun) with \(minPlays)+ plays — darker means more of them; the dots are the \(perQuadrant) most-played in each corner. The dashed lines are the medians (\(median)). \(spread.note)")
            if data.previous != nil, compareView == .movers {
                Text("Hollow circles and dashed lines show where the \(Self.moverCount) biggest movers (in both periods) were before, and the line runs to where they are now. Hover a dot to see whether it is new this period. The medians combine both periods.")
            }
            Text("Hover a dot to pick it out and click it to open it. Click any shaded area to list what’s in it in Query, or a box above to focus a quadrant.")
        }
        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
    }

    private func recompute() async {
        isLoading = true
        let (target, spread, metric, inputs) = (entity, self.spread, self.metric, self.inputs)
        let computed = await Task.detached(priority: .utility) {
            TrendsLoyaltyEngine.compute(scrobbles: inputs.scrobbles, target: target, spread: spread, range: inputs.range, compareRange: inputs.compareRange, metric: metric, durations: inputs.durations)
        }.value
        guard !Task.isCancelled else { return }
        data = computed
        isLoading = false
        hovered = nil
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
