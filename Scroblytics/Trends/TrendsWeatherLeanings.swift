import SwiftUI

/// One artist, album or track and how much its plays lean toward (or away from) one kind of weather.
struct TrendsLeaningItem: Identifiable, Equatable, Sendable {
    let id: QueryEntityID
    /// Its plays that have this kind of weather information (a play without weather says nothing).
    let plays: Int
    /// Of those, the plays made in the chosen weather.
    let inWeather: Int
    /// How many of its plays would be in that weather if it were played like everything else (with the time of year allowed for, when asked).
    let expected: Double
    /// Different days with a play in that weather: a long sitting on one rainy afternoon is one day, not forty plays of rain-music.
    let days: Int
    /// For a track: the album it was played under (so its own artwork, or the album's, can be found).
    var album: String? = nil
    /// The artwork the plays themselves carried, used when the app has none saved for the item.
    var fallbackImageURL: String? = nil

    var name: String { id.name }
    var artist: String { id.artist }
    /// 1.34 is 34% more often than usual.
    var lift: Double { expected > 0 ? Double(inWeather) / expected : 0 }
    var share: Double { plays > 0 ? Double(inWeather) / Double(plays) : 0 }
}

struct TrendsLeaningsResult: Equatable, Sendable {
    var toward: [TrendsLeaningItem] = []
    var away: [TrendsLeaningItem] = []
    /// Items with enough plays to be judged at all.
    var eligible = 0
    /// Every play in the period that has this kind of weather information.
    var totalPlays = 0
    /// The share of those plays made in the chosen weather.
    var baselineShare: Double?
    var adjusted = false

    static let empty = TrendsLeaningsResult()
}

/// Which artists, albums or tracks lean into a kind of weather: the share of an item's plays made in it, against what it would be if the item
/// were played like everything else. Played-like-everything-else is the share across all plays of the period, or (with `adjust`) of the same
/// calendar month, so a winter album is not a cold-weather album just because it is January. An item needs enough plays to judge, and its
/// plays in that weather must fall on several different days.
enum TrendsLeaningsEngine {
    static let minimumPlays = 40
    static let minimumInWeather = 8
    static let minimumDays = 4
    /// A lean is at least this much different from usual: 15% more, or (the other way) 15% less.
    static let minimumLift = 1.15
    static let maximumAwayLift = 0.85
    /// Below usual, the item must have been expected to have this many plays in the weather for its absence to mean anything.
    static let minimumExpectedAway = 8.0
    static let listLength = 10
    /// The weathers on offer: the common ones. (Fog and thunderstorms are too rare to judge anything by.)
    static let choices = ["Rain", "Snow", "Cold", "Hot", "Clear", "Cloudy"]

    /// Whether the weather of a play is `choice`; nil when it has no information of that kind (a condition for "Rain", a temperature for "Hot").
    static func isWeather(_ sample: WeatherSample, weather: WeatherSnapshot, choice: String) -> Bool? {
        if let condition = WeatherCondition(rawValue: choice) {
            guard let known = sample.condition else { return nil }
            return known == condition
        }
        if let band = TemperatureBand(rawValue: choice) {
            guard let known = weather.band(for: sample) else { return nil }
            return known == band
        }
        return nil
    }

    private struct Record {
        let entity: QueryEntityID
        let month: Int
        let day: Int
        let hit: Bool
        let album: String
        let imageURL: String?
    }

    private struct Accumulator {
        var plays = 0
        var hits = 0
        var expected = 0.0
        var days = Set<Int>()
        var album: String?
        var imageURL: String?
    }

    static func compute(
        scrobbles: [ScrobbleSnapshot], weather: WeatherSnapshot, range: DateRange, target: QueryTarget, choice: String, adjust: Bool,
        calendar: Calendar = AppCalendars.listening
    ) -> TrendsLeaningsResult {
        guard !weather.isEmpty, WeatherCondition(rawValue: choice) != nil || TemperatureBand(rawValue: choice) != nil else { return .empty }
        var records: [Record] = []
        var monthKnown = [Int](repeating: 0, count: 13), monthHits = monthKnown
        for play in scrobbles where play.playedAt >= range.from && play.playedAt <= range.to {
            let entity: QueryEntityID
            switch target {
            case .artist: entity = QueryEntityID(target: .artist, artist: play.artistName, name: play.artistName)
            case .album:
                guard !play.albumName.isEmpty else { continue }
                entity = QueryEntityID(target: .album, artist: play.artistName, name: play.albumName)
            case .track, .scrobble: entity = QueryEntityID(target: .track, artist: play.artistName, name: play.trackName)
            }
            guard let sample = weather.sample(at: play.playedAt), let hit = isWeather(sample, weather: weather, choice: choice) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: play.playedAt)
            let month = parts.month ?? 1
            records.append(Record(entity: entity, month: month, day: (parts.year ?? 0) * 10_000 + month * 100 + (parts.day ?? 1), hit: hit, album: play.albumName, imageURL: play.imageURL))
            monthKnown[month] += 1
            if hit { monthHits[month] += 1 }
        }
        guard !records.isEmpty else { return .empty }
        let total = records.count
        let overall = Double(records.filter(\.hit).count) / Double(total)
        let monthShare = (0...12).map { monthKnown[$0] > 0 ? Double(monthHits[$0]) / Double(monthKnown[$0]) : overall }
        var accumulators: [QueryEntityID: Accumulator] = [:]
        for record in records {
            // Changed in place (copying the accumulator out and back would copy its set of days for every play).
            accumulators[record.entity, default: Accumulator()].plays += 1
            accumulators[record.entity, default: Accumulator()].expected += adjust ? monthShare[record.month] : overall
            if record.hit {
                accumulators[record.entity, default: Accumulator()].hits += 1
                accumulators[record.entity, default: Accumulator()].days.insert(record.day)
            }
            if !record.album.isEmpty { accumulators[record.entity, default: Accumulator()].album = record.album }
            if let url = record.imageURL, !url.isEmpty, !TextNormalization.isLastfmPlaceholderImage(url) { accumulators[record.entity, default: Accumulator()].imageURL = url }
        }
        let items = accumulators.compactMap { id, a -> TrendsLeaningItem? in
            a.plays >= minimumPlays ? TrendsLeaningItem(id: id, plays: a.plays, inWeather: a.hits, expected: a.expected, days: a.days.count, album: a.album, fallbackImageURL: a.imageURL) : nil
        }
        func order(_ a: TrendsLeaningItem, _ b: TrendsLeaningItem, descending: Bool) -> Bool {
            if a.lift != b.lift { return descending ? a.lift > b.lift : a.lift < b.lift }
            if a.plays != b.plays { return a.plays > b.plays }
            return (a.artist, a.name) < (b.artist, b.name)
        }
        let toward = items.filter { $0.lift >= minimumLift && $0.inWeather >= minimumInWeather && $0.days >= minimumDays }
            .sorted { order($0, $1, descending: true) }.prefix(listLength)
        let away = items.filter { $0.lift <= maximumAwayLift && $0.expected >= minimumExpectedAway }
            .sorted { order($0, $1, descending: false) }.prefix(listLength)
        return TrendsLeaningsResult(toward: Array(toward), away: Array(away), eligible: items.count, totalPlays: total, baselineShare: overall, adjusted: adjust)
    }

    /// The artwork a row shows: the picture saved for the item (a custom one first), then the one its plays carried.
    static func imageURL(for item: TrendsLeaningItem, lookup: [String: String]) -> String? {
        let imageTarget: ImageTarget
        switch item.id.target {
        case .artist: imageTarget = ImageTarget(kind: .artist, artist: item.artist, album: nil, track: nil)
        case .album: imageTarget = ImageTarget(kind: .album, artist: item.artist, album: item.name, track: nil)
        case .track, .scrobble: imageTarget = ImageTarget(kind: .track, artist: item.artist, album: item.album, track: item.name)
        }
        return ImageResolutionEngine.effectiveImageURL(for: imageTarget, lookup: lookup, fallbackURL: item.fallbackImageURL)
    }

    /// The plays one item's row counts, as a Query: exactly the plays of it made in that weather (an artist opens as its tracks).
    static func drillSpec(for item: TrendsLeaningItem, choice: String, range: DateRange) -> QuerySpec {
        let isBand = TemperatureBand(rawValue: choice) != nil
        let filter = QueryPlayFilter(
            weekdays: nil, fromHour: nil, toHour: nil, months: nil,
            weatherConditions: isBand ? nil : [choice], temperatureBands: isBand ? [choice] : nil
        )
        var spec = TrendsDrill.spec(from: range.from, to: range.to, target: item.id.target == .artist ? .track : item.id.target, playFilter: filter)
        switch item.id.target {
        case .artist: spec.groups[0].append(QueryCondition("artist", .textIs, [.text(item.id.artist)]))
        case .album, .track, .scrobble:
            spec.groups[0].append(QueryCondition("name", .textIs, [.text(item.id.name)]))
            spec.groups[0].append(QueryCondition("artist", .textIs, [.text(item.id.artist)]))
        }
        return spec
    }
}

/// Trends › Weather & places › Leaning into the weather.
struct TrendsLeaningsCard: View {
    let inputs: TrendsWeatherGroup.Inputs
    let adjust: Bool
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.weather.leaning.choice") private var choice = "Rain"
    @AppStorage("trends.weather.leaning.target") private var targetRaw = QueryTarget.artist.rawValue
    @AppStorage("trends.weather.leaning.away") private var showsAway = false
    @State private var result: TrendsLeaningsResult?

    private var target: QueryTarget { QueryTarget(rawValue: targetRaw) ?? .artist }
    private struct ComputeKey: Equatable { let choice: String; let target: QueryTarget; let adjust: Bool; let inputs: TrendsWeatherGroup.Inputs }
    private struct LeanShareKey: Equatable { let result: TrendsLeaningsResult?; let choice: String; let target: QueryTarget; let away: Bool }

    private var weatherWord: String {
        TemperatureBand(rawValue: choice) != nil ? "when it is \(choice.lowercased())" : "in \(choice.lowercased() == "clear" ? "clear weather" : choice.lowercased())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            VStack(alignment: .leading, spacing: 6) {
                if let result {
                    let items = showsAway ? result.away : result.toward
                    if items.isEmpty {
                        Text(emptyText(result)).font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in row(index + 1, item) }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .shareChartArea()
            .shareSummary(summary)
            .shareNative(id: LeanShareKey(result: result, choice: choice, target: target, away: showsAway)) {
                result.map { TrendsShareCharts.leanings(result: $0, choice: choice, target: target, away: showsAway, imageLookup: inputs.imageLookup) }
            }
            if let result, !(showsAway ? result.away : result.toward).isEmpty { footnote(result) }
        }
        .task(id: ComputeKey(choice: choice, target: target, adjust: adjust, inputs: inputs), priority: .utility) { await recompute() }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { controlItems }
            VStack(alignment: .leading, spacing: 8) { controlItems }
        }
    }

    @ViewBuilder
    private var controlItems: some View {
        Picker("Weather", selection: $choice) {
            ForEach(TrendsLeaningsEngine.choices, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().fixedSize()
        .help("The weather to compare: a kind of weather, or how warm it was for your place")
        Picker("Show", selection: $targetRaw) {
            Text("Artists").tag(QueryTarget.artist.rawValue)
            Text("Albums").tag(QueryTarget.album.rawValue)
            Text("Tracks").tag(QueryTarget.track.rawValue)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        Picker("Direction", selection: $showsAway) {
            Text("More than usual").tag(false)
            Text("Less than usual").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        Spacer(minLength: 0)
    }

    private var entityKind: TopChartsEntity {
        switch target {
        case .artist: .artist
        case .album: .album
        case .track, .scrobble: .track
        }
    }

    /// The same artwork Top Charts and Query show: the picture saved for the item (a custom one first), then the one its plays carried.
    private func imageURL(for item: TrendsLeaningItem) -> String? { TrendsLeaningsEngine.imageURL(for: item, lookup: inputs.imageLookup) }

    private func row(_ rank: Int, _ item: TrendsLeaningItem) -> some View {
        let strength = min(1, abs(item.lift - 1) / 1.0)
        return Button {
            openQuery(TrendsLeaningsEngine.drillSpec(for: item, choice: choice, range: inputs.range), "Scrobbles · \(item.name) · \(weatherWord) · " + TrendsDrill.rangeLabel(from: inputs.range.from, to: inputs.range.to))
        } label: {
            HStack(spacing: 10) {
                Text("\(rank)").font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                EntityThumbnail(url: imageURL(for: item), entity: entityKind)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(AppTypography.metadata.weight(.semibold)).lineLimit(1)
                    if target != .artist {
                        Text(item.artist).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text("\(item.inWeather.formatted()) of \(item.plays.formatted()) plays · \(item.days.formatted()) days")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule().fill(WeatherPalette.lift(item.lift)).frame(width: max(6, 70 * strength))
                }
                .frame(width: 70, height: 8)
                Text(WeatherPalette.percent(item.lift))
                    .font(AppTypography.metadata.monospacedDigit().weight(.semibold))
                    .frame(width: 56, alignment: .trailing)
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(item.name): \(item.inWeather) of its \(item.plays) plays \(weatherWord), on \(item.days) different days; about \(item.expected.formatted(.number.precision(.fractionLength(0)))) would be usual. Click to open those plays in Query.")
    }

    private func footnote(_ result: TrendsLeaningsResult) -> some View {
        let base = result.baselineShare.map { "\(Int(($0 * 100).rounded()))% of all your plays were \(weatherWord)" } ?? ""
        return Text("\(base). Percentages are against \(result.adjusted ? "the usual for the same month" : "that overall share"), and only a difference of 15% or more is shown. An item needs \(TrendsLeaningsEngine.minimumPlays)+ plays with weather" + (showsAway ? " and at least \(Int(TrendsLeaningsEngine.minimumExpectedAway)) of them expected \(weatherWord)." : ", at least \(TrendsLeaningsEngine.minimumInWeather) of them \(weatherWord) on \(TrendsLeaningsEngine.minimumDays)+ different days (one long sitting is not a pattern)."))
            .font(AppTypography.compactMetadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func emptyText(_ result: TrendsLeaningsResult) -> String {
        if result.totalPlays == 0 { return "No plays in this period have this weather information." }
        if result.eligible == 0 { return "Nothing has \(TrendsLeaningsEngine.minimumPlays) plays with weather in this period yet. Pick a longer period." }
        return showsAway ? "Nothing is clearly less likely \(weatherWord) in this period." : "Nothing clearly leans \(weatherWord) in this period, with enough plays on different days to say so."
    }

    private var summary: ShareChartSummary? {
        guard let result else { return nil }
        let items = showsAway ? result.away : result.toward
        guard let top = items.first else { return ShareChartSummary(headline: "", change: nil, detail: "Nothing clearly leans \(weatherWord)") }
        let noun = target == .artist ? "artist" : target == .album ? "album" : "track"
        return ShareChartSummary(
            headline: "\(showsAway ? "Least" : "Most") \(weatherWord): \(top.name)", change: nil,
            detail: showsAway
                ? "\(Int(((1 - top.lift) * 100).rounded()))% less often than usual, the \(noun) you play least \(weatherWord)"
                : "\(Int(((top.lift - 1) * 100).rounded()))% more often than usual, your top \(noun) \(weatherWord)"
        )
    }

    private func recompute() async {
        result = nil
        let (choice, target, adjust, inputs) = (self.choice, self.target, self.adjust, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            TrendsLeaningsEngine.compute(scrobbles: inputs.canonical, weather: inputs.weather, range: inputs.range, target: target, choice: choice, adjust: adjust)
        }
        guard !Task.isCancelled, let computed else { return }
        result = computed
    }
}
