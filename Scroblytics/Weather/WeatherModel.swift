import Foundation

// MARK: - Where

/// The place whose weather is matched with the listening: a name for people and a coordinate for the weather service. The coordinate is
/// rounded to one decimal place (about 11 km) the moment a place is made, so nothing finer than that is ever stored or sent.
struct WeatherPlace: Codable, Equatable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double

    init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = Self.rounded(latitude)
        self.longitude = Self.rounded(longitude)
    }

    static func rounded(_ value: Double) -> Double { ((value * 10).rounded() / 10) + 0 }

    static func isValid(latitude: Double, longitude: Double) -> Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// The folder name the downloaded weather for this place lives under.
    var key: String { String(format: "%.1f_%.1f", latitude, longitude) }

    var coordinateLabel: String {
        String(format: "%.1f° %@, %.1f° %@", abs(latitude), latitude >= 0 ? "N" : "S", abs(longitude), longitude >= 0 ? "E" : "W")
    }
}

/// Degrees Celsius or Fahrenheit. Weather is stored and compared in °C; the unit only decides how temperatures are shown and typed.
enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case automatic, celsius, fahrenheit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic (follows your Mac’s region)"
        case .celsius: "Celsius (°C)"
        case .fahrenheit: "Fahrenheit (°F)"
        }
    }

    /// The unit actually used: Automatic is Fahrenheit where the Mac’s region uses US measurements and Celsius elsewhere.
    func resolved(system: Locale.MeasurementSystem = Locale.current.measurementSystem) -> TemperatureUnit {
        switch self {
        case .automatic: system == .us ? .fahrenheit : .celsius
        default: self
        }
    }

    var symbol: String { self == .fahrenheit ? "°F" : "°C" }

    /// A temperature in °C as this unit would show it (a resolved unit; Automatic reads as Celsius here).
    func fromCelsius(_ celsius: Double) -> Double { self == .fahrenheit ? celsius * 9 / 5 + 32 : celsius }

    /// "12 °C" or "54 °F", for a temperature in °C.
    func text(celsius: Double, places: Int = 0) -> String { text(shown: fromCelsius(celsius), places: places) }

    /// "12.3 °C", for a number that is already in this unit.
    func text(shown: Double, places: Int = 0) -> String {
        shown.formatted(.number.precision(.fractionLength(places))) + " " + symbol
    }
}

/// A stay away from home. For the days it covers, the weather at its place stands in for the home weather: nothing about any scrobble is
/// changed, a play simply looks up where you were when it was made. `until` is the moment the trip ends (the start of the day after the
/// last day); nil means still there.
struct WeatherTrip: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var place: WeatherPlace
    var from: Date
    var until: Date?

    func covers(_ date: Date) -> Bool { date >= from && (until.map { date < $0 } ?? true) }

    /// The trip a play at `date` falls in: where two overlap, the one that began later (the more recent decision). nil means at home.
    static func effective(at date: Date, in trips: [WeatherTrip]) -> WeatherTrip? {
        var best: (trip: WeatherTrip, index: Int)?
        for (index, trip) in trips.enumerated() where trip.covers(date) {
            if let current = best, (trip.from, index) < (current.trip.from, current.index) { continue }
            best = (trip, index)
        }
        return best?.trip
    }

    /// Two trips cover some of the same time.
    func overlaps(_ other: WeatherTrip) -> Bool {
        from < (other.until ?? .distantFuture) && other.from < (until ?? .distantFuture)
    }

    /// "Oslo" from "Oslo, Norway".
    var shortName: String { place.shortName }
}

extension WeatherPlace {
    var shortName: String { name.split(separator: ",", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name }
}

/// The home place and every trip: what a backup carries and a restore puts back.
struct WeatherLocationBook: Codable, Equatable, Sendable {
    var home: WeatherPlace?
    var trips: [WeatherTrip]
}

/// Trips are kept in one small file beside the app's other data (not in the downloaded-weather folder, which "Remove Downloaded Weather"
/// empties): they are the person's own entries, and they go into backups.
enum WeatherTripStore {
    static func defaultFile() -> URL { ActivityLog.defaultDirectory().appending(path: "WeatherTrips.json") }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func load(file: URL = defaultFile()) -> [WeatherTrip] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WeatherTrip].self, from: data)) ?? []
    }

    static func save(_ trips: [WeatherTrip], file: URL = defaultFile()) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if trips.isEmpty { try? FileManager.default.removeItem(at: file); return }
        try? encoder().encode(trips).write(to: file, options: .atomic)
    }

    /// Where a trip's weather is kept: its own folder, so changing the trip's place or dates never leaves odd gaps in a shared one.
    static func cacheDirectory(for trip: WeatherTrip, base: URL = WeatherFiles().directory) -> URL {
        base.appending(path: "trips", directoryHint: .isDirectory).appending(path: trip.id.uuidString, directoryHint: .isDirectory)
    }
}

/// The weather settings, kept in the app's preferences. Off until the person turns it on, because turning it on sends the rounded
/// coordinate to a weather service.
enum WeatherSettings {
    static let enabledKey = "weather.enabled"
    static let placeKey = "weather.place"
    static let coldPercentileKey = "weather.coldPercentile"
    static let hotPercentileKey = "weather.hotPercentile"
    static let lastUpdateKey = "weather.lastUpdateAt"
    static let temperatureUnitKey = "weather.temperatureUnit"

    static let defaultColdPercentile = 20
    static let defaultHotPercentile = 80

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

    static func place(defaults: UserDefaults = .standard) -> WeatherPlace? {
        defaults.data(forKey: placeKey).flatMap { try? JSONDecoder().decode(WeatherPlace.self, from: $0) }
    }

    static func setPlace(_ place: WeatherPlace?, defaults: UserDefaults = .standard) {
        if let place, let data = try? JSONEncoder().encode(place) { defaults.set(data, forKey: placeKey) } else { defaults.removeObject(forKey: placeKey) }
    }

    /// What was chosen in Settings (Automatic until chosen; an unknown saved value is Automatic).
    static func chosenTemperatureUnit(defaults: UserDefaults = .standard) -> TemperatureUnit {
        defaults.string(forKey: temperatureUnitKey).flatMap(TemperatureUnit.init(rawValue:)) ?? .automatic
    }

    /// The unit to show temperatures in right now: Celsius or Fahrenheit, never Automatic.
    static func temperatureUnit(defaults: UserDefaults = .standard, system: Locale.MeasurementSystem = Locale.current.measurementSystem) -> TemperatureUnit {
        chosenTemperatureUnit(defaults: defaults).resolved(system: system)
    }

    /// The cold and hot cut-offs as percentiles of the place's own hourly temperatures. Out-of-range or crossed values fall back to the
    /// defaults, so a bad saved value can never make the bands meaningless.
    static func percentiles(defaults: UserDefaults = .standard) -> (cold: Int, hot: Int) {
        let cold = defaults.object(forKey: coldPercentileKey) as? Int ?? defaultColdPercentile
        let hot = defaults.object(forKey: hotPercentileKey) as? Int ?? defaultHotPercentile
        guard (1...49).contains(cold), (51...99).contains(hot) else { return (defaultColdPercentile, defaultHotPercentile) }
        return (cold, hot)
    }
}

// MARK: - What the weather was

/// The kinds of weather a play can be put in, from the weather service's WMO code for that hour.
enum WeatherCondition: String, CaseIterable, Sendable {
    case clear = "Clear", cloudy = "Cloudy", fog = "Fog", rain = "Rain", snow = "Snow", thunderstorm = "Thunderstorm"

    /// The SF Symbol that stands for this weather in lists.
    var symbolName: String {
        switch self {
        case .clear: "sun.max"
        case .cloudy: "cloud"
        case .fog: "cloud.fog"
        case .rain: "cloud.rain"
        case .snow: "cloud.snow"
        case .thunderstorm: "cloud.bolt.rain"
        }
    }

    /// nil for a code that isn't one of these (or no code).
    init?(code: Int?) {
        guard let code else { return nil }
        switch code {
        case 0, 1: self = .clear
        case 2, 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82: self = .rain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95, 96, 99: self = .thunderstorm
        default: return nil
        }
    }
}

/// How warm the hour was for the place: against the place's own hourly temperatures, so 15° can be hot in one climate and cold in another.
enum TemperatureBand: String, CaseIterable, Sendable {
    case cold = "Cold", mild = "Mild", hot = "Hot"
}

struct WeatherSample: Equatable, Sendable {
    var temperature: Double?
    var precipitation: Double?
    var rain: Double?
    var snowfall: Double?
    var code: Int?

    var condition: WeatherCondition? { WeatherCondition(code: code) }

    /// "Rain · 8 °C", or just the part that is known; nil when neither is.
    func summary(unit: TemperatureUnit) -> String? {
        let parts = [condition?.rawValue, temperature.map { unit.text(celsius: $0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - The hours

/// A run of consecutive hours of weather (UTC hour numbers since 1970), packed small: temperatures in tenths of a degree and amounts in
/// tenths of a millimetre or centimetre, 2 bytes each. A year is about 90 KB. `Int16.min` marks an hour the service had no value for.
struct WeatherSeries: Sendable, Equatable {
    static let none = Int16.min

    var startHour: Int
    private(set) var temperature: [Int16]
    private(set) var precipitation: [Int16]
    private(set) var rain: [Int16]
    private(set) var snowfall: [Int16]
    private(set) var code: [Int16]
    /// Every hour up to and including this one has been asked for (hours the service had no value for stay empty and are not asked
    /// again). `Int.min` when nothing has been.
    var coveredThroughHour = Int.min

    var count: Int { temperature.count }
    var endHour: Int { startHour + count - 1 }

    init(startHour: Int, count: Int) {
        self.startHour = startHour
        let empty = [Int16](repeating: Self.none, count: max(0, count))
        temperature = empty; precipitation = empty; rain = empty; snowfall = empty; code = empty
    }

    static func hour(of date: Date) -> Int { Int((date.timeIntervalSince1970 / 3600).rounded(.down)) }
    static func date(ofHour hour: Int) -> Date { Date(timeIntervalSince1970: Double(hour) * 3600) }

    private static func pack(_ value: Double?) -> Int16 {
        guard let value, value.isFinite else { return none }
        let tenths = (value * 10).rounded()
        return Int16(max(-3000, min(3000, tenths)))
    }

    private static func unpack(_ value: Int16) -> Double? { value == none ? nil : Double(value) / 10 }

    mutating func set(hour: Int, _ sample: WeatherSample) {
        let index = hour - startHour
        guard index >= 0, index < count else { return }
        temperature[index] = Self.pack(sample.temperature)
        precipitation[index] = Self.pack(sample.precipitation)
        rain[index] = Self.pack(sample.rain)
        snowfall[index] = Self.pack(sample.snowfall)
        code[index] = sample.code.map { Int16(clamping: $0) } ?? Self.none
    }

    func sample(hour: Int) -> WeatherSample? {
        let index = hour - startHour
        guard index >= 0, index < count else { return nil }
        let sample = WeatherSample(
            temperature: Self.unpack(temperature[index]), precipitation: Self.unpack(precipitation[index]),
            rain: Self.unpack(rain[index]), snowfall: Self.unpack(snowfall[index]), code: code[index] == Self.none ? nil : Int(code[index])
        )
        return sample.temperature == nil && sample.code == nil && sample.precipitation == nil ? nil : sample
    }

    func sample(at date: Date) -> WeatherSample? { sample(hour: Self.hour(of: date)) }

    /// Every hour's temperature there is one for.
    var temperatures: [Double] { temperature.compactMap(Self.unpack) }

    /// The hour with real values closest to the end, for "weather up to …" status text.
    var lastHourWithData: Int? {
        guard let index = temperature.lastIndex(where: { $0 != Self.none }) else { return nil }
        return startHour + index
    }

    /// Several years' series laid end to end as one, so a lookup is a single array read.
    static func merged(_ parts: [WeatherSeries]) -> WeatherSeries? {
        guard let first = parts.map(\.startHour).min(), let last = parts.map(\.endHour).max() else { return nil }
        var out = WeatherSeries(startHour: first, count: last - first + 1)
        for part in parts where part.count > 0 {
            for hour in part.startHour...part.endHour {
                if let sample = part.sample(hour: hour) { out.set(hour: hour, sample) }
            }
        }
        return out
    }

    // MARK: Saving

    private static let magic: [UInt8] = Array("SWX1".utf8)

    func encoded() -> Data {
        var data = Data(Self.magic)
        func put<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        put(Int64(startHour)); put(UInt32(count)); put(Int64(coveredThroughHour == Int.min ? Int64.min : Int64(coveredThroughHour)))
        for array in [temperature, precipitation, rain, snowfall, code] { for value in array { put(value) } }
        return data
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 24, Array(bytes[0..<4]) == Self.magic else { return nil }
        func read<T: FixedWidthInteger>(_ offset: Int, as: T.Type) -> T {
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes[offset..<offset + MemoryLayout<T>.size]) }
            return T(littleEndian: value)
        }
        let start = Int(read(4, as: Int64.self)), count = Int(read(12, as: UInt32.self)), covered = read(16, as: Int64.self)
        guard count >= 0, count <= 24 * 366 * 2, bytes.count == 24 + count * 5 * 2 else { return nil }
        self.init(startHour: start, count: count)
        coveredThroughHour = covered == Int64.min ? Int.min : Int(covered)
        var offset = 24
        func array() -> [Int16] {
            var out = [Int16](repeating: 0, count: count)
            for i in 0..<count { out[i] = read(offset + i * 2, as: Int16.self) }
            offset += count * 2
            return out
        }
        temperature = array(); precipitation = array(); rain = array(); snowfall = array(); code = array()
    }
}

// MARK: - What a query reads

/// The weather for every hour of the listening history, plus where "cold" and "hot" begin for this place. Empty when weather is off, no
/// place is chosen, or nothing has been downloaded yet; the weather fields then have no value.
struct WeatherSnapshot: Sendable {
    /// The weather at one trip, with the trip it belongs to.
    struct TripWeather: Sendable {
        let trip: WeatherTrip
        let series: WeatherSeries
    }

    /// The home place's weather.
    var series: WeatherSeries?
    /// The weather at each trip; a play made during one looks there instead of at home.
    var trips: [TripWeather] = []
    /// °C at or below which an hour is Cold, and at or above which it is Hot: where the coldest and the warmest share of the place's own
    /// hourly temperatures (20% each by default) begin.
    var coldAtOrBelow: Double?
    var hotAtOrAbove: Double?
    var placeName: String?
    /// The unit temperature fields are worked out in (the unit chosen in Settings when the snapshot was read).
    var unit = TemperatureUnit.celsius

    static let empty = WeatherSnapshot()

    var isEmpty: Bool { series == nil && trips.isEmpty }

    init() {}

    init(series: WeatherSeries, placeName: String?, percentiles: (cold: Int, hot: Int), unit: TemperatureUnit = .celsius) {
        self.series = series
        self.placeName = placeName
        self.unit = unit
        let temperatures = series.temperatures.sorted()
        coldAtOrBelow = Self.coldCutoff(percent: percentiles.cold, of: temperatures)
        hotAtOrAbove = Self.hotCutoff(percent: 100 - percentiles.hot, of: temperatures)
    }

    /// The temperature of the last hour in the coldest `percent`% of `sorted` (so that many hours, give or take ties, are at or below it).
    static func coldCutoff(percent: Int, of sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let count = max(1, Int((Double(percent) / 100 * Double(sorted.count)).rounded(.up)))
        return sorted[min(sorted.count, count) - 1]
    }

    /// The temperature of the first hour in the warmest `percent`% of `sorted`.
    static func hotCutoff(percent: Int, of sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let count = max(1, Int((Double(percent) / 100 * Double(sorted.count)).rounded(.up)))
        return sorted[sorted.count - min(sorted.count, count)]
    }

    /// The trip a play at `date` was made on, if any.
    private func tripWeather(at date: Date) -> TripWeather? {
        guard !trips.isEmpty, let trip = WeatherTrip.effective(at: date, in: trips.map(\.trip)) else { return nil }
        return trips.first { $0.trip.id == trip.id }
    }

    /// The weather where the person was at `date`: the trip's if they were away, else home's. A trip with no weather for that hour has
    /// none (home's weather would be the wrong place's).
    func sample(at date: Date) -> WeatherSample? {
        if let trip = tripWeather(at: date) { return trip.series.sample(at: date) }
        return series?.sample(at: date)
    }

    func sample(hour: Int) -> WeatherSample? { sample(at: WeatherSeries.date(ofHour: hour)) }

    /// Where the weather for a play at `date` was taken: the trip's place or the home place, short ("Oslo", not "Oslo, Norway"). nil when
    /// there is no weather for that time, so a list never names a place it has no weather for.
    func locationName(at date: Date) -> String? {
        guard sample(at: date) != nil else { return nil }
        if let trip = tripWeather(at: date) { return trip.trip.shortName }
        guard let placeName, !placeName.isEmpty else { return nil }
        return placeName.split(separator: ",", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? placeName
    }

    /// The first and last hour any of the weather covers.
    var hourBounds: ClosedRange<Int>? {
        let all = (series.map { [$0] } ?? []) + trips.map(\.series)
        guard let first = all.map(\.startHour).min(), let last = all.map(\.endHour).max(), first <= last else { return nil }
        return first...last
    }

    /// The temperatures hot and cold are judged against: the home place's, wherever the person was (a hot trip is hot for them).
    var climateTemperatures: [Double] { series?.temperatures ?? trips.flatMap { $0.series.temperatures } }

    func band(for sample: WeatherSample) -> TemperatureBand? {
        guard let temperature = sample.temperature, let coldAtOrBelow, let hotAtOrAbove else { return nil }
        if temperature <= coldAtOrBelow { return .cold }
        if temperature >= hotAtOrAbove { return .hot }
        return .mild
    }
}
