import Foundation

/// Where "home" is for the local-scene meter: a place the person chose for it, else the home place from Settings › Weather. Names only, so
/// nothing is looked up; the meter compares them with where artists are from.
enum OriginHome {
    private static let key = "origin.homePlace"

    /// The place chosen for the meter; nil until one is.
    static func chosen(defaults: UserDefaults = .standard) -> OriginPlace? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(OriginPlace.self, from: $0) }
    }

    static func setChosen(_ place: OriginPlace?, defaults: UserDefaults = .standard) {
        if let place, !place.isEmpty, let data = try? JSONEncoder().encode(place) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// The weather home place as an origin place: "Oslo, Oslo, Norway" is the city Oslo, the region Oslo and the country Norway. nil when
    /// no weather home place is set.
    static func fromWeather(defaults: UserDefaults = .standard) -> OriginPlace? {
        guard let weather = WeatherSettings.place(defaults: defaults) else { return nil }
        let city = weather.name.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        let country = weather.country?.trimmingCharacters(in: .whitespaces)
        let place = OriginPlace(
            city: city?.isEmpty == false ? city : nil, region: weather.region?.isEmpty == false ? weather.region : nil,
            country: country, countryCode: country.flatMap { CountryNames.code(for: $0) }
        )
        return place.isEmpty ? nil : place
    }

    /// The home the meter uses: the one chosen for it, else the weather home place.
    static func current(defaults: UserDefaults = .standard) -> OriginPlace? { chosen(defaults: defaults) ?? fromWeather(defaults: defaults) }

    /// The ISO code of a place's country, from its code or its name.
    static func countryCode(of place: OriginPlace) -> String? {
        place.countryCode.flatMap { CountryNames.code(for: $0) } ?? place.country.flatMap { CountryNames.code(for: $0) }
    }
}

/// How close to home an artist's origin is.
enum LocalScene: Int, CaseIterable, Sendable {
    /// From the home city.
    case city
    /// From the home state or region, but not the city.
    case region
    /// From the home country, but not the region.
    case country
    /// From somewhere else.
    case elsewhere
    /// No origin known (not looked up, or MusicBrainz doesn't know the artist).
    case unknown

    var label: String {
        switch self {
        case .city: "Your city"
        case .region: "Rest of your region"
        case .country: "Rest of your country"
        case .elsewhere: "Elsewhere"
        case .unknown: "Origin not known"
        }
    }

    /// How an artist's place sits against home. A place is compared at each level only when both have it: a city counts only in the same
    /// country (and the same region when both name one), a region only in the same country.
    static func of(place: OriginPlace, home: OriginPlace) -> LocalScene {
        guard let homeCountry = OriginHome.countryCode(of: home), let country = OriginHome.countryCode(of: place) else { return .elsewhere }
        guard homeCountry == country else { return .elsewhere }
        func same(_ a: String?, _ b: String?) -> Bool? {
            guard let a, let b, !a.isEmpty, !b.isEmpty else { return nil }
            return PlaceCoordinates.key(a) == PlaceCoordinates.key(b)
        }
        let regionMatch = same(place.region, home.region)
        if same(place.city, home.city) == true, regionMatch != false { return .city }
        if regionMatch == true { return .region }
        return .country
    }
}

/// The share of the period's listening by artists from home, by week, month or year.
struct LocalSceneResult: Sendable, Equatable {
    struct Bucket: Identifiable, Sendable, Equatable {
        let start: Date
        let end: Date
        /// What each kind of artist adds up to in this bucket (plays, or seconds).
        let weights: [LocalScene: Int]
        var id: Date { start }
        var total: Int { weights.values.reduce(0, +) }
        func share(_ scene: LocalScene) -> Double { total == 0 ? 0 : Double(weights[scene] ?? 0) / Double(total) }
    }

    let metric: TrendsMetric
    let bucketing: TrendsRankBump.Bucketing
    let buckets: [Bucket]
    /// The whole period.
    let overall: [LocalScene: Int]
    /// Plays whose track length isn't known yet (only when counting time): left out, never guessed at.
    let pendingLength: Int
    let home: OriginPlace

    var total: Int { overall.values.reduce(0, +) }
    func share(_ scene: LocalScene) -> Double { total == 0 ? 0 : Double(overall[scene] ?? 0) / Double(total) }
    /// Everything from the home country, whichever part of it.
    var homeCountryShare: Double { share(.city) + share(.region) + share(.country) }
}

enum LocalSceneEngine {
    /// `scrobbles` carry canonical artist names and are sorted by time.
    static func compute(
        scrobbles: [ScrobbleSnapshot], origins: QueryOriginSnapshot, durations: DurationEngine.Snapshot, range: DateRange, metric: TrendsMetric,
        home: OriginPlace
    ) -> LocalSceneResult {
        let bucketing = TrendsRankBump.Bucketing.forRange(range)
        var sceneOfArtist: [String: LocalScene] = [:]
        func scene(for artist: String) -> LocalScene {
            if let known = sceneOfArtist[artist] { return known }
            let display = origins.display(artist: artist)
            let result: LocalScene = display.state == .known ? LocalScene.of(place: display.place, home: home) : .unknown
            sceneOfArtist[artist] = result
            return result
        }
        var starts: [Date] = []
        var cursor = bucketing.start(of: range.from)
        while cursor <= range.to {
            starts.append(cursor)
            cursor = bucketing.next(after: cursor)
        }
        var perBucket = [[LocalScene: Int]](repeating: [:], count: starts.count)
        var overall: [LocalScene: Int] = [:]
        var pending = 0
        var bucketIndex = 0
        for play in scrobbles where play.playedAt >= range.from && play.playedAt <= range.to {
            guard let weight = TrendsWeight.of(play, metric: metric, durations: durations) else { pending += 1; continue }
            guard weight > 0 else { continue }
            while bucketIndex + 1 < starts.count, play.playedAt >= starts[bucketIndex + 1] { bucketIndex += 1 }
            let kind = scene(for: play.artistName)
            perBucket[bucketIndex][kind, default: 0] += weight
            overall[kind, default: 0] += weight
        }
        let buckets = starts.enumerated().map { index, start in
            LocalSceneResult.Bucket(start: max(start, range.from), end: min(index + 1 < starts.count ? starts[index + 1] : bucketing.next(after: start), range.to), weights: perBucket[index])
        }
        return LocalSceneResult(metric: metric, bucketing: bucketing, buckets: buckets, overall: overall, pendingLength: pending, home: home)
    }
}
