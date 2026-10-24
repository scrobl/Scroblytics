import SwiftUI

/// How the map picks and places its artists.
enum TrendsWeatherMapMode: String, CaseIterable, Identifiable, Sendable {
    /// The artists whose plays lean furthest into one weather and temperature, each where it leans.
    case affinity
    /// The artists played most, each where it is played most.
    case mostPlayed

    var id: String { rawValue }
    var label: String { self == .affinity ? "Weather affinity" : "Most played" }
}

/// One cell of the map: a kind of weather at a range of temperatures, and how an artist's plays fall in it.
struct TrendsWeatherMapPlacement: Equatable, Sendable {
    let condition: WeatherCondition
    /// Which five-degree range of temperatures (see `TrendsWeatherMapEngine.bin(of:)`).
    let bin: Int
    /// Its plays in this cell.
    let plays: Int
    /// How many of its plays would be in this cell if it were played like everything else (with the time of year allowed for, when asked).
    let expected: Double
    /// Different days with a play in this cell: one long sitting on a rainy afternoon is one day, not a pattern.
    let days: Int
    /// The average temperature (°C) of those plays: where on the map the bubble sits.
    let temperature: Double
    /// How strongly it leans here, damped for small numbers so a handful of plays in a rare cell cannot win.
    let score: Double

    var lift: Double { expected > 0 ? Double(plays) / expected : 0 }
}

/// An artist with enough plays to place, and everything the map and its hover need to know about where it listens.
struct TrendsWeatherMapCandidate: Equatable, Sendable {
    let artist: String
    /// Its plays that have both a kind of weather and a temperature.
    let plays: Int
    let averageTemperature: Double
    /// Its plays in each kind of weather (indexed like `WeatherCondition.allCases`) and in each range of temperatures.
    let conditionPlays: [Int]
    let binPlays: [Int]
    /// Where it leans furthest, when it leans clearly anywhere.
    let affinity: TrendsWeatherMapPlacement?
    /// Where it is played most.
    let modal: TrendsWeatherMapPlacement
}

struct TrendsWeatherMapBubble: Identifiable, Equatable, Sendable {
    let candidate: TrendsWeatherMapCandidate
    let placement: TrendsWeatherMapPlacement
    var id: String { candidate.artist }
}

/// How a ring is coloured: against the other artists on the map, because the artists that make a Top 10 all lean hard and a fixed scale
/// would paint every one the same. From the weakest lean shown (pale gold) to a strong one (deep red-orange; the top fifth are all at full
/// colour so one outlier does not wash the rest out), on a logarithmic scale since a lean of 4× is "twice" 2×. Less than usual (possible in
/// Most played) stays blue.
struct TrendsWeatherMapRingScale: Equatable {
    let low: Double
    let high: Double

    init(lifts: [Double]) {
        let above = lifts.filter { $0 >= 1 && $0.isFinite }.sorted()
        low = above.first ?? 1
        high = above.isEmpty ? 1 : above[min(above.count - 1, Int((Double(above.count - 1) * 0.8).rounded(.down)))]
    }

    /// 0 for the weakest lean shown to 1 for the strongest; the middle when they are all about the same.
    func position(_ lift: Double) -> Double {
        guard high / max(low, 1e-9) >= 1.1 else { return 0.6 }
        return min(1, max(0, (log(max(lift, 1)) - log(low)) / (log(high) - log(low))))
    }

    private static let stops: [(Double, (Double, Double, Double))] = [(0, (1.00, 0.88, 0.55)), (0.5, (0.97, 0.58, 0.15)), (1, (0.84, 0.20, 0.12))]

    func color(_ lift: Double) -> Color {
        if lift < 1 { return WeatherPalette.lean(lift) }
        let p = position(lift)
        let (a, b) = p <= 0.5 ? (Self.stops[0], Self.stops[1]) : (Self.stops[1], Self.stops[2])
        let f = (p - a.0) / (b.0 - a.0)
        return Color(red: a.1.0 + (b.1.0 - a.1.0) * f, green: a.1.1 + (b.1.1 - a.1.1) * f, blue: a.1.2 + (b.1.2 - a.1.2) * f)
    }

    /// The colour at a position along the key.
    func color(atPosition p: Double) -> Color { color(low * pow(max(high / max(low, 1e-9), 1), min(1, max(0, p)))) }
}

struct TrendsWeatherMapResult: Equatable, Sendable {
    /// Replaced with every computation: the result is large, so equality is identity.
    let revision: UUID
    let candidates: [TrendsWeatherMapCandidate]
    /// Plays in every cell (kind of weather × range of temperatures): the shading behind the bubbles.
    let cellTotals: [Int]
    /// Plays in each kind of weather, and the share of all plays each makes (the usual, which an artist is compared with).
    let conditionTotals: [Int]
    let baseline: [Double]
    /// Every play in the period that has both a kind of weather and a temperature.
    let totalPlays: Int
    let adjusted: Bool

    static func == (a: Self, b: Self) -> Bool { a.revision == b.revision }

    static let empty = TrendsWeatherMapResult(revision: UUID(), candidates: [], cellTotals: [], conditionTotals: [], baseline: [], totalPlays: 0, adjusted: false)

    /// The kinds of weather with enough plays to draw a row for (the rare ones stay off the map).
    var rows: [WeatherCondition] {
        WeatherCondition.allCases.enumerated().compactMap { index, condition in
            index < conditionTotals.count && conditionTotals[index] >= TrendsWeatherMapEngine.minimumRowPlays ? condition : nil
        }
    }

    /// The kinds of weather left off for having too few plays (but some).
    var leftOut: [WeatherCondition] {
        WeatherCondition.allCases.enumerated().compactMap { index, condition in
            index < conditionTotals.count && conditionTotals[index] > 0 && conditionTotals[index] < TrendsWeatherMapEngine.minimumRowPlays ? condition : nil
        }
    }

    func cellTotal(_ condition: WeatherCondition, bin: Int) -> Int {
        guard let index = WeatherCondition.allCases.firstIndex(of: condition) else { return 0 }
        let cell = index * TrendsWeatherMapEngine.bins + bin
        return cell < cellTotals.count ? cellTotals[cell] : 0
    }

    /// The artists the map shows. Weather affinity takes the strongest leans first, but no one cell may take more than a quarter of them
    /// (so the map spreads across the weather instead of piling into the commonest); cells nobody leans into stay empty. Most played takes the
    /// most played.
    func bubbles(mode: TrendsWeatherMapMode, count: Int) -> [TrendsWeatherMapBubble] {
        switch mode {
        case .mostPlayed:
            return candidates.sorted { ($0.plays, $1.artist) > ($1.plays, $0.artist) }
                .prefix(count).map { TrendsWeatherMapBubble(candidate: $0, placement: $0.modal) }
        case .affinity:
            let ranked = candidates.compactMap { candidate -> TrendsWeatherMapBubble? in
                candidate.affinity.map { TrendsWeatherMapBubble(candidate: candidate, placement: $0) }
            }
            .sorted {
                if $0.placement.score != $1.placement.score { return $0.placement.score > $1.placement.score }
                if $0.candidate.plays != $1.candidate.plays { return $0.candidate.plays > $1.candidate.plays }
                return $0.candidate.artist < $1.candidate.artist
            }
            let cap = max(3, Int((Double(count) * TrendsWeatherMapEngine.cellShareCap).rounded(.up)))
            var perCell: [Int: Int] = [:]
            var chosen: [TrendsWeatherMapBubble] = []
            for bubble in ranked where chosen.count < count {
                let cell = (WeatherCondition.allCases.firstIndex(of: bubble.placement.condition) ?? 0) * TrendsWeatherMapEngine.bins + bubble.placement.bin
                guard perCell[cell, default: 0] < cap else { continue }
                perCell[cell, default: 0] += 1
                chosen.append(bubble)
            }
            return chosen
        }
    }
}

/// Which artists belong where on a map of weather against temperature. Every play with a kind of weather and a temperature falls in one
/// cell (a kind of weather and a five-degree range of temperatures). An artist's lean in a cell is the number of its plays there against what
/// it would have if it were played like everything else, so a quiet cell with a handful of plays cannot win on luck: the score is damped
/// toward "as usual", and a lean needs several plays on several different days.
enum TrendsWeatherMapEngine {
    static let conditions = WeatherCondition.allCases
    /// Five-degree ranges from below −15 °C to 40 °C and up: bin 1 is −15 to −10, bin 4 is 0 to 5, bin 12 is 40 and up.
    static let bins = 13
    static let binWidth = 5.0
    private static let zeroBin = 4

    /// An artist needs this many plays with weather to be placed at all.
    static let minimumPlays = 30
    /// A lean needs this many plays in the cell, on this many different days, and at least this much more than usual.
    static let minimumInCell = 8
    static let minimumDays = 4
    static let minimumLift = 1.25
    /// Some cell of an artist's will be above usual by luck alone, so the excess must also be this many standard deviations of what luck
    /// would give (the square root of the expected plays): 8 plays where 6 were expected is luck; 50 where 30 were expected is not.
    static let minimumSignificance = 2.5
    /// Added to both sides of the lean (plays and expected plays) so small cells are pulled toward "as usual".
    static let smoothing = 5.0
    /// A kind of weather needs this many plays in the period to have a row.
    static let minimumRowPlays = 30
    /// The most of the map any one cell may take in weather-affinity mode.
    static let cellShareCap = 0.25

    static func bin(of temperature: Double) -> Int { max(0, min(bins - 1, Int((temperature / binWidth).rounded(.down)) + zeroBin)) }

    /// The temperatures (°C) a bin holds, as a play filter takes them: from the lower edge up to (not including) the upper one; the two ends
    /// are open.
    static func range(ofBin bin: Int) -> (from: Double?, to: Double?) {
        (bin <= 0 ? nil : Double(bin - zeroBin) * binWidth, bin >= bins - 1 ? nil : Double(bin + 1 - zeroBin) * binWidth)
    }

    /// The edges drawn for a bin, with the open ends given the width of one more bin.
    static func edges(ofBin bin: Int) -> (low: Double, high: Double) {
        (Double(bin - zeroBin) * binWidth, Double(bin + 1 - zeroBin) * binWidth)
    }

    private struct Record {
        let artist: Int32
        let cell: Int16
        let month: Int8
        let day: Int32
        let temperature: Float
    }

    static func compute(
        scrobbles: [ScrobbleSnapshot], weather: WeatherSnapshot, range: DateRange, adjust: Bool, calendar: Calendar = AppCalendars.listening
    ) -> TrendsWeatherMapResult {
        guard !weather.isEmpty else { return .empty }
        let cellCount = conditions.count * bins
        var records: [Record] = []
        var ids: [String: Int32] = [:]
        var names: [String] = []
        var playsPerArtist: [Int] = []
        var cellTotals = [Int](repeating: 0, count: cellCount)
        var monthCell = [Int](repeating: 0, count: 12 * cellCount)
        var monthTotal = [Int](repeating: 0, count: 12)
        for play in scrobbles where play.playedAt >= range.from && play.playedAt <= range.to {
            guard let sample = weather.sample(at: play.playedAt), let condition = sample.condition, let temperature = sample.temperature,
                  let conditionIndex = conditions.firstIndex(of: condition) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: play.playedAt)
            let month = (parts.month ?? 1) - 1
            let cell = conditionIndex * bins + bin(of: temperature)
            let artist: Int32
            if let known = ids[play.artistName] { artist = known } else {
                artist = Int32(names.count)
                ids[play.artistName] = artist
                names.append(play.artistName)
                playsPerArtist.append(0)
            }
            playsPerArtist[Int(artist)] += 1
            records.append(Record(artist: artist, cell: Int16(cell), month: Int8(month), day: Int32((parts.year ?? 0) * 10_000 + (month + 1) * 100 + (parts.day ?? 1)), temperature: Float(temperature)))
            cellTotals[cell] += 1
            monthCell[month * cellCount + cell] += 1
            monthTotal[month] += 1
        }
        guard !records.isEmpty else { return .empty }

        // Only artists with enough plays are followed any further.
        var slotOf = [Int32](repeating: -1, count: names.count)
        var eligible: [Int32] = []
        for (index, plays) in playsPerArtist.enumerated() where plays >= minimumPlays {
            slotOf[index] = Int32(eligible.count)
            eligible.append(Int32(index))
        }
        let total = records.count
        var conditionTotals = [Int](repeating: 0, count: conditions.count)
        for cell in 0..<cellCount { conditionTotals[cell / bins] += cellTotals[cell] }
        let baseline = conditionTotals.map { Double($0) / Double(total) }
        guard !eligible.isEmpty else {
            return TrendsWeatherMapResult(revision: UUID(), candidates: [], cellTotals: cellTotals, conditionTotals: conditionTotals, baseline: baseline, totalPlays: total, adjusted: adjust)
        }

        let count = eligible.count
        var cellPlays = [Int32](repeating: 0, count: count * cellCount)
        var cellDays = [Int16](repeating: 0, count: count * cellCount)
        var cellLastDay = [Int32](repeating: 0, count: count * cellCount)
        var cellTemperature = [Double](repeating: 0, count: count * cellCount)
        var artistMonth = [Int](repeating: 0, count: count * 12)
        var temperatureSum = [Double](repeating: 0, count: count)
        var artistPlays = [Int](repeating: 0, count: count)
        // Plays arrive oldest first, so a cell's different days are counted by noticing the day change within that cell.
        for record in records {
            let slot = Int(slotOf[Int(record.artist)])
            guard slot >= 0 else { continue }
            let at = slot * cellCount + Int(record.cell)
            cellPlays[at] += 1
            cellTemperature[at] += Double(record.temperature)
            if cellLastDay[at] != record.day {
                cellLastDay[at] = record.day
                cellDays[at] += 1
            }
            artistMonth[slot * 12 + Int(record.month)] += 1
            temperatureSum[slot] += Double(record.temperature)
            artistPlays[slot] += 1
        }

        let overall = cellTotals.map { Double($0) / Double(total) }
        let monthShare: [Double] = (0..<12).flatMap { month in
            (0..<cellCount).map { cell in monthTotal[month] > 0 ? Double(monthCell[month * cellCount + cell]) / Double(monthTotal[month]) : overall[cell] }
        }
        func expected(slot: Int, cell: Int) -> Double {
            if !adjust { return Double(artistPlays[slot]) * overall[cell] }
            var sum = 0.0
            for month in 0..<12 { sum += Double(artistMonth[slot * 12 + month]) * monthShare[month * cellCount + cell] }
            return sum
        }
        func placement(slot: Int, cell: Int) -> TrendsWeatherMapPlacement {
            let at = slot * cellCount + cell
            let plays = Int(cellPlays[at])
            let usual = expected(slot: slot, cell: cell)
            return TrendsWeatherMapPlacement(
                condition: conditions[cell / bins], bin: cell % bins, plays: plays, expected: usual, days: Int(cellDays[at]),
                temperature: plays > 0 ? cellTemperature[at] / Double(plays) : 0, score: log((Double(plays) + smoothing) / (usual + smoothing))
            )
        }

        var candidates: [TrendsWeatherMapCandidate] = []
        candidates.reserveCapacity(count)
        for slot in 0..<count {
            var modalCell = -1, modalPlays: Int32 = 0
            var bestCell = -1, bestScore = -Double.infinity
            var conditionPlays = [Int](repeating: 0, count: conditions.count)
            var binPlays = [Int](repeating: 0, count: bins)
            for cell in 0..<cellCount {
                let plays = cellPlays[slot * cellCount + cell]
                guard plays > 0 else { continue }
                conditionPlays[cell / bins] += Int(plays)
                binPlays[cell % bins] += Int(plays)
                if plays > modalPlays { modalPlays = plays; modalCell = cell }
                guard Int(plays) >= minimumInCell, Int(cellDays[slot * cellCount + cell]) >= minimumDays else { continue }
                let usual = expected(slot: slot, cell: cell)
                guard usual > 0, Double(plays) / usual >= minimumLift, (Double(plays) - usual) / usual.squareRoot() >= minimumSignificance else { continue }
                let score = log((Double(plays) + smoothing) / (usual + smoothing))
                if score > bestScore { bestScore = score; bestCell = cell }
            }
            guard modalCell >= 0 else { continue }
            candidates.append(TrendsWeatherMapCandidate(
                artist: names[Int(eligible[slot])], plays: artistPlays[slot], averageTemperature: temperatureSum[slot] / Double(artistPlays[slot]),
                conditionPlays: conditionPlays, binPlays: binPlays, affinity: bestCell >= 0 ? placement(slot: slot, cell: bestCell) : nil, modal: placement(slot: slot, cell: modalCell)
            ))
        }
        return TrendsWeatherMapResult(revision: UUID(), candidates: candidates, cellTotals: cellTotals, conditionTotals: conditionTotals, baseline: baseline, totalPlays: total, adjusted: adjust)
    }

    /// The plays one bubble counts, as a Query: exactly the artist's plays made in that weather at those temperatures, as its tracks.
    static func drillSpec(for bubble: TrendsWeatherMapBubble, range: DateRange) -> QuerySpec {
        let temperatures = Self.range(ofBin: bubble.placement.bin)
        let filter = QueryPlayFilter(
            weekdays: nil, fromHour: nil, toHour: nil, months: nil, weatherConditions: [bubble.placement.condition.rawValue],
            temperatureFrom: temperatures.from, temperatureTo: temperatures.to
        )
        var spec = TrendsDrill.spec(from: range.from, to: range.to, target: .track, playFilter: filter)
        spec.groups[0].append(QueryCondition("artist", .textIs, [.text(bubble.candidate.artist)]))
        return spec
    }

    /// The picture drawn on an artist's bubble: the one saved for the artist (a custom one first); nil when there is none.
    static func artworkURL(for artist: String, lookup: [String: String]) -> String? {
        ImageResolutionEngine.effectiveImageURL(for: ImageTarget(kind: .artist, artist: artist, album: nil, track: nil), lookup: lookup, fallbackURL: nil)
    }

    /// A bubble at least this big (points, radius) shows its artist's picture; smaller ones are too small to recognise anyone in and stay a
    /// plain coloured dot.
    static let artworkMinimumRadius: CGFloat = 9

    // MARK: Wording

    /// "in rain", "in clear weather": a kind of weather as a phrase.
    static func phrase(_ condition: WeatherCondition) -> String {
        switch condition {
        case .clear: "in clear weather"
        case .cloudy: "in cloudy weather"
        case .fog: "in fog"
        case .rain: "in rain"
        case .snow: "in snow"
        case .thunderstorm: "in thunderstorms"
        }
    }

    /// "0 to 5 °C", "below −15 °C", "40 °C and up", in the chosen unit.
    static func rangeText(bin: Int, unit: TemperatureUnit) -> String {
        let bounds = range(ofBin: bin)
        switch (bounds.from, bounds.to) {
        case (nil, let to?): return "below \(unit.text(celsius: to))"
        case (let from?, nil): return "\(unit.text(celsius: from)) and up"
        case (let from?, let to?):
            let low = unit.fromCelsius(from), high = unit.fromCelsius(to)
            return "\(Int(low.rounded())) to \(unit.text(shown: high))"
        default: return ""
        }
    }

    /// "2.8×" for a lean, "0.8×" for a lean away.
    static func timesText(_ lift: Double) -> String { String(format: lift >= 10 ? "%.0f×" : "%.1f×", lift) }

    /// "2.8× as often as usual in rain at 0 to 5 °C".
    static func sentence(_ placement: TrendsWeatherMapPlacement, unit: TemperatureUnit) -> String {
        "\(timesText(placement.lift)) as often as usual \(phrase(placement.condition)) at \(rangeText(bin: placement.bin, unit: unit))"
    }
}
