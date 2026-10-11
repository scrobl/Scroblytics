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

    private static func spec(_ target: QueryTarget, caps: QueryGroupLimit?, limit: Int? = nil) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
        spec.columns = [QueryFieldRef("plays")]
        spec.groupLimit = caps
        spec.limit = limit
        return spec
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
        let asString = read(reply(sorts: playsDescending, caps: #""perArtist":null,"perAlbum":"2","perReleaseYear":null,"#), request: "x")
        check("a cap written as the string \"2\" is read as 2", asString?.interpretation.spec.groupLimit?.perAlbum == 2)
        let large = read(reply(sorts: playsDescending, caps: #""perArtist":500,"perAlbum":null,"perReleaseYear":null,"#), request: "x")
        check("an over-large cap is held to 20", large?.interpretation.spec.groupLimit?.perArtist == 20)
        let zero = read(reply(sorts: playsDescending, caps: #""perArtist":0,"perAlbum":null,"perReleaseYear":0,"#), request: "x")
        check("a cap of 0 means none", zero?.interpretation.spec.groupLimit == nil && zero?.interpretation.dropped.isEmpty == true)

        let year = read(reply(target: "album", sorts: playsDescending, caps: #""perArtist":null,"perAlbum":null,"perReleaseYear":1,"#), request: "my most played album from every release year")
        check("albums with perReleaseYear: 1 keep the cap", year?.interpretation.spec.groupLimit == QueryGroupLimit(perReleaseYear: 1))
        let artistTarget = read(reply(target: "artist", sorts: playsDescending, caps: #""perArtist":1,"perAlbum":1,"perReleaseYear":1,"#), request: "x")
        check("on an artist query all three caps are dropped, each with a reason",
              artistTarget?.interpretation.spec.groupLimit == nil && artistTarget?.interpretation.dropped.count == 3, "\(String(describing: artistTarget?.interpretation.dropped))")
        let albumTarget = read(reply(target: "album", sorts: playsDescending, caps: #""perArtist":null,"perAlbum":1,"perReleaseYear":null,"#), request: "x")
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
        let yearTracks = read(reply(sorts: playsDescending, caps: #""perArtist":null,"perAlbum":null,"perReleaseYear":2,"#), request: "x")
        check("…and on tracks", columnIDs(yearTracks).contains("releaseYear") && columnIDs(yearTracks).first == "plays", "\(columnIDs(yearTracks))")
        let yearAndBase = columnIDs(yearAlbums)
        check("…with the usual Plays and Last played still there", yearAndBase == ["plays", "releaseYear", "lastPlayed"], "\(yearAndBase)")
        let noCap = read(reply(target: "album", sorts: playsDescending), request: "my top albums")
        check("without a cap no Release year column is added", !columnIDs(noCap).contains("releaseYear"))
        let artistCap = read(reply(target: "artist", sorts: playsDescending, caps: #""perArtist":null,"perAlbum":null,"perReleaseYear":1,"#), request: "x")
        check("a cap dropped for an artist query adds no column", !columnIDs(artistCap).contains("releaseYear"))
        let albumCaps = read(reply(sorts: playsDescending, caps: #""perArtist":1,"perAlbum":1,"perReleaseYear":null,"#), request: "x")
        check("per-artist and per-album caps add no column (artist and album are in each row already)", columnIDs(albumCaps) == ["plays", "lastPlayed"], "\(columnIDs(albumCaps))")
        let yearCondition = #"[{"field":"releaseYear","op":"greaterThan","value":1990,"valueTo":null,"text":null,"date":null,"dateTo":null,"tags":[],"parameters":[],"scope":null,"comparedAgo":null}]"#
        let yearBoth = read(reply(target: "album", conditions: yearCondition, sorts: playsDescending, caps: #""perArtist":null,"perAlbum":null,"perReleaseYear":1,"#), request: "x")
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
