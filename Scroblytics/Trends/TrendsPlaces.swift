import SwiftUI
import Charts

/// One stretch of time in one place: a trip, or all the time at home.
struct TrendsStay: Identifiable, Equatable, Sendable {
    struct Artist: Equatable, Sendable { let name: String; let plays: Int }

    let id: String
    let city: String
    let isHome: Bool
    /// What decides its colour: the place itself, so every trip to the same city is the same colour (a group of trips is one place already).
    var colorKey = ""
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
    /// How many trips this stay is made of: 1 for a trip on its own, more when trips to the same region or country are grouped.
    var tripCount = 1
    /// The cities of those trips (just one for a single trip), which are what a click opens in Query.
    var cities: [String] = []

    var perDay: Double { days > 0 ? Double(plays) / Double(days) : 0 }

    /// "6 days", or "3 trips · 18 days" for a group: the line under a stay's name.
    var summaryLine: String {
        let daysText = "\(days) day\(days == 1 ? "" : "s")"
        return tripCount > 1 ? "\(tripCount) trips · \(daysText)" : daysText
    }
}

/// One trip's own stretch of the period, for the chart's shading and bars (a group of trips is several of these).
struct TrendsTripSpan: Equatable, Sendable {
    /// The id of the `TrendsStay` it belongs to.
    let group: String
    /// The place it was to, which decides its colour (see `TrendsStay.colorKey`).
    var colorKey = ""
    let from: Date
    let until: Date
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
    /// Every trip's own stretch (a group has one for each of its trips).
    var spans: [TrendsTripSpan] = []
    var level = PlaceLevel.city
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

    static func compute(scrobbles: [ScrobbleSnapshot], weather: WeatherSnapshot, range: DateRange, level: PlaceLevel = .city, now: Date = Date(), calendar: Calendar = AppCalendars.listening) -> TrendsPlacesResult {
        let trips = weather.trips.map(\.trip)
        guard !weather.isEmpty, weather.placeName != nil, let homeCity = weather.cities.first else { return .empty }
        let firstPlay = scrobbles.first?.playedAt ?? range.from
        // Plays count from the period's first moment; days are whole calendar days, so the first (partly inside the period) is a day too.
        let from = max(range.from, firstPlay)
        let start = calendar.startOfDay(for: from)
        let end = min(range.to, now)
        guard from <= end else { return .empty }

        // Which stay each trip belongs to: itself by city, or every trip to the same region or country together.
        var groupOf: [UUID: (id: String, label: String, color: String)] = [:]
        for trip in trips {
            if level == .city {
                groupOf[trip.id] = (trip.id.uuidString, trip.shortName, "city:" + PlaceNames.key(trip.place.name))
            } else {
                let id = "\(level.rawValue):" + PlaceNames.key(trip.place.name(at: level))
                groupOf[trip.id] = (id, trip.place.name(at: level), id)
            }
        }
        func groupID(_ trip: WeatherTrip?) -> String { trip.flatMap { groupOf[$0.id]?.id } ?? "home" }

        // Each day goes to the trip that covers its middle, or to home.
        var dayCount: [String: Int] = [:]
        var tripDays: [UUID: Int] = [:]
        var totalDays = 0
        var day = start
        var guardCount = 0
        while day <= end, guardCount < 40_000 {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            let noon = day.addingTimeInterval(next.timeIntervalSince(day) / 2)
            let trip = WeatherTrip.effective(at: noon, in: trips)
            dayCount[groupID(trip), default: 0] += 1
            if let trip { tripDays[trip.id, default: 0] += 1 }
            totalDays += 1
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
        var tripPlays: [UUID: Int] = [:]
        var seen = Set<String>()
        var perDay: [Date: Int] = [:]
        for play in scrobbles {
            let first = seen.insert(play.artistName).inserted
            guard play.playedAt >= from, play.playedAt <= end else { continue }
            let trip = WeatherTrip.effective(at: play.playedAt, in: trips)
            let stay = groupID(trip)
            if let trip { tripPlays[trip.id, default: 0] += 1 }
            // Changed in place: copying the tally out and back would copy its whole artist dictionary for every play.
            tallies[stay, default: Tally()].plays += 1
            if first { tallies[stay, default: Tally()].newArtists += 1 }
            tallies[stay, default: Tally()].artists[play.artistName, default: 0] += 1
            if let sample = weather.sample(at: play.playedAt) {
                if let temperature = sample.temperature { tallies[stay, default: Tally()].temperatureSum += temperature; tallies[stay, default: Tally()].temperatureCount += 1 }
                if let condition = sample.condition {
                    tallies[stay, default: Tally()].conditionKnown += 1
                    if condition == .rain { tallies[stay, default: Tally()].rain += 1 }
                }
            }
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
        result.level = level
        result.home = stay(id: "home", city: homeCity, isHome: true, from: from, until: end)
        result.home?.cities = [homeCity]
        // The trips that happened in the period, earliest first, gathered into their stays.
        struct Group { var label: String; var color = ""; var from: Date; var until: Date; var count = 0; var cities: [String] = [] }
        var groups: [String: Group] = [:]
        for trip in trips.sorted(by: { $0.from < $1.from }) {
            guard (tripDays[trip.id] ?? 0) > 0 || (tripPlays[trip.id] ?? 0) > 0, let info = groupOf[trip.id] else { continue }
            let tripFrom = max(trip.from, from), tripUntil = max(tripFrom, min(trip.until ?? now, end))
            result.spans.append(TrendsTripSpan(group: info.id, colorKey: info.color, from: tripFrom, until: tripUntil))
            var group = groups[info.id] ?? Group(label: info.label, color: info.color, from: tripFrom, until: tripUntil)
            group.from = min(group.from, tripFrom)
            group.until = max(group.until, tripUntil)
            group.count += 1
            if !group.cities.contains(where: { PlaceNames.key($0) == PlaceNames.key(trip.shortName) }) { group.cities.append(trip.shortName) }
            groups[info.id] = group
        }
        result.trips = groups.map { id, group in
            var grouped = stay(id: id, city: group.label, isHome: false, from: group.from, until: group.until)
            grouped.tripCount = group.count
            grouped.colorKey = group.color
            grouped.cities = group.cities
            return grouped
        }
        // The most recent visit first.
        .sorted { ($0.until, $0.from, $0.id) > ($1.until, $1.from, $1.id) }

        // The chart: plays a day (a day, or a week on a long period).
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

    /// The plays a stay counts, as a Query: its dates and its city (or cities, for a group).
    static func drillSpec(for stay: TrendsStay, target: QueryTarget) -> QuerySpec {
        let filter = QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil, months: nil, cities: stay.cities.isEmpty ? [stay.city] : stay.cities)
        return TrendsDrill.spec(from: stay.from, to: stay.until, target: target, playFilter: filter)
    }
}

extension TrendsPlacesResult {
    /// One colour for each place, in the order you first went there (so neighbours in time get different colours), used for its shading
    /// on the chart, its bars, and the dot in front of its row. Every trip to the same city (or, grouped, the same region or country) is the
    /// same colour. Home is grey.
    static let tripColors: [Color] = [.blue, .orange, .green, .purple, .teal, .pink, .yellow, .red, .indigo, .mint]

    func tint(for stay: TrendsStay) -> Color { tint(forKey: stay.colorKey.isEmpty ? stay.id : stay.colorKey) }

    /// The colour of a place by its key (a trip's stretch on the chart names its place's key).
    func tint(forKey key: String) -> Color {
        var order: [String] = []
        for stay in trips.sorted(by: { ($0.from, $0.id) < ($1.from, $1.id) }) {
            let stayKey = stay.colorKey.isEmpty ? stay.id : stay.colorKey
            if !order.contains(stayKey) { order.append(stayKey) }
        }
        guard let index = order.firstIndex(of: key) else { return .secondary }
        return Self.tripColors[index % Self.tripColors.count]
    }
}

/// Plays a day through the period, each trip shaded and drawn in its own colour (named above the chart where there is room), and home's
/// rate as a dashed line. Drawn on screen and, larger, on a shared card.
struct TrendsPlacesChart: View {
    let result: TrendsPlacesResult
    var height: CGFloat = 200

    /// Which of a few rows each trip's name goes in so names that would run into each other sit on different rows, or nil to leave a name
    /// out when every row is taken there (the trip's colour and its row below still say which it is). `labels` are in order of position.
    static func labelLanes(_ labels: [(x: CGFloat, width: CGFloat)], lanes: Int = 3, gap: CGFloat = 4) -> [Int?] {
        var edges = [CGFloat](repeating: -.infinity, count: lanes)
        return labels.map { label in
            for lane in 0..<lanes where label.x >= edges[lane] + gap {
                edges[lane] = label.x + label.width
                return lane
            }
            return nil
        }
    }

    var body: some View {
        let peak = max(result.buckets.map(\.perDay).max() ?? 1, 1) * 1.15
        let homeRate = result.home?.perDay ?? 0
        return Chart {
            ForEach(Array(result.spans.enumerated()), id: \.offset) { _, span in
                RectangleMark(xStart: .value("From", span.from), xEnd: .value("Until", max(span.until, span.from.addingTimeInterval(86_400))), yStart: .value("Bottom", 0), yEnd: .value("Top", peak))
                    .foregroundStyle(result.tint(forKey: span.colorKey.isEmpty ? span.group : span.colorKey).opacity(0.2))
            }
            ForEach(result.buckets) { bucket in
                RectangleMark(
                    xStart: .value("Start", bucket.start), xEnd: .value("End", bucket.start.addingTimeInterval(Double(bucket.days) * 86_400 - 3_600)),
                    yStart: .value("Bottom", 0), yEnd: .value("Plays a day", bucket.perDay)
                )
                .foregroundStyle(tripColor(of: bucket).map { $0.opacity(0.95) } ?? Color.secondary.opacity(0.55))
            }
            if homeRate > 0 {
                RuleMark(y: .value("At home", homeRate))
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    // Below the line, at the right: the trips' names run along the top.
                    .annotation(position: .bottom, alignment: .trailing, spacing: 3) {
                        Text("at home \(homeRate.formatted(.number.precision(.fractionLength(0)))) a day")
                            .font(AppTypography.denseBadge).foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.45), in: Capsule())
                    }
            }
        }
        .chartYScale(domain: 0...peak)
        .chartYAxisLabel("plays a day", position: .leading)
        .chartOverlay { proxy in tripNames(proxy) }
        .frame(height: height)
    }

    /// The trips' names inside the top of the chart, each at the start of its trip, staggered so they don't run into each other.
    private func tripNames(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let plot = proxy.plotFrame {
                let frame = geometry[plot]
                let named = result.trips.sorted { $0.from < $1.from }.compactMap { trip -> (trip: TrendsStay, left: CGFloat, width: CGFloat)? in
                    guard let x = proxy.position(forX: trip.from) else { return nil }
                    let width = CGFloat(trip.city.count) * 5.8 + 6
                    return (trip, min(frame.minX + x, frame.maxX - width), width)
                }
                let lanes = Self.labelLanes(named.map { (x: $0.left, width: $0.width) })
                ForEach(Array(named.enumerated()), id: \.offset) { index, item in
                    if let lane = lanes[index] {
                        Text(item.trip.city)
                            .font(AppTypography.denseBadge.weight(.semibold)).foregroundStyle(result.tint(for: item.trip)).lineLimit(1).fixedSize()
                            .position(x: item.left + item.width / 2, y: frame.minY + 8 + CGFloat(lane) * 13)
                    }
                }
            }
        }
    }

    /// The colour of the trip a bucket falls in, nil at home.
    private func tripColor(of bucket: TrendsPlaceBucket) -> Color? {
        let middle = bucket.start.addingTimeInterval(Double(bucket.days) * 43_200)
        return result.spans.first { middle >= $0.from && middle < max($0.until, $0.from.addingTimeInterval(86_400)) }.map { result.tint(forKey: $0.colorKey.isEmpty ? $0.group : $0.colorKey) }
    }
}

/// Trends › Weather & places › Where you listened.
struct TrendsPlacesCard: View {
    let inputs: TrendsWeatherGroup.Inputs
    let unit: TemperatureUnit
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.weather.drillTarget") private var drillTargetRaw = QueryTarget.track.rawValue
    /// How trips are grouped on the chart and in the list: each on its own, or by the region or country they are in.
    @AppStorage("trends.places.level") private var levelRaw = PlaceLevel.city.rawValue
    @State private var result: TrendsPlacesResult?

    private var level: PlaceLevel { PlaceLevel(rawValue: levelRaw) ?? .city }
    private struct ComputeKey: Equatable { let level: PlaceLevel; let inputs: TrendsWeatherGroup.Inputs }

    private var drillTarget: QueryTarget { QueryTarget(rawValue: drillTargetRaw) ?? .track }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result {
                if result.trips.isEmpty {
                    Text("No trips in this period. Add where you were away, and for which dates, in Settings › Weather › Trips, and each one gets a comparison with home here.")
                        .font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SettingsLink { Text("Open Settings") }
                } else {
                    Picker("Group trips by", selection: $levelRaw) {
                        ForEach(PlaceLevel.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("City: each trip on its own. State/Region or Country: trips to the same state or country together, in one colour. A place with no region or country on record (coordinates) stays on its own.")
                    VStack(alignment: .leading, spacing: 12) {
                        TrendsPlacesChart(result: result)
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
                    .shareNative(id: result) { TrendsShareCharts.places(result: result, unit: unit) }
                    Text("A day counts as a trip day when the trip covers its middle. “A day” is plays divided by those days, so a day away with no listening counts against the trip.")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: ComputeKey(level: level, inputs: inputs), priority: .utility) { await recompute() }
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
            .background(result.tint(for: stay).opacity(stay.isHome ? 0.06 : 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the \(stay.plays.formatted()) plays made in \(stay.city) in Query")
    }

    @ViewBuilder
    private func rowItems(_ stay: TrendsStay, result: TrendsPlacesResult) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(stay.isHome ? Color.secondary.opacity(0.6) : result.tint(for: stay)).frame(width: 9, height: 9).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(stay.isHome ? "\(stay.city) · home" : stay.city).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
                Text(stay.isHome ? "everything else in this period" : (stay.tripCount > 1 ? stay.summaryLine : dates(stay))).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
            }
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
        let (inputs, level) = (self.inputs, self.level)
        let computed = await TrendsComputeGate.shared.run {
            TrendsPlacesEngine.compute(scrobbles: inputs.canonical, weather: inputs.weather, range: inputs.range, level: level)
        }
        guard !Task.isCancelled, let computed else { return }
        result = computed
    }
}
