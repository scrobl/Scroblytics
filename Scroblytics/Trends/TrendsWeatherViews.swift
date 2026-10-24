import Charts
import SwiftUI

// MARK: - What the three weather views draw

/// One kind of weather: how much was played per day of it, against how much on an average day.
struct TrendsWeatherTile: Identifiable, Equatable {
    let condition: WeatherCondition
    /// Scrobbles (or time) per day of this weather.
    let perDay: Double
    /// The same across every hour with weather: the dashed line the tiles compare with.
    let average: Double
    /// How many plays were made in this weather (always a count, even when the chart adds up time listened).
    let playCount: Int
    /// What the chart adds up for them: the plays, or their seconds.
    let weight: Int
    let hours: Int

    var id: WeatherCondition { condition }
    var lift: Double? { average > 0 && hours > 0 ? perDay / average : nil }
    /// Too few plays to say anything: drawn faded, with the count.
    var isThin: Bool { playCount < TrendsWeatherTile.thinBelow }
    static let thinBelow = 30
}

/// How much more or less than usual was played at each temperature and time of day. Columns are tenths of the place's own hours from
/// coldest to warmest; rows are parts of the day.
struct TrendsWeatherGrid: Equatable {
    struct Cell: Equatable {
        let lift: Double?
        let plays: Int
    }

    static let dayparts = ["Morning", "Afternoon", "Evening", "Night"]
    /// Eleven °C edges for ten columns (the coldest hour, nine decile cut-offs, the warmest hour).
    let edges: [Double]
    /// Rows by columns.
    let cells: [[Cell]]
}

/// One week of listening against that week's weather.
struct TrendsWeatherWeek: Identifiable, Equatable {
    enum Precipitation { case none, rain, snow }
    let start: Date
    /// Average temperature, °C.
    let temperature: Double
    /// What the chart adds up for the bucket (plays, or seconds of listening).
    let plays: Int
    let precipitation: Precipitation
    /// How many days the bucket covers: 7 for a week, 1 for a day.
    var days = 7
    var id: Date { start }
}

/// The colours the weather views share.
enum WeatherPalette {
    static func tint(_ condition: WeatherCondition) -> Color {
        switch condition {
        case .clear: Color(red: 0.96, green: 0.70, blue: 0.20)
        case .cloudy: Color(red: 0.55, green: 0.64, blue: 0.76)
        case .fog: Color(red: 0.62, green: 0.66, blue: 0.70)
        case .rain: Color(red: 0.25, green: 0.58, blue: 0.95)
        case .snow: Color(red: 0.55, green: 0.85, blue: 0.95)
        case .thunderstorm: Color(red: 0.62, green: 0.42, blue: 0.92)
        }
    }

    private static let stops: [(Double, (Double, Double, Double))] = [
        (0.00, (0.16, 0.29, 0.62)), (0.28, (0.27, 0.62, 0.78)), (0.50, (0.91, 0.89, 0.78)), (0.75, (0.94, 0.63, 0.29)), (1.00, (0.84, 0.27, 0.24)),
    ]

    /// Blue for the coldest, through pale, to red for the warmest (`position` 0…1).
    static func temperature(_ position: Double) -> Color {
        let p = max(0, min(1, position))
        for index in 1..<stops.count where p <= stops[index].0 {
            let (a, b) = (stops[index - 1], stops[index])
            let f = (p - a.0) / (b.0 - a.0)
            return Color(red: a.1.0 + (b.1.0 - a.1.0) * f, green: a.1.1 + (b.1.1 - a.1.1) * f, blue: a.1.2 + (b.1.2 - a.1.2) * f)
        }
        return Color(red: stops[4].1.0, green: stops[4].1.1, blue: stops[4].1.2)
    }

    /// Less than usual is blue, more than usual is orange, usual is quiet; the further from 1 the stronger.
    static func lift(_ lift: Double?) -> Color {
        guard let lift else { return Color.secondary.opacity(0.10) }
        let strength = min(1, abs(lift - 1) / 0.6)
        return lift >= 1 ? Color(red: 0.96, green: 0.58, blue: 0.20).opacity(0.12 + 0.78 * strength) : Color(red: 0.25, green: 0.52, blue: 0.95).opacity(0.12 + 0.78 * strength)
    }

    /// How strongly something leans, as a solid colour: grey for usual, through orange for more than usual, or blue for less. The square
    /// root lets a modest lean show (1.25× already has colour) while a strong one (3×) is full strength.
    static func leanStrength(_ lift: Double) -> Double {
        lift >= 1 ? min(1, ((lift - 1) / 2).squareRoot()) : min(1, ((1 - lift) / 0.7).squareRoot())
    }

    static func lean(_ lift: Double) -> Color {
        let t = leanStrength(lift)
        let from = (0.66, 0.69, 0.74)
        let to = lift >= 1 ? (0.96, 0.50, 0.12) : (0.22, 0.50, 0.95)
        return Color(red: from.0 + (to.0 - from.0) * t, green: from.1 + (to.1 - from.1) * t, blue: from.2 + (to.2 - from.2) * t)
    }

    static func percent(_ lift: Double) -> String {
        let change = (lift - 1) * 100
        if abs(change) < 0.5 { return "±0%" }
        return (change >= 0 ? "+" : "−") + String(format: "%.0f%%", abs(change))
    }
}

// MARK: - Weather tiles

/// One tile per kind of weather: its symbol, how much more or less than usual you listen in it, and the numbers behind that. Clicking
/// a tile opens Query on the plays made in that weather.
struct TrendsWeatherTiles: View {
    let tiles: [TrendsWeatherTile]
    /// Each weather's lift in the comparison period, when one is chosen.
    var previousLifts: [WeatherCondition: Double] = [:]
    var metric = TrendsMetric.plays
    var onSelect: (WeatherCondition) -> Void = { _ in }
    /// False in a shared card that leaves the plays-and-hours line off.
    var showsDetail = true

    private var maximum: Double { max(tiles.map(\.perDay).max() ?? 1, tiles.first?.average ?? 1, 0.0001) }

    private func amount(_ perDay: Double) -> String {
        metric == .plays ? perDay.formatted(.number.precision(.fractionLength(0))) : TrendsDuration.formatCompact(Int(perDay.rounded()))
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 230), spacing: 12)], spacing: 12) {
            ForEach(tiles) { tile in
                Button { onSelect(tile.condition) } label: { tileView(tile) }
                    .buttonStyle(.plain)
                    .disabled(tile.playCount == 0)
                    .help(tile.playCount == 0 ? "No plays in this weather" : "Open the plays made in \(tile.condition.rawValue.lowercased()) in Query")
            }
        }
    }

    private func tileView(_ tile: TrendsWeatherTile) -> some View {
        let tint = WeatherPalette.tint(tile.condition)
        let thin = tile.isThin || tile.hours == 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: tile.condition.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.18), in: Circle())
                Text(tile.condition == .thunderstorm ? "Storm" : tile.condition.rawValue).font(AppTypography.compactTitle).lineLimit(1)
                Spacer(minLength: 0)
            }
            if let lift = tile.lift, !thin {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    let even = abs(lift - 1) < 0.005
                    Image(systemName: even ? "arrow.right" : (lift >= 1 ? "arrow.up.right" : "arrow.down.right"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(even ? Color.secondary : (lift >= 1 ? Color.green : Color.orange))
                    Text(WeatherPalette.percent(lift))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            } else {
                Text(tile.hours == 0 ? "None in this period" : "Not enough plays")
                    .font(AppTypography.compactTitle).foregroundStyle(.secondary)
                    .frame(maxHeight: 36, alignment: .leading)
            }
            // How much per day, against the average day: the fill is this weather, the tick is the average.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(tint).frame(width: max(4, proxy.size.width * tile.perDay / maximum))
                    Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 2, height: 10)
                        .offset(x: proxy.size.width * tile.average / maximum - 1)
                }
            }
            .frame(height: 8)
            Text("\(amount(tile.perDay)) a day · average \(amount(tile.average))")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            if showsDetail {
                Text(detail(tile))
                    .font(AppTypography.supportingDense).foregroundStyle(.tertiary).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(thin ? 0.12 : 0.30), lineWidth: 1) }
        .opacity(thin ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "4,210 scrobbles · 3,480 h", plus the earlier period's number when comparing.
    private func detail(_ tile: TrendsWeatherTile) -> String {
        let base = (metric == .plays ? "\(tile.playCount.formatted()) scrobbles" : TrendsDuration.formatCompact(tile.weight)) + " · \(tile.hours.formatted()) h"
        guard let previous = previousLifts[tile.condition] else { return base }
        return "before " + WeatherPalette.percent(previous) + " · " + base
    }
}

// MARK: - Temperature and time of day

/// A grid of rounded cells: how warm it was across, the time of day down, and how much more or less than usual you played in each.
/// Clicking a cell opens Query on exactly the plays made then.
struct TrendsWeatherGridView: View {
    let grid: TrendsWeatherGrid
    let unit: TemperatureUnit
    var onSelect: (_ row: Int, _ column: Int) -> Void = { _, _ in }
    /// False in a shared card: no hover hint, and the cells' own height and values are set by the card.
    var interactive = true
    var cellHeight: CGFloat = 40
    var showsValues = true
    var showsLegend = true
    @State private var hovered: HoverCell?

    struct HoverCell: Equatable { let row: Int; let column: Int }
    static let minimumPlays = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<grid.cells.count, id: \.self) { row in
                    GridRow {
                        Text(TrendsWeatherGrid.dayparts[row])
                            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                        ForEach(0..<grid.cells[row].count, id: \.self) { column in cell(grid.cells[row][column], row: row, column: column) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if interactive { Text(hoverText).font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2) }
                if showsLegend {
                    HStack(spacing: 16) {
                        temperatureScale
                        Spacer()
                        legend
                    }
                }
            }
            .padding(.leading, 74)
        }
    }

    private func cell(_ cell: TrendsWeatherGrid.Cell, row: Int, column: Int) -> some View {
        let enough = cell.plays >= Self.minimumPlays && cell.lift != nil
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(enough ? WeatherPalette.lift(cell.lift) : Color.secondary.opacity(0.08))
            .frame(minWidth: 34, maxWidth: .infinity, minHeight: cellHeight, maxHeight: cellHeight)
            .overlay {
                if showsValues, enough, let lift = cell.lift {
                    Text(WeatherPalette.percent(lift)).font(AppTypography.denseBadge).monospacedDigit().foregroundStyle(Color.primary.opacity(0.88))
                }
            }
            .overlay { if hovered == HoverCell(row: row, column: column) { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.primary.opacity(0.7), lineWidth: 1.5) } }
            .contentShape(Rectangle())
            .onHover { inside in hovered = inside ? HoverCell(row: row, column: column) : (hovered == HoverCell(row: row, column: column) ? nil : hovered) }
            .onTapGesture { if cell.plays > 0 { onSelect(row, column) } }
    }

    /// A short key to the columns: coldest to warmest. It is deliberately not as wide as the grid, because the columns hold equal
    /// shares of your hours, not equal ranges of temperature, so a position along it would say nothing; hover a cell for its range.
    private var temperatureScale: some View {
        HStack(spacing: 6) {
            Text(label(grid.edges.first)).font(AppTypography.denseBadge).foregroundStyle(.secondary).monospacedDigit()
            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map { WeatherPalette.temperature($0) }, startPoint: .leading, endPoint: .trailing)
                .frame(width: 70, height: 8).clipShape(Capsule())
            Text(label(grid.edges.last)).font(AppTypography.denseBadge).foregroundStyle(.secondary).monospacedDigit()
            Text("coldest to warmest").font(AppTypography.denseBadge).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
        }
    }

    private func label(_ celsius: Double?) -> String { celsius.map { unit.text(celsius: $0) } ?? "" }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("less than usual").font(AppTypography.denseBadge).foregroundStyle(.secondary)
            LinearGradient(colors: [WeatherPalette.lift(0.4), WeatherPalette.lift(1).opacity(0.5), WeatherPalette.lift(1.6)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 90, height: 8).clipShape(Capsule())
            Text("more").font(AppTypography.denseBadge).foregroundStyle(.secondary)
        }
    }

    private var hoverText: String {
        guard let hovered, hovered.column < grid.edges.count - 1 else { return "Hover a cell to see the plays behind it; click it to open them" }
        let cell = grid.cells[hovered.row][hovered.column]
        let range = "\(label(grid.edges[hovered.column])) to \(label(grid.edges[hovered.column + 1]))"
        let amount = cell.lift.map { WeatherPalette.percent($0) + " vs usual" } ?? "no value"
        return "\(TrendsWeatherGrid.dayparts[hovered.row]) · \(range) · \(amount) · \(cell.plays.formatted()) plays"
    }
}

// MARK: - Listening against the weather

/// Your listening drawn over the weather of the same weeks (days, for a short period): the background of each is its temperature (blue
/// cold, red warm), the line is how much you played, and dots along the bottom mark rainy and snowy ones. Hover for the numbers; click a
/// week to open what you played in it.
struct TrendsWeatherTimeline: View {
    let weeks: [TrendsWeatherWeek]
    let unit: TemperatureUnit
    var metric = TrendsMetric.plays
    var onSelect: (TrendsWeatherWeek) -> Void = { _ in }
    /// What a shared card can leave out, and the chart's height (the card sets it to fill its space).
    var chartHeight: CGFloat = 240
    var showsLegend = true
    var showsTemperature = true
    var showsMarkers = true
    var showsAverage = true
    @State private var hovered: TrendsWeatherWeek?

    private var span: Int { weeks.first?.days ?? 7 }
    private var spanWord: String { span == 1 ? "day" : "week" }
    private var peak: Double { Double(max(weeks.map(\.plays).max() ?? 1, 1)) * 1.1 }
    private var average: Double { weeks.isEmpty ? 0 : Double(weeks.map(\.plays).reduce(0, +)) / Double(weeks.count) }
    private var coldest: Double { weeks.map(\.temperature).min() ?? 0 }
    private var warmest: Double { weeks.map(\.temperature).max() ?? 1 }

    private func position(_ week: TrendsWeatherWeek) -> Double { warmest > coldest ? (week.temperature - coldest) / (warmest - coldest) : 0.5 }
    private func middle(_ week: TrendsWeatherWeek) -> Date { week.start.addingTimeInterval(Double(week.days) * 43_200) }
    private func format(_ value: Double) -> String { metric == .plays ? value.formatted(.number.precision(.fractionLength(0))) : TrendsDuration.formatCompact(Int(value.rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(showsTemperature ? weeks : []) { week in
                    RectangleMark(
                        xStart: .value("Start", week.start), xEnd: .value("End", week.start.addingTimeInterval(Double(week.days) * 86_400)),
                        yStart: .value("From", 0), yEnd: .value("To", peak)
                    )
                    .foregroundStyle(WeatherPalette.temperature(position(week)).opacity(0.62))
                }
                ForEach(weeks) { week in
                    AreaMark(x: .value("When", middle(week)), y: .value("Listening", week.plays))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [Color.primary.opacity(0.42), Color.primary.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                }
                ForEach(weeks) { week in
                    LineMark(x: .value("When", middle(week)), y: .value("Listening", week.plays))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.primary.opacity(0.92))
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
                if showsAverage {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("average \(format(average)) a \(spanWord)")
                            .font(AppTypography.denseBadge).foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.45), in: Capsule())
                    }
                }
                ForEach(showsMarkers ? weeks.filter { $0.precipitation != .none } : []) { week in
                    PointMark(x: .value("When", middle(week)), y: .value("Marker", peak * 0.04))
                        .symbol(week.precipitation == .rain ? .circle : .diamond)
                        .symbolSize(week.precipitation == .rain ? 22 : 30)
                        .foregroundStyle(week.precipitation == .rain ? Color(red: 0.25, green: 0.58, blue: 0.95) : Color.primary)
                }
                if let hovered {
                    RuleMark(x: .value("When", middle(hovered)))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text(hoverText(hovered))
                                .font(AppTypography.denseBadge).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        }
                }
            }
            .chartYScale(domain: 0...peak)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.10))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)) } }.font(AppTypography.chartAxis)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                    AxisTick().foregroundStyle(Color.primary.opacity(0.4))
                    AxisValueLabel(format: span == 1 ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).year(.twoDigits)).font(AppTypography.chartAxis)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hovered = week(at: location, proxy: proxy, geometry: geometry)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { location in if let week = week(at: location, proxy: proxy, geometry: geometry) { onSelect(week) } }
                }
            }
            .frame(height: chartHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if showsLegend { legend }
        }
    }

    private func week(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> TrendsWeatherWeek? {
        guard let frame = proxy.plotFrame, let date: Date = proxy.value(atX: location.x - geometry[frame].origin.x) else { return nil }
        return weeks.min { abs($0.start.timeIntervalSince(date) + Double($0.days) * 43_200) < abs($1.start.timeIntervalSince(date) + Double($1.days) * 43_200) }
    }

    private func hoverText(_ week: TrendsWeatherWeek) -> String {
        let label = (span == 1 ? "" : "Week of ") + week.start.formatted(.dateTime.month(.abbreviated).day().year())
        let kind = week.precipitation == .rain ? " · rainy" : week.precipitation == .snow ? " · snowy" : ""
        let amount = metric == .plays ? "\(week.plays.formatted()) scrobbles" : TrendsDuration.formatCompact(week.plays)
        return "\(label) · \(amount) · \(unit.text(celsius: week.temperature))\(kind)"
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text(unit.text(celsius: coldest)).font(AppTypography.denseBadge).foregroundStyle(.secondary).monospacedDigit()
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map { WeatherPalette.temperature($0) }, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 110, height: 8).clipShape(Capsule())
                Text(unit.text(celsius: warmest)).font(AppTypography.denseBadge).foregroundStyle(.secondary).monospacedDigit()
                Text("average temperature of the \(spanWord)").font(AppTypography.denseBadge).foregroundStyle(.tertiary)
            }
            Label("rainy \(spanWord)", systemImage: "circle.fill").font(AppTypography.denseBadge).foregroundStyle(Color(red: 0.25, green: 0.58, blue: 0.95))
            Label("snowy \(spanWord)", systemImage: "diamond.fill").font(AppTypography.denseBadge).foregroundStyle(Color.primary.opacity(0.8))
            Spacer()
        }
    }
}
