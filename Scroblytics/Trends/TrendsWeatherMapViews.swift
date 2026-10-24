import SwiftUI

// MARK: - Where each bubble goes

/// The map's geometry for one size: the rows, the span of temperatures, and where each artist's bubble sits. A bubble is at its artist's
/// own average temperature in its cell along the way across, and in the lane of its kind of weather; bubbles that would sit on top of each
/// other move up or down within their lane, never sideways, so the temperature stays honest.
struct TrendsWeatherMapLayout {
    struct Placed: Identifiable {
        let bubble: TrendsWeatherMapBubble
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        var id: String { bubble.id }
    }

    let rows: [WeatherCondition]
    let lowBin: Int
    let highBin: Int
    let size: CGSize
    let labelWidth: CGFloat
    let axisHeight: CGFloat
    /// How tall each row is against the others: a row with no bubble is shorter, one with many is taller, so the room goes where the bubbles are.
    let laneWeights: [CGFloat]
    let placed: [Placed]

    var plotWidth: CGFloat { max(40, size.width - labelWidth - 6) }
    var plotHeight: CGFloat { max(40, size.height - axisHeight) }
    func laneHeight(_ index: Int) -> CGFloat {
        let total = laneWeights.reduce(0, +)
        return total > 0 && index < laneWeights.count ? plotHeight * laneWeights[index] / total : plotHeight / CGFloat(max(rows.count, 1))
    }
    func laneTop(_ index: Int) -> CGFloat { (0..<index).reduce(0) { $0 + laneHeight($1) } }
    /// The temperatures (°C) the plot spans, from the low edge of its first bin to the high edge of its last.
    var domain: ClosedRange<Double> { TrendsWeatherMapEngine.edges(ofBin: lowBin).low...TrendsWeatherMapEngine.edges(ofBin: highBin).high }

    func x(forCelsius temperature: Double) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        return labelWidth + plotWidth * CGFloat((min(max(temperature, domain.lowerBound), domain.upperBound) - domain.lowerBound) / span)
    }

    func row(of condition: WeatherCondition) -> Int? { rows.firstIndex(of: condition) }

    static func make(bubbles: [TrendsWeatherMapBubble], result: TrendsWeatherMapResult, size: CGSize, labelWidth: CGFloat = 92, axisHeight: CGFloat = 40) -> TrendsWeatherMapLayout {
        let bins = TrendsWeatherMapEngine.bins
        var rows = result.rows
        // A bubble's own kind of weather always gets a row, even a thin one (most played mode can land there).
        for bubble in bubbles where !rows.contains(bubble.placement.condition) { rows.append(bubble.placement.condition) }
        rows.sort { (WeatherCondition.allCases.firstIndex(of: $0) ?? 0) < (WeatherCondition.allCases.firstIndex(of: $1) ?? 0) }
        // The temperatures with any listening in them (and wherever a bubble sits): only the ends nothing was played in are left off, and
        // never fewer than three ranges.
        func binTotal(_ bin: Int) -> Int { rows.reduce(0) { $0 + result.cellTotal($1, bin: bin) } }
        let used = (0..<bins).filter { binTotal($0) > 0 } + bubbles.map(\.placement.bin)
        var low = used.min() ?? 0, high = used.max() ?? bins - 1
        while high - low < 2 {
            if low > 0 { low -= 1 }
            if high - low < 2, high < bins - 1 { high += 1 }
        }
        var perRow = [Int](repeating: 0, count: rows.count)
        for bubble in bubbles { if let index = rows.firstIndex(of: bubble.placement.condition) { perRow[index] += 1 } }
        let busiest = Double(max(perRow.max() ?? 1, 1))
        let weights: [CGFloat] = bubbles.isEmpty ? [CGFloat](repeating: 1, count: rows.count) : perRow.map { $0 == 0 ? 0.5 : CGFloat(0.75 + 0.75 * Double($0) / busiest) }
        var layout = TrendsWeatherMapLayout(rows: rows, lowBin: low, highBin: high, size: size, labelWidth: labelWidth, axisHeight: axisHeight, laneWeights: weights, placed: [])
        guard !bubbles.isEmpty, !rows.isEmpty else { return layout }

        let area = Double(layout.plotWidth * layout.plotHeight)
        let biggest = Double(bubbles.map(\.candidate.plays).max() ?? 1)
        // The most bubbles any one cell holds sets how large they can be, so a crowded cell is still readable.
        let columnWidth = layout.plotWidth * CGFloat(TrendsWeatherMapEngine.binWidth / (layout.domain.upperBound - layout.domain.lowerBound))
        var perCell: [Int: Int] = [:]
        for bubble in bubbles { perCell[(layout.row(of: bubble.placement.condition) ?? 0) * bins + bubble.placement.bin, default: 0] += 1 }
        // How large the biggest bubble can be: against the room per bubble, and against the most crowded cell holding all of its bubbles.
        var cellFit = Double.infinity
        for (cell, count) in perCell {
            let fit = (0.7 * Double(columnWidth * layout.laneHeight(cell / bins)) / (Double.pi * Double(count))).squareRoot()
            cellFit = min(cellFit, fit)
        }
        let maxRadius = max(7, min(CGFloat(max(9, min(36, (area / Double(bubbles.count)).squareRoot() * 0.30))), CGFloat(cellFit)))
        // Sizes differ by plays but never shrink to a speck: the smallest is at least half the largest, so more artists get a recognisable picture.
        let minRadius = max(5, maxRadius * 0.5)
        func radius(_ bubble: TrendsWeatherMapBubble) -> CGFloat {
            let wanted = minRadius + (maxRadius - minRadius) * CGFloat((Double(bubble.candidate.plays) / biggest).squareRoot())
            return min(wanted, layout.laneHeight(layout.row(of: bubble.placement.condition) ?? 0) * 0.46)
        }

        var placed: [Placed] = []
        // Biggest first, so the small ones fit around them. A bubble starts at its own temperature and, if that is taken, settles in a spiral
        // around it, but never out of its own cell: it stays within its range of temperatures and its kind of weather.
        for bubble in bubbles.sorted(by: { ($0.candidate.plays, $1.id) > ($1.candidate.plays, $0.id) }) {
            guard let rowIndex = layout.row(of: bubble.placement.condition) else { continue }
            let r = radius(bubble)
            let edges = TrendsWeatherMapEngine.edges(ofBin: bubble.placement.bin)
            let left = layout.x(forCelsius: edges.low), right = layout.x(forCelsius: edges.high)
            // Kept whole inside its range of temperatures where it can be, so a bubble never straddles the edge of the map or of its cell.
            let inset = min(r * 0.8, (right - left) / 2)
            let (low, high) = (left + inset, right - inset)
            let x0 = min(max(layout.x(forCelsius: bubble.placement.temperature), low), high)
            let y0 = layout.laneTop(rowIndex) + layout.laneHeight(rowIndex) / 2
            let reach = max(0, layout.laneHeight(rowIndex) / 2 - r - 1)
            var best: (x: CGFloat, y: CGFloat, overlap: CGFloat) = (x0, y0, .infinity)
            let step = max(1.5, r / 2.2)
            for i in 0..<500 {
                let angle = Double(i) * 2.399963, distance = step * CGFloat(Double(i).squareRoot())
                let x = x0 + distance * CGFloat(cos(angle)), y = y0 + distance * CGFloat(sin(angle))
                guard x >= low - 0.01, x <= high + 0.01, abs(y - y0) <= reach + 0.01 else { continue }
                var overlap: CGFloat = 0
                for other in placed {
                    let gap = hypot(other.x - x, other.y - y)
                    let allowed = (other.radius + r) * 0.9
                    if gap < allowed { overlap += allowed - gap }
                }
                if overlap < best.overlap { best = (x, y, overlap) }
                if overlap == 0 { break }
            }
            placed.append(Placed(bubble: bubble, x: best.x, y: best.y, radius: r))
        }
        layout = TrendsWeatherMapLayout(rows: rows, lowBin: low, highBin: high, size: size, labelWidth: labelWidth, axisHeight: axisHeight, laneWeights: weights, placed: placed)
        return layout
    }

    /// The names that fit: the biggest bubbles first, each only if its label would not sit on one already chosen.
    func labelled(limit: Int) -> [(placed: Placed, x: CGFloat, y: CGFloat)] {
        var chosen: [(placed: Placed, x: CGFloat, y: CGFloat)] = []
        var taken: [CGRect] = []
        for item in placed.sorted(by: { ($0.radius, $1.id) > ($1.radius, $0.id) }) where chosen.count < limit {
            let width = CGFloat(item.bubble.candidate.artist.count) * 5.6 + 12
            let laneIndex = row(of: item.bubble.placement.condition) ?? 0
            let laneBottom = laneTop(laneIndex) + laneHeight(laneIndex)
            let x = min(max(item.x, labelWidth + width / 2), size.width - width / 2)
            let y = min(item.y + item.radius + 8, laneBottom - 9)
            let rect = CGRect(x: x - width / 2, y: y - 8, width: width, height: 16)
            if taken.contains(where: { $0.intersects(rect) }) { continue }
            taken.append(rect)
            chosen.append((item, x, y))
        }
        return chosen
    }

    /// The bubble under a point, nearest first.
    func bubble(at point: CGPoint) -> Placed? {
        placed.filter { hypot($0.x - point.x, $0.y - point.y) <= $0.radius + 3 }
            .min { hypot($0.x - point.x, $0.y - point.y) - $0.radius < hypot($1.x - point.x, $1.y - point.y) - $1.radius }
    }
}

// MARK: - The chart

/// Artists as bubbles on a map of weather (down) against temperature (across): size is plays, colour is how warm, shading behind them is
/// how much listening happened in that weather and temperature. Hover a bubble for its weather; click it to open those plays in Query.
struct TrendsWeatherMapChart: View {
    let bubbles: [TrendsWeatherMapBubble]
    let result: TrendsWeatherMapResult
    let unit: TemperatureUnit
    let height: CGFloat
    var interactive = true
    /// How many of the biggest bubbles carry their name.
    var labelCount = 12
    var showsDensity = true
    var showsLegend = true
    /// Each artist's picture (by name) and, for a shared card drawn in one frame, the pictures already loaded (by address).
    var artwork: [String: String] = [:]
    var images: [String: NSImage]?
    var showsArtwork = true
    /// The smallest bubble (radius, in this chart's own points) that shows a picture; a card drawn larger than it is laid out lowers this so the
    /// picture is the same size on the card.
    var artworkMinimumRadius = TrendsWeatherMapEngine.artworkMinimumRadius
    var onSelect: (TrendsWeatherMapBubble) -> Void = { _ in }
    @State private var hovered: String?

    private var chartHeight: CGFloat { max(120, height - (showsLegend ? 22 : 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let layout = TrendsWeatherMapLayout.make(bubbles: bubbles, result: result, size: CGSize(width: geometry.size.width, height: chartHeight))
                canvas(layout)
                    .frame(width: geometry.size.width, height: chartHeight)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard interactive else { return }
                        switch phase {
                        case .active(let point): hovered = layout.bubble(at: point)?.id
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { point in
                        guard interactive, let hit = layout.bubble(at: point) else { return }
                        onSelect(hit.bubble)
                    }
            }
            .frame(height: chartHeight)
            if showsLegend { legend }
        }
    }

    private func canvas(_ layout: TrendsWeatherMapLayout) -> some View {
        ZStack(alignment: .topLeading) {
            backdrop(layout)
            axis(layout)
            let scale = ringScale
            ForEach(layout.placed) { item in bubbleView(item, scale: scale) }
            ForEach(layout.labelled(limit: labelCount), id: \.placed.id) { label in
                Text(label.placed.bubble.candidate.artist)
                    .font(AppTypography.denseBadge).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .fixedSize()
                    .position(x: label.x, y: label.y)
                    .allowsHitTesting(false)
            }
            if interactive, let hovered, let item = layout.placed.first(where: { $0.id == hovered }) {
                tooltip(item, layout)
            }
        }
    }

    /// The colour of a bubble's ring (or of the whole dot): how strongly its artist leans there, against the others shown.
    private var ringScale: TrendsWeatherMapRingScale { TrendsWeatherMapRingScale(lifts: bubbles.map(\.placement.lift)) }

    @ViewBuilder
    private func bubbleView(_ item: TrendsWeatherMapLayout.Placed, scale: TrendsWeatherMapRingScale) -> some View {
        let isHovered = hovered == item.id
        let diameter = item.radius * 2
        let ring = scale.color(item.bubble.placement.lift)
        let dot = Circle().fill(ring.opacity(isHovered ? 1 : 0.85))
        Group {
            if showsArtwork, item.radius >= artworkMinimumRadius, let url = artwork[item.bubble.candidate.artist] {
                ZStack {
                    dot
                    picture(url, diameter: diameter - 3.5)
                }
                .overlay { Circle().stroke(ring, lineWidth: 1.75) }
            } else {
                dot.overlay { Circle().stroke(Color.white.opacity(isHovered ? 0.9 : 0.4), lineWidth: isHovered ? 2 : 1) }
            }
        }
        .overlay { if isHovered { Circle().stroke(Color.white, lineWidth: 2).padding(-2) } }
        .frame(width: diameter, height: diameter)
        .position(x: item.x, y: item.y)
    }

    @ViewBuilder
    private func picture(_ url: String, diameter: CGFloat) -> some View {
        Group {
            if let images {
                if let image = images[url] { Image(nsImage: image).resizable().scaledToFill() } else { Color.clear }
            } else {
                ArtworkImage(urlString: url, contentMode: .fill) { Color.clear }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    // MARK: Backdrop

    private func backdrop(_ layout: TrendsWeatherMapLayout) -> some View {
        let biggest = Double(max(1, layout.rows.flatMap { row in (layout.lowBin...layout.highBin).map { result.cellTotal(row, bin: $0) } }.max() ?? 1))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(layout.rows.enumerated()), id: \.element) { index, condition in
                let top = layout.laneTop(index), lane = layout.laneHeight(index)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(index.isMultiple(of: 2) ? 0.045 : 0.02))
                    .frame(width: layout.plotWidth, height: lane - 2)
                    .position(x: layout.labelWidth + layout.plotWidth / 2, y: top + lane / 2)
                HStack(spacing: 5) {
                    Image(systemName: condition.symbolName).font(.system(size: 12, weight: .semibold)).foregroundStyle(WeatherPalette.tint(condition))
                    Text(condition == .thunderstorm ? "Storm" : condition.rawValue).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
                .frame(width: layout.labelWidth - 8, alignment: .trailing)
                .position(x: (layout.labelWidth - 8) / 2, y: top + lane / 2)
                if showsDensity {
                    ForEach(layout.lowBin...layout.highBin, id: \.self) { bin in
                        let total = result.cellTotal(condition, bin: bin)
                        if total > 0 {
                            let edges = TrendsWeatherMapEngine.edges(ofBin: bin)
                            let left = layout.x(forCelsius: edges.low), right = layout.x(forCelsius: edges.high)
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(WeatherPalette.tint(condition).opacity(0.05 + 0.30 * (Double(total) / biggest).squareRoot()))
                                .frame(width: max(2, right - left - 2), height: lane - 6)
                                .position(x: (left + right) / 2, y: top + lane / 2)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func axis(_ layout: TrendsWeatherMapLayout) -> some View {
        let lower = layout.domain.lowerBound, upper = layout.domain.upperBound
        let fahrenheit = unit == .fahrenheit
        // Round numbers in the chosen unit, as many as fit with room between their labels.
        let shownLow = unit.fromCelsius(lower), shownHigh = unit.fromCelsius(upper)
        let steps: [Double] = fahrenheit ? [10, 20, 40] : [5, 10, 20]
        let pointsPerDegree = Double(layout.plotWidth) / max(shownHigh - shownLow, 1)
        let step = steps.first { $0 * pointsPerDegree >= 56 } ?? steps[steps.count - 1]
        let ticks = Array(stride(from: (shownLow / step).rounded(.up) * step, through: shownHigh, by: step))
        let top = layout.plotHeight + 4
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map { WeatherPalette.temperature($0) }, startPoint: .leading, endPoint: .trailing)
                .frame(width: layout.plotWidth, height: 5).clipShape(Capsule())
                .position(x: layout.labelWidth + layout.plotWidth / 2, y: top + 2.5)
            ForEach(ticks, id: \.self) { shown in
                let celsius = fahrenheit ? (shown - 32) * 5 / 9 : shown
                Text(unit.text(shown: shown))
                    .font(AppTypography.denseBadge).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    .position(x: min(layout.x(forCelsius: celsius), layout.size.width - 16), y: top + 17)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Hover

    private func tooltip(_ item: TrendsWeatherMapLayout.Placed, _ layout: TrendsWeatherMapLayout) -> some View {
        let width: CGFloat = 240
        let left = item.x + item.radius + 12 + width > layout.size.width ? item.x - item.radius - 12 - width : item.x + item.radius + 12
        let estimated: CGFloat = 52 + CGFloat(layout.rows.count) * 15 + 34 + (showsArtwork && artwork[item.bubble.candidate.artist] != nil ? 30 : 0)
        let top = min(max(item.y - estimated / 2, 2), max(2, layout.size.height - estimated - 2))
        return TrendsWeatherMapTooltip(bubble: item.bubble, result: result, rows: layout.rows, unit: unit, artworkURL: showsArtwork ? artwork[item.bubble.candidate.artist] : nil)
            .frame(width: width, alignment: .leading)
            .offset(x: max(2, left), y: top)
            .allowsHitTesting(false)
    }

    private var legend: some View {
        let scale = ringScale
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems(long: true, scale: scale); Spacer(minLength: 0) }
            HStack(spacing: 12) { legendItems(long: false, scale: scale); Spacer(minLength: 0) }
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private func legendItems(long: Bool, scale: TrendsWeatherMapRingScale) -> some View {
        Label("size is plays", systemImage: "circle").font(AppTypography.denseBadge).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        if showsDensity { Label(long ? "shading is how much you listened" : "shading is listening", systemImage: "square.fill").font(AppTypography.denseBadge).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
        HStack(spacing: 5) {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            Text(long ? "ring is the lean:" : "lean:").foregroundStyle(.secondary)
            if scale.high / max(scale.low, 1e-9) >= 1.1 {
                Text(TrendsWeatherMapEngine.timesText(scale.low)).foregroundStyle(.secondary).monospacedDigit()
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map { scale.color(atPosition: $0) }, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 56, height: 6).clipShape(Capsule())
                Text(TrendsWeatherMapEngine.timesText(scale.high) + "+").foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text(TrendsWeatherMapEngine.timesText(scale.low)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(AppTypography.denseBadge).lineLimit(1).fixedSize()
    }
}

// MARK: - The hover card

/// One artist's weather: where it leans, and its plays across the kinds of weather against what everything you play looks like.
struct TrendsWeatherMapTooltip: View {
    let bubble: TrendsWeatherMapBubble
    let result: TrendsWeatherMapResult
    let rows: [WeatherCondition]
    let unit: TemperatureUnit
    var artworkURL: String?

    private var candidate: TrendsWeatherMapCandidate { bubble.candidate }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if let artworkURL {
                    ArtworkImage(urlString: artworkURL, contentMode: .fill) { Color.secondary.opacity(0.2) }
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.artist).font(AppTypography.metadata.weight(.semibold)).lineLimit(2)
                    Text(TrendsWeatherMapEngine.sentence(bubble.placement, unit: unit)).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 3) {
                ForEach(rows, id: \.self) { condition in
                    let index = WeatherCondition.allCases.firstIndex(of: condition) ?? 0
                    let share = candidate.plays > 0 ? Double(candidate.conditionPlays[index]) / Double(candidate.plays) : 0
                    let usual = index < result.baseline.count ? result.baseline[index] : 0
                    HStack(spacing: 6) {
                        Text(condition == .thunderstorm ? "Storm" : condition.rawValue).font(AppTypography.denseBadge).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.18))
                                Capsule().fill(WeatherPalette.tint(condition)).frame(width: max(2, proxy.size.width * min(1, share)))
                                Rectangle().fill(Color.primary.opacity(0.75)).frame(width: 1.5, height: 9).offset(x: proxy.size.width * min(1, usual) - 0.75)
                            }
                        }
                        .frame(height: 6)
                        Text("\(Int((share * 100).rounded()))%").font(AppTypography.denseBadge.monospacedDigit()).frame(width: 30, alignment: .trailing)
                    }
                }
            }
            Text("\(candidate.plays.formatted()) plays · average \(unit.text(celsius: candidate.averageTemperature)) · mostly \(TrendsWeatherMapEngine.rangeText(bin: candidate.binPlays.enumerated().max { $0.element < $1.element }?.offset ?? 0, unit: unit))")
                .font(AppTypography.denseBadge).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Text("Ticks mark how all your plays are spread").font(AppTypography.denseBadge).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.18), lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}

// MARK: - The card

/// Trends › Weather & places › Artist weather map.
struct TrendsWeatherMapCard: View {
    let inputs: TrendsWeatherGroup.Inputs
    let unit: TemperatureUnit
    let adjust: Bool
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.weather.map.mode") private var modeRaw = TrendsWeatherMapMode.affinity.rawValue
    @AppStorage("trends.weather.map.count") private var count = 10
    @State private var result: TrendsWeatherMapResult?

    private var mode: TrendsWeatherMapMode { TrendsWeatherMapMode(rawValue: modeRaw) ?? .affinity }
    private struct ComputeKey: Equatable { let adjust: Bool; let inputs: TrendsWeatherGroup.Inputs }
    private struct ShareKey: Equatable { let result: TrendsWeatherMapResult?; let mode: TrendsWeatherMapMode; let count: Int; let unit: TemperatureUnit; let version: Int }

    private var bubbles: [TrendsWeatherMapBubble] { result?.bubbles(mode: mode, count: count) ?? [] }

    private func artwork(for shown: [TrendsWeatherMapBubble]) -> [String: String] {
        var out: [String: String] = [:]
        for bubble in shown { if let url = TrendsWeatherMapEngine.artworkURL(for: bubble.candidate.artist, lookup: inputs.imageLookup) { out[bubble.candidate.artist] = url } }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            if let result {
                let shown = bubbles
                if shown.isEmpty {
                    Text(emptyText(result)).font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                } else {
                    TrendsWeatherMapChart(bubbles: shown, result: result, unit: unit, height: 480, labelCount: count <= 10 ? 10 : (count <= 25 ? 14 : (count <= 50 ? 9 : 6)), artwork: artwork(for: shown)) { bubble in
                        openQuery(TrendsWeatherMapEngine.drillSpec(for: bubble, range: inputs.range), "Scrobbles · \(bubble.candidate.artist) · \(TrendsWeatherMapEngine.phrase(bubble.placement.condition)) at \(TrendsWeatherMapEngine.rangeText(bin: bubble.placement.bin, unit: unit)) · " + TrendsDrill.rangeLabel(from: inputs.range.from, to: inputs.range.to))
                    }
                    .shareChartArea()
                    .shareSummary(summary(shown))
                    .shareNative(id: ShareKey(result: result, mode: mode, count: count, unit: unit, version: inputs.version)) {
                        TrendsShareCharts.weatherMap(result: result, mode: mode, count: count, unit: unit, imageLookup: inputs.imageLookup)
                    }
                    footnote(result, shown: shown)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: ComputeKey(adjust: adjust, inputs: inputs), priority: .utility) { await recompute() }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { controlItems }
            VStack(alignment: .leading, spacing: 8) { controlItems }
        }
    }

    @ViewBuilder
    private var controlItems: some View {
        Picker("Place by", selection: $modeRaw) {
            ForEach(TrendsWeatherMapMode.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("Weather affinity places the artists that lean furthest into one kind of weather and temperature, each where it leans. Most played places the artists you play most, each where it is played most.")
        Picker("Show", selection: $count) {
            Text("Top 10").tag(10)
            Text("Top 25").tag(25)
            Text("Top 50").tag(50)
            Text("Top 100").tag(100)
        }
        .labelsHidden().fixedSize()
        Spacer(minLength: 0)
    }

    private func summary(_ shown: [TrendsWeatherMapBubble]) -> ShareChartSummary? {
        guard let first = shown.first else { return nil }
        return ShareChartSummary(headline: first.candidate.artist, change: nil, detail: TrendsWeatherMapEngine.sentence(first.placement, unit: unit))
    }

    private func footnote(_ result: TrendsWeatherMapResult, shown: [TrendsWeatherMapBubble]) -> some View {
        var text = mode == .affinity
            ? "Each artist sits where its plays lean furthest against what is usual" + (result.adjusted ? " for the same month" : "") + ". It needs \(TrendsWeatherMapEngine.minimumPlays)+ plays with weather and \(TrendsWeatherMapEngine.minimumInCell)+ of them there on \(TrendsWeatherMapEngine.minimumDays)+ different days, \(Int(((TrendsWeatherMapEngine.minimumLift - 1) * 100).rounded()))% or more above usual and more than luck would give. Cells nobody leans into stay empty."
            : "Each artist sits where it is played most."
        text += " Across is the artist’s average temperature there; trips count with the weather where you were."
        if !result.leftOut.isEmpty { text += " Left off for having under \(TrendsWeatherMapEngine.minimumRowPlays) plays: " + result.leftOut.map { $0.rawValue.lowercased() }.joined(separator: ", ") + "." }
        if shown.count < count { text += " \(shown.count) artist\(shown.count == 1 ? "" : "s") qualified." }
        return Text(text).font(AppTypography.compactMetadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func emptyText(_ result: TrendsWeatherMapResult) -> String {
        if result.totalPlays == 0 { return "No plays in this period have both a kind of weather and a temperature." }
        if result.candidates.isEmpty { return "No artist has \(TrendsWeatherMapEngine.minimumPlays) plays with weather in this period yet. Pick a longer period." }
        return "No artist clearly leans into one kind of weather and temperature in this period. Try Most played, or a longer period."
    }

    private func recompute() async {
        result = nil
        let (adjust, inputs) = (self.adjust, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            TrendsWeatherMapEngine.compute(scrobbles: inputs.canonical, weather: inputs.weather, range: inputs.range, adjust: adjust)
        }
        guard !Task.isCancelled, let computed else { return }
        result = computed
    }
}
