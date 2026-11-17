import Foundation

/// Where on the globe a place is, and how well it was found: the city itself, the middle of its state or region, or the middle of its
/// country. The map draws the last two as approximate and says so.
struct PlaceCoordinate: Sendable, Equatable {
    enum Level: Int, Sendable { case city, region, country }

    let latitude: Double
    let longitude: Double
    let level: Level
    /// The place that was found (a city or region name, or the country).
    let matchedName: String
}

/// Coordinates for the places artists come from, from a bundled list of about 70,000 cities (GeoNames, `cities5000`, CC BY 4.0) with no
/// network. A city is matched by country, name (accents, case, "St." and "Saint" ignored) and, when several share a name, its state or
/// region, else the biggest. A city that is not in the list falls back to the middle of its region, then of its country.
struct PlaceCoordinates: Sendable {
    private struct Row: Sendable {
        let name: String
        let regionKey: String
        let latitude: Double
        let longitude: Double
        let population: Int
    }

    private struct Centre: Sendable {
        var weight = 0.0, latitude = 0.0, longitude = 0.0, name = ""
    }

    private var rows: [Row] = []
    /// "CC|name key" to the rows with that name, from the name and its plain-letter spelling.
    private var cities: [String: [Int]] = [:]
    /// "CC|region key" to the population-weighted middle of the region's cities.
    private var regions: [String: Centre] = [:]
    /// "CC" to the population-weighted middle of the country's cities, for a country the outline doesn't have.
    private var countries: [String: Centre] = [:]
    private let geometry: WorldGeometry

    /// Reads the list (one place per line: name, plain-letter name, country code, region, latitude, longitude, population, tab-separated).
    init(tsv: String, geometry: WorldGeometry = .bundled) {
        self.geometry = geometry
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 7, let lat = Double(f[4]), let lon = Double(f[5]) else { continue }
            let code = String(f[2])
            let regionName = String(f[3])
            let row = Row(name: String(f[0]), regionKey: Self.key(regionName), latitude: lat, longitude: lon, population: Int(f[6]) ?? 0)
            let index = rows.count
            rows.append(row)
            for name in Set([String(f[0]), f[1].isEmpty ? String(f[0]) : String(f[1])]) {
                cities["\(code)|\(Self.key(name))", default: []].append(index)
            }
            let weight = Double(max(row.population, 1))
            for slot in [("R", "\(code)|\(row.regionKey)", regionName), ("C", code, code)] {
                guard slot.0 == "C" || !regionName.isEmpty else { continue }
                var centre = slot.0 == "R" ? (regions[slot.1] ?? Centre(name: slot.2)) : (countries[slot.1] ?? Centre(name: slot.2))
                centre.weight += weight
                centre.latitude += lat * weight
                centre.longitude += lon * weight
                if slot.0 == "R" { regions[slot.1] = centre } else { countries[slot.1] = centre }
            }
        }
    }

    /// The list that ships in the app.
    static let bundled: PlaceCoordinates = {
        guard let url = Bundle.main.url(forResource: "cities5000", withExtension: "tsv"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return PlaceCoordinates(tsv: "")
        }
        return PlaceCoordinates(tsv: text)
    }()

    var cityCount: Int { rows.count }

    /// A name folded for matching: no accents or case, "St." as "Saint", "Mt." as "Mount".
    static func key(_ text: String) -> String {
        ArtistMapNames.key(text).split(separator: " ").map { word -> String in
            switch word {
            case "st": "saint"
            case "ste": "sainte"
            case "mt": "mount"
            case "ft": "fort"
            default: String(word)
            }
        }.joined(separator: " ")
    }

    /// The best coordinates for a place, or nil when not even its country is known.
    func coordinate(for place: OriginPlace) -> PlaceCoordinate? {
        guard let code = place.countryCode.flatMap({ CountryNames.code(for: $0) }) ?? place.country.flatMap({ CountryNames.code(for: $0) }) else { return nil }
        let regionKey = place.region.map(Self.key) ?? ""
        if let city = place.city?.trimmingCharacters(in: .whitespaces), !city.isEmpty {
            let base = Self.key(city)
            // MusicBrainz says "New York"; the list says "New York City". "Abingdon-on-Thames" is listed as plain "Abingdon".
            var candidates = [base, base + " city"]
            for connector in [" on ", " upon "] {
                if let range = base.range(of: connector), range.lowerBound > base.startIndex { candidates.append(String(base[..<range.lowerBound])) }
            }
            for candidate in candidates {
                let matches = (cities["\(code)|\(candidate)"] ?? []).map { rows[$0] }
                guard !matches.isEmpty else { continue }
                let inRegion = regionKey.isEmpty ? [] : matches.filter { $0.regionKey == regionKey }
                if let best = (inRegion.isEmpty ? matches : inRegion).max(by: { $0.population < $1.population }) {
                    return PlaceCoordinate(latitude: best.latitude, longitude: best.longitude, level: .city, matchedName: best.name)
                }
            }
        }
        if !regionKey.isEmpty, let centre = regions["\(code)|\(regionKey)"], centre.weight > 0 {
            return PlaceCoordinate(latitude: centre.latitude / centre.weight, longitude: centre.longitude / centre.weight, level: .region, matchedName: centre.name)
        }
        if let middle = geometry.centre(of: code) {
            return PlaceCoordinate(latitude: middle.latitude, longitude: middle.longitude, level: .country, matchedName: CountryNames.name(forCode: code) ?? code)
        }
        if let centre = countries[code], centre.weight > 0 {
            return PlaceCoordinate(latitude: centre.latitude / centre.weight, longitude: centre.longitude / centre.weight, level: .country, matchedName: CountryNames.name(forCode: code) ?? code)
        }
        return nil
    }
}
