import Foundation

/// What the origin map shows for a period: the places artists come from (as dots), the countries (as shading), and an exact account of
/// what is not on the map. `mapped` plus everything in `notOnMap` plus `pendingLength` is always `total`.
struct OriginMapResult: Sendable, Equatable {
    struct Top: Sendable, Equatable {
        let name: String
        let weight: Int
    }

    /// One dot: a city, or (when the city was not found) the middle of a region or a country, which is drawn as approximate.
    struct Place: Identifiable, Sendable, Equatable {
        let id: String
        /// "City A, State A, United States"; for an approximate dot, the region or country it stands at.
        let label: String
        let city: String?
        let region: String?
        let country: String
        let countryCode: String
        let latitude: Double
        let longitude: Double
        let level: PlaceCoordinate.Level
        var weight: Int
        var artists: Int
        var top: [Top]

        var isApproximate: Bool { level != .city }
    }

    struct CountryTotal: Identifiable, Sendable, Equatable {
        let code: String
        let name: String
        var weight: Int
        var artists: Int
        var id: String { code }
    }

    /// Why plays are not on the map.
    enum NotOnMap: Int, CaseIterable, Sendable {
        case notLookedUp, lookupsOff, unknownToMusicBrainz, noCountry

        var label: String {
            switch self {
            case .notLookedUp: "artists not looked up yet"
            case .lookupsOff: "artists with no origin (looking up is off)"
            case .unknownToMusicBrainz: "artists MusicBrainz doesn’t know"
            case .noCountry: "artists whose place has no known country"
            }
        }
    }

    let metric: TrendsMetric
    /// Biggest first.
    let places: [Place]
    let countries: [CountryTotal]
    /// Everything counted in the period (plays, or seconds of listening).
    let total: Int
    let mapped: Int
    let notOnMap: [NotOnMap: Int]
    /// Plays whose track length isn't known yet (only when counting time): not in `total`, never guessed at.
    let pendingLength: Int

    var maxPlaceWeight: Int { places.first?.weight ?? 0 }
    var unmapped: Int { notOnMap.values.reduce(0, +) }
    var artistsMapped: Int { countries.reduce(0) { $0 + $1.artists } }
}

enum OriginMapEngine {
    /// `scrobbles` carry canonical artist names, as every Trends chart's do.
    static func compute(
        scrobbles: [ScrobbleSnapshot], origins: QueryOriginSnapshot, durations: DurationEngine.Snapshot, range: DateRange,
        metric: TrendsMetric, places coordinates: PlaceCoordinates
    ) -> OriginMapResult {
        var weights: [String: Int] = [:]
        var pendingLength = 0
        for play in scrobbles where play.playedAt >= range.from && play.playedAt <= range.to {
            guard let weight = TrendsWeight.of(play, metric: metric, durations: durations) else { pendingLength += 1; continue }
            weights[play.artistName, default: 0] += weight
        }

        struct Dot {
            var place: OriginMapResult.Place
            var byArtist: [String: Int]
        }
        var dots: [String: Dot] = [:]
        var countries: [String: OriginMapResult.CountryTotal] = [:]
        var notOnMap: [OriginMapResult.NotOnMap: Int] = [:]
        var total = 0, mapped = 0

        for (artist, weight) in weights where weight > 0 {
            total += weight
            let display = origins.display(artist: artist)
            switch display.state {
            case .pending:
                notOnMap[origins.lookupsOn ? .notLookedUp : .lookupsOff, default: 0] += weight
                continue
            case .unknown:
                notOnMap[.unknownToMusicBrainz, default: 0] += weight
                continue
            case .known:
                break
            }
            guard let found = coordinates.coordinate(for: display.place),
                  let code = display.place.countryCode.flatMap({ CountryNames.code(for: $0) }) ?? display.place.country.flatMap({ CountryNames.code(for: $0) }) else {
                notOnMap[.noCountry, default: 0] += weight
                continue
            }
            mapped += weight
            let countryName = CountryNames.name(forCode: code) ?? display.place.country ?? code
            var country = countries[code] ?? OriginMapResult.CountryTotal(code: code, name: countryName, weight: 0, artists: 0)
            country.weight += weight
            country.artists += 1
            countries[code] = country

            let key = "\(found.level.rawValue)|\(Int((found.latitude * 10_000).rounded()))|\(Int((found.longitude * 10_000).rounded()))"
            if dots[key] == nil {
                let label: String
                let regionName: String?
                switch found.level {
                case .city:
                    label = display.place.text
                    regionName = display.place.region
                case .region:
                    regionName = display.place.region
                    label = [display.place.region, countryName].compactMap { $0 }.joined(separator: ", ")
                case .country:
                    regionName = nil
                    label = countryName
                }
                dots[key] = Dot(
                    place: OriginMapResult.Place(
                        id: key, label: label, city: found.level == .city ? display.place.city : nil, region: regionName, country: countryName, countryCode: code,
                        latitude: found.latitude, longitude: found.longitude, level: found.level, weight: 0, artists: 0, top: []
                    ),
                    byArtist: [:]
                )
            }
            dots[key]?.place.weight += weight
            dots[key]?.place.artists += 1
            dots[key]?.byArtist[artist] = weight
        }

        let placed = dots.values.map { dot -> OriginMapResult.Place in
            var place = dot.place
            place.top = dot.byArtist.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3).map { OriginMapResult.Top(name: $0.key, weight: $0.value) }
            return place
        }.sorted { ($0.weight, $1.label) > ($1.weight, $0.label) }
        let ranked = countries.values.sorted { ($0.weight, $1.name) > ($1.weight, $0.name) }
        return OriginMapResult(metric: metric, places: placed, countries: ranked, total: total, mapped: mapped, notOnMap: notOnMap, pendingLength: pendingLength)
    }
}

/// What a click on the map opens in Query: the artists from that place, played in the period, most played first.
enum OriginMapDrill {
    static func place(_ place: OriginMapResult.Place, range: DateRange) -> QuerySpec {
        var spec = TrendsDrill.spec(from: range.from, to: range.to, target: .artist)
        switch place.level {
        case .city:
            if let city = place.city { spec.groups[0].append(QueryCondition("originCity", .textIs, [.text(city)])) }
            if let region = place.region { spec.groups[0].append(QueryCondition("originRegion", .textIs, [.text(region)])) }
        case .region:
            if let region = place.region { spec.groups[0].append(QueryCondition("originRegion", .textIs, [.text(region)])) }
        case .country:
            break
        }
        spec.groups[0].append(QueryCondition("originCountry", .textIs, [.text(place.country)]))
        spec.columns.append(QueryFieldRef("originPlace"))
        return spec
    }

    static func country(name: String, range: DateRange) -> QuerySpec {
        var spec = TrendsDrill.spec(from: range.from, to: range.to, target: .artist)
        spec.groups[0].append(QueryCondition("originCountry", .textIs, [.text(name)]))
        spec.columns.append(QueryFieldRef("originPlace"))
        return spec
    }

    /// Everyone from a country over the whole history, most played first (what a passport stamp opens).
    static func countryAllTime(name: String) -> QuerySpec {
        var spec = TrendsDrill.spec(from: Date.distantPast, to: Date(), target: .artist)
        spec.period = nil
        spec.groups[0].append(QueryCondition("originCountry", .textIs, [.text(name)]))
        spec.columns.append(QueryFieldRef("originPlace"))
        return spec
    }
}
