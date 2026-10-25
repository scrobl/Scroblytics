import AppKit
import SwiftData
import SwiftUI

#if DEBUG
/// `SCROBLYTICS_LAYOUT_SNAPSHOT_DETAIL=<folder>` (with `SCROBLYTICS_STORE_PATH` on a scratch path): renders the new detail pages'
/// header card offscreen, with made-up data, at several window widths in dark and light, so the layout can be looked at without
/// driving the app. Nothing is shown on screen and nothing is read from or written to the real data.
enum DetailSnapshots {
    static func sampleStats(loved: Bool = true) -> EntityStats {
        let now = Date()
        let trend = (0..<30).map { TrendBucket(start: now.addingTimeInterval(Double($0 - 30) * 86400), count: [2, 1, 4, 3, 6, 5, 9, 4, 3, 8][$0 % 10]) }
        let first = now.addingTimeInterval(-86400 * 900)
        let milestones = MilestonesEngine.EntityMilestones(
            achieved: [(milestone: 100, achievedAt: now.addingTimeInterval(-86400 * 300), firstAt: first)],
            upcoming: (next: 250, remaining: 108, etaDays: 190)
        )
        return EntityStats(plays: 142, firstScrobble: first, lastScrobble: now.addingTimeInterval(-86400 * 3), imageURL: nil, loved: loved, trend: trend, milestones: milestones)
    }

    @MainActor
    static func trackCard(stats: EntityStats?, facts: [DetailFact]) -> some View {
        DetailHeaderCard(
            entity: .track, name: "Track Title", subtitle: "Artist A", tertiary: "Album Name", imageURL: nil, stats: stats,
            errorMessage: nil, metric: .scrobbles, timeListenedSeconds: 142 * 224,
            yearlyTopRanks: [TopChartsEngine.YearlyRank(year: 2024, rank: 3), TopChartsEngine.YearlyRank(year: 2022, rank: 9)],
            onToggleLoved: {}, facts: facts, sharePeriodLabel: "Last 12 months"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Community tags").font(AppTypography.statLabel).foregroundStyle(.secondary)
                Text("dream pop · shoegaze · 2010s").font(AppTypography.metadata)
            }
        }
    }

    static func sampleObservedTurnover() -> AlbumTurnoverEngine.AlbumTurnover {
        AlbumTurnoverEngine.AlbumTurnover(
            artist: "Artist A", album: "Album Name", applicable: true, basis: .observed, ambiguous: false, noCanonicalMatch: true,
            resolved: false, rateDays: nil, cyclesCompleted: 0, lastTurnoverDate: nil, trackCount: 3, observedDistinct: 3,
            inProgressHeard: 1, inProgressTotal: 3, inProgressMissing: [], tracks: [.init(title: "A", heardThisCycle: true)], isCompilation: false, groupKey: "k", imageURL: nil
        )
    }

    static func sampleTurnover(
        ambiguous: Bool = false, cycles: Int = 7, heard: Int = 8, total: Int = 11, tracks: [AlbumTurnoverEngine.TrackCycleState] = []
    ) -> AlbumTurnoverEngine.AlbumTurnover {
        AlbumTurnoverEngine.AlbumTurnover(
            artist: "Artist A", album: "Album Name", applicable: true, basis: .canonical, ambiguous: ambiguous, noCanonicalMatch: false,
            resolved: false, rateDays: 38, cyclesCompleted: cycles, lastTurnoverDate: nil, trackCount: total, observedDistinct: total,
            inProgressHeard: heard, inProgressTotal: total, inProgressMissing: [], tracks: tracks, isCompilation: false, groupKey: "k", imageURL: nil
        )
    }

    @MainActor
    static func artistCard(stats: EntityStats?, facts: [DetailFact] = []) -> some View {
        DetailHeaderCard(
            entity: .artist, name: "Artist A", subtitle: nil, tertiary: nil, imageURL: nil, stats: stats,
            errorMessage: nil, metric: .scrobbles, timeListenedSeconds: 300 * 3600,
            yearlyTopRanks: [TopChartsEngine.YearlyRank(year: 2024, rank: 4), TopChartsEngine.YearlyRank(year: 2023, rank: 7)],
            facts: facts, sharePeriodLabel: "Last 12 months"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Community tags").font(AppTypography.statLabel).foregroundStyle(.secondary)
                Text("dream pop · shoegaze · 2010s").font(AppTypography.metadata)
            }
        }
    }

    @MainActor
    static func albumCard(stats: EntityStats?, turnover: AlbumTurnoverState, title: String = "Album Name", extraFacts: [DetailFact] = []) -> some View {
        let released = DetailFact(id: "released", label: "Released", value: .text("Sep 12, 2018"), systemImage: "calendar", onEdit: {})
        return DetailHeaderCard(
            entity: .album, name: title, subtitle: "Artist A", tertiary: nil, imageURL: nil, stats: stats,
            errorMessage: nil, metric: .scrobbles, timeListenedSeconds: 78 * 3600,
            yearlyTopRanks: [TopChartsEngine.YearlyRank(year: 2024, rank: 2)],
            onFixAlbumMatch: {}, facts: [released] + AlbumDetailModel.turnoverFacts(turnover, onFixAlbumMatch: {}) + extraFacts, sharePeriodLabel: "Last 12 months"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Community tags").font(AppTypography.statLabel).foregroundStyle(.secondary)
                Text("dream pop · shoegaze · 2010s").font(AppTypography.metadata)
            }
        }
    }


    @MainActor
    static func table(compact: Bool = false, longAlbum: Bool = false) -> some View {
        let now = Date()
        func entry(_ name: String, plays: Int, daysAgo: Double) -> TopChartEntry {
            TopChartEntry(
                rank: 1, name: name, artist: "Artist A", album: "Album Name", playcount: plays, timeListenedSeconds: nil, imageURL: nil,
                hasCompareRange: false, previousRank: nil, peakRank: 1, lastPlayedAt: now.addingTimeInterval(-daysAgo * 86400), loved: plays > 40,
                releaseDateResolution: .unknown
            )
        }
        let count = longAlbum ? 64 : 11
        let heard = (0..<count).map { $0 % 4 != 3 }
        let listed: [AlbumTurnoverEngine.TrackCycleState] = (0..<count).map { .init(title: "Song \($0 + 1)", heardThisCycle: heard[$0]) }
        var played: [TopChartEntry] = []
        for index in 0..<count where index % 5 != 4 {
            played.append(entry("Song \(index + 1)", plays: max(1, 60 - index * 4 + (index % 3) * 7), daysAgo: Double(1 + index * 3)))
        }
        played.append(entry("Bonus Track", plays: 3, daysAgo: 20))
        return NavigationStack {
            ScrollView {
                AlbumTrackTable(
                    artist: "Artist A", album: "Album Name",
                    range: DateRange(from: now.addingTimeInterval(-365 * 86400), to: now), compareRange: nil, metric: .scrobbles,
                    turnover: .ready(sampleTurnover(total: count, tracks: listed)), seedEntries: played,
                    seedDurations: Dictionary(uniqueKeysWithValues: played.enumerated().map { (DurationEngine.cacheKey(artist: "Artist A", track: $0.element.name), 170 + ($0.offset * 17) % 140) })
                )
            }
        }
        .frame(height: longAlbum ? 900 : 560)
    }

    /// A track's plays with and without weather: some covered, one before the downloaded years, one at an hour with no temperature.
    @MainActor
    static func playsList(withWeather: Bool) -> some View {
        let now = Date()
        let history = (0..<8).map { ScrobbleHistoryEntry(playedAt: now.addingTimeInterval(-Double($0) * 86_400 * 3 - Double($0) * 5_000), album: $0 % 3 == 0 ? nil : "Album Name") }
        var series = WeatherSeries(startHour: WeatherSeries.hour(of: now) - 24 * 14, count: 24 * 15)
        let codes = [61, 0, 3, 71, 95, 45]
        for hour in series.startHour..<(series.startHour + series.count) {
            let index = (hour / 24) % codes.count
            series.set(hour: hour, WeatherSample(temperature: hour % 11 == 0 ? nil : Double((hour / 24) % 17) - 3 + Double(hour % 24) / 6, precipitation: nil, rain: nil, snowfall: nil, code: codes[index]))
        }
        let snapshot = withWeather ? WeatherSnapshot(series: series, placeName: "Oslo, Norway", percentiles: (20, 80)) : .empty
        return TrackPlaysList(history: history, weather: snapshot, unit: .celsius)
    }

    /// The scope's days / months / weather chips, as the narrow Query panel shows them (with weather ticked but off, to show its note).
    private struct PlayFilterHost: View {
        @State var filter: QueryPlayFilter
        var body: some View {
            VStack(alignment: .leading) {
                Toggle("Only count plays at certain times or in certain weather", isOn: .constant(true))
                PlayFilterEditor(filter: $filter)
            }
        }
    }

    @MainActor
    static func playFilter(_ filter: QueryPlayFilter) -> some View { PlayFilterHost(filter: filter) }

    // MARK: Trends › weather (made-up data)

    private static func weatherCard<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppTypography.sectionTitle)
                Text(subtitle).font(AppTypography.metadata).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
    }

    static func sampleWeatherTiles() -> [TrendsWeatherTile] {
        [
            TrendsWeatherTile(condition: .clear, perDay: 29, average: 31, playCount: 4_210, weight: 4_210, hours: 3_480),
            TrendsWeatherTile(condition: .cloudy, perDay: 31, average: 31, playCount: 6_020, weight: 6_020, hours: 4_660),
            TrendsWeatherTile(condition: .fog, perDay: 33, average: 31, playCount: 410, weight: 410, hours: 300),
            TrendsWeatherTile(condition: .rain, perDay: 38, average: 31, playCount: 3_340, weight: 3_340, hours: 2_110),
            TrendsWeatherTile(condition: .snow, perDay: 36, average: 31, playCount: 1_150, weight: 1_150, hours: 770),
            TrendsWeatherTile(condition: .thunderstorm, perDay: 22, average: 31, playCount: 14, weight: 14, hours: 15),
        ]
    }

    static func sampleWeatherGrid() -> TrendsWeatherGrid {
        let rowBias = [-0.10, 0.02, 0.08, 0.17]
        let cells: [[TrendsWeatherGrid.Cell]] = (0..<4).map { row in
            (0..<10).map { column in
                let cold = (4.5 - Double(column)) / 4.5
                let wobble = sin(Double(row * 7 + column * 3)) * 0.05
                let plays = (row == 3 && column == 9) ? 8 : 70 + (column * 13 + row * 29) % 130
                return TrendsWeatherGrid.Cell(lift: 1 + cold * 0.30 + rowBias[row] + wobble, plays: plays)
            }
        }
        return TrendsWeatherGrid(edges: [-9, -4, -1, 1.5, 4, 6.5, 9, 12, 15, 19, 27], cells: cells)
    }

    static func sampleWeatherWeeks() -> [TrendsWeatherWeek] {
        let calendar = AppCalendars.listening
        let start = calendar.date(from: DateComponents(year: 2023, month: 1, day: 2))!
        return (0..<156).map { index in
            let season = sin(2 * Double.pi * (Double(index) - 14) / 52)
            let temperature = 8 + 13 * season + sin(Double(index) * 1.7) * 2.2
            let plays = Int(200 - 3.4 * (temperature - 8) + sin(Double(index) * 0.9) * 28 + (index % 23 == 0 ? 70 : 0))
            let precipitation: TrendsWeatherWeek.Precipitation = temperature < 0.5 && index % 2 == 0 ? .snow : (index % 3 == 0 && temperature > 1 ? .rain : .none)
            return TrendsWeatherWeek(start: calendar.date(byAdding: .day, value: index * 7, to: start)!, temperature: temperature, plays: plays, precipitation: precipitation)
        }
    }

    @MainActor
    static func weatherTrends(unit: TemperatureUnit) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            weatherCard("Weather and listening", "Rainy days are your music days: 38 scrobbles a day, +23% on an average day") {
                TrendsWeatherTiles(tiles: sampleWeatherTiles())
            }
            weatherCard("Temperature and time of day", "How much more or less than usual you play, by how warm it was for your place and the time of day") {
                TrendsWeatherGridView(grid: sampleWeatherGrid(), unit: unit)
            }
            weatherCard("Listening against the weather", "Each week’s scrobbles over that week’s temperature, adjusted for nothing: the raw story") {
                TrendsWeatherTimeline(weeks: sampleWeatherWeeks(), unit: unit)
            }
        }
    }

    /// The leanings and places cards on made-up listening: four months at home (Oslo) with two trips, artists that favour rain, cold or neither.
    @MainActor
    static func leaningsAndPlaces() -> some View {
        let inputs = syntheticTrendsInputs()
        return VStack(alignment: .leading, spacing: 18) {
            weatherCard("Leaning into the weather", "The artists, albums and tracks you play more (or less) than usual in a kind of weather") {
                TrendsLeaningsCard(inputs: inputs, adjust: true, openQuery: { _, _ in })
            }
            weatherCard("Where you listened", "Your trips against home: how much you played, what was new, and the weather") {
                TrendsPlacesCard(inputs: inputs, unit: .celsius, openQuery: { _, _ in })
            }
        }
    }

    /// Made-up listening for the weather map: forty artists that each favour a kind of weather and warm or cold, over the same made-up weather.
    @MainActor
    static func weatherMapInputs() -> TrendsWeatherGroup.Inputs {
        let base = syntheticTrendsInputs()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var seed: UInt64 = 7
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double((seed >> 33) % 10_000) / 10_000 }
        var plays: [ScrobbleSnapshot] = []
        var day = calendar.startOfDay(for: base.range.from)
        while day <= base.range.to {
            for i in 0..<45 {
                let at = day.addingTimeInterval(Double(7 * 3600 + i * 1100))
                guard let sample = base.weather.sample(at: at), let condition = sample.condition, let temperature = sample.temperature else { continue }
                var weights: [Double] = []
                for artist in 0..<40 {
                    var w = 1.0 + Double(artist % 5) * 0.6
                    let likes: WeatherCondition = [.rain, .clear, .cloudy][artist % 3]
                    if condition == likes { w *= 3.2 }
                    if artist % 2 == 0 ? temperature > 12 : temperature < 6 { w *= 2.2 }
                    weights.append(w)
                }
                var pick = next() * weights.reduce(0, +)
                var chosen = 0
                for (index, weight) in weights.enumerated() { pick -= weight; if pick <= 0 { chosen = index; break } }
                let name = "Artist \(Character(UnicodeScalar(65 + chosen % 26)!))\(chosen / 26 + 1)"
                plays.append(ScrobbleSnapshot(artistName: name, albumName: "Album", trackName: "Song \(i % 5)", imageURL: nil, playedAt: at))
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        plays.sort { $0.playedAt < $1.playedAt }
        // Made-up pictures for most artists (none for the rest, so both looks show).
        var lookup: [String: String] = [:]
        let folder = FileManager.default.temporaryDirectory.appending(path: "scroblytics-map-art-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in Set(plays.map(\.artistName)).sorted().enumerated() where index % 4 != 3 {
            let image = NSImage(size: NSSize(width: 160, height: 160), flipped: false) { rect in
                NSColor(hue: CGFloat((index * 37) % 100) / 100, saturation: 0.5, brightness: 0.7, alpha: 1).setFill(); rect.fill()
                NSColor.white.withAlphaComponent(0.4).setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 45, dy: 45)).fill()
                NSColor.black.withAlphaComponent(0.25).setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: 40)).fill()
                return true
            }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let file = folder.appending(path: "\(index).png")
                try? png.write(to: file)
                lookup[ImageResolutionEngine.lookupKey(for: ImageTarget(kind: .artist, artist: name, album: nil, track: nil))] = file.absoluteString
            }
        }
        return TrendsWeatherGroup.Inputs(scrobbles: plays, canonical: plays, imageLookup: lookup, durations: .empty, weather: base.weather, range: base.range, compareRange: nil, version: 2)
    }

    @MainActor
    static func weatherMapScene(unit: TemperatureUnit) -> some View {
        weatherCard("Artist weather map", "Where your artists sit on a map of weather against temperature") {
            TrendsWeatherMapCard(inputs: weatherMapInputs(), unit: unit, adjust: false, openQuery: { _, _ in })
        }
    }

    /// Every Weather & places chart as the card it makes, from the made-up listening above, for each shape (the shared cards' own renders).
    @MainActor
    static func nativeShareCards() async -> [(name: String, card: ShareCard, images: [String: NSImage])] {
        let inputs = syntheticTrendsInputs()
        let range = inputs.range
        let result = TrendsWeatherEngine.compute(
            scrobbles: inputs.scrobbles, weather: inputs.weather, range: range, compareRange: nil, metric: .plays, durations: .empty, adjustForSeason: true
        )
        let leanings = TrendsLeaningsEngine.compute(scrobbles: inputs.canonical, weather: inputs.weather, range: range, target: .artist, choice: "Rain", adjust: true)
        let places = TrendsPlacesEngine.compute(scrobbles: inputs.canonical, weather: inputs.weather, range: range)
        let mapInputs = weatherMapInputs()
        let mapResult = TrendsWeatherMapEngine.compute(scrobbles: mapInputs.canonical, weather: mapInputs.weather, range: mapInputs.range, adjust: false)
        let natives: [(String, String, ShareNativeChart)] = [
            ("tiles", "Weather and listening", TrendsShareCharts.tiles(result: result, metric: .plays, caption: "Rain is your music weather: +23% against an average day")),
            ("grid", "Temperature and time of day", TrendsShareCharts.grid(result: result, unit: .celsius)),
            ("timeline", "Listening against the weather", TrendsShareCharts.timeline(result: result, unit: .celsius, metric: .plays)),
            ("leanings", "Leaning into the weather", TrendsShareCharts.leanings(result: leanings, choice: "Rain", target: .artist, away: false, imageLookup: inputs.imageLookup)),
            ("places", "Where you listened", TrendsShareCharts.places(result: places, unit: .celsius)),
            ("weathermap", "Artist weather map", TrendsShareCharts.weatherMap(result: mapResult, mode: .affinity, count: 25, unit: .celsius, imageLookup: mapInputs.imageLookup)),
        ]
        // The other nine Trends charts: from the same plays where an engine makes them, by hand where it needs data this made-up library lacks.
        let calendar = AppCalendars.listening
        let volume = TrendsEngine.volume(scrobbles: inputs.canonical, range: range, compareRange: nil, metric: .plays, durations: .empty)
        let heatmap = TrendsEngine.heatmap(scrobbles: inputs.canonical, range: range, compareRange: nil, metric: .plays, durations: .empty)
        let discovery = TrendsDiscoveryEngine.compute(scrobbles: inputs.canonical, range: range, compareRange: nil, metric: .plays, durations: .empty)
        let tags = TrendsTags(
            rows: [("indie rock", 940, 800), ("dream pop", 610, 700), ("folk", 480, 480), ("shoegaze", 300, 120), ("ambient", 220, nil)].map { TrendsTags.Row(tag: $0.0, plays: $0.1, comparePlays: $0.2) },
            range: range, compareRange: range, totalPlays: 2_600, taggedPlays: 2_550, pendingPlays: 50, metric: .plays, pendingRuntime: 0
        )
        let months = (0..<6).map { index -> TrendsDecadeRiver.Point in
            let start = calendar.date(byAdding: .month, value: index - 6, to: calendar.startOfDay(for: range.to))!
            return TrendsDecadeRiver.Point(index: index, start: start, from: start, to: start.addingTimeInterval(86_400 * 28), counts: [5, 12, 30 + index * 4, 60, 80 - index * 6, 120 + index * 10, 40], years: [:], pending: 0, noDate: 0)
        }
        let eras = TrendsDecadeRiver(target: .track, bucketing: .month, range: range, compareRange: nil, metric: .plays, points: months, comparePoints: nil)
        let flowEdges = [("Artist A", "Artist B", 31), ("Artist C", "Artist A", 27), ("Artist B", "Artist D", 22), ("Artist D", "Artist E", 18), ("Artist E", "Artist A", 14), ("Artist A", "Artist D", 11)]
            .map { TrendsFlow.Edge(source: $0.0, target: $0.1, count: $0.2, status: .shared, previousCount: nil) }
        let flow = TrendsFlow(granularity: .artist, gapMinutes: 30, minTransitions: 3, range: range, compareRange: nil, sessionCount: 480, totalTransitions: 2_300, nodes: [], edges: flowEdges)
        func loyaltyItems(_ names: [String]) -> [LoyaltyItem] { names.enumerated().map { LoyaltyItem(id: QueryEntityID(target: .artist, artist: $1, name: $1), plays: 90 - $0 * 9, spread: 40, value: 90 - $0 * 9) } }
        let quadrants: [(quadrant: LoyaltyQuadrant, count: Int, tops: [LoyaltyItem])] = [
            (.lifers, 41, loyaltyItems(["Artist A", "Artist B", "Artist C", "Artist D"])), (.obsessions, 18, loyaltyItems(["Artist E", "Artist F", "Artist G"])),
            (.background, 66, loyaltyItems(["Artist H", "Artist I", "Artist J", "Artist K"])), (.passing, 52, loyaltyItems(["Artist L", "Artist M"])),
        ]
        var more: [(String, String, ShareNativeChart)] = [
            ("volume", "Volume over time", TrendsShareCharts2.volume(volume: volume, metric: .plays, mode: "Per period")),
            ("heatmap", "When you listen", TrendsShareCharts2.heatmap(heatmap: heatmap, metric: .plays)),
            ("discovery", "Discovery", TrendsShareCharts2.discovery(discovery: discovery, metric: .plays)),
            ("taste", "Taste", TrendsShareCharts2.taste(tags: tags, metric: .plays)),
            ("eras", "Eras", TrendsShareCharts2.eras(data: eras, colors: [.blue, .orange, .green, .pink, .purple, .yellow, .red])),
            ("flow", "Listening flow", TrendsShareCharts2.flow(data: flow, noun: "artist", gapText: "30 min")),
            ("loyalty", "Loyalty", TrendsShareCharts2.loyalty(noun: "artists", quadrants: quadrants, population: 177, minPlays: 3, metric: .plays)),
        ]
        if let ranked = TrendsRankBumpEngine.compute(scrobbles: inputs.canonical, target: .artist, topN: 5, range: range, metric: .plays, durations: .empty), ranked.buckets.count >= 2 {
            more.append(("rankings", "Rankings", TrendsShareCharts2.rankings(data: ranked, metric: .plays)))
        }
        if let tail = TrendsLongTailEngine.compute(scrobbles: inputs.canonical, snapshots: QuerySnapshots(), target: .artist, metric: .plays, range: range), tail.stats != nil {
            more.append(("longtail", "Long tail", TrendsShareCharts2.longTail(data: tail, entity: .artist, metric: .plays, topPercent: 10)))
        }
        // The same volume chart with a comparison period (the first 60 days against the last 60), to check the comparison is left out until asked for.
        let halfway = calendar.date(byAdding: .day, value: -60, to: range.to) ?? range.to
        let lastHalf = DateRange(from: halfway, to: range.to), firstHalf = DateRange(from: range.from, to: halfway.addingTimeInterval(-1))
        let compared = TrendsEngine.volume(scrobbles: inputs.canonical, range: lastHalf, compareRange: firstHalf, metric: .plays, durations: .empty)
        more.append(("volumecompare", "Volume over time", TrendsShareCharts2.volume(volume: compared, metric: .plays, mode: "Per period")))
        var out: [(String, ShareCard, [String: NSImage])] = []
        for (slug, title, native) in natives + more {
            let card = ShareCard(title: title, period: "Last 120 days", measure: slug == "volumecompare" ? "Compared with the 60 days before" : "", rows: [], valueLabel: "", hasMovement: false, kindID: "trends.\(slug).native", native: native)
            let images = await ShareArtwork.load(card.pictureURLs(for: ShareOptions()))
            out.append((slug, card, images))
        }
        return out
    }

    @MainActor
    static func syntheticTrendsInputs() -> TrendsWeatherGroup.Inputs {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -120, to: end)!
        let startHour = WeatherSeries.hour(of: start)
        var series = WeatherSeries(startHour: startHour, count: 24 * 121)
        var rainy = Set<Int>()
        for h in startHour..<(startHour + 24 * 121) {
            let dayIndex = (h - startHour) / 24, hod = h % 24
            let isRainDay = dayIndex % 4 == 1
            if isRainDay { rainy.insert(dayIndex) }
            series.set(hour: h, WeatherSample(temperature: 4 + 10 * sin(Double(dayIndex) / 19) + Double(hod) / 6, precipitation: isRainDay ? 0.4 : 0, rain: isRainDay ? 0.4 : 0, snowfall: 0, code: isRainDay ? 61 : (dayIndex % 3 == 0 ? 3 : 0)))
        }
        var snapshot = WeatherSnapshot(series: series, placeName: "Oslo, Norway", percentiles: (20, 80))
        let lisbonPlace = WeatherPlace(name: "Lisbon, Portugal", latitude: 38.72, longitude: -9.14)
        let tripA = WeatherTrip(place: lisbonPlace, from: calendar.date(byAdding: .day, value: -40, to: end)!, until: calendar.date(byAdding: .day, value: -34, to: end)!)
        let tripB = WeatherTrip(place: WeatherPlace(name: "Tokyo, Japan", latitude: 35.68, longitude: 139.69), from: calendar.date(byAdding: .day, value: -9, to: end)!, until: nil)
        // Trips close together (the case that used to run their names into each other), then the two above.
        func nearby(_ name: String, _ lat: Double, _ from: Int, _ until: Int) -> WeatherTrip {
            WeatherTrip(place: WeatherPlace(name: name, latitude: lat, longitude: lat), from: calendar.date(byAdding: .day, value: from, to: end)!, until: calendar.date(byAdding: .day, value: until, to: end)!)
        }
        let more = [
            nearby("Paris, Île-de-France, France", 11, -104, -98), nearby("Madrid, Madrid, Spain", 12, -96, -91), nearby("Berlin, Berlin, Germany", 13, -70, -66),
            nearby("Munich, Bavaria, Germany", 14, -64, -60), nearby("Porto, Porto, Portugal", 15, -22, -17),
        ]
        for trip in [tripA, tripB] + more {
            var away = WeatherSeries(startHour: WeatherSeries.hour(of: trip.from), count: 24 * 12)
            for h in away.startHour..<(away.startHour + 24 * 12) { away.set(hour: h, WeatherSample(temperature: 19 + Double(h % 24) / 5, precipitation: 0, rain: 0, snowfall: 0, code: 0)) }
            snapshot.trips.append(WeatherSnapshot.TripWeather(trip: trip, series: away))
        }
        var plays: [ScrobbleSnapshot] = []
        let artists = ["Artist A", "Artist B", "Artist C", "Artist D", "Artist E", "Artist F"]
        for dayIndex in 0..<120 {
            let day = calendar.date(byAdding: .day, value: dayIndex, to: start)!
            let away = (dayIndex >= 80 && dayIndex < 86) || dayIndex >= 111
            let count = away ? 3 : 9
            let isRain = rainy.contains(dayIndex)
            for i in 0..<count {
                // A and B favour rainy days, C and D dry ones, E and F neither.
                let pool: [Int] = isRain ? [0, 0, 1, 1, 4, 5, 2] : [2, 2, 3, 3, 4, 5, 0]
                let artist = artists[pool[(dayIndex * 7 + i) % pool.count]]
                plays.append(ScrobbleSnapshot(artistName: artist, albumName: "Album \(artist)", trackName: "Song \(artist) \(i % 4)", imageURL: nil, playedAt: day.addingTimeInterval(Double(10 * 3600 + i * 1500))))
            }
        }
        let range = DateRange(from: start, to: end.addingTimeInterval(86_399))
        // Artwork for some artists (made-up pictures on disk), none for the rest, so both states show.
        var lookup: [String: String] = [:]
        let folder = FileManager.default.temporaryDirectory.appending(path: "scroblytics-art-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in ["Artist A", "Artist B", "Artist C"].enumerated() {
            let image = NSImage(size: NSSize(width: 120, height: 120), flipped: false) { rect in
                NSColor(hue: CGFloat(index) / 3, saturation: 0.55, brightness: 0.75, alpha: 1).setFill(); rect.fill()
                NSColor.white.withAlphaComponent(0.35).setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 30, dy: 30)).fill()
                return true
            }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let file = folder.appending(path: "\(index).png")
                try? png.write(to: file)
                lookup[ImageResolutionEngine.lookupKey(for: ImageTarget(kind: .artist, artist: name, album: nil, track: nil))] = file.absoluteString
            }
        }
        return TrendsWeatherGroup.Inputs(scrobbles: plays, canonical: plays, imageLookup: lookup, durations: .empty, weather: snapshot, range: range, compareRange: nil, version: 1)
    }

    /// Settings › Weather › Trips with two trips (one open), and the sheet that adds one. Seeds the scratch trips file.
    @MainActor
    static func tripsSettings() -> some View {
        let calendar = AppCalendars.listening
        let today = calendar.startOfDay(for: Date())
        let lisbon = WeatherPlace(name: "Lisbon, Portugal", latitude: 38.72, longitude: -9.14)
        let tokyo = WeatherPlace(name: "Tokyo, Japan", latitude: 35.68, longitude: 139.69)
        WeatherTripStore.save([
            WeatherTrip(place: lisbon, from: calendar.date(byAdding: .day, value: -3, to: today)!, until: nil),
            WeatherTrip(place: tokyo, from: calendar.date(byAdding: .day, value: -200, to: today)!, until: calendar.date(byAdding: .day, value: -190, to: today)!),
            // Shares days with the open trip to Lisbon, so both are highlighted.
            WeatherTrip(place: WeatherPlace(name: "Madrid, Madrid, Spain", latitude: 40.42, longitude: -3.70), from: calendar.date(byAdding: .day, value: -5, to: today)!, until: calendar.date(byAdding: .day, value: -1, to: today)!),
        ])
        return Form { WeatherTripsSection() }.formStyle(.grouped).frame(height: 540)
    }

    /// Tools › Trips on made-up listening: trips of each kind (a place from a search, one that is only a typed name, two that overlap, one still on).
    @MainActor
    static func tripsTool(container: ModelContainer) async -> some View {
        let calendar = AppCalendars.listening
        let today = calendar.startOfDay(for: Date())
        func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: today)! }
        // Writes trips and made-up plays, so it only runs on a scratch store that is empty, with no network (a Debug launch would
        // otherwise start importing the saved Last.fm account into it).
        let env = ProcessInfo.processInfo.environment
        let existing = (try? container.mainContext.fetchCount(FetchDescriptor<Scrobble>())) ?? -1
        guard env["SCROBLYTICS_STORE_PATH"] != nil, env["SCROBLYTICS_OFFLINE"] != nil, existing == 0 else {
            print("tripsTool snapshot refused: needs SCROBLYTICS_STORE_PATH (scratch), SCROBLYTICS_OFFLINE and an empty store (found \(existing) plays)")
            return TripsView(modelContainer: container, navigation: DetailNavigationCoordinator(origin: .tools), openQuery: { _, _, _ in })
        }
        WeatherTripStore.save([
            WeatherTrip(place: WeatherPlace(name: "Chicago, Illinois, United States", latitude: 41.9, longitude: -87.6, region: "Illinois", country: "United States"), from: day(-10), until: day(-6)),
            WeatherTrip(place: WeatherPlace(typedName: "Grandma’s house"), from: day(-25), until: day(-21)),
            WeatherTrip(place: WeatherPlace(name: "Lisbon, Portugal", latitude: 38.72, longitude: -9.14), from: day(-40), until: day(-33)),
            WeatherTrip(place: WeatherPlace(name: "Madrid, Madrid, Spain", latitude: 40.42, longitude: -3.70), from: day(-36), until: day(-30)),
            WeatherTrip(place: WeatherPlace(name: "Tokyo, Japan", latitude: 35.68, longitude: 139.69), from: day(-3), until: nil),
        ])
        let context = container.mainContext
        let artists = ["Artist A", "Artist B", "Artist C", "Artist D", "Artist E", "Artist F"]
        for offset in -60...0 {
            let plays = (-25 ... -21).contains(offset) ? 7 : ((-3...0).contains(offset) ? 2 : 4)
            for i in 0..<plays {
                let artist = artists[(offset + 60 + i) % artists.count]
                context.insert(Scrobble(artistName: artist, albumName: "Album \(artist)", trackName: "Song \(i)", imageURL: nil, playedAt: day(offset).addingTimeInterval(Double(12 * 3600 + i * 900)), lastConfirmedAt: Date()))
            }
        }
        try? context.save()
        await ScrobbleHistoryCache.shared.invalidate()
        return TripsView(modelContainer: container, navigation: DetailNavigationCoordinator(origin: .tools), openQuery: { _, _, _ in })
    }

    @MainActor
    static func tripEditor() -> some View {
        let calendar = AppCalendars.listening
        return TripEditor(draft: TripDraft.new(calendar: calendar), onSave: { _ in }, onCancel: {})
    }

    @MainActor
    static func render<Content: View>(_ content: Content, width: CGFloat, dark: Bool, container: ModelContainer, flagged: FlaggedTracksStore? = nil, settle: Int = 0, to url: URL) async {
        let view = content
            .padding(16)
            .frame(width: width)
            .modelContainer(container)
            .environment(PopularityStore())
            .environment(LovedTracksStore())
            .environment(flagged ?? FlaggedTracksStore())
            .environment(LibraryGapBadgeStore())
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: 600))
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
        let fitting = host.fittingSize
        window.setContentSize(NSSize(width: width, height: max(200, fitting.height)))
        for _ in 0..<(3 + settle) { try? await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        }
    }

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let folder = ProcessInfo.processInfo.environment["SCROBLYTICS_LAYOUT_SNAPSHOT_DETAIL"] else { return }
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let loaded = [
                DetailFact(id: "released", label: "Released", value: .text("Sep 12, 2018"), systemImage: "calendar", onEdit: {}),
                DetailFact(id: "length", label: "Length", value: .text("3:44"), corrected: true, systemImage: "clock", onEdit: {}),
                DetailFact(id: "tempo", label: "Tempo", value: .text("118 BPM"), detail: "4/4 · A minor", systemImage: "metronome", onEdit: {}),
            ]
            let waiting = [
                DetailFact(id: "released", label: "Released", value: .loading, systemImage: "calendar", onEdit: {}),
                DetailFact(id: "length", label: "Length", value: .unknown, systemImage: "clock", onEdit: {}),
                DetailFact(id: "tempo", label: "Tempo", value: .loading, systemImage: "metronome", onEdit: {}),
            ]
            let base = URL(fileURLWithPath: folder)
            for width in [1200, 900, 700, 560, 440] as [CGFloat] {
                for dark in [true, false] {
                    let mode = dark ? "dark" : "light"
                    await render(trackCard(stats: sampleStats(), facts: loaded), width: width, dark: dark, container: container, to: base.appending(path: "track-loaded-\(Int(width))-\(mode).png"))
                    await render(trackCard(stats: nil, facts: waiting), width: width, dark: dark, container: container, to: base.appending(path: "track-waiting-\(Int(width))-\(mode).png"))
                    await render(albumCard(stats: sampleStats(loved: false), turnover: .ready(sampleTurnover())), width: width, dark: dark, container: container, to: base.appending(path: "album-ready-\(Int(width))-\(mode).png"))
                    await render(albumCard(stats: sampleStats(loved: false), turnover: .ready(sampleTurnover(ambiguous: true))), width: width, dark: dark, container: container, to: base.appending(path: "album-uncertain-\(Int(width))-\(mode).png"))
                    await render(albumCard(stats: nil, turnover: .loading), width: width, dark: dark, container: container, to: base.appending(path: "album-loading-\(Int(width))-\(mode).png"))
                }
            }
            let weatherTile = EntityWeatherLean.fact(for: .leans(EntityWeatherLean.Lean(name: "Rain", lift: 1.34, count: 41, total: 120, isTemperature: false)))
            let coldTile = EntityWeatherLean.fact(for: .leans(EntityWeatherLean.Lean(name: "Cold", lift: 1.21, count: 66, total: 150, isTemperature: true)))
            for width in [900, 440] as [CGFloat] {
                for dark in [true, false] {
                    await render(artistCard(stats: sampleStats(loved: false), facts: [weatherTile].compactMap { $0 }), width: width, dark: dark, container: container, to: base.appending(path: "artist-weather-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
            await render(albumCard(stats: sampleStats(loved: false), turnover: .ready(sampleTurnover()), extraFacts: [coldTile].compactMap { $0 }), width: 900, dark: true, container: container, to: base.appending(path: "album-weather-900-dark.png"))
            for width in [1200, 700, 440] as [CGFloat] {
                await render(artistCard(stats: sampleStats(loved: false)), width: width, dark: true, container: container, to: base.appending(path: "artist-\(Int(width))-dark.png"))
                await render(artistCard(stats: nil), width: width, dark: false, container: container, to: base.appending(path: "artist-loading-\(Int(width))-light.png"))
            }
            let longTitle = "The Idler Wheel Is Wiser Than the Driver of the Screw and Whipping Cords Will Serve You More Than Ropes Will Ever Do (Deluxe Version)"
            for width in [1600, 1000, 700] as [CGFloat] {
                await render(albumCard(stats: sampleStats(loved: false), turnover: .ready(sampleTurnover()), title: longTitle), width: width, dark: true, container: container, to: base.appending(path: "album-longtitle-\(width)-dark.png".replacingOccurrences(of: ".0", with: "")))
            }
            // A flag on a track nobody played in the period (Song 5, Song 10) and on one that was (Song 2): all three show their mark.
            let flagged = FlaggedTracksStore()
            for song in ["Song 2", "Song 5", "Song 10"] { try? flagged.toggle(context: container.mainContext, artist: "Artist A", track: song, album: "Album Name") }
            for width in [1600, 1000, 700, 520] as [CGFloat] {
                for dark in [true, false] {
                    let mode = dark ? "dark" : "light"
                    await render(table(), width: width, dark: dark, container: container, flagged: flagged, to: base.appending(path: "table-\(Int(width))-\(mode).png"))
                }
            }
            for width in [900, 560, 440] as [CGFloat] {
                for dark in [true, false] {
                    let mode = dark ? "dark" : "light"
                    await render(playsList(withWeather: true), width: width, dark: dark, container: container, to: base.appending(path: "plays-weather-\(Int(width))-\(mode).png"))
                }
            }
            let chosen = QueryPlayFilter(weekdays: [0], fromHour: nil, toHour: nil, months: Season.winter.months(in: .north), weatherConditions: ["Rain", "Snow"], temperatureBands: ["Cold"])
            for width in [330, 280] as [CGFloat] {
                for dark in [true, false] {
                    await render(playFilter(chosen), width: width, dark: dark, container: container, to: base.appending(path: "playfilter-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
            // The strip that asks about a difference the recent-days re-check could not settle, for each reason, at three widths.
            let strips = VStack(spacing: 14) {
                RecheckStrip(container: container, isSyncing: false, onCheckNow: {}, pending: PendingRecheck(reason: .totalGrewMoreThanFound(grew: 14, found: 3), remoteTotal: 368_000, unexplained: 14, windowDays: 16))
                RecheckStrip(container: container, isSyncing: false, onCheckNow: {}, pending: PendingRecheck(reason: .totalFell(by: 2), remoteTotal: 24_000, unexplained: -2, windowDays: 16))
                RecheckStrip(container: container, isSyncing: false, onCheckNow: {}, pending: PendingRecheck(reason: .fewerHereThanLastfm(onThisMac: 90_412, onLastfm: 90_431), remoteTotal: 90_431, unexplained: 19, windowDays: nil))
            }
            for (width, dark) in [(1000, true), (1000, false), (640, true), (460, true)] as [(CGFloat, Bool)] {
                await render(strips, width: width, dark: dark, container: container, to: base.appending(path: "recheck-strip-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
            let mapOnly = ProcessInfo.processInfo.environment["SCROBLYTICS_SNAPSHOT_MAP_ONLY"] != nil
            for (width, dark, unit) in [(1000, true, TemperatureUnit.celsius), (1000, false, .fahrenheit), (640, true, .celsius), (440, true, .celsius)] as [(CGFloat, Bool, TemperatureUnit)] {
                await render(weatherMapScene(unit: unit), width: width, dark: dark, container: container, settle: 15, to: base.appending(path: "trends-map-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
            for key in ["50", "100"] {
                UserDefaults.standard.set(Int(key), forKey: "trends.weather.map.count")
                await render(weatherMapScene(unit: .celsius), width: 1000, dark: true, container: container, settle: 15, to: base.appending(path: "trends-map-\(key)-dark.png"))
            }
            UserDefaults.standard.set("mostPlayed", forKey: "trends.weather.map.mode")
            await render(weatherMapScene(unit: .celsius), width: 1000, dark: true, container: container, settle: 15, to: base.appending(path: "trends-map-most-dark.png"))
            UserDefaults.standard.removeObject(forKey: "trends.weather.map.mode")
            UserDefaults.standard.removeObject(forKey: "trends.weather.map.count")
            let tipInputs = weatherMapInputs()
            let tipResult = TrendsWeatherMapEngine.compute(scrobbles: tipInputs.canonical, weather: tipInputs.weather, range: tipInputs.range, adjust: false)
            if let bubble = tipResult.bubbles(mode: .affinity, count: 5).first {
                for (unit, dark) in [(TemperatureUnit.celsius, true), (.fahrenheit, false)] {
                    await render(TrendsWeatherMapTooltip(bubble: bubble, result: tipResult, rows: tipResult.rows, unit: unit).frame(width: 240), width: 300, dark: dark, container: container, settle: 15, to: base.appending(path: "trends-map-tooltip-\(dark ? "dark" : "light").png"))
                }
            }
            if mapOnly {
                // (The quick pass also renders the trips list in Settings, which the full pass does later.)
                for dark in [true, false] {
                    await render(tripsSettings(), width: 560, dark: dark, container: container, to: base.appending(path: "trips-settings-\(dark ? "dark" : "light").png"))
                }
                WeatherTripStore.save([])
                let tool = await tripsTool(container: container)
                for (width, dark) in [(1000, true), (1000, false), (600, true)] as [(CGFloat, Bool)] {
                    await render(tool, width: width, dark: dark, container: container, settle: 15, to: base.appending(path: "trips-tool-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
                // Query finding single plays, on the made-up plays and trips the tool scene just seeded.
                var playsSpec = QuerySpec(target: .scrobble)
                playsSpec.columns = ["playedAt", "playPlace", "listenNumber", "playGap"].map { QueryFieldRef($0) }
                playsSpec.sorts = [QuerySort(key: .field(QueryFieldRef("playedAt")), direction: .descending)]
                playsSpec.limit = QuerySpec.scrobbleLimit
                let request = AskQueryRequest(spec: playsSpec, action: .run)
                for (width, dark) in [(1200, true), (1200, false), (800, true)] as [(CGFloat, Bool)] {
                    let queryScene = QueryView(modelContainer: container, settings: ChartDateSettings(), isActive: true, askRequest: .constant(request))
                        .frame(width: width, height: 640)
                        .environment(TagStore())
                        .environment(AskSimilarRouter())
                        .environment(AskSuggestionStore())
                    await render(queryScene, width: width, dark: dark, container: container, settle: 25, to: base.appending(path: "query-scrobbles-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
                WeatherTripStore.save([])
                for (name, card, images) in await nativeShareCards() where name == "weathermap" {
                    for size in ShareSize.allCases {
                        var options = card.defaultOptions
                        options.size = size
                        if let png = ShareRenderer.png(card: card, options: options, identity: ShareIdentity(name: nil, showsFooter: true), images: images, scale: 1) {
                            try? png.write(to: base.appending(path: "share-native-\(name)-\(size.rawValue).png"))
                        }
                    }
                }
                exit(0)
            }
            for dark in [true, false] {
                await render(weatherTrends(unit: .celsius), width: 1000, dark: dark, container: container, to: base.appending(path: "trends-weather-\(dark ? "dark" : "light").png"))
            }
            UserDefaults.standard.set("country", forKey: "trends.places.level")
            await render(leaningsAndPlaces(), width: 1000, dark: true, container: container, to: base.appending(path: "trends-new-country-1000-dark.png"))
            UserDefaults.standard.set("region", forKey: "trends.places.level")
            await render(leaningsAndPlaces(), width: 1000, dark: true, container: container, to: base.appending(path: "trends-new-region-1000-dark.png"))
            UserDefaults.standard.removeObject(forKey: "trends.places.level")
            for (width, dark) in [(1000, true), (1000, false), (640, true)] as [(CGFloat, Bool)] {
                await render(leaningsAndPlaces(), width: width, dark: dark, container: container, to: base.appending(path: "trends-new-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
            for (name, card, images) in await nativeShareCards() {
                for size in ShareSize.allCases {
                    var options = card.defaultOptions
                    options.size = size
                    if let png = ShareRenderer.png(card: card, options: options, identity: ShareIdentity(name: nil, showsFooter: true), images: images, scale: 1) {
                        try? png.write(to: base.appending(path: "share-native-\(name)-\(size.rawValue).png"))
                    }
                }
            }
            await render(weatherTrends(unit: .fahrenheit), width: 640, dark: true, container: container, to: base.appending(path: "trends-weather-640-dark.png"))
            for dark in [true, false] {
                await render(tripsSettings(), width: 560, dark: dark, container: container, to: base.appending(path: "trips-settings-\(dark ? "dark" : "light").png"))
            }
            await render(tripEditor(), width: 480, dark: true, container: container, to: base.appending(path: "trip-editor-dark.png"))
            WeatherTripStore.save([])
            await render(playsList(withWeather: false), width: 700, dark: true, container: container, to: base.appending(path: "plays-plain-700-dark.png"))
            await render(table(longAlbum: true), width: 900, dark: true, container: container, to: base.appending(path: "table-long-900-dark.png"))
            exit(0)
        }
    }
}
#endif
