import SwiftUI
import Charts

/// One stretch of time in one place: a trip, or all the time at home.
struct TrendsStay: Identifiable, Equatable, Sendable {
    struct Artist: Equatable, Sendable { let name: String; let plays: Int }

    let id: String
    let city: String
    let isHome: Bool
    /// The stretch inside the chosen period (a trip that began before it, or is still going, is cut to the period and to now).
    let from: Date
    let until: Date
    /// Calendar days (in your local time) the stay covers; for home, every day of the period not spent away.
    var days = 0
    var plays = 0
    /// Artists whose first play ever was made here.
    var newArtists = 0
    var topArtists: [Artist] = []
    var averageTemperature: Double?
    var rainShare: Double?

    var perDay: Double { days > 0 ? Double(plays) / Double(days) : 0 }
}

/// Plays per day through a stretch of days, for the chart.
struct TrendsPlaceBucket: Identifiable, Equatable, Sendable {
    let start: Date
    let days: Int
    let plays: Int
    var id: Date { start }
    var perDay: Double { days > 0 ? Double(plays) / Double(days) : 0 }
}

struct TrendsPlacesResult: Equatable, Sendable {
    var home: TrendsStay?
    /// Trips inside the period, newest first.
    var trips: [TrendsStay] = []
    var buckets: [TrendsPlaceBucket] = []
    var bucketDays = 1
    static let empty = TrendsPlacesResult()

    /// What a trip's listening is against home's: 0.43 is 43% as much a day.
    func relativeToHome(_ stay: TrendsStay) -> Double? {
        guard let home, home.perDay > 0, stay.days > 0 else { return nil }
        return stay.perDay / home.perDay
    }
}

/// Where you listened: every trip in the period, how much you played there against how much you play at home, what was new, and the weather.
/// A play belongs to the trip the weather and the city filter put it in (the trip it falls in by moment; where two overlap, the later); a day
/// counts as a trip day when the trip covers its middle, so the day you left or came back goes to one place.
enum TrendsPlacesEngine {
    static let topArtistCount = 3
    /// A period longer than this many days is drawn a week at a time.
    static let dailyBucketLimit = 200

    static func compute(scrobbles: [ScrobbleSnapshot], weather: WeatherSnapshot, range: DateRange, now: Date = Date(), calendar: Calendar = AppCalendars.listening) -> TrendsPlacesResult {
        let trips = weather.trips.map(\.trip)
        guard !weather.isEmpty, weather.placeName != nil, let homeCity = weather.cities.first else { return .empty }
        let firstPlay = scrobbles.first?.playedAt ?? range.from
        // Plays count from the period's first moment; days are whole calendar days, so the first (partly inside the period) is a day too.
        let from = max(range.from, firstPlay)
        let start = calendar.startOfDay(for: from)
        let end = min(range.to, now)
        guard from <= end else { return .empty }

        // Each day goes to the trip that covers its middle, or to home.
        var dayCount: [String: Int] = [:]
        var dayStays: [Date: String] = [:]
        var day = start
        var guardCount = 0
        while day <= end, guardCount < 40_000 {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            let noon = day.addingTimeInterval(next.timeIntervalSince(day) / 2)
            let stay = WeatherTrip.effective(at: noon, in: trips)?.id.uuidString ?? "home"
            dayStays[day] = stay
            dayCount[stay, default: 0] += 1
            day = next
            guardCount += 1
        }

        struct Tally {
            var plays = 0
            var temperatureSum = 0.0
            var temperatureCount = 0
            var conditionKnown = 0
            var rain = 0
            var newArtists = 0
            var artists: [String: Int] = [:]
        }
        var tallies: [String: Tally] = [:]
        var seen = Set<String>()
        var perDay: [Date: Int] = [:]
        for play in scrobbles {
            let first = seen.insert(play.artistName).inserted
            guard play.playedAt >= from, play.playedAt <= end else { continue }
            let stay = WeatherTrip.effective(at: play.playedAt, in: trips)?.id.uuidString ?? "home"
            var tally = tallies[stay, default: Tally()]
            tally.plays += 1
            if first { tally.newArtists += 1 }
            tally.artists[play.artistName, default: 0] += 1
            if let sample = weather.sample(at: play.playedAt) {
                if let temperature = sample.temperature { tally.temperatureSum += temperature; tally.temperatureCount += 1 }
                if let condition = sample.condition { tally.conditionKnown += 1; if condition == .rain { tally.rain += 1 } }
            }
            tallies[stay] = tally
            perDay[calendar.startOfDay(for: play.playedAt), default: 0] += 1
        }

        func stay(id: String, city: String, isHome: Bool, from: Date, until: Date) -> TrendsStay {
            let tally = tallies[id] ?? Tally()
            var result = TrendsStay(id: id, city: city, isHome: isHome, from: from, until: until)
            result.days = dayCount[id] ?? 0
            result.plays = tally.plays
            result.newArtists = tally.newArtists
            result.topArtists = tally.artists.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(topArtistCount).map { TrendsStay.Artist(name: $0.key, plays: $0.value) }
            result.averageTemperature = tally.temperatureCount > 0 ? tally.temperatureSum / Double(tally.temperatureCount) : nil
            result.rainShare = tally.conditionKnown > 0 ? Double(tally.rain) / Double(tally.conditionKnown) : nil
            return result
        }

        var result = TrendsPlacesResult()
        result.home = stay(id: "home", city: homeCity, isHome: true, from: from, until: end)
        for trip in trips.sorted(by: { $0.from > $1.from }) {
            let id = trip.id.uuidString
            guard (dayCount[id] ?? 0) > 0 || (tallies[id]?.plays ?? 0) > 0 else { continue }
            let tripFrom = max(trip.from, from), tripUntil = min(trip.until ?? now, end)
            result.trips.append(stay(id: id, city: trip.shortName, isHome: false, from: tripFrom, until: max(tripFrom, tripUntil)))
        }

        // The chart: plays a day (a day, or a week on a long period).
        let totalDays = dayStays.count
        let span = totalDays > dailyBucketLimit ? 7 : 1
        var bucketStart = start
        while bucketStart <= end {
            var days = 0, plays = 0
            var cursor = bucketStart
            for _ in 0..<span where cursor <= end {
                days += 1
                plays += perDay[cursor] ?? 0
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
            }
            result.buckets.append(TrendsPlaceBucket(start: bucketStart, days: days, plays: plays))
            bucketStart = cursor
        }
        result.bucketDays = span
        return result
    }

    /// The plays a stay counts, as a Query: its dates and its city.
    static func drillSpec(for stay: TrendsStay, target: QueryTarget) -> QuerySpec {
        let filter = QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil, months: nil, cities: [stay.city])
        return TrendsDrill.spec(from: stay.from, to: stay.until, target: target, playFilter: filter)
    }
}

/// Trends › Weather & places › Where you listened.
struct TrendsPlacesCard: View {
    let inputs: TrendsWeatherGroup.Inputs
    let unit: TemperatureUnit
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.weather.drillTarget") private var drillTargetRaw = QueryTarget.track.rawValue
    @State private var result: TrendsPlacesResult?

    private var drillTarget: QueryTarget { QueryTarget(rawValue: drillTargetRaw) ?? .track }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result {
                if result.trips.isEmpty {
                    Text("No trips in this period. Add where you were away, and for which dates, in Settings › Weather › Trips, and each one gets a comparison with home here.")
                        .font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SettingsLink { Text("Open Settings") }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        chart(result)
                        VStack(spacing: 6) {
                            ForEach(result.trips.prefix(8)) { trip in stayRow(trip, result: result) }
                            if result.trips.count > 8 {
                                Text("and \(result.trips.count - 8) earlier trips").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                            }
                            if let home = result.home { stayRow(home, result: result) }
                        }
                    }
                    .shareChartArea()
                    .shareSummary(summary(result))
                    Text("A day counts as a trip day when the trip covers its middle. “A day” is plays divided by those days, so a day away with no listening counts against the trip.")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: inputs, priority: .utility) { await recompute() }
    }

    // MARK: Chart

    private func chart(_ result: TrendsPlacesResult) -> some View {
        let peak = max(result.buckets.map(\.perDay).max() ?? 1, 1) * 1.15
        let homeRate = result.home?.perDay ?? 0
        return Chart {
            ForEach(result.trips) { trip in
                RectangleMark(xStart: .value("From", trip.from), xEnd: .value("Until", max(trip.until, trip.from.addingTimeInterval(86_400))), yStart: .value("Bottom", 0), yEnd: .value("Top", peak))
                    .foregroundStyle(Color.accentColor.opacity(0.16))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(trip.city).font(AppTypography.denseBadge).foregroundStyle(Color.accentColor).lineLimit(1)
                    }
            }
            ForEach(result.buckets) { bucket in
                RectangleMark(
                    xStart: .value("Start", bucket.start), xEnd: .value("End", bucket.start.addingTimeInterval(Double(bucket.days) * 86_400 - 3_600)),
                    yStart: .value("Bottom", 0), yEnd: .value("Plays a day", bucket.perDay)
                )
                .foregroundStyle(away(bucket, result) ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.55))
            }
            if homeRate > 0 {
                RuleMark(y: .value("At home", homeRate))
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("at home \(homeRate.formatted(.number.precision(.fractionLength(0)))) a day")
                            .font(AppTypography.denseBadge).foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.45), in: Capsule())
                    }
            }
        }
        .chartYScale(domain: 0...peak)
        .chartYAxisLabel("plays a day", position: .leading)
        .frame(height: 200)
    }

    private func away(_ bucket: TrendsPlaceBucket, _ result: TrendsPlacesResult) -> Bool {
        let middle = bucket.start.addingTimeInterval(Double(bucket.days) * 43_200)
        return result.trips.contains { middle >= $0.from && middle < max($0.until, $0.from.addingTimeInterval(86_400)) }
    }

    // MARK: Rows

    private func stayRow(_ stay: TrendsStay, result: TrendsPlacesResult) -> some View {
        Button {
            openQuery(TrendsPlacesEngine.drillSpec(for: stay, target: drillTarget), "Scrobbles · in \(stay.city) · " + TrendsDrill.rangeLabel(from: stay.from, to: stay.until))
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { rowItems(stay, result: result) }
                VStack(alignment: .leading, spacing: 4) { rowItems(stay, result: result) }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background((stay.isHome ? Color.secondary : Color.accentColor).opacity(stay.isHome ? 0.06 : 0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the \(stay.plays.formatted()) plays made in \(stay.city) in Query")
    }

    @ViewBuilder
    private func rowItems(_ stay: TrendsStay, result: TrendsPlacesResult) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(stay.isHome ? "\(stay.city) · home" : stay.city).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
            Text(stay.isHome ? "everything else in this period" : dates(stay)).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        VStack(alignment: .leading, spacing: 1) {
            Text("\(stay.plays.formatted()) plays").font(AppTypography.metadata.monospacedDigit())
            Text(perDayText(stay, result: result)).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        VStack(alignment: .leading, spacing: 1) {
            Text(stay.isHome ? "\(stay.newArtists.formatted()) new artists" : (stay.newArtists == 1 ? "1 new artist" : "\(stay.newArtists.formatted()) new artists")).font(AppTypography.metadata)
            Text(weatherText(stay)).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 130, alignment: .leading)
        Text(stay.topArtists.map(\.name).joined(separator: " · "))
            .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(2)
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
    }

    private func dates(_ stay: TrendsStay) -> String {
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        let last = stay.until.addingTimeInterval(-1)
        return stay.from.formatted(format) + " – " + last.formatted(format) + " · \(stay.days) day\(stay.days == 1 ? "" : "s")"
    }

    private func perDayText(_ stay: TrendsStay, result: TrendsPlacesResult) -> String {
        let perDay = stay.perDay.formatted(.number.precision(.fractionLength(0)))
        guard !stay.isHome, let relative = result.relativeToHome(stay) else { return "\(perDay) a day" }
        return "\(perDay) a day · \(Int((relative * 100).rounded()))% of home"
    }

    private func weatherText(_ stay: TrendsStay) -> String {
        var parts: [String] = []
        if let temperature = stay.averageTemperature { parts.append(unit.text(celsius: temperature)) }
        if let rain = stay.rainShare { parts.append("\(Int((rain * 100).rounded()))% rain") }
        return parts.isEmpty ? "no weather" : parts.joined(separator: " · ")
    }

    private func summary(_ result: TrendsPlacesResult) -> ShareChartSummary? {
        let away = result.trips.filter { $0.days > 0 }
        guard !away.isEmpty, let home = result.home, home.perDay > 0 else { return nil }
        let days = away.reduce(0) { $0 + $1.days }
        let plays = away.reduce(0) { $0 + $1.plays }
        let rate = Double(plays) / Double(max(days, 1)) / home.perDay
        return ShareChartSummary(
            headline: "Away, \(Int((rate * 100).rounded()))% as much", change: nil,
            detail: "\(away.count) trip\(away.count == 1 ? "" : "s"), \(days) days: \((Double(plays) / Double(max(days, 1))).formatted(.number.precision(.fractionLength(0)))) plays a day against \(home.perDay.formatted(.number.precision(.fractionLength(0)))) at home"
        )
    }

    private func recompute() async {
        result = nil
        let inputs = self.inputs
        let computed = await TrendsComputeGate.shared.run {
            TrendsPlacesEngine.compute(scrobbles: inputs.canonical, weather: inputs.weather, range: inputs.range)
        }
        guard !Task.isCancelled, let computed else { return }
        result = computed
    }
}
