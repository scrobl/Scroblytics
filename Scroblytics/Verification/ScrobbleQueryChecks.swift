#if DEBUG
import Foundation
import SwiftData

/// `SCROBLYTICS_SCROBBLEQUERY_CHECK=1`: a query that finds single plays (the Scrobbles target), on made-up plays with hand-worked answers.
/// Every number is compared with an independent count over the same plays, never with the engine's own bookkeeping.
enum ScrobbleQueryChecks {
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_SCROBBLEQUERY_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let calendar = AppCalendars.listening
            func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
                calendar.date(from: DateComponents(year: 2025, month: 3, day: day, hour: hour, minute: minute))!
            }
            func play(_ artist: String, _ track: String, _ album: String, _ date: Date) -> ScrobbleSnapshot {
                ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: nil, playedAt: date)
            }
            // Day 1 morning session (three plays four minutes apart), a repeat of the first song that evening, a Saturday night, and so on.
            let plays: [ScrobbleSnapshot] = [
                play("Artist A", "Song 1", "Album X", at(3, 9, 0)),
                play("Artist A", "Song 2", "Album X", at(3, 9, 4)),
                play("Artist B", "Song 3", "Album Y", at(3, 9, 8)),
                play("Artist A", "Song 1", "Album X", at(3, 21, 30)),
                play("Artist B", "Song 3", "", at(4, 14, 0)),
                play("Artist A", "Song 1", "Album X", at(8, 23, 15)),   // a Saturday
                play("Artist C", "Song 4", "Album Z", at(9, 1, 5)),     // a Sunday, after midnight
                play("Artist A", "Song 1", "Album X", at(12, 12, 0)),
            ].sorted { $0.playedAt < $1.playedAt }
            let asOf = at(20, 12)
            let registry = QueryFieldRegistry.standard

            func evaluate(_ spec: QuerySpec, weather: WeatherSnapshot = .empty, plays library: [ScrobbleSnapshot]? = nil) throws -> QueryResult {
                let validated = try spec.validate(against: registry)
                var snapshots = QuerySnapshots()
                snapshots.weather = weather
                let source = library ?? plays
                let run = QueryRun(target: spec.target, asOf: asOf, scrobbles: spec.countedPlays(source, weather: weather), allTimeScrobbles: source, snapshots: snapshots)
                return QueryEngine.evaluate(validated, run: run)
            }
            func key(_ id: String) -> String { try! registry.resolve(QueryFieldRef(id), target: .scrobble).cacheKey }
            func spec(columns: [String] = ["playedAt"], sort: QuerySortDirection? = .descending) -> QuerySpec {
                var s = QuerySpec(target: .scrobble)
                s.columns = columns.map { QueryFieldRef($0) }
                if let sort { s.sorts = [QuerySort(key: .field(QueryFieldRef("playedAt")), direction: sort)] }
                return s
            }
            func recentSpecCounted(_ source: [ScrobbleSnapshot]) -> [ScrobbleSnapshot] { spec().countedPlays(source) }
            func sortsBy(_ spec: QuerySpec, _ id: String) -> Bool {
                if case .field(let ref)? = spec.sorts.first?.key { return ref.id == id }
                return false
            }
            func number(_ row: QueryRow, _ id: String) -> Double? { if case .value(.number(let n))? = row.cells[key(id)] { n } else { nil } }
            func text(_ row: QueryRow, _ id: String) -> String? { if case .value(.text(let t))? = row.cells[key(id)] { t } else { nil } }
            func flag(_ row: QueryRow, _ id: String) -> Bool? { if case .value(.bool(let b))? = row.cells[key(id)] { b } else { nil } }
            func date(_ row: QueryRow, _ id: String) -> Date? { if case .value(.date(let d))? = row.cells[key(id)] { d } else { nil } }

            // One row per play, newest first.
            let all = try? evaluate(spec(columns: ["playedAt", "hourOfDay", "playAlbum", "playGap", "listenNumber", "firstListen"]))
            check("a scrobble query lists every play, one row each", all?.rows.count == plays.count && all?.matchedCount == plays.count, "\(String(describing: all?.rows.count))")
            check("…newest first", all?.rows.compactMap { date($0, "playedAt") } == plays.reversed().map(\.playedAt))
            let oldest = try? evaluate(spec(sort: .ascending))
            check("…and oldest first when asked", oldest?.rows.compactMap { date($0, "playedAt") } == plays.map(\.playedAt))
            check("two plays of the same song are two rows", all?.rows.filter { $0.entity.name == "Song 1" }.count == 4 && Set(all?.rows.map(\.id) ?? []).count == plays.count)
            check("a row says which song, artist and album it is", all?.rows.first?.entity.name == "Song 1" && all?.rows.first?.entity.artist == "Artist A" && all?.rows.first.flatMap { text($0, "playAlbum") } == "Album X")
            check("a play with no album has no album value", all?.rows.first { $0.entity.artist == "Artist B" && date($0, "playedAt") == at(4, 14) }.flatMap { text($0, "playAlbum") } == nil)
            check("the hour is the local hour of the play", all?.rows.compactMap { number($0, "hourOfDay") } == plays.reversed().map { Double(calendar.component(.hour, from: $0.playedAt)) })

            // Since the previous play, over the whole history.
            let gaps = all?.rows.map { number($0, "playGap") }
            check("the first play ever has no gap, every other the seconds since the play before it", gaps?.last == .some(nil) && zip(plays.dropFirst(), plays).map { $0.playedAt.timeIntervalSince($1.playedAt) } == (gaps?.dropLast().reversed().compactMap { $0 } ?? []))
            check("three plays four minutes apart read as 240 seconds", all?.rows.first { date($0, "playedAt") == at(3, 9, 4) }.flatMap { number($0, "playGap") } == 240)

            // Which listen of the song it is, over the whole history.
            let songOne = all?.rows.filter { $0.entity.name == "Song 1" }.sorted { (date($0, "playedAt") ?? .distantPast) < (date($1, "playedAt") ?? .distantPast) }
            check("the Nth listen counts 1, 2, 3, 4 for a song played four times", songOne?.compactMap { number($0, "listenNumber") } == [1, 2, 3, 4])
            check("only the first is marked the first time", songOne?.compactMap { flag($0, "firstListen") } == [true, false, false, false])
            var later = spec(columns: ["playedAt", "listenNumber", "playGap"])
            later.period = QueryPeriod(from: at(8, 0), to: at(30, 0))
            let laterResult = try? evaluate(later)
            check("a period leaves the earlier plays out of the list but still counts them", laterResult?.rows.count == 3 && laterResult?.rows.first.flatMap { number($0, "listenNumber") } == 4 && laterResult?.rows.last.flatMap { number($0, "listenNumber") } == 3, "\(String(describing: laterResult?.rows.compactMap { number($0, "listenNumber") }))")
            check("…and the gap reaches back past the period", laterResult?.rows.last.flatMap { number($0, "playGap") } == at(8, 23, 15).timeIntervalSince(at(4, 14)))

            // Conditions and the other fields.
            var byArtist = spec()
            byArtist.groups = [[QueryCondition("artist", .textIs, [.text("Artist B")])]]
            check("a condition on the artist keeps just its plays", (try? evaluate(byArtist))?.rows.count == plays.filter { $0.artistName == "Artist B" }.count)
            var night = spec(columns: ["playedAt", "hourOfDay"])
            night.groups = [[QueryCondition("hourOfDay", .greaterThanOrEqual, [.number(21)])]]
            let nightRows = try? evaluate(night)
            check("a condition on the hour keeps the late plays", nightRows?.rows.count == plays.filter { calendar.component(.hour, from: $0.playedAt) >= 21 }.count && nightRows?.rows.count == 2)
            var weekend = spec(columns: ["playedAt", "playDayOfWeek", "playWeekdayOrWeekend", "playTimeOfDay", "playSeason"])
            weekend.groups = [[QueryCondition("playWeekdayOrWeekend", .textIs, [.text("Weekend")])]]
            let weekendRows = try? evaluate(weekend)
            let weekendCount = plays.filter { let d = calendar.component(.weekday, from: $0.playedAt); return d == 1 || d == 7 }.count
            check("the weekend fields keep the Saturday and Sunday plays", weekendRows?.rows.count == weekendCount && weekendCount == 2, "\(String(describing: weekendRows?.rows.count)) of \(weekendCount)")
            check("a play's day of week and time of day are its own", weekendRows?.rows.compactMap { text($0, "playDayOfWeek") }.sorted() == ["Saturday", "Sunday"] && weekendRows?.rows.compactMap { text($0, "playTimeOfDay") }.sorted() == ["Night", "Night"], "\(String(describing: weekendRows?.rows.compactMap { text($0, "playTimeOfDay") }))")
            var firsts = spec()
            firsts.groups = [[QueryCondition("firstListen", .isTrue)]]
            check("“first time played” finds the four songs' first plays", (try? evaluate(firsts))?.rows.count == 4)

            // Limit, caps and the play filter.
            var top = spec()
            top.limit = 3
            check("a limit keeps the newest three", (try? evaluate(top))?.rows.compactMap { date($0, "playedAt") } == plays.reversed().prefix(3).map(\.playedAt))
            var oneEach = spec()
            oneEach.groupLimit = QueryGroupLimit(perArtist: 1)
            check("one per artist keeps each artist's newest play", (try? evaluate(oneEach))?.rows.map(\.entity.artist) == ["Artist A", "Artist C", "Artist B"])
            var capsYear = spec()
            capsYear.groupLimit = QueryGroupLimit(perReleaseYear: 1)
            check("a release-year cap or an album cap is refused for plays", (try? capsYear.validate(against: registry)) == nil && { var s = spec(); s.groupLimit = QueryGroupLimit(perAlbum: 1); return (try? s.validate(against: registry)) == nil }())
            var onlyMornings = spec()
            onlyMornings.playFilter = QueryPlayFilter(weekdays: nil, fromHour: 5, toHour: 11)
            check("the play filter narrows the plays listed", (try? evaluate(onlyMornings))?.rows.count == plays.filter { (5...11).contains(calendar.component(.hour, from: $0.playedAt)) }.count)

            // Where the play happened.
            let chicago = WeatherPlace(name: "Chicago, Illinois, United States", latitude: 41.9, longitude: -87.6, region: "Illinois", country: "United States")
            var places = WeatherSnapshot()
            places.placeName = "Oslo, Norway"
            places.homePlace = WeatherPlace(name: "Oslo, Norway", latitude: 59.9, longitude: 10.7)
            places.trips = [WeatherSnapshot.TripWeather(trip: WeatherTrip(place: chicago, from: at(8, 0), until: at(10, 0)), series: nil)]
            let whereRows = try? evaluate(spec(columns: ["playedAt", "playPlace", "playRegion", "playCountry"]), weather: places)
            let onTrip = whereRows?.rows.filter { (date($0, "playedAt") ?? .distantPast) >= at(8, 0) && (date($0, "playedAt") ?? .distantPast) < at(10, 0) }
            let athome = whereRows?.rows.filter { (date($0, "playedAt") ?? .distantPast) < at(8, 0) || (date($0, "playedAt") ?? .distantPast) >= at(10, 0) }
            check("plays on the trip say Chicago, Illinois, United States", onTrip?.count == 2 && onTrip?.allSatisfy { text($0, "playPlace") == "Chicago" && text($0, "playRegion") == "Illinois" && text($0, "playCountry") == "United States" } == true)
            check("plays at home say Oslo and Norway, and have no state", athome?.count == 6 && athome?.allSatisfy { text($0, "playPlace") == "Oslo" && text($0, "playCountry") == "Norway" && text($0, "playRegion") == nil } == true)
            var inIllinois = spec()
            inIllinois.playFilter = QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil, months: nil, regions: ["Illinois"])
            check("a state filter lists the plays made there", (try? evaluate(inIllinois, weather: places))?.rows.count == 2)
            var inNorway = spec()
            inNorway.groups = [[QueryCondition("playCountry", .textIs, [.text("Norway")])]]
            check("a condition on the country agrees with the filter", (try? evaluate(inNorway, weather: places))?.rows.count == 6)
            check("with no places recorded there is no place or weather value", (try? evaluate(spec(columns: ["playedAt", "playPlace", "playWeather", "playTemperature"])))?.rows.allSatisfy { text($0, "playPlace") == nil && text($0, "playWeather") == nil && number($0, "playTemperature") == nil } == true)

            // What a play inherits from the track, album and artist it is of (phase 2): each inherited field must equal the same field on a
            // query of that kind, and the counts must equal a recount of the plays.
            var snapshotsWithLoved = QuerySnapshots()
            snapshotsWithLoved.lovedKeys = [TextNormalization.lovedKey(artist: "Artist A", track: "Song 1")]
            func evaluateWith(_ s: QuerySpec, _ snaps: QuerySnapshots) throws -> QueryResult {
                let validated = try s.validate(against: registry)
                let run = QueryRun(target: s.target, asOf: asOf, scrobbles: s.countedPlays(plays), allTimeScrobbles: plays, snapshots: snaps)
                return QueryEngine.evaluate(validated, run: run)
            }
            var mismatched: [String] = []
            var compared = 0
            for entry in QueryFieldRegistry.inheritedFieldIDs {
                var playsSpec = QuerySpec(target: .scrobble)
                var itemSpec = QuerySpec(target: entry.level)
                let levelFields = Set(registry.fields(for: entry.level).map(\.id))
                let ids = entry.ids.filter { levelFields.contains($0) }
                playsSpec.columns = ids.map { QueryFieldRef(QueryFieldRegistry.inheritedFieldID(entry.level, $0)) }
                itemSpec.columns = ids.map { QueryFieldRef($0) }
                guard let playRows = try? evaluateWith(playsSpec, snapshotsWithLoved), let itemRows = try? evaluateWith(itemSpec, snapshotsWithLoved) else { mismatched.append("\(entry.level) did not run"); continue }
                let byItem = Dictionary(uniqueKeysWithValues: itemRows.rows.map { ($0.id, $0) })
                for row in playRows.rows {
                    guard let source = plays.first(where: { $0.playedAt.timeIntervalSince1970 == row.entity.id.at && $0.trackName == row.entity.name && $0.artistName == row.entity.artist }) else { continue }
                    let itemID: QueryEntityID? = switch entry.level {
                    case .artist: QueryEntityID(target: .artist, artist: source.artistName, name: source.artistName)
                    case .album: source.albumName.isEmpty ? nil : QueryEntityID(target: .album, artist: source.artistName, name: source.albumName)
                    default: QueryEntityID(target: .track, artist: source.artistName, name: source.trackName)
                    }
                    for id in ids {
                        let got = row.cells[try! registry.resolve(QueryFieldRef(QueryFieldRegistry.inheritedFieldID(entry.level, id)), target: .scrobble).cacheKey] ?? .missing
                        let want = itemID.flatMap { byItem[$0] }.map { $0.cells[try! registry.resolve(QueryFieldRef(id), target: entry.level).cacheKey] ?? .missing } ?? .missing
                        compared += 1
                        if got != want { mismatched.append("\(entry.level).\(id) \(got) vs \(want)") }
                    }
                }
            }
            check("every inherited field equals the same field on a query of its own kind, for every play (\(compared) cells)", mismatched.isEmpty && compared > 300, mismatched.prefix(3).joined(separator: "; "))
            var inheritedSpec = spec(columns: ["playedAt", "track.plays", "album.plays", "artist.plays", "track.firstPlayed", "track.loved"])
            inheritedSpec.sorts = [QuerySort(key: .field(QueryFieldRef("playedAt")), direction: .ascending)]
            let inheritedRows = try? evaluateWith(inheritedSpec, snapshotsWithLoved)
            func iNumber(_ row: QueryRow, _ id: String) -> Double? { if case .value(.number(let n))? = row.cells[try! registry.resolve(QueryFieldRef(id), target: .scrobble).cacheKey] { n } else { nil } }
            let expectedTrackPlays = plays.map { p in Double(plays.filter { $0.artistName == p.artistName && $0.trackName == p.trackName }.count) }
            let expectedAlbumPlays = plays.map { p in p.albumName.isEmpty ? nil : Double(plays.filter { $0.artistName == p.artistName && $0.albumName == p.albumName }.count) }
            let expectedArtistPlays = plays.map { p in Double(plays.filter { $0.artistName == p.artistName }.count) }
            check("a play's track, album and artist plays equal a recount", inheritedRows?.rows.map { iNumber($0, "track.plays") } == expectedTrackPlays.map { Optional($0) } && inheritedRows?.rows.map { iNumber($0, "album.plays") } == expectedAlbumPlays && inheritedRows?.rows.map { iNumber($0, "artist.plays") } == expectedArtistPlays.map { Optional($0) })
            check("a play of a loved track says so, and a play of another does not", inheritedRows?.rows.map { row -> Bool? in if case .value(.bool(let b))? = row.cells[try! registry.resolve(QueryFieldRef("track.loved"), target: .scrobble).cacheKey] { b } else { nil } } == plays.map { Optional($0.trackName == "Song 1") })
            var loadedTrack = spec()
            loadedTrack.groups = [[QueryCondition("track.plays", .greaterThanOrEqual, [.number(3)])]]
            check("a condition on the track's plays keeps every play of a song heard at least three times", (try? evaluateWith(loadedTrack, snapshotsWithLoved))?.rows.count == plays.filter { p in plays.filter { $0.trackName == p.trackName && $0.artistName == p.artistName }.count >= 3 }.count)
            var throughPeriod = spec(columns: ["track.plays", "track.firstPlayed"])
            throughPeriod.period = QueryPeriod(from: at(8, 0), to: at(30, 0))
            let throughRows = try? evaluateWith(throughPeriod, snapshotsWithLoved)
            check("inside a period a play's track plays count the period's plays, as on the Tracks target", throughRows?.rows.compactMap { iNumber($0, "track.plays") }.sorted() == [1, 2, 2])
            var tagged = spec(columns: ["track.tags", "album.tags"])
            tagged.groups = [[QueryCondition("playedAt", .after, [.date(at(1, 0))])]]
            let taggedRows = try? evaluateWith(tagged, snapshotsWithLoved)
            let tagPending = taggedRows?.pendingEntities[.tags] ?? []
            check("a lookup that fills in a play's tags is asked for the track or album, not the play", !tagPending.isEmpty && tagPending.allSatisfy { $0.target != .scrobble && $0.at == 0 }, "\(tagPending.prefix(2))")

            // Listening sessions: plays each started within the gap of the one before, over the whole history.
            func sessionIndexes(_ source: [ScrobbleSnapshot], gapMinutes: Double) -> [Int] {
                var out: [Int] = []
                var current = -1
                for (i, p) in source.enumerated() {
                    if i == 0 || p.playedAt.timeIntervalSince(source[i - 1].playedAt) > gapMinutes * 60 { current += 1 }
                    out.append(current)
                }
                return out
            }
            func sessionColumns(_ gap: Double? = nil) -> [QueryFieldRef] {
                let parameters: [String: QueryValue] = gap.map { ["gapMinutes": .number($0)] } ?? [:]
                return ["sessionStart", "sessionPosition", "sessionSize", "sessionLength", "sessionArtists", "startsSession", "endsSession", "artistRun"].map { QueryFieldRef($0, parameters: parameters) }
            }
            func column(_ row: QueryRow, _ id: String, _ gap: Double? = nil) -> QueryCell {
                let ref = QueryFieldRef(id, parameters: gap.map { ["gapMinutes": .number($0)] } ?? [:])
                return row.cells[try! registry.resolve(ref, target: .scrobble).cacheKey] ?? .missing
            }
            func num(_ cell: QueryCell) -> Double? { if case .value(.number(let n)) = cell { n } else { nil } }
            var inSessions = spec()
            inSessions.sort(ascending: true)
            inSessions.columns = sessionColumns()
            let sessionRows = try? evaluate(inSessions)
            let mine = sessionIndexes(plays, gapMinutes: 30)
            let expectedPositions = plays.indices.map { i in Double(mine[..<(i + 1)].filter { $0 == mine[i] }.count) }
            let expectedSizes = plays.indices.map { i in Double(mine.filter { $0 == mine[i] }.count) }
            check("each play knows its place in its session: 1, 2, 3, then four sessions of one, with six sessions in all", sessionRows?.rows.map { num(column($0, "sessionPosition")) } == expectedPositions.map { Optional($0) } && Set(mine).count == 6, "\(String(describing: sessionRows?.rows.map { num(column($0, "sessionPosition")) }))")
            check("…and how many plays its session has", sessionRows?.rows.map { num(column($0, "sessionSize")) } == expectedSizes.map { Optional($0) })
            check("plays in a session share when it began, and the first play's own time is it", sessionRows?.rows.prefix(3).allSatisfy { date($0, "sessionStart") == at(3, 9) } == true && sessionRows?.rows.dropFirst(3).first.flatMap { date($0, "sessionStart") } == at(3, 21, 30))
            check("the first session lasted 8 minutes from its first play to its last, and had two artists", sessionRows?.rows.first.flatMap { num(column($0, "sessionLength")) } == 480 && sessionRows?.rows.first.flatMap { num(column($0, "sessionArtists")) } == 2)
            check("the plays in a row by one artist within a session: two by the first artist, then one by the next", sessionRows?.rows.prefix(3).map { num(column($0, "artistRun")) } == [2, 2, 1])
            check("a session starts and ends once each, as many times as an independent count finds", sessionRows?.rows.filter { column($0, "startsSession") == .value(.bool(true)) }.count == 6 && sessionRows?.rows.filter { column($0, "endsSession") == .value(.bool(true)) }.count == 6)
            // A longer gap joins the two plays either side of midnight.
            var longGap = spec()
            longGap.sort(ascending: true)
            longGap.columns = sessionColumns(120)
            let longRows = try? evaluate(longGap)
            let long = sessionIndexes(plays, gapMinutes: 120)
            check("with a 120-minute gap the Saturday night and Sunday morning plays are one session of two, five sessions in all", Set(long).count == 5 && longRows?.rows.map { num(column($0, "sessionSize", 120)) } == plays.indices.map { i in Double(long.filter { $0 == long[i] }.count) }.map { Optional($0) } && longRows?.rows.filter { column($0, "startsSession", 120) == .value(.bool(true)) }.count == 5)
            // Sessions reach back past a period.
            var inPeriod = spec(columns: ["playedAt"])
            inPeriod.period = QueryPeriod(from: at(3, 9, 6), to: at(3, 10))
            inPeriod.columns = [QueryFieldRef("playedAt"), QueryFieldRef("sessionPosition"), QueryFieldRef("sessionSize"), QueryFieldRef("startsSession")]
            let periodRows = try? evaluate(inPeriod)
            check("a play whose session began before the period is still its third play, of three", periodRows?.rows.count == 1 && periodRows?.rows.first.flatMap { num(column($0, "sessionPosition")) } == 3 && periodRows?.rows.first.flatMap { num(column($0, "sessionSize")) } == 3 && periodRows?.rows.first.map { column($0, "startsSession") } == .value(.bool(false)))
            var onePerSession = spec(columns: ["playedAt", "sessionSize"])
            onePerSession.groups = [[QueryCondition("startsSession", .isTrue)]]
            let starts = try? evaluate(onePerSession)
            check("“starts a session” lists one row for each session, newest first", starts?.rows.count == 6 && starts?.rows.compactMap { date($0, "playedAt") } == [at(12, 12), at(9, 1, 5), at(8, 23, 15), at(4, 14), at(3, 21, 30), at(3, 9)])
            var bigSessions = spec(columns: ["playedAt", "sessionSize"])
            bigSessions.groups = [[QueryCondition("sessionSize", .greaterThanOrEqual, [.number(3)])]]
            check("a condition on the session's size finds the three plays of the long one", (try? evaluate(bigSessions))?.rows.count == 3)
            check("the session fields have a gap setting, 30 minutes to begin with", registry.fields(for: .scrobble).filter { $0.id.hasPrefix("session") || $0.id == "artistRun" || $0.id.hasSuffix("Session") }.allSatisfy { $0.parameters.first?.id == "gapMinutes" && $0.parameters.first?.defaultValue == .number(30) })

            // The pieces around the target.
            check("scrobble fields are offered only for scrobbles, and items' fields are not", registry.fields(for: .scrobble).contains { $0.id == "playedAt" } && !registry.fields(for: .track).contains { $0.id == "playedAt" } && !registry.fields(for: .scrobble).contains { $0.id == "plays" })
            check("every scrobble field has a definition", registry.fields(for: .scrobble).allSatisfy { !$0.help.isEmpty })
            check("Ask does not offer the target yet", !QueryTarget.askTargets.contains(.scrobble) && QueryTarget.allCases.contains(.scrobble))
            var saved = spec()
            saved.groups = [[QueryCondition("artist", .textIs, [.text("Artist A")])]]
            let again = try? QuerySpec.decode(saved.encoded())
            check("a scrobble query survives saving", again?.target == .scrobble && again?.groups == saved.groups && again?.sorts == saved.sorts)
            // Switching target.
            var starting = QueryBuilderModel.defaultSpec(target: .track)
            starting.groups = [[QueryCondition("plays", .greaterThan, [.number(1)]), QueryCondition("name", .contains, [.text("Song")])]]
            let toPlays = QueryBuilderModel.switching(starting, to: .scrobble, registry: registry)
            check("switching to plays drops what doesn't apply, lists newest first and widens the limit", toPlays.removed >= 1 && toPlays.spec.groups.first?.count == 1 && sortsBy(toPlays.spec, "playedAt") && toPlays.spec.columns == [QueryFieldRef("playedAt")] && toPlays.spec.limit == 1000, "\(toPlays)")
            let back = QueryBuilderModel.switching(toPlays.spec, to: .track, registry: registry)
            check("switching back restores most played first, a hundred, and the usual columns", sortsBy(back.spec, "plays") && back.spec.limit == 100 && back.spec.columns == [QueryFieldRef("plays"), QueryFieldRef("lastPlayed")])

            // A copy of a real library, when there is one: the whole list, its order and its running counts against independent counts.
            let history = (try? await ScrobbleHistoryCache.shared.snapshots(container: container)) ?? []
            if history.count > 1000 {
                let listing = spec(columns: ["playedAt", "playGap", "listenNumber"])
                var everything = listing
                everything.limit = nil
                let started = Date()
                let result = try? evaluate(everything, plays: history)
                let seconds = Date().timeIntervalSince(started)
                print("      (real library: \(history.count.formatted()) plays listed in \(String(format: "%.2f", seconds)) s)")
                check("real library: one row for each play", result?.rows.count == history.count && result?.matchedCount == history.count, "\(result?.rows.count ?? -1) vs \(history.count)")
                check("real library: newest first, to the second", result?.rows.compactMap { date($0, "playedAt") } == history.reversed().map(\.playedAt))
                // Independent counts over a sample of plays: the gap and the Nth listen, recomputed from the raw history.
                var seen: [String: Int] = [:]
                var nth: [Int: Int] = [:]
                for (index, item) in history.enumerated() {
                    let k = item.artistName + "\u{0}" + item.trackName
                    seen[k, default: 0] += 1
                    nth[index] = seen[k]
                }
                let rowsOldestFirst = Array((result?.rows ?? []).reversed())
                var mismatches: [String] = []
                for index in stride(from: 0, to: history.count, by: max(1, history.count / 400)) where index < rowsOldestFirst.count {
                    let row = rowsOldestFirst[index]
                    let wantGap = index == 0 ? nil : max(0, history[index].playedAt.timeIntervalSince(history[index - 1].playedAt))
                    if number(row, "listenNumber") != nth[index].map(Double.init) || number(row, "playGap") != wantGap { mismatches.append("\(index)") }
                }
                check("real library: the gap and the Nth listen agree with a recount on 400 plays across the history", mismatches.isEmpty, mismatches.prefix(5).joined(separator: ", "))
                check("real library: listing every play takes a few seconds at most", seconds < 15, "\(seconds) s")
                do {
                    // Where the time goes, for the log only.
                    var snaps = QuerySnapshots()
                    snaps.weather = .empty
                    var t = Date()
                    func lap(_ name: String) { print("      (  \(name): \(String(format: "%.2f", Date().timeIntervalSince(t))) s)"); t = Date() }
                    let counted = recentSpecCounted(history)
                    lap("count the plays the query keeps")
                    let probe = QueryRun(target: .scrobble, asOf: asOf, scrobbles: counted, allTimeScrobbles: history, snapshots: snaps)
                    _ = probe.universe
                    lap("build the universe")
                    let validatedProbe = try? listing.validate(against: registry)
                    lap("validate")
                    if let validatedProbe { _ = QueryEngine.evaluate(validatedProbe, run: probe); lap("evaluate (universe cached)") }
                }
                var recent = listing
                recent.limit = QuerySpec.scrobbleLimit
                let t2 = Date()
                let recentResult = try? evaluate(recent, plays: history)
                let recentSeconds = Date().timeIntervalSince(t2)
                print("      (real library: the newest \(QuerySpec.scrobbleLimit) in \(String(format: "%.2f", recentSeconds)) s)")
                // Inherited fields against an independent recount over the whole library, on the newest thousand plays.
                var inheritedReal = spec(columns: ["track.plays", "album.plays", "artist.plays", "track.firstPlayed", "artist.lastPlayed"])
                inheritedReal.limit = 1000
                let inheritedStart = Date()
                let inheritedResult = try? evaluate(inheritedReal, plays: history)
                print("      (real library: five inherited columns on the newest 1000 in \(String(format: "%.2f", Date().timeIntervalSince(inheritedStart))) s)")
                var trackCounts: [String: Int] = [:], albumCounts: [String: Int] = [:], artistCounts: [String: Int] = [:]
                var trackFirst: [String: Date] = [:], artistLast: [String: Date] = [:]
                for s in history {
                    trackCounts[s.artistName + "\u{0}" + s.trackName, default: 0] += 1
                    if !s.albumName.isEmpty { albumCounts[s.artistName + "\u{0}" + s.albumName, default: 0] += 1 }
                    artistCounts[s.artistName, default: 0] += 1
                    let key = s.artistName + "\u{0}" + s.trackName
                    if trackFirst[key] == nil || s.playedAt < trackFirst[key]! { trackFirst[key] = s.playedAt }
                    if artistLast[s.artistName] == nil || s.playedAt > artistLast[s.artistName]! { artistLast[s.artistName] = s.playedAt }
                }
                var badCells: [String] = []
                for row in inheritedResult?.rows ?? [] {
                    let artist = row.entity.artist, trackKey = artist + "\u{0}" + row.entity.name
                    let albumName = history.first { $0.playedAt.timeIntervalSince1970 == row.entity.id.at && $0.trackName == row.entity.name && $0.artistName == artist }?.albumName ?? ""
                    func cell(_ id: String) -> QueryCell { row.cells[try! registry.resolve(QueryFieldRef(id), target: .scrobble).cacheKey] ?? .missing }
                    if cell("track.plays") != .value(.number(Double(trackCounts[trackKey] ?? -1))) { badCells.append("track.plays") }
                    if cell("album.plays") != (albumName.isEmpty ? .missing : .value(.number(Double(albumCounts[artist + "\u{0}" + albumName] ?? -1)))) { badCells.append("album.plays") }
                    if cell("artist.plays") != .value(.number(Double(artistCounts[artist] ?? -1))) { badCells.append("artist.plays") }
                    if cell("track.firstPlayed") != trackFirst[trackKey].map({ QueryCell.value(.date($0)) }) ?? .missing { badCells.append("track.firstPlayed") }
                    if cell("artist.lastPlayed") != artistLast[artist].map({ QueryCell.value(.date($0)) }) ?? .missing { badCells.append("artist.lastPlayed") }
                }
                check("real library: the newest thousand plays' track, album and artist counts and dates equal a recount over the whole library", badCells.isEmpty && inheritedResult?.rows.count == 1000, "\(badCells.prefix(4))")
                // Sessions on the whole library against an independent walk.
                var sessionQuery = spec(columns: ["sessionPosition", "sessionSize", "artistRun"])
                sessionQuery.limit = nil
                sessionQuery.sort(ascending: true)
                let sessionStarted = Date()
                let sessionResult = try? evaluate(sessionQuery, plays: history)
                print("      (real library: session fields on every play in \(String(format: "%.2f", Date().timeIntervalSince(sessionStarted))) s)")
                var begin = 0
                var wrong: [String] = []
                var sessionCount = 0
                var index = 0
                while index < history.count {
                    var end = index
                    while end + 1 < history.count, history[end + 1].playedAt.timeIntervalSince(history[end].playedAt) <= 1800 { end += 1 }
                    sessionCount += 1
                    for i in index...end where i % 37 == 0 {
                        guard let row = sessionResult?.rows[i] else { wrong.append("row \(i)"); continue }
                        var runStart = i, runEnd = i
                        while runStart > index, history[runStart - 1].artistName == history[i].artistName { runStart -= 1 }
                        while runEnd < end, history[runEnd + 1].artistName == history[i].artistName { runEnd += 1 }
                        let got = (column(row, "sessionPosition"), column(row, "sessionSize"), column(row, "artistRun"))
                        let want = (QueryCell.value(.number(Double(i - index + 1))), QueryCell.value(.number(Double(end - index + 1))), QueryCell.value(.number(Double(runEnd - runStart + 1))))
                        if got != want { wrong.append("\(i)") }
                    }
                    begin = index
                    index = end + 1
                }
                _ = begin
                check("real library: position, size and artist run agree with an independent walk on every 37th play (\(sessionCount.formatted()) sessions)", wrong.isEmpty && sessionResult?.rows.count == history.count, "\(wrong.prefix(5))")
                var startsOnly = spec(columns: ["playedAt"])
                startsOnly.limit = nil
                startsOnly.groups = [[QueryCondition("startsSession", .isTrue)]]
                check("real library: “starts a session” finds one play for each session", (try? evaluate(startsOnly, plays: history))?.rows.count == sessionCount)
                check("real library: the default query shows the newest thousand", recentResult?.rows.count == QuerySpec.scrobbleLimit && recentResult?.matchedCount == history.count)
            } else {
                print("      (no library copy here: the real-data cross-check was skipped)")
            }

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

private extension QuerySpec {
    /// Lists plays oldest first (a check reads them in the order they happened).
    mutating func sort(ascending: Bool) {
        sorts = [QuerySort(key: .field(QueryFieldRef("playedAt")), direction: ascending ? .ascending : .descending)]
    }
}
#endif
