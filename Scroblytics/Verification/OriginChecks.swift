import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_ORIGIN_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): where artists are from. Matching an artist to a
/// MusicBrainz artist, walking a city up to its state and country, the person's edits winning over the lookup, what is saved and what is
/// never saved (a failed lookup), how often MusicBrainz is asked, and that edits survive a backup. All on made-up artists and places
/// through a stand-in for MusicBrainz, so nothing leaves this Mac. Exits 0 on success.
///
/// `SCROBLYTICS_ORIGIN_DUMP=<count>` (scratch store copy only) looks up the top artists of that copy on the real MusicBrainz, read-only,
/// and prints what came back, one line per artist, so it can be compared with an independent reading.
enum OriginChecks {
    /// MusicBrainz as a table: artists by the name searched, artists by id, areas by id. Counts what it is asked.
    final class Stub: OriginFetching, @unchecked Sendable {
        private let lock = NSLock()
        var byName: [String: [ArtistOriginCandidate]] = [:]
        var byID: [String: ArtistOriginCandidate] = [:]
        var areas: [String: MBAreaInfo] = [:]
        var failure: Error?
        /// Names whose search always answers 503, and how long each search takes (so a check can act while one is in flight).
        var failingNames: Set<String> = []
        var delay: Duration = .zero
        private var searched: [String] = []
        private var searchCount = 0
        private var artistFetchCount = 0
        private var areaFetched: [String] = []

        var searches: Int { lock.withLock { searchCount } }
        var searchOrder: [String] { lock.withLock { searched } }
        var artistFetches: Int { lock.withLock { artistFetchCount } }
        var areaRequests: [String] { lock.withLock { areaFetched } }

        func searchArtists(name: String) async throws -> [ArtistOriginCandidate] {
            lock.withLock { searchCount += 1; searched.append(name) }
            if delay > .zero { try? await Task.sleep(for: delay) }
            if let failure { throw failure }
            if failingNames.contains(name) { throw MusicBrainzAPIError.http(503) }
            return byName[name] ?? []
        }

        func fetchArtist(id: String) async throws -> ArtistOriginCandidate? {
            lock.withLock { artistFetchCount += 1 }
            if let failure { throw failure }
            return byID[id]
        }

        func fetchArea(id: String) async throws -> MBAreaInfo? {
            lock.withLock { areaFetched.append(id) }
            if let failure { throw failure }
            return areas[id]
        }
    }

    private static func candidate(_ id: String, _ name: String, score: Int = 100, type: String? = "Group", begin: String? = "city-a", area: String? = nil, disambiguation: String? = nil) -> ArtistOriginCandidate {
        ArtistOriginCandidate(id: id, name: name, score: score, type: type, disambiguation: disambiguation, areaID: area, areaName: nil, beginAreaID: begin, beginAreaName: nil)
    }

    /// City A → County A → State A → Country (US); City B → Region B → Nation B → Country (GB); a city directly under its country;
    /// a state with no city; an area with no known parent.
    private static func stubAreas() -> [String: MBAreaInfo] {
        func area(_ id: String, _ name: String, _ type: String?, parent: String?, iso1: String? = nil, iso2: String? = nil) -> MBAreaInfo {
            MBAreaInfo(id: id, name: name, type: type, iso31661: iso1, iso31662: iso2, parentID: parent)
        }
        return [
            "city-a": area("city-a", "City A", "City", parent: "county-a"),
            "county-a": area("county-a", "County A", "County", parent: "state-a"),
            "state-a": area("state-a", "State A", "Subdivision", parent: "country-us", iso2: "US-AA"),
            "country-us": area("country-us", "United States of America", "Country", parent: nil, iso1: "US"),
            "city-b": area("city-b", "City B", "City", parent: "region-b", iso2: "GB-BBB"),
            "region-b": area("region-b", "Region B", "Subdivision", parent: "nation-b", iso2: "GB-RRR"),
            "nation-b": area("nation-b", "Nation B", "Subdivision", parent: "country-gb", iso2: "GB-NNN"),
            "country-gb": area("country-gb", "United Kingdom", "Country", parent: nil, iso1: "GB"),
            "city-c": area("city-c", "City C", "City", parent: "country-nz", iso2: "NZ-CCC"),
            "country-nz": area("country-nz", "New Zealand", "Country", parent: nil, iso1: "NZ"),
            "state-only": area("state-only", "State Z", "Subdivision", parent: "country-us", iso2: "US-ZZ"),
            "lonely": area("lonely", "Place Q", "City", parent: nil),
            "loop-1": area("loop-1", "Loop One", "City", parent: "loop-2"),
            "loop-2": area("loop-2", "Loop Two", "County", parent: "loop-1"),
        ]
    }

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        if let count = env["SCROBLYTICS_ORIGIN_DUMP"].flatMap(Int.init) {
            Task { @MainActor in await dump(container: container, count: count) }
            return
        }
        guard env["SCROBLYTICS_ORIGIN_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            matcherChecks(check)
            await placeChecks(check)
            await lookupChecks(check)
            resolverChecks(check)
            parsingChecks(check)
            pacerChecks(check)
            await storeChecks(container: container, check)
            await sweepChecks(container: container, check)
            await backupChecks(container: container, check)
            HeadlessTask.finish(failures)
        }
    }

    // MARK: Matching

    @MainActor
    private static func matcherChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let one = ArtistOriginMatcher.choose(for: "Artist A", from: [candidate("1", "Artist A")])
        check("one exact artist is found", one.status == .found && one.chosen?.id == "1" && one.others.isEmpty)
        let folded = ArtistOriginMatcher.choose(for: "The Band Ä & Co.", from: [candidate("1", "Band A and Co")])
        check("case, accents, 'The', '&' and punctuation do not stop a match", folded.status == .found, "\(folded.status)")
        check("a different name is not matched, however high it scores", ArtistOriginMatcher.choose(for: "Artist A", from: [candidate("1", "Artist AB", score: 100)]).status == ArtistOriginStatus.none)
        check("a name match below the minimum score is not used", ArtistOriginMatcher.choose(for: "Artist A", from: [candidate("1", "Artist A", score: 89)]).status == ArtistOriginStatus.none)
        check("a name match at the minimum score is used", ArtistOriginMatcher.choose(for: "Artist A", from: [candidate("1", "Artist A", score: 90)]).status == .found)
        check("no candidates is a miss", ArtistOriginMatcher.choose(for: "Artist A", from: []).status == ArtistOriginStatus.none)
        let close = ArtistOriginMatcher.choose(for: "Artist A", from: [candidate("2", "Artist A", score: 97), candidate("1", "Artist A", score: 100)])
        check("two close namesakes: the best is used but flagged as a guess, with the other kept", close.status == .guess && close.chosen?.id == "1" && close.others.map(\.id) == ["2"])
        let clear = ArtistOriginMatcher.choose(for: "Artist A", from: [candidate("1", "Artist A", score: 100), candidate("2", "Artist A", score: 90)])
        check("a namesake 10 points behind does not make it a guess", clear.status == .found && clear.chosen?.id == "1" && clear.others.isEmpty)
        let mixed = ArtistOriginMatcher.choose(for: "Artist A", from: [candidate("9", "Artist AB", score: 100), candidate("1", "Artist A", score: 99)])
        check("a better-scoring different name never counts as a namesake", mixed.status == .found && mixed.chosen?.id == "1")
        check("a person is born, a group formed, anything else is 'from'",
              ArtistOriginKind(musicBrainzType: "Person").label == "Born in" && ArtistOriginKind(musicBrainzType: "Group").label == "Formed in"
                && ArtistOriginKind(musicBrainzType: "Orchestra").label == "Formed in" && ArtistOriginKind(musicBrainzType: nil).label == "From"
                && ArtistOriginKind(musicBrainzType: "Character").label == "From")
    }

    // MARK: Walking a place up

    @MainActor
    private static func placeChecks(_ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let areas = stubAreas()
        func walk(_ id: String) async -> OriginPlace? {
            guard let start = areas[id] else { return nil }
            return try? await OriginPlaceWalker.place(from: start, area: { areas[$0] })
        }
        let us = await walk("city-a")
        check("a city is walked up through its county to the state and country", us == OriginPlace(city: "City A", region: "State A", country: "United States", countryCode: "US"), "\(String(describing: us))")
        check("…and reads as 'City A, State A, United States'", us?.text == "City A, State A, United States")
        let gb = await walk("city-b")
        check("the region is the highest subdivision below the country, not the county", gb == OriginPlace(city: "City B", region: "Nation B", country: "United Kingdom", countryCode: "GB"), "\(String(describing: gb))")
        let nz = await walk("city-c")
        check("a city directly under its country has no region", nz == OriginPlace(city: "City C", region: nil, country: "New Zealand", countryCode: "NZ"), "\(String(describing: nz))")
        check("…and reads without a gap", nz?.text == "City C, New Zealand")
        let state = await walk("state-only")
        check("a state with no city gives its region and country", state == OriginPlace(city: nil, region: "State Z", country: "United States", countryCode: "US"), "\(String(describing: state))")
        let country = await walk("country-gb")
        check("a country alone gives only the country", country == OriginPlace(city: nil, region: nil, country: "United Kingdom", countryCode: "GB"), "\(String(describing: country))")
        let lonely = await walk("lonely")
        check("an area with no known parent gives just the city", lonely == OriginPlace(city: "Place Q", region: nil, country: nil, countryCode: nil), "\(String(describing: lonely))")
        let loop = await walk("loop-1")
        check("a loop in the data ends instead of spinning", loop != nil)
        let missingParent = try? await OriginPlaceWalker.place(from: areas["city-a"]!, area: { $0 == "county-a" ? nil : areas[$0] })
        check("a parent MusicBrainz no longer has stops the walk with what is known", missingParent == OriginPlace(city: "City A", region: nil, country: nil, countryCode: nil), "\(String(describing: missingParent))")
        var thrown = false
        do { _ = try await OriginPlaceWalker.place(from: areas["city-a"]!, area: { _ in throw MusicBrainzAPIError.http(503) }) } catch { thrown = true }
        check("a failed fetch while walking throws instead of giving a partial place", thrown)
        check("a place with the same city and region names does not repeat itself", OriginPlace(city: "City A", region: "City A", country: "Country X").text == "City A, Country X")
        check("a country's name comes from its code, always in English", OriginPlaceWalker.countryName(forCode: "DE") == "Germany")
    }

    // MARK: A whole lookup

    @MainActor
    private static func lookupChecks(_ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let areas = MemoryAreas()
        let stub = Stub()
        stub.areas = stubAreas()
        stub.byName["Artist A"] = [candidate("a1", "Artist A", type: "Group", begin: "city-a")]
        stub.byName["Artist B"] = [candidate("b1", "Artist B", type: "Person", begin: "city-b")]
        stub.byName["Artist C"] = [candidate("c1", "Artist C", score: 98, begin: "city-a"), candidate("c2", "Artist C", score: 97, type: "Person", begin: "city-b")]
        stub.byName["Artist E"] = [candidate("e1", "Artist E", type: "Person", begin: nil, area: "country-gb")]
        stub.byName["Artist F"] = [candidate("f1", "Artist F", begin: nil, area: nil)]
        stub.byID["c2"] = candidate("c2", "Artist C", score: 100, type: "Person", begin: "city-b")

        let a = try? await ArtistOriginLookup.resolve(artist: "Artist A", chosenMBID: nil, fetcher: stub, areas: areas)
        check("a clear match gives found, its place and 'Formed in'", a?.status == .found && a?.place.text == "City A, State A, United States" && a?.kind?.label == "Formed in" && a?.mbid == "a1" && a?.candidates.isEmpty == true, "\(String(describing: a))")
        let b = try? await ArtistOriginLookup.resolve(artist: "Artist B", chosenMBID: nil, fetcher: stub, areas: areas)
        check("a person gives 'Born in'", b?.kind?.label == "Born in" && b?.place.text == "City B, Nation B, United Kingdom", "\(String(describing: b))")
        let c = try? await ArtistOriginLookup.resolve(artist: "Artist C", chosenMBID: nil, fetcher: stub, areas: areas)
        check("namesakes give a guess that keeps every candidate for review", c?.status == .guess && c?.mbid == "c1" && c?.candidates.map(\.id) == ["c1", "c2"], "\(String(describing: c))")
        let searchesBefore = stub.searches
        let picked = try? await ArtistOriginLookup.resolve(artist: "Artist C", chosenMBID: "c2", fetcher: stub, areas: areas)
        check("a picked artist is fetched by id with no name search, and is found", stub.searches == searchesBefore && picked?.status == .found && picked?.mbid == "c2" && picked?.place.text == "City B, Nation B, United Kingdom", "\(String(describing: picked))")
        let gone = try? await ArtistOriginLookup.resolve(artist: "Artist A", chosenMBID: "no-such", fetcher: stub, areas: areas)
        check("a picked artist MusicBrainz no longer has falls back to the name search", gone?.status == .found && gone?.mbid == "a1")
        let e = try? await ArtistOriginLookup.resolve(artist: "Artist E", chosenMBID: nil, fetcher: stub, areas: areas)
        check("an artist with only a wider area gives that area (a country here)", e?.place == OriginPlace(city: nil, region: nil, country: "United Kingdom", countryCode: "GB"), "\(String(describing: e?.place))")
        let f = try? await ArtistOriginLookup.resolve(artist: "Artist F", chosenMBID: nil, fetcher: stub, areas: areas)
        check("an artist with no area at all is found, with an empty place", f?.status == .found && f?.place.isEmpty == true)
        let none = try? await ArtistOriginLookup.resolve(artist: "Artist Z", chosenMBID: nil, fetcher: stub, areas: areas)
        check("an artist MusicBrainz does not know is a miss", none?.status == ArtistOriginStatus.none && none?.mbid == nil && none?.place.isEmpty == true)

        // A parent shared by two artists is fetched once.
        let fresh = Stub()
        fresh.areas = stubAreas()
        fresh.byName["Artist A"] = stub.byName["Artist A"]
        fresh.byName["Artist D"] = [candidate("d1", "Artist D", type: "Person", begin: "city-a")]
        let freshAreas = MemoryAreas()
        _ = try? await ArtistOriginLookup.resolve(artist: "Artist A", chosenMBID: nil, fetcher: fresh, areas: freshAreas)
        let afterFirst = fresh.areaRequests.count
        _ = try? await ArtistOriginLookup.resolve(artist: "Artist D", chosenMBID: nil, fetcher: fresh, areas: freshAreas)
        check("the first artist walks the whole chain (4 areas)", afterFirst == 4, "\(afterFirst)")
        check("a second artist from the same city asks for no area again", fresh.areaRequests.count == 4, "\(fresh.areaRequests.count)")

        // Failures are errors, never answers.
        let failing = Stub()
        failing.failure = MusicBrainzAPIError.http(503)
        var threw = false
        do { _ = try await ArtistOriginLookup.resolve(artist: "Artist A", chosenMBID: nil, fetcher: failing, areas: MemoryAreas()) } catch { threw = true }
        check("a 503 throws instead of being read as 'no such artist'", threw)
        let flaky = Stub()
        flaky.byName["Artist A"] = stub.byName["Artist A"]
        flaky.areas = [:]
        let flakyAreas = MemoryAreas()
        let unknownArea = try? await ArtistOriginLookup.resolve(artist: "Artist A", chosenMBID: nil, fetcher: flaky, areas: flakyAreas)
        check("an area MusicBrainz does not have gives an empty place, not a failure", unknownArea?.status == .found && unknownArea?.place.isEmpty == true)
    }

    /// Areas kept in memory, standing in for the saved area table.
    private actor MemoryAreas: OriginAreaProviding {
        private var store: [String: MBAreaInfo] = [:]
        func cached(_ id: String) async -> MBAreaInfo? { store[id] }
        func save(_ area: MBAreaInfo) async { store[area.id] = area }
    }

    // MARK: What is shown, and when to ask again

    @MainActor
    private static func resolverChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ status: ArtistOriginStatus, mbid: String? = "m1", city: String? = "City A", ageDays: Double = 1, kind: ArtistOriginKind? = .group) -> OriginEntrySnapshot {
            OriginEntrySnapshot(status: status, mbid: mbid, matchedName: "Artist A", kind: kind, place: OriginPlace(city: city, region: "State A", country: "United States", countryCode: "US"), candidates: [], resolvedAt: now.addingTimeInterval(-ageDays * 86_400))
        }
        let own = OriginPlace(city: "My City", region: nil, country: "My Country", countryCode: nil)

        check("nothing saved yet is 'pending'", ArtistOriginResolver.display(entry: nil, edit: nil).state == .pending)
        check("a recorded miss is 'unknown'", ArtistOriginResolver.display(entry: entry(.none), edit: nil).state == .unknown)
        let found = ArtistOriginResolver.display(entry: entry(.found), edit: nil)
        check("a found place is shown as looked up, with its label", found.state == .known && !found.corrected && !found.needsReview && found.text == "City A, State A, United States" && found.label == "Formed in")
        let guess = ArtistOriginResolver.display(entry: entry(.guess), edit: nil)
        check("a guess is shown and flagged for review", guess.state == .known && guess.needsReview)
        check("'Looks right' stops the flag", !ArtistOriginResolver.display(entry: entry(.guess), edit: OriginEditSnapshot(place: nil, chosenMBID: nil, confirmed: true)).needsReview)
        let edited = ArtistOriginResolver.display(entry: entry(.found), edit: OriginEditSnapshot(place: own, chosenMBID: nil, confirmed: false))
        check("the person's own place wins and is marked corrected", edited.corrected && edited.text == "My City, My Country" && !edited.needsReview)
        check("…even over a guess (no flag left)", !ArtistOriginResolver.display(entry: entry(.guess), edit: OriginEditSnapshot(place: own, chosenMBID: nil, confirmed: false)).needsReview)
        let editedMiss = ArtistOriginResolver.display(entry: entry(.none, kind: nil), edit: OriginEditSnapshot(place: own, chosenMBID: nil, confirmed: false))
        check("a place entered for an artist MusicBrainz lacks is shown, labelled 'From'", editedMiss.state == .known && editedMiss.label == "From")
        let editedBeforeLookup = ArtistOriginResolver.display(entry: nil, edit: OriginEditSnapshot(place: own, chosenMBID: nil, confirmed: false))
        check("a place entered before any lookup is shown, not pending", editedBeforeLookup.state == .known && editedBeforeLookup.corrected)
        check("an edit with no place (only a picked artist) changes nothing shown", ArtistOriginResolver.display(entry: entry(.found), edit: OriginEditSnapshot(place: nil, chosenMBID: "m1", confirmed: false)).corrected == false)

        check("nothing saved is looked up", ArtistOriginResolver.needsLookup(entry: nil, edit: nil, now: now))
        check("a fresh found answer is not looked up again", !ArtistOriginResolver.needsLookup(entry: entry(.found), edit: nil, now: now))
        check("a found answer is asked again after a year", ArtistOriginResolver.needsLookup(entry: entry(.found, ageDays: 366), edit: nil, now: now) && !ArtistOriginResolver.needsLookup(entry: entry(.found, ageDays: 364), edit: nil, now: now))
        check("a miss is asked again after 90 days", ArtistOriginResolver.needsLookup(entry: entry(.none, ageDays: 91), edit: nil, now: now) && !ArtistOriginResolver.needsLookup(entry: entry(.none, ageDays: 89), edit: nil, now: now))
        check("a different artist picked since the lookup is looked up now", ArtistOriginResolver.needsLookup(entry: entry(.guess, mbid: "m1"), edit: OriginEditSnapshot(place: nil, chosenMBID: "m2", confirmed: true), now: now))
        check("…but not when the pick is the one already saved", !ArtistOriginResolver.needsLookup(entry: entry(.guess, mbid: "m1"), edit: OriginEditSnapshot(place: nil, chosenMBID: "m1", confirmed: true), now: now))
    }

    // MARK: Reading MusicBrainz's answers

    @MainActor
    private static func parsingChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let search = Data(#"""
        {"count": 2, "artists": [
          {"id": "11111111-1111-1111-1111-111111111111", "name": "Artist A", "score": 100, "type": "Group", "disambiguation": "",
           "area": {"id": "22222222-2222-2222-2222-222222222222", "name": "Country X"},
           "begin-area": {"id": "33333333-3333-3333-3333-333333333333", "name": "City A"}},
          {"id": "44444444-4444-4444-4444-444444444444", "name": "Artist A", "score": 62, "disambiguation": "the other one"}
        ]}
        """#.utf8)
        let found = try? MusicBrainzOriginParsing.parseArtistSearch(search)
        check("an artist search is read: ids, score, type, areas", found?.count == 2 && found?[0].beginAreaName == "City A" && found?[0].beginAreaID == "33333333-3333-3333-3333-333333333333" && found?[0].areaName == "Country X" && found?[0].score == 100 && found?[0].type == "Group")
        check("an empty disambiguation is dropped and a missing area is nil", found?[0].disambiguation == nil && found?[1].disambiguation == "the other one" && found?[1].beginAreaID == nil && found?[1].areaID == nil)
        check("an answer with no artists list is an empty list", ((try? MusicBrainzOriginParsing.parseArtistSearch(Data("{}".utf8))) ?? [ArtistOriginCandidate(id: "x", name: "x", score: 0, type: nil, disambiguation: nil, areaID: nil, areaName: nil, beginAreaID: nil, beginAreaName: nil)]).isEmpty)
        var refused = false
        do { _ = try MusicBrainzOriginParsing.parseArtistSearch(Data("not json".utf8)) } catch { refused = true }
        check("an answer that isn't JSON is refused", refused)
        let area = Data(#"""
        {"id": "33333333-3333-3333-3333-333333333333", "name": "City A", "type": "City", "iso-3166-2-codes": ["XX-AA"],
         "relations": [
           {"type": "part of", "direction": "forward", "area": {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "name": "District Inside"}},
           {"type": "part of", "direction": "backward", "area": {"id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "name": "County A"}}
         ]}
        """#.utf8)
        let parsed = try? MusicBrainzOriginParsing.parseArea(area)
        check("an area is read with the area it is part of (not the areas inside it)", parsed?.name == "City A" && parsed?.type == "City" && parsed?.iso31662 == "XX-AA" && parsed?.parentID == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let country = try? MusicBrainzOriginParsing.parseArea(Data(#"{"id": "1", "name": "Country X", "type": "Country", "iso-3166-1-codes": ["US"]}"#.utf8))
        check("a country has its code and no parent", country?.iso31661 == "US" && country?.parentID == nil)
        check("only a real MusicBrainz id is ever put in a request", MusicBrainzAPIClient.isMBID("11111111-1111-1111-1111-111111111111") && !MusicBrainzAPIClient.isMBID("../../x") && !MusicBrainzAPIClient.isMBID("a1"))
        check("a quote in a name is escaped in the search", MusicBrainzAPIClient.escapeLucene("A\"B\\C") == "A\\\"B\\\\C")
    }

    // MARK: Pace

    @MainActor
    private static func pacerChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        var pacer = MusicBrainzPacer()
        check("the first request goes at once", pacer.reserve(now: 100, minimum: 2.5) == 0)
        check("the next waits out the gap", pacer.reserve(now: 100.5, minimum: 2.5) == 2.0)
        check("two requests asked at the same moment are spaced, not stacked", pacer.reserve(now: 100.5, minimum: 2.5) == 4.5)
        check("a request long after the last goes at once", pacer.reserve(now: 200, minimum: 2.5) == 0)
        check("a faster caller still waits for the slower caller's gap", abs(pacer.reserve(now: 200.1, minimum: 1.1) - 2.4) < 0.001)
        var throttled = MusicBrainzPacer()
        _ = throttled.reserve(now: 0, minimum: 1.1)
        throttled.noteThrottled(now: 1)
        check("after a 503 the next request waits 10 s", abs(throttled.reserve(now: 1, minimum: 1.1) - MusicBrainzPacer.throttledPause) < 0.001)
        check("and for two minutes the gap is at least 4 s, even for a caller that would use 1.1", abs(throttled.reserve(now: 11, minimum: 1.1) - 4.0) < 0.001)
        check("later it is back to the caller's own gap", { var p = throttled; _ = p.reserve(now: 200, minimum: 1.1); return abs(p.reserve(now: 200, minimum: 1.1) - 1.1) < 0.001 }())
    }

    // MARK: Saved lookups, edits and areas

    @MainActor
    private static func storeChecks(container: ModelContainer, _ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        cleanUp(container.mainContext)
        defer { cleanUp(container.mainContext) }
        let store = ArtistOriginDataStore(modelContainer: container)
        let place = OriginPlace(city: "City A", region: "State A", country: "United States", countryCode: "US")
        let found = ArtistOriginLookup.Outcome(status: .found, mbid: "m1", matchedName: "Artist A", kind: .group, place: place, candidates: [])
        let guess = ArtistOriginLookup.Outcome(status: .guess, mbid: "m2", matchedName: "Artist B", kind: .person, place: place, candidates: [candidate("m2", "Artist B"), candidate("m3", "Artist B", score: 95)])
        let miss = ArtistOriginLookup.Outcome(status: .none, mbid: nil, matchedName: nil, kind: nil, place: OriginPlace(), candidates: [])
        try? await store.save([("Artist A", found), ("ARTIST B ", guess), ("Artist Z", miss)])
        let saved = try? await store.snapshots(for: ["artist a", "Artist B", "Artist Z", "Artist Y"])
        check("saved answers are read back by artist, whatever the case or spacing", saved?["artist a"]?.entry?.place == place && saved?["artist b"]?.entry?.status == .guess && saved?["artist z"]?.entry?.status == ArtistOriginStatus.none)
        check("an artist never looked up has nothing saved", saved?["artist y"]?.entry == nil)
        check("a guess keeps its candidates", saved?["artist b"]?.entry?.candidates.map(\.id) == ["m2", "m3"])
        check("a found answer keeps its kind and artist id", saved?["artist a"]?.entry?.kind == .group && saved?["artist a"]?.entry?.mbid == "m1")
        try? await store.save([("Artist A", ArtistOriginLookup.Outcome(status: .found, mbid: "m1", matchedName: "Artist A", kind: .group, place: OriginPlace(city: "City B", region: nil, country: "United Kingdom", countryCode: "GB"), candidates: []))])
        let rows = (try? container.mainContext.fetch(FetchDescriptor<ArtistOriginEntry>())) ?? []
        check("a new answer replaces the old one (one row per artist)", rows.filter { $0.normalizedName == "artist a" }.count == 1 && rows.first { $0.normalizedName == "artist a" }?.cityName == "City B")

        // The person's decisions.
        try? await store.setPlace(OriginPlace(city: " My City ", region: "", country: "My Country", countryCode: "mc"), for: "Artist A")
        var all = try? await store.allSnapshots()
        check("a typed place is saved trimmed, blank parts left out, the code upper-cased", all?.edits["artist a"]?.place == OriginPlace(city: "My City", region: nil, country: "My Country", countryCode: "MC"), "\(String(describing: all?.edits["artist a"]))")
        check("the lookup is untouched by an edit", all?.entries["artist a"]?.place.city == "City B")
        try? await store.choose(mbid: "m9", for: "Artist A")
        try? await store.resetPlace(for: "Artist A")
        all = try? await store.allSnapshots()
        check("Reset to Detected removes the place and keeps the picked artist", all?.edits["artist a"]?.place == nil && all?.edits["artist a"]?.chosenMBID == "m9")
        try? await store.choose(mbid: nil, for: "Artist A")
        try? await store.confirm("Artist A", confirmed: false)
        all = try? await store.allSnapshots()
        check("with nothing left to decide, the edit row is removed", all?.edits["artist a"] == nil)
        try? await store.confirm("Artist B")
        all = try? await store.allSnapshots()
        check("'Looks right' is remembered", all?.edits["artist b"]?.confirmed == true && all?.edits["artist b"]?.place == nil)
        try? await store.setPlace(OriginPlace(), for: "Artist B")
        all = try? await store.allSnapshots()
        check("clearing a place that was never set changes nothing else", all?.edits["artist b"]?.confirmed == true)
        try? await store.choose(mbid: "m4", for: "Artist C")
        all = try? await store.allSnapshots()
        check("picking an artist counts as having reviewed the match", all?.edits["artist c"]?.chosenMBID == "m4" && all?.edits["artist c"]?.confirmed == true)

        // Areas.
        await store.save(MBAreaInfo(id: "area-1", name: "City A", type: "City", iso31661: nil, iso31662: nil, parentID: "area-2"))
        await store.save(MBAreaInfo(id: "area-1", name: "City A2", type: "City", iso31661: nil, iso31662: nil, parentID: "area-2"))
        let area = await store.cached("area-1")
        check("a saved area is read back, and saving it again replaces it", area?.name == "City A2" && area?.parentID == "area-2" && ((try? container.mainContext.fetch(FetchDescriptor<OriginAreaCacheEntry>())) ?? []).count == 1)
        check("an area never saved is not found", await store.cached("area-9") == nil)

        // Forgetting.
        try? await store.setPlace(OriginPlace(city: "My City", region: nil, country: nil, countryCode: nil), for: "Artist A")
        try? await store.forgetLookups()
        all = try? await store.allSnapshots()
        check("Forget removes every looked-up place and area", all?.entries.isEmpty == true && ((try? container.mainContext.fetch(FetchDescriptor<OriginAreaCacheEntry>())) ?? []).isEmpty)
        check("…and keeps the person's own edits", all?.edits["artist a"]?.place?.city == "My City" && all?.edits["artist b"]?.confirmed == true)
    }

    @MainActor
    private static func cleanUp(_ context: ModelContext) {
        for item in (try? context.fetch(FetchDescriptor<ArtistOriginEntry>())) ?? [] { context.delete(item) }
        for item in (try? context.fetch(FetchDescriptor<ArtistOriginEdit>())) ?? [] { context.delete(item) }
        for item in (try? context.fetch(FetchDescriptor<OriginAreaCacheEntry>())) ?? [] { context.delete(item) }
        try? context.save()
    }

    // MARK: The sweep

    @MainActor
    private static func sweepChecks(container: ModelContainer, _ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let context = container.mainContext
        func cleanUpAll() {
            cleanUp(context)
            for item in (try? context.fetch(FetchDescriptor<Scrobble>())) ?? [] { context.delete(item) }
            try? context.save()
        }
        cleanUpAll()
        await ScrobbleHistoryCache.shared.invalidate()
        defer { cleanUpAll(); Task { await ScrobbleHistoryCache.shared.invalidate() } }
        // Plays: A five times, B three (one under another spelling), C once; D and E once each.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = 0
        func play(_ artist: String) {
            clock += 1
            context.insert(Scrobble(artistName: artist, albumName: "Album", trackName: "Song \(clock)", imageURL: nil, playedAt: t0.addingTimeInterval(Double(clock) * 60), lastConfirmedAt: t0))
        }
        for _ in 0..<5 { play("Artist A") }
        for _ in 0..<2 { play("Artist B") }
        play("artist b")
        for name in ["Artist C", "Artist D", "Artist E"] { play(name) }
        try? context.save()
        await ScrobbleHistoryCache.shared.invalidate()

        let store = ArtistOriginDataStore(modelContainer: container)
        func stub(_ names: [String]) -> Stub {
            let s = Stub()
            s.areas = stubAreas()
            for (i, name) in names.enumerated() { s.byName[name] = [candidate("id-\(i)", name, type: "Group", begin: "city-a")] }
            return s
        }
        func waitUntilIdle(_ sweep: ArtistOriginStore) async {
            for _ in 0..<400 where sweep.isWarming || sweep.remaining > 0 { try? await Task.sleep(for: .milliseconds(25)) }
        }
        func freshDefaults() -> UserDefaults {
            let suite = "origin-check-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }
        let everyone = ["Artist A", "Artist B", "Artist C", "Artist D", "Artist E"]

        // Seeding: most played first, one entry per artist (case variants joined), nothing for an artist with a fresh answer.
        let seeded = (try? await ArtistOriginStore.seedTargets(container: container))?.map(\.name)
        check("every artist is queued, most played first", seeded.map { Array($0.prefix(2)) } == ["Artist A", "Artist B"] && Set(seeded ?? []) == Set(everyone), "\(String(describing: seeded))")
        try? await store.save([("Artist C", ArtistOriginLookup.Outcome(status: .found, mbid: "m", matchedName: "Artist C", kind: .group, place: OriginPlace(city: "City A", region: nil, country: nil, countryCode: nil), candidates: [])),
                               ("Artist D", ArtistOriginLookup.Outcome(status: .found, mbid: "m1", matchedName: "Artist D", kind: .group, place: OriginPlace(), candidates: []))])
        try? await store.choose(mbid: "m2", for: "Artist D")
        let reseeded = (try? await ArtistOriginStore.seedTargets(container: container)) ?? []
        check("an artist with a fresh answer is not queued again", !reseeded.map(\.name).contains("Artist C"))
        check("…but one the person has since picked a different artist for is, with that pick", reseeded.first { $0.name == "Artist D" }?.chosenMBID == "m2")
        let old = try? await ArtistOriginStore.seedTargets(container: container, now: Date().addingTimeInterval(400 * 86_400))
        check("every answer is asked again a year and more later", Set(old?.map(\.name) ?? []) == Set(everyone))
        cleanUp(context)

        // A whole sweep through a stand-in.
        let work = BackgroundWorkStore()
        let happy = stub(everyone)
        let sweep = ArtistOriginStore(defaults: freshDefaults())
        sweep.makeFetcher = { happy }
        await sweep.start(container: container, work: work, warm: true)
        await waitUntilIdle(sweep)
        check("the sweep looks every artist up, most played first", Array(happy.searchOrder.prefix(2)) == ["Artist A", "Artist B"] && Set(happy.searchOrder) == Set(everyone), "\(happy.searchOrder)")
        let after = try? await store.allSnapshots()
        check("each answer is saved, as found, with its place", everyone.allSatisfy { after?.entries[TextNormalization.artistIdentityKey($0)]?.place.text == "City A, State A, United States" })
        check("the count of artists looked up follows", sweep.knownCount == 5, "\(sweep.knownCount)")
        check("the status strip job is finished", !work.active.keys.contains(.origins) && work.failures[.origins] == nil)
        check("the status line says it is up to date", sweep.statusText.contains("5 artists looked up"), sweep.statusText)
        let requestsAfterFirst = happy.searches
        await sweep.start(container: container, work: work, warm: true)
        await waitUntilIdle(sweep)
        check("a second start with everything answered asks MusicBrainz for nothing", happy.searches == requestsAfterFirst)

        // A failing artist is retried, never recorded, and the rest carry on.
        cleanUp(context)
        let flaky = stub(everyone)
        flaky.failingNames = ["Artist B"]
        let failing = ArtistOriginStore(defaults: freshDefaults())
        failing.makeFetcher = { flaky }
        await failing.start(container: container, work: BackgroundWorkStore(), warm: true)
        await waitUntilIdle(failing)
        let failedSnap = try? await store.allSnapshots()
        check("an artist whose lookup keeps failing is tried \(ArtistOriginStore.maxAttempts) times", flaky.searchOrder.filter { $0 == "Artist B" }.count == ArtistOriginStore.maxAttempts)
        check("…is not recorded at all (so it is asked again next time)", failedSnap?.entries["artist b"] == nil)
        check("…is counted as failed", failing.failedThisRun == 1, "\(failing.failedThisRun)")
        check("…and the others are saved", ["artist a", "artist c", "artist d", "artist e"].allSatisfy { failedSnap?.entries[$0] != nil })

        // MusicBrainz down: the sweep stops instead of grinding through everything.
        cleanUp(context)
        for i in 0..<12 { play("Down \(i)") }
        try? context.save()
        await ScrobbleHistoryCache.shared.invalidate()
        let down = Stub()
        down.areas = stubAreas()
        down.failure = MusicBrainzAPIError.http(503)
        let stopping = ArtistOriginStore(defaults: freshDefaults())
        stopping.makeFetcher = { down }
        await stopping.start(container: container, work: BackgroundWorkStore(), warm: true)
        await waitUntilIdle(stopping)
        check("after \(ArtistOriginStore.failureStreakLimit) failures in a row the sweep stops", down.searches == ArtistOriginStore.failureStreakLimit * ArtistOriginStore.maxAttempts, "\(down.searches)")
        check("…says MusicBrainz isn't answering", stopping.lastError?.contains("isn’t answering") == true, "\(String(describing: stopping.lastError))")
        check("…and nothing was recorded", ((try? await store.allSnapshots())?.entries.isEmpty) == true)

        // Switch off, Offline mode.
        cleanUp(context)
        let quiet = stub(everyone)
        let off = ArtistOriginStore(defaults: freshDefaults())
        off.makeFetcher = { quiet }
        off.setEnabled(false)
        await off.start(container: container, work: BackgroundWorkStore(), warm: true)
        await waitUntilIdle(off)
        check("with the switch off nothing is looked up", quiet.searches == 0 && off.statusText.hasPrefix("Off"))
        let onlineBefore = ConnectivityGate.isOffline
        ConnectivityGate.set(offline: true)
        let paused = ArtistOriginStore(defaults: freshDefaults())
        paused.makeFetcher = { quiet }
        await paused.start(container: container, work: BackgroundWorkStore(), warm: true)
        await waitUntilIdle(paused)
        ConnectivityGate.set(offline: onlineBefore)
        check("in Offline mode nothing is looked up", quiet.searches == 0)

        // Prioritize: what a Query or a page waits on goes first.
        cleanUp(context)
        let slow = stub(everyone)
        slow.delay = .milliseconds(200)
        let ordered = ArtistOriginStore(defaults: freshDefaults())
        ordered.makeFetcher = { slow }
        await ordered.start(container: container, work: BackgroundWorkStore(), warm: true)
        await ordered.prioritize(["Artist E"], force: true)
        await waitUntilIdle(ordered)
        let order = slow.searchOrder
        check("an artist someone is waiting on is looked up before the rest", order.count >= 3 && order.firstIndex(of: "Artist E").map { $0 <= 1 } == true, "\(order)")
        check("…and is not looked up twice", order.filter { $0 == "Artist E" }.count == 1, "\(order)")
        let offered = ArtistOriginStore(defaults: freshDefaults())
        offered.makeFetcher = { quiet }
        offered.setEnabled(false)
        await offered.prioritize(["Artist A"], force: true)
        check("prioritize does nothing while the switch is off", quiet.searches == 0)
    }

    // MARK: Backup

    @MainActor
    private static func backupChecks(container: ModelContainer, _ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let context = container.mainContext
        cleanUp(context)
        defer { cleanUp(context) }
        let store = ArtistOriginDataStore(modelContainer: container)
        try? await store.save([("Artist A", ArtistOriginLookup.Outcome(status: .found, mbid: "m1", matchedName: "Artist A", kind: .group, place: OriginPlace(city: "Looked Up", region: nil, country: nil, countryCode: nil), candidates: []))])
        try? await store.setPlace(OriginPlace(city: "My City", region: "My Region", country: "My Country", countryCode: "MC"), for: "Artist A")
        try? await store.choose(mbid: "m7", for: "Artist A")
        try? await store.confirm("Artist B")

        guard let document = try? NativeBackupEngine.makeDocument(context: context), let (archive, summary) = try? NativeBackupEngine.inspect(document: document) else {
            check("a backup can be made and read back", false)
            return
        }
        let records = archive.artistOrigins ?? []
        check("a backup carries each person's decisions", records.count == 2 && records.first { $0.artist == "Artist A" }?.city == "My City" && records.first { $0.artist == "Artist A" }?.chosenMBID == "m7" && records.first { $0.artist == "Artist B" }?.confirmed == true)
        check("and says so in its summary", summary.description.contains("2 artist origin edits"), summary.description)
        check("but never the looked-up places", !String(decoding: document.data, as: UTF8.self).contains("Looked Up"))

        cleanUp(context)
        try? NativeBackupEngine.restoreArtistOrigins(archive.artistOrigins, context: context)
        let back = try? await store.allSnapshots()
        check("restoring brings the decisions back", back?.edits["artist a"]?.place?.text == "My City, My Region, My Country" && back?.edits["artist a"]?.place?.countryCode == "MC" && back?.edits["artist a"]?.chosenMBID == "m7" && back?.edits["artist b"]?.confirmed == true, "\(String(describing: back?.edits))")
        try? NativeBackupEngine.restoreArtistOrigins(nil, context: context)
        check("an older backup (no field) leaves them alone", ((try? context.fetch(FetchDescriptor<ArtistOriginEdit>())) ?? []).count == 2)
        try? NativeBackupEngine.restoreArtistOrigins([], context: context)
        check("a backup with none clears them", ((try? context.fetch(FetchDescriptor<ArtistOriginEdit>())) ?? []).isEmpty)
    }

    // MARK: Live, read-only dump

    /// Looks up the top `count` artists of this store copy on the real MusicBrainz and prints one line each. Needs a scratch store (a
    /// copy of a library) so what it saves never lands in the real database. Offline mode is lifted for this run only.
    @MainActor
    private static func dump(container: ModelContainer, count: Int) async {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_STORE_PATH"] != nil else {
            print("ORIGIN_DUMP refused: set SCROBLYTICS_STORE_PATH to a copy of a library")
            exit(2)
        }
        do {
            let snapshots = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            let top = ArtistMapScope.top(snapshots: snapshots, count: count).entries
            ConnectivityGate.set(offline: false)
            let store = ArtistOriginDataStore(modelContainer: container)
            let client = MusicBrainzAPIClient()
            let started = Date()
            var tally: [ArtistOriginStatus: Int] = [:]
            for entry in top {
                do {
                    let outcome = try await ArtistOriginLookup.resolve(artist: entry.name, chosenMBID: nil, fetcher: client, areas: store)
                    try await store.save([(entry.name, outcome)])
                    tally[outcome.status, default: 0] += 1
                    print("ORIGIN\t\(entry.name)\t\(entry.plays)\t\(outcome.status.rawValue)\t\(outcome.kind?.label ?? "-")\t\(outcome.place.text)\t\(outcome.matchedName ?? "-")\t\(outcome.mbid ?? "-")")
                } catch {
                    print("ORIGIN\t\(entry.name)\t\(entry.plays)\tFAILED\t\(error)")
                }
            }
            let areaRows = try container.mainContext.fetchCount(FetchDescriptor<OriginAreaCacheEntry>())
            print("ORIGIN_SUMMARY artists=\(top.count) found=\(tally[.found] ?? 0) guess=\(tally[.guess] ?? 0) none=\(tally[.none] ?? 0) areas=\(areaRows) seconds=\(Int(Date().timeIntervalSince(started)))")
            exit(0)
        } catch {
            print("ORIGIN_DUMP failed: \(error)")
            exit(1)
        }
    }
}
#endif
