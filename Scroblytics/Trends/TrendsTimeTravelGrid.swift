import SwiftUI

/// The time-travel map: when you listened (across) against the year of the release you played (down), shaded by how
/// much. A horizontal band is a stretch of time spent in one era; a diagonal is following new releases as they came
/// out; a vertical smear is digging through an era's whole catalogue in a short window.
///
/// Drawn compactly: one grid at a time (This period / Previous period, never both stacked), release years grouped into
/// as many rows as fit, and a strip of bars on the right totalling each row — with the other period as a tick — so the
/// two periods can still be compared without a second grid. It draws from the same per-bucket release-year counts as
/// the decade river, which come from the Query engine's "Release year".
struct TrendsTimeTravelGrid: View {
    let data: TrendsDecadeRiver
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.timeTravel.rows") private var rowChoice = 0   // 0 = automatic, else years per row
    @State private var showPrevious = false
    @State private var hovered: (col: Int, row: Int)?
    @State private var pointer: CGPoint = .zero

    private static let levelOpacity: [Double] = [0.10, 0.20, 0.31, 0.43, 0.56, 0.70, 0.84, 0.97]
    private static let axisWidth: CGFloat = 68
    private static let barsWidth: CGFloat = 130
    private static let footerHeight: CGFloat = 22

    private var comparing: Bool { data.comparePoints != nil }
    private var points: [TrendsDecadeRiver.Point] { showPrevious ? (data.comparePoints ?? data.points) : data.points }
    private var otherPoints: [TrendsDecadeRiver.Point]? { comparing ? (showPrevious ? data.points : data.comparePoints) : nil }

    /// The rows: contiguous groups of release years covering every year in either period, oldest first.
    private struct Layout {
        let size: Int
        let bands: [ClosedRange<Int>]
        func band(of year: Int) -> Int? { bands.firstIndex { $0.contains(year) } }
    }

    private func layout() -> Layout? {
        let years = (data.points + (data.comparePoints ?? [])).flatMap { $0.years.keys }
        guard let lo = years.min(), let hi = years.max() else { return nil }
        let span = hi - lo + 1
        let size = rowChoice > 0 ? rowChoice : (span <= 30 ? 1 : span <= 60 ? 2 : span <= 120 ? 5 : 10)
        let start = (lo / size) * size
        let bands = stride(from: start, through: hi, by: size).map { $0...min($0 + size - 1, Int.max) }
        return Layout(size: size, bands: bands)
    }

    var body: some View {
        if let layout = layout() {
            let grid = values(points, layout)
            let other = otherPoints.map { values($0, layout) }
            let thresholds = thresholds(grid + (other ?? []))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if comparing {
                        Picker("Period", selection: $showPrevious) {
                            Text("This period").tag(false)
                            Text("Previous period").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    Picker("Rows", selection: $rowChoice) {
                        Text("Rows: automatic").tag(0)
                        Text("Rows: each year").tag(1)
                        Text("Rows: 5 years").tag(5)
                        Text("Rows: decades").tag(10)
                    }
                    .fixedSize()
                    .help("How many release years share a row. Automatic picks whatever fits.")
                    Spacer()
                    Text(showPrevious ? (data.compareRange.map { TrendsDrill.rangeLabel(from: $0.from, to: $0.to) } ?? "") : TrendsDrill.rangeLabel(from: data.range.from, to: data.range.to))
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
                canvas(layout: layout, grid: grid, other: other, thresholds: thresholds)
                    .onChange(of: points.count) { hovered = nil }
                    .onChange(of: rowChoice) { hovered = nil }
                    .onChange(of: showPrevious) { hovered = nil }
                Text("Across: when you listened, by \(data.bucketing.label). Down: the year of the release, newest at the top. Darker means more plays. The bars total each row\(comparing ? "; the tick marks the \(showPrevious ? "this" : "previous") period" : ""). Click a cell to see what you played.")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Values

    /// `grid[bucket][row]` — plays whose release year falls in the row.
    private func values(_ points: [TrendsDecadeRiver.Point], _ layout: Layout) -> [[Int]] {
        points.map { point in
            var row = Array(repeating: 0, count: layout.bands.count)
            for (year, count) in point.years { if let b = layout.band(of: year) { row[b] += count } }
            return row
        }
    }

    /// Eight bands, each holding about the same number of cells, so the shading shows the shape of the listening even
    /// when a few cells are far busier than the rest (a log scale bunches most cells into the top few bands).
    private func thresholds(_ grids: [[Int]]) -> [Double] {
        let nonzero = grids.flatMap { $0 }.filter { $0 > 0 }.sorted()
        guard let lo = nonzero.first, let hi = nonzero.last else { return Array(repeating: 0, count: 8) }
        if lo == hi { return Array(repeating: Double(hi), count: 8) }
        return (1...8).map { Double(nonzero[min(nonzero.count - 1, nonzero.count * $0 / 8 - ($0 == 8 ? 0 : 1) )]) }
    }

    private func level(_ value: Int, _ thresholds: [Double]) -> Int {
        guard value > 0 else { return 0 }
        return (thresholds.firstIndex { Double(value) <= $0 } ?? 7) + 1
    }

    // MARK: - Drawing

    private func canvas(layout: Layout, grid: [[Int]], other: [[Int]]?, thresholds: [Double]) -> some View {
        let rows = layout.bands.count
        let rowH = min(30, max(8, 300 / CGFloat(rows)))
        let gridH = rowH * CGFloat(rows)
        let totals: [Int] = (0..<rows).map { r in grid.reduce(0) { $0 + $1[r] } }
        let otherTotals: [Int]? = other.map { o in (0..<rows).map { r in o.reduce(0) { $0 + $1[r] } } }
        let barMax = Double(max(1, (totals + (otherTotals ?? [])).max() ?? 1))

        return GeometryReader { geo in
            let plotW = max(50, geo.size.width - Self.axisWidth - Self.barsWidth - 20)
            let n = max(1, points.count)
            let cellW = plotW / CGFloat(n)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    // Row labels and the row totals.
                    let labelEvery = rowH >= 12 ? 1 : (layout.size == 1 ? 5 : 2)
                    for r in 0..<rows {
                        let y = CGFloat(rows - 1 - r) * rowH          // newest at the top
                        let band = layout.bands[r]
                        if (rows - 1 - r) % labelEvery == 0 || rows <= 12 {
                            let label = layout.size == 1 ? "\(band.lowerBound)" : layout.size == 10 ? "\(band.lowerBound)s" : "\(band.lowerBound)–\(String(band.upperBound).suffix(2))"
                            context.draw(Text(label).font(AppTypography.chartAxis).foregroundStyle(.secondary),
                                         at: CGPoint(x: Self.axisWidth - 6, y: y + rowH / 2), anchor: .trailing)
                        }
                        let barX = Self.axisWidth + plotW + 14
                        let w = Self.barsWidth * CGFloat(Double(totals[r]) / barMax)
                        context.fill(Path(roundedRect: CGRect(x: barX, y: y + rowH * 0.15, width: max(totals[r] > 0 ? 2 : 0, w), height: rowH * 0.7), cornerRadius: 2), with: .color(.accentColor.opacity(0.75)))
                        if let otherTotals, otherTotals[r] > 0 {
                            let tx = barX + Self.barsWidth * CGFloat(Double(otherTotals[r]) / barMax)
                            context.fill(Path(CGRect(x: tx - 1, y: y + rowH * 0.05, width: 2, height: rowH * 0.9)), with: .color(.purple))
                        }
                    }
                    // The cells.
                    for c in 0..<n {
                        for r in 0..<rows {
                            let rect = CGRect(x: Self.axisWidth + CGFloat(c) * cellW, y: CGFloat(rows - 1 - r) * rowH, width: max(1, cellW - 1), height: max(1, rowH - 1))
                            let l = level(grid[c][r], thresholds)
                            context.fill(Path(roundedRect: rect, cornerRadius: min(2, rowH / 4)), with: .color(l == 0 ? Color.primary.opacity(0.05) : Color.accentColor.opacity(Self.levelOpacity[l - 1])))
                        }
                    }
                    // A month / week label under every few columns.
                    let every = max(1, Int((70 / cellW).rounded(.up)))
                    for c in stride(from: 0, to: n, by: every) {
                        let text = points[c].start.formatted(data.bucketing == .year ? .dateTime.year() : .dateTime.month(.abbreviated).year(.twoDigits))
                        context.draw(Text(text).font(AppTypography.chartAxis).foregroundStyle(.secondary), at: CGPoint(x: Self.axisWidth + CGFloat(c) * cellW, y: gridH + 11), anchor: .leading)
                    }
                    if let h = hovered {
                        let rect = CGRect(x: Self.axisWidth + CGFloat(h.col) * cellW, y: CGFloat(rows - 1 - h.row) * rowH, width: max(1, cellW - 1), height: max(1, rowH - 1))
                        context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(.primary), lineWidth: 1.5)
                    }
                }
                .frame(width: geo.size.width, height: gridH + Self.footerHeight)

                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: geo.size.width, height: gridH)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let c = Int((p.x - Self.axisWidth) / cellW), r = rows - 1 - Int(p.y / rowH)
                            hovered = (p.x >= Self.axisWidth && c >= 0 && c < n && r >= 0 && r < rows) ? (c, r) : nil
                            pointer = p
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture {
                        guard let h = hovered, let band = layout.bands[safe: h.row], let point = points[safe: h.col] else { return }
                        openQuery(
                            TrendsDrill.releaseYears(target: data.target, years: band, from: point.from, to: point.to, metric: data.metric),
                            "\(band.lowerBound == band.upperBound ? "\(band.lowerBound)" : "\(band.lowerBound)–\(band.upperBound)") releases · " + data.bucketing.name(point.start)
                        )
                    }

                // `hovered` was validated when the pointer moved, but the data can be replaced under a stationary
                // pointer (a background refresh, a range change) — so it is re-checked against THIS render's arrays
                // rather than trusted; indexing with a stale position is a crash, not a wrong tooltip.
                if let h = hovered, let band = layout.bands[safe: h.row], let point = points[safe: h.col],
                   let column = grid[safe: h.col], let value = column[safe: h.row] {
                    let bucketTotal = column.reduce(0, +)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(data.bucketing.name(point.start)).font(AppTypography.metadata.weight(.semibold))
                        Text("Releases from \(band.lowerBound == band.upperBound ? "\(band.lowerBound)" : "\(band.lowerBound)–\(band.upperBound)")").font(AppTypography.compactMetadata)
                        Text("\(TrendsWeight.format(value, metric: data.metric))" + (data.metric == .plays ? " plays" : "") + (bucketTotal > 0 ? " · \((Double(value) / Double(bucketTotal) * 100).formatted(.number.precision(.fractionLength(0))))% of that \(data.bucketing.label)" : ""))
                            .font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                        Text("Click to list them in Query").font(AppTypography.denseBadge).foregroundStyle(.tertiary)
                    }
                    .padding(8).fixedSize()
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)) }
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .offset(x: min(max(0, pointer.x + 12), max(0, geo.size.width - 230)), y: pointer.y > gridH - 70 ? pointer.y - 84 : pointer.y + 14)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: gridH + Self.footerHeight)
    }
}
