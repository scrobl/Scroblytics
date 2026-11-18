import AppKit
import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_ORIGINMAP_CHECK=1`: the foundation of the origin map. The projection, the bundled world outline, the country names and
/// the place coordinates, against hand-made tables and then against the data that ships in the app. All offline; exits 0 on success.
///
/// `SCROBLYTICS_ORIGINMAP_DUMP=1` (same setting): the map for all time, country by country and dot by dot, to compare with an independent count.
///
/// `SCROBLYTICS_ORIGINMAP_COVERAGE=1` (with `SCROBLYTICS_STORE_PATH` on a copy of a library): how many of that library's artists can be
/// placed on the map, at city, region or country level, weighted by plays, and which ones fall short.
enum OriginMapChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        if env["SCROBLYTICS_ORIGINMAP_DUMP"] != nil {
            Task { @MainActor in await dump(container: container) }
            return
        }
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
            mapEngineChecks(check)
            artistMapChecks(check)
            localSceneChecks(check)
            rabbitHoleChecks(check)
            tripChecks(check)
            passportChecks(check)
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
        check("the whole globe is about twice as wide as it is tall", abs(RobinsonProjection.fullAspect - 1.9717) < 0.001, "\(RobinsonProjection.fullAspect)")
        check("the frame shows 84°N to 58°S, so it is wider than the globe", RobinsonProjection.top > 0.95 && RobinsonProjection.bottom < -0.65 && abs(RobinsonProjection.aspect - 2.347) < 0.01, "\(RobinsonProjection.aspect) \(RobinsonProjection.top) \(RobinsonProjection.bottom)")
        let rect = CGRect(x: 10, y: 20, width: 400, height: 200)
        let corner = WorldGeometry.point(CGPoint(x: -1, y: RobinsonProjection.top), in: rect)
        let opposite = WorldGeometry.point(CGPoint(x: 1, y: RobinsonProjection.bottom), in: rect)
        check("the top left of the frame is 84°N at the western edge, y pointing down on screen", abs(corner.x - 10) < 1e-9 && abs(corner.y - 20) < 1e-9 && abs(opposite.x - 410) < 1e-9 && abs(opposite.y - 220) < 1e-9, "\(corner) \(opposite)")
        var roundTrips = true
        for (lon, lat) in [(-98.4, 39.5), (2.5, 46.6), (151.2, -33.9), (-70.0, -54.0), (18.0, 78.0)] {
            let unit = RobinsonProjection.project(longitude: lon, latitude: lat)
            let there = WorldGeometry.point(unit, in: rect)
            let back = WorldGeometry.projected(there, in: rect)
            if abs(back.x - unit.x) > 1e-9 || abs(back.y - unit.y) > 1e-9 || !rect.contains(there) { roundTrips = false }
        }
        check("a point placed in the frame and read back is where it began, and lands inside the frame", roundTrips)
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

    // MARK: Artist Map and country phrases

    @MainActor
    private static func artistMapChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let summary = ArtistMapModel.originSummary
        check("a group with one known origin says nothing", summary([nil, nil, "GB"]) == nil && summary([]) == nil && summary([nil, nil]) == nil)
        check("a group all from one country says so", summary(["GB", "GB", "GB", nil]) == "All 3 with a known origin are from the United Kingdom", "\(String(describing: summary(["GB", "GB", "GB", nil])))")
        check("more than half from one country is 'mostly'", summary(["GB", "GB", "US"]) == "Mostly from the United Kingdom: 2 of 3 with a known origin" && summary(["CA", "CA", "CA", "US", nil]) == "Mostly from Canada: 3 of 4 with a known origin")
        check("exactly half is not 'mostly', and a spread says nothing", summary(["GB", "US"]) == nil && summary(["GB", "GB", "US", "US"]) == nil && summary(["GB", "US", "DE", "FR"]) == nil)
        check("artists with no known origin are left out of the count", summary(["US", "US", nil, nil, nil, "GB"]) == "Mostly from the United States: 2 of 3 with a known origin")
        check("a country reads with 'the' where it should", CountryNames.phrase(forCode: "US") == "the United States" && CountryNames.phrase(forCode: "GB") == "the United Kingdom" && CountryNames.phrase(forCode: "NL") == "the Netherlands")
        check("…and without it elsewhere", CountryNames.phrase(forCode: "CA") == "Canada" && CountryNames.phrase(forCode: "NZ") == "New Zealand" && CountryNames.phrase(forCode: "ZZ") == "ZZ")
        // The map's saved options: an older save with no colour setting opens as it did, and the new choice survives a save.
        let old = Data(#"{"mode":"top","count":50,"periodId":"last30","minMatchPercent":40,"showGhosts":false,"showArtwork":true,"reach":1}"#.utf8)
        let decoded = try? JSONDecoder().decode(ArtistMapModel.Options.self, from: old)
        check("options saved before coloring by country existed open colored by group", decoded?.colorBy == .group && decoded?.count == 50)
        var chosen = ArtistMapModel.Options()
        chosen.colorBy = .country
        let again = (try? JSONEncoder().encode(chosen)).flatMap { try? JSONDecoder().decode(ArtistMapModel.Options.self, from: $0) }
        check("a color-by-country choice survives a save", again?.colorBy == .country)
        check("the color choices are group and country", ArtistMapModel.Options.ColorBy.allCases.map(\.title) == ["Group", "Country"])
        check("eight countries get colors, distinct from each other and from the others", Set(ArtistMapPalette.countryColors.map { "\($0)" }).count == 8 && ArtistMapPalette.countryColors.count == 8)
    }

    // MARK: Close to home

    @MainActor
    private static func localSceneChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let home = OriginPlace(city: "City A", region: "State One", country: "United States", countryCode: "US")
        func scene(_ place: OriginPlace, home: OriginPlace = home) -> LocalScene { LocalScene.of(place: place, home: home) }
        check("the home city is the city layer", scene(OriginPlace(city: "City A", region: "State One", country: nil, countryCode: "US")) == .city)
        check("case, accents and St./Saint don't matter", scene(OriginPlace(city: "city a", region: "STATE ONE", country: nil, countryCode: "US")) == .city
              && scene(OriginPlace(city: "St. Louis", region: nil, country: nil, countryCode: "US"), home: OriginPlace(city: "Saint Louis", region: nil, country: nil, countryCode: "US")) == .city)
        check("another city in the home region is the region layer", scene(OriginPlace(city: "City B", region: "State One", country: nil, countryCode: "US")) == .region)
        check("an artist known only by the home region is the region layer", scene(OriginPlace(city: nil, region: "State One", country: nil, countryCode: "US")) == .region)
        check("another region of the home country is the country layer", scene(OriginPlace(city: "City C", region: "State Two", country: nil, countryCode: "US")) == .country)
        check("a city with the home city's name in another region is not the home city", scene(OriginPlace(city: "City A", region: "State Two", country: nil, countryCode: "US")) == .country)
        check("a city with the home city's name in another country is elsewhere", scene(OriginPlace(city: "City A", region: nil, country: "France", countryCode: "FR")) == .elsewhere)
        check("a country alone is the country layer at best", scene(OriginPlace(city: nil, region: nil, country: "United States", countryCode: nil)) == .country)
        check("a place with no country can't be at home", scene(OriginPlace(city: "City A", region: nil, country: nil, countryCode: nil)) == .elsewhere)
        let noRegion = OriginPlace(city: "City A", region: nil, country: "United States", countryCode: "US")
        check("a home with no region still matches its city, and everything else in the country is the country layer",
              scene(OriginPlace(city: "City A", region: "State Two", country: nil, countryCode: "US"), home: noRegion) == .city && scene(OriginPlace(city: "City B", region: "State One", country: nil, countryCode: "US"), home: noRegion) == .country)
        check("a home with no country makes everything elsewhere", scene(OriginPlace(city: "City A", region: "State One", country: nil, countryCode: "US"), home: OriginPlace(city: "City A", region: nil, country: nil, countryCode: nil)) == .elsewhere)

        // A quarter of plays by month, worked out by hand.
        let calendar = AppCalendars.listening
        func day(_ month: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: 2027, month: month, day: d, hour: 12))! }
        let range = DateRange(from: calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!, to: calendar.date(from: DateComponents(year: 2027, month: 3, day: 31, hour: 23, minute: 59))!)
        func entry(_ place: OriginPlace) -> OriginEntrySnapshot { OriginEntrySnapshot(status: .found, mbid: "m", matchedName: nil, kind: .group, place: place, candidates: [], resolvedAt: range.from) }
        var origins = QueryOriginSnapshot(lookupsOn: true)
        origins.entries["artist a"] = entry(OriginPlace(city: "City A", region: "State One", country: nil, countryCode: "US"))
        origins.entries["artist b"] = entry(OriginPlace(city: "City B", region: "State One", country: nil, countryCode: "US"))
        origins.entries["artist c"] = entry(OriginPlace(city: "City C", region: "State Two", country: nil, countryCode: "US"))
        origins.entries["artist d"] = entry(OriginPlace(city: "City D", region: nil, country: "France", countryCode: "FR"))
        origins.entries["artist e"] = OriginEntrySnapshot(status: .none, mbid: nil, matchedName: nil, kind: nil, place: OriginPlace(), candidates: [], resolvedAt: range.from)
        var plays: [ScrobbleSnapshot] = []
        func add(_ artist: String, _ count: Int, _ month: Int) {
            for i in 0..<count { plays.append(ScrobbleSnapshot(artistName: artist, albumName: "Album", trackName: "Song \(artist) \(month) \(i)", imageURL: nil, playedAt: day(month, 15).addingTimeInterval(Double(i * 60)))) }
        }
        add("Artist A", 2, 1); add("Artist B", 1, 1); add("Artist C", 1, 1)
        add("Artist A", 1, 2); add("Artist D", 3, 2)
        add("Artist E", 2, 3); add("Artist C", 2, 3)
        plays.append(ScrobbleSnapshot(artistName: "Artist A", albumName: "Album", trackName: "Out of range", imageURL: nil, playedAt: day(1, 15).addingTimeInterval(-90 * 86_400)))
        plays.sort { $0.playedAt < $1.playedAt }
        let result = LocalSceneEngine.compute(scrobbles: plays, origins: origins, durations: .empty, range: range, metric: .plays, home: home)
        check("a quarter is counted by month, with the plays outside it left out", result.bucketing == .month && result.buckets.count == 3 && result.total == 12, "\(result.bucketing) \(result.buckets.count) \(result.total)")
        check("January: two from the city, one from the region, one from the country",
              result.buckets[0].weights == [.city: 2, .region: 1, .country: 1] && abs(result.buckets[0].share(.city) - 0.5) < 1e-9, "\(result.buckets[0].weights)")
        check("February: one from the city, three elsewhere", result.buckets[1].weights == [.city: 1, .elsewhere: 3])
        check("March: two unknown, two from the country", result.buckets[2].weights == [.unknown: 2, .country: 2])
        check("the whole period adds the months up", result.overall == [.city: 3, .region: 1, .country: 3, .elsewhere: 3, .unknown: 2], "\(result.overall)")
        check("the home country's share is the three layers together", abs(result.homeCountryShare - 7.0 / 12.0) < 1e-9)
        check("the first bucket starts with the period and every bucket ends where the next begins", result.buckets.first?.start == range.from && zip(result.buckets, result.buckets.dropFirst()).allSatisfy { $0.end <= $1.start })
        let time = LocalSceneEngine.compute(scrobbles: plays, origins: origins, durations: .empty, range: range, metric: .timeListened, home: home)
        check("counting time with no track lengths known counts nothing and says how many plays wait", time.total == 0 && time.pendingLength == 12)

        // The home place.
        let suite = "origin-home-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check("with no home chosen and no weather place there is no home", OriginHome.current(defaults: defaults) == nil)
        WeatherSettings.setPlace(WeatherPlace(name: "City W, Region W, Norway", latitude: 59.9, longitude: 10.7, region: "Region W", country: "Norway"), defaults: defaults)
        let fromWeather = OriginHome.current(defaults: defaults)
        check("the weather home place is the home, as a city, region and country", fromWeather == OriginPlace(city: "City W", region: "Region W", country: "Norway", countryCode: "NO"), "\(String(describing: fromWeather))")
        OriginHome.setChosen(OriginPlace(city: "City A", region: "State One", country: "United States", countryCode: "US"), defaults: defaults)
        check("a home chosen for the chart wins over the weather place", OriginHome.current(defaults: defaults)?.city == "City A")
        OriginHome.setChosen(nil, defaults: defaults)
        check("forgetting it goes back to the weather place", OriginHome.current(defaults: defaults)?.city == "City W")
        OriginHome.setChosen(OriginPlace(), defaults: defaults)
        check("an empty place is never saved as the home", OriginHome.chosen(defaults: defaults) == nil)
        // A weather place saved before countries were kept has only a name and coordinates; the bundled outlines and cities supply the rest.
        let towns = PlaceCoordinates(tsv: """
        City One\t\tUS\tState One\t39.1\t-98.2\t90000
        City Two\t\tUS\tState Two\t30.0\t-95.0\t90000
        City W\t\tNO\tRegion W\t59.1\t5.7\t90000
        """)
        let inland = towns.locate(latitude: 39.0, longitude: -98.0)
        check("a spot inland is placed by the outline, with the region of the nearest listed city", inland?.countryCode == "US" && inland?.region == "State One", "\(String(describing: inland))")
        let farFromAny = towns.locate(latitude: 45.0, longitude: -110.0)
        check("inside a country but over 150 km from any listed city gives the country and no region", farFromAny?.countryCode == "US" && farFromAny?.region == nil, "\(String(describing: farFromAny))")
        let coast = towns.locate(latitude: 59.05, longitude: 5.3)
        check("a spot just off the coast, outside the coarse outline, is placed by the nearest city within 60 km", coast?.countryCode == "NO" && coast?.region == "Region W", "\(String(describing: coast))")
        check("open sea far from any city is nowhere", towns.locate(latitude: 0, longitude: -30) == nil && towns.locate(latitude: 95, longitude: 0) == nil)
        WeatherSettings.setPlace(WeatherPlace(name: "City One", latitude: 39.0, longitude: -98.0), defaults: defaults)
        let oldPlace = OriginHome.fromWeather(defaults: defaults, places: towns)
        check("an older weather place with only a name and coordinates gets its country and region from them", oldPlace == OriginPlace(city: "City One", region: "State One", country: "United States", countryCode: "US"), "\(String(describing: oldPlace))")
        check("the local scene then puts an artist from that region at home instead of elsewhere", oldPlace.map { LocalScene.of(place: OriginPlace(city: "City Q", region: "State One", country: "United States", countryCode: "US"), home: $0) } == .region)
        WeatherSettings.setPlace(WeatherPlace(name: "City One", latitude: 39.0, longitude: -98.0, region: nil, country: "Norway"), defaults: defaults)
        check("a country that was saved is never replaced by the coordinates", OriginHome.fromWeather(defaults: defaults, places: towns)?.countryCode == "NO")
        WeatherSettings.setPlace(WeatherPlace(typedName: "Typed Place"), defaults: defaults)
        check("a weather place that is only a typed name has no country", OriginHome.countryCode(of: OriginHome.current(defaults: defaults) ?? OriginPlace()) == nil)
    }

    // MARK: Rabbit Hole: scenes and borders

    @MainActor
    private static func rabbitHoleChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func display(_ city: String?, _ region: String?, _ country: String, _ code: String) -> ArtistOriginDisplay {
            ArtistOriginDisplay(state: .known, place: OriginPlace(city: city, region: region, country: country, countryCode: code), kind: .group, corrected: false, needsReview: false)
        }
        let seed = display("City A", "State One", "United States", "US")
        let unknown = ArtistOriginDisplay(state: .pending, place: OriginPlace(), kind: nil, corrected: false, needsReview: false)
        func relation(_ other: ArtistOriginDisplay, seed: ArtistOriginDisplay = seed) -> RabbitHoleScene { RabbitHoleScene.relation(seed: seed, other: other) }
        check("the same city is the same scene", relation(display("City A", "State One", "United States", "US")) == .city)
        check("another city in the same region is the region", relation(display("City B", "State One", "United States", "US")) == .region)
        check("another region of the same country is the country", relation(display("City C", "State Two", "United States", "US")) == .country)
        check("another country is abroad", relation(display("City D", nil, "France", "FR")) == .abroad)
        check("an artist with no known origin, or a seed with none, has no scene", relation(unknown) == .unknown && relation(seed, seed: unknown) == .unknown)
        check("a place with no country can't be compared", relation(ArtistOriginDisplay(state: .known, place: OriginPlace(city: "City A", region: nil, country: nil, countryCode: nil), kind: nil, corrected: false, needsReview: false)) == .unknown)

        let scenes: [RabbitHoleScene] = [.city, .region, .country, .abroad, .unknown]
        check("with no lean every scene counts the same", scenes.allSatisfy { $0.factor(places: 0) == 1 })
        check("staying in the scene favours the nearer, in order, and an unknown stays neutral",
              RabbitHoleScene.city.factor(places: 1) > RabbitHoleScene.region.factor(places: 1) && RabbitHoleScene.region.factor(places: 1) > RabbitHoleScene.country.factor(places: 1)
                && RabbitHoleScene.country.factor(places: 1) > RabbitHoleScene.unknown.factor(places: 1) && RabbitHoleScene.unknown.factor(places: 1) > RabbitHoleScene.abroad.factor(places: 1))
        check("crossing borders favours another country over every nearer scene", RabbitHoleScene.abroad.factor(places: 2) > 1 && [RabbitHoleScene.city, .region, .country].allSatisfy { $0.factor(places: 2) < 1 })
        check("no scene is ever given a zero chance, whatever the setting", (0...2).allSatisfy { places in scenes.allSatisfy { $0.factor(places: places) > 0 } })

        func item(_ key: String, _ scene: RabbitHoleScene) -> RabbitHoleSelector.Item {
            RabbitHoleSelector.Item(key: key, artistKey: key, albumKey: key, topTag: nil, score: 80, plays: 10, lastPlayed: Date(timeIntervalSince1970: 1_700_000_000), loved: false, scene: scene)
        }
        var knobs = RabbitHoleKnobs()
        knobs.avoidRepeats = false
        let memory = RabbitHoleMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        knobs.places = 1
        let near = RabbitHoleSelector.weight(item("a", .city), knobs: knobs, memory: memory, now: now), far = RabbitHoleSelector.weight(item("b", .abroad), knobs: knobs, memory: memory, now: now)
        check("a track's weight follows its scene under 'stay in the scene'", near > far * 3, "\(near) \(far)")
        knobs.places = 0
        check("and not at all with no lean", RabbitHoleSelector.weight(item("a", .city), knobs: knobs, memory: memory, now: now) == RabbitHoleSelector.weight(item("b", .abroad), knobs: knobs, memory: memory, now: now))

        // Over thousands of picks each setting leans the way it says, and every item stays possible.
        let pool: [RabbitHoleSelector.Item] = scenes.flatMap { scene in (0..<2).map { item("\(scene.rawValue)-\($0)", scene) } }
        func share(places: Int, scene: RabbitHoleScene, trials: Int = 6000) -> Double {
            var rng = SeededRandom(seed: UInt64(11 + places))
            var k = RabbitHoleKnobs(); k.avoidRepeats = false; k.places = places
            var hits = 0
            for _ in 0..<trials {
                if RabbitHoleSelector.pick(pool, count: 1, knobs: k, memory: memory, pathArtistCounts: [:], pathAlbumCounts: [:], perArtist: 0, perAlbum: 0, now: now, using: &rng).first?.scene == scene { hits += 1 }
            }
            return Double(hits) / Double(trials)
        }
        let anyCity = share(places: 0, scene: .city), stayCity = share(places: 1, scene: .city), crossCity = share(places: 2, scene: .city), crossAbroad = share(places: 2, scene: .abroad)
        check("with no lean a fifth of the picks are from the same city", abs(anyCity - 0.2) < 0.03, "\(anyCity)")
        check("'stay in the scene' makes the same city's picks about a third", abs(stayCity - 6.0 / 16.8) < 0.04, "\(stayCity)")
        check("'cross borders' makes it rare, and picks another country about half the time", crossCity < 0.09 && abs(crossAbroad - 5.0 / 9.6) < 0.04, "\(crossCity) \(crossAbroad)")
        var rng = SeededRandom(seed: 99)
        var cross = RabbitHoleKnobs(); cross.places = 2
        let onlyCity = (0..<4).map { item("c\($0)", .city) }
        check("a pool with nothing in the preferred scene still gives its three picks", RabbitHoleSelector.pick(onlyCity, count: 3, knobs: cross, memory: memory, pathArtistCounts: [:], pathAlbumCounts: [:], perArtist: 0, perAlbum: 0, now: now, using: &rng).count == 3)

        // The saved option.
        let old = Data(#"{"familiarity":1,"wander":2,"avoidRepeats":true,"newMusic":1}"#.utf8)
        let decoded = try? JSONDecoder().decode(RabbitHoleKnobs.self, from: old)
        check("options saved before Places existed open with no lean", decoded?.places == 0 && decoded?.wander == 2 && decoded?.newMusic == 1)
        check("an out-of-range Places value is clamped", (try? JSONDecoder().decode(RabbitHoleKnobs.self, from: Data(#"{"places":7}"#.utf8)))?.places == 2 && (try? JSONDecoder().decode(RabbitHoleKnobs.self, from: Data(#"{"places":-3}"#.utf8)))?.places == 0)
        var chosen = RabbitHoleKnobs(); chosen.places = 2
        check("the choice survives a save", (try? JSONEncoder().encode(chosen)).flatMap { try? JSONDecoder().decode(RabbitHoleKnobs.self, from: $0) }?.places == 2)

        // Why a track was offered.
        let other = display("City A", "State One", "United States", "US")
        check("the same city says 'Also from' it, at any setting", RabbitHoleEngine.sceneReason(.city, seed: seed, other: other, places: 0)?.text == "Also from City A" && RabbitHoleEngine.sceneReason(.city, seed: seed, other: other, places: 0)?.kind == .sameScene)
        check("the same region says so too", RabbitHoleEngine.sceneReason(.region, seed: seed, other: display("City B", "State One", "United States", "US"), places: 0)?.text == "Also from State One")
        check("the same country is only said when you asked to stay in the scene", RabbitHoleEngine.sceneReason(.country, seed: seed, other: display("City C", "State Two", "United States", "US"), places: 1)?.text == "Also from the United States"
              && RabbitHoleEngine.sceneReason(.country, seed: seed, other: display("City C", "State Two", "United States", "US"), places: 0) == nil)
        check("another country is only said when you asked to cross borders", RabbitHoleEngine.sceneReason(.abroad, seed: seed, other: display("City D", nil, "France", "FR"), places: 2)?.text == "From France, not the United States"
              && RabbitHoleEngine.sceneReason(.abroad, seed: seed, other: display("City D", nil, "France", "FR"), places: 1) == nil)
        check("a track with no scene has no such reason", RabbitHoleEngine.sceneReason(.unknown, seed: seed, other: unknown, places: 1) == nil)
        let reasons = [RabbitHoleReason(kind: .similar, text: "s"), RabbitHoleReason(kind: .sharedTags, text: "t"), RabbitHoleReason(kind: .forgotten, text: "f"), RabbitHoleReason(kind: .sameScene, text: "scene")]
        check("a scene reason ranks above shared tags among the three shown", RabbitHoleEngine.topReasons(reasons).map(\.kind) == [.similar, .sameScene, .sharedTags])
    }

    // MARK: Trips: local music abroad

    @MainActor
    private static func tripChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { a.map { abs($0 - b) < tolerance } ?? false }
        let utc = WeatherChecks.utc
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date { WeatherChecks.date(y, m, d, h, min) }
        // 20 days, Mar 1–20: two plays a day at home by Artist A (30 plays), and on the five trip days (Mar 5–9) one play a day:
        // Artist A on the first, Artist B on the other four.
        func scenario(tripCountry: String?) -> (plays: [ScrobbleSnapshot], weather: WeatherSnapshot) {
            let place = WeatherPlace(name: "City T, Country T", latitude: 38.72, longitude: -9.14, region: nil, country: tripCountry)
            let trip = WeatherTrip(place: place, from: date(2025, 3, 5), until: date(2025, 3, 10))
            var weather = WeatherChecks.marchApril()
            var away = WeatherSeries(startHour: WeatherSeries.hour(of: date(2025, 3, 5)), count: 24 * 5)
            for h in away.startHour..<(away.startHour + 24 * 5) { away.set(hour: h, WeatherSample(temperature: 20, precipitation: nil, rain: nil, snowfall: nil, code: 61)) }
            weather.trips = [WeatherSnapshot.TripWeather(trip: trip, series: away)]
            var plays: [ScrobbleSnapshot] = []
            for d in 1...20 {
                if (5...9).contains(d) { plays.append(WeatherChecks.playAt(d == 5 ? "Artist A" : "Artist B", day: d, hour: 12)) }
                else { plays.append(WeatherChecks.playAt("Artist A", day: d, hour: 10)); plays.append(WeatherChecks.playAt("Artist A", day: d, hour: 15)) }
            }
            return (plays, weather)
        }
        func entry(_ place: OriginPlace) -> OriginEntrySnapshot { OriginEntrySnapshot(status: .found, mbid: "m", matchedName: nil, kind: .group, place: place, candidates: [], resolvedAt: date(2025, 1, 1)) }
        var origins = QueryOriginSnapshot(lookupsOn: true)
        origins.entries["artist a"] = entry(OriginPlace(city: nil, region: nil, country: "Norway", countryCode: "NO"))
        origins.entries["artist b"] = entry(OriginPlace(city: nil, region: nil, country: "Portugal", countryCode: "PT"))
        let range = DateRange(from: date(2025, 3, 1), to: date(2025, 3, 20, 23, 59))
        let now = date(2025, 3, 20, 23, 59)
        let (plays, weather) = scenario(tripCountry: "Portugal")
        let result = TrendsPlacesEngine.compute(scrobbles: plays, weather: weather, range: range, origins: origins, homeCountry: "NO", now: now, calendar: utc)
        let trip = result.trips.first, home = result.home
        check("the trip's country comes from its place, and home's from the weather home place", trip?.countryCode == "PT" && home?.countryCode == "NO")
        check("on the trip 4 of 5 plays were by artists from Portugal: Artist B", trip?.localPlays == 4 && trip?.knownOriginPlays == 5 && near(trip?.localShare, 0.8) && trip?.topLocalArtists == [TrendsStay.Artist(name: "Artist B", plays: 4)], "\(String(describing: trip))")
        check("at home all 30 plays were by Norwegian Artist A", home?.localPlays == 30 && home?.knownOriginPlays == 30 && near(home?.localShare, 1))
        check("every play's artist is known here, so coverage is complete", near(trip?.originCoverage, 1) && near(home?.originCoverage, 1))
        var partial = origins
        partial.entries["artist b"] = nil
        let half = TrendsPlacesEngine.compute(scrobbles: plays, weather: weather, range: range, origins: partial, homeCountry: "NO", now: now, calendar: utc)
        check("an artist whose origin isn't known counts as a play, not as local, and lowers the coverage", near(half.trips.first?.localShare, 0) && near(half.trips.first?.originCoverage, 0.2) && half.trips.first?.knownOriginPlays == 1, "\(String(describing: half.trips.first))")
        let blind = TrendsPlacesEngine.compute(scrobbles: plays, weather: weather, range: range, homeCountry: "NO", now: now, calendar: utc)
        check("with no origins loaded there is no share at all, not zero", blind.trips.first?.localShare == nil && blind.home?.localShare == nil && blind.trips.first?.countryCode == "PT")
        let (typedPlays, typedWeather) = scenario(tripCountry: nil)
        let typed = TrendsPlacesEngine.compute(scrobbles: typedPlays, weather: typedWeather, range: range, origins: origins, homeCountry: "NO", now: now, calendar: utc)
        check("a trip whose place has no country has no local share", typed.trips.first?.countryCode == nil && typed.trips.first?.localShare == nil)
        let noHome = TrendsPlacesEngine.compute(scrobbles: plays, weather: weather, range: range, origins: origins, homeCountry: nil, now: now, calendar: utc)
        check("with no home country, home has no share but the trip still does", noHome.home?.localShare == nil && near(noHome.trips.first?.localShare, 0.8))
        check("the stay's plays are the same with or without origins", result.trips.first?.plays == blind.trips.first?.plays && result.home?.plays == blind.home?.plays && result.trips.first?.plays == 5)
    }

    // MARK: Passport

    @MainActor
    private static func passportChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func day(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 86_400) }
        func entry(_ country: String, _ code: String) -> OriginEntrySnapshot {
            OriginEntrySnapshot(status: .found, mbid: "m", matchedName: nil, kind: .group, place: OriginPlace(city: nil, region: nil, country: country, countryCode: code), candidates: [], resolvedAt: t0)
        }
        var origins = QueryOriginSnapshot(lookupsOn: true)
        // Day 0 Artist A (US), day 1 Artist B (US), day 2 Artist C (GB), day 3 Artist D (unknown), day 4 Artist E (FR), day 5 Artist F (JP), day 6 Artist G (not looked up).
        origins.entries["artist a"] = entry("United States", "US"); origins.entries["artist b"] = entry("United States", "US")
        origins.entries["artist c"] = entry("United Kingdom", "GB"); origins.entries["artist e"] = entry("France", "FR"); origins.entries["artist f"] = entry("Japan", "JP")
        origins.entries["artist d"] = OriginEntrySnapshot(status: .none, mbid: nil, matchedName: nil, kind: nil, place: OriginPlace(), candidates: [], resolvedAt: t0)
        var plays: [ScrobbleSnapshot] = []
        func play(_ artist: String, _ n: Int, count: Int = 1) {
            for i in 0..<count { plays.append(ScrobbleSnapshot(artistName: artist, albumName: "Album", trackName: "Song \(artist) \(n) \(i)", imageURL: nil, playedAt: day(n).addingTimeInterval(Double(i * 60)))) }
        }
        play("Artist A", 0, count: 3); play("Artist B", 1, count: 2); play("Artist C", 2); play("Artist D", 3); play("Artist E", 4, count: 4); play("Artist F", 5); play("Artist G", 6)
        play("Artist A", 20, count: 2)
        plays.sort { $0.playedAt < $1.playedAt }
        let result = CountryPassportEngine.compute(scrobbles: plays, origins: origins)
        check("four countries were reached, in the order they were first heard", result.stamps.map(\.code) == ["US", "GB", "FR", "JP"], "\(result.stamps.map(\.code))")
        let us = result.stamps.first
        check("a country's first heard date and artist are the earliest play of any artist from it", us?.firstHeard == day(0) && us?.firstArtist == "Artist A")
        check("its artists and all-time plays are added up over every artist from it (A 3+2, B 2)", us?.artists == 2 && us?.plays == 7, "\(String(describing: us))")
        check("another country's stamp is its own artist's", result.stamps.first { $0.code == "FR" }.map { $0.firstArtist == "Artist E" && $0.plays == 4 && $0.firstHeard == day(4) } == true)
        check("artists with no known origin are counted apart, not as a country", result.unknownArtists == 2 && result.knownArtists == 5, "\(result.unknownArtists) \(result.knownArtists)")
        check("a country's name is spelled one way", result.stamps.map(\.name) == ["United States", "United Kingdom", "France", "Japan"])
        check("the ladder has the first country and nothing beyond what was reached", result.steps.map(\.count) == [1] && result.steps.first?.reachedAt == day(0) && result.steps.first?.country == "United States")
        check("the next step is the fifth country", result.nextStep == 5 && result.countryCount == 4)
        // Enough countries for the ladder.
        var many = origins
        var longPlays = plays
        for index in 0..<12 {
            let code = ["DE", "SE", "NO", "IE", "CA", "AU", "NZ", "BR", "MX", "IT", "ES", "NL"][index]
            many.entries["artist x\(index)"] = entry(CountryNames.name(forCode: code) ?? code, code)
            longPlays.append(ScrobbleSnapshot(artistName: "Artist X\(index)", albumName: "Album", trackName: "Song", imageURL: nil, playedAt: day(30 + index)))
        }
        longPlays.sort { $0.playedAt < $1.playedAt }
        let long = CountryPassportEngine.compute(scrobbles: longPlays, origins: many)
        check("sixteen countries reach the steps 1, 5, 10 and 15, each dated by the country that made it", long.countryCount == 16 && long.steps.map(\.count) == [1, 5, 10, 15], "\(long.steps.map(\.count))")
        check("the fifth country's date is the day its first artist was first played (DE was country 5, day 30)", long.steps[1].reachedAt == day(30) && long.steps[1].country == "Germany", "\(long.steps[1])")
        check("the next step after sixteen countries is twenty", long.nextStep == 20)
        let none = CountryPassportEngine.compute(scrobbles: plays, origins: .empty)
        check("with no origins known there is no country and every artist is unknown", none.countryCount == 0 && none.steps.isEmpty && none.unknownArtists == 7 && none.nextStep == 1)
        check("a passport stamp opens everyone from that country over all time, most played first",
              { var spec = OriginMapDrill.countryAllTime(name: "United States"); spec.period = nil
                guard let validated = try? spec.validate(against: .standard) else { return false }
                var snapshots = QuerySnapshots(); snapshots.origins = origins
                let run = QueryRun(target: .artist, asOf: day(40), scrobbles: spec.countedPlays(plays), allTimeScrobbles: plays, snapshots: snapshots)
                let evaluated = QueryEngine.evaluate(validated, run: run)
                return Set(evaluated.rows.map(\.entity.name)) == ["Artist A", "Artist B"] }())
    }

    // MARK: The map's numbers

    @MainActor
    private static func mapEngineChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let range = DateRange(from: t0, to: t0.addingTimeInterval(30 * 86_400))
        let places = PlaceCoordinates(tsv: """
        City One\t\tUS\tState One\t10.0\t-80.0\t100000
        City Two\t\tUS\tState Two\t20.0\t-90.0\t50000
        Town X\t\tGB\tRegion R\t52.0\t-1.5\t80000
        """)
        let usOne = OriginPlace(city: "City One", region: "State One", country: "United States", countryCode: "US")
        let usTwo = OriginPlace(city: "City Two", region: "State Two", country: "United States", countryCode: "US")
        let hamlet = OriginPlace(city: "Tiny Hamlet", region: "Region R", country: "United Kingdom", countryCode: "GB")
        let gbOnly = OriginPlace(city: nil, region: nil, country: "United Kingdom", countryCode: "GB")
        func entry(_ status: ArtistOriginStatus, _ place: OriginPlace) -> OriginEntrySnapshot {
            OriginEntrySnapshot(status: status, mbid: "m", matchedName: nil, kind: .group, place: place, candidates: [], resolvedAt: t0)
        }
        var origins = QueryOriginSnapshot(lookupsOn: true)
        origins.entries["artist a"] = entry(.found, usOne)
        origins.entries["artist b"] = entry(.found, usTwo)
        origins.entries["artist c"] = entry(.found, usOne)
        origins.entries["artist d"] = entry(.found, hamlet)
        origins.entries["artist e"] = entry(.found, gbOnly)
        origins.entries["artist f"] = entry(.none, OriginPlace())
        origins.entries["artist h"] = entry(.found, OriginPlace(city: "Nowhere", region: nil, country: nil, countryCode: nil))
        // Artist G has nothing saved yet; Artist I's plays are outside the period.
        let counts: [(String, Int)] = [("Artist A", 5), ("Artist B", 3), ("Artist C", 2), ("Artist D", 4), ("Artist E", 1), ("Artist F", 6), ("Artist G", 2), ("Artist H", 1)]
        var plays: [ScrobbleSnapshot] = []
        var tick = 0
        for (artist, count) in counts {
            for i in 0..<count {
                tick += 1
                plays.append(ScrobbleSnapshot(artistName: artist, albumName: "Album", trackName: "Song \(artist) \(i)", imageURL: nil, playedAt: t0.addingTimeInterval(Double(tick) * 600)))
            }
        }
        for i in 0..<7 { plays.append(ScrobbleSnapshot(artistName: "Artist I", albumName: "Album", trackName: "Old \(i)", imageURL: nil, playedAt: t0.addingTimeInterval(-86_400 * Double(i + 5)))) }
        plays.sort { $0.playedAt < $1.playedAt }

        let result = OriginMapEngine.compute(scrobbles: plays, origins: origins, durations: .empty, range: range, metric: .plays, places: places)
        check("everything played in the period is counted, and nothing outside it", result.total == 24, "\(result.total)")
        check("plays by artists placed on the map are counted as mapped", result.mapped == 15, "\(result.mapped)")
        check("the rest is accounted for by reason: unknown 6, not looked up 2, no country 1",
              result.notOnMap[.unknownToMusicBrainz] == 6 && result.notOnMap[.notLookedUp] == 2 && result.notOnMap[.noCountry] == 1 && result.notOnMap[.lookupsOff] == nil, "\(result.notOnMap)")
        check("mapped plus not on the map is always the total", result.mapped + result.unmapped + 0 == result.total)
        check("there are four dots, biggest first", result.places.map(\.weight) == [7, 4, 3, 1], "\(result.places.map(\.weight))")
        let shared = result.places.first
        check("two artists from one city are one dot, with both counted and the bigger first", shared?.label == "City One, State One, United States" && shared?.artists == 2 && shared?.top.map(\.name) == ["Artist A", "Artist C"] && shared?.top.map(\.weight) == [5, 2], "\(String(describing: shared))")
        check("a city in the list is an exact dot at its coordinates", shared?.level == .city && abs((shared?.latitude ?? 0) - 10) < 0.001 && abs((shared?.longitude ?? 0) + 80) < 0.001 && shared?.isApproximate == false)
        let region = result.places.first { $0.level == .region }
        check("a city that isn't listed is a dashed dot for its region, which it names", region?.label == "Region R, United Kingdom" && region?.isApproximate == true && region?.weight == 4 && region?.city == nil, "\(String(describing: region))")
        let countryDot = result.places.first { $0.level == .country }
        check("an artist known only by country is a dot at the country's centre", countryDot?.label == "United Kingdom" && countryDot?.weight == 1 && (countryDot?.latitude ?? 0) > 50 && (countryDot?.latitude ?? 0) < 56)
        check("countries add their dots up, with the artists counted once each",
              result.countries.map(\.code) == ["US", "GB"] && result.countries.map(\.weight) == [10, 5] && result.countries.map(\.artists) == [3, 2] && result.countries.first?.name == "United States", "\(result.countries)")
        check("the artists on the map are the artists with a place", result.artistsMapped == 5)
        let off = { () -> OriginMapResult in var o = origins; o.lookupsOn = false; return OriginMapEngine.compute(scrobbles: plays, origins: o, durations: .empty, range: range, metric: .plays, places: places) }()
        check("with looking up switched off, artists with nothing saved are counted as having no origin, not as waiting", off.notOnMap[.lookupsOff] == 2 && off.notOnMap[.notLookedUp] == nil && off.mapped == 15)
        let time = OriginMapEngine.compute(scrobbles: plays, origins: origins, durations: .empty, range: range, metric: .timeListened, places: places)
        check("counting time with no track lengths known yet counts nothing and says how many plays wait", time.total == 0 && time.mapped == 0 && time.pendingLength == 24 && time.places.isEmpty, "\(time.total) \(time.pendingLength)")
        let nothing = OriginMapEngine.compute(scrobbles: plays, origins: origins, durations: .empty, range: DateRange(from: t0.addingTimeInterval(-10 * 86_400 * 100), to: t0.addingTimeInterval(-9 * 86_400 * 100)), metric: .plays, places: places)
        check("a period with no plays is an empty map", nothing.total == 0 && nothing.places.isEmpty && nothing.countries.isEmpty)

        // Top artists: only the most played of the period are counted; the totals still add up.
        let top3 = OriginMapEngine.compute(scrobbles: plays, origins: origins, durations: .empty, range: range, metric: .plays, places: places, topArtists: 3)
        check("the top 3 artists of the period (F 6, A 5, D 4) are all that is counted", top3.total == 15 && top3.topArtists == 3, "\(top3.total)")
        check("of them A (5) and D (4) are on the map and F (6) is unknown to MusicBrainz", top3.mapped == 9 && top3.notOnMap[.unknownToMusicBrainz] == 6 && top3.unmapped == 6 && top3.places.map(\.weight) == [5, 4], "\(top3.mapped) \(top3.notOnMap)")
        check("with the top 3, mapped plus not on the map is still the total", top3.mapped + top3.unmapped == top3.total)
        let top5 = OriginMapEngine.compute(scrobbles: plays, origins: origins, durations: .empty, range: range, metric: .plays, places: places, topArtists: 5)
        check("a tie for the last place goes to the name that sorts first (C before G), so the cut is always the same", top5.total == 20 && top5.mapped == 14 && top5.notOnMap[.notLookedUp] == nil, "\(top5.total) \(top5.mapped) \(top5.notOnMap)")
        let top100 = OriginMapEngine.compute(scrobbles: plays, origins: origins, durations: .empty, range: range, metric: .plays, places: places, topArtists: 100)
        check("asking for more artists than there are counts everyone, as with no limit", top100.total == result.total && top100.mapped == result.mapped && top100.places == result.places && top100.countries == result.countries)
        check("no limit leaves the result as it was, with no limit recorded", result.topArtists == nil && OriginMapEngine.compute(scrobbles: plays, origins: origins, durations: .empty, range: range, metric: .plays, places: places, topArtists: 0).total == 24)

        // Zooming about the cursor keeps the spot under it where it is.
        func screen(_ base: CGPoint, zoom: CGFloat, pan: CGSize, size: CGSize) -> CGPoint {
            CGPoint(x: size.width / 2 + pan.width + zoom * (base.x - size.width / 2), y: size.height / 2 + pan.height + zoom * (base.y - size.height / 2))
        }
        let frame = CGSize(width: 1000, height: 500), anchor = CGPoint(x: 700, y: 100)
        let startZoom: CGFloat = 2, startPan = CGSize(width: 30, height: -20)
        // The point of the unzoomed frame that is under the cursor now.
        let under = CGPoint(x: frame.width / 2 + (anchor.x - frame.width / 2 - startPan.width) / startZoom, y: frame.height / 2 + (anchor.y - frame.height / 2 - startPan.height) / startZoom)
        var anchored = true
        for target in [CGFloat(1), 3, 5, 12] {
            let pan = TrendsOriginMapChart.anchoredPan(anchor: anchor, size: frame, from: (startZoom, startPan), toZoom: target)
            let after = screen(under, zoom: target, pan: pan, size: frame)
            anchored = anchored && abs(after.x - anchor.x) < 0.001 && abs(after.y - anchor.y) < 0.001
        }
        check("zooming in or out about the cursor leaves the map point under it exactly where it was", anchored)
        let same = TrendsOriginMapChart.anchoredPan(anchor: anchor, size: frame, from: (startZoom, startPan), toZoom: startZoom)
        check("not changing the zoom changes nothing", same == startPan)
        let middle = TrendsOriginMapChart.anchoredPan(anchor: CGPoint(x: 500, y: 250), size: frame, from: (1, .zero), toZoom: 4)
        check("zooming about the middle of an unmoved map leaves it centred", middle == .zero)

        // What a click opens is exactly the artists behind the dot, with their plays in the period.
        var snapshots = QuerySnapshots()
        snapshots.origins = origins
        func clicked(_ spec: QuerySpec) -> [String: Double] {
            guard let validated = try? spec.validate(against: .standard) else { return [:] }
            let run = QueryRun(target: .artist, asOf: range.to, scrobbles: spec.countedPlays(plays), allTimeScrobbles: plays, snapshots: snapshots)
            let evaluated = QueryEngine.evaluate(validated, run: run)
            guard let playsKey = evaluated.columns.first(where: { $0.field.id == "plays" })?.cacheKey else { return [:] }
            return Dictionary(uniqueKeysWithValues: evaluated.rows.compactMap { row -> (String, Double)? in
                if case .value(.number(let n))? = row.cells[playsKey] { (row.entity.name, n) } else { nil }
            })
        }
        check("a city dot opens exactly its artists and their plays", shared.map { clicked(OriginMapDrill.place($0, range: range)) } == ["Artist A": 5, "Artist C": 2], "\(String(describing: shared.map { clicked(OriginMapDrill.place($0, range: range)) }))")
        check("a region dot opens everyone from that region", region.map { clicked(OriginMapDrill.place($0, range: range)) } == ["Artist D": 4])
        check("a country opens everyone from it", clicked(OriginMapDrill.country(name: "United States", range: range)) == ["Artist A": 5, "Artist B": 3, "Artist C": 2], "\(clicked(OriginMapDrill.country(name: "United States", range: range)))")
        check("…whatever the case of the name", clicked(OriginMapDrill.country(name: "united states", range: range)).count == 3)
        check("a click's list shows where each artist is from", OriginMapDrill.country(name: "United States", range: range).columns.contains(QueryFieldRef("originPlace")))

        // Colour steps and speed.
        check("shading steps rise and number at most four", { let s = TrendsOriginMapChart.shadingSteps(Array(1...10)); return s.count == 4 && s == s.sorted() }())
        check("one country needs no steps beyond itself, none needs none", TrendsOriginMapChart.shadingSteps([5]) == [5] && TrendsOriginMapChart.shadingSteps([]).isEmpty)
        var big: [ScrobbleSnapshot] = []
        big.reserveCapacity(400_000)
        for i in 0..<400_000 { big.append(ScrobbleSnapshot(artistName: "Artist \(i % 500)", albumName: "Album", trackName: "Song \(i % 3000)", imageURL: nil, playedAt: t0.addingTimeInterval(Double(i))) ) }
        let started = Date()
        let heavy = OriginMapEngine.compute(scrobbles: big, origins: origins, durations: .empty, range: DateRange(from: t0, to: t0.addingTimeInterval(400_000)), metric: .plays, places: places)
        let seconds = Date().timeIntervalSince(started)
        print("      (400,000 plays across 500 artists: \(String(format: "%.2f", seconds)) s)")
        check("a big library's map is worked out in under a second", seconds < 1.0 && heavy.total == 400_000, "\(seconds)")
        check("and its totals still add up", heavy.mapped + heavy.unmapped == heavy.total)
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

    // MARK: A made-up world for layout snapshots

    /// A spread of dots and countries around the world (real coordinates, made-up names and numbers) for looking at the map's layout.
    static func samplePlaces() -> OriginMapResult {
        // code, country, city label, latitude, longitude, weight, artists, approximate
        let rows: [(String, String, String, Double, Double, Int, Int, Bool)] = [
            ("US", "United States", "City A, State A", 33.75, -84.39, 3100, 22, false), ("US", "United States", "City B, State B", 40.71, -74.0, 2600, 31, false),
            ("US", "United States", "City C, State C", 47.61, -122.33, 1500, 14, false), ("US", "United States", "City D, State D", 41.88, -87.63, 1300, 12, false),
            ("US", "United States", "City E, State E", 34.05, -118.24, 900, 11, false), ("US", "United States", "State F", 44.0, -120.5, 700, 3, true),
            ("GB", "United Kingdom", "City G, England", 51.5, -0.12, 2100, 24, false), ("GB", "United Kingdom", "City H, England", 53.41, -2.99, 1400, 4, false),
            ("GB", "United Kingdom", "City I, Scotland", 55.95, -3.19, 400, 5, false), ("IE", "Ireland", "City J", 52.66, -8.63, 600, 2, false),
            ("CA", "Canada", "City K, Ontario", 43.65, -79.38, 800, 9, false), ("CA", "Canada", "City L, Quebec", 45.5, -73.57, 650, 7, false),
            ("AU", "Australia", "City M, State M", -33.87, 151.21, 500, 6, false), ("NZ", "New Zealand", "New Zealand", -41.0, 172.0, 900, 2, true),
            ("SE", "Sweden", "City N", 59.33, 18.07, 450, 6, false), ("DE", "Germany", "City O", 52.52, 13.4, 350, 5, false),
            ("FR", "France", "City P", 48.85, 2.35, 300, 4, false), ("JP", "Japan", "City Q", 35.69, 139.69, 250, 3, false),
            ("BR", "Brazil", "City R", -23.55, -46.63, 200, 2, false), ("NG", "Nigeria", "City S", 6.52, 3.38, 120, 1, false),
            ("IS", "Iceland", "City T", 64.14, -21.9, 180, 2, false), ("ZA", "South Africa", "City U", -26.2, 28.05, 90, 1, false),
        ]
        var places: [OriginMapResult.Place] = []
        var countries: [String: OriginMapResult.CountryTotal] = [:]
        for (index, row) in rows.enumerated() {
            places.append(OriginMapResult.Place(
                id: "sample\(index)", label: row.7 ? row.2 : row.2 + ", " + row.1, city: row.7 ? nil : row.2, region: nil, country: row.1, countryCode: row.0,
                latitude: row.3, longitude: row.4, level: row.7 ? .region : .city, weight: row.5, artists: row.6,
                top: [.init(name: "Artist A", weight: row.5 / 2), .init(name: "Artist B", weight: row.5 / 3), .init(name: "Artist C", weight: row.5 / 6)]
            ))
            var country = countries[row.0] ?? OriginMapResult.CountryTotal(code: row.0, name: row.1, weight: 0, artists: 0)
            country.weight += row.5
            country.artists += row.6
            countries[row.0] = country
        }
        let mapped = rows.reduce(0) { $0 + $1.5 }
        return OriginMapResult(
            metric: .plays, places: places.sorted { $0.weight > $1.weight }, countries: countries.values.sorted { $0.weight > $1.weight },
            total: mapped + 2300, mapped: mapped, notOnMap: [.notLookedUp: 1200, .unknownToMusicBrainz: 1100], pendingLength: 0
        )
    }

    /// Made-up pictures (a color block with a stripe) for the sample artists, so snapshots show how artwork sits on a dot and in the hover card.
    @MainActor
    static func sampleArtwork() -> [String: NSImage] {
        var images: [String: NSImage] = [:]
        for (index, name) in ["Artist A", "Artist B", "Artist C"].enumerated() {
            let image = NSImage(size: NSSize(width: 96, height: 96))
            image.lockFocus()
            [NSColor.systemPurple, NSColor.systemTeal, NSColor.systemPink][index].setFill()
            NSRect(x: 0, y: 0, width: 96, height: 96).fill()
            NSColor.white.withAlphaComponent(0.6).setFill()
            NSRect(x: 0, y: 36, width: 96, height: 24).fill()
            image.unlockFocus()
            images[name] = image
        }
        return images
    }

    // MARK: The map of a real library

    @MainActor
    private static func dump(container: ModelContainer) async {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_STORE_PATH"] != nil else {
            print("ORIGINMAP_DUMP refused: set SCROBLYTICS_STORE_PATH to a copy of a library")
            exit(2)
        }
        do {
            let snapshots = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            let origins = QueryOriginSnapshot.load(context: container.mainContext)
            let result = OriginMapEngine.compute(
                scrobbles: snapshots, origins: origins, durations: .empty, range: DateRange(from: .distantPast, to: Date()), metric: .plays, places: .bundled
            )
            print("MAPTOTAL total=\(result.total) mapped=\(result.mapped) unmapped=\(result.unmapped) places=\(result.places.count) countries=\(result.countries.count)")
            for country in result.countries { print("MAPCOUNTRY\t\(country.code)\t\(country.weight)\t\(country.artists)") }
            let scene = LocalSceneEngine.compute(
                scrobbles: snapshots, origins: origins, durations: .empty, range: DateRange(from: .distantPast, to: Date()), metric: .plays,
                home: OriginPlace(city: nil, region: nil, country: "United States", countryCode: "US")
            )
            print("LOCALSCENE total=\(scene.total) " + LocalScene.allCases.map { "\($0)=\(scene.overall[$0] ?? 0)" }.joined(separator: " ") + " buckets=\(scene.buckets.count) bucketSum=\(scene.buckets.reduce(0) { $0 + $1.total })")
            // The home the chart really uses (the Weather home place, with its country and region worked out when it was saved without them).
            if let home = OriginHome.current() {
                let real = LocalSceneEngine.compute(
                    scrobbles: snapshots, origins: origins, durations: .empty, range: DateRange(from: .distantPast, to: Date()), metric: .plays, home: home
                )
                print("HOME country=\(OriginHome.countryCode(of: home) ?? "none") region=\(home.region == nil ? "none" : "set") city=\(home.city == nil ? "none" : "set")")
                print("HOMESCENE total=\(real.total) " + LocalScene.allCases.map { "\($0)=\(real.overall[$0] ?? 0)" }.joined(separator: " "))
            } else {
                print("HOME none")
            }
            for place in result.places { print("MAPPLACE\t\(place.label)\t\(place.weight)\t\(place.artists)\t\(place.level)\t\(String(format: "%.3f", place.latitude))\t\(String(format: "%.3f", place.longitude))") }
            exit(0)
        } catch {
            print("ORIGINMAP_DUMP failed: \(error)")
            exit(1)
        }
    }

    /// Twelve months of made-up shares, for the layout snapshots of the local-scene chart.
    static func sampleLocalScene() -> (result: LocalSceneResult, home: OriginPlace) {
        let calendar = AppCalendars.listening
        let home = OriginPlace(city: "City A", region: "State One", country: "United States", countryCode: "US")
        var buckets: [LocalSceneResult.Bucket] = []
        var overall: [LocalScene: Int] = [:]
        for month in 0..<12 {
            let start = calendar.date(from: DateComponents(year: 2026, month: month + 1, day: 1))!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            let city = 40 + (month * 7) % 30, region = 60 + (month * 11) % 40, country = 300 + (month * 37) % 150, elsewhere = 250 + (month * 53) % 200, unknown = 40 + (month * 5) % 90
            let weights: [LocalScene: Int] = [.city: city, .region: region, .country: country, .elsewhere: elsewhere, .unknown: unknown]
            for (scene, weight) in weights { overall[scene, default: 0] += weight }
            buckets.append(LocalSceneResult.Bucket(start: start, end: end, weights: weights))
        }
        return (LocalSceneResult(metric: .plays, bucketing: .month, buckets: buckets, overall: overall, pendingLength: 0, home: home), home)
    }

    /// A passport of made-up countries, for the layout snapshots.
    static func samplePassport() -> CountryPassportResult {
        let rows: [(String, Int, String, Int, Int)] = [
            ("US", 0, "Artist A", 31, 4200), ("GB", 3, "Artist B", 22, 2300), ("CA", 9, "Artist C", 9, 800), ("IE", 14, "Artist D", 4, 640), ("SE", 30, "Artist E", 6, 410),
            ("AU", 55, "Artist F", 5, 300), ("DE", 80, "Artist G", 4, 180), ("JP", 120, "Artist H", 3, 150), ("NZ", 160, "Artist I", 3, 220), ("IS", 240, "Artist J", 2, 140),
            ("FR", 300, "Artist K", 2, 60), ("BR", 400, "Artist L", 1, 20),
        ]
        let start = Date(timeIntervalSince1970: 1_450_000_000)
        let stamps = rows.map { code, day, artist, artists, plays in
            CountryPassportResult.Stamp(code: code, name: CountryNames.name(forCode: code) ?? code, firstHeard: start.addingTimeInterval(Double(day) * 30 * 86_400), firstArtist: artist, artists: artists, plays: plays)
        }
        let steps = CountryPassportResult.ladder.filter { $0 <= stamps.count }.map { CountryPassportResult.Step(count: $0, reachedAt: stamps[$0 - 1].firstHeard, country: stamps[$0 - 1].name) }
        return CountryPassportResult(stamps: stamps, steps: steps, unknownArtists: 140, knownArtists: 92)
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
