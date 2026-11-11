#if DEBUG
import Foundation
import SwiftData

/// Checks for Unscrobbled Plays on made-up data, plus a dump of the real library for comparing against an independent count.
/// `SCROBLYTICS_UNSCROBBLED_CHECK=1` runs the checks; `SCROBLYTICS_UNSCROBBLED_DUMP=<file>` writes the real result.
enum UnscrobbledPlaysChecks {
    typealias Engine = UnscrobbledPlaysEngine
    typealias ToolView = UnscrobbledPlaysView

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SCROBLYTICS_UNSCROBBLED_DUMP"] {
            HeadlessTask.run("unscrobbled-dump") {
                let inputs = try await UnscrobbledPlaysRunner.read(container: container)
                var out: [String] = []
                out.append("MUSIC_TRACKS \(inputs.music.library.count)")
                out.append("SYNCED_THROUGH \(inputs.syncedThrough.map { Int($0.timeIntervalSince1970) } ?? -1)")
                for (label, variants) in [("VARIANTS_ON", true), ("VARIANTS_OFF", false)] {
                    let r = Engine.evaluate(inputs, matchVariants: variants)
                    out.append("\(label) compared=\(r.compared) upToDate=\(r.upToDate) notScrobbled=\(r.notScrobbled.count) timeDiffers=\(r.timeDiffers.count) tooRecent=\(r.tooRecent) beforeFirst=\(r.beforeFirstScrobble)")
                    out.append("\(label)_NEVER \(r.notScrobbled.filter { $0.kind == .neverScrobbled }.count)")
                    out.append("\(label)_WITH_VARIANT_NOTE \(r.notScrobbled.filter { $0.variantSpelling != nil }.count)")
                    for row in (r.notScrobbled + r.timeDiffers).sorted(by: { $0.id < $1.id }) {
                        out.append("ROW_\(label)\t\(row.artist)\t\(row.track)\t\(Int(row.musicLastPlayed.timeIntervalSince1970))\t\(row.lastScrobble.map { Int($0.timeIntervalSince1970) } ?? -1)\t\(row.scrobbles)\t\(row.musicPlays)\t\(row.shiftHours.map(String.init) ?? "-")\t\(row.kind == .neverScrobbled ? "never" : "later")")
                    }
                }
                // Played dates as the reader returned them, one per distinct song, for an independent comparison.
                for t in inputs.music.library where t.lastPlayedAt != nil {
                    out.append("PLAYED\t\(t.artist)\t\(t.name)\t\(Int(t.lastPlayedAt!.timeIntervalSince1970))\t\(t.playCount)")
                }
                try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                print("wrote \(path)")
                exit(0)
            }
            return
        }
        if let out = environment["SCROBLYTICS_SCROBBLE_E2E_OUT"], environment["SCROBLYTICS_SCROBBLE_E2E"] != nil {
            HeadlessTask.run("scrobble-e2e") { await scrobbleEndToEnd(outputPath: out) }
            return
        }
        guard environment["SCROBLYTICS_UNSCROBBLED_CHECK"] != nil else { return }
        HeadlessTask.run("unscrobbled-check") {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            classificationChecks(check)
            variantChecks(check)
            songChecks(check)
            listChecks(check)
            await scrobbleChecks(check)
            crossCheck(check)
            HeadlessTask.finish(failures)
        }
    }

    // MARK: Against the stand-in server

    /// Submits made-up plays through the real client to the stand-in Last.fm server (`scripts/scrobble-test.sh` starts it and runs
    /// this under a test profile), and writes what happened to `outputPath`. It refuses to run unless the Last.fm address is on this
    /// Mac, so it can never reach a real account. The stand-in checks each request's signature on its own and keeps what it accepted.
    @MainActor
    private static func scrobbleEndToEnd(outputPath: String) async {
        var lines: [String] = []
        func finish(_ code: Int32) -> Never {
            try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
            exit(code)
        }
        guard ConnectivityGate.isLoopback(host: LastfmEndpoint.host) else {
            lines.append("REFUSED the Last.fm address is not on this Mac: \(LastfmEndpoint.host ?? "nil")")
            finish(2)
        }
        let secret = "scrobblesecret", apiKey = "e2ekey", sessionKey = "e2esession"
        let now = Date()
        // Awkward names (symbols, quotes, accents, other scripts, stray spaces) first, then ordinary ones: 55 plays in all, so two batches.
        var plays: [UnscrobbledPlaysScrobbling.Play] = [
            ("Artist & Co.", "Song + Plus % Percent \"Quoted\", with comma", "Album: Ünï / Café"),
            ("日本語アーティスト", "テスト曲", ""),
            (" Spaced Artist ", " spaced   title ", "Album"),
        ].enumerated().map { i, n in
            UnscrobbledPlaysScrobbling.Play(id: "e\(i)", artist: n.0, track: n.1, album: n.2, playedAt: now.addingTimeInterval(-Double(i + 1) * 600), neverScrobbled: true)
        }
        for i in 3..<55 {
            plays.append(UnscrobbledPlaysScrobbling.Play(id: "e\(i)", artist: "Artist \(i % 7)", track: "Track \(i)", album: "Album \(i % 5)", playedAt: now.addingTimeInterval(-Double(i + 1) * 600), neverScrobbled: i % 2 == 0))
        }
        for play in UnscrobbledPlaysScrobbling.submissions(plays) {
            lines.append("EXPECTED\t\(play.artist)\t\(play.track)\t\(play.album ?? "")\t\(play.timestamp)")
        }
        let report = await UnscrobbledPlaysScrobbling.submit(plays, send: UnscrobbledPlaysScrobbling.sender(apiKey: apiKey, secret: secret, sessionKey: sessionKey), pause: .milliseconds(50))
        lines.append("ACCEPTED \(report.accepted.count)")
        lines.append("IGNORED \(report.ignored.count)")
        lines.append("NOTSENT \(report.notSent.count)")
        lines.append("FAILURE \(report.failure ?? "none")")
        // A play too old for Last.fm, sent straight through the client (the screen never offers one): an ignore code, not an error.
        do {
            let old = try await LastfmWriteClient.scrobble(apiKey: apiKey, secret: secret, sessionKey: sessionKey, plays: [
                .init(artist: "Old Artist", track: "Old Track", album: nil, timestamp: Int(now.addingTimeInterval(-20 * 86_400).timeIntervalSince1970)),
            ])
            lines.append("OLD accepted=\(old.first?.accepted ?? true) code=\(old.first?.ignoredCode.map(String.init) ?? "none")")
        } catch {
            lines.append("OLD error \(error)")
        }
        // A wrong secret must be refused (signature error 13), and nothing may be kept.
        do {
            _ = try await LastfmWriteClient.scrobble(apiKey: apiKey, secret: "wrong-secret", sessionKey: sessionKey, plays: [
                .init(artist: "Wrong Secret", track: "Wrong Secret", album: nil, timestamp: Int(now.timeIntervalSince1970)),
            ])
            lines.append("WRONGSECRET accepted")
        } catch let LastfmAPIError.api(code, _) {
            lines.append("WRONGSECRET api \(code)")
        } catch {
            lines.append("WRONGSECRET other \(error)")
        }
        finish(0)
    }

    // MARK: Made-up data

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// The history starts a long time before the plays below and was last synced a day after them.
    private static let firstScrobble = t0.addingTimeInterval(-400 * 86_400)
    private static let synced = t0.addingTimeInterval(86_400)

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func scrobble(_ artist: String, _ track: String, _ time: Date) -> ScrobbleSnapshot {
        ScrobbleSnapshot(artistName: artist, albumName: "Album", trackName: track, imageURL: nil, playedAt: time)
    }

    private static func song(_ artist: String, _ name: String, played: Date?, plays: Int = 1, cloud: String = "") -> AppleMusicSnapshot.Track {
        AppleMusicSnapshot.Track(name: name, artist: artist, album: "Album", cloudStatus: cloud, lastPlayedAt: played, playCount: plays)
    }

    private static func music(_ tracks: [AppleMusicSnapshot.Track]) -> AppleMusicSnapshot {
        AppleMusicSnapshot(favorites: [], library: tracks, source: .favoritedFlag, readSeconds: 0)
    }

    /// A history that begins long before the plays under test, so none of them is "before the first scrobble".
    private static func history(_ extra: [ScrobbleSnapshot]) -> [ScrobbleSnapshot] {
        [scrobble("Artist Z", "Old Song", firstScrobble)] + extra
    }

    private static func run(_ tracks: [AppleMusicSnapshot.Track], _ scrobbles: [ScrobbleSnapshot], variants: Bool = true) -> Engine.Result {
        Engine.compute(scrobbles: history(scrobbles), music: music(tracks), matchVariants: variants, syncedThrough: synced, now: t0)
    }

    private static func row(_ r: Engine.Result, _ track: String) -> Engine.Row? {
        (r.notScrobbled + r.timeDiffers).first { $0.track == track }
    }

    // MARK: Classification

    private static func classificationChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let p = at(0)
        let r = run(
            [
                song("A", "Exact", played: p), song("A", "Within Tolerance", played: p), song("A", "Just Late", played: p),
                song("A", "Never", played: p),
                song("A", "Ten Hours", played: p), song("A", "Ten Hours Five Min", played: p), song("A", "Ten Hours Twenty Min", played: p),
                song("A", "Two Hours", played: p), song("A", "One Hour", played: p), song("A", "Fourteen Hours", played: p), song("A", "Fifteen Hours", played: p),
                song("A", "Unplayed", played: nil),
            ],
            [
                scrobble("A", "Exact", p), scrobble("A", "Within Tolerance", at(-300)), scrobble("A", "Just Late", at(-1200)),
                scrobble("A", "Ten Hours", at(-36_000)), scrobble("A", "Ten Hours Five Min", at(-36_300)), scrobble("A", "Ten Hours Twenty Min", at(-37_200)),
                scrobble("A", "Two Hours", at(-7200)), scrobble("A", "One Hour", at(-3600)), scrobble("A", "Fourteen Hours", at(-50_400)), scrobble("A", "Fifteen Hours", at(-54_000)),
            ]
        )
        check("a scrobble at the played date agrees", row(r, "Exact") == nil)
        check("a scrobble 5 minutes before the played date still agrees", row(r, "Within Tolerance") == nil)
        check("a scrobble 20 minutes before is a missed play, with its gap", row(r, "Just Late")?.kind == .playedAfterLastScrobble && row(r, "Just Late")?.gap == 1200 && row(r, "Just Late")?.shiftHours == nil)
        check("a song with no scrobble at all is never scrobbled", row(r, "Never")?.kind == .neverScrobbled && row(r, "Never")?.lastScrobble == nil && row(r, "Never")?.scrobbles == 0)
        check("exactly 10 hours is a time difference, not a missed play", row(r, "Ten Hours")?.shiftHours == 10 && r.timeDiffers.contains { $0.track == "Ten Hours" })
        check("10 hours and 5 minutes is still that time difference", row(r, "Ten Hours Five Min")?.shiftHours == 10)
        check("10 hours and 20 minutes is not a whole-hour shift, so it is a missed play", row(r, "Ten Hours Twenty Min")?.shiftHours == nil && r.notScrobbled.contains { $0.track == "Ten Hours Twenty Min" })
        check("1, 2 and 14 hours are time differences; 15 is not", row(r, "One Hour")?.shiftHours == 1 && row(r, "Two Hours")?.shiftHours == 2 && row(r, "Fourteen Hours")?.shiftHours == 14 && row(r, "Fifteen Hours")?.shiftHours == nil)
        check("a song Music never played is left out of everything", row(r, "Unplayed") == nil && r.compared == 11, "compared \(r.compared)")
        check("the counts add up", r.compared == r.upToDate + r.notScrobbled.count + r.timeDiffers.count, "\(r.compared) vs \(r.upToDate) + \(r.notScrobbled.count) + \(r.timeDiffers.count)")
        check("two songs agree, four are missed plays and five are time differences", r.upToDate == 2 && r.notScrobbled.count == 4 && r.timeDiffers.count == 5, "\(r.upToDate) \(r.notScrobbled.count) \(r.timeDiffers.count)")

        // Before the first scrobble, and too recent to judge.
        let early = Engine.compute(
            scrobbles: [scrobble("A", "Other", at(-1000))], music: music([song("A", "Early", played: at(-5000)), song("A", "Later", played: at(-500))]),
            matchVariants: true, syncedThrough: synced, now: t0
        )
        check("a song last played in Music before the first scrobble is not judged", early.beforeFirstScrobble == 1 && early.compared == 1 && row(early, "Early") == nil)
        check("the first scrobble date is reported", early.firstScrobble == at(-1000))
        let recent = Engine.compute(
            scrobbles: history([]), music: music([song("A", "Fresh", played: synced.addingTimeInterval(-120)), song("A", "Old Enough", played: synced.addingTimeInterval(-900))]),
            matchVariants: true, syncedThrough: synced, now: t0
        )
        check("a play within 5 minutes of the last sync is too recent to judge, and one 15 minutes before it is judged", recent.tooRecent == 1 && row(recent, "Fresh") == nil && row(recent, "Old Enough") != nil)
        check("the grace is 5 minutes", Engine.recentGrace == 300 && recent.judgedBefore == synced.addingTimeInterval(-300))
        check("the too-recent songs are listed, with when Music played them and their latest scrobble", recent.tooRecentSongs.map(\.track) == ["Fresh"] && recent.tooRecentSongs.first?.musicLastPlayed == synced.addingTimeInterval(-120) && recent.tooRecentSongs.first?.lastScrobble == nil)
        let boundary = Engine.compute(
            scrobbles: history([scrobble("A", "Edge", synced.addingTimeInterval(-1000))]),
            music: music([song("A", "Edge", played: synced.addingTimeInterval(-300)), song("A", "Just Inside", played: synced.addingTimeInterval(-299))]),
            matchVariants: true, syncedThrough: synced, now: t0
        )
        check("a play exactly 5 minutes before the sync is judged; one a second later is not", row(boundary, "Edge") != nil && boundary.tooRecentSongs.map(\.track) == ["Just Inside"])
        let several = Engine.compute(
            scrobbles: history([scrobble("A", "Seen", synced.addingTimeInterval(-100))]),
            music: music([song("A", "Seen", played: synced.addingTimeInterval(-100)), song("B", "Later", played: synced.addingTimeInterval(-10)), song("C", "Earlier", played: synced.addingTimeInterval(-200))]),
            matchVariants: true, syncedThrough: synced, now: t0
        )
        check("too-recent songs come newest first and say when a scrobble already exists", several.tooRecentSongs.map(\.track) == ["Later", "Seen", "Earlier"] && several.tooRecentSongs.first { $0.track == "Seen" }?.lastScrobble == synced.addingTimeInterval(-100) && several.tooRecent == several.tooRecentSongs.count, "\(several.tooRecentSongs.map(\.track))")
        let noSync = Engine.compute(
            scrobbles: history([scrobble("A", "Seen", at(0))]), music: music([song("A", "After Newest", played: at(0).addingTimeInterval(100))]),
            matchVariants: true, syncedThrough: nil, now: t0
        )
        check("with no sync time known, the newest scrobble stands in for it", noSync.tooRecent == 1, "\(noSync.tooRecent)")
        let none = Engine.compute(scrobbles: [], music: music([song("A", "X", played: at(0))]), matchVariants: true, syncedThrough: nil, now: t0)
        check("with no history at all nothing is compared", none.compared == 0 && none.notScrobbled.isEmpty && none.firstScrobble == nil)
    }

    // MARK: Spelling variants

    private static func variantChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let p = at(0)
        let tracks = [
            song("A", "Title", played: p),                       // scrobbled only as "Title (feat. Guest)"
            song("B", "Other Song", played: p),                  // an old identical scrobble, and a newer "(Remastered 2011)" one
            song("C", "Same Title", played: p),                  // scrobbled in different case and spacing
        ]
        let scrobbles = [
            scrobble("A", "Title (feat. Guest)", p),
            scrobble("B", "Other Song", at(-100_000)), scrobble("B", "Other Song (Remastered 2011)", p),
            scrobble("C", "same   title", p),
        ]
        let on = run(tracks, scrobbles, variants: true)
        let off = run(tracks, scrobbles, variants: false)
        check("with variants matched, a differently written scrobble counts", row(on, "Title") == nil && row(on, "Other Song") == nil)
        check("case and spacing never count as a variant, in either mode", row(on, "Same Title") == nil && row(off, "Same Title") == nil)
        check("with variants not matched, the song is listed as never scrobbled, and says how it was scrobbled",
              row(off, "Title")?.kind == .neverScrobbled && row(off, "Title")?.variantSpelling == "A — Title (feat. Guest)", "\(String(describing: row(off, "Title")?.variantSpelling))")
        check("with variants not matched, an older identical scrobble leaves it listed, naming the variant that would have counted",
              row(off, "Other Song")?.kind == .playedAfterLastScrobble && row(off, "Other Song")?.variantSpelling == "B — Other Song (Remastered 2011)")
        check("with variants matched, no row carries a variant note", (on.notScrobbled + on.timeDiffers).allSatisfy { $0.variantSpelling == nil })
        check("the scrobble count follows the matching in use", {
            let both = Engine.compute(scrobbles: history([scrobble("D", "Song", at(-10)), scrobble("D", "Song (Remastered 2011)", at(-9_000_000))]), music: music([song("D", "Song", played: at(0))]), matchVariants: true, syncedThrough: synced, now: t0)
            let only = Engine.compute(scrobbles: history([scrobble("D", "Song", at(-3000)), scrobble("D", "Song (Remastered 2011)", at(-9_000_000))]), music: music([song("D", "Song", played: at(0))]), matchVariants: false, syncedThrough: synced, now: t0)
            return both.upToDate == 1 && row(only, "Song")?.scrobbles == 1
        }())
        check("a note is only given when a variant exists", row(off, "Same Title") == nil && (off.notScrobbled + off.timeDiffers).filter { $0.variantSpelling != nil }.count == 2)
    }

    // MARK: Copies and details

    private static func songChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        // Two library copies: the later play decides, and the counts add up.
        let r = run(
            [song("A", "Twice", played: at(-5000), plays: 3, cloud: "uploaded"), song("A", "Twice", played: at(0), plays: 4, cloud: "subscription"),
             song("A", "Behind", played: at(0), plays: 2), song("A", "Behind", played: at(-9000), plays: 5)],
            [scrobble("A", "Twice", at(0)), scrobble("A", "Behind", at(-9000))]
        )
        check("two copies of a song are one: the later play is used, so it agrees", row(r, "Twice") == nil && r.compared == 2)
        let behind = row(r, "Behind")
        check("a song's Music plays are summed over its copies", behind?.musicPlays == 7 && behind?.musicLastPlayed == at(0), "\(String(describing: behind?.musicPlays))")
        check("the row carries the latest scrobble and how many there are", behind?.lastScrobble == at(-9000) && behind?.scrobbles == 1 && behind?.gap == 9000)
        check("the row opens the song under the spelling it was scrobbled with", {
            let x = run([song("A", "Title Here", played: at(0))], [scrobble("A", "title here", at(-2000))])
            return row(x, "Title Here")?.historyTrack == "title here" && row(x, "Title Here")?.historyArtist == "A"
        }())
        check("a streaming copy's cloud status is available for the row", row(run([song("A", "S", played: at(0), cloud: "subscription")], []), "S")?.cloudStatus == "subscription")

        // Months
        let months = Engine.byMonth(
            [at(0), at(86_400), at(-90 * 86_400), at(-90 * 86_400 + 3600), at(-91 * 86_400)].map { date in
                Engine.Row(id: "\(date)", artist: "A", track: "T", album: "", cloudStatus: "", musicLastPlayed: date, musicPlays: 1, lastScrobble: nil, scrobbles: 0,
                           kind: .neverScrobbled, historyArtist: nil, historyTrack: nil, gap: nil, shiftHours: nil, variantSpelling: nil, coveredByVariant: false)
            },
            calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
        )
        check("rows are grouped by the month Music last played them, newest month first", months.map(\.count).reduce(0, +) == 5 && months.count >= 2 && zip(months, months.dropFirst()).allSatisfy { $0.month > $1.month }, "\(months)")

        // Options
        check("saved options from an older version fill in defaults, with variants matched", {
            guard let o = try? JSONDecoder().decode(ToolView.Options.self, from: Data("{\"group\":\"timeDiffers\"}".utf8)) else { return false }
            return o.group == .timeDiffers && o.matchVariants && o.period == .anyTime && !o.hasRun
        }())
        check("options round-trip, including variants off", {
            var o = ToolView.Options(); o.matchVariants = false; o.period = .quarter; o.sort = .gap; o.filter = .never; o.hasRun = true
            guard let data = try? JSONEncoder().encode(o), let back = try? JSONDecoder().decode(ToolView.Options.self, from: data) else { return false }
            return back == o && !back.matchVariants
        }())
        check("an unknown saved value falls back to its default", {
            let o = try? JSONDecoder().decode(ToolView.Options.self, from: Data("{\"period\":\"someday\",\"sort\":\"nope\"}".utf8))
            return o?.period == .anyTime && o?.sort == .lastPlayed
        }())
        check("gaps read as minutes, hours, days or months", ToolView.gapText(1200) == "20 min" && ToolView.gapText(7200) == "2 h" && ToolView.gapText(86_400 * 3) == "3 days" && ToolView.gapText(86_400 * 120) == "4 months", "\(ToolView.gapText(86_400 * 120))")
    }

    // MARK: What a view lists

    private static func listChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let p = at(0)
        let r = run(
            [song("B", "Never Old", played: at(-100 * 86_400)), song("A", "Never New", played: at(-86_400 * 2)), song("C", "Late New", played: p),
             song("D", "Shifted", played: p)],
            [scrobble("C", "Late New", at(-60_000)), scrobble("D", "Shifted", at(-3600))]
        )
        let now = t0.addingTimeInterval(86_400)
        func titles(_ filter: ToolView.Filter, _ period: ToolView.Period, _ sort: ToolView.Sort, _ group: ToolView.Group = .notScrobbled) -> [String] {
            ToolView.listed(group == .notScrobbled ? r.notScrobbled : r.timeDiffers, group: group, filter: filter, period: period, sort: sort, now: now).map(\.track)
        }
        check("All lists every not-scrobbled song, most recently played first", titles(.all, .anyTime, .lastPlayed) == ["Late New", "Never New", "Never Old"], "\(titles(.all, .anyTime, .lastPlayed))")
        check("Never scrobbled and Played after its last scrobble split them", titles(.never, .anyTime, .lastPlayed) == ["Never New", "Never Old"] && titles(.afterLast, .anyTime, .lastPlayed) == ["Late New"])
        check("the period leaves out songs last played earlier", titles(.all, .quarter, .lastPlayed) == ["Late New", "Never New"] && titles(.all, .month, .lastPlayed) == ["Late New", "Never New"])
        check("Last 14 days keeps only plays from the last two weeks", titles(.all, .fortnight, .lastPlayed) == ["Late New", "Never New"] && ToolView.Period.fortnight.days == 14 && ToolView.Period.allCases.last == .fortnight)
        check("a play just over 14 days old is out and one just under is in", {
            let two = run([song("A", "Edge Out", played: at(0)), song("A", "Edge In", played: at(0))], [])
            let edge = ToolView.listed(two.notScrobbled, group: .notScrobbled, filter: .all, period: .fortnight, sort: .artist, now: t0.addingTimeInterval(14 * 86_400 - 60))
            let out = ToolView.listed(two.notScrobbled, group: .notScrobbled, filter: .all, period: .fortnight, sort: .artist, now: t0.addingTimeInterval(14 * 86_400 + 60))
            return edge.count == 2 && out.isEmpty
        }())
        check("artist order sorts by artist name", titles(.all, .anyTime, .artist) == ["Never New", "Never Old", "Late New"], "\(titles(.all, .anyTime, .artist))")
        check("Largest gap lists never-scrobbled songs first", titles(.all, .anyTime, .gap).first == "Never New" || titles(.all, .anyTime, .gap).first == "Never Old")
        check("Time differs lists its songs and ignores the Show filter", titles(.never, .anyTime, .lastPlayed, .timeDiffers) == ["Shifted"])
    }

    // MARK: Submitting to Last.fm (everything but the network)

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[LastfmWriteClient.ScrobbleSubmission]] = []
        func add(_ b: [LastfmWriteClient.ScrobbleSubmission]) { lock.lock(); batches.append(b); lock.unlock() }
        var all: [[LastfmWriteClient.ScrobbleSubmission]] { lock.lock(); defer { lock.unlock() }; return batches }
    }

    private final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var plays: [[UnscrobbledPlaysScrobbling.Play]] = []
        func add(_ p: [UnscrobbledPlaysScrobbling.Play]) { lock.lock(); plays.append(p); lock.unlock() }
        var all: [[UnscrobbledPlaysScrobbling.Play]] { lock.lock(); defer { lock.unlock() }; return plays }
    }

    private static func play(_ i: Int, artist: String = "A") -> UnscrobbledPlaysScrobbling.Play {
        UnscrobbledPlaysScrobbling.Play(id: "p\(i)", artist: artist, track: "Song \(i)", album: "Album", playedAt: at(Double(-i * 60)), neverScrobbled: i % 2 == 0)
    }

    private static func scrobbleChecks(_ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        typealias Scrobbling = UnscrobbledPlaysScrobbling
        let hour: TimeInterval = 3600

        // What is eligible: inside the 14-day window (less a safety margin), not in the future, not covered by a variant, not time-shifted.
        let ages: [(String, TimeInterval)] = [("One Hour", hour), ("Thirteen Days", 13 * 86_400), ("Edge In", 14 * 86_400 - 2 * hour), ("Edge Out", 14 * 86_400 - 1800), ("Fifteen Days", 15 * 86_400), ("Future", -600)]
        let r = run(
            ages.map { song("A", $0.0, played: at(-$0.1)) } + [song("A", "Shifted", played: at(-hour * 30))],
            [scrobble("A", "Shifted", at(-hour * 40))]
        )
        let ok = Scrobbling.eligible(r.notScrobbled, now: t0)
        check("plays inside the 14-day window are eligible, oldest first", ok.map(\.track) == ["Edge In", "Thirteen Days", "One Hour"], "\(ok.map(\.track))")
        check("a play within the safety margin of the edge, an older one and a future one are not", !ok.contains { ["Edge Out", "Fifteen Days", "Future"].contains($0.track) })
        check("a time-shifted play (already scrobbled) is never offered", r.timeDiffers.contains { $0.track == "Shifted" } && !ok.contains { $0.track == "Shifted" })
        check("the timestamp is Music's played date in whole seconds", ok.first { $0.track == "One Hour" }?.timestamp == Int(at(-hour).timeIntervalSince1970))
        check("the window is 14 days less an hour", Scrobbling.maxAge == 14 * 86_400 - 3600)

        // A play covered by a scrobble under another spelling is not offered (variants not matched)
        let covered = run([song("A", "Title", played: at(-hour)), song("B", "Other", played: at(-hour))], [scrobble("A", "Title (feat. Guest)", at(-hour)), scrobble("B", "Other (Remastered 2011)", at(-30 * hour))], variants: false)
        let coveredEligible = Scrobbling.eligible(covered.notScrobbled, now: t0)
        check("with variants not matched, a play already scrobbled under another spelling is marked covered and not offered", covered.notScrobbled.first { $0.track == "Title" }?.coveredByVariant == true && !coveredEligible.contains { $0.track == "Title" })
        check("a variant scrobble from before the play does not cover it", covered.notScrobbled.first { $0.track == "Other" }?.coveredByVariant == false && coveredEligible.contains { $0.track == "Other" })

        // The plays as sent
        let subs = Scrobbling.submissions([
            Scrobbling.Play(id: "1", artist: "A", track: "Late", album: "Alb", playedAt: at(-60), neverScrobbled: true),
            Scrobbling.Play(id: "2", artist: "A", track: "Early", album: "", playedAt: at(-600), neverScrobbled: true),
            Scrobbling.Play(id: "3", artist: " a ", track: "EARLY", album: "", playedAt: at(-600), neverScrobbled: true),     // the same song at the same moment
            Scrobbling.Play(id: "4", artist: "", track: "No Artist", album: "", playedAt: at(-60), neverScrobbled: true),
        ])
        check("submissions are oldest first, drop repeats and plays with no artist, and omit an empty album", subs.map(\.track) == ["Early", "Late"] && subs[0].album == nil && subs[1].album == "Alb", "\(subs)")

        // The request: known-answer signature, computed independently
        let two = [
            LastfmWriteClient.ScrobbleSubmission(artist: "Artist One", track: "Song & One", album: "Album, One", timestamp: 1_700_000_000),
            LastfmWriteClient.ScrobbleSubmission(artist: "Artist Two", track: "Song Two", album: nil, timestamp: 1_700_000_100),
        ]
        let params = LastfmWriteClient.scrobbleParameters(apiKey: "key123", sessionKey: "sess456", plays: two)
        check("the request carries numbered fields, and album only when there is one",
              Set(params.keys) == ["method", "api_key", "sk", "artist[0]", "track[0]", "timestamp[0]", "album[0]", "artist[1]", "track[1]", "timestamp[1]"] && params["method"] == "track.scrobble")
        check("the signature matches a value computed separately", LastfmSigning.sign(params: params, secret: "s3cret") == "88da1c7bc87d14c5ced99b49a5e84177", LastfmSigning.sign(params: params, secret: "s3cret"))

        // Reading Last.fm's answer
        func parse(_ json: String, expected: Int) -> [LastfmWriteClient.ScrobbleOutcome]? { try? LastfmWriteClient.parseScrobbleResponse(Data(json.utf8), expected: expected) }
        let one = parse(##"{"scrobbles":{"@attr":{"accepted":1,"ignored":0},"scrobble":{"track":{"#text":"T"},"ignoredMessage":{"code":"0","#text":""},"timestamp":"1"}}}"##, expected: 1)
        check("a single scrobble comes back as an object and is read", one == [.init(accepted: true, ignoredCode: nil, message: "")], "\(String(describing: one))")
        let many = parse(##"{"scrobbles":{"@attr":{"accepted":1,"ignored":2},"scrobble":[{"ignoredMessage":{"code":"0","#text":""}},{"ignoredMessage":{"code":"3","#text":"Timestamp too old"}},{"ignoredMessage":{"code":5,"#text":"limit"}}]}}"##, expected: 3)
        check("several come back in order, with text or number codes", many?.map(\.ignoredCode) == [nil, 3, 5] && many?.map(\.accepted) == [true, false, false] && many?[1].message == "Timestamp too old", "\(String(describing: many))")
        check("a count that doesn't match what was sent is an error, not a guess", parse(##"{"scrobbles":{"scrobble":[{"ignoredMessage":{"code":"0"}}]}}"##, expected: 2) == nil && parse(##"{"nothing":1}"##, expected: 1) == nil && parse("not json", expected: 1) == nil)
        check("an answer with no ignoredMessage counts as accepted", parse(##"{"scrobbles":{"scrobble":[{"track":{"#text":"T"}}]}}"##, expected: 1)?.first?.accepted == true)

        // Sending in batches
        let many120 = (0..<120).map { play($0) }
        let calls = Calls()
        let recorded = Recorded()
        let sender: Scrobbling.Sender = { batch in calls.add(batch); return batch.map { _ in .init(accepted: true, ignoredCode: nil, message: "") } }
        let done = await Scrobbling.submit(many120, send: sender, pause: .zero, recordAccepted: { recorded.add($0) })
        check("120 plays go out as 50, 50 and 20, oldest first", calls.all.map(\.count) == [50, 50, 20] && calls.all.flatMap { $0 }.map(\.timestamp) == calls.all.flatMap { $0 }.map(\.timestamp).sorted(), "\(calls.all.map(\.count))")
        check("every play is accepted and recorded batch by batch", done.accepted.count == 120 && recorded.all.map(\.count) == [50, 50, 20] && done.failure == nil && done.notSent.isEmpty)
        let mixed: Scrobbling.Sender = { batch in batch.enumerated().map { $0.offset == 1 ? .init(accepted: false, ignoredCode: 3, message: "") : .init(accepted: true, ignoredCode: nil, message: "") } }
        let partial = await Scrobbling.submit((0..<4).map { play($0) }, send: mixed, pause: .zero)
        check("a play Last.fm ignores is reported with its code and is not recorded as accepted", partial.accepted.count == 3 && partial.ignored.count == 1 && partial.ignored[0].code == 3 && partial.failure == nil)

        let calls2 = Calls(); let recorded2 = Recorded()
        let failSecond: Scrobbling.Sender = { batch in
            calls2.add(batch)
            if calls2.all.count == 2 { throw LastfmAPIError.api(code: 9, message: "Invalid session key") }
            return batch.map { _ in .init(accepted: true, ignoredCode: nil, message: "") }
        }
        let stopped = await Scrobbling.submit(many120, send: failSecond, pause: .zero, recordAccepted: { recorded2.add($0) })
        check("when Last.fm answers with an error the run stops, keeps what went through, and reports the rest as not sent",
              stopped.accepted.count == 50 && recorded2.all.count == 1 && stopped.notSent.count == 70 && stopped.outcomeUnknownFor.isEmpty && stopped.failure != nil, "\(stopped.accepted.count) \(stopped.notSent.count)")
        let calls3 = Calls()
        let dropSecond: Scrobbling.Sender = { batch in
            calls3.add(batch)
            if calls3.all.count == 2 { throw LastfmAPIError.network(URLError(.networkConnectionLost)) }
            return batch.map { _ in .init(accepted: true, ignoredCode: nil, message: "") }
        }
        let dropped = await Scrobbling.submit(many120, send: dropSecond, pause: .zero)
        check("a dropped connection leaves that batch's outcome unknown and the later ones not sent", dropped.outcomeUnknownFor.count == 50 && dropped.notSent.count == 20 && dropped.accepted.count == 50)
        let offline: Scrobbling.Sender = { _ in throw OfflineError() }
        let off = await Scrobbling.submit(many120, send: offline, pause: .zero)
        check("Offline mode sends nothing and nothing is unknown", off.accepted.isEmpty && off.outcomeUnknownFor.isEmpty && off.notSent.count == 120 && off.failure != nil)
        let again = await Scrobbling.submit([play(1), play(1)], send: sender, pause: .zero)
        check("the same play twice is sent once", again.accepted.count == 1)
        check("which errors may have been taken: only those with no usable answer", Scrobbling.mayHaveBeenTaken(LastfmAPIError.network(URLError(.timedOut))) && Scrobbling.mayHaveBeenTaken(LastfmAPIError.http(502)) && !Scrobbling.mayHaveBeenTaken(LastfmAPIError.api(code: 13, message: "")))
        check("ignore codes have plain wording", Scrobbling.ignoredReason(code: 3, message: "").contains("14 days") && Scrobbling.ignoredReason(code: 5, message: "").contains("daily") && Scrobbling.ignoredReason(code: 99, message: "odd") == "odd")

        // The ledger keeps a submitted play out of the list until the history has it
        let suite = UserDefaults(suiteName: "unscrobbled-plays-check")!
        suite.removePersistentDomain(forName: "unscrobbled-plays-check")
        UnscrobbledPlaysLedger.record([play(3)], now: t0, defaults: suite)
        check("a recorded play is remembered", UnscrobbledPlaysLedger.load(now: t0, defaults: suite).count == 1)
        check("and forgotten after 30 days", UnscrobbledPlaysLedger.load(now: t0.addingTimeInterval(31 * 86_400), defaults: suite).isEmpty)
        suite.removePersistentDomain(forName: "unscrobbled-plays-check")
        let playedAt = at(-600)
        let key = Scrobbling.ledgerKey(artist: "a", track: "SONG   x", timestamp: Int(playedAt.timeIntervalSince1970))
        let hidden = Engine.compute(scrobbles: history([]), music: music([song("A", "Song X", played: playedAt)]), matchVariants: true, syncedThrough: synced, submitted: [key], now: t0)
        let shown = Engine.compute(scrobbles: history([]), music: music([song("A", "Song X", played: playedAt)]), matchVariants: true, syncedThrough: synced, submitted: [], now: t0)
        check("a submitted play (names compared ignoring case and spacing) is not listed, and is counted as waiting", hidden.notScrobbled.isEmpty && hidden.submittedWaiting == 1 && shown.notScrobbled.count == 1 && shown.submittedWaiting == 0)
        let otherMoment = Engine.compute(scrobbles: history([]), music: music([song("A", "Song X", played: at(-5000))]), matchVariants: true, syncedThrough: synced, submitted: [key], now: t0)
        check("a later play of the same song is still listed", otherMoment.notScrobbled.count == 1)
    }

    // MARK: An independent count on generated data

    private static func crossCheck(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        var seed: UInt64 = 20_261_107
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        var tracks: [AppleMusicSnapshot.Track] = []
        var scrobbles: [ScrobbleSnapshot] = []
        for i in 0..<400 {
            let artist = "Artist \(i % 37)", name = "Song \(i)"
            let played = at(-Double(next(300 * 86_400) + 7200))
            if next(5) > 0 { tracks.append(song(artist, name, played: played, plays: 1 + next(9))) }
            switch next(7) {
            case 0: break                                                                    // never scrobbled
            case 1: scrobbles.append(scrobble(artist, name, played.addingTimeInterval(-Double((1 + next(13)) * 3600))))   // whole-hour shift
            case 2: scrobbles.append(scrobble(artist, name, played.addingTimeInterval(-Double(700 + next(100_000)))))      // some gap
            case 3: scrobbles.append(scrobble(artist, name, played.addingTimeInterval(Double(next(500)))))                 // later or equal
            default: scrobbles.append(scrobble(artist, name, played))
            }
        }
        let result = Engine.compute(scrobbles: history(scrobbles), music: music(tracks), matchVariants: false, syncedThrough: synced, now: t0)
        var expectedNever = 0, expectedLate = 0, expectedShift = 0, expectedAgree = 0
        var byKey: [String: Date] = [:]
        for t in tracks { byKey[Engine.exactKey(artist: t.artist, track: t.name)] = t.lastPlayedAt }
        for (key, played) in byKey {
            let latest = scrobbles.filter { Engine.exactKey(artist: $0.artistName, track: $0.trackName) == key }.map(\.playedAt).max()
            guard let latest else { expectedNever += 1; continue }
            let gap = played.timeIntervalSince(latest)
            if gap <= 600 { expectedAgree += 1; continue }
            let hours = (gap / 3600).rounded()
            if hours >= 1, hours <= 14, abs(gap - hours * 3600) <= 600 { expectedShift += 1 } else { expectedLate += 1 }
        }
        check("generated library: songs agreeing equal an independent count", result.upToDate == expectedAgree, "\(result.upToDate) vs \(expectedAgree)")
        check("generated library: never-scrobbled songs equal an independent count", result.notScrobbled.filter { $0.kind == .neverScrobbled }.count == expectedNever, "\(result.notScrobbled.filter { $0.kind == .neverScrobbled }.count) vs \(expectedNever)")
        check("generated library: played-after-scrobble songs equal an independent count", result.notScrobbled.filter { $0.kind == .playedAfterLastScrobble }.count == expectedLate, "\(result.notScrobbled.filter { $0.kind == .playedAfterLastScrobble }.count) vs \(expectedLate)")
        check("generated library: time differences equal an independent count", result.timeDiffers.count == expectedShift, "\(result.timeDiffers.count) vs \(expectedShift)")
        check("generated library: every song with a played date is accounted for", result.compared == expectedAgree + expectedNever + expectedLate + expectedShift, "\(result.compared)")
    }
}
#endif
