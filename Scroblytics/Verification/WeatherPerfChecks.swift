import Foundation
import SwiftData
import SwiftUI

#if DEBUG
/// `SCROBLYTICS_WEATHERPERF_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): how long the weather features take on a very large,
/// very long history. Twenty years of made-up hourly weather for a home place and three trips, and 400,000 made-up plays across them, run
/// through the weather play filter and fields, the Trends cards (tiles, grid, timeline, leanings, places), a city filter, and the share
/// cards drawn from them. Each step has a generous ceiling so a regression shows up as a failure, not just a slower number.
/// With `SCROBLYTICS_WEATHERPERF_REAL=1` the same steps also run on the plays in the store and the weather saved beside it (a copy of a
/// real library): the numbers that matter. Exits 0 on success.
enum WeatherPerfChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        guard env["SCROBLYTICS_WEATHERPERF_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            // For a copy of a real library whose history is longer than the weather saved beside it: download what is missing (from Open-Meteo, as
            // Update Now does) into the scratch folder, home place first, then each trip. Only on request, and it is the only thing that goes online.
            if env["SCROBLYTICS_WEATHERPERF_DOWNLOAD"] != nil {
                ConnectivityGate.set(offline: false)
                do {
                    guard let place = WeatherSettings.place(), let firstPlay = try await TopChartsEngine.fetchOldestScrobbleDate(container: container) else { print("PERF download: no home place or no plays"); exit(1) }
                    let started = Date()
                    var requests = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, client: WeatherClient(), files: WeatherFiles()).requests
                    for trip in WeatherTripStore.load() where trip.from <= Date() {
                        requests += try await WeatherUpdater.update(place: trip.place, firstPlay: trip.from, through: trip.until, client: WeatherClient(), files: WeatherFiles(directory: WeatherTripStore.cacheDirectory(for: trip))).requests
                    }
                    print("PERF download: \(requests) requests for plays since \(firstPlay.formatted(date: .abbreviated, time: .omitted)) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                } catch { print("PERF download failed: \(error)"); exit(1) }
                ConnectivityGate.set(offline: true)
            }
            let (plays, weather) = synthetic()
            print("PERF synthetic: \(plays.count.formatted()) plays over \(years) years, \(weather.climateTemperatures.count.formatted()) hours of weather, resident \(residentMB()) MB")
            run("synthetic", plays: plays, weather: weather, check: check)
            if env["SCROBLYTICS_WEATHERPERF_REAL"] != nil {
                let real = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
                let snapshot = await QuerySnapshotReader.loadAll(container: container)
                print("PERF real: \(real.count.formatted()) plays, \(snapshot.weather.climateTemperatures.count.formatted()) hours of weather, \(snapshot.weather.trips.count) trips, resident \(residentMB()) MB")
                if real.isEmpty || snapshot.weather.isEmpty {
                    print("PERF real: nothing to measure (no plays or no weather beside the store)")
                } else {
                    run("real", plays: real, weather: snapshot.weather, check: check)
                }
            }
            print("PERF done, resident \(residentMB()) MB")
            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static let years = 20
    private static let playCount = 400_000

    private static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    /// Twenty years of weather (home plus three trips) and 400,000 plays, the same every run.
    private static func synthetic() -> ([ScrobbleSnapshot], WeatherSnapshot) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .year, value: -years, to: end)!
        let startHour = WeatherSeries.hour(of: start), hours = WeatherSeries.hour(of: end) - startHour
        var series = WeatherSeries(startHour: startHour, count: hours)
        for h in startHour..<(startHour + hours) {
            let day = Double(h - startHour) / 24, hod = Double(h % 24)
            let temperature = 10 + 11 * sin((day - 100) / 365.25 * 2 * .pi) + 4 * sin((hod - 9) / 24 * 2 * .pi)
            let wet = ((h / 7) % 11 == 0) || ((h / 5) % 17 == 0)
            series.set(hour: h, WeatherSample(temperature: temperature, precipitation: wet ? 0.4 : 0, rain: wet ? 0.4 : 0, snowfall: 0, code: wet ? 61 : (h % 5 == 0 ? 3 : 0)))
        }
        var snapshot = WeatherSnapshot(series: series, placeName: "Home City, Country", percentiles: (20, 80))
        for (index, name) in ["Trip One", "Trip Two", "Trip Three"].enumerated() {
            let from = calendar.date(byAdding: .day, value: -(900 + index * 1_100), to: end)!
            let trip = WeatherTrip(place: WeatherPlace(name: "\(name), Country", latitude: 10 + Double(index), longitude: 20 + Double(index)), from: from, until: calendar.date(byAdding: .day, value: 8, to: from)!)
            var away = WeatherSeries(startHour: WeatherSeries.hour(of: from), count: 24 * 8)
            for h in away.startHour..<(away.startHour + 24 * 8) { away.set(hour: h, WeatherSample(temperature: 22 + Double(h % 24) / 4, precipitation: 0, rain: 0, snowfall: 0, code: 0)) }
            snapshot.trips.append(WeatherSnapshot.TripWeather(trip: trip, series: away))
        }
        var seed: UInt64 = 42
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        let span = end.timeIntervalSince(start)
        var plays: [ScrobbleSnapshot] = []
        plays.reserveCapacity(playCount)
        for _ in 0..<playCount {
            let artist = Int(pow(next(), 2.5) * 3_000), track = Int(next() * 8)
            plays.append(ScrobbleSnapshot(
                artistName: "Artist \(artist)", albumName: "Album \(artist)-\(track % 3)", trackName: "Track \(artist)-\(track)", imageURL: nil,
                playedAt: start.addingTimeInterval(next() * span)
            ))
        }
        plays.sort { $0.playedAt < $1.playedAt }
        return (plays, snapshot)
    }

    /// Times each step and fails it if it takes longer than `limit` seconds.
    @MainActor
    private static func run(_ name: String, plays: [ScrobbleSnapshot], weather: WeatherSnapshot, check report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func timed<T>(_ label: String, limit: Double, _ body: () -> T) -> T {
            let started = Date()
            let value = body()
            let seconds = Date().timeIntervalSince(started)
            print("PERF \(name): \(label) \(String(format: "%.2f", seconds)) s (resident \(residentMB()) MB)")
            check("\(name): \(label) within \(Int(limit)) s", seconds < limit, String(format: "%.2f s", seconds))
            return value
        }
        let first = plays.first?.playedAt ?? Date(), last = Date()
        let all = DateRange(from: first, to: last)
        let year = DateRange(from: last.addingTimeInterval(-365 * 86_400), to: last)

        _ = timed("sampling the weather of every play", limit: 8) { plays.reduce(0) { $0 + (weather.sample(at: $1.playedAt) == nil ? 0 : 1) } }
        _ = timed("naming the city of every play", limit: 8) { plays.reduce(0) { $0 + (weather.city(at: $1.playedAt) == nil ? 0 : 1) } }
        // Weather is saved a year at a time (a file holds at most two years of hours), so twenty years are twenty files read back and joined.
        let joined = timed("saving and reading twenty years of weather, a year per file", limit: 4) { () -> Int in
            guard let series = weather.series else { return -1 }
            let yearHours = 8_760 * 2
            var files: [WeatherSeries] = []
            var offset = 0
            while offset < series.count {
                let hours = min(yearHours, series.count - offset)
                var part = WeatherSeries(startHour: series.startHour + offset, count: hours)
                for h in 0..<hours { if let sample = series.sample(hour: series.startHour + offset + h) { part.set(hour: series.startHour + offset + h, sample) } }
                if let again = WeatherSeries(data: part.encoded()) { files.append(again) }
                offset += hours
            }
            return WeatherSeries.merged(files)?.count ?? -1
        }
        check("\(name): the weather survives saving and reading", joined == weather.series?.count, "\(joined) of \(weather.series?.count ?? 0)")

        // The play filter and fields, through the same engine Query uses.
        func evaluate(_ spec: QuerySpec, target: QueryTarget) -> Int {
            var spec = spec
            spec.columns = [QueryFieldRef("plays")]
            guard let validated = try? spec.validate(against: .standard) else { return -1 }
            var snapshots = QuerySnapshots(); snapshots.weather = weather
            let counted = spec.countedPlays(plays, weather: weather)
            let run = QueryRun(target: target, asOf: Date(), scrobbles: counted, allTimeScrobbles: plays, snapshots: snapshots)
            return QueryEngine.evaluate(validated, run: run).matchedCount
        }
        var rainy = QuerySpec(target: .track)
        rainy.playFilter = QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil, months: nil, weatherConditions: ["Rain"], temperatureBands: ["Cold"])
        rainy.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
        rainy.limit = 10
        let matched = timed("top 10 tracks played in cold rain", limit: 10) { evaluate(rainy, target: .track) }
        check("\(name): that query found something", matched > 0, "\(matched)")
        var city = QuerySpec(target: .artist)
        city.playFilter = QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil, months: nil, cities: weather.cities.dropFirst().prefix(1).map { $0 })
        city.sorts = rainy.sorts
        city.limit = 10
        _ = timed("top artists played in a trip's city", limit: 10) { evaluate(city, target: .artist) }
        var lifted = QuerySpec(target: .artist)
        lifted.groups = [[QueryCondition("plays", .greaterThanOrEqual, [.number(50)])]]
        lifted.sorts = [QuerySort(key: .field(QueryFieldRef("weatherLift", parameters: ["weather": .text("Rain")])), direction: .descending)]
        lifted.limit = 10
        lifted.columns = [QueryFieldRef("plays"), QueryFieldRef("weatherLift", parameters: ["weather": .text("Rain")]), QueryFieldRef("playCity")]
        _ = timed("artists sorted by their weather lift, with City", limit: 12) {
            guard let validated = try? lifted.validate(against: .standard) else { return -1 }
            var snapshots = QuerySnapshots(); snapshots.weather = weather
            let run = QueryRun(target: .artist, asOf: Date(), scrobbles: plays, allTimeScrobbles: plays, snapshots: snapshots)
            return QueryEngine.evaluate(validated, run: run).matchedCount
        }

        // The Trends cards.
        let result = timed("the weather cards (tiles, grid, timeline) over the whole history", limit: 12) {
            TrendsWeatherEngine.compute(scrobbles: plays, weather: weather, range: all, compareRange: nil, metric: .plays, durations: .empty, adjustForSeason: true)
        }
        check("\(name): the weather cards have something to draw", result.hasWeather && !result.tiles.isEmpty && !result.buckets.isEmpty)
        _ = timed("the weather cards for the last year, compared with the year before", limit: 12) {
            TrendsWeatherEngine.compute(scrobbles: plays, weather: weather, range: year, compareRange: DateRange(from: year.from.addingTimeInterval(-365 * 86_400), to: year.from.addingTimeInterval(-1)), metric: .plays, durations: .empty, adjustForSeason: true)
        }
        let leanings = timed("leaning into the weather, artists", limit: 12) {
            TrendsLeaningsEngine.compute(scrobbles: plays, weather: weather, range: all, target: .artist, choice: "Rain", adjust: true)
        }
        _ = timed("leaning into the weather, tracks", limit: 12) {
            TrendsLeaningsEngine.compute(scrobbles: plays, weather: weather, range: all, target: .track, choice: "Hot", adjust: true)
        }
        let places = timed("where you listened over the whole history", limit: 12) {
            TrendsPlacesEngine.compute(scrobbles: plays, weather: weather, range: all)
        }
        check("\(name): the places card finds the trips", weather.trips.isEmpty || !places.trips.isEmpty)

        // The shared cards drawn from them.
        let cards: [(String, ShareNativeChart)] = [
            ("tiles", TrendsShareCharts.tiles(result: result, metric: .plays, caption: "Caption")),
            ("grid", TrendsShareCharts.grid(result: result, unit: .celsius)),
            ("timeline", TrendsShareCharts.timeline(result: result, unit: .celsius, metric: .plays)),
            ("leanings", TrendsShareCharts.leanings(result: leanings, choice: "Rain", target: .artist, away: false, imageLookup: [:])),
            ("places", TrendsShareCharts.places(result: places, unit: .celsius)),
        ]
        for (slug, native) in cards {
            let card = ShareCard(title: slug, period: "All time", measure: "", rows: [], valueLabel: "", hasMovement: false, kindID: "perf.\(slug)", native: native)
            let png = timed("drawing the \(slug) card (2x, \(card.defaultOptions.size.label))", limit: 6) { ShareRenderer.png(card: card, options: card.defaultOptions, identity: .anonymous, images: [:]) }
            check("\(name): the \(slug) card is drawn", (png?.count ?? 0) > 5_000)
        }
        if ProcessInfo.processInfo.environment["SCROBLYTICS_WEATHERPERF_LEAKS"] != nil {
            for (slug, native) in cards {
                let card = ShareCard(title: slug, period: "All time", measure: "", rows: [], valueLabel: "", hasMovement: false, kindID: "perf.leak.\(slug)", native: native)
                for scale in [0.8, 2.0] as [CGFloat] {
                    var sizes: [Int] = []
                    for index in 0..<8 {
                        var options = card.defaultOptions
                        options.flags["caption"] = index % 2 == 0
                        autoreleasepool { _ = ShareRenderer.nsImage(card: card, options: options, identity: .anonymous, images: [:], scale: scale) }
                        sizes.append(residentMB())
                    }
                    print("LEAK \(slug) scale \(scale): \(sizes[0]) -> \(sizes[7]) MB, per redraw \((sizes[7] - sizes[1]) / 6) MB")
                }
            }
        }
        if ProcessInfo.processInfo.environment["SCROBLYTICS_WEATHERPERF_LEAKS"] != nil, let native = cards.first(where: { $0.0 == "timeline" })?.1 {
            let card = ShareCard(title: "t", period: "All time", measure: "", rows: [], valueLabel: "", hasMovement: false, kindID: "perf.leak.png", native: native)
            func viaPNG() { _ = ShareRenderer.png(card: card, options: card.defaultOptions, identity: .anonymous, images: [:]) }
            func viaCGImage() {
                let renderer = ImageRenderer(content: ShareCardView(card: card, options: card.defaultOptions, identity: .anonymous, images: [:]))
                renderer.proposedSize = ProposedViewSize(card.defaultOptions.size.points)
                renderer.scale = 2
                if let cg = renderer.cgImage { _ = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) }
            }
            func imageOnly() { _ = ShareRenderer.nsImage(card: card, options: card.defaultOptions, identity: .anonymous, images: [:], scale: 2) }
            func tiffOnly() { _ = ShareRenderer.nsImage(card: card, options: card.defaultOptions, identity: .anonymous, images: [:], scale: 2)?.tiffRepresentation }
            for (label, work) in [("png() as it is", viaPNG), ("via cgImage", viaCGImage), ("image only", imageOnly), ("image + tiff", tiffOnly)] as [(String, () -> Void)] {
                var sizes: [Int] = []
                for _ in 0..<8 { autoreleasepool { work() }; sizes.append(residentMB()) }
                print("LEAK2 \(label): \(sizes[0]) -> \(sizes[7]) MB, per redraw \((sizes[7] - sizes[1]) / 6) MB")
            }
        }
        // Drawing the same card over and over (changing an option in the preview does this) must not keep growing the process.
        if let native = cards.first(where: { $0.0 == "timeline" })?.1 {
            let card = ShareCard(title: "timeline", period: "All time", measure: "", rows: [], valueLabel: "", hasMovement: false, kindID: "perf.repeat", native: native)
            var sizes: [Int] = []
            for index in 0..<12 {
                var options = card.defaultOptions
                options.flags["markers"] = index % 2 == 0
                // One pool per redraw, as each redraw in the app is its own pass of the run loop; a tight loop with none holds every picture.
                autoreleasepool { _ = ShareRenderer.png(card: card, options: options, identity: .anonymous, images: [:]) }
                sizes.append(residentMB())
            }
            print("PERF \(name): resident MB over 12 redraws of one card: \(sizes)")
            check("\(name): twelve redraws of one card grow the process by under 250 MB after the first three", sizes[11] - sizes[2] < 250, "\(sizes[2]) to \(sizes[11]) MB")
        }
    }
}
#endif
