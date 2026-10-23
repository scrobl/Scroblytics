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
            if let start = query["start_date"], let end = query["end_date"] {
                from = WeatherClient.hourNumber(start + "T00:00")!
                to = WeatherClient.hourNumber(end + "T23:00")!
            } else {
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
                temps.append(sample.temperature.map { String($0) } ?? "null")
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
            check("three days later only the new days are asked for, in one request", top.requests == 1 && log.urls.count == 1 && log.urls[0].host == "api.open-meteo.com" && query(log.urls[0])["past_days"] == "4", "\(log.urls.map(\.absoluteString))")
            let continued = files.timeline(place)
            check("the weather continues without a gap", [hour(2025, 3, 10, 13), hour(2025, 3, 12, 5), hour(2025, 3, 13, 12)].allSatisfy { continued?.sample(hour: $0) == weather(atHour: $0) })

            // Three weeks later: the days the archive now has, then the recent ones.
            log.urls.removeAll()
            let now3 = date(2025, 4, 2, 12, 30)
            currentNow = WeatherSeries.hour(of: now3)
            let later = try await WeatherUpdater.update(place: place, firstPlay: firstPlay, now: now3, client: service, files: files, pause: .zero)
            let laterQuery = log.urls.map(query)
            check("three weeks later the archive request picks up where the last one ended, then the recent days", later.requests == 2 && laterQuery[0]["start_date"] == "2025-03-13" && laterQuery[0]["end_date"] == "2025-03-26" && log.urls[1].host == "api.open-meteo.com", "\(laterQuery)")

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
        check("a weather filter survives saving at schema version 7", weatherAgain?.playFilter?.weatherConditions == ["Rain", "Snow"] && weatherAgain?.playFilter?.temperatureBands == ["Cold"] && weatherAgain?.schemaVersion == 7)
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
