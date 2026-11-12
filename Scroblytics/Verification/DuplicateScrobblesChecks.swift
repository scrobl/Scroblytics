#if DEBUG
import Foundation
import SwiftData

/// `SCROBLYTICS_DUPLICATES_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): Duplicate Scrobbles on made-up plays with
/// hand-worked answers, the Query hand-off through the real `QueryEngine`, and the Last.fm link wording. No network. Exits 0 on success.
///
/// `SCROBLYTICS_DUPLICATES_DUMP=<file>` runs it on the REAL history (a store copy on `SCROBLYTICS_STORE_PATH`) and writes one line per
/// run, so the runs can be compared with an independent count over the same store. `SCROBLYTICS_DUPLICATES_GAP=<seconds>` sets the
/// fixed gap (60 otherwise) and `SCROBLYTICS_DUPLICATES_NOLENGTHS=1` leaves every length out, so only the fixed gap decides. Changes nothing.
enum DuplicateScrobblesChecks {
    typealias Engine = DuplicateScrobblesEngine

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SCROBLYTICS_DUPLICATES_DUMP"] {
            HeadlessTask.run("duplicates-dump") {
                let plays = QueryIdentity.canonicalizingArtists(
                    try container.mainContext.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
                )
                let lengths = environment["SCROBLYTICS_DUPLICATES_NOLENGTHS"] != nil ? [:] : DurationEngine.loadSnapshot(context: container.mainContext).secondsLookup
                let gap = Int(environment["SCROBLYTICS_DUPLICATES_GAP"] ?? "") ?? 60
                let started = Date()
                let result = Engine.find(scrobbles: plays, lengths: lengths, options: Engine.Options(fallbackGapSeconds: gap))
                let elapsed = Date().timeIntervalSince(started)
                var out = ["PLAYS \(plays.count)", "RUNS \(result.clusters.count)", "EXTRA \(result.extraPlays)",
                           "CERTAIN \(result.certain.count)", "POSSIBLE \(result.possible.count)", String(format: "SECONDS %.2f", elapsed)]
                for cluster in result.clusters.sorted(by: { ($0.key, $0.first) < ($1.key, $1.first) }) {
                    out.append("RUN\t\(cluster.artist)\t\(cluster.track)\t\(cluster.confidence.rawValue)\t\(cluster.lengthSeconds.map(String.init) ?? "-")\t\(cluster.times.count)\t\(cluster.times.map { String(Int($0.timeIntervalSince1970)) }.joined(separator: ","))")
                }
                // The length the engine had for every song played more than once, so the same rule can be applied by an independent scan.
                var plays2: [String: Int] = [:]
                for play in plays { plays2[play.artistName + "\u{0}" + play.trackName, default: 0] += 1 }
                for (pair, count) in plays2 where count > 1 {
                    let parts = pair.components(separatedBy: "\u{0}")
                    if let seconds = lengths[DurationEngine.cacheKey(artist: parts[0], track: parts[1])] { out.append("LEN\t\(parts[0])\t\(parts[1])\t\(seconds)") }
                }
                try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                print("wrote \(path)")
                exit(0)
            }
            return
        }
        guard environment["SCROBLYTICS_DUPLICATES_CHECK"] != nil else { return }
        HeadlessTask.run("duplicates-check") {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            SongMatchingSettings.setForTesting(TitleFolding(editionNotes: true, recordingVersions: false, contentRatings: true))
            defer { SongMatchingSettings.setForTesting(nil) }
            engineChecks(check)
            foldingChecks(check)
            crossCheck(check)
            handoffChecks(check)
            wordingChecks(check)
            HeadlessTask.finish(failures)
        }
    }

    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private static func play(_ artist: String, _ track: String, _ album: String = "Album X", at seconds: Double) -> ScrobbleSnapshot {
        ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: nil, playedAt: origin.addingTimeInterval(seconds))
    }
    private static func key(_ artist: String, _ track: String) -> String { DurationEngine.cacheKey(artist: artist, track: track) }
    private static func find(_ plays: [ScrobbleSnapshot], lengths: [String: Int] = [:], gap: Int = 60) -> Engine.Result {
        Engine.find(scrobbles: plays.sorted { $0.playedAt < $1.playedAt }, lengths: lengths, options: Engine.Options(fallbackGapSeconds: gap))
    }

    // MARK: - The rule

    private static func engineChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let long = [key("Artist A", "Song 1"): 200]
        func verdict(_ gap: Double, length: Int = 200) -> Engine.Confidence? {
            let plays = [play("Artist A", "Song 1", at: 0), play("Artist A", "Song 1", at: gap)]
            return find(plays, lengths: [key("Artist A", "Song 1"): length]).clusters.first?.confidence
        }

        // Known length 200 s: under half (100 s) is certain, up to 90% (180 s) is possible, beyond that is a repeat played through.
        var result = find([play("Artist A", "Song 1", at: 0), play("Artist A", "Song 1", at: 50)], lengths: long)
        check("a song replayed 50 s in, length 200 s, is one certain run with one extra play and the length noted",
              result.clusters.count == 1 && result.clusters[0].confidence == .certain && result.clusters[0].lengthSeconds == 200 && result.extraPlays == 1)
        check("…99 s in is certain, exactly half the length is not", verdict(99) == .certain && verdict(100) == .possible)
        check("…150 s and 179 s in are possible", verdict(150) == .possible && verdict(179) == .possible)
        check("…180 s in (90%) and 195 s in are a repeat played straight through, so not flagged", verdict(180) == nil && verdict(195) == nil && verdict(200) == nil && verdict(250) == nil)

        // Four-minute cap: a long song's certain zone stops at 240 s, not half its length.
        check("a 1,000 s song: 239 s is certain, 240 s possible, 899 s possible, 900 s not flagged",
              verdict(239, length: 1_000) == .certain && verdict(240, length: 1_000) == .possible && verdict(899, length: 1_000) == .possible && verdict(900, length: 1_000) == nil)

        // A known short length is never replaced by the fixed gap.
        check("a 40 s song: 19 s is certain, 25 s possible, 36 s and 50 s not flagged (the 60 s fixed gap does not apply to a known length)",
              verdict(19, length: 40) == .certain && verdict(25, length: 40) == .possible && verdict(36, length: 40) == nil && verdict(50, length: 40) == nil)
        check("an hour-long mix replayed 200 s in is certain, 30 minutes in possible, 54 minutes in not flagged",
              verdict(200, length: 3_600) == .certain && verdict(1_800, length: 3_600) == .possible && verdict(3_240, length: 3_600) == nil)

        // No known length: the fixed gap.
        result = find([play("Artist A", "Song 3", at: 0), play("Artist A", "Song 3", at: 59)])
        check("with no length, 59 s apart is a possible run under the default 60 s", result.clusters.count == 1 && result.clusters[0].confidence == .possible && result.clusters[0].lengthSeconds == nil)
        result = find([play("Artist A", "Song 3", at: 0), play("Artist A", "Song 3", at: 60)])
        check("…exactly 60 s apart is not", result.clusters.isEmpty)
        result = find([play("Artist A", "Song 3", at: 0), play("Artist A", "Song 3", at: 45)], gap: 30)
        check("…and a 30 s fixed gap leaves 45 s apart alone", result.clusters.isEmpty)
        result = find([play("Artist A", "Song 3", at: 0), play("Artist A", "Song 3", at: 100)], gap: 120)
        check("…while a 120 s fixed gap flags 100 s apart", result.clusters.count == 1)
        result = find([play("Artist A", "Song 3", at: 0), play("Artist A", "Song 3", at: 5)], lengths: [key("Artist A", "Song 3"): 0])
        check("a recorded length of 0 counts as unknown", result.clusters.count == 1 && result.clusters[0].confidence == .possible && result.clusters[0].lengthSeconds == nil)

        // Runs.
        result = find([play("Artist A", "Song 4", at: 0), play("Artist A", "Song 4", at: 10), play("Artist A", "Song 4", at: 20)])
        check("three plays 10 s apart are one run with two extra plays", result.clusters.count == 1 && result.clusters[0].times.count == 3 && result.extraPlays == 2)
        check("…whose first play is the one to keep, with the smallest gap and summary worked out",
              result.clusters.first?.first == origin && result.clusters.first?.smallestGap == 10 && result.clusters.first.map(Engine.summary) == "3 plays within 20 seconds")
        result = find([play("Artist A", "Song 4", at: 0), play("Artist A", "Song 4", at: 10), play("Artist A", "Song 4", at: 500)])
        check("a later play that is far away is not part of the run", result.clusters.count == 1 && result.clusters[0].times.count == 2)
        result = find([play("Artist A", "Song 4", at: 0), play("Artist A", "Song 4", at: 10), play("Artist A", "Song 4", at: 500), play("Artist A", "Song 4", at: 505)])
        check("two separate pairs are two runs, newest first", result.clusters.count == 2 && result.clusters[0].first > result.clusters[1].first && result.extraPlays == 2)
        result = find([play("Artist A", "Song 4", at: 0), play("Artist A", "Song 4", at: 50), play("Artist A", "Song 4", at: 100)])
        check("a run continues while each neighbouring gap is short, even when the whole run is longer than the limit", result.clusters.count == 1 && result.clusters[0].times.count == 3)
        let pair = find([play("Artist A", "Song 4", at: 0), play("Artist A", "Song 4", at: 50)])
        check("a pair\u{2019}s summary reads \u{201C}2 plays 50 seconds apart\u{201D}", pair.clusters.first.map(Engine.summary) == "2 plays 50 seconds apart")

        // A run is certain when any of its pairs is.
        let twoSteps = [key("Artist A", "Song 13"): 200]
        result = find([play("Artist A", "Song 13", at: 0), play("Artist A", "Song 13", at: 150), play("Artist A", "Song 13", at: 160)], lengths: twoSteps)
        check("a run with a possible pair and a certain pair is certain", result.clusters.count == 1 && result.clusters[0].times.count == 3 && result.clusters[0].confidence == .certain)
        result = find([play("Artist A", "Song 13", at: 0), play("Artist A", "Song 13", at: 150), play("Artist A", "Song 13", at: 300)], lengths: twoSteps)
        check("…and one made only of possible pairs is possible", result.clusters.count == 1 && result.clusters[0].times.count == 3 && result.clusters[0].confidence == .possible)
        result = find([play("Artist A", "Song 13", at: 0), play("Artist A", "Song 13", at: 195), play("Artist A", "Song 13", at: 390)], lengths: twoSteps)
        check("three back-to-back repeats of a 200 s song, each 195 s after the last, are not flagged", result.clusters.isEmpty)

        // What is not a duplicate.
        result = find([play("Artist A", "Song 5", at: 0), play("Artist A", "Song 6", at: 5), play("Artist B", "Song 5", at: 10)])
        check("different songs, and the same title by another artist, never form a run", result.clusters.isEmpty)
        result = find([play("Artist A", "", at: 0), play("Artist A", "", at: 3)])
        check("plays with no title are ignored", result.clusters.isEmpty)
        result = find([play("Artist A", "Song 7", at: 0)])
        check("a song played once cannot be a duplicate", result.clusters.isEmpty)
        result = find([play("Artist A", "Song 8", "Album X", at: 0), play("Artist A", "Song 8", "Album Y", at: 4)])
        check("the same song on two albums is one run", result.clusters.count == 1 && result.clusters[0].album == "Album X")
        result = find([play("Artist A", "Song 8", "", at: 0), play("Artist A", "Song 8", "Album Y", at: 4)])
        check("…whose album is the first one that has a name", result.clusters.first?.album == "Album Y")
        result = find([play("Artist A", "SONG 9", at: 0), play("Artist A", "song 9", at: 4)])
        check("letter case does not make a different song", result.clusters.count == 1)

        // A length found under the other play's spelling.
        result = find([play("Artist A", "Song 10", at: 0), play("Artist A", "Song 10 (Remastered)", at: 100)], lengths: [key("Artist A", "Song 10 (Remastered)"): 240])
        check("a length known only under the later spelling still judges the pair", result.clusters.count == 1 && result.clusters[0].confidence == .certain && result.clusters[0].lengthSeconds == 240)
    }

    // MARK: - Song matching settings

    private static func foldingChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let plays = [play("Artist A", "Song 11", at: 0), play("Artist A", "Song 11 (Remastered 2011)", at: 20)]
        var result = find(plays)
        check("with edition notes folded, a song and its remaster played 20 s apart are one run naming both titles",
              result.clusters.count == 1 && Set(result.clusters[0].titles) == ["Song 11", "Song 11 (Remastered 2011)"])
        SongMatchingSettings.setForTesting(TitleFolding(editionNotes: false, recordingVersions: false, contentRatings: true))
        result = find(plays)
        check("…and not when edition notes are kept apart", result.clusters.isEmpty)
        SongMatchingSettings.setForTesting(TitleFolding(editionNotes: true, recordingVersions: false, contentRatings: true))
        result = find([play("Artist A", "Song 12", at: 0), play("Artist A", "Song 12 (Instrumental)", at: 20)])
        check("an instrumental version is a different song by default, so no run", result.clusters.isEmpty)
        SongMatchingSettings.setForTesting(TitleFolding(editionNotes: true, recordingVersions: true, contentRatings: true))
        result = find([play("Artist A", "Song 12", at: 0), play("Artist A", "Song 12 (Instrumental)", at: 20)])
        check("…and the same song once instrumental versions are matched with the plain one", result.clusters.count == 1)
        SongMatchingSettings.setForTesting(TitleFolding(editionNotes: true, recordingVersions: false, contentRatings: true))
    }

    // MARK: - Independent count

    /// Many plays of a few made-up songs at random gaps, compared with a plain scan that shares no code with the engine: for each
    /// song, a play is an extra when the play before it started less than the limit earlier. The sets of extra plays must be equal.
    private static func crossCheck(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let artists = ["Artist A", "Artist B", "Artist C"]
        let titles = (1...12).map { "Cross Song \($0)" }
        var lengths: [String: Int] = [:]
        for (index, title) in titles.enumerated() where index % 3 != 0 { lengths[key("Artist A", title)] = 30 + next(300) }
        for title in titles { lengths[key("Artist B", title)] = nil }
        var plays: [ScrobbleSnapshot] = []
        var clock = 0.0
        for _ in 0..<4_000 {
            clock += Double([0, 1, 2, 3, 5, 8, 20, 45, 70, 130, 400, 3_600][next(12)]) + Double(next(2))
            plays.append(play(artists[next(artists.count)], titles[next(titles.count)], at: clock))
        }
        let sorted = plays.sorted { $0.playedAt < $1.playedAt }
        let result = Engine.find(scrobbles: sorted, lengths: lengths, options: Engine.Options(fallbackGapSeconds: 60))

        // Independent scan: for each song, a play is an extra when the play before it started closer than the song allows.
        var expected: [String: Engine.Confidence] = [:]
        var previous: [String: ScrobbleSnapshot] = [:]
        for p in sorted {
            let song = p.artistName + "|" + p.trackName
            if let before = previous[song] {
                let gap = p.playedAt.timeIntervalSince(before.playedAt)
                let slot = song + "|" + String(Int(p.playedAt.timeIntervalSince1970))
                if let length = lengths[key(p.artistName, p.trackName)] {
                    if gap < min(Double(length) / 2, 240) { expected[slot] = .certain } else if gap < Double(length) * 0.9 { expected[slot] = .possible }
                } else if gap < 60 {
                    expected[slot] = .possible
                }
            }
            previous[song] = p
        }
        var found = Set<String>()
        for cluster in result.clusters {
            for time in cluster.times.dropFirst() { found.insert(cluster.artist + "|" + cluster.track + "|" + String(Int(time.timeIntervalSince1970))) }
        }
        let certainSlots = Set(expected.filter { $0.value == .certain }.keys)
        let certainRunsAreRight = result.clusters.allSatisfy { cluster in
            let extras = cluster.times.dropFirst().map { cluster.artist + "|" + cluster.track + "|" + String(Int($0.timeIntervalSince1970)) }
            return (cluster.confidence == .certain) == extras.contains { certainSlots.contains($0) }
        }
        check("4,000 random plays: the extra plays found are exactly those an independent scan finds (\(expected.count))", found == Set(expected.keys) && !expected.isEmpty, "found \(found.count), expected \(expected.count)")
        check("…and the extras counted equal them", result.extraPlays == expected.count)
        check("…with every run's plays in time order and its first play kept", result.clusters.allSatisfy { $0.times == $0.times.sorted() && $0.times.count >= 2 })
        check("…and runs newest first", zip(result.clusters, result.clusters.dropFirst()).allSatisfy { $0.last >= $1.last })
        check("…and a run is certain exactly when one of its extras is certain by the independent scan", certainRunsAreRight)
        check("…and certain plus possible runs make up all of them", result.certain.count + result.possible.count == result.clusters.count && !result.certain.isEmpty && !result.possible.isEmpty)
    }

    // MARK: - Query hand-off

    @MainActor
    private static func handoffChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let calendar = AppCalendars.listening
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2025, month: 3, day: day, hour: hour, minute: minute, second: second))!
        }
        func make(_ track: String, _ artist: String, _ date: Date) -> ScrobbleSnapshot {
            ScrobbleSnapshot(artistName: artist, albumName: "Album X", trackName: track, imageURL: nil, playedAt: date)
        }
        let plays = [
            make("Song 1", "Artist A", at(2, 9)),                 // another day: outside the run's days
            make("Song 1", "Artist A", at(3, 9, 0, 0)),
            make("Song 1", "Artist A", at(3, 9, 0, 4)),           // the extra
            make("Song 1 (Remastered)", "Artist A", at(3, 20)),   // same day, other spelling of the song
            make("Song 2", "Artist A", at(3, 9, 0, 2)),           // another song, same time
            make("Song 1", "Artist B", at(3, 9, 0, 3)),           // same title, other artist
            make("Song 1", "Artist A", at(5, 9)),                 // after
        ].sorted { $0.playedAt < $1.playedAt }
        let result = Engine.find(scrobbles: plays, lengths: [:], options: Engine.Options())
        check("the made-up history has one run, Song 1 by Artist A on the 3rd", result.clusters.count == 1 && result.clusters[0].track == "Song 1" && result.clusters[0].artist == "Artist A")
        guard let cluster = result.clusters.first else { return }
        let spec = Engine.spec(for: cluster, calendar: calendar)
        check("the hand-off asks for single plays, oldest first", spec.target == .scrobble && spec.sorts.first?.direction == .ascending)
        check("…over the days the run spans (the 3rd, to the second before the 4th)", spec.period == QueryPeriod(from: at(3, 0), to: at(4, 0).addingTimeInterval(-1)))
        do {
            let registry = QueryFieldRegistry.standard
            let validated = try spec.validate(against: registry)
            let run = QueryRun(target: .scrobble, asOf: at(20, 12), scrobbles: spec.countedPlays(plays), allTimeScrobbles: plays, snapshots: QuerySnapshots(), sessionGapMinutes: Double(spec.effectiveSessionGapMinutes))
            let rows = QueryEngine.evaluate(validated, run: run).rows
            // The plays of that song by that artist on that day, counted independently.
            let expected = plays.filter { $0.artistName == "Artist A" && $0.trackName == "Song 1" && calendar.isDate($0.playedAt, inSameDayAs: at(3, 12)) }
            check("running it in Query lists exactly the song’s plays on those days (\(expected.count)), not other songs, artists or days", rows.count == expected.count && expected.count == 2, "\(rows.count)")
            check("…and the run’s first and extra play are both there", rows.map { Date(timeIntervalSince1970: $0.entity.id.at) } == expected.map(\.playedAt))
        } catch {
            check("the hand-off is a valid query", false, "\(error)")
        }

        // Two spellings in one run: both titles are asked for.
        let folded = Engine.find(scrobbles: [make("Song 3", "Artist A", at(3, 9)), make("Song 3 (Remastered)", "Artist A", at(3, 9, 0, 20))], lengths: [:], options: Engine.Options())
        if let c = folded.clusters.first {
            let s = Engine.spec(for: c, calendar: calendar)
            check("a run under two spellings asks for each of them (one group per title)", s.groups.count == 2)
            let library = [make("Song 3", "Artist A", at(3, 9)), make("Song 3 (Remastered)", "Artist A", at(3, 9, 0, 20)), make("Song 4", "Artist A", at(3, 9, 0, 30))]
            if let validated = try? s.validate(against: QueryFieldRegistry.standard) {
                let run = QueryRun(target: .scrobble, asOf: at(20, 12), scrobbles: s.countedPlays(library), allTimeScrobbles: library, snapshots: QuerySnapshots(), sessionGapMinutes: Double(s.effectiveSessionGapMinutes))
                check("…and Query then lists both plays of the song and not the other song", QueryEngine.evaluate(validated, run: run).rows.count == 2)
            } else {
                check("the two-spelling hand-off is a valid query", false)
            }
        } else {
            check("two spellings fold into one run", false)
        }
    }

    // MARK: - Wording and links

    private static func wordingChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        check("durations read as seconds under a minute and m:ss after", Engine.durationText(4) == "4 seconds" && Engine.durationText(1) == "1 second" && Engine.durationText(225) == "3:45 min" && Engine.durationText(60) == "1:00 min")
        let known = Engine.Cluster(key: "k", artist: "A", track: "T", album: "", titles: ["T"], imageURL: nil, times: [origin, origin.addingTimeInterval(5)], lengthSeconds: 225, confidence: .certain)
        let unknown = Engine.Cluster(key: "k", artist: "A", track: "T", album: "", titles: ["T"], imageURL: nil, times: [origin, origin.addingTimeInterval(5)], lengthSeconds: nil, confidence: .possible)
        check("the length line names the length, or says it is unknown and the gap used", Engine.lengthText(known, fallbackGapSeconds: 60) == "Length 3:45 min · closest gap 2% of it" && Engine.lengthText(unknown, fallbackGapSeconds: 90) == "Length unknown · under 90 s")

        let url = LastfmUserLinks.songHistoryURL(username: "some_user", artist: "Artist & Co/1", track: "What? #1 (live)")
        check("the Last.fm song history link has the user, library, artist and title as separate encoded segments",
              url?.absoluteString == "https://www.last.fm/user/some_user/library/music/Artist+%26+Co%2F1/_/What%3F+%231+%28live%29", url?.absoluteString ?? "nil")
        check("…and an ordinary name reads plainly", LastfmUserLinks.songHistoryURL(username: "some_user", artist: "Artist A", track: "Song 1")?.absoluteString == "https://www.last.fm/user/some_user/library/music/Artist+A/_/Song+1")
    }
}
#endif
