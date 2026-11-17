import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_ORIGINMAP_CHECK=1`: the foundation of the origin map. The projection, the bundled world outline, the country names and
/// the place coordinates, against hand-made tables and then against the data that ships in the app. All offline; exits 0 on success.
///
/// `SCROBLYTICS_ORIGINMAP_COVERAGE=1` (with `SCROBLYTICS_STORE_PATH` on a copy of a library): how many of that library's artists can be
/// placed on the map, at city, region or country level, weighted by plays, and which ones fall short.
enum OriginMapChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        if env["SCROBLYTICS_ORIGINMAP_COVERAGE"] != nil {
            Task { @MainActor in await coverage(container: container) }
            return
        }
        guard env["SCROBLYTICS_ORIGINMAP_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            projectionChecks(check)
            geometryChecks(check)
            countryNameChecks(check)
            coordinateChecks(check)
            bundledChecks(check)
            HeadlessTask.finish(failures)
        }
    }

    // MARK: Projection

    @MainActor
    private static func projectionChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func near(_ a: CGFloat, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(Double(a) - b) < tolerance }
        let origin = RobinsonProjection.project(longitude: 0, latitude: 0)
        check("the middle of the map is the middle of the frame", near(origin.x, 0) && near(origin.y, 0))
        let east = RobinsonProjection.project(longitude: 180, latitude: 0), west = RobinsonProjection.project(longitude: -180, latitude: 0)
        check("the equator spans the full width", near(east.x, 1) && near(west.x, -1))
        let north = RobinsonProjection.project(longitude: 0, latitude: 90), south = RobinsonProjection.project(longitude: 0, latitude: -90)
        check("the poles are the top and bottom of the frame", near(north.y, 1) && near(south.y, -1))
        check("a pole is a line as wide as the table says (about 53% of the equator)", near(RobinsonProjection.project(longitude: 180, latitude: 90).x, 0.5322))
        var symmetric = true, rising = true, smooth = true
        var previous = RobinsonProjection.project(longitude: 40, latitude: -90)
        for latitude in stride(from: -89.0, through: 90.0, by: 1.0) {
            let point = RobinsonProjection.project(longitude: 40, latitude: latitude)
            if point.y <= previous.y { rising = false }
            if abs(point.y - previous.y) > 0.05 || abs(point.x - previous.x) > 0.01 { smooth = false }
            previous = point
            let mirrored = RobinsonProjection.project(longitude: -40, latitude: -latitude)
            if !near(mirrored.x, -Double(point.x)) || !near(mirrored.y, -Double(point.y)) { symmetric = false }
        }
        check("going north always moves a point up", rising)
        check("a degree of latitude never jumps", smooth)
        check("the map is symmetric about the equator and the prime meridian", symmetric)
        check("the whole map is about twice as wide as it is tall", abs(RobinsonProjection.aspect - 1.9717) < 0.001, "\(RobinsonProjection.aspect)")
        let rect = CGRect(x: 10, y: 20, width: 400, height: 200)
        let corner = WorldGeometry.point(CGPoint(x: -1, y: 1), in: rect)
        let opposite = WorldGeometry.point(CGPoint(x: 1, y: -1), in: rect)
        check("the top left of the projection is the top left of the frame, y pointing down on screen", corner == CGPoint(x: 10, y: 20) && opposite == CGPoint(x: 410, y: 220))
    }

    // MARK: Outline

    @MainActor
    private static func geometryChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let world = WorldGeometry.bundled
        check("the bundled outline has the world's countries", world.countries.count >= 170, "\(world.countries.count)")
        let missing = ["US", "GB", "FR", "NO", "NZ", "RU", "JP", "BR", "AU", "CA", "IE", "DE", "IN", "ZA", "XK"].filter { world.country($0) == nil }
        check("the countries people are from are all there, including those the data leaves without a code (France, Norway)", missing.isEmpty, "missing \(missing)")
        check("Antarctica is left out", world.country("AQ") == nil)
        check("every country has at least one outline of 3 or more points", world.countries.allSatisfy { !$0.rings.isEmpty && $0.rings.allSatisfy { $0.count >= 3 } })
        var inRange = true
        for country in world.countries {
            for point in country.rings.flatMap({ $0 }) where point.x < -180 || point.x > 180 || point.y < -90 || point.y > 90 { inRange = false }
            for point in country.projected.flatMap({ $0 }) where point.x < -1.0001 || point.x > 1.0001 || point.y < -1.0001 || point.y > 1.0001 { inRange = false }
        }
        check("every point is a real longitude and latitude and lands inside the frame", inRange)
        check("a point inland in the middle of North America is the United States", world.countryAt(RobinsonProjection.project(longitude: -98.4, latitude: 39.5)) == "US")
        check("a point in central France is France", world.countryAt(RobinsonProjection.project(longitude: 2.5, latitude: 46.6)) == "FR")
        check("a point in the Australian interior is Australia", world.countryAt(RobinsonProjection.project(longitude: 134, latitude: -25)) == "AU")
        check("a point in the middle of the Atlantic is no country", world.countryAt(RobinsonProjection.project(longitude: -30, latitude: 0)) == nil)
        let centreChecks = ["US", "GB", "BR", "AU", "FR", "JP", "IN", "DE"].allSatisfy { iso in
            guard let centre = world.centre(of: iso), let country = world.country(iso) else { return false }
            return country.bounds.contains(RobinsonProjection.project(longitude: centre.longitude, latitude: centre.latitude))
        }
        check("a country's centre lies within its own outline's frame", centreChecks)
        let american = world.centre(of: "US")
        check("the centre of the United States is on the mainland", american.map { $0.latitude > 35 && $0.latitude < 45 && $0.longitude > -105 && $0.longitude < -85 } == true, "\(String(describing: american))")
        check("a code that isn't in the outline has no centre", world.centre(of: "ZZ") == nil)
        let rect = CGRect(x: 0, y: 0, width: 800, height: 800 / RobinsonProjection.aspect)
        if let us = world.country("US") {
            let bounds = world.path(for: us, in: rect).boundingRect
            check("a country's path fits the frame it is drawn in", rect.insetBy(dx: -1, dy: -1).contains(bounds) && bounds.width > 10)
        } else {
            check("a country's path fits the frame it is drawn in", false)
        }
    }

    // MARK: Country names

    @MainActor
    private static func countryNameChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        check("a name resolves to its code", CountryNames.code(for: "United States") == "US" && CountryNames.code(for: "Germany") == "DE")
        check("the usual other names resolve too",
              ["United States of America", "USA", "u.s.a.", "America"].allSatisfy { CountryNames.code(for: $0) == "US" }
                && ["UK", "Great Britain", "England"].allSatisfy { CountryNames.code(for: $0) == "GB" }
                && CountryNames.code(for: "Czech Republic") == "CZ" && CountryNames.code(for: "Czechia") == "CZ"
                && CountryNames.code(for: "Turkey") == "TR" && CountryNames.code(for: "Türkiye") == "TR" && CountryNames.code(for: "Burma") == "MM")
        check("case, accents and a leading 'The' don't matter", CountryNames.code(for: "the netherlands") == "NL" && CountryNames.code(for: "CÔTE D’IVOIRE") == "CI")
        check("a code resolves to itself, in any case", CountryNames.code(for: "de") == "DE" && CountryNames.code(for: "GB") == "GB")
        check("two letters that are no country, and names that aren't one, resolve to nothing", CountryNames.code(for: "ZZ") == nil && CountryNames.code(for: "Narnia") == nil && CountryNames.code(for: "  ") == nil)
        check("a code gives its English name", CountryNames.name(forCode: "US") == "United States" && CountryNames.name(forCode: "gb") == "United Kingdom" && CountryNames.name(forCode: "NZ") == "New Zealand")
        check("Kosovo, which the system has no name for, still has one", CountryNames.name(forCode: "XK") == "Kosovo")
        check("a bad code gives no name", CountryNames.name(forCode: "ZZZ") == nil && CountryNames.name(forCode: "1A") == nil)
        check("a flag is drawn from the code", CountryNames.flag(forCode: "US") == "🇺🇸" && CountryNames.flag(forCode: "gb") == "🇬🇧" && CountryNames.flag(forCode: "x") == "")
        let unresolved = WorldGeometry.bundled.countries.filter { CountryNames.name(forCode: $0.iso) == nil }.map(\.iso)
        check("every country in the outline has a name", unresolved.isEmpty, "no name for \(unresolved)")
        let roundTrip = WorldGeometry.bundled.countries.filter { country in CountryNames.name(forCode: country.iso).flatMap { CountryNames.code(for: $0) } != country.iso }.map(\.iso)
        check("a country's name resolves back to its code", roundTrip.isEmpty, "\(roundTrip)")
    }

    // MARK: Coordinates

    private static let table = """
    Springfield\t\tUS\tState One\t10.0\t-80.0\t100000
    Springfield\t\tUS\tState Two\t20.0\t-90.0\t300000
    Town A\t\tUS\tState One\t11.0\t-81.0\t6000
    Town B\t\tUS\tState One\t13.0\t-83.0\t6000
    Paris\t\tFR\tRegion F\t48.85\t2.35\t2000000
    Paris\t\tUS\tState Two\t33.6\t-95.5\t25000
    Zürich\tZurich\tCH\tCanton Z\t47.37\t8.54\t400000
    New York City\t\tUS\tNew York\t40.71\t-74.0\t8000000
    Saint Louis\t\tUS\tState Three\t38.6\t-90.2\t300000
    Riverton\t\tGB\tEngland\t51.67\t-1.28\t35000
    Stratford\t\tGB\tEngland\t52.19\t-1.71\t28000
    """

    @MainActor
    private static func coordinateChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let places = PlaceCoordinates(tsv: table)
        func at(_ place: OriginPlace) -> PlaceCoordinate? { places.coordinate(for: place) }
        func near(_ value: Double, _ expected: Double, _ tolerance: Double = 0.001) -> Bool { abs(value - expected) < tolerance }
        let one = at(OriginPlace(city: "Springfield", region: "State One", country: "United States", countryCode: "US"))
        check("a city name shared by two states is told apart by the region", one?.level == .city && near(one?.latitude ?? 0, 10) && near(one?.longitude ?? 0, -80), "\(String(describing: one))")
        let biggest = at(OriginPlace(city: "Springfield", region: nil, country: nil, countryCode: "US"))
        check("with no region the biggest of the same name is taken", biggest?.level == .city && near(biggest?.latitude ?? 0, 20), "\(String(describing: biggest))")
        let paris = at(OriginPlace(city: "Paris", region: nil, country: nil, countryCode: "FR"))
        check("the same city name in another country is told apart by the country", paris?.level == .city && near(paris?.latitude ?? 0, 48.85), "\(String(describing: paris))")
        let parisUS = at(OriginPlace(city: "Paris", region: nil, country: "United States", countryCode: nil))
        check("a country given only by name works too", parisUS?.level == .city && near(parisUS?.latitude ?? 0, 33.6), "\(String(describing: parisUS))")
        check("a city is never taken from another country", at(OriginPlace(city: "Springfield", region: nil, country: nil, countryCode: "FR"))?.level != .city)
        check("accents and their plain spelling match the same place",
              at(OriginPlace(city: "Zurich", region: nil, country: nil, countryCode: "CH"))?.matchedName == "Zürich" && at(OriginPlace(city: "ZÜRICH", region: nil, country: nil, countryCode: "CH"))?.matchedName == "Zürich")
        check("'New York' finds 'New York City'", at(OriginPlace(city: "New York", region: nil, country: nil, countryCode: "US"))?.matchedName == "New York City")
        check("'-on-Thames' style names find the plain town", at(OriginPlace(city: "Riverton-on-Thames", region: "England", country: nil, countryCode: "GB"))?.matchedName == "Riverton" && at(OriginPlace(city: "Stratford-upon-Avon", region: nil, country: nil, countryCode: "GB"))?.matchedName == "Stratford")
        check("'St.' and 'Saint' are the same", at(OriginPlace(city: "St. Louis", region: nil, country: nil, countryCode: "US"))?.matchedName == "Saint Louis")
        let region = at(OriginPlace(city: "Nowhere Town", region: "State One", country: nil, countryCode: "US"))
        // The region's centre is its cities' average, each counted by population: (10·100000 + 11·6000 + 13·6000) / 112000.
        check("a city that isn't listed falls back to the middle of its region, weighted by population", region?.level == .region && near(region?.latitude ?? 0, 1_144_000.0 / 112_000.0, 0.0001) && region?.matchedName == "State One", "\(String(describing: region))")
        let noRegionCity = at(OriginPlace(city: nil, region: "State One", country: nil, countryCode: "US"))
        check("a region with no city gives the region's middle", noRegionCity?.level == .region)
        let country = at(OriginPlace(city: "Nowhere Town", region: "No Such Region", country: nil, countryCode: "US"))
        check("a region that isn't listed falls back to the middle of the country", country?.level == .country && country?.matchedName == "United States", "\(String(describing: country))")
        let bare = at(OriginPlace(city: nil, region: nil, country: "United Kingdom", countryCode: nil))
        check("a country alone is placed at its centre", bare?.level == .country && (bare?.latitude ?? 0) > 50 && (bare?.latitude ?? 0) < 56)
        let islands = PlaceCoordinates(tsv: table, geometry: WorldGeometry(countries: []))
        let noOutline = islands.coordinate(for: OriginPlace(city: nil, region: nil, country: nil, countryCode: "CH"))
        check("a country the outline doesn't have is placed at the average of its cities", noOutline?.level == .country && near(noOutline?.latitude ?? 0, 47.37) && near(noOutline?.longitude ?? 0, 8.54), "\(String(describing: noOutline))")
        check("a place with no country can't be placed", at(OriginPlace(city: "Springfield", region: "State One", country: nil, countryCode: nil)) == nil && at(OriginPlace()) == nil)
        check("a country name nobody knows can't be placed", at(OriginPlace(city: "Springfield", region: nil, country: "Narnia", countryCode: nil)) == nil)
        check("names fold as the list does", PlaceCoordinates.key("St. John’s") == "saint john s" && PlaceCoordinates.key("Mt. Pleasant") == "mount pleasant" && PlaceCoordinates.key("ZÜRICH") == "zurich")
        check("the list counts its places", places.cityCount == 11)
    }

    // MARK: What ships

    @MainActor
    private static func bundledChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let started = Date()
        let places = PlaceCoordinates.bundled
        let seconds = Date().timeIntervalSince(started)
        print("      (the bundled list loaded in \(String(format: "%.2f", seconds)) s)")
        check("the bundled list has the world's cities", places.cityCount > 60_000, "\(places.cityCount)")
        check("building the index takes under 3 seconds", seconds < 3, "\(seconds)")
        func find(_ city: String, _ code: String, _ region: String? = nil) -> PlaceCoordinate? {
            places.coordinate(for: OriginPlace(city: city, region: region, country: nil, countryCode: code))
        }
        let known: [(String, String, Double, Double)] = [
            ("Paris", "FR", 48.85, 2.35), ("London", "GB", 51.51, -0.13), ("Tokyo", "JP", 35.69, 139.69), ("Sydney", "AU", -33.87, 151.21),
            ("Reykjavik", "IS", 64.14, -21.90), ("Mexico City", "MX", 19.43, -99.13), ("Cairo", "EG", 30.04, 31.24), ("Auckland", "NZ", -36.85, 174.76),
        ]
        let misses = known.filter { city, code, lat, lon in
            guard let found = find(city, code) else { return true }
            return found.level != .city || abs(found.latitude - lat) > 0.6 || abs(found.longitude - lon) > 0.6
        }.map(\.0)
        check("well-known cities land where they are, at city level", misses.isEmpty, "off: \(misses)")
        let york = places.coordinate(for: OriginPlace(city: "New York", region: nil, country: nil, countryCode: "US"))
        check("'New York' in the real list is the city", york.map { $0.level == .city && abs($0.latitude - 40.7) < 0.3 && abs($0.longitude + 74) < 0.5 } == true, "\(String(describing: york))")
        let brooklyn = places.coordinate(for: OriginPlace(city: "Brooklyn", region: "New York", country: nil, countryCode: "US"))
        check("a borough is found by its own name", brooklyn.map { $0.level == .city && abs($0.latitude - 40.65) < 0.2 } == true, "\(String(describing: brooklyn))")
        check("a country with an outline is placed from it", places.coordinate(for: OriginPlace(city: nil, region: nil, country: nil, countryCode: "NZ"))?.level == .country)

        // Swapped latitude and longitude, or a row in the wrong country, would put many cities outside their country's frame.
        if let url = Bundle.main.url(forResource: "cities5000", withExtension: "tsv"), let text = try? String(contentsOf: url, encoding: .utf8) {
            let world = WorldGeometry.bundled
            var frames: [String: (minLon: Double, maxLon: Double, minLat: Double, maxLat: Double)] = [:]
            for country in world.countries {
                let points = country.rings.flatMap { $0 }
                frames[country.iso] = (Double(points.map(\.x).min() ?? 0), Double(points.map(\.x).max() ?? 0), Double(points.map(\.y).min() ?? 0), Double(points.map(\.y).max() ?? 0))
            }
            var inside = 0, total = 0
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard f.count >= 7, let frame = frames[String(f[2])], let lat = Double(f[4]), let lon = Double(f[5]) else { continue }
                total += 1
                if lon >= frame.minLon - 3, lon <= frame.maxLon + 3, lat >= frame.minLat - 3, lat <= frame.maxLat + 3 { inside += 1 }
            }
            let share = total == 0 ? 0 : Double(inside) / Double(total)
            print("      (\(total) cities checked against their country's frame: \(String(format: "%.1f", share * 100))% inside)")
            check("nearly every city lies within 3° of its country's outline (swapped coordinates would not)", total > 50_000 && share > 0.97, "\(inside) of \(total)")
        } else {
            check("the bundled city list can be read", false)
        }
    }

    // MARK: Coverage of a real library

    /// Reports, for a copy of a library, how many artists have an origin and at what level the map could place them.
    @MainActor
    private static func coverage(container: ModelContainer) async {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_STORE_PATH"] != nil else {
            print("ORIGINMAP_COVERAGE refused: set SCROBLYTICS_STORE_PATH to a copy of a library")
            exit(2)
        }
        do {
            let snapshots = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            let artists = ArtistMapScope.top(snapshots: snapshots, count: Int.max).entries
            let origins = QueryOriginSnapshot.load(context: container.mainContext)
            let places = PlaceCoordinates.bundled
            var counts: [String: Int] = [:], plays: [String: Int] = [:]
            var totalPlays = 0
            for artist in artists {
                totalPlays += artist.plays
                let display = origins.display(artist: artist.name)
                var level: String
                var detail = ""
                switch display.state {
                case .pending: level = "not looked up"
                case .unknown: level = "unknown to MusicBrainz"
                case .known:
                    if let found = places.coordinate(for: display.place) {
                        level = ["city", "region", "country"][found.level.rawValue]
                        detail = "\(display.place.text) → \(found.matchedName)"
                    } else {
                        level = "no coordinates"
                        detail = display.place.text
                    }
                }
                counts[level, default: 0] += 1
                plays[level, default: 0] += artist.plays
                if level != "city" { print("COVERAGE\t\(level)\t\(artist.name)\t\(artist.plays)\t\(detail)") }
            }
            print("COVERAGE_SUMMARY artists=\(artists.count) plays=\(totalPlays)")
            for level in ["city", "region", "country", "no coordinates", "unknown to MusicBrainz", "not looked up"] {
                let n = counts[level] ?? 0, p = plays[level] ?? 0
                print("COVERAGE_LEVEL\t\(level)\tartists=\(n)\tplays=\(p)\t\(totalPlays == 0 ? 0 : p * 100 / totalPlays)% of plays")
            }
            exit(0)
        } catch {
            print("ORIGINMAP_COVERAGE failed: \(error)")
            exit(1)
        }
    }
}
#endif
