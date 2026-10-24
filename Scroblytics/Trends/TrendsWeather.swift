import Foundation

/// Everything the three weather views in Trends draw for one period, worked out from the plays and the weather of the same hours.
struct TrendsWeatherResult: Sendable, Equatable {
    let tiles: [TrendsWeatherTile]
    /// Each weather's lift in the comparison period, when there is one.
    let previousLifts: [WeatherCondition: Double]
    let grid: TrendsWeatherGrid
    let buckets: [TrendsWeatherWeek]
    /// 1 for a short period (a bucket is a day), 7 for a long one (a week).
    let bucketDays: Int
    /// Plays still waiting for a track length (time listened only), left out.
    let pending: Int
    /// Whether each hour was compared with the usual rate for its month, so a season isn't mistaken for a weather.
    let adjusted: Bool
    /// False when the period has no weather at all (before the first downloaded year, or weather off).
    let hasWeather: Bool

    static let empty = TrendsWeatherResult(tiles: [], previousLifts: [:], grid: TrendsWeatherGrid(edges: [], cells: []), buckets: [], bucketDays: 7, pending: 0, adjusted: false, hasWeather: false)

    /// The weather this period's listening leans into most (more than usual, with enough plays to say so).
    var leaning: TrendsWeatherTile? {
        tiles.filter { !$0.isThin && ($0.lift ?? 0) > 1.0 }.max { ($0.lift ?? 0) < ($1.lift ?? 0) }
    }
}

/// How the weather and the plays of a period are put side by side. Plays are tallied per hour of the weather: the rate of listening in a
/// kind of weather is what it is divided by how many hours of that weather there were, not raw plays (more plays on clear days just
/// because there are more clear days). With `adjustForSeason` each hour is also compared with the usual rate for its month.
enum TrendsWeatherEngine {
    static let dayparts = TrendsWeatherGrid.dayparts
    static let columns = 10
    /// The hours each part of the day covers, as `QueryPlayFilter` takes them (night wraps midnight).
    static let daypartHours: [(from: Int, to: Int)] = [(5, 11), (12, 16), (17, 20), (21, 4)]

    /// 0 morning (5–11), 1 afternoon (12–16), 2 evening (17–20), 3 night (21–4): the same parts of the day as the Peak time of day field.
    static func daypart(hour: Int) -> Int {
        switch hour {
        case 5...11: 0
        case 12...16: 1
        case 17...20: 2
        default: 3
        }
    }

    /// Eleven °C edges for ten columns: the coldest hour, the nine decile cut-offs, the warmest hour (of every hour the weather covers).
    static func decileEdges(of series: WeatherSeries) -> [Double] { decileEdges(ofTemperatures: series.temperatures) }

    /// The same edges from everything a snapshot knows about the home climate.
    static func decileEdges(of weather: WeatherSnapshot) -> [Double] { decileEdges(ofTemperatures: weather.climateTemperatures) }

    private static func decileEdges(ofTemperatures temperatures: [Double]) -> [Double] {
        let sorted = temperatures.sorted()
        guard let first = sorted.first, let last = sorted.last else { return [] }
        var edges = [first]
        for k in 1..<columns { edges.append(sorted[min(sorted.count - 1, Int((Double(k) / Double(columns) * Double(sorted.count)).rounded(.up)) - 1)]) }
        edges.append(last)
        return edges
    }

    /// The column a temperature falls in: the last edge at or below it, never past the final column.
    static func column(of temperature: Double, edges: [Double]) -> Int {
        var low = 0, high = columns - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if edges[mid] <= temperature { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The plays a grid cell counts, as a play filter: its part of the day and its range of temperatures. Clicking the cell opens exactly
    /// these plays in Query. The range is from the column's lower edge up to (not including) the next edge; the last column also takes the
    /// warmest hour itself, and a column whose edges are equal still gets a range that holds its temperature.
    static func cellFilter(row: Int, column: Int, edges: [Double]) -> QueryPlayFilter? {
        guard (0..<4).contains(row), column >= 0, column + 1 < edges.count else { return nil }
        let hours = daypartHours[row]
        let from = edges[column]
        let upper = edges[column + 1]
        let to = column == columns - 1 || upper <= from ? max(upper, from) + 0.05 : upper
        return QueryPlayFilter(weekdays: nil, fromHour: hours.from, toHour: hours.to, months: nil, temperatureFrom: from, temperatureTo: to)
    }

    private static let conditionCount = WeatherCondition.allCases.count

    private struct Tally {
        // hours and plays by month × kind of weather
        var hoursByMonthCondition = [Int](repeating: 0, count: 12 * conditionCount)
        var weightByMonthCondition = [Double](repeating: 0, count: 12 * conditionCount)
        var countByCondition = [Int](repeating: 0, count: conditionCount)
        // hours and plays by month × part of the day × temperature column
        var hoursByCell = [Int](repeating: 0, count: 12 * 4 * columns)
        var weightByCell = [Double](repeating: 0, count: 12 * 4 * columns)
        var countByCell = [Int](repeating: 0, count: 4 * columns)
        // by month × part of the day: all hours / plays that have a temperature
        var hoursByMonthRow = [Int](repeating: 0, count: 12 * 4)
        var weightByMonthRow = [Double](repeating: 0, count: 12 * 4)
        var pending = 0
        var hasWeather = false
        // buckets (a day or a week each)
        var bucketIndex: [Date: Int] = [:]
        var bucketStarts: [Date] = []
        var bucketWeight: [Double] = []
        var bucketTempSum: [Double] = []
        var bucketTempCount: [Int] = []
        var bucketRain: [Int] = []
        var bucketSnow: [Int] = []
        var bucketHours: [Int] = []
    }

    static func compute(
        scrobbles: [ScrobbleSnapshot], weather: WeatherSnapshot, range: DateRange, compareRange: DateRange?, metric: TrendsMetric,
        durations: DurationEngine.Snapshot, adjustForSeason: Bool, calendar: Calendar = AppCalendars.listening
    ) -> TrendsWeatherResult {
        guard let bounds = weather.hourBounds else { return .empty }
        let edges = decileEdges(of: weather)
        guard edges.count == columns + 1 else { return .empty }
        let days = Int(range.to.timeIntervalSince(range.from) / 86_400)
        let bucketDays = days <= 150 ? 1 : 7
        let main = tally(range, scrobbles: scrobbles, weather: weather, bounds: bounds, edges: edges, metric: metric, durations: durations, bucketDays: bucketDays, calendar: calendar)
        guard main.hasWeather else { return TrendsWeatherResult(tiles: [], previousLifts: [:], grid: TrendsWeatherGrid(edges: edges, cells: []), buckets: [], bucketDays: bucketDays, pending: main.pending, adjusted: adjustForSeason, hasWeather: false) }
        let tiles = tiles(from: main, adjust: adjustForSeason)
        var previous: [WeatherCondition: Double] = [:]
        var pending = main.pending
        if let compareRange {
            let other = tally(compareRange, scrobbles: scrobbles, weather: weather, bounds: bounds, edges: edges, metric: metric, durations: durations, bucketDays: bucketDays, calendar: calendar)
            pending += other.pending
            for tile in Self.tiles(from: other, adjust: adjustForSeason) { if let lift = tile.lift, !tile.isThin { previous[tile.condition] = lift } }
        }
        let grid = TrendsWeatherGrid(edges: edges, cells: gridCells(from: main, adjust: adjustForSeason))
        var buckets: [TrendsWeatherWeek] = []
        for index in main.bucketStarts.indices where main.bucketTempCount[index] > 0 {
            let hours = Double(max(1, main.bucketHours[index]))
            let precipitation: TrendsWeatherWeek.Precipitation = Double(main.bucketSnow[index]) / hours >= 0.05 ? .snow : (Double(main.bucketRain[index]) / hours >= 0.10 ? .rain : .none)
            buckets.append(TrendsWeatherWeek(
                start: main.bucketStarts[index], temperature: main.bucketTempSum[index] / Double(main.bucketTempCount[index]),
                plays: Int(main.bucketWeight[index].rounded()), precipitation: precipitation, days: bucketDays
            ))
        }
        buckets.sort { $0.start < $1.start }
        return TrendsWeatherResult(tiles: tiles, previousLifts: previous, grid: grid, buckets: buckets, bucketDays: bucketDays, pending: pending, adjusted: adjustForSeason, hasWeather: true)
    }

    // MARK: Tallying one period

    private static func tally(
        _ range: DateRange, scrobbles: [ScrobbleSnapshot], weather: WeatherSnapshot, bounds: ClosedRange<Int>, edges: [Double], metric: TrendsMetric,
        durations: DurationEngine.Snapshot, bucketDays: Int, calendar: Calendar
    ) -> Tally {
        var t = Tally()
        func bucket(forDayStarting day: Date) -> Int {
            let start: Date = bucketDays == 1 ? day : (calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day)
            if let index = t.bucketIndex[start] { return index }
            let index = t.bucketStarts.count
            t.bucketIndex[start] = index
            t.bucketStarts.append(start)
            t.bucketWeight.append(0); t.bucketTempSum.append(0); t.bucketTempCount.append(0); t.bucketRain.append(0); t.bucketSnow.append(0); t.bucketHours.append(0)
            return index
        }

        // The hours: what the weather was, hour by hour, through the period.
        var day = calendar.startOfDay(for: range.from)
        while day <= range.to {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            let first = WeatherSeries.hour(of: day), last = WeatherSeries.hour(of: next) - 1
            if first <= bounds.upperBound, last >= bounds.lowerBound {
                var bucketIndex: Int?
                for hour in max(first, bounds.lowerBound)...min(last, bounds.upperBound) {
                    let date = WeatherSeries.date(ofHour: hour)
                    guard date >= range.from, date <= range.to, let sample = weather.sample(at: date) else { continue }
                    t.hasWeather = true
                    let index = bucketIndex ?? bucket(forDayStarting: day)
                    bucketIndex = index
                    let month = calendar.component(.month, from: date) - 1
                    let row = daypart(hour: calendar.component(.hour, from: date))
                    t.bucketHours[index] += 1
                    if let condition = sample.condition, let ci = WeatherCondition.allCases.firstIndex(of: condition) {
                        t.hoursByMonthCondition[month * conditionCount + ci] += 1
                        if condition == .rain { t.bucketRain[index] += 1 }
                        if condition == .snow { t.bucketSnow[index] += 1 }
                    }
                    if let temperature = sample.temperature {
                        let col = column(of: temperature, edges: edges)
                        t.hoursByCell[(month * 4 + row) * columns + col] += 1
                        t.hoursByMonthRow[month * 4 + row] += 1
                        t.bucketTempSum[index] += temperature
                        t.bucketTempCount[index] += 1
                    }
                }
            }
            day = next
        }

        // The plays made in those hours.
        for s in scrobbles where s.playedAt >= range.from && s.playedAt <= range.to {
            guard let weight = TrendsWeight.of(s, metric: metric, durations: durations) else { t.pending += 1; continue }
            guard let sample = weather.sample(at: s.playedAt) else { continue }
            let w = Double(weight)
            let month = calendar.component(.month, from: s.playedAt) - 1
            let row = daypart(hour: calendar.component(.hour, from: s.playedAt))
            if let condition = sample.condition, let ci = WeatherCondition.allCases.firstIndex(of: condition) {
                t.weightByMonthCondition[month * conditionCount + ci] += w
                t.countByCondition[ci] += 1
            }
            if let temperature = sample.temperature {
                let col = column(of: temperature, edges: edges)
                t.weightByCell[(month * 4 + row) * columns + col] += w
                t.countByCell[row * columns + col] += 1
                t.weightByMonthRow[month * 4 + row] += w
            }
            let dayStart = calendar.startOfDay(for: s.playedAt)
            let bucketStart: Date = bucketDays == 1 ? dayStart : (calendar.dateInterval(of: .weekOfYear, for: dayStart)?.start ?? dayStart)
            if let index = t.bucketIndex[bucketStart] { t.bucketWeight[index] += w }
        }
        return t
    }

    // MARK: Turning tallies into what is drawn

    private static func tiles(from t: Tally, adjust: Bool) -> [TrendsWeatherTile] {
        var hoursByCondition = [Int](repeating: 0, count: conditionCount)
        var weightByCondition = [Double](repeating: 0, count: conditionCount)
        var monthHours = [Int](repeating: 0, count: 12), monthWeight = [Double](repeating: 0, count: 12)
        for month in 0..<12 {
            for ci in 0..<conditionCount {
                hoursByCondition[ci] += t.hoursByMonthCondition[month * conditionCount + ci]
                weightByCondition[ci] += t.weightByMonthCondition[month * conditionCount + ci]
                monthHours[month] += t.hoursByMonthCondition[month * conditionCount + ci]
                monthWeight[month] += t.weightByMonthCondition[month * conditionCount + ci]
            }
        }
        let totalHours = hoursByCondition.reduce(0, +)
        let average = totalHours > 0 ? weightByCondition.reduce(0, +) / Double(totalHours) * 24 : 0
        return WeatherCondition.allCases.enumerated().map { ci, condition in
            let hours = hoursByCondition[ci]
            var perDay = hours > 0 ? weightByCondition[ci] / Double(hours) * 24 : 0
            if adjust, hours > 0 {
                // What this weather's hours would have brought at the usual rate of the month each fell in.
                var expected = 0.0
                for month in 0..<12 where monthHours[month] > 0 {
                    expected += Double(t.hoursByMonthCondition[month * conditionCount + ci]) * monthWeight[month] / Double(monthHours[month])
                }
                perDay = expected > 0 ? weightByCondition[ci] / expected * average : 0
            }
            return TrendsWeatherTile(condition: condition, perDay: perDay, average: average, playCount: t.countByCondition[ci], weight: Int(weightByCondition[ci].rounded()), hours: hours)
        }
    }

    private static func gridCells(from t: Tally, adjust: Bool) -> [[TrendsWeatherGrid.Cell]] {
        // The usual rate for each part of the day: per month when adjusting, over the whole period when not.
        var overallHours = [Int](repeating: 0, count: 4), overallWeight = [Double](repeating: 0, count: 4)
        for month in 0..<12 {
            for row in 0..<4 {
                overallHours[row] += t.hoursByMonthRow[month * 4 + row]
                overallWeight[row] += t.weightByMonthRow[month * 4 + row]
            }
        }
        return (0..<4).map { row in
            (0..<columns).map { col in
                var weight = 0.0, expected = 0.0
                for month in 0..<12 {
                    let hours = Double(t.hoursByCell[(month * 4 + row) * columns + col])
                    weight += t.weightByCell[(month * 4 + row) * columns + col]
                    if adjust {
                        let monthHours = t.hoursByMonthRow[month * 4 + row]
                        if monthHours > 0 { expected += hours * t.weightByMonthRow[month * 4 + row] / Double(monthHours) }
                    } else if overallHours[row] > 0 {
                        expected += hours * overallWeight[row] / Double(overallHours[row])
                    }
                }
                return TrendsWeatherGrid.Cell(lift: expected > 0 ? weight / expected : nil, plays: t.countByCell[row * columns + col])
            }
        }
    }
}
