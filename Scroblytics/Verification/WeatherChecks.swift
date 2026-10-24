import Foundation

#if DEBUG
/// `SCROBLYTICS_WEATHER_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): matching listening with the weather, on made-up data
/// and a stand-in for the weather service. Covers the place and settings, reading the service's answers, the packed hours and their
/// files, the download plan (which requests are made and which are not), what each request contains, failures, the hot/cold cut-offs, and
/// the Query fields against hand-worked values. No network. Exits 0 on success.
enum WeatherChecks {
    @MainActor
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_WEATHER_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            basics(check)
            await download(check)
            fields(check)
            trends(check)
            await tripChecks(check)
            leanChecks(check)
            leaningChecks(check)
            mapChecks(check)
            placeChecks(check)
            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static let utc: Calendar = WeatherClientCalendar.utc

    private static func hour(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Int {
        WeatherSeries.hour(of: utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!)
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// The weather the stand-in service "had" at an hour: a temperature that follows the hour of the day, rain at 6–8, snow at 20–21,
    /// and no temperature at all every 97th hour.
    private static func weather(atHour h: Int) -> WeatherSample {
        let hod = ((h % 24) + 24) % 24
        let code = (6...8).contains(hod) ? 61 : (20...21).contains(hod) ? 71 : 0
        return WeatherSample(temperature: h % 97 == 0 ? nil : Double(hod) - 2, precipitation: code == 61 ? 0.5 : 0, rain: code == 61 ? 0.5 : 0, snowfall: code == 71 ? 0.3 : 0, code: code)
    }

    // MARK: - Places, settings, answers, hours, files

    @MainActor
    private static func basics(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }

        // The place: rounded at once, so nothing finer is ever kept.
        let oslo = WeatherPlace(name: "Oslo", latitude: 59.91273, longitude: 10.74609)
        check("a place rounds its coordinates to one decimal place", oslo.latitude == 59.9 && oslo.longitude == 10.7 && oslo.key == "59.9_10.7", oslo.key)
        let south = WeatherPlace(name: "Sydney", latitude: -33.87, longitude: 151.21)
        check("southern and western coordinates round and label correctly", south.latitude == -33.9 && south.coordinateLabel == "33.9° S, 151.2° E", south.coordinateLabel)
        check("a coordinate that rounds to zero has no minus sign in its folder name", WeatherPlace(name: "x", latitude: -0.04, longitude: 0.04).key == "0.0_0.0")
        check("only real coordinates are valid", WeatherPlace.isValid(latitude: 90, longitude: -180) && !WeatherPlace.isValid(latitude: 91, longitude: 0) && !WeatherPlace.isValid(latitude: 0, longitude: 181))

        // Settings.
        let defaults = UserDefaults(suiteName: "weather-check-\(UUID().uuidString)")!
        check("weather is off until turned on, with no place", !WeatherSettings.isEnabled(defaults: defaults) && WeatherSettings.place(defaults: defaults) == nil)
        WeatherSettings.setPlace(oslo, defaults: defaults)
        check("a place is remembered and can be removed", WeatherSettings.place(defaults: defaults) == oslo && { WeatherSettings.setPlace(nil, defaults: defaults); return WeatherSettings.place(defaults: defaults) == nil }())
        check("hot and cold default to the coldest and warmest 20%", WeatherSettings.percentiles(defaults: defaults) == (20, 80))
        defaults.set(10, forKey: WeatherSettings.coldPercentileKey); defaults.set(90, forKey: WeatherSettings.hotPercentileKey)
        check("chosen percentages are used", WeatherSettings.percentiles(defaults: defaults) == (10, 90))
        defaults.set(60, forKey: WeatherSettings.coldPercentileKey); defaults.set(70, forKey: WeatherSettings.hotPercentileKey)
        check("crossed or out-of-range percentages fall back to the defaults", WeatherSettings.percentiles(defaults: defaults) == (20, 80))

        // Celsius or Fahrenheit.
        check("temperatures convert: 0 °C is 32 °F, 100 °C is 212 °F, −40 is the same in both, 37.5 °C is 99.5 °F",
              TemperatureUnit.fahrenheit.fromCelsius(0) == 32 && TemperatureUnit.fahrenheit.fromCelsius(100) == 212 && TemperatureUnit.fahrenheit.fromCelsius(-40) == -40 && TemperatureUnit.fahrenheit.fromCelsius(37.5) == 99.5)
        check("Celsius shows the number as it is", TemperatureUnit.celsius.fromCelsius(21.4) == 21.4)
        check("Automatic is Fahrenheit for US measurements and Celsius for metric and UK; a chosen unit ignores the region",
              TemperatureUnit.automatic.resolved(system: .us) == .fahrenheit && TemperatureUnit.automatic.resolved(system: .metric) == .celsius && TemperatureUnit.automatic.resolved(system: .uk) == .celsius
                && TemperatureUnit.celsius.resolved(system: .us) == .celsius && TemperatureUnit.fahrenheit.resolved(system: .metric) == .fahrenheit)
        let unitDefaults = UserDefaults(suiteName: "weather-unit-\(UUID().uuidString)")!
        check("the unit is Automatic until chosen, follows the choice, and an unknown saved value is Automatic",
              WeatherSettings.chosenTemperatureUnit(defaults: unitDefaults) == .automatic && WeatherSettings.temperatureUnit(defaults: unitDefaults, system: .us) == .fahrenheit
                && { unitDefaults.set("celsius", forKey: WeatherSettings.temperatureUnitKey); return WeatherSettings.temperatureUnit(defaults: unitDefaults, system: .us) == .celsius }()
                && { unitDefaults.set("kelvin", forKey: WeatherSettings.temperatureUnitKey); return WeatherSettings.chosenTemperatureUnit(defaults: unitDefaults) == .automatic }())
        let shownC = TemperatureUnit.celsius.text(celsius: 21.4), shownF = TemperatureUnit.fahrenheit.text(celsius: 21.4)
        check("a temperature reads with its symbol, rounded for whole degrees", shownC == "21 °C" && shownF == "71 °F", "\(shownC) \(shownF)")
        check("a number already in the unit keeps its decimal and symbol", TemperatureUnit.celsius.text(shown: 12.34, places: 1).hasPrefix("12") && TemperatureUnit.celsius.text(shown: 12.34, places: 1).hasSuffix(" °C") && TemperatureUnit.fahrenheit.text(shown: 54.1, places: 1).hasSuffix(" °F"))

        // How a play's weather reads in a list.
        let rainy = WeatherSample(temperature: 8.3, precipitation: 0.5, rain: 0.5, snowfall: 0, code: 61)
        check("a play's weather reads as the condition and the temperature in the chosen unit",
              rainy.summary(unit: .celsius) == "Rain · 8 °C" && rainy.summary(unit: .fahrenheit) == "Rain · 47 °F", "\(String(describing: rainy.summary(unit: .celsius))) \(String(describing: rainy.summary(unit: .fahrenheit)))")
        check("with only a temperature or only a condition it shows what is known; with neither, nothing",
              WeatherSample(temperature: 2, precipitation: nil, rain: nil, snowfall: nil, code: nil).summary(unit: .celsius) == "2 °C"
                && WeatherSample(temperature: nil, precipitation: nil, rain: nil, snowfall: nil, code: 71).summary(unit: .celsius) == "Snow"
                && WeatherSample(temperature: nil, precipitation: nil, rain: nil, snowfall: nil, code: nil).summary(unit: .celsius) == nil)
        check("each condition has its own symbol", Set(WeatherCondition.allCases.map(\.symbolName)).count == WeatherCondition.allCases.count && WeatherCondition.rain.symbolName == "cloud.rain")
        var listed = WeatherSeries(startHour: hour(2025, 1, 1), count: 24)
        listed.set(hour: hour(2025, 1, 1, 5), rainy)
        let listSnapshot = WeatherSnapshot(series: listed, placeName: "Oslo, Norway", percentiles: (20, 80))
        check("the location of a play is the short home place, and only where there is weather for it",
              listSnapshot.locationName(at: date(2025, 1, 1, 5, 40)) == "Oslo" && listSnapshot.locationName(at: date(2025, 1, 1, 6)) == nil && listSnapshot.locationName(at: date(2024, 6, 1)) == nil)
        check("with no place name there is no location", WeatherSnapshot(series: listed, placeName: nil, percentiles: (20, 80)).locationName(at: date(2025, 1, 1, 5)) == nil)

        // Conditions from the service's codes.
        let table: [Int: WeatherCondition] = [0: .clear, 1: .clear, 2: .cloudy, 3: .cloudy, 45: .fog, 48: .fog, 51: .rain, 53: .rain, 55: .rain, 56: .rain, 57: .rain,
                                              61: .rain, 63: .rain, 65: .rain, 66: .rain, 67: .rain, 71: .snow, 73: .snow, 75: .snow, 77: .snow, 80: .rain, 81: .rain, 82: .rain,
                                              85: .snow, 86: .snow, 95: .thunderstorm, 96: .thunderstorm, 99: .thunderstorm]
        check("every weather code maps to the right condition", table.allSatisfy { WeatherCondition(code: $0.key) == $0.value })
        check("an unknown or missing code is no condition", WeatherCondition(code: 4) == nil && WeatherCondition(code: 100) == nil && WeatherCondition(code: nil) == nil)

        // Times.
        let sampleDays = stride(from: 0, to: 47_000, by: 37).map { Date(timeIntervalSince1970: Double($0) * 86_400 + 5 * 3600) }
        check("a service time converts to the same hour as the calendar does, across 130 years",
              sampleDays.allSatisfy { d in
                  let parts = utc.dateComponents([.year, .month, .day, .hour], from: d)
                  let text = String(format: "%04d-%02d-%02dT%02d:00", parts.year!, parts.month!, parts.day!, parts.hour!)
                  return WeatherClient.hourNumber(text) == WeatherSeries.hour(of: d)
              })
        check("the start of 1970 is hour 0, and a leap day is read", WeatherClient.hourNumber("1970-01-01T00:00") == 0 && WeatherClient.hourNumber("2024-02-29T13:00") == hour(2024, 2, 29, 13))
        check("a malformed time is refused", WeatherClient.hourNumber("2024-13-01T00:00") == nil && WeatherClient.hourNumber("yesterday") == nil)

        // Answers.
        let answer = Data(#"{"hourly":{"time":["2024-01-01T00:00","2024-01-01T01:00","2024-01-01T02:00"],"temperature_2m":[-3.4,null,2.0],"precipitation":[0.0,0.2,null],"rain":[0,0.2,null],"snowfall":[0.0,0.0,null],"weather_code":[3,61.0,null]}}"#.utf8)
        let parsed = try? WeatherClient.parseHourly(answer)
        check("an hourly answer is read, with nulls kept as no value",
              parsed?.count == 3 && parsed?[0].sample.temperature == -3.4 && parsed?[1].sample.temperature == nil && parsed?[1].sample.condition == .rain && parsed?[2].sample.code == nil && parsed?[0].hour == hour(2024, 1, 1), "\(String(describing: parsed))")
        check("an answer that isn't weather is refused, not read as 'no weather'", (try? WeatherClient.parseHourly(Data("{}".utf8))) == nil && (try? WeatherClient.parseHourly(Data(#"{"hourly":{"time":["soon"]}}"#.utf8))) == nil)
        let search = Data(#"{"results":[{"name":"Oslo","latitude":59.91273,"longitude":10.74609,"country":"Norway","admin1":"Oslo","population":1000},{"name":"Oslo","latitude":48.2,"longitude":-97.1,"country":"United States","admin1":"Minnesota"},{"name":"Nowhere","latitude":120,"longitude":0}]}"#.utf8)
        let found = try? WeatherClient.parseSearch(search)
        check("a search answer lists real places, labelled without repeating a part, and drops impossible coordinates",
              found?.map(\.label) == ["Oslo, Norway", "Oslo, Minnesota, United States"] && found?.first?.place.key == oslo.key && found?.first?.place.name == "Oslo, Norway", "\(String(describing: found?.map(\.label)))")
        check("a search with no results is an empty list", (try? WeatherClient.parseSearch(Data("{\"generationtime_ms\":0.1}".utf8)))?.isEmpty == true)

        // The hours, packed.
        var series = WeatherSeries(startHour: 100, count: 48)
        series.coveredThroughHour = 130
        for h in 100..<148 { series.set(hour: h, weather(atHour: h)) }
        check("an hour reads back what was set, to a tenth", series.sample(hour: 107)?.temperature == Double((107 % 24) - 2) && series.sample(hour: 102)?.condition == .rain && series.sample(hour: 140)?.snowfall == 0.3, "\(String(describing: series.sample(hour: 140)))")
        check("hours outside the run have no weather", series.sample(hour: 99) == nil && series.sample(hour: 148) == nil)
        var gap = WeatherSeries(startHour: 190, count: 10)
        for h in 190..<200 { gap.set(hour: h, weather(atHour: h)) }
        check("an hour with no temperature keeps its other values and has no temperature", gap.sample(hour: 194)?.temperature == nil && gap.sample(hour: 194)?.condition != nil && gap.sample(hour: 195)?.temperature != nil)
        let restored = WeatherSeries(data: series.encoded())
        check("a series saves and loads exactly, including how far it is covered", restored == series && restored?.coveredThroughHour == 130)
        var fresh = WeatherSeries(startHour: 0, count: 5)
        check("a new series is empty and not covered", fresh.sample(hour: 2) == nil && fresh.coveredThroughHour == Int.min && WeatherSeries(data: fresh.encoded())?.coveredThroughHour == Int.min)
        fresh.set(hour: 2, WeatherSample(temperature: 99_999, precipitation: nil, rain: nil, snowfall: nil, code: 3))
        check("an absurd temperature is clamped, not wrapped", (fresh.sample(hour: 2)?.temperature ?? 0) == 300)
        let encoded = series.encoded()
        check("damaged files are refused rather than read as weather", WeatherSeries(data: encoded.dropLast(3)) == nil && WeatherSeries(data: Data([1, 2, 3])) == nil && WeatherSeries(data: Data("XXXX".utf8) + encoded.dropFirst(4)) == nil)
        var next = WeatherSeries(startHour: 148, count: 24)
        for h in 148..<172 { next.set(hour: h, weather(atHour: h)) }
        let merged = WeatherSeries.merged([next, series])
        check("years laid end to end read as one", merged?.startHour == 100 && merged?.count == 72 && merged?.sample(hour: 150)?.temperature == weather(atHour: 150).temperature && merged?.sample(hour: 110) == series.sample(hour: 110))

        // Files.
        let folder = FileManager.default.temporaryDirectory.appending(path: "scroblytics-weather-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = WeatherFiles(directory: folder)
        files.save(series, place: oslo, year: 2024)
        check("a saved year loads back and can be seen in the timeline", files.load(oslo, year: 2024) == series && files.timeline(oslo)?.startHour == 100 && files.bytesOnDisk > 400)
        check("another place has nothing", files.timeline(south) == nil)
        files.removeAll()
        check("removing the weather deletes every file", files.timeline(oslo) == nil && files.bytesOnDisk == 0)

        // Snapshots and the hot/cold cut-offs.
        var uniform = WeatherSeries(startHour: hour(2025, 1, 1), count: 240)
        for h in uniform.startHour..<(uniform.startHour + 240) { uniform.set(hour: h, WeatherSample(temperature: Double(h % 24), precipitation: 0, rain: 0, snowfall: 0, code: 0)) }
        let snapshot = WeatherSnapshot(series: uniform, placeName: "Test", percentiles: (20, 80))
        check("with 240 hours spread evenly over 0–23°, the coldest 20% end at 4° and the warmest 20% begin at 19°", snapshot.coldAtOrBelow == 4 && snapshot.hotAtOrAbove == 19, "\(String(describing: snapshot.coldAtOrBelow)) \(String(describing: snapshot.hotAtOrAbove))")
        let counts = TemperatureBand.allCases.map { band in uniform.temperatures.filter { snapshot.band(for: WeatherSample(temperature: $0, precipitation: nil, rain: nil, snowfall: nil, code: nil)) == band }.count }
        check("that makes the coldest 20% cold and the warmest 20% hot (50 hours each, because every hour at the cut-off temperature goes with it), the rest mild", counts == [50, 140, 50], "\(counts)")
        let wider = WeatherSnapshot(series: uniform, placeName: nil, percentiles: (10, 90))
        check("changing the percentages moves the cut-offs", wider.coldAtOrBelow == 2 && wider.hotAtOrAbove == 21, "\(String(describing: wider.coldAtOrBelow)) \(String(describing: wider.hotAtOrAbove))")
        check("no temperature, no band", snapshot.band(for: WeatherSample(temperature: nil, precipitation: nil, rain: nil, snowfall: nil, code: 0)) == nil)

        let loadFolder = FileManager.default.temporaryDirectory.appending(path: "scroblytics-weather-load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: loadFolder) }
        let loadFiles = WeatherFiles(directory: loadFolder)
        loadFiles.save(uniform, place: oslo, year: 2025)
        let suite = UserDefaults(suiteName: "weather-load-\(UUID().uuidString)")!
        check("while weather is off the snapshot is empty even if files exist", WeatherSnapshot.load(defaults: suite, files: loadFiles).isEmpty)
        suite.set(true, forKey: WeatherSettings.enabledKey)
        check("turned on with no place it is still empty", WeatherSnapshot.load(defaults: suite, files: loadFiles).isEmpty)
        WeatherSettings.setPlace(oslo, defaults: suite)
        let loaded = WeatherSnapshot.load(defaults: suite, files: loadFiles)
        check("turned on with a place and files it reads the weather and the cut-offs", !loaded.isEmpty && loaded.coldAtOrBelow == 4 && loaded.placeName == "Oslo")
        suite.set("fahrenheit", forKey: WeatherSettings.temperatureUnitKey)
        check("the snapshot carries the unit chosen in Settings", WeatherSnapshot.load(defaults: suite, files: loadFiles).unit == .fahrenheit && loaded.unit == WeatherSettings.temperatureUnit(defaults: UserDefaults(suiteName: "weather-none-\(UUID().uuidString)")!))
        suite.set(10, forKey: WeatherSettings.coldPercentileKey); suite.set(90, forKey: WeatherSettings.hotPercentileKey)
        check("the cut-offs follow the settings", WeatherSnapshot.load(defaults: suite, files: loadFiles).hotAtOrAbove == 21)
        check("the credit line is the one Open-Meteo asks for", WeatherAttribution.text == "Weather data by Open-Meteo.com" && WeatherAttribution.url.host == "open-meteo.com")
    }

    // MARK: - The download

    /// Everything the stand-in service was asked, in order.
    private final class Log: @unchecked Sendable {
        var urls: [URL] = []
        var failOn: Int?
        var statusOn: (call: Int, status: Int, body: String)?
    }

    private static func standIn(_ log: Log) {
        FirstRunChecks.StubTransport.requests = 0
        FirstRunChecks.StubTransport.responder = { request in
            log.urls.append(request.url!)
            let call = log.urls.count
            if log.failOn == call { return nil }
            if let special = log.statusOn, special.call == call { return (special.status, special.body) }
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            let from: Int, to: Int
            var isRecent = false
            if let start = query["start_date"], let end = query["end_date"] {
                from = WeatherClient.hourNumber(start + "T00:00")!
                to = WeatherClient.hourNumber(end + "T23:00")!
            } else {
                isRecent = true
                let days = Int(query["past_days"]!)!
                to = (currentNow / 24) * 24 + 23
                from = (currentNow / 24) * 24 - days * 24
            }
            var times: [String] = [], temps: [String] = [], precip: [String] = [], snow: [String] = [], codes: [String] = []
            for h in from...to {
                let date = WeatherSeries.date(ofHour: h)
                let p = utc.dateComponents([.year, .month, .day, .hour], from: date)
                times.append(String(format: "\"%04d-%02d-%02dT%02d:00\"", p.year!, p.month!, p.day!, p.hour!))
                let sample = weather(atHour: h)
                temps.append(sample.temperature.map { String($0 + (isRecent ? recentBias : 0)) } ?? "null")
                precip.append(String(sample.precipitation ?? 0))
                snow.append(String(sample.snowfall ?? 0))
                codes.append(String(sample.code ?? 0))
            }
            let body = "{\"hourly\":{\"time\":[\(times.joined(separator: ","))],\"temperature_2m\":[\(temps.joined(separator: ","))],\"precipitation\":[\(precip.joined(separator: ","))],\"rain\":[\(precip.joined(separator: ","))],\"snowfall\":[\(snow.joined(separator: ","))],\"weather_code\":[\(codes.joined(separator: ","))]}}"
            return (200, body)
        }
    }

    /// The "now" the stand-in uses to answer a request for the last few days.
    nonisolated(unsafe) private static var currentNow = hour(2025, 3, 10, 12)
    /// Degrees the stand-in's recent-history source is off from the archive (the real two disagree by a few degrees until the archive settles).
    nonisolated(unsafe) private static var recentBias = 0.0

    private static func client() -> WeatherClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstRunChecks.StubTransport.self]
        return WeatherClient(session: URLSession(configuration: configuration))
    }

    private static func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }

    @MainActor
    private static func download(_ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let place = WeatherPlace(name: "Oslo", latitude: 59.91273, longitude: 10.74609)
        let firstPlay = date(2023, 6, 15, 9, 10)
        let folder = FileManager.default.temporaryDirectory.appending(path: "scroblytics-weather-dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = WeatherFiles(directory: folder)
        let log = Log()
        standIn(log)
        let service = client()
        let now1 = date(2025, 3, 10, 12, 30)
        currentNow = WeatherSeries.hour(of: now1)

        do {
            let first = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now1, client: service, files: files, pause: .zero)
            check("the first download makes one archive request for each year of the history and one for the last days (4)", first.requests == 4 && log.urls.count == 4, "\(log.urls.map(\.absoluteString))")
            let q = log.urls.map(query)
            check("the first year starts at the first play's day, not January", q[0]["start_date"] == "2023-06-15" && q[0]["end_date"] == "2023-12-31", "\(q[0])")
            check("a full year in the middle is asked for whole", q[1]["start_date"] == "2024-01-01" && q[1]["end_date"] == "2024-12-31")
            check("the current year's archive stops a week before now", q[2]["start_date"] == "2025-01-01" && q[2]["end_date"] == "2025-03-03", "\(q[2])")
            check("the days after that come from the recent-history source", log.urls[3].host == "api.open-meteo.com" && q[3]["past_days"] == "8", "\(q[3])")
            check("a download from the archive and the recent source marks what the archive has settled (through Mar 3)", files.load(place, year: 2025)?.settledThroughHour == hour(2025, 3, 3, 23) && files.load(place, year: 2025)?.coveredThroughHour == WeatherSeries.hour(of: now1), "\(String(describing: files.load(place, year: 2025)?.settledThroughHour))")
            check("the archive requests go to the archive host", log.urls[0].host == "archive-api.open-meteo.com" && log.urls[2].host == "archive-api.open-meteo.com")

            let timeline = files.timeline(place)
            let probes = [hour(2023, 6, 15, 0), hour(2023, 9, 1, 7), hour(2024, 2, 29, 20), hour(2024, 12, 31, 23), hour(2025, 3, 3, 23), hour(2025, 3, 4, 0), hour(2025, 3, 10, 12)]
            check("every hour from the first play's day to now has the service's weather", probes.allSatisfy { timeline?.sample(hour: $0) == weather(atHour: $0) }, "\(probes.filter { timeline?.sample(hour: $0) != weather(atHour: $0) })")
            check("an hour the service had no temperature for stays empty (and is not asked for again)", timeline?.sample(hour: 97 * 4000)?.temperature == nil)
            check("hours before the first play's day and after now are empty", timeline?.sample(hour: hour(2023, 6, 14, 23)) == nil && timeline?.sample(hour: hour(2025, 3, 10, 13)) == nil)

            // Nothing new to ask.
            log.urls.removeAll()
            let again = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now1, client: service, files: files, pause: .zero)
            check("downloading again straight away asks for nothing", again.requests == 0 && log.urls.isEmpty)

            // Three days later: only the new days, from the recent source.
            let now2 = date(2025, 3, 13, 12, 30)
            currentNow = WeatherSeries.hour(of: now2)
            let top = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now2, client: service, files: files, pause: .zero)
            check("three days later the days the archive now has (Mar 4–6) come from it, then the recent days from the first hour it hasn't settled", top.requests == 2 && log.urls.count == 2 && log.urls[0].host == "archive-api.open-meteo.com" && query(log.urls[0])["start_date"] == "2025-03-04" && query(log.urls[0])["end_date"] == "2025-03-06" && log.urls[1].host == "api.open-meteo.com" && query(log.urls[1])["past_days"] == "8", "\(log.urls.map(\.absoluteString))")
            let continued = files.timeline(place)
            check("the weather continues without a gap", [hour(2025, 3, 10, 13), hour(2025, 3, 12, 5), hour(2025, 3, 13, 12)].allSatisfy { continued?.sample(hour: $0) == weather(atHour: $0) })

            // Three weeks later: the days the archive now has, then the recent ones.
            log.urls.removeAll()
            let now3 = date(2025, 4, 2, 12, 30)
            currentNow = WeatherSeries.hour(of: now3)
            let later = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now3, client: service, files: files, pause: .zero)
            let laterQuery = log.urls.map(query)
            check("three weeks later the archive request picks up where the last one ended, then the recent days", later.requests == 2 && laterQuery[0]["start_date"] == "2025-03-07" && laterQuery[0]["end_date"] == "2025-03-26" && log.urls[1].host == "api.open-meteo.com", "\(laterQuery)")

            // Everything that was ever sent.
            let allowedHosts: Set<String> = ["archive-api.open-meteo.com", "api.open-meteo.com", "geocoding-api.open-meteo.com"]
            let allowedKeys: Set<String> = ["latitude", "longitude", "start_date", "end_date", "hourly", "timezone", "past_days", "forecast_days"]
            let sent = log.urls + [service.archiveRequest(place: place, from: now1, to: now1).url!, service.recentRequest(place: place, pastDays: 3).url!]
            check("every request goes to Open-Meteo and carries only a rounded coordinate, dates and the weather variables asked for",
                  sent.allSatisfy { allowedHosts.contains($0.host ?? "") && Set(query($0).keys).isSubset(of: allowedKeys) && query($0)["latitude"] == "59.9" && query($0)["longitude"] == "10.7" })
            check("the search request carries only the typed name and fixed options", Set(query(service.searchRequest(name: "Oslo").url!).keys) == ["name", "count", "language", "format"] && query(service.searchRequest(name: "Oslo").url!)["name"] == "Oslo")
            check("requests ask for UTC, so hours are matched by instant", sent.allSatisfy { query($0)["timezone"] == "GMT" })
        } catch {
            check("a download from a stand-in service completes", false, "\(error)")
        }

        // Hours first taken from the recent source are replaced by the archive's settled values once it has them.
        let revised = WeatherFiles(directory: folder.appending(path: "revised"))
        standIn(Log())
        recentBias = 2
        do {
            currentNow = WeatherSeries.hour(of: now1)
            _ = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now1, client: service, files: revised, pause: .zero)
            func temperature(_ h: Int) -> Double? { revised.timeline(place)?.sample(hour: h)?.temperature }
            let settled = hour(2025, 3, 2, 10), recentHour = hour(2025, 3, 5, 10), newest = hour(2025, 3, 9, 10)
            check("an archive hour is the archive's value, and an hour after it is the recent source's (here 2° off)", temperature(settled) == weather(atHour: settled).temperature && temperature(recentHour) == (weather(atHour: recentHour).temperature ?? 0) + 2)
            let later = date(2025, 3, 13, 12, 30)
            currentNow = WeatherSeries.hour(of: later)
            _ = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: later, client: service, files: revised, pause: .zero)
            check("once the archive reaches that day its settled value replaces the recent source's (Mar 5)", temperature(recentHour) == weather(atHour: recentHour).temperature, "\(String(describing: temperature(recentHour)))")
            check("a day the archive still doesn't have stays the recent source's (Mar 9)", temperature(newest) == (weather(atHour: newest).temperature ?? 0) + 2)
            // A file saved before the archive and recent hours were told apart: nothing settled, so the history is asked of the archive again.
            var old = WeatherSeries(startHour: 100, count: 4)
            old.coveredThroughHour = 103; old.settledThroughHour = 101
            for h in 100..<104 { old.set(hour: h, weather(atHour: h)) }
            var legacy = old.encoded()
            legacy.replaceSubrange(0..<4, with: Array("SWX1".utf8))
            legacy.removeSubrange(24..<32)
            let read = WeatherSeries(data: legacy)
            check("a file saved by the earlier format still reads, with nothing settled", read?.coveredThroughHour == 103 && read?.settledThroughHour == Int.min && read?.sample(hour: 102) == old.sample(hour: 102) && WeatherSeries(data: old.encoded())?.settledThroughHour == 101)
        } catch {
            check("recent hours are replaced by settled ones", false, "\(error)")
        }
        recentBias = 0

        // A limit part-way: what was fetched is kept, and the next run only asks for the rest.
        let limited = WeatherFiles(directory: folder.appending(path: "limit"))
        let limitLog = Log(); limitLog.statusOn = (2, 429, "{}")
        standIn(limitLog)
        currentNow = WeatherSeries.hour(of: now1)
        do {
            _ = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now1, client: service, files: limited, pause: .zero)
            check("a rate limit stops the download", false)
        } catch {
            check("a rate limit stops the download with a plain error", (error as? WeatherError) == .rateLimited, "\(error)")
        }
        check("…and the first year, already downloaded, is kept", limited.load(place, year: 2023) != nil && limited.load(place, year: 2024) == nil)
        limitLog.urls.removeAll(); limitLog.statusOn = nil
        do {
            let resumed = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now1, client: service, files: limited, pause: .zero)
            check("the next run asks only for what is missing (3 requests, not 4)", resumed.requests == 3 && query(limitLog.urls[0])["start_date"] == "2024-01-01", "\(limitLog.urls.map(\.absoluteString))")
        } catch {
            check("a download resumes after a limit", false, "\(error)")
        }

        // Network failure: never saved as 'no weather'.
        let broken = WeatherFiles(directory: folder.appending(path: "broken"))
        let brokenLog = Log(); brokenLog.failOn = 1
        standIn(brokenLog)
        do {
            _ = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now1, client: service, files: broken, pause: .zero)
            check("a dropped connection stops the download", false)
        } catch {
            check("a dropped connection is a network error, and nothing is saved as weather", (error as? WeatherError) == .network && broken.load(place, year: 2023) == nil, "\(error)")
        }

        // A refused request says why.
        let refusedLog = Log(); refusedLog.statusOn = (1, 400, #"{"error":true,"reason":"Date out of range"}"#)
        standIn(refusedLog)
        do {
            _ = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now1, client: service, files: WeatherFiles(directory: folder.appending(path: "refused")), pause: .zero)
            check("a refused request stops the download", false)
        } catch {
            check("a refused request carries the service's reason", (error as? WeatherError) == .rejected("Date out of range"), "\(error)")
        }

        // Offline mode: nothing is sent.
        let offlineLog = Log()
        standIn(offlineLog)
        ConnectivityGate.set(offline: true)
        do {
            _ = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now1, client: service, files: WeatherFiles(directory: folder.appending(path: "offline")), pause: .zero)
            check("Offline mode stops the download", false)
        } catch {
            check("Offline mode stops the download before anything is sent", (error as? WeatherError) == .offline && offlineLog.urls.isEmpty, "\(error)")
        }
        do { _ = try await service.search(name: "Oslo"); check("Offline mode stops a place search", false) } catch {
            check("Offline mode stops a place search before anything is sent", (error as? WeatherError) == .offline && offlineLog.urls.isEmpty)
        }
        ConnectivityGate.set(offline: false)

        // A search through the stand-in.
        FirstRunChecks.StubTransport.responder = { _ in (200, #"{"results":[{"name":"Oslo","latitude":59.91273,"longitude":10.74609,"country":"Norway","admin1":"Oslo"}]}"#) }
        let hits = try? await service.search(name: " Oslo ")
        let shortSearch = try? await service.search(name: "O")
        check("a search returns the places, and a one-letter search sends nothing", hits?.first?.place.key == place.key && shortSearch?.isEmpty == true)
    }

    // MARK: - Trends

    private static func trends(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { a.map { abs($0 - b) < tolerance } ?? false }
        // Everything is worked out in UTC so the numbers do not depend on the time zone of the Mac running the check.
        let calendar = utc
        func play(_ day: Date, _ hod: Int, _ minute: Int = 10) -> ScrobbleSnapshot {
            let when = calendar.date(byAdding: .minute, value: hod * 60 + minute, to: day)!
            return ScrobbleSnapshot(artistName: "A", albumName: "Album A", trackName: "Track A", imageURL: nil, playedAt: when)
        }
        /// The stand-in weather: temperature is the hour of the day, rain at 6–8, snow at 20–21, clear otherwise; only inside `days`.
        func series(windows: [(from: Date, days: Int)], rainOnly: [Int]? = nil) -> WeatherSeries {
            let start = windows.map { WeatherSeries.hour(of: $0.from) }.min()!
            let end = windows.map { WeatherSeries.hour(of: $0.from) + $0.days * 24 }.max()!
            var s = WeatherSeries(startHour: start, count: end - start)
            for (index, window) in windows.enumerated() {
                let first = WeatherSeries.hour(of: window.from)
                for h in first..<(first + window.days * 24) {
                    let hod = h % 24
                    let isRain = (6...8).contains(hod), isSnow = (20...21).contains(hod) && (rainOnly == nil || !rainOnly!.contains(index))
                    s.set(hour: h, WeatherSample(temperature: Double(hod), precipitation: nil, rain: nil, snowfall: nil, code: isRain ? 61 : (isSnow ? 71 : 0)))
                }
            }
            return s
        }
        func snapshot(_ s: WeatherSeries) -> WeatherSnapshot { WeatherSnapshot(series: s, placeName: "Test", percentiles: (20, 80)) }
        func lifts(_ r: TrendsWeatherResult) -> [WeatherCondition: Double] { Dictionary(uniqueKeysWithValues: r.tiles.compactMap { t in t.lift.map { (t.condition, $0) } }) }
        let jan1 = date(2025, 1, 1), jul1 = date(2025, 7, 1)
        func window(_ from: Date, days: Int) -> DateRange { DateRange(from: from, to: calendar.date(byAdding: .day, value: days, to: from)!.addingTimeInterval(-1)) }

        // Parts of the day and the temperature columns.
        let names = (0..<24).map { TrendsWeatherEngine.dayparts[TrendsWeatherEngine.daypart(hour: $0)] }
        check("the day is split Morning 5–11, Afternoon 12–16, Evening 17–20, Night 21–4", names[4] == "Night" && names[5] == "Morning" && names[11] == "Morning" && names[12] == "Afternoon" && names[16] == "Afternoon" && names[17] == "Evening" && names[20] == "Evening" && names[21] == "Night" && names[0] == "Night")

        // Dataset A: ten days, each with 2 plays at 7 (rain), 1 at 12 (clear), 1 at 20 (snow), 1 at 2 (clear).
        let weatherA = snapshot(series(windows: [(jan1, 10)]))
        let edges = TrendsWeatherEngine.decileEdges(of: weatherA.series!)
        check("ten days of hourly 0–23° give the column edges 0, 2, 4, 7, 9, 11, 14, 16, 19, 21, 23", edges == [0, 2, 4, 7, 9, 11, 14, 16, 19, 21, 23], "\(edges)")
        check("a temperature belongs to the last edge at or below it, and never past the final column",
              TrendsWeatherEngine.column(of: 0, edges: edges) == 0 && TrendsWeatherEngine.column(of: 1.99, edges: edges) == 0 && TrendsWeatherEngine.column(of: 2, edges: edges) == 1
                && TrendsWeatherEngine.column(of: 23, edges: edges) == 9 && TrendsWeatherEngine.column(of: 100, edges: edges) == 9 && TrendsWeatherEngine.column(of: -5, edges: edges) == 0)
        var playsA: [ScrobbleSnapshot] = []
        for d in 0..<10 {
            let day = calendar.date(byAdding: .day, value: d, to: jan1)!
            playsA += [play(day, 7), play(day, 7, 30), play(day, 12), play(day, 20), play(day, 2)]
        }
        let rangeA = window(jan1, days: 10)
        func run(_ plays: [ScrobbleSnapshot], _ weather: WeatherSnapshot, _ range: DateRange, compare: DateRange? = nil, metric: TrendsMetric = .plays, adjust: Bool = false) -> TrendsWeatherResult {
            TrendsWeatherEngine.compute(scrobbles: plays, weather: weather, range: range, compareRange: compare, metric: metric, durations: .empty, adjustForSeason: adjust, calendar: calendar)
        }
        let a = run(playsA, weatherA, rangeA)
        let aLifts = lifts(a)
        check("rain: 20 plays over 30 hours of rain is 16 a day against an average day of 5, a lift of 3.2", near(a.tiles.first { $0.condition == .rain }?.perDay, 16) && near(a.tiles.first?.average, 5) && near(aLifts[.rain], 3.2), "\(a.tiles.map { "\($0.condition) \($0.perDay) \($0.lift ?? -1)" })")
        check("snow: 10 plays over 20 hours is 12 a day, a lift of 2.4", near(a.tiles.first { $0.condition == .snow }?.perDay, 12) && near(aLifts[.snow], 2.4))
        check("clear: 20 plays over 190 hours is about 2.53 a day, a lift of about 0.505", near(a.tiles.first { $0.condition == .clear }?.perDay, 20.0 / 190 * 24) && near(aLifts[.clear], 20.0 / 190 * 24 / 5))
        check("a weather that never happened has no hours and no lift", a.tiles.first { $0.condition == .fog }?.hours == 0 && aLifts[.fog] == nil && a.tiles.first { $0.condition == .fog }?.lift == nil)
        check("the hours and plays behind each tile are counted: rain 30 h and 20 plays, all 240 hours in total", a.tiles.first { $0.condition == .rain }.map { $0.hours == 30 && $0.playCount == 20 && $0.weight == 20 } == true && a.tiles.map(\.hours).reduce(0, +) == 240)
        check("fewer than 30 plays is thin, and the leaning weather ignores thin ones", a.tiles.allSatisfy(\.isThin) && a.leaning == nil)
        let aAdjusted = lifts(run(playsA, weatherA, rangeA, adjust: true))
        check("within one month allowing for the time of year changes nothing", near(aAdjusted[.rain], 3.2) && near(aAdjusted[.snow], 2.4))

        // The grid: how much more or less than that part of the day's usual rate, by temperature.
        let g = a.grid
        check("the grid has four parts of the day and ten temperature columns", g.cells.count == 4 && g.cells.allSatisfy { $0.count == 10 } && g.edges == edges)
        check("morning at 7–9°: 20 plays against 20 hours at 2/7 an hour is 3.5 times usual", near(g.cells[0][3].lift, 3.5) && g.cells[0][3].plays == 20, "\(String(describing: g.cells[0][3]))")
        check("afternoon at 11–14°: 10 plays against 4 expected is 2.5", near(g.cells[1][5].lift, 2.5) && g.cells[1][5].plays == 10)
        check("evening at 19–21°: 10 against 5 expected is 2.0, night at 2–4°: 10 against 2.5 is 4.0", near(g.cells[2][8].lift, 2.0) && near(g.cells[3][1].lift, 4.0))
        check("a cell with hours but no plays is 0 times usual, and one with no hours has no value", near(g.cells[0][2].lift, 0) && g.cells[0][2].plays == 0 && g.cells[0][0].lift == nil && g.cells[0][9].lift == nil)

        // The weeks (days, for a short period).
        check("a ten-day period is drawn day by day: ten days, each 5 plays, 11.5° and snowy (2 of 24 hours of snow)",
              a.bucketDays == 1 && a.buckets.count == 10 && a.buckets.allSatisfy { $0.plays == 5 && near($0.temperature, 11.5) && $0.precipitation == .snow && $0.days == 1 }, "\(a.buckets.prefix(2))")

        // Clicking what is drawn opens exactly what is counted.
        func counted(_ filter: QueryPlayFilter, _ plays: [ScrobbleSnapshot], _ weather: WeatherSnapshot) -> Int {
            plays.filter { filter.matches($0.playedAt, calendar: calendar, weather: weather) }.count
        }
        var cellsAgree = true, cellDetail = ""
        for row in 0..<4 { for col in 0..<10 {
            guard let filter = TrendsWeatherEngine.cellFilter(row: row, column: col, edges: edges) else { cellsAgree = false; continue }
            let opened = counted(filter, playsA, weatherA)
            if opened != g.cells[row][col].plays { cellsAgree = false; cellDetail += " [\(row),\(col)] drawn \(g.cells[row][col].plays) opens \(opened)" }
        } }
        check("every grid cell opens exactly the plays it counts (all 40 cells)", cellsAgree, cellDetail)
        check("a tile opens exactly its weather's plays: rain 20, snow 10, clear 20",
              [(WeatherCondition.rain, 20), (.snow, 10), (.clear, 20)].allSatisfy { counted(QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil, months: nil, weatherConditions: [$0.0.rawValue]), playsA, weatherA) == $0.1 })

        // Two months where the weather differs: Jan all clear, July with rain. January is busy, July quiet.
        let weatherB = snapshot(series(windows: [(jan1, 10), (jul1, 10)], rainOnly: nil))
        // Jan: no rain at all (use a series with rain only in July): rebuild with codes by month.
        var seriesB = WeatherSeries(startHour: WeatherSeries.hour(of: jan1), count: WeatherSeries.hour(of: jul1) + 240 - WeatherSeries.hour(of: jan1))
        for (from, days) in [(jan1, 10), (jul1, 10)] {
            let first = WeatherSeries.hour(of: from)
            for h in first..<(first + days * 24) {
                let hod = h % 24
                let rain = from == jul1 && (6...8).contains(hod)
                seriesB.set(hour: h, WeatherSample(temperature: Double(hod), precipitation: nil, rain: nil, snowfall: nil, code: rain ? 61 : 0))
            }
        }
        _ = weatherB
        let snapB = snapshot(seriesB)
        var playsB: [ScrobbleSnapshot] = []
        for d in 0..<10 {
            let janDay = calendar.date(byAdding: .day, value: d, to: jan1)!, julDay = calendar.date(byAdding: .day, value: d, to: jul1)!
            for i in 0..<8 { playsB.append(play(janDay, 12, i)) }          // January: 8 a day at noon (clear)
            playsB += [play(julDay, 7), play(julDay, 7, 30)]                // July: 2 a day at 7 (rain)
        }
        let rangeB = DateRange(from: jan1, to: calendar.date(byAdding: .day, value: 11, to: jul1)!)
        let b = run(playsB, snapB, rangeB), bAdj = run(playsB, snapB, rangeB, adjust: true)
        check("unadjusted, rain looks 3.2 times usual and clear 0.85 (rain only happens in the quiet month)",
              near(lifts(b)[.rain], 3.2) && near(lifts(b)[.clear], 80.0 / 450 * 24 / 5), "\(lifts(b))")
        check("allowing for the time of year, rain is 8 times what July usually brings and clear is 0.82 times what its months bring",
              near(lifts(bAdj)[.rain], 8.0) && near(lifts(bAdj)[.clear], 80.0 / 97.5), "\(lifts(bAdj))")
        check("the adjusted bar is the lift times the average day: rain 40 a day, clear 4.1", near(bAdj.tiles.first { $0.condition == .rain }?.perDay, 40) && near(bAdj.tiles.first { $0.condition == .clear }?.perDay, 80.0 / 97.5 * 5))
        check("a long period is drawn week by week, and every play lands in a week: four weeks with data, 100 plays",
              b.bucketDays == 7 && b.buckets.count == 4 && b.buckets.map(\.plays).reduce(0, +) == 100 && b.buckets.map(\.plays) == [32, 48, 10, 10], "\(b.buckets.map(\.plays))")
        check("a rainy week is marked (July's 3 of 24 hours a day), a January week is not", b.buckets.last?.precipitation == .rain && b.buckets.first?.precipitation == TrendsWeatherWeek.Precipitation.none)

        // A comparison period.
        var playsC: [ScrobbleSnapshot] = []
        for d in 0..<10 {
            let day = calendar.date(byAdding: .day, value: d, to: jan1)!
            for i in 0..<8 { playsC.append(play(day, 7, i)) }
            for i in 0..<4 { playsC += [play(day, 12, i), play(day, 20, i), play(day, 2, i)] }
        }
        let c = run(playsC, weatherA, window(jan1, days: 5), compare: window(calendar.date(byAdding: .day, value: 5, to: jan1)!, days: 5))
        check("with a comparison period each weather also reports last period's lift: rain 3.2 (enough plays), not snow (too few)", near(c.previousLifts[.rain], 3.2) && c.previousLifts[.snow] == nil && c.leaning?.condition == .rain, "\(c.previousLifts)")

        // Nothing to show.
        check("with no weather, or a period before it, there is nothing to draw", !run(playsA, .empty, rangeA).hasWeather && !run(playsA, weatherA, window(date(2020, 1, 1), days: 10)).hasWeather)
        let pendingRun = run(playsA, weatherA, rangeA, metric: .timeListened)
        check("counting time listened, plays still waiting for a track length are set aside, not guessed", pendingRun.pending == 50 && pendingRun.tiles.allSatisfy { $0.weight == 0 }, "\(pendingRun.pending)")
    }

    // MARK: - Trips

    @MainActor
    private static func tripChecks(_ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { a.map { abs($0 - b) < tolerance } ?? false }
        let calendar = utc
        let oslo = WeatherPlace(name: "Oslo, Norway", latitude: 59.91273, longitude: 10.74609)
        let lisbon = WeatherPlace(name: "Lisbon, Portugal", latitude: 38.72, longitude: -9.14)
        func trip(_ place: WeatherPlace, _ from: Date, _ until: Date?) -> WeatherTrip { WeatherTrip(place: place, from: from, until: until) }
        let mar1 = date(2025, 3, 1), mar5 = date(2025, 3, 5), mar10 = date(2025, 3, 10), mar15 = date(2025, 3, 15)

        // Which trip a moment falls in.
        let t1 = trip(lisbon, mar5, mar10)
        check("a trip covers its first moment and not the moment it ends", t1.covers(mar5) && t1.covers(mar10.addingTimeInterval(-1)) && !t1.covers(mar10) && !t1.covers(mar5.addingTimeInterval(-1)))
        check("an open trip covers everything from its start on", trip(lisbon, mar5, nil).covers(date(2031, 1, 1)) && !trip(lisbon, mar5, nil).covers(mar1))
        check("no trips, or none covering the moment, means at home", WeatherTrip.effective(at: mar1, in: []) == nil && WeatherTrip.effective(at: mar1, in: [t1]) == nil && WeatherTrip.effective(at: mar10, in: [t1]) == nil)
        let inner = trip(oslo, date(2025, 3, 6), date(2025, 3, 8))
        check("where trips overlap the one that began later is used", WeatherTrip.effective(at: date(2025, 3, 7), in: [t1, inner])?.id == inner.id && WeatherTrip.effective(at: date(2025, 3, 7), in: [inner, t1])?.id == inner.id && WeatherTrip.effective(at: date(2025, 3, 9), in: [t1, inner])?.id == t1.id)
        let tied = trip(oslo, mar5, mar10)
        check("trips that began together: the later entry wins", WeatherTrip.effective(at: date(2025, 3, 7), in: [t1, tied])?.id == tied.id)
        check("trips that follow each other do not overlap, an open trip overlaps a later one",
              !t1.overlaps(trip(oslo, mar10, mar15)) && t1.overlaps(inner) && trip(lisbon, mar5, nil).overlaps(trip(oslo, mar15, nil)))
        check("a place reads short in lists", lisbon.shortName == "Lisbon" && WeatherPlace(name: "Home", latitude: 0, longitude: 0).shortName == "Home")

        // Adding a trip: places already used are offered again, and the last day follows the first until it is picked.
        let lisbonAgain = WeatherPlace(name: "Lisbon, Portugal", latitude: 38.72, longitude: -9.14)
        let known = TripEditor.knownPlaces(in: [trip(lisbon, mar5, mar10), trip(oslo, mar15, nil), trip(lisbonAgain, date(2025, 3, 20), date(2025, 3, 22))])
        check("a trip's place can be picked again: each place once, the most recently visited first", known.map(\.shortName) == ["Lisbon", "Oslo"] && known.first?.key == lisbon.key, "\(known.map(\.name))")
        check("with no trips there is nothing to pick from", TripEditor.knownPlaces(in: []).isEmpty)
        var draft = TripDraft.new(calendar: calendar)
        draft.from = date(2025, 6, 10); draft.firstDayChanged()
        check("a new trip's last day follows its first day (a date in the future, not today)", draft.lastDay == date(2025, 6, 10))
        draft.from = date(2025, 6, 12); draft.firstDayChanged()
        check("…and keeps following it when the first day moves again", draft.lastDay == date(2025, 6, 12))
        draft.lastDay = date(2025, 6, 20); draft.lastDayChosen = true
        draft.from = date(2025, 6, 14); draft.firstDayChanged()
        check("once the last day is picked it stays, as long as it isn't before the first day", draft.lastDay == date(2025, 6, 20))
        draft.from = date(2025, 6, 25); draft.firstDayChanged()
        check("a first day after a picked last day pulls the last day along, so a trip never ends before it starts", draft.lastDay == date(2025, 6, 25))
        let existing = TripDraft(trip: trip(lisbon, mar5, mar10), calendar: calendar)
        var edited = existing
        edited.from = date(2025, 3, 6); edited.firstDayChanged()
        check("an existing trip keeps its own last day when its first day is changed", edited.lastDay == existing.lastDay && existing.lastDayChosen)

        // Saving trips.
        let folder = FileManager.default.temporaryDirectory.appending(path: "scroblytics-trips-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tripsFile = folder.appending(path: "WeatherTrips.json")
        check("no file means no trips", WeatherTripStore.load(file: tripsFile).isEmpty)
        WeatherTripStore.save([t1, trip(oslo, mar15, nil)], file: tripsFile)
        let loaded = WeatherTripStore.load(file: tripsFile)
        check("trips save and load exactly, including an open one", loaded.count == 2 && loaded[0] == t1 && loaded[1].until == nil && loaded[1].place == oslo)
        WeatherTripStore.save([], file: tripsFile)
        check("saving no trips removes the file", !FileManager.default.fileExists(atPath: tripsFile.path))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: tripsFile)
        check("a damaged file is no trips, not a crash", WeatherTripStore.load(file: tripsFile).isEmpty)

        // The weather where you were.
        let homeHours = WeatherSeries.hour(of: mar1)
        var home = WeatherSeries(startHour: homeHours, count: 24 * 20)
        for h in homeHours..<(homeHours + 24 * 20) { home.set(hour: h, WeatherSample(temperature: Double(h % 24), precipitation: nil, rain: nil, snowfall: nil, code: 0)) }
        var away = WeatherSeries(startHour: WeatherSeries.hour(of: mar5), count: 24 * 5)
        for h in away.startHour..<(away.startHour + 24 * 5) { away.set(hour: h, WeatherSample(temperature: 20 + Double(h % 24) / 10, precipitation: nil, rain: nil, snowfall: nil, code: 61)) }
        var snapshot = WeatherSnapshot(series: home, placeName: "Oslo, Norway", percentiles: (20, 80))
        snapshot.trips = [WeatherSnapshot.TripWeather(trip: t1, series: away)]
        let onTrip = date(2025, 3, 7, 12), atHome = date(2025, 3, 3, 12)
        check("a play on a trip gets the trip's weather, one at home gets home's", snapshot.sample(at: onTrip)?.condition == .rain && near(snapshot.sample(at: onTrip)?.temperature, 21.2) && snapshot.sample(at: atHome)?.condition == .clear)
        check("the location of a play is the trip's place on a trip and home otherwise", snapshot.locationName(at: onTrip) == "Lisbon" && snapshot.locationName(at: atHome) == "Oslo")
        // Cities: where you were, from the settings alone (not from what has been downloaded).
        check("the city of a play is the trip's on a trip and home's otherwise, short", snapshot.city(at: onTrip) == "Lisbon" && snapshot.city(at: atHome) == "Oslo")
        var noWeatherForTrip = snapshot
        noWeatherForTrip.trips = [WeatherSnapshot.TripWeather(trip: t1, series: WeatherSeries(startHour: WeatherSeries.hour(of: mar5), count: 0))]
        check("a trip whose weather isn't downloaded yet is still its city (the weather is none, the city is known)", noWeatherForTrip.sample(at: onTrip) == nil && noWeatherForTrip.city(at: onTrip) == "Lisbon")
        check("no home place means no city for any play", WeatherSnapshot.empty.city(at: onTrip) == nil)
        var sameCity = snapshot
        sameCity.trips = [WeatherSnapshot.TripWeather(trip: trip(WeatherPlace(name: "Oslo, Norway", latitude: 59.9, longitude: 10.7), mar5, mar10), series: away), WeatherSnapshot.TripWeather(trip: trip(lisbon, mar10, mar15), series: away)]
        check("the cities are home first, then each trip, each once", snapshot.cities == ["Oslo", "Lisbon"] && sameCity.cities == ["Oslo", "Lisbon"] && WeatherSnapshot.empty.cities.isEmpty, "\(sameCity.cities)")
        check("names compare without case or accents", PlaceNames.key(" MÜNCHEN ") == PlaceNames.key("munchen") && PlaceNames.key("Munich") != PlaceNames.key("München") && WeatherLocations.match("lisbon", in: ["Oslo", "Lisbon"]) == "Lisbon" && WeatherLocations.match("Paris", in: ["Oslo", "Lisbon"]) == nil)
        func cityFilter(_ cities: [String], _ conditions: [String] = []) -> QueryPlayFilter {
            QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil, months: nil, weatherConditions: conditions, temperatureBands: nil, cities: cities)
        }
        check("a city filter keeps the plays made there: Lisbon on the trip, Oslo at home, either spelling of the case", cityFilter(["lisbon"]).matches(onTrip, weather: snapshot) && !cityFilter(["Lisbon"]).matches(atHome, weather: snapshot) && cityFilter(["OSLO"]).matches(atHome, weather: snapshot) && !cityFilter(["Oslo"]).matches(onTrip, weather: snapshot))
        check("several cities mean any of them", cityFilter(["Oslo", "Lisbon"]).matches(onTrip, weather: snapshot) && cityFilter(["Oslo", "Lisbon"]).matches(atHome, weather: snapshot) && !cityFilter(["Paris"]).matches(atHome, weather: snapshot))
        check("with no home place a city filter counts nothing, instead of everything", !cityFilter(["Oslo"]).matches(atHome, weather: .empty))
        check("a city combines with the weather: rain in Lisbon, but not rain in Oslo (the trip's rain)", cityFilter(["Lisbon"], ["Rain"]).matches(onTrip, weather: snapshot) && !cityFilter(["Oslo"], ["Rain"]).matches(onTrip, weather: snapshot))
        check("a city filter is not empty and says so in words, before the weather", !cityFilter(["Lisbon"]).isEmpty && cityFilter(["Lisbon"]).usesCity && !cityFilter(["Lisbon"]).usesWeather && cityFilter(["Lisbon", "Oslo"], ["Rain"]).label(hemisphere: .north) == "in Lisbon or Oslo, in rain" && QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil).label.isEmpty, cityFilter(["Lisbon"], ["Rain"]).label(hemisphere: .north))
        check("a city with no name is refused", (try? cityFilter([" "]).validate()) == nil && (try? cityFilter(["Lisbon"]).validate()) != nil)
        var citySpec = QuerySpec(target: .track)
        citySpec.playFilter = cityFilter(["Lisbon"], ["Rain"])
        let cityAgain = try? QuerySpec.decode(citySpec.encoded())
        check("a city filter survives saving, and an older set without it still loads", cityAgain?.playFilter?.cities == ["Lisbon"] && cityAgain?.schemaVersion == QuerySpec.currentSchemaVersion && (try? QuerySpec.decode(Data(#"{"schemaVersion": 8, "target": "artist", "groups": [], "sorts": [], "columns": [], "playFilter": {"months": [12]}}"#.utf8)))?.playFilter?.cities == nil)
        // The plays counted and the fields: A only at home, B only on the trip, C both.
        func cityPlay(_ artist: String, _ date: Date, _ i: Int) -> ScrobbleSnapshot {
            ScrobbleSnapshot(artistName: artist, albumName: "Album \(artist)", trackName: "Track \(artist)", imageURL: nil, playedAt: date.addingTimeInterval(Double(i) * 60))
        }
        let cityPlays = (0..<3).map { cityPlay("A", atHome, $0) } + (0..<2).map { cityPlay("B", onTrip, $0) } + [cityPlay("C", atHome, 9), cityPlay("C", onTrip, 9)]
        func cityResult(_ filter: QueryPlayFilter?, columns: [String]) -> [String: [QueryCell?]] {
            var spec = QuerySpec(target: .artist)
            spec.playFilter = filter
            spec.columns = columns.map { QueryFieldRef($0) }
            guard let validated = try? spec.validate(against: .standard) else { return ["invalid": []] }
            var snapshots = QuerySnapshots()
            snapshots.weather = snapshot
            let run = QueryRun(target: .artist, asOf: date(2025, 4, 1), scrobbles: spec.countedPlays(cityPlays, weather: snapshot), allTimeScrobbles: cityPlays, snapshots: snapshots)
            let result = QueryEngine.evaluate(validated, run: run)
            return Dictionary(uniqueKeysWithValues: result.rows.map { row in (row.entity.name, result.columns.map { row.cells[$0.cacheKey] }) })
        }
        func plays(_ rows: [String: [QueryCell?]]) -> [String: Int] { rows.compactMapValues { cells in if case .value(.number(let n))? = cells.first ?? nil { Int(n) } else { nil } } }
        check("only the plays made in Lisbon are counted: B's two and C's one", plays(cityResult(cityFilter(["Lisbon"]), columns: ["plays"])) == ["B": 2, "C": 1], "\(plays(cityResult(cityFilter(["Lisbon"]), columns: ["plays"])))")
        check("only the plays made in Oslo: A's three and C's one", plays(cityResult(cityFilter(["Oslo"]), columns: ["plays"])) == ["A": 3, "C": 1])
        let cityFields = cityResult(nil, columns: ["plays", "playCity", "playCityCount"])
        func text(_ cell: QueryCell??) -> String? { if case .value(.text(let t))? = cell ?? nil { t } else { nil } }
        func number(_ cell: QueryCell??) -> Double? { if case .value(.number(let n))? = cell ?? nil { n } else { nil } }
        check("the City field is the city most of an item's plays were made in (a tie goes to the first alphabetically)", text(cityFields["A"]?[1]) == "Oslo" && text(cityFields["B"]?[1]) == "Lisbon" && text(cityFields["C"]?[1]) == "Lisbon", "\(cityFields)")
        check("Cities played in counts the different cities", number(cityFields["A"]?[2]) == 1 && number(cityFields["C"]?[2]) == 2)
        check("with weather off the city fields have no value", cityResult(nil, columns: ["plays", "playCity"]).isEmpty == false && { var spec = QuerySpec(target: .artist); spec.columns = [QueryFieldRef("playCity")]; let v = try! spec.validate(against: .standard); let run = QueryRun(target: .artist, asOf: date(2025, 4, 1), scrobbles: cityPlays, allTimeScrobbles: cityPlays, snapshots: QuerySnapshots()); let r = QueryEngine.evaluate(v, run: run); return r.rows.allSatisfy { row in text(r.columns.first.map { row.cells[$0.cacheKey] }) == nil } }())
        // Ask: a city a model names is checked against the places set; one that isn't is dropped, with the places named.
        var droppedCities: [AskInterpretation.Dropped] = []
        let asked = AskInterpreter.playFilter(AskWire.PlayFilter(weekdays: nil, months: nil, fromHour: nil, toHour: nil, weather: nil, temperature: nil, city: ["lisbon", "Atlantis", "OSLO"]), dropped: &droppedCities, knownCities: ["Oslo", "Lisbon"])
        check("Ask keeps the cities that are the person's, spelled the app's way, and drops the others with a reason", asked?.cities == ["Lisbon", "Oslo"] && droppedCities.count == 1 && droppedCities[0].what.contains("Atlantis") && droppedCities[0].reason.contains("Oslo, Lisbon"), "\(String(describing: asked?.cities)) \(droppedCities)")
        var noPlaces: [AskInterpretation.Dropped] = []
        let none = AskInterpreter.playFilter(AskWire.PlayFilter(weekdays: nil, months: nil, fromHour: nil, toHour: nil, weather: nil, temperature: nil, city: ["Oslo"]), dropped: &noPlaces, knownCities: [])
        check("with no places set Ask drops the city and says there is no home place", none == nil && noPlaces.first?.reason.contains("no home place") == true)
        let cityChips = AskChips.describe(citySpec, registry: .standard, weatherReady: true, cityReady: false)
        check("the chip says what is counted and warns when no home place is set", cityChips.contains { $0.text == "Only plays: in Lisbon, in rain" && $0.caveat?.contains("home place") == true }, "\(cityChips.map(\.text))")
        check("with a home place set the chip has no warning", AskChips.describe(citySpec, registry: .standard, weatherReady: true, cityReady: true).first { $0.text.hasPrefix("Only plays:") }?.caveat == nil)
        check("the first day of a trip is the trip's and the day it ends is home's again", snapshot.sample(at: date(2025, 3, 5, 0))?.condition == .rain && snapshot.sample(at: date(2025, 3, 10, 0))?.condition == .clear)
        var gappy = snapshot
        gappy.trips = [WeatherSnapshot.TripWeather(trip: trip(lisbon, mar5, mar15), series: away)]   // weather for 5 of the 10 days
        check("a trip hour with no downloaded weather has none (home's would be the wrong place's)", gappy.sample(at: date(2025, 3, 12, 12)) == nil && gappy.locationName(at: date(2025, 3, 12, 12)) == nil)
        check("the snapshot's reach covers home and trips; hot and cold come from home", snapshot.hourBounds == homeHours...(homeHours + 24 * 20 - 1) && snapshot.climateTemperatures.count == 24 * 20 && !snapshot.isEmpty)
        var tripsOnly = WeatherSnapshot()
        tripsOnly.trips = snapshot.trips
        check("a snapshot with only trips is not empty, and an empty one is", !tripsOnly.isEmpty && WeatherSnapshot.empty.isEmpty)

        // The Trends numbers use the weather where you were: days 1–4 home (clear, 10 plays a day), days 5–10 on a trip (rain, 2 a day).
        func play(_ day: Date, _ i: Int) -> ScrobbleSnapshot {
            ScrobbleSnapshot(artistName: "A", albumName: "Album A", trackName: "Track A", imageURL: nil, playedAt: calendar.date(byAdding: .minute, value: 12 * 60 + i, to: day)!)
        }
        let jan1 = date(2025, 1, 1)
        var homeJan = WeatherSeries(startHour: WeatherSeries.hour(of: jan1), count: 240)
        var awayJan = WeatherSeries(startHour: WeatherSeries.hour(of: date(2025, 1, 5)), count: 24 * 6)
        for h in homeJan.startHour..<(homeJan.startHour + 240) { homeJan.set(hour: h, WeatherSample(temperature: Double(h % 24), precipitation: nil, rain: nil, snowfall: nil, code: 0)) }
        for h in awayJan.startHour..<(awayJan.startHour + 24 * 6) { awayJan.set(hour: h, WeatherSample(temperature: Double(h % 24), precipitation: nil, rain: nil, snowfall: nil, code: 61)) }
        var janSnapshot = WeatherSnapshot(series: homeJan, placeName: "Oslo, Norway", percentiles: (20, 80))
        janSnapshot.trips = [WeatherSnapshot.TripWeather(trip: trip(lisbon, date(2025, 1, 5), date(2025, 1, 11)), series: awayJan)]
        var janPlays: [ScrobbleSnapshot] = []
        for d in 0..<10 {
            let day = calendar.date(byAdding: .day, value: d, to: jan1)!
            for i in 0..<(d < 4 ? 10 : 2) { janPlays.append(play(day, i)) }
        }
        let result = TrendsWeatherEngine.compute(scrobbles: janPlays, weather: janSnapshot, range: DateRange(from: jan1, to: calendar.date(byAdding: .day, value: 10, to: jan1)!.addingTimeInterval(-1)), compareRange: nil, metric: .plays, durations: .empty, adjustForSeason: false, calendar: calendar)
        let rainTile = result.tiles.first { $0.condition == .rain }, clearTile = result.tiles.first { $0.condition == .clear }
        check("the Trends tiles count rain only on the trip: 144 hours and 12 plays, 2 a day against an average of 5.2",
              rainTile?.hours == 144 && rainTile?.playCount == 12 && near(rainTile?.perDay, 2) && near(rainTile?.average, 5.2) && clearTile?.hours == 96 && near(clearTile?.perDay, 10), "\(String(describing: rainTile)) \(String(describing: clearTile))")
        check("…so rain is 0.38 times an average day and clear 1.92", near(rainTile?.lift, 2 / 5.2) && near(clearTile?.lift, 10 / 5.2))

        // Downloading a trip: just its days, in its own folder.
        let dl = FileManager.default.temporaryDirectory.appending(path: "scroblytics-trips-dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dl) }
        let log = Log()
        standIn(log)
        let service = client()
        let now = date(2025, 3, 20, 12, 30)
        currentNow = WeatherSeries.hour(of: now)
        let past = trip(lisbon, mar5, mar10)
        let pastFiles = WeatherFiles(directory: WeatherTripStore.cacheDirectory(for: past, base: dl))
        do {
            let summary = try await WeatherUpdater.update(place: past.place, firstPlay: past.from, through: past.until, now: now, client: service, files: pastFiles, pause: .zero)
            let q = log.urls.map(query)
            check("a past trip asks for exactly its days, in one request: March 5 to March 9", summary.requests == 1 && q.first?["start_date"] == "2025-03-05" && q.first?["end_date"] == "2025-03-09", "\(q)")
            check("…at the trip's place (rounded), not home", q.first?["latitude"] == "38.7" && q.first?["longitude"] == "-9.1")
            check("…and keeps it in the trip's own folder", pastFiles.timeline(past.place)?.sample(hour: WeatherSeries.hour(of: mar5)) != nil && pastFiles.timeline(past.place)?.sample(hour: WeatherSeries.hour(of: mar5) - 1) == nil && pastFiles.timeline(lisbon)?.lastHourWithData == WeatherSeries.hour(of: mar10) - 1, "\(String(describing: pastFiles.timeline(past.place)?.lastHourWithData))")
            log.urls.removeAll()
            let again = try await WeatherUpdater.update(place: past.place, firstPlay: past.from, through: past.until, now: now, client: service, files: pastFiles, pause: .zero)
            check("a finished trip is never asked for again", again.requests == 0 && log.urls.isEmpty)
            let open = trip(lisbon, mar15, nil)
            let openFiles = WeatherFiles(directory: WeatherTripStore.cacheDirectory(for: open, base: dl))
            let openRun = try await WeatherUpdater.update(place: open.place, firstPlay: open.from, through: open.until, now: now, client: service, files: openFiles, pause: .zero)
            check("a trip you are still on is topped up like home: from the recent-days source (the archive is a week behind), asking for just its days (7), not the year so far", openRun.requests == 1 && log.urls.last?.host == "api.open-meteo.com" && log.urls.last.map { query($0)["past_days"] } == "7", "\(log.urls.map(\.absoluteString))")
            check("…and holds nothing from before the trip began", openFiles.timeline(open.place)?.sample(hour: WeatherSeries.hour(of: mar15) - 1) == nil && openFiles.timeline(open.place)?.sample(hour: WeatherSeries.hour(of: mar15) + 5) != nil)
            // The case that was missed: a trip begun six days ago, late in a year (more than 92 days after January), still being on it.
            let lateNow = date(2025, 10, 23, 12, 30)
            currentNow = WeatherSeries.hour(of: lateNow)
            let lateTrip = trip(lisbon, date(2025, 10, 17, 22), nil)
            let lateFiles = WeatherFiles(directory: WeatherTripStore.cacheDirectory(for: lateTrip, base: dl))
            log.urls.removeAll()
            let lateRun = try await WeatherUpdater.update(place: lateTrip.place, firstPlay: lateTrip.from, through: nil, now: lateNow, client: service, files: lateFiles, pause: .zero)
            check("a trip begun last week, late in the year, is downloaded (one request for its days), not skipped", lateRun.requests == 1 && log.urls.last.map { query($0)["past_days"] } == "8", "\(lateRun.requests) \(log.urls.map(\.absoluteString))")
            check("…with weather from the day it began and nothing earlier", lateFiles.timeline(lateTrip.place)?.sample(hour: WeatherSeries.hour(of: date(2025, 10, 17, 22))) != nil && lateFiles.timeline(lateTrip.place)?.sample(hour: WeatherSeries.hour(of: date(2025, 10, 16, 12))) == nil)
            currentNow = WeatherSeries.hour(of: now)
            check("a trip that has not started yet is not downloaded", try await WeatherUpdater.update(place: lisbon, firstPlay: date(2025, 6, 1), through: nil, now: now, client: service, files: WeatherFiles(directory: dl.appending(path: "future")), pause: .zero).requests == 0)
            // The loader puts trips on the snapshot and the cleaner forgets removed trips.
            let defaults = UserDefaults(suiteName: "weather-trips-\(UUID().uuidString)")!
            defaults.set(true, forKey: WeatherSettings.enabledKey)
            WeatherSettings.setPlace(oslo, defaults: defaults)
            let homeFiles = WeatherFiles(directory: dl)
            homeFiles.save(home, place: oslo, year: 2025)
            let file = dl.appending(path: "trips.json")
            WeatherTripStore.save([past, open], file: file)
            let loadedSnapshot = WeatherSnapshot.load(defaults: defaults, files: homeFiles, tripsFile: file)
            check("the snapshot loads each trip's weather from its folder", loadedSnapshot.trips.count == 2 && loadedSnapshot.locationName(at: date(2025, 3, 7, 12)) != nil)
            // A trip whose weather has not been downloaded yet: its days show no weather, not home's.
            let pending = trip(lisbon, date(2025, 3, 2), date(2025, 3, 4))
            let pendingFile = dl.appending(path: "pending.json")
            WeatherTripStore.save([pending], file: pendingFile)
            let beforeDownload = WeatherSnapshot.load(defaults: defaults, files: homeFiles, tripsFile: pendingFile)
            check("a trip not downloaded yet is on the snapshot with no weather: its days show none, and the days around it still show home's",
                  beforeDownload.trips.count == 1 && beforeDownload.sample(at: date(2025, 3, 3, 12)) == nil && beforeDownload.locationName(at: date(2025, 3, 3, 12)) == nil && beforeDownload.sample(at: date(2025, 3, 1, 12)) != nil && beforeDownload.locationName(at: date(2025, 3, 1, 12)) == "Oslo")
            WeatherStatus.removeCaches(ofTripsNotIn: [open], base: dl)
            check("removing a trip forgets its downloaded weather and keeps the others'", !FileManager.default.fileExists(atPath: WeatherTripStore.cacheDirectory(for: past, base: dl).path) && FileManager.default.fileExists(atPath: WeatherTripStore.cacheDirectory(for: open, base: dl).path))
            homeFiles.removeAll()
            WeatherTripStore.save([past], file: file)
            check("removing the downloaded weather leaves the trips themselves", WeatherTripStore.load(file: file) == [past])
        } catch {
            check("a trip downloads from a stand-in service", false, "\(error)")
        }

        // Backups carry the home place and the trips.
        let book = WeatherLocationBook(home: oslo, trips: [past, trip(oslo, mar15, nil)])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        check("the home place and trips survive a trip through backup JSON", (try? decoder.decode(WeatherLocationBook.self, from: encoder.encode(book))) == book)
        let restoreDefaults = UserDefaults(suiteName: "weather-restore-\(UUID().uuidString)")!
        let restoreFile = folder.appending(path: "restored.json")
        NativeBackupEngine.restoreWeatherLocations(book, tripsFile: restoreFile, defaults: restoreDefaults)
        check("a restore puts the home place and trips back", WeatherSettings.place(defaults: restoreDefaults) == oslo && WeatherTripStore.load(file: restoreFile) == book.trips)
        NativeBackupEngine.restoreWeatherLocations(nil, tripsFile: restoreFile, defaults: restoreDefaults)
        check("restoring an older backup (without them) leaves the current ones alone", WeatherSettings.place(defaults: restoreDefaults) == oslo && WeatherTripStore.load(file: restoreFile) == book.trips)
    }

    // MARK: - What an artist or album leans into

    /// A snapshot over March and April 2025 with the stand-in weather (rain at 06–08 UTC, snow at 20–21, clear otherwise).
    private static func marchApril() -> WeatherSnapshot {
        let startHour = WeatherSeries.hour(of: date(2025, 3, 1))
        var series = WeatherSeries(startHour: startHour, count: 24 * 61)
        for h in startHour..<(startHour + 24 * 61) { series.set(hour: h, weather(atHour: h)) }
        return WeatherSnapshot(series: series, placeName: "Oslo, Norway", percentiles: (20, 80))
    }

    private static func playAt(_ artist: String, _ album: String = "", _ track: String = "", day: Int, month: Int = 3, hour h: Int, minute: Int = 0) -> ScrobbleSnapshot {
        ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track.isEmpty ? "Track \(artist)" : track, imageURL: nil, playedAt: date(2025, month, day, h, minute))
    }

    @MainActor
    private static func leaningChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { a.map { abs($0 - b) < tolerance } ?? false }
        let weather = marchApril()
        let range = DateRange(from: date(2025, 3, 1), to: date(2025, 4, 30, 23))
        // R: 50 plays at 07:00 over 10 days (all rain). C: 50 at noon (none). M: 25 + 25. S: 50 plays in ONE rainy sitting. T: 10 plays (too few).
        var plays: [ScrobbleSnapshot] = []
        for i in 0..<50 { plays.append(playAt("R", day: 1 + i % 10, hour: 7, minute: i)) }
        for i in 0..<50 { plays.append(playAt("C", day: 1 + i % 10, hour: 12, minute: i)) }
        for i in 0..<25 { plays.append(playAt("M", day: 1 + i % 5, hour: 7, minute: i)); plays.append(playAt("M", day: 1 + i % 5, hour: 12, minute: 30 + i)) }
        for i in 0..<50 { plays.append(playAt("S", day: 20, hour: 7, minute: i)) }
        for i in 0..<10 { plays.append(playAt("T", day: 1 + i, hour: 12)) }
        plays.sort { $0.playedAt < $1.playedAt }
        let result = TrendsLeaningsEngine.compute(scrobbles: plays, weather: weather, range: range, target: .artist, choice: "Rain", adjust: false, calendar: utc)
        // Rain plays: R 50 + M 25 + S 50 = 125 of 210 → 125/210 of everything is rain; R is expected 50 × 125/210.
        let overall = 125.0 / 210
        check("every play with weather counts once: 210, and the overall share in rain is 125 of 210", result.totalPlays == 210 && near(result.baselineShare, overall), "\(result.totalPlays) \(String(describing: result.baselineShare))")
        check("a play outside the period or without weather says nothing", TrendsLeaningsEngine.compute(scrobbles: plays, weather: weather, range: DateRange(from: date(2025, 3, 1), to: date(2025, 3, 2)), target: .artist, choice: "Rain", adjust: false, calendar: utc).totalPlays < 210 && TrendsLeaningsEngine.compute(scrobbles: plays, weather: .empty, range: range, target: .artist, choice: "Rain", adjust: false, calendar: utc).totalPlays == 0)
        let r = result.toward.first
        check("the artist played only in rain leans most: 50 of 50 plays on 10 days, 50 ÷ (50 × 125/210) = 1.68×", result.toward.map(\.name) == ["R"] && r?.plays == 50 && r?.inWeather == 50 && r?.days == 10 && near(r?.lift, 50 / (50 * overall)), "\(result.toward.map { ($0.name, $0.lift, $0.days) })")
        check("a sitting on one rainy day is not a pattern: S has the same lift but one day, so it is left out", !result.toward.contains { $0.name == "S" } && result.eligible == 4, "\(result.eligible)")
        check("only a lean of 15% or more is listed, either way", (result.toward.allSatisfy { $0.lift >= TrendsLeaningsEngine.minimumLift }) && (result.away.allSatisfy { $0.lift <= TrendsLeaningsEngine.maximumAwayLift }) && TrendsLeaningsEngine.minimumLift == 1.15)
        check("an item with too few plays is not judged at all (T has 10)", !(result.toward + result.away).contains { $0.name == "T" })
        check("an even mix is not 'more': M is 25 of 50, 0.84×, so it is not on the list", !result.toward.contains { $0.name == "M" })
        check("the artist never played in rain is the one it leans away from: 0 of 50 with 29.8 expected, lift 0", result.away.first?.name == "C" && near(result.away.first?.lift, 0) && near(result.away.first?.expected, 50 * overall), "\(result.away.map { ($0.name, $0.lift, $0.expected) })")
        check("away needs enough expected plays to mean something: T (expected 6) is not on the list", !result.away.contains { $0.name == "T" })
        check("the least-played-in-rain list is ordered from the lowest lift up (C 0, then M 0.84)", result.away.map(\.name) == ["C", "M"], "\(result.away.map(\.name))")
        // The time of year: Y plays 40 times in a month that is all rain, Z 40 in a month with none.
        var seasonal: [ScrobbleSnapshot] = []
        for i in 0..<40 { seasonal.append(playAt("Y", day: 1 + i % 8, month: 3, hour: 7, minute: i)) }
        for i in 0..<40 { seasonal.append(playAt("Z", day: 1 + i % 8, month: 4, hour: 12, minute: i)) }
        seasonal.sort { $0.playedAt < $1.playedAt }
        let raw = TrendsLeaningsEngine.compute(scrobbles: seasonal, weather: weather, range: range, target: .artist, choice: "Rain", adjust: false, calendar: utc)
        let adjusted = TrendsLeaningsEngine.compute(scrobbles: seasonal, weather: weather, range: range, target: .artist, choice: "Rain", adjust: true, calendar: utc)
        check("without allowing for the time of year, the artist of the rainy month leans 2×", raw.toward.first?.name == "Y" && near(raw.toward.first?.lift, 2), "\(raw.toward.map { ($0.name, $0.lift) })")
        check("allowing for it, that is just the month: lift 1×, nothing leans, and the dry month's artist was never expected any rain", adjusted.toward.isEmpty && adjusted.away.isEmpty && adjusted.adjusted)
        // A temperature band, albums and tracks.
        let cold = TrendsLeaningsEngine.compute(scrobbles: plays, weather: weather, range: range, target: .track, choice: "Cold", adjust: false, calendar: utc)
        check("a temperature band counts the plays with a temperature, and a track is its own item", cold.totalPlays == 210 && cold.eligible == 4 && (cold.toward + cold.away).allSatisfy { $0.id.target == .track })
        let albumPlays = plays.map { ScrobbleSnapshot(artistName: $0.artistName, albumName: $0.artistName == "R" ? "" : "Album \($0.artistName)", trackName: $0.trackName, imageURL: nil, playedAt: $0.playedAt) }
        let albums = TrendsLeaningsEngine.compute(scrobbles: albumPlays, weather: weather, range: range, target: .album, choice: "Rain", adjust: false, calendar: utc)
        check("plays with no album are left out of an album list", albums.totalPlays == 160 && !(albums.toward + albums.away).contains { $0.artist == "R" })
        let withArt = plays.map { ScrobbleSnapshot(artistName: $0.artistName, albumName: "Album \($0.artistName)", trackName: $0.trackName, imageURL: $0.artistName == "R" ? "https://example.test/r.jpg" : nil, playedAt: $0.playedAt) }
        let art = TrendsLeaningsEngine.compute(scrobbles: withArt, weather: weather, range: range, target: .track, choice: "Rain", adjust: false, calendar: utc)
        check("a row carries the album it was played under and the artwork its plays had, for the thumbnail", art.toward.first?.album == "Album R" && art.toward.first?.fallbackImageURL == "https://example.test/r.jpg" && art.away.first?.fallbackImageURL == nil, "\(String(describing: art.toward.first?.album)) \(String(describing: art.toward.first?.fallbackImageURL))")
        check("an unknown weather gives nothing", TrendsLeaningsEngine.compute(scrobbles: plays, weather: weather, range: range, target: .artist, choice: "Lukewarm", adjust: false, calendar: utc) == .empty)
        // What a row opens.
        let drill = TrendsLeaningsEngine.drillSpec(for: r!, choice: "Rain", range: range)
        check("an artist row opens its tracks played in rain, in the period", drill.target == .track && drill.playFilter?.weatherConditions == ["Rain"] && drill.playFilter?.temperatureBands == nil && drill.period?.from == range.from && drill.groups[0].contains { $0.field.id == "artist" && $0.operands == [.text("R")] })
        let coldDrill = TrendsLeaningsEngine.drillSpec(for: TrendsLeaningItem(id: QueryEntityID(target: .album, artist: "R", name: "X"), plays: 1, inWeather: 1, expected: 1, days: 1), choice: "Cold", range: range)
        check("a temperature row filters by the band, and an album row opens that album", coldDrill.target == .album && coldDrill.playFilter?.temperatureBands == ["Cold"] && coldDrill.playFilter?.weatherConditions == nil && coldDrill.groups[0].contains { $0.field.id == "name" })
        // The rows Query shows for that drill are exactly the plays counted: R's 50 rain plays.
        var rainSpec = drill
        rainSpec.columns = [QueryFieldRef("plays")]
        var snapshots = QuerySnapshots(); snapshots.weather = weather
        if let validated = try? rainSpec.validate(against: .standard) {
            let run = QueryRun(target: .track, asOf: date(2025, 5, 1), scrobbles: rainSpec.countedPlays(plays, weather: weather), allTimeScrobbles: plays, snapshots: snapshots)
            let rows = QueryEngine.evaluate(validated, run: run)
            let key = rows.columns.first?.cacheKey ?? ""
            let total = rows.rows.reduce(0) { sum, row in if case .value(.number(let n))? = row.cells[key] { sum + Int(n) } else { sum } }
            check("the plays that drill opens are exactly the 50 the row counted", total == r?.inWeather, "\(total)")
        } else { check("the drill is a valid query", false) }
    }

    // MARK: - The artist weather map

    @MainActor
    private static func mapChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { a.map { abs($0 - b) < tolerance } ?? false }
        let engine = TrendsWeatherMapEngine.self
        // The ranges of temperature.
        check("a temperature falls in its five-degree range: 4.99 is 0 to 5, 5 is 5 to 10, −0.1 is −5 to 0", engine.bin(of: 4.99) == 4 && engine.bin(of: 5) == 5 && engine.bin(of: -0.1) == 3)
        check("the coldest and warmest ranges are open: −15.1 and −60 are below −15, 40 and 100 are 40 and up", engine.bin(of: -15) == 1 && engine.bin(of: -15.1) == 0 && engine.bin(of: -60) == 0 && engine.bin(of: 40) == 12 && engine.bin(of: 100) == 12)
        let open = engine.range(ofBin: 0), mid = engine.range(ofBin: 5), top = engine.range(ofBin: 12)
        check("a range is as a play filter takes it (from, up to but not including), and the ends are open", open.from == nil && open.to == -15 && mid.from == 5 && mid.to == 10 && top.from == 40 && top.to == nil)
        check("a range reads in either unit: 5 to 10 °C is 41 to 50 °F", engine.rangeText(bin: 5, unit: .celsius) == "5 to \(TemperatureUnit.celsius.text(shown: 10))" && engine.rangeText(bin: 5, unit: .fahrenheit) == "41 to \(TemperatureUnit.fahrenheit.text(shown: 50))", engine.rangeText(bin: 5, unit: .fahrenheit))

        // R: 50 plays at 07:00 (rain, 5 °C) on 10 days. C: 50 at noon (clear, 10 °C). M: 25 + 25. S: 50 in one rainy sitting. T: 10 (too few).
        let weather = marchApril()
        let range = DateRange(from: date(2025, 3, 1), to: date(2025, 4, 30, 23))
        var plays: [ScrobbleSnapshot] = []
        for i in 0..<50 { plays.append(playAt("R", day: 1 + i % 10, hour: 7, minute: i)) }
        for i in 0..<50 { plays.append(playAt("C", day: 1 + i % 10, hour: 12, minute: i)) }
        for i in 0..<25 { plays.append(playAt("M", day: 1 + i % 5, hour: 7, minute: i)); plays.append(playAt("M", day: 1 + i % 5, hour: 12, minute: 30 + i)) }
        for i in 0..<50 { plays.append(playAt("S", day: 20, hour: 7, minute: i)) }
        for i in 0..<10 { plays.append(playAt("T", day: 1 + i, hour: 12)) }
        plays.sort { $0.playedAt < $1.playedAt }
        let result = engine.compute(scrobbles: plays, weather: weather, range: range, adjust: false, calendar: utc)
        let clearBin6 = 0 * engine.bins + 6, rainBin5 = 3 * engine.bins + 5
        check("every play with a weather and a temperature falls in exactly one cell: 210, 125 in rain at 5 to 10 and 85 in clear at 10 to 15", result.totalPlays == 210 && result.cellTotals.reduce(0, +) == 210 && result.cellTotals[rainBin5] == 125 && result.cellTotals[clearBin6] == 85, "\(result.totalPlays) \(result.cellTotals.filter { $0 > 0 })")
        check("the usual share of each weather is its plays over all: clear 85/210, rain 125/210", near(result.baseline[0], 85.0 / 210) && near(result.baseline[3], 125.0 / 210))
        check("only weathers with 30+ plays get a row: clear and rain; none are left out when the others have no plays at all", result.rows == [.clear, .rain] && result.leftOut.isEmpty)
        check("an artist with fewer than 30 plays is not placed (T has 10), the rest are", result.candidates.map(\.artist).sorted() == ["C", "M", "R", "S"], "\(result.candidates.map(\.artist))")
        let byName = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.artist, $0) })
        // R: rain at 5 to 10 °C: 50 plays, expected 50 × 125/210, so 1.68×; score ln((50 + 5) / (29.76 + 5)).
        let r = byName["R"]?.affinity
        check("R leans into rain at 5 to 10: 50 plays on 10 days, expected 50 × 125/210, at 5 °C", r?.condition == .rain && r?.bin == 5 && r?.plays == 50 && r?.days == 10 && near(r?.expected, 50 * 125.0 / 210) && near(r?.temperature, 5) && near(r?.lift, 210.0 / 125), "\(String(describing: r))")
        check("the score is the lean damped by 5 plays on each side: ln(55 ÷ 34.76) for R, ln(55 ÷ 25.24) for C", near(r?.score, log(55 / (50 * 125.0 / 210 + 5))) && near(byName["C"]?.affinity?.score, log(55 / (50 * 85.0 / 210 + 5))), "\(String(describing: r?.score))")
        check("M plays half and half, which is not enough more than usual in either cell (rain 0.84×, clear 1.24×): no lean, but it is placed where it plays most", byName["M"]?.affinity == nil && byName["M"]?.modal.condition == .clear)
        check("S has the same lean as R but on one day (one long sitting is not a pattern): no lean, most played is rain", byName["S"]?.affinity == nil && byName["S"]?.modal.condition == .rain && byName["S"]?.modal.days == 1)
        check("an artist's plays by weather and by temperature add up to its plays", byName.values.allSatisfy { $0.conditionPlays.reduce(0, +) == $0.plays && $0.binPlays.reduce(0, +) == $0.plays })
        check("an artist's average temperature is over all its plays: M is 25 at 5 °C and 25 at 10 °C, 7.5", near(byName["M"]?.averageTemperature, 7.5))
        let affinity = result.bubbles(mode: .affinity, count: 25)
        check("weather affinity shows the artists that lean, strongest first: C (clear, 10 °C), then R", affinity.map(\.id) == ["C", "R"] && affinity[0].placement.condition == .clear && near(affinity[0].placement.temperature, 10), "\(affinity.map(\.id))")
        let played = result.bubbles(mode: .mostPlayed, count: 3)
        check("most played shows the most played artists (all 50, by name), cut at the count", played.map(\.id) == ["C", "M", "R"], "\(played.map(\.id))")
        check("most played puts an artist where it is played most (R in rain at 5 to 10 °C)", played[2].placement.condition == .rain && played[2].placement.bin == 5)
        check("the sentence reads the lean: R is 1.7× as often as usual in rain at 5 to 10 °C", engine.sentence(affinity[1].placement, unit: .celsius) == "1.7× as often as usual in rain at 5 to \(TemperatureUnit.celsius.text(shown: 10))", engine.sentence(affinity[1].placement, unit: .celsius))
        // Luck: 8 plays where 6.4 were expected is 1.25× but not significant; 14 where 8 were expected is.
        func lean(_ plays: Int, expected: Double) -> Bool { Double(plays) / expected >= engine.minimumLift && (Double(plays) - expected) / expected.squareRoot() >= engine.minimumSignificance }
        check("a lean has to be more than luck: 8 plays against 6.4 expected is not, 50 against 29.8 and 25 against 12 are", !lean(8, expected: 6.4) && lean(50, expected: 29.76) && lean(25, expected: 12) && engine.minimumSignificance == 2.5)
        // The ring: grey for usual, orange more, blue less, stronger the further from usual.
        check("a lean is coloured by how far from usual: none at 1×, a modest lean already shows (1.25×), full at 3× and beyond, blue below 1", WeatherPalette.leanStrength(1) == 0 && WeatherPalette.leanStrength(1.25) > 0.3 && WeatherPalette.leanStrength(3) == 1 && WeatherPalette.leanStrength(8) == 1 && WeatherPalette.leanStrength(2) > WeatherPalette.leanStrength(1.5) && WeatherPalette.leanStrength(0.3) > WeatherPalette.leanStrength(0.8) && WeatherPalette.leanStrength(0) == 1, "\(WeatherPalette.leanStrength(1.25))")
        check("a picture is drawn only on a bubble big enough to recognise anyone in (radius 9 and up); the artist's saved picture is found, and none when there is none", engine.artworkMinimumRadius == 9 && engine.artworkURL(for: "Nobody", lookup: [:]) == nil && engine.artworkURL(for: "R", lookup: [ImageResolutionEngine.lookupKey(for: ImageTarget(kind: .artist, artist: "R", album: nil, track: nil)): "file:///art/r.png"]) == "file:///art/r.png")
        // The ring: coloured against the others shown, so a Top 10 of strong leans still shows who leans most.
        let scale = TrendsWeatherMapRingScale(lifts: [1.5, 2, 3, 4, 10])
        check("the ring scale runs from the weakest lean shown to the 80th percentile (4×), with the strongest beyond it at full colour", near(scale.low, 1.5) && near(scale.high, 4) && near(scale.position(1.5), 0) && near(scale.position(4), 1) && near(scale.position(10), 1) && near(scale.position(2), log(2 / 1.5) / log(4 / 1.5)), "\(scale.low) \(scale.high)")
        check("each lean has its own colour, the same lean the same colour, and blue below usual", scale.color(1.5) != scale.color(2) && scale.color(2) != scale.color(3) && scale.color(3) != scale.color(4) && scale.color(4) == scale.color(10) && scale.color(2) == scale.color(2) && scale.color(0.5) == WeatherPalette.lean(0.5))
        let flat = TrendsWeatherMapRingScale(lifts: [2.0, 2.05, 2.1])
        check("leans that are all about the same share one middle colour instead of being stretched apart", near(flat.position(2.05), 0.6) && flat.color(2.0) == flat.color(2.1))
        // No one cell may take more than a quarter of the map (and never fewer than three).
        func fake(_ name: String, score: Double, condition: WeatherCondition, bin: Int) -> TrendsWeatherMapCandidate {
            let place = TrendsWeatherMapPlacement(condition: condition, bin: bin, plays: 20, expected: 5, days: 8, temperature: 7, score: score)
            return TrendsWeatherMapCandidate(artist: name, plays: 100, averageTemperature: 7, conditionPlays: [Int](repeating: 0, count: 6), binPlays: [Int](repeating: 0, count: 13), affinity: place, modal: place)
        }
        let crowd = (0..<10).map { fake("big\($0)", score: 2 - Double($0) * 0.01, condition: .rain, bin: 5) } + (0..<2).map { fake("small\($0)", score: 0.5 - Double($0) * 0.01, condition: .snow, bin: 1) }
        let spread = TrendsWeatherMapResult(revision: UUID(), candidates: crowd, cellTotals: [], conditionTotals: [], baseline: [], totalPlays: 0, adjusted: false)
        let eight = spread.bubbles(mode: .affinity, count: 8).map(\.id)
        check("a crowded cell stops at a quarter of the map (3 of 8) and the others still show: the 3 strongest rainy ones, then the snowy ones", eight == ["big0", "big1", "big2", "small0", "small1"], "\(eight)")
        // The time of year: Y plays 40 times in a rainy month, Z 40 in a clear one.
        var seasonal: [ScrobbleSnapshot] = []
        for i in 0..<40 { seasonal.append(playAt("Y", day: 1 + i % 8, month: 3, hour: 7, minute: i)) }
        for i in 0..<40 { seasonal.append(playAt("Z", day: 1 + i % 8, month: 4, hour: 12, minute: i)) }
        seasonal.sort { $0.playedAt < $1.playedAt }
        let raw = engine.compute(scrobbles: seasonal, weather: weather, range: range, adjust: false, calendar: utc).bubbles(mode: .affinity, count: 25)
        let allowed = engine.compute(scrobbles: seasonal, weather: weather, range: range, adjust: true, calendar: utc)
        check("without allowing for the time of year, the artist of the rainy month leans 2× into rain", raw.first(where: { $0.id == "Y" }).map { near($0.placement.lift, 2) && $0.placement.condition == .rain } ?? false, "\(raw.map { ($0.id, $0.placement.lift) })")
        check("allowing for it, that is just the month: nobody leans, and the map says adjusted", allowed.bubbles(mode: .affinity, count: 25).isEmpty && allowed.adjusted && allowed.candidates.count == 2)
        check("nothing to place without weather, outside the period, or for an empty history", engine.compute(scrobbles: plays, weather: .empty, range: range, adjust: false, calendar: utc) == .empty && engine.compute(scrobbles: [], weather: weather, range: range, adjust: false, calendar: utc).candidates.isEmpty && engine.compute(scrobbles: plays, weather: weather, range: DateRange(from: date(2024, 1, 1), to: date(2024, 1, 2)), adjust: false, calendar: utc).totalPlays == 0)
        // Where bubbles go: across by temperature, down by weather, kept in their lane, a crowd spread up and down only.
        let size = CGSize(width: 700, height: 320)
        let placed = TrendsWeatherMapLayout.make(bubbles: affinity, result: result, size: size)
        let c = placed.placed.first { $0.id == "C" }, rr = placed.placed.first { $0.id == "R" }
        check("each bubble sits in its weather's lane and its temperature's column: C (clear) above R (rain), R colder than C, so left of it", c != nil && rr != nil && c!.y < rr!.y && rr!.x < c!.x && rr!.x >= placed.x(forCelsius: 5) - 0.01 && rr!.x - placed.x(forCelsius: 5) <= rr!.radius && c!.x - placed.x(forCelsius: 10) <= c!.radius, "\(String(describing: c)) \(String(describing: rr))")
        let packed = TrendsWeatherMapResult(revision: UUID(), candidates: (0..<60).map { fake("a\($0)", score: 1, condition: .rain, bin: 5) }, cellTotals: result.cellTotals, conditionTotals: result.conditionTotals, baseline: result.baseline, totalPlays: 210, adjusted: false)
        let crowdLayout = TrendsWeatherMapLayout.make(bubbles: packed.bubbles(mode: .mostPlayed, count: 60), result: packed, size: size)
        let lane = crowdLayout.row(of: .rain) ?? 0
        let laneTop = crowdLayout.laneTop(lane), laneBottom = laneTop + crowdLayout.laneHeight(lane)
        let columnLeft = crowdLayout.x(forCelsius: 5), columnRight = crowdLayout.x(forCelsius: 10)
        check("sixty bubbles in one cell stay inside it: their lane and their five degrees", crowdLayout.placed.count == 60 && crowdLayout.placed.allSatisfy { $0.x >= columnLeft - 0.01 && $0.x <= columnRight + 0.01 && $0.y - $0.radius >= laneTop - 0.5 && $0.y + $0.radius <= laneBottom + 0.5 })
        func overlaps(_ layout: TrendsWeatherMapLayout) -> Int {
            var count = 0
            for (index, a) in layout.placed.enumerated() { for b in layout.placed[(index + 1)...] where hypot(a.x - b.x, a.y - b.y) < (a.radius + b.radius) * 0.5 { count += 1 } }
            return count
        }
        check("and they are packed so that none sits mostly on another", overlaps(crowdLayout) == 0, "\(overlaps(crowdLayout))")
        check("a bubble is found under the pointer, and not away from it", placed.bubble(at: CGPoint(x: c!.x, y: c!.y))?.id == "C" && placed.bubble(at: CGPoint(x: 1, y: 1)) == nil)
        // What a bubble opens: exactly its plays in that weather and range of temperature.
        let drill = engine.drillSpec(for: affinity[1], range: range)
        check("a bubble opens its artist's tracks played in that weather at those temperatures, in the period", drill.target == .track && drill.playFilter?.weatherConditions == ["Rain"] && drill.playFilter?.temperatureFrom == 5 && drill.playFilter?.temperatureTo == 10 && drill.period?.from == range.from && drill.groups[0].contains { $0.field.id == "artist" && $0.operands == [.text("R")] })
        for bubble in affinity {
            var spec = engine.drillSpec(for: bubble, range: range)
            spec.columns = [QueryFieldRef("plays")]
            var snapshots = QuerySnapshots(); snapshots.weather = weather
            if let validated = try? spec.validate(against: .standard) {
                let run = QueryRun(target: .track, asOf: date(2025, 5, 1), scrobbles: spec.countedPlays(plays, weather: weather), allTimeScrobbles: plays, snapshots: snapshots)
                let rows = QueryEngine.evaluate(validated, run: run)
                let key = rows.columns.first?.cacheKey ?? ""
                let total = rows.rows.reduce(0) { sum, row in if case .value(.number(let n))? = row.cells[key] { sum + Int(n) } else { sum } }
                check("the plays the drill for \(bubble.id) opens are exactly the \(bubble.placement.plays) its bubble counted", total == bubble.placement.plays, "\(total)")
            } else { check("the drill for \(bubble.id) is a valid query", false) }
        }
    }

    @MainActor
    private static func placeChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { a.map { abs($0 - b) < tolerance } ?? false }
        let lisbon = WeatherPlace(name: "Lisbon, Portugal", latitude: 38.72, longitude: -9.14)
        let trip = WeatherTrip(place: lisbon, from: date(2025, 3, 5), until: date(2025, 3, 10))
        var snapshot = marchApril()
        var away = WeatherSeries(startHour: WeatherSeries.hour(of: date(2025, 3, 5)), count: 24 * 5)
        for h in away.startHour..<(away.startHour + 24 * 5) { away.set(hour: h, WeatherSample(temperature: 20 + Double(h % 24) / 10, precipitation: nil, rain: nil, snowfall: nil, code: 61)) }
        snapshot.trips = [WeatherSnapshot.TripWeather(trip: trip, series: away)]
        // 20 days, Mar 1–20: two plays a day at home (A at 10:00 and 15:00), one at noon on each trip day (B, new on the trip, on top of A's).
        var plays: [ScrobbleSnapshot] = []
        for d in 1...20 {
            if (5...9).contains(d) {
                plays.append(playAt(d == 5 ? "A" : "B", day: d, hour: 12))
            } else {
                plays.append(playAt("A", day: d, hour: 10)); plays.append(playAt("A", day: d, hour: 15))
            }
        }
        let range = DateRange(from: date(2025, 3, 1), to: date(2025, 3, 20, 23, 59))
        let now = date(2025, 3, 20, 23, 59)
        let result = TrendsPlacesEngine.compute(scrobbles: plays, weather: snapshot, range: range, now: now, calendar: utc)
        let home = result.home, lisbonStay = result.trips.first
        check("home is the other 15 days and 30 plays, 2 a day; the trip is 5 days and 5 plays, 1 a day", home?.days == 15 && home?.plays == 30 && near(home?.perDay, 2) && lisbonStay?.days == 5 && lisbonStay?.plays == 5 && near(lisbonStay?.perDay, 1), "\(String(describing: home?.days)) \(String(describing: home?.plays)) \(String(describing: lisbonStay?.days)) \(String(describing: lisbonStay?.plays))")
        check("the trip is half as much a day as home", near(lisbonStay.flatMap { result.relativeToHome($0) }, 0.5))
        check("the city and the trip's dates are the trip's, cut to the period", lisbonStay?.city == "Lisbon" && lisbonStay?.from == date(2025, 3, 5) && lisbonStay?.until == date(2025, 3, 10) && home?.city == "Oslo")
        check("an artist is new where its first play ever was made: B on the trip, A at home", lisbonStay?.newArtists == 1 && home?.newArtists == 1, "\(String(describing: lisbonStay?.newArtists)) \(String(describing: home?.newArtists))")
        check("the trip's top artists are by plays there (B 4, A 1) and home's is A", lisbonStay?.topArtists == [TrendsStay.Artist(name: "B", plays: 4), TrendsStay.Artist(name: "A", plays: 1)] && home?.topArtists == [TrendsStay.Artist(name: "A", plays: 30)], "\(String(describing: lisbonStay?.topArtists))")
        check("the weather of a stay is the weather where you were: the trip is 21.2° and all rain, home's noon-free plays are clear", near(lisbonStay?.averageTemperature, 21.2, 1e-9) && near(lisbonStay?.rainShare, 1) && near(home?.rainShare, 0), "\(String(describing: lisbonStay?.averageTemperature)) \(String(describing: home?.rainShare))")
        check("the chart has a bucket for each of the 20 days with each day's plays a day", result.bucketDays == 1 && result.buckets.count == 20 && result.buckets[0].plays == 2 && result.buckets[5].plays == 1 && near(result.buckets[5].perDay, 1))
        check("the plays in the buckets are all 35 plays of the period", result.buckets.reduce(0) { $0 + $1.plays } == 35)
        // A trip going on, and a period that ends part-way through it.
        let partial = TrendsPlacesEngine.compute(scrobbles: plays, weather: snapshot, range: DateRange(from: date(2025, 3, 1), to: date(2025, 3, 7, 23, 59)), now: now, calendar: utc)
        check("a period that ends during the trip cuts it: 3 days (5, 6, 7) and its plays up to then", partial.trips.first?.days == 3 && partial.trips.first?.plays == 3 && partial.trips.first?.until == date(2025, 3, 7, 23, 59), "\(String(describing: partial.trips.first?.days)) \(String(describing: partial.trips.first?.plays))")
        check("a period with no trip has no trips (the chart is not drawn)", TrendsPlacesEngine.compute(scrobbles: plays, weather: snapshot, range: DateRange(from: date(2025, 3, 11), to: date(2025, 3, 20, 23, 59)), now: now, calendar: utc).trips.isEmpty)
        check("with no weather or home place there is nothing to compare", TrendsPlacesEngine.compute(scrobbles: plays, weather: .empty, range: range, now: now, calendar: utc) == .empty)
        var open = snapshot
        open.trips = [WeatherSnapshot.TripWeather(trip: WeatherTrip(place: lisbon, from: date(2025, 3, 18), until: nil), series: away)]
        let ongoing = TrendsPlacesEngine.compute(scrobbles: plays, weather: open, range: range, now: now, calendar: utc)
        check("a trip you are still on runs to now: from the 18th, 3 days", ongoing.trips.first?.days == 3 && ongoing.trips.first?.until == now, "\(String(describing: ongoing.trips.first?.days))")
        // Colours and names on the chart: each trip has its own colour in the order it happened, and names that would collide are staggered.
        var twoTrips = snapshot
        twoTrips.trips = [WeatherSnapshot.TripWeather(trip: trip, series: away), WeatherSnapshot.TripWeather(trip: WeatherTrip(place: WeatherPlace(name: "Oslo, Norway", latitude: 59.9, longitude: 10.7), from: date(2025, 3, 14), until: date(2025, 3, 17)), series: away)]
        let colored = TrendsPlacesEngine.compute(scrobbles: plays, weather: twoTrips, range: range, now: now, calendar: utc)
        check("each trip has its own colour in the order they happened, and home is grey", colored.trips.count == 2 && colored.tint(for: colored.trips[1]) == TrendsPlacesResult.tripColors[0] && colored.tint(for: colored.trips[0]) == TrendsPlacesResult.tripColors[1] && colored.tint(for: colored.home!) == .secondary && TrendsPlacesResult.tripColors[0] != TrendsPlacesResult.tripColors[1])
        // The same place twice is the same colour: Lisbon, Oslo, then Lisbon again.
        var revisit = snapshot
        revisit.trips = twoTrips.trips + [WeatherSnapshot.TripWeather(trip: WeatherTrip(place: lisbon, from: date(2025, 3, 18), until: date(2025, 3, 19)), series: away)]
        let again = TrendsPlacesEngine.compute(scrobbles: plays, weather: revisit, range: range, now: now, calendar: utc)
        let lisbons = again.trips.filter { $0.city == "Lisbon" }, oslos = again.trips.filter { $0.city == "Oslo" }
        check("every trip to the same city is the same colour (two Lisbon trips), and another city has its own", lisbons.count == 2 && oslos.count == 1 && again.tint(for: lisbons[0]) == again.tint(for: lisbons[1]) && again.tint(for: lisbons[0]) != again.tint(for: oslos[0]) && again.spans.filter { $0.colorKey == lisbons[0].colorKey }.count == 2, "\(again.trips.map(\.city))")
        check("trip names that don't collide share a row", TrendsPlacesChart.labelLanes([(x: 10, width: 40), (x: 100, width: 40), (x: 200, width: 40)]) == [0, 0, 0])
        check("names that would run into each other go on other rows, and one is left out when every row is taken", TrendsPlacesChart.labelLanes([(x: 10, width: 40), (x: 30, width: 40), (x: 60, width: 40), (x: 200, width: 40)]) == [0, 1, 0, 0] && TrendsPlacesChart.labelLanes([(x: 10, width: 100), (x: 20, width: 100), (x: 30, width: 100), (x: 40, width: 100)]) == [0, 1, 2, nil])
        // Grouping trips by region or country.
        let lisbonPT = WeatherPlace(name: "Lisbon, Portugal", latitude: 38.72, longitude: -9.14, region: nil, country: "Portugal")
        let portoPT = WeatherPlace(name: "Porto, Porto, Portugal", latitude: 41.15, longitude: -8.6, region: "Porto", country: "Portugal")
        let munichDE = WeatherPlace(name: "Munich, Bavaria, Germany", latitude: 48.1, longitude: 11.6)
        let coordinates = WeatherPlace(name: "My place", latitude: 10, longitude: 10)
        let oslo = WeatherPlace(name: "Oslo, Norway", latitude: 59.9, longitude: 10.7)
        check("a place is named at each level: its city, its region (or its country when it has none), its country", [lisbonPT, portoPT].map { [$0.name(at: .city), $0.name(at: .region), $0.name(at: .country)] } == [["Lisbon", "Portugal", "Portugal"], ["Porto", "Porto", "Portugal"]])
        check("a place saved before regions were kept is read from its name: Munich, Bavaria, Germany and Oslo, Norway", [munichDE.name(at: .city), munichDE.name(at: .region), munichDE.name(at: .country)] == ["Munich", "Bavaria", "Germany"] && [oslo.name(at: .region), oslo.name(at: .country)] == ["Norway", "Norway"])
        check("the middle level is called State/Region, the others City and Country", PlaceLevel.allCases.map(\.label) == ["City", "State/Region", "Country"])
        check("coordinates or a name with no region or country is its own entry at every level", PlaceLevel.allCases.allSatisfy { coordinates.name(at: $0) == "My place" })
        check("places saved before this still load, and region and country survive saving", (try? JSONDecoder().decode(WeatherPlace.self, from: Data(#"{"name":"Oslo, Norway","latitude":59.9,"longitude":10.7}"#.utf8)))?.country == nil && (try? JSONDecoder().decode(WeatherPlace.self, from: JSONEncoder().encode(portoPT)))?.region == "Porto")
        var grouped = snapshot
        grouped.trips = [
            WeatherSnapshot.TripWeather(trip: WeatherTrip(place: lisbonPT, from: date(2025, 3, 5), until: date(2025, 3, 10)), series: away),
            WeatherSnapshot.TripWeather(trip: WeatherTrip(place: portoPT, from: date(2025, 3, 12), until: date(2025, 3, 15)), series: away),
            WeatherSnapshot.TripWeather(trip: WeatherTrip(place: munichDE, from: date(2025, 3, 17), until: date(2025, 3, 18)), series: away),
        ]
        func at(_ level: PlaceLevel) -> TrendsPlacesResult { TrendsPlacesEngine.compute(scrobbles: plays, weather: grouped, range: range, level: level, now: now, calendar: utc) }
        let byCity = at(.city), byRegion = at(.region), byCountry = at(.country)
        check("by city every trip is its own stay; by region the two Portuguese trips with different regions stay apart and Lisbon joins the country; by country they join", byCity.trips.count == 3 && byRegion.trips.count == 3 && byCountry.trips.count == 2, "\(byCity.trips.count) \(byRegion.trips.count) \(byCountry.trips.count)")
        let portugal = byCountry.trips.first { $0.city == "Portugal" }
        check("Portugal is both trips together: 8 days (5 + 3), 11 plays (5 + 6), 2 trips, in order of the cities", portugal?.days == 8 && portugal?.plays == 11 && portugal?.tripCount == 2 && portugal?.cities == ["Lisbon", "Porto"], "\(String(describing: portugal?.days)) \(String(describing: portugal?.plays)) \(String(describing: portugal?.cities))")
        check("its dates run from the first trip to the end of the last", portugal?.from == date(2025, 3, 5) && portugal?.until == date(2025, 3, 15))
        check("whatever the level every play and every day is counted once: stays plus home are the 35 plays and 20 days", [byCity, byRegion, byCountry].allSatisfy { $0.trips.reduce($0.home?.plays ?? 0) { $0 + $1.plays } == 35 && $0.trips.reduce($0.home?.days ?? 0) { $0 + $1.days } == 20 && $0.trips.reduce(0) { $0 + $1.tripCount } == 3 })
        check("the chart still has each trip's own stretch (three), in the colour of its stay", byCountry.spans.count == 3 && Set(byCountry.spans.map(\.group)).count == 2 && byCountry.spans.filter { $0.group == portugal?.id }.count == 2)
        check("the two Portuguese trips share a colour and Germany has another", portugal.map { byCountry.tint(for: $0) } != byCountry.trips.first { $0.city == "Germany" }.map { byCountry.tint(for: $0) } && byCountry.spans.filter { $0.group == portugal?.id }.map { byCountry.tint(forKey: $0.colorKey) }.count == 2)
        let portugalDrill = portugal.map { TrendsPlacesEngine.drillSpec(for: $0, target: .track) }
        check("clicking Portugal opens the plays made in either city, between the first trip's start and the last's end", portugalDrill?.playFilter?.cities == ["Lisbon", "Porto"] && portugalDrill?.period?.from == date(2025, 3, 5) && portugalDrill?.period?.to == date(2025, 3, 15))
        check("a group says how many trips it is: “2 trips · 8 days”; a single trip just its days", portugal?.summaryLine == "2 trips · 8 days" && byCity.trips.allSatisfy { $0.tripCount == 1 })
        // Long periods are drawn a week at a time.
        let early = [ScrobbleSnapshot(artistName: "A", albumName: "", trackName: "Track A", imageURL: nil, playedAt: date(2024, 6, 2, 10))] + plays
        let long = TrendsPlacesEngine.compute(scrobbles: early, weather: snapshot, range: DateRange(from: date(2024, 6, 1), to: date(2025, 3, 20, 23, 59)), now: now, calendar: utc)
        check("a period over 200 days is drawn in weeks, each with its days", long.bucketDays == 7 && long.buckets.allSatisfy { $0.days <= 7 } && long.buckets.reduce(0) { $0 + $1.plays } == 36, "\(long.bucketDays) \(long.buckets.count)")
        // What a stay opens.
        let spec = lisbonStay.map { TrendsPlacesEngine.drillSpec(for: $0, target: .track) }
        check("a trip opens the plays made in its city between its dates", spec?.playFilter?.cities == ["Lisbon"] && spec?.period?.from == date(2025, 3, 5) && spec?.period?.to == date(2025, 3, 10) && spec?.target == .track)
        if let spec, let validated = try? { var s = spec; s.columns = [QueryFieldRef("plays")]; return try s.validate(against: .standard) }() {
            var s = spec; s.columns = [QueryFieldRef("plays")]
            var snapshots = QuerySnapshots(); snapshots.weather = snapshot
            let run = QueryRun(target: .track, asOf: date(2025, 5, 1), scrobbles: s.countedPlays(plays, weather: snapshot), allTimeScrobbles: plays, snapshots: snapshots)
            let rows = QueryEngine.evaluate(validated, run: run)
            let key = rows.columns.first?.cacheKey ?? ""
            let total = rows.rows.reduce(0) { sum, row in if case .value(.number(let n))? = row.cells[key] { sum + Int(n) } else { sum } }
            check("the plays that opens are exactly the trip's 5", total == lisbonStay?.plays, "\(total)")
        }
    }

    private static func leanChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { a.map { abs($0 - b) < tolerance } ?? false }
        let jan1 = date(2025, 1, 1)
        let start = WeatherSeries.hour(of: jan1)
        var series = WeatherSeries(startHour: start, count: 240)
        for h in start..<(start + 240) {
            let hod = h % 24
            series.set(hour: h, WeatherSample(temperature: Double(hod), precipitation: nil, rain: nil, snowfall: nil, code: (6...8).contains(hod) ? 61 : ((20...21).contains(hod) ? 71 : 0)))
        }
        let weather = WeatherSnapshot(series: series, placeName: "Test", percentiles: (20, 80))
        let range = DateRange(from: jan1, to: jan1.addingTimeInterval(10 * 86_400 - 1))
        func plays(_ artist: String, hour: Int, count: Int) -> [ScrobbleSnapshot] {
            (0..<count).map { i in
                ScrobbleSnapshot(artistName: artist, albumName: "Album \(artist)", trackName: "Track \(artist)", imageURL: nil,
                                 playedAt: jan1.addingTimeInterval(Double(i % 10) * 86_400 + Double(hour) * 3600 + Double(i / 10) * 60))
            }
        }
        func lean(_ all: [ScrobbleSnapshot], _ artist: String = "A", weather: WeatherSnapshot = weather) -> EntityWeatherLean.Result {
            EntityWeatherLean.compute(plays: all, range: range, weather: weather) { $0.artistName == artist }
        }
        // A: 20 plays in rain, 10 in clear weather. Everyone else (B): 10 in rain, 90 in clear. All at mild temperatures.
        let busy = plays("A", hour: 7, count: 20) + plays("A", hour: 12, count: 10) + plays("B", hour: 7, count: 10) + plays("B", hour: 12, count: 90)
        let result = lean(busy)
        if case .leans(let l) = result {
            check("an artist with 20 of its 30 plays in rain, when 30 of everyone's 130 are, leans into rain 2.89 times (+189%)", l.name == "Rain" && near(l.lift, (20.0 / 30) / (30.0 / 130)) && l.count == 20 && l.total == 30 && !l.isTemperature, "\(l)")
            let fact = EntityWeatherLean.fact(for: result)
            check("the tile reads 'Rain +189%' with '20 of 30 plays' under it", fact?.label == "Weather" && fact?.displayText == "Rain +189%" && fact?.detail == "20 of 30 plays")
        } else {
            check("an artist that plays more in rain leans into rain", false, "\(result)")
        }
        check("fewer than 20 plays with weather is not enough to say anything (and shows no tile)", lean(plays("A", hour: 7, count: 19) + plays("B", hour: 12, count: 100)) == .notEnough && EntityWeatherLean.fact(for: .notEnough) == nil)
        let flat = lean(plays("A", hour: 7, count: 3) + plays("A", hour: 12, count: 27) + plays("B", hour: 7, count: 10) + plays("B", hour: 12, count: 90))
        check("plays that follow the weather like everyone's are 'no standout'", flat == .even(total: 30) && EntityWeatherLean.fact(for: flat)?.displayText == "No standout", "\(flat)")
        check("a weather in fewer than 5 of its plays can't be a lean, however big the share", lean(plays("A", hour: 7, count: 4) + plays("A", hour: 12, count: 21) + plays("B", hour: 12, count: 200)) == .even(total: 25))
        let cold = lean(plays("A", hour: 2, count: 25) + plays("B", hour: 12, count: 100))
        if case .leans(let l) = cold {
            check("an artist played at cold hours (relative to the place) leans into Cold: 25 of 25 against 25 of 125 is 5 times", l.name == "Cold" && l.isTemperature && near(l.lift, 5) && l.count == 25, "\(l)")
            check("…and says so in words: '25 of 25 plays when it was cold'", EntityWeatherLean.fact(for: cold)?.detail == "25 of 25 plays when it was cold" && EntityWeatherLean.fact(for: cold)?.displayText == "Cold +400%")
        } else {
            check("an artist played at cold hours leans into Cold", false, "\(cold)")
        }
        check("with weather off there is no tile", lean(busy, weather: .empty) == .unavailable)
        check("plays before the downloaded weather give no tile at all", EntityWeatherLean.compute(plays: busy, range: DateRange(from: date(2020, 1, 1), to: date(2020, 12, 31)), weather: weather, isEntity: { $0.artistName == "A" }) == .unavailable)
        let outside = busy.map { ScrobbleSnapshot(artistName: $0.artistName, albumName: $0.albumName, trackName: $0.trackName, imageURL: nil, playedAt: $0.playedAt.addingTimeInterval(20 * 86_400)) }
        check("plays outside the period are left out", EntityWeatherLean.compute(plays: busy + outside, range: range, weather: weather, isEntity: { $0.artistName == "A" }) == result)
        // Album matching follows the page's own rule: the album's exact name and its artist (collab credits count).
        let credited = ScrobbleSnapshot(artistName: "Artist A & Artist B", albumName: "Album", trackName: "T", imageURL: nil, playedAt: jan1.addingTimeInterval(7 * 3600))
        check("the album rule counts a collab-credited track toward the artist's own album", TextNormalization.trackMatchesArtistContext(trackArtist: credited.artistName, context: "Artist A") && credited.albumName == "Album")
    }

    // MARK: - The Query fields

    private static func fields(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let start = hour(2025, 1, 1)
        var series = WeatherSeries(startHour: start, count: 240)
        for h in start..<(start + 240) {
            let hod = h % 24
            series.set(hour: h, WeatherSample(temperature: Double(hod), precipitation: nil, rain: nil, snowfall: nil, code: (6...8).contains(hod) ? 61 : (20...21).contains(hod) ? 71 : 0))
        }
        let snapshot = WeatherSnapshot(series: series, placeName: "Test", percentiles: (20, 80))
        func play(_ artist: String, _ d: Date) -> ScrobbleSnapshot {
            ScrobbleSnapshot(artistName: artist, albumName: "Album \(artist)", trackName: "Track \(artist)", imageURL: nil, playedAt: d)
        }
        let day = { (hod: Int, minute: Int) in date(2025, 1, 1, hod, minute) }
        var plays: [ScrobbleSnapshot] = []
        for (artist, hours) in [("A", [7, 7, 7, 12]), ("B", [12, 13, 20]), ("C", [2, 3, 22])] {
            for (i, hod) in hours.enumerated() { plays.append(play(artist, day(hod, 10 + i))) }
        }
        plays.append(play("D", date(2024, 6, 1, 12)))                      // before the downloaded weather
        plays.append(play("E", date(2025, 1, 2, 7))); plays.append(play("E", date(2024, 12, 30, 7)))   // one covered, one not
        plays.sort { $0.playedAt < $1.playedAt }

        func cells(_ ref: QueryFieldRef, weather: WeatherSnapshot = snapshot, conditions: [[QueryCondition]] = []) -> [String: QueryCell] {
            var spec = QuerySpec(target: .artist)
            spec.columns = [ref]
            spec.groups = conditions
            guard let validated = try? spec.validate(against: .standard) else { return [:] }
            var snapshots = QuerySnapshots()
            snapshots.weather = weather
            let run = QueryRun(target: .artist, asOf: date(2025, 2, 1), scrobbles: plays, allTimeScrobbles: plays, snapshots: snapshots)
            let result = QueryEngine.evaluate(validated, run: run)
            let key = result.columns.first?.cacheKey ?? ""
            return Dictionary(uniqueKeysWithValues: result.rows.map { ($0.entity.name, $0.cells[key] ?? .missing) })
        }
        func text(_ c: QueryCell?) -> String? { if case .value(.text(let t))? = c { return t }; return nil }
        func number(_ c: QueryCell?) -> Double? { if case .value(.number(let n))? = c { return n }; return nil }
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

        let condition = cells(QueryFieldRef("weatherCondition"))
        check("the weather most plays were made in: A rain, B clear, C clear, E rain", text(condition["A"]) == "Rain" && text(condition["B"]) == "Clear" && text(condition["C"]) == "Clear" && text(condition["E"]) == "Rain", "\(condition)")
        check("an artist none of whose plays has weather has no value", condition["D"] == .missing || condition["D"] == nil)
        let average = cells(QueryFieldRef("weatherAverageTemperature"))
        check("average temperature: A (7+7+7+12)/4, B (12+13+20)/3, C (2+3+22)/3, E 7 from its one covered play", near(number(average["A"]), 8.25) && near(number(average["B"]), 15) && near(number(average["C"]), 9) && near(number(average["E"]), 7), "\(average)")
        var fahrenheitSnapshot = snapshot
        fahrenheitSnapshot.unit = .fahrenheit
        let averageF = cells(QueryFieldRef("weatherAverageTemperature"), weather: fahrenheitSnapshot)
        check("in Fahrenheit the average is converted once, from the true average: A 8.25 °C is 46.85 °F, B 15 °C is 59 °F", near(number(averageF["A"]), 8.25 * 9 / 5 + 32) && near(number(averageF["B"]), 59), "\(averageF)")
        let bandF = cells(QueryFieldRef("weatherTemperatureBand"), weather: fahrenheitSnapshot)
        check("the unit changes nothing about hot and cold (judged on the Celsius weather)", bandF.mapValues(text) == cells(QueryFieldRef("weatherTemperatureBand")).mapValues(text))
        let band = cells(QueryFieldRef("weatherTemperatureBand"))
        check("with cold at 4° and below and hot at 19° and above: A and B are mostly mild, C mostly cold, E mild", text(band["A"]) == "Mild" && text(band["B"]) == "Mild" && text(band["C"]) == "Cold" && text(band["E"]) == "Mild", "\(band)")
        let rain = cells(QueryFieldRef("weatherShare", parameters: ["weather": .text("Rain")]))
        check("share of plays in rain: A 3 of 4, B 0, C 0, E 1 of its 1 covered play", near(number(rain["A"]), 0.75) && near(number(rain["B"]), 0) && near(number(rain["C"]), 0) && near(number(rain["E"]), 1), "\(rain)")
        let snow = cells(QueryFieldRef("weatherShare", parameters: ["weather": .text("Snow")]))
        check("share of plays in snow: only B's 20:00 play", near(number(snow["B"]), 1.0 / 3) && near(number(snow["A"]), 0), "\(snow)")
        let hot = cells(QueryFieldRef("weatherShare", parameters: ["weather": .text("Hot")]))
        check("share of plays when it was hot for the place: B and C one in three", near(number(hot["B"]), 1.0 / 3) && near(number(hot["C"]), 1.0 / 3) && near(number(hot["A"]), 0), "\(hot)")
        let lift = cells(QueryFieldRef("weatherLift", parameters: ["weather": .text("Rain")]))
        check("rain lift divides by the share across all plays with weather (4 of 11): A 2.0625, B 0, E 2.75", near(number(lift["A"]), 0.75 / (4.0 / 11)) && near(number(lift["B"]), 0) && near(number(lift["E"]), 1 / (4.0 / 11)), "\(lift)")
        let hotLift = cells(QueryFieldRef("weatherLift", parameters: ["weather": .text("Hot")]))
        check("hot lift: B (1/3) ÷ (2 of 11) = 1.8333", near(number(hotLift["B"]), (1.0 / 3) / (2.0 / 11)), "\(hotLift)")
        let fog = cells(QueryFieldRef("weatherLift", parameters: ["weather": .text("Fog")]))
        check("a weather that never occurs has no lift, not a divide by zero", fog.values.allSatisfy { $0 == .missing })
        check("the default weather is rain", number(cells(QueryFieldRef("weatherShare"))["A"]) == number(rain["A"]))

        let off = cells(QueryFieldRef("weatherCondition"), weather: .empty)
        check("with weather off or not downloaded every weather field has no value", off.values.allSatisfy { $0 == .missing })

        let rainy = cells(QueryFieldRef("plays"), conditions: [[QueryCondition(QueryFieldRef("weatherShare", parameters: ["weather": .text("Rain")]), .greaterThanOrEqual, [.number(0.5)])]])
        check("a condition on the share of rainy plays keeps A and E", Set(rainy.keys) == ["A", "E"], "\(rainy.keys.sorted())")
        let wintry = cells(QueryFieldRef("plays"), conditions: [[QueryCondition("weatherCondition", .textIs, [.text("Clear")])]])
        check("a condition on the weather keeps B and C", Set(wintry.keys) == ["B", "C"], "\(wintry.keys.sorted())")
        // The play filter: only the plays made in certain weather are counted.
        func counted(_ filter: QueryPlayFilter?, weather: WeatherSnapshot = snapshot) -> [String: Int] {
            var spec = QuerySpec(target: .artist)
            spec.playFilter = filter
            spec.columns = [QueryFieldRef("plays")]
            guard let validated = try? spec.validate(against: .standard) else { return ["invalid": 1] }
            var snapshots = QuerySnapshots()
            snapshots.weather = weather
            let run = QueryRun(target: .artist, asOf: date(2025, 2, 1), scrobbles: spec.countedPlays(plays, weather: weather), allTimeScrobbles: plays, snapshots: snapshots)
            let result = QueryEngine.evaluate(validated, run: run)
            let key = result.columns.first?.cacheKey ?? ""
            var out: [String: Int] = [:]
            for row in result.rows { if case .value(.number(let n))? = row.cells[key] { out[row.entity.name] = Int(n) } }
            return out
        }
        func filter(_ conditions: [String] = [], _ bands: [String] = [], months: [Int]? = nil) -> QueryPlayFilter {
            QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil, months: months, weatherConditions: conditions, temperatureBands: bands)
        }
        check("only the plays made in rain: A's three 7 o'clock plays and E's covered one", counted(filter(["Rain"])) == ["A": 3, "E": 1], "\(counted(filter(["Rain"])))")
        check("only the plays made in snow: B's 20:00 play", counted(filter(["Snow"])) == ["B": 1], "\(counted(filter(["Snow"])))")
        check("rain or snow keeps both kinds", counted(filter(["Rain", "Snow"])) == ["A": 3, "E": 1, "B": 1])
        check("only the plays made when it was cold for the place: C's 2 and 3 o'clock plays", counted(filter([], ["Cold"])) == ["C": 2], "\(counted(filter([], ["Cold"])))")
        check("only the plays made when it was hot: B's 20:00 and C's 22:00", counted(filter([], ["Hot"])) == ["B": 1, "C": 1])
        check("snow AND cold means both at once: B's snowy hour was hot, so nothing", counted(filter(["Snow"], ["Cold"])).isEmpty)
        check("snow AND hot keeps B's snowy hot hour", counted(filter(["Snow"], ["Hot"])) == ["B": 1])
        check("clear AND mild: A's noon play and B's noon and 1 PM plays", counted(filter(["Clear"], ["Mild"])) == ["A": 1, "B": 2], "\(counted(filter(["Clear"], ["Mild"])))")
        check("a weather filter combines with months: winter rain is the same plays, summer rain none", counted(filter(["Rain"], months: Season.winter.months(in: .north))) == ["A": 3, "E": 1] && counted(filter(["Rain"], months: Season.summer.months(in: .north))).isEmpty)
        check("a play before the downloaded weather never matches a weather filter (D, E's 2024 play)", counted(filter(["Rain", "Snow", "Clear", "Cloudy", "Fog", "Thunderstorm"])).keys.sorted() == ["A", "B", "C", "E"])
        check("with no weather at all a weather filter counts nothing, instead of everything", counted(filter(["Rain"]), weather: .empty).isEmpty)
        check("with no weather but no weather choice every play still counts (A 4, B 3, C 3, D 1, E 2)", counted(filter(), weather: .empty) == ["A": 4, "B": 3, "C": 3, "D": 1, "E": 2], "\(counted(filter(), weather: .empty))")
        check("a filter that only ticks weather is not empty; empty lists are", !filter(["Rain"]).isEmpty && filter().isEmpty && filter([], ["Cold"]).usesWeather && !filter().usesWeather)
        check("an unknown kind of weather or band is refused", (try? filter(["Monsoon"]).validate()) == nil && (try? filter([], ["Lukewarm"]).validate()) == nil && (try? filter(["Rain"], ["Cold"]).validate()) != nil)
        check("the label reads as a sentence, in a fixed order", filter(["Snow", "Rain"]).label(hemisphere: .north) == "in rain or snow" && filter([], ["Cold"]).label(hemisphere: .north) == "when cold" && filter(["Rain"], ["Cold", "Hot"], months: Season.winter.months(in: .north)).label(hemisphere: .north) == "Winter (Dec–Feb), in rain, when cold or hot", filter(["Rain"], ["Cold", "Hot"], months: Season.winter.months(in: .north)).label(hemisphere: .north))
        var weatherSpec = QuerySpec(target: .track)
        weatherSpec.playFilter = filter(["Rain", "Snow"], ["Cold"])
        let weatherAgain = try? QuerySpec.decode(weatherSpec.encoded())
        check("a weather filter survives saving at the current schema version", weatherAgain?.playFilter?.weatherConditions == ["Rain", "Snow"] && weatherAgain?.playFilter?.temperatureBands == ["Cold"] && weatherAgain?.schemaVersion == QuerySpec.currentSchemaVersion)
        let v6 = Data(#"{"schemaVersion": 6, "target": "artist", "groups": [], "sorts": [], "columns": [], "playFilter": {"months": [12, 1, 2]}}"#.utf8)
        let decodedV6 = try? QuerySpec.decode(v6)
        check("a set saved before weather filters still loads, with any weather", decodedV6?.playFilter?.months == [12, 1, 2] && decodedV6?.playFilter?.usesWeather == false)

        let reg = QueryFieldRegistry.standard
        check("the weather fields are in the registry for artists, albums and tracks", ["weatherCondition", "weatherTemperatureBand", "weatherAverageTemperature", "weatherShare", "weatherLift"].allSatisfy { id in
            (try? reg.field(id)).map { $0.targets == [.artist, .album, .track] } ?? false
        })
        check("the weather and band fields offer exactly their choices", (try? reg.field("weatherCondition"))?.choices == ["Clear", "Cloudy", "Fog", "Rain", "Snow", "Thunderstorm"] && (try? reg.field("weatherTemperatureBand"))?.choices == ["Cold", "Mild", "Hot"])
    }
}
#endif
