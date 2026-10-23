import Foundation

#if DEBUG
/// `SCROBLYTICS_QUERYCAP_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the diversity caps ("at most N per
/// artist / album / release year") on made-up data, and Ask's reading of them. No network and no model: the Ask part hands
/// `AskModelEngine.read` canned replies. Exits 0 on success, 1 on failure.
enum QueryCapChecks {
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_QUERYCAP_CHECK"] != nil else { return }
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
            if !ok { failures += 1 }
        }
        breakdownChecks(check)
        engineChecks(check)
        modelChecks(check)
        askChecks(check)
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Made-up library

    /// artist, album, album's release year ("none" = looked up, no date; nil = not looked up yet), tracks with their play counts.
    private struct Album {
        let artist: String
        let name: String
        let year: String?
        let looked: Bool
        let tracks: [(String, Int)]
    }

    private static let library: [Album] = [
        Album(artist: "Artist A", name: "A One", year: "1990", looked: true, tracks: [("a1 x", 10), ("a1 y", 9)]),
        Album(artist: "Artist A", name: "A Two", year: "1990", looked: true, tracks: [("a2 x", 8), ("a2 y", 7)]),
        Album(artist: "Artist A", name: "A Three", year: "1995", looked: true, tracks: [("a3 x", 6), ("a3 y", 5)]),
        Album(artist: "Artist B", name: "B One", year: "1995", looked: true, tracks: [("b1 x", 4), ("b1 y", 3)]),
        Album(artist: "Artist B", name: "B Two", year: nil, looked: true, tracks: [("b2 x", 2), ("b2 y", 1)]),       // no date found
        Album(artist: "Artist B", name: "B Three", year: nil, looked: false, tracks: [("b3 x", 20)]),               // not looked up yet
    ]

    private static func scrobbles() -> [ScrobbleSnapshot] {
        var out: [ScrobbleSnapshot] = []
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        for album in library {
            for (track, plays) in album.tracks {
                for _ in 0..<plays {
                    out.append(ScrobbleSnapshot(artistName: album.artist, albumName: album.name, trackName: track, imageURL: nil, playedAt: t))
                    t = t.addingTimeInterval(60)
                }
            }
        }
        return out
    }

    private static func snapshots() -> QuerySnapshots {
        var releases = ReleaseDateEngine.Snapshot()
        for album in library where album.looked {
            let info = ReleaseDateEngine.Snapshot.AlbumInfo(
                artistKey: TextNormalization.artistIdentityKey(album.artist), override: nil, detected: album.year, resolved: true
            )
            releases.albumsByIdentityKey[TextNormalization.albumIdentityKey(artist: album.artist, album: album.name)] = info
            releases.albumsByNormalizedTitle[TextNormalization.normalizeAlbumName(album.name), default: []].append(info)
        }
        var snapshots = QuerySnapshots()
        snapshots.releaseDates = releases
        return snapshots
    }

    private static func run(_ spec: QuerySpec) throws -> QueryResult {
        let validated = try spec.validate(against: .standard)
        let all = scrobbles()
        let run = QueryRun(target: spec.target, asOf: Date(timeIntervalSince1970: 1_700_100_000), scrobbles: all, allTimeScrobbles: all, snapshots: snapshots())
        return QueryEngine.evaluate(validated, run: run)
    }

    /// `rankOrder`: show the results in the order the sorts picked them (the checks of what the caps keep read them that way). False is the
    /// automatic display order, by release year where a per-release-year cap is set.
    private static func spec(_ target: QueryTarget, caps: QueryGroupLimit?, limit: Int? = nil, rankOrder: Bool = true) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
        spec.columns = [QueryFieldRef("plays")]
        spec.groupLimit = caps
        spec.limit = limit
        if rankOrder { spec.showInRankOrder = true }
        return spec
    }

    // MARK: - Break down by calendar year

    /// Plays per (artist, calendar year), the way the checks below work their answers out by hand.
    private static let yearlyPlays: [(artist: String, year: Int, plays: Int)] = [
        ("A", 2019, 5), ("A", 2020, 2), ("A", 2021, 6),
        ("B", 2019, 3), ("B", 2020, 9), ("B", 2021, 6), ("B", 2022, 4),
        ("C", 2020, 4), ("C", 2021, 1), ("C", 2022, 4),
    ]

    private static func yearlyScrobbles() -> [ScrobbleSnapshot] {
        let calendar = AppCalendars.listening
        var out: [ScrobbleSnapshot] = []
        for entry in yearlyPlays {
            let base = calendar.date(from: DateComponents(year: entry.year, month: 6, day: 15, hour: 12))!
            for i in 0..<entry.plays {
                out.append(ScrobbleSnapshot(artistName: entry.artist, albumName: "Album \(entry.artist)", trackName: "Track \(entry.artist)", imageURL: nil, playedAt: base.addingTimeInterval(Double(i) * 600)))
            }
        }
        return out.sorted { $0.playedAt < $1.playedAt }
    }

    private static func runYearly(_ spec: QuerySpec) throws -> QueryResult {
        let validated = try spec.validate(against: .standard)
        let all = yearlyScrobbles()
        let run = QueryRun(target: spec.target, asOf: Date(timeIntervalSince1970: 1_800_000_000), scrobbles: spec.countedPlays(all), allTimeScrobbles: all, snapshots: QuerySnapshots())
        return QueryEngine.evaluate(validated, run: run)
    }

    private static func breakdownChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func spec(_ target: QueryTarget = .artist, limit: Int?, newestFirst: Bool? = nil) -> QuerySpec {
            var spec = QuerySpec(target: target)
            spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
            spec.columns = [QueryFieldRef("plays")]
            spec.limit = limit
            spec.breakdown = QueryBreakdown(newestFirst: newestFirst)
            return spec
        }
        // Independent answer: per year, the artists by plays (descending), ties by name, the first `n`.
        func expected(_ n: Int, newestFirst: Bool = false, minimum: Int = 0) -> [String] {
            let years = Set(yearlyPlays.map(\.year)).sorted(by: newestFirst ? (>) : (<))
            return years.flatMap { year in
                yearlyPlays.filter { $0.year == year && $0.plays >= minimum }
                    .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.artist < $1.artist }
                    .prefix(n).map { "\(year) \($0.artist) \($0.plays)" }
            }
        }
        func shown(_ result: QueryResult) -> [String] {
            let key = result.columns.first?.cacheKey ?? ""
            return result.rows.map { row in
                var plays = -1
                if case .value(.number(let n))? = row.cells[key] { plays = Int(n) }
                return "\(row.period.map(String.init) ?? "-") \(row.entity.name) \(plays)"
            }
        }
        do {
            let one = try runYearly(spec(limit: 1))
            check("the top artist of each year, with that year's own plays", shown(one) == expected(1), "\(shown(one)) vs \(expected(1))")
            let two = try runYearly(spec(limit: 2))
            check("the top two of each year (a year with fewer than two artists keeps what it has)", shown(two) == expected(2), "\(shown(two)) vs \(expected(2))")
            let newest = try runYearly(spec(limit: 1, newestFirst: true))
            check("newest year first when asked", shown(newest) == expected(1, newestFirst: true), "\(shown(newest))")
            check("a year's tie goes to the name that sorts first, as everywhere else", shown(one).contains("2021 A 6") && shown(one).contains("2022 B 4"))
            check("every year of the plays appears, oldest first by default", one.rows.compactMap(\.period) == [2019, 2020, 2021, 2022])
            check("the matched count adds up the years' (2 + 3 + 3 + 2 artists)", try runYearly(spec(limit: nil)).matchedCount == 10 && one.matchedCount == 10, "\(one.matchedCount)")

            var conditioned = spec(limit: 5)
            conditioned.groups = [[QueryCondition("plays", .greaterThanOrEqual, [.number(4)])]]
            check("a condition is tested against each year's plays, not the total", shown(try runYearly(conditioned)) == expected(5, minimum: 4), "\(shown(try runYearly(conditioned))) vs \(expected(5, minimum: 4))")

            let displayRows = QueryDisplayRow.make(from: try runYearly(spec(limit: 2)), imageLookup: [:])
            check("the same artist in several years is several rows with their own identities", Set(displayRows.map(\.id)).count == displayRows.count && Set(displayRows.map(\.entityID)).count < displayRows.count)

            var windowed = spec(limit: 1)
            windowed.period = QueryPeriod(from: AppCalendars.listening.date(from: DateComponents(year: 2020, month: 1, day: 1))!, to: AppCalendars.listening.date(from: DateComponents(year: 2021, month: 12, day: 31, hour: 23))!)
            check("with a period chosen, only its years are broken down", try runYearly(windowed).rows.compactMap(\.period) == [2020, 2021])

            var plain = spec(limit: 1)
            plain.breakdown = nil
            let plainResult = try runYearly(plain)
            check("without a breakdown nothing changes: one list over all the plays, no years", plainResult.rows.count == 1 && plainResult.rows[0].period == nil && shown(plainResult) == ["- B 22"], "\(shown(plainResult))")

            let albums = try runYearly(spec(.album, limit: 1))
            let tracks = try runYearly(spec(.track, limit: 1))
            check("albums and tracks break down the same way", albums.rows.compactMap(\.period) == [2019, 2020, 2021, 2022] && tracks.rows.map(\.entity.name) == ["Track A", "Track B", "Track A", "Track B"], "\(tracks.rows.map(\.entity.name))")
        } catch {
            check("the engine runs a query broken down by year", false, "\(error)")
        }
        let breakdown = QueryBreakdown(newestFirst: true)
        check("a breakdown survives saving, and an older query has none", {
            var s = QuerySpec(target: .artist); s.breakdown = breakdown
            let back = try? QuerySpec.decode(s.encoded())
            let older = try? QuerySpec.decode(Data(#"{"schemaVersion":4,"target":"artist","groups":[],"sorts":[],"columns":[]}"#.utf8))
            return back?.breakdown == breakdown && older?.breakdown == nil
        }())
        let switched = QueryBuilderModel.switching({ var s = QuerySpec(target: .album); s.breakdown = QueryBreakdown(); return s }(), to: .artist, registry: .standard)
        check("switching target keeps the breakdown", switched.spec.breakdown != nil)

        // Ask
        func read(_ request: String, limit: String = "null", target: String = "artist", unsupported: String = "[]") -> AskTranslation? {
            try? AskModelEngine.read(reply(target: target, sorts: playsDescending, limit: limit, unsupported: unsupported), request: request, registry: .standard, context: .none, now: Date(), engine: "test", seconds: 0)
        }
        let top3 = read("my top 3 artists of each year", limit: "3")
        check("“my top 3 artists of each year” runs once per year, 3 each", top3?.interpretation.spec.breakdown != nil && top3?.interpretation.spec.limit == 3)
        let one = read("my top album each year", limit: "null", target: "album")
        check("“my top album each year” with no number from the model means one per year", one?.interpretation.spec.breakdown != nil && one?.interpretation.spec.limit == 1, "\(String(describing: one?.interpretation.spec.limit))")
        let named = read("my top 5 tracks per year", limit: "null", target: "track")
        check("a count in the request is used when the model left it out", named?.interpretation.spec.limit == 5, "\(String(describing: named?.interpretation.spec.limit))")
        let newestFirst = read("top artist every year, newest first", limit: "1")
        check("“newest first” flips the years", newestFirst?.interpretation.spec.breakdown?.showsNewestFirst == true)
        let chips = top3.map { AskChips.describe($0.interpretation.spec, registry: .standard).map(\.text) } ?? []
        check("the chips say it: for each calendar year, top 3 per year", chips.contains("For each calendar year") && chips.contains("Top 3 per year"), "\(chips)")
        let releaseYear = read("my most played album from each release year", limit: "null", target: "album")
        check("“each release year” is the cap, not a breakdown", releaseYear?.interpretation.spec.breakdown == nil)
        check("the wordings", ["top artist each year", "most played song every year", "my top albums per year", "best track for each year", "top 10 artists by year", "year by year"].allSatisfy { AskPatterns.breakdownByYear(in: $0) } && !["my top albums", "albums by release year", "top album by release year", "plays this year", "songs from last year"].contains { AskPatterns.breakdownByYear(in: $0) })
        let noted = read("my top artist of each year", limit: "1", unsupported: #"["grouping results by each year isn't supported"]"#)
        check("a model's note that per-year isn't supported is removed, since the app does it", noted?.interpretation.unsupported.isEmpty == true && noted?.interpretation.spec.breakdown != nil, "\(String(describing: noted?.interpretation.unsupported))")
    }

    // MARK: - Engine

    private static func engineChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        // The sorted list the caps act on, worked out by hand from the library above (plays, descending).
        struct Row { let artist: String, album: String, track: String, year: String?, plays: Int }
        let rows: [Row] = library.flatMap { album in album.tracks.map { Row(artist: album.artist, album: album.name, track: $0.0, year: album.looked ? album.year : nil, plays: $0.1) } }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.track < $1.track }

        // Independent answer: walk the sorted list, counting per year / album / artist, skipping a row once a cap is full.
        func expected(perArtist: Int? = nil, perAlbum: Int? = nil, perYear: Int? = nil) -> [String] {
            var artists: [String: Int] = [:], albums: [String: Int] = [:], years: [String: Int] = [:]
            var kept: [String] = []
            for row in rows {
                if let perArtist, artists[row.artist, default: 0] >= perArtist { continue }
                if let perAlbum, albums[row.album, default: 0] >= perAlbum { continue }
                if let perYear, let year = row.year, years[year, default: 0] >= perYear { continue }
                artists[row.artist, default: 0] += 1; albums[row.album, default: 0] += 1
                if let year = row.year { years[year, default: 0] += 1 }
                kept.append(row.track)
            }
            return kept
        }
        func names(_ result: QueryResult) -> [String] { result.rows.map(\.entity.name) }

        do {
            let one = try run(spec(.track, caps: QueryGroupLimit(perReleaseYear: 1)))
            check("tracks, 1 per release year, match the hand-worked answer", names(one) == expected(perYear: 1), "\(names(one)) vs \(expected(perYear: 1))")
            check("…and that answer keeps one track per dated year plus every track with no known year",
                  names(one) == ["b3 x", "a1 x", "a3 x", "b2 x", "b2 y"], "\(names(one))")
            let two = try run(spec(.track, caps: QueryGroupLimit(perReleaseYear: 2)))
            check("tracks, 2 per release year", names(two) == expected(perYear: 2), "\(names(two))")
            let all = try run(spec(.track, caps: QueryGroupLimit(perArtist: 3, perAlbum: 1, perReleaseYear: 2)))
            check("all three caps together match the hand-worked answer", names(all) == expected(perArtist: 3, perAlbum: 1, perYear: 2), "\(names(all)) vs \(expected(perArtist: 3, perAlbum: 1, perYear: 2))")
            let limited = try run(spec(.track, caps: QueryGroupLimit(perReleaseYear: 1), limit: 2))
            check("the overall limit applies after the cap", names(limited) == Array(expected(perYear: 1).prefix(2)), "\(names(limited))")
            let none = try run(spec(.track, caps: nil))
            check("without caps nothing is dropped", names(none).count == rows.count)
            check("a track whose year is still being looked up is reported as pending", one.pending.contains { $0.field == "Release year" && $0.count > 0 },
                  "\(one.pending.map { "\($0.field)=\($0.count)" })")

            let albums = try run(spec(.album, caps: QueryGroupLimit(perReleaseYear: 1)))
            check("albums, 1 per release year (no-date and not-yet-looked-up albums are never capped)",
                  names(albums) == ["B Three", "A One", "A Three", "B Two"], "\(names(albums))")

            // The display order: the sorts pick who survives, the results are then shown by release year (oldest first) unless told otherwise.
            let yearOf = Dictionary(uniqueKeysWithValues: rows.map { ($0.track, $0.year) })
            func byYear(_ tracks: [String], ascending: Bool) -> [String] {
                // Stable: tracks of one year (or with no year) keep the order they were picked in; no year goes last either way.
                tracks.enumerated().sorted { a, b in
                    switch (yearOf[a.element] ?? nil, yearOf[b.element] ?? nil) {
                    case (let x?, let y?): return x != y ? (ascending ? x < y : x > y) : a.offset < b.offset
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: return a.offset < b.offset
                    }
                }.map(\.element)
            }
            let auto = try run(spec(.track, caps: QueryGroupLimit(perReleaseYear: 1), rankOrder: false))
            check("with a per-release-year cap the results are shown by release year, oldest first, by default", names(auto) == byYear(expected(perYear: 1), ascending: true), "\(names(auto)) vs \(byYear(expected(perYear: 1), ascending: true))")
            check("…and the same tracks survive as when shown in rank order", Set(names(auto)) == Set(names(one)))
            check("…with the tracks that have no known year last", names(auto) == ["a1 x", "a3 x", "b3 x", "b2 x", "b2 y"], "\(names(auto))")
            var newest = spec(.track, caps: QueryGroupLimit(perReleaseYear: 1), rankOrder: false)
            newest.resultSorts = [QuerySort(key: .field(QueryFieldRef("releaseYear")), direction: .descending)]
            let newestFirst = try run(newest)
            check("a chosen display order replaces the automatic one (newest first), and still keeps the same tracks", names(newestFirst) == byYear(expected(perYear: 1), ascending: false) && Set(names(newestFirst)) == Set(names(one)), "\(names(newestFirst))")
            var byPlays = spec(.track, caps: QueryGroupLimit(perReleaseYear: 1), rankOrder: false)
            byPlays.showInRankOrder = true
            check("“in rank order” keeps the sorts' order", names(try run(byPlays)) == expected(perYear: 1))
            var byName = spec(.track, caps: QueryGroupLimit(perReleaseYear: 1), rankOrder: false)
            byName.resultSorts = [QuerySort(key: .field(QueryFieldRef("name")), direction: .ascending)]
            check("any field can be the display order (here the name)", names(try run(byName)) == names(one).sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "\(names(try run(byName)))")
            let limitedAuto = try run(spec(.track, caps: QueryGroupLimit(perReleaseYear: 1), limit: 2, rankOrder: false))
            check("the limit still takes the top of the rank order, then those are shown by year", names(limitedAuto) == byYear(Array(expected(perYear: 1).prefix(2)), ascending: true), "\(names(limitedAuto))")
            let artistCap = try run(spec(.track, caps: QueryGroupLimit(perArtist: 1), rankOrder: false))
            check("a cap on something other than release year leaves the order alone", names(artistCap) == expected(perArtist: 1), "\(names(artistCap))")
            check("no cap leaves it alone too", names(try run(spec(.track, caps: nil, rankOrder: false))) == rows.map(\.track))
            let albumsAuto = try run(spec(.album, caps: QueryGroupLimit(perReleaseYear: 1), rankOrder: false))
            check("albums, one per release year, shown by year", names(albumsAuto) == ["A One", "A Three", "B Three", "B Two"], "\(names(albumsAuto))")

            // Saved queries
            let oldJSON = Data(#"{"schemaVersion":4,"target":"album","groups":[],"sorts":[],"columns":[]}"#.utf8)
            let decodedOld = try? QuerySpec.decode(oldJSON)
            check("a query saved before the display order existed still decodes, with none", decodedOld != nil && decodedOld?.resultSorts == nil && decodedOld?.showInRankOrder == nil)
            check("the display order survives saving", (try? QuerySpec.decode(newest.encoded()))?.resultSorts == newest.resultSorts && QuerySpec.currentSchemaVersion == 5)
            check("a query from a newer version is still refused", (try? QuerySpec.decode(Data(#"{"schemaVersion":6,"target":"album","groups":[],"sorts":[],"columns":[]}"#.utf8))) == nil)
        } catch {
            check("the engine runs a per-release-year cap", false, "\(error)")
        }

        func rejected(_ target: QueryTarget, _ caps: QueryGroupLimit) -> Bool { (try? spec(target, caps: caps).validate(against: .standard)) == nil }
        check("a per-release-year cap on an artist query is refused", rejected(.artist, QueryGroupLimit(perReleaseYear: 1)))
        check("a per-release-year cap below 1 is refused", rejected(.track, QueryGroupLimit(perReleaseYear: 0)))
        check("a per-release-year cap is accepted on albums and tracks", !rejected(.album, QueryGroupLimit(perReleaseYear: 1)) && !rejected(.track, QueryGroupLimit(perReleaseYear: 3)))
        check("a per-album cap on an album query is still refused", rejected(.album, QueryGroupLimit(perAlbum: 1)))
    }

    // MARK: - Saved queries and the builder

    private static func modelChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let old = Data(#"{"schemaVersion":4,"target":"track","groups":[],"sorts":[],"columns":[],"groupLimit":{"perArtist":2}}"#.utf8)
        let decoded = try? QuerySpec.decode(old)
        check("a query saved before the cap existed still opens, with the cap off", decoded?.groupLimit?.perArtist == 2 && decoded?.groupLimit?.perReleaseYear == nil)
        var spec = QuerySpec(target: .track)
        spec.groupLimit = QueryGroupLimit(perArtist: 2, perAlbum: 1, perReleaseYear: 3)
        let again = (try? QuerySpec.decoder().decode(QuerySpec.self, from: JSONEncoder().encode(spec)))
        check("a query with all three caps survives saving and opening", again?.groupLimit == spec.groupLimit)

        let (artistSpec, removed) = QueryBuilderModel.switching(spec, to: .artist, registry: .standard)
        check("switching to artists removes all three caps and counts them", artistSpec.groupLimit == nil && removed == 3, "removed \(removed), left \(String(describing: artistSpec.groupLimit))")
        let (albumSpec, removedForAlbum) = QueryBuilderModel.switching(spec, to: .album, registry: .standard)
        check("switching to albums keeps the per-artist and per-release-year caps, drops per-album",
              albumSpec.groupLimit == QueryGroupLimit(perArtist: 2, perAlbum: nil, perReleaseYear: 3) && removedForAlbum == 1, "\(String(describing: albumSpec.groupLimit))")
        var caps = QueryGroupLimit(perArtist: 2, perAlbum: 1)
        caps.perReleaseYear = 4
        check("setting one cap leaves the others", caps == QueryGroupLimit(perArtist: 2, perAlbum: 1, perReleaseYear: 4) && !caps.isEmpty && QueryGroupLimit().isEmpty)
    }

    // MARK: - Ask

    private static func reply(target: String = "track", conditions: String = "[]", sorts: String = "[]", limit: String = "null", caps: String = "", unsupported: String = "[]") -> AskLLMReply {
        let json = """
        {"target":"\(target)","groups":[\(conditions == "[]" ? "" : conditions)],"sorts":\(sorts),"limit":\(limit),\(caps)"unsupported":\(unsupported),
        "resolvedTerms":[],"similarSeed":"","similarKind":"none","similarArtist":"","similarLimit":0}
        """
        return AskLLMReply(json: Data(json.utf8))
    }

    private static let artistCondition = #"[{"field":"artist","op":"textIs","value":null,"valueTo":null,"text":"Artist A","date":null,"dateTo":null,"tags":[],"parameters":[],"scope":null,"comparedAgo":null}]"#
    private static let playsDescending = #"[{"field":"plays","direction":"descending","parameters":[],"scope":null,"comparedAgo":null}]"#

    private static func askChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func read(_ reply: AskLLMReply, request: String?) -> AskTranslation? {
            try? AskModelEngine.read(reply, request: request, registry: .standard, context: .none, now: Date(), engine: "test", seconds: 0)
        }
        // Any wording about diversity lets the model's own caps through (see `AskPatterns.mentionsDiversity`).
        let cappedRequest = "tracks, per the usual rules"
        let sentence = "Show me the top song from each Band X album"
        let restated = #"["the top song from each album — grouping by album isn’t something a field can express"]"#

        // The reply a model gave before caps existed in the answer shape: sorted by plays, the cap written as "unsupported".
        let before = read(reply(conditions: artistCondition, sorts: playsDescending, unsupported: restated), request: sentence)
        check("the failing reply, with the request text, now carries 1 per album", before?.interpretation.spec.groupLimit?.perAlbum == 1, "\(String(describing: before?.interpretation.spec.groupLimit))")
        check("…with no 'not something I can search for' note left", before?.interpretation.unsupported.isEmpty == true, "\(String(describing: before?.interpretation.unsupported))")
        check("…still sorted by plays, most first, with no overall limit",
              before?.interpretation.spec.sorts.count == 1 && before?.interpretation.spec.limit == nil)
        check("…and nothing was dropped", before?.interpretation.dropped.isEmpty == true)
        let without = read(reply(conditions: artistCondition, sorts: playsDescending, unsupported: restated), request: nil)
        check("without the request text, the model's own answer is trusted as is (cap null, note kept)", without?.interpretation.spec.groupLimit == nil && without?.interpretation.unsupported.count == 1)

        let modelWrote = read(reply(conditions: artistCondition, sorts: playsDescending, caps: #""perArtist":null,"perAlbum":1,"perReleaseYear":null,"#), request: sentence)
        check("a reply that sets perAlbum: 1 gives the same cap", modelWrote?.interpretation.spec.groupLimit == QueryGroupLimit(perAlbum: 1), "\(String(describing: modelWrote?.interpretation.spec.groupLimit))")
        let asString = read(reply(sorts: playsDescending, caps: #""perArtist":null,"perAlbum":"2","perReleaseYear":null,"#), request: cappedRequest)
        check("a cap written as the string \"2\" is read as 2", asString?.interpretation.spec.groupLimit?.perAlbum == 2)
        let large = read(reply(sorts: playsDescending, caps: #""perArtist":500,"perAlbum":null,"perReleaseYear":null,"#), request: cappedRequest)
        check("an over-large cap is held to 20", large?.interpretation.spec.groupLimit?.perArtist == 20)
        let zero = read(reply(sorts: playsDescending, caps: #""perArtist":0,"perAlbum":null,"perReleaseYear":0,"#), request: cappedRequest)
        check("a cap of 0 means none", zero?.interpretation.spec.groupLimit == nil && zero?.interpretation.dropped.isEmpty == true)

        let year = read(reply(target: "album", sorts: playsDescending, caps: #""perArtist":null,"perAlbum":null,"perReleaseYear":1,"#), request: "my most played album from every release year")
        check("albums with perReleaseYear: 1 keep the cap", year?.interpretation.spec.groupLimit == QueryGroupLimit(perReleaseYear: 1))
        // "Top Album by Release Year" (the reported case): the model sorted by plays and wrote no cap at all.
        let reported = read(reply(target: "album", sorts: playsDescending), request: "Top Album by Release Year")
        check("“Top Album by Release Year” with a model that wrote no cap is still one album per release year", reported?.interpretation.spec.groupLimit == QueryGroupLimit(perReleaseYear: 1) && reported?.interpretation.spec.limit == nil, "\(String(describing: reported?.interpretation.spec.groupLimit)) \(String(describing: reported?.interpretation.spec.limit))")
        let reportedThe = read(reply(target: "album", sorts: playsDescending), request: "the top album by release year")
        check("…and \"the top album by release year\" is not cut to one album in all", reportedThe?.interpretation.spec.groupLimit == QueryGroupLimit(perReleaseYear: 1) && reportedThe?.interpretation.spec.limit == nil)
        check("the wordings that mean one per year", ["best track by release year", "top song of each release year", "favorite album for every release year", "most played album in release year"].allSatisfy { AskPatterns.groupLimit(in: $0).perReleaseYear == 1 })
        check("the plural could mean sorted by year, so it is left to the model", AskPatterns.groupLimit(in: "top albums by release year").isEmpty && AskPatterns.groupLimit(in: "albums sorted by release year").isEmpty && AskPatterns.groupLimit(in: "my top album").isEmpty)
        let plural = read(reply(target: "album", sorts: playsDescending), request: "top albums by release year")
        check("…and the plural without a cap from the model stays uncapped", plural?.interpretation.spec.groupLimit == nil)
        // The display order Ask gives a per-release-year query
        let reportedChips = reported.map { AskChips.describe($0.interpretation.spec, registry: .standard).map(\.text) } ?? []
        check("“Top Album by Release Year” is shown by release year (automatic), and says so in its chips", reported?.interpretation.spec.resultSorts == nil && reportedChips.contains("Shown by release year ↑") && reportedChips.contains("≤1 per release year"), "\(reportedChips)")
        let newestFirst = read(reply(target: "album", sorts: playsDescending), request: "top album by release year, newest first")
        check("“newest first” makes the years newest first", newestFirst?.interpretation.spec.resultSorts == [QuerySort(key: .field(QueryFieldRef("releaseYear")), direction: .descending)] && newestFirst?.interpretation.spec.sorts.first?.direction == .descending, "\(String(describing: newestFirst?.interpretation.spec.resultSorts))")
        let oldestFirst = read(reply(target: "album", sorts: playsDescending), request: "my most played album from each release year, oldest first")
        check("“oldest first” makes them oldest first", oldestFirst?.interpretation.spec.resultSorts?.first?.direction == .ascending)
        check("the plays sort that picks the winners is kept either way", reported?.interpretation.spec.sorts.first?.direction == .descending && oldestFirst?.interpretation.spec.sorts.first?.direction == .descending)
        let noCapNewest = read(reply(target: "album", sorts: playsDescending), request: "my top albums, newest first")
        check("a direction for the years without a per-year cap changes nothing", noCapNewest?.interpretation.spec.resultSorts == nil)
        check("the wordings for the direction", ["newest first", "latest to earliest", "most recent first", "reverse chronological"].allSatisfy { AskPatterns.yearOrder(in: $0) == .descending } && ["oldest first", "earliest first", "chronologically", "oldest to newest"].allSatisfy { AskPatterns.yearOrder(in: $0) == .ascending } && AskPatterns.yearOrder(in: "top album by release year") == nil)
        let rankChips = AskChips.describe({ var s = QuerySpec(target: .album); s.groupLimit = QueryGroupLimit(perReleaseYear: 1); s.showInRankOrder = true; return s }(), registry: .standard).map(\.text)
        check("“in rank order” has no “shown by” chip", !rankChips.contains { $0.hasPrefix("Shown by") })
        let switched = QueryBuilderModel.switching({ var s = QuerySpec(target: .album); s.resultSorts = [QuerySort(key: .field(QueryFieldRef("releaseYear")), direction: .ascending)]; return s }(), to: .artist, registry: .standard)
        check("switching to artists drops a display order by a field artists don't have, and says so", switched.spec.resultSorts == nil && switched.removed == 1)
        let artistTarget = read(reply(target: "artist", sorts: playsDescending, caps: #""perArtist":1,"perAlbum":1,"perReleaseYear":1,"#), request: cappedRequest)
        check("on an artist query all three caps are dropped, each with a reason",
              artistTarget?.interpretation.spec.groupLimit == nil && artistTarget?.interpretation.dropped.count == 3, "\(String(describing: artistTarget?.interpretation.dropped))")
        let albumTarget = read(reply(target: "album", sorts: playsDescending, caps: #""perArtist":null,"perAlbum":1,"perReleaseYear":null,"#), request: cappedRequest)
        check("per album on an album query is dropped with a reason", albumTarget?.interpretation.spec.groupLimit == nil && albumTarget?.interpretation.dropped.count == 1)

        let both = read(reply(sorts: playsDescending, limit: "10", caps: #""perArtist":1,"perAlbum":null,"perReleaseYear":null,"#), request: "top 10 songs, 1 per artist")
        check("a cap and a total limit are both kept", both?.interpretation.spec.groupLimit?.perArtist == 1 && both?.interpretation.spec.limit == 10)

        let unrelated = read(reply(conditions: artistCondition, sorts: playsDescending, unsupported: #"["songs that give me chills — no field measures how a song feels"]"#), request: "top song from each album that gives me chills")
        check("an unrelated 'unsupported' note survives while the cap is applied", unrelated?.interpretation.spec.groupLimit?.perAlbum == 1 && unrelated?.interpretation.unsupported.count == 1,
              "\(String(describing: unrelated?.interpretation.unsupported))")
        let noCapAsked = read(reply(conditions: artistCondition, unsupported: restated), request: "songs by Artist A")
        check("a request that states no cap never gets one", noCapAsked?.interpretation.spec.groupLimit == nil)

        // The closed-vocabulary reader.
        func caps(_ text: String) -> AskPatterns.Caps { AskPatterns.groupLimit(in: text) }
        check("“the top song from each album” → 1 per album", caps("the top song from each Band X album") == AskPatterns.Caps(perAlbum: 1))
        check("“2 songs per artist” → 2 per artist", caps("top 20 songs, 2 songs per artist") == AskPatterns.Caps(perArtist: 2))
        check("“one album per release year” → 1 per release year", caps("one album per release year") == AskPatterns.Caps(perReleaseYear: 1))
        check("“3 per release year” → 3", caps("3 tracks per release year") == AskPatterns.Caps(perReleaseYear: 3))
        check("“each release year” → 1", caps("my favorite track from each release year") == AskPatterns.Caps(perReleaseYear: 1))
        check("bare “each year” is not read as a cap (it could mean the year it was played)", caps("my top song each year").isEmpty && caps("tracks I played every year").isEmpty)
        check("a request with no cap words reads none", caps("songs by Artist A I haven't played this year").isEmpty)

        // What the model is told, and may answer.
        let schema = AskPortableSchema.build(registry: .standard).object()
        let properties = schema["properties"] as? [String: Any] ?? [:]
        check("the answer schema declares all three caps", ["perArtist", "perAlbum", "perReleaseYear"].allSatisfy { properties[$0] != nil })
        let prompt = AskPrompt.system(registry: .standard, context: .none, now: Date())
        check("the instructions explain all three caps", ["perArtist", "perAlbum", "perReleaseYear"].allSatisfy { prompt.contains($0) })
        check("every worked example still reads cleanly (none dropped)", AskExamples.staleExamples(registry: .standard).isEmpty)
        let rendered = AskExamples.renderedForModels(registry: .standard)
        check("the worked examples show a cap", rendered.contains("\"perAlbum\":1") && rendered.contains("\"perReleaseYear\":1"))

        // Columns: what the request is about is shown.
        func columnIDs(_ translation: AskTranslation?) -> [String] { translation?.interpretation.spec.columns.map(\.id) ?? [] }
        let yearAlbums = read(reply(target: "album", sorts: playsDescending, caps: #""perArtist":null,"perAlbum":null,"perReleaseYear":1,"#), request: "my most played album from each release year")
        check("a per-release-year cap on albums shows the Release year column", columnIDs(yearAlbums).contains("releaseYear"), "\(columnIDs(yearAlbums))")
        let yearTracks = read(reply(sorts: playsDescending, caps: #""perArtist":null,"perAlbum":null,"perReleaseYear":2,"#), request: cappedRequest)
        check("…and on tracks", columnIDs(yearTracks).contains("releaseYear") && columnIDs(yearTracks).first == "plays", "\(columnIDs(yearTracks))")
        let yearAndBase = columnIDs(yearAlbums)
        check("…with the usual Plays and Last played still there", yearAndBase == ["plays", "releaseYear", "lastPlayed"], "\(yearAndBase)")
        let noCap = read(reply(target: "album", sorts: playsDescending), request: "my top albums")
        check("without a cap no Release year column is added", !columnIDs(noCap).contains("releaseYear"))
        let artistCap = read(reply(target: "artist", sorts: playsDescending, caps: #""perArtist":null,"perAlbum":null,"perReleaseYear":1,"#), request: cappedRequest)
        check("a cap dropped for an artist query adds no column", !columnIDs(artistCap).contains("releaseYear"))
        let albumCaps = read(reply(sorts: playsDescending, caps: #""perArtist":1,"perAlbum":1,"perReleaseYear":null,"#), request: cappedRequest)
        check("per-artist and per-album caps add no column (artist and album are in each row already)", columnIDs(albumCaps) == ["plays", "lastPlayed"], "\(columnIDs(albumCaps))")
        let yearCondition = #"[{"field":"releaseYear","op":"greaterThan","value":1990,"valueTo":null,"text":null,"date":null,"dateTo":null,"tags":[],"parameters":[],"scope":null,"comparedAgo":null}]"#
        let yearBoth = read(reply(target: "album", conditions: yearCondition, sorts: playsDescending, caps: #""perArtist":null,"perAlbum":null,"perReleaseYear":1,"#), request: cappedRequest)
        check("a request that already filters on release year gets one such column, not two", columnIDs(yearBoth).filter { $0 == "releaseYear" }.count == 1, "\(columnIDs(yearBoth))")
        if let spec = yearAlbums?.interpretation.spec, let result = try? run(spec) {
            let key = result.columns.first { $0.field.id == "releaseYear" }?.cacheKey
            let years = result.rows.compactMap { row -> Int? in
                if let key, case .value(.number(let n))? = row.cells[key] { return Int(n) }
                return nil
            }
            check("the Release year column carries the real years in the results (1990 and 1995 here)", Set(years) == [1990, 1995], "\(years)")
        } else {
            check("the Ask reading runs and carries a Release year column", false)
        }

        // A smaller model's blanks and guesses (what a local model wrote for these exact requests).
        let junkScope = #"{"days":0,"from":"2026-10-16","kind":"absolute","shiftCount":0,"shiftUnit":"day","to":"2026-10-16","unit":"day"}"#
        let junkCondition = #"[{"comparedAgo":{"count":0,"unit":"year"},"date":"2026-10-16","dateTo":"2026-10-16","field":"artist","op":"textIs","parameters":[],"scope":"# + junkScope + #","tags":[],"text":"Artist A","value":null,"valueTo":null}]"#
        let junkSort = #"[{"comparedAgo":{"count":0,"unit":"year"},"direction":"descending","field":"plays","parameters":[],"scope":"# + junkScope + "}]"
        let blanks = read(reply(conditions: junkCondition, sorts: junkSort, limit: "10"), request: "top 10 songs by Artist A")
        check("a period and a 'compare with 0 earlier' written on a name field are ignored, not fatal", blanks?.interpretation.dropped.isEmpty == true, "\(String(describing: blanks?.interpretation.dropped))")
        check("…so the artist filter, the sort and the limit all survive",
              blanks?.interpretation.spec.groups.first?.first?.field.id == "artist" && blanks?.interpretation.spec.sorts.count == 1 && blanks?.interpretation.spec.limit == 10)
        let zeroCompare = #"[{"comparedAgo":{"count":0,"unit":"day"},"direction":"descending","field":"plays","parameters":[],"scope":{"kind":"calendar","unit":"year","days":0,"from":"","to":"","shiftCount":0,"shiftUnit":"none"}}]"#
        let zeroed = read(reply(sorts: zeroCompare), request: "most played this year")
        check("a zero comparison on a field that does take a period is none: the period is kept", zeroed?.interpretation.dropped.isEmpty == true && { if case .field(let ref)? = zeroed?.interpretation.spec.sorts.first?.key { return ref.scope != nil } else { return false } }(), "\(String(describing: zeroed?.interpretation.dropped))")

        // Caps the request never asked for.
        let allOnes = #""perArtist":1,"perAlbum":1,"perReleaseYear":1,"#
        let guessed = read(reply(sorts: playsDescending, limit: "1", caps: allOnes), request: "my most played song by Artist A")
        check("caps set with no diversity wording in the request are dropped", guessed?.interpretation.spec.groupLimit == nil && guessed?.interpretation.dropped.isEmpty == true, "\(String(describing: guessed?.interpretation.spec.groupLimit))")
        let wanted = read(reply(sorts: playsDescending, limit: "10", caps: #""perArtist":1,"perAlbum":null,"perReleaseYear":null,"#), request: "top 10 songs from different artists")
        check("…while 'different artists' lets the model's per-artist cap through", wanted?.interpretation.spec.groupLimit == QueryGroupLimit(perArtist: 1))
        for (text, expected) in [("2 songs per artist", true), ("one track from each album", true), ("each year", true), ("at most 3 per band", true), ("my most played song by X", false), ("top 10 albums", false), ("songs I played this week", false)] {
            check("diversity wording: “\(text)” → \(expected)", AskPatterns.mentionsDiversity(text) == expected)
        }

        // "by <an artist in the library>" with no artist condition in the answer.
        let known: Set<String> = ["Artist A", "Artist B & Artist C"]
        let withLibrary = AskContext(knownArtists: known)
        func readWith(_ reply: AskLLMReply, _ request: String, _ context: AskContext = withLibrary) -> AskTranslation? {
            try? AskModelEngine.read(reply, request: request, registry: .standard, context: context, now: Date(), engine: "test", seconds: 0)
        }
        let wrongField = #"[{"field":"plays","op":"greaterThan","value":0,"valueTo":null,"text":"Artist A","date":null,"dateTo":null,"tags":[],"parameters":[],"scope":null,"comparedAgo":null}]"#
        let fixed = readWith(reply(conditions: wrongField, sorts: playsDescending, limit: "1"), "my most played song by Artist A")
        let fixedArtist = fixed?.interpretation.spec.groups.flatMap { $0 }.first { $0.field.id == "artist" }
        check("a named library artist with no artist condition gets one", fixedArtist?.op == .textIs && fixedArtist?.operands == [.text("Artist A")], "\(String(describing: fixed?.interpretation.spec.groups))")
        check("…and the added filter is said out loud", fixed?.resolvedTerms.contains { $0.phrase == "by Artist A" && $0.meaning == "the artist is Artist A" } == true)
        let none = readWith(reply(sorts: playsDescending, limit: "1"), "my most played song by Artist A")
        check("…even when the model wrote no condition at all", none?.interpretation.spec.groups == [[QueryCondition("artist", .textIs, [.text("Artist A")])]], "\(String(describing: none?.interpretation.spec.groups))")
        let already = readWith(reply(conditions: artistCondition, sorts: playsDescending, limit: "1"), "my most played song by Artist A")
        check("an artist condition the model wrote is not doubled", already?.interpretation.spec.groups.flatMap { $0 }.filter { $0.field.id == "artist" }.count == 1)
        let stranger = readWith(reply(sorts: playsDescending), "my most played song by Nobody Known")
        check("a name that isn't a library artist adds nothing", stranger?.interpretation.spec.groups.isEmpty == true)
        let sorted = readWith(reply(sorts: playsDescending), "my songs sorted by plays")
        check("“sorted by plays” is a sort, not an artist", sorted?.interpretation.spec.groups.isEmpty == true)
        let noLibrary = readWith(reply(sorts: playsDescending), "my most played song by Artist A", .none)
        check("without the library's artist names nothing is guessed", noLibrary?.interpretation.spec.groups.isEmpty == true)
        let artistQuery = readWith(reply(target: "artist", sorts: playsDescending), "artists by Artist A")
        check("an artist query never gets an artist condition added", artistQuery?.interpretation.spec.groups.isEmpty == true)
        check("an artist with an ampersand is found whole", AskPatterns.namedArtist(in: "albums by Artist B & Artist C", knownArtists: known) == nil || AskPatterns.namedArtist(in: "albums by Artist B & Artist C", knownArtists: known) == "Artist B & Artist C")

        // Numbers the request states that a model left out.
        let leanTop = AskLLMReply(json: Data(#"{"target":"track","groups":[],"sorts":[{"field":"plays","direction":"descending"}]}"#.utf8))
        check("“top 50 tracks of all time”: a limit the model left out is applied from the wording", read(leanTop, request: "top 50 tracks of all time")?.interpretation.spec.limit == 50)
        check("“10 most recently played tracks” → 10", read(leanTop, request: "10 most recently played tracks")?.interpretation.spec.limit == 10)
        check("a request with no count gets no limit", read(leanTop, request: "tracks longer than 6 minutes")?.interpretation.spec.limit == nil)
        check("a limit the model did write is kept", read(reply(sorts: playsDescending, limit: "7"), request: "top 50 tracks")?.interpretation.spec.limit == 7)
        for (text, expected) in [("my most played song by Artist A", true), ("the top album", true), ("my favorite track", true), ("my most played songs", false), ("top songs of 2024", false), ("my most played song this year", true), ("the top song from each album", false), ("my most played album from each release year", false), ("songs I played most", false)] {
            check("a singular superlative asks for one: “\(text)” → \(expected)", AskPatterns.asksForOne(text) == expected)
        }
        check("“my most played song by …” gets a limit of 1 when the model left it out", read(leanTop, request: "my most played song by Artist A")?.interpretation.spec.limit == 1)
        for (text, expected) in [("find 25 songs similar to Song A", 25), ("40 tracks similar to Song A by Artist A", 40), ("ten songs like Song A", 10)] as [(String, Int)] {
            check("similar count: “\(text)” → \(expected)", AskPatterns.similarCount(in: text) == expected)
        }
        for text in ["recommend some music like Artist A", "songs like 3 Doors Down", "what should I listen to if I like Album A"] {
            check("similar count: “\(text)” → none", AskPatterns.similarCount(in: text) == nil)
        }
        let seedReply = AskLLMReply(json: Data(#"{"target":"track","groups":[],"similarSeed":"Song A"}"#.utf8))
        check("a similar request takes its number from the wording", read(seedReply, request: "find 25 songs similar to Song A")?.similar?.limit == 25)
        check("…and keeps the default without one", read(seedReply, request: "recommend some music like Song A")?.similar?.limit == AskSimilarIntent.defaultLimit)
        let bogus = AskLLMReply(json: Data(#"{"target":"track","groups":[],"unsupported":[",", " . ", "a real note"]}"#.utf8))
        check("an 'unsupported' note with no letters or digits is noise and is dropped", read(bogus, request: "x")?.interpretation.unsupported == ["a real note"], "\(String(describing: read(bogus, request: "x")?.interpretation.unsupported))")

        // What Ollama is sent: only what a query can't exist without is required; the cloud schema is unchanged.
        let strict = AskPortableSchema.build(registry: .standard)
        let local = AskSchemaAdapter.ollama(strict.object())
        let localRequired = Set(local["required"] as? [String] ?? [])
        check("the Ollama schema requires only the target and the groups", localRequired == ["target", "groups"], "\(localRequired)")
        let groupsSchema = ((local["properties"] as? [String: Any])?["groups"] as? [String: Any])?["items"] as? [String: Any]
        let conditionSchema = groupsSchema?["items"] as? [String: Any]
        check("…and a condition only its field and operator", Set(conditionSchema?["required"] as? [String] ?? []) == ["field", "op"], "\(String(describing: conditionSchema?["required"]))")
        let strictRequired = Set(strict.object()["required"] as? [String] ?? [])
        check("the schema cloud providers get still requires every key", strictRequired.isSuperset(of: ["target", "groups", "sorts", "limit", "perArtist", "perAlbum", "perReleaseYear", "unsupported"]), "\(strictRequired)")
        let lean = read(AskLLMReply(json: Data(#"{"target":"track","groups":[[{"field":"artist","op":"textIs","text":"Artist A"}]],"sorts":[{"field":"plays","direction":"descending"}],"limit":1}"#.utf8)), request: "my most played song by Artist A")
        check("an answer that leaves out every unused key reads fine", lean?.interpretation.dropped.isEmpty == true && lean?.interpretation.spec.limit == 1 && lean?.interpretation.spec.groupLimit == nil && lean?.interpretation.spec.groups.first?.first?.field.id == "artist")

        // The engine indicator under the Ask box.
        var settings = AskSettings()
        let onDevice = AskEngineIndicator.describe(settings)
        check("the indicator names the on-device model and warns that it is limited", onDevice.title == "Apple on-device" && onDevice.warning?.hasPrefix("Limited") == true)
        for engine in AskEngineID.allCases where engine != .onDevice {
            settings.selected = engine
            let line = AskEngineIndicator.describe(settings)
            let model = settings.config(for: engine).model
            check("the indicator for \(engine.label) names it and its model, with no warning",
                  line.title.hasPrefix(engine.label) && (model.isEmpty || line.title.hasSuffix(model)) && line.warning == nil, line.title)
        }
        for engine in AskEngineID.allCases {
            settings.selected = engine
            let note = AskEngineIndicator.describe(settings).note
            let isLocal = engine == .ollama || engine == .openAICompatible
            check("the first-answer-is-slow note is shown for \(engine.label) only if it runs on your own Mac or server", (note != nil) == isLocal && (note?.contains("first question") ?? true), note ?? "none")
        }
        settings.selected = .openAI
        settings.set(AskProviderConfig(model: "model-x", baseURL: ""), for: .openAI)
        check("a model chosen in Settings is the one shown", AskEngineIndicator.describe(settings).title.hasSuffix("model-x"))
        check("the indicator watches the key the settings are stored under", AskSettingsStore.key == "ask.settings.v1")

        // Chips.
        var chipSpec = QuerySpec(target: .track)
        chipSpec.groupLimit = QueryGroupLimit(perArtist: 2, perAlbum: 1, perReleaseYear: 3)
        let chipTexts = AskChips.describe(chipSpec, registry: .standard).map(\.text)
        check("the chips say each cap", chipTexts.contains("≤2 per artist") && chipTexts.contains("≤1 per album") && chipTexts.contains("≤3 per release year"), "\(chipTexts)")
    }
}
#endif
