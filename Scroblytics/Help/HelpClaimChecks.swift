import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_HELP_CLAIMS=1`: runs the real query engine over small, hand-built sets of plays whose answers were
/// worked out by hand, to confirm the statements in the Help field definitions. Touches no real data.
enum HelpClaimChecks {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1   // Sunday: weeks in "Active weeks" must still start on Monday
        return calendar
    }()

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private static func play(_ track: String, _ at: Date, artist: String = "Artist A", album: String = "Album") -> ScrobbleSnapshot {
        ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: nil, playedAt: at)
    }

    /// The value of `ref` for every track (or other target) of a run, keyed by the entity's name.
    private static func values(
        _ ref: QueryFieldRef, target: QueryTarget = .track, plays: [ScrobbleSnapshot], asOf: Date, groups: [[QueryCondition]] = [],
        calendar runCalendar: Calendar? = nil
    ) -> [String: QueryCell] {
        Dictionary(uniqueKeysWithValues: cells(ref, target: target, plays: plays, asOf: asOf, groups: groups, calendar: runCalendar).map { ($0.key.name, $0.value) })
    }

    private static func cells(
        _ ref: QueryFieldRef, target: QueryTarget = .track, plays: [ScrobbleSnapshot], asOf: Date, groups: [[QueryCondition]] = [],
        calendar runCalendar: Calendar? = nil
    ) -> [QueryEntityID: QueryCell] {
        var spec = QuerySpec(target: target)
        spec.columns = [ref]
        spec.groups = groups
        guard let validated = try? spec.validate(against: .standard) else { return [:] }
        let sorted = plays.sorted { $0.playedAt < $1.playedAt }
        let run = QueryRun(target: target, asOf: asOf, calendar: runCalendar ?? calendar, scrobbles: spec.countedPlays(sorted), allTimeScrobbles: sorted)
        let result = QueryEngine.evaluate(validated, run: run)
        let key = validated.columns[0].cacheKey
        return Dictionary(uniqueKeysWithValues: result.rows.map { ($0.entity.id, $0.cells[key] ?? .missing) })
    }

    /// `SCROBLYTICS_HELP_STORE_CHECK=/path/out.tsv` (with `SCROBLYTICS_STORE_PATH` pointing at a COPY of the store): writes
    /// several fields for a spread of real tracks as of a fixed moment, in UTC, so they can be recomputed independently
    /// from the same copy with SQLite.
    static func runStoreCheckIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_HELP_STORE_CHECK"] else { return }
        HeadlessTask.run("HelpClaimChecks") {
            let raw = try container.mainContext.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
            let plays = QueryIdentity.canonicalizingArtists(raw)
            let asOf = date(2026, 10, 4, 12)
            let ids = ["plays", "allTimePlays", "activeDays", "activeWeeks", "activeMonths", "daysSinceLastPlayed", "daysSinceFirstPlayed",
                       "playSpanDays", "playRank", "nextMilestone", "artistDiscographySize", "peakTimeOfDay", "dayOfWeek", "weekdayOrWeekend", "peakSeason"]
            var table: [String: [QueryEntityID: QueryCell]] = [:]
            for id in ids { table[id] = cells(QueryFieldRef(id), plays: plays, asOf: asOf) }
            let byRank = (table["plays"] ?? [:]).compactMap { id, cell in number(cell).map { (id, $0) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.artist, $0.0.name) < ($1.0.artist, $1.0.name) }
            let step = max(1, byRank.count / 8)
            let chosen = Array(byRank.prefix(6)) + stride(from: 6, to: byRank.count, by: step).map { byRank[$0] }
            var lines = [(["artist", "track"] + ids).joined(separator: "\t")]
            for (id, _) in chosen {
                let row = ids.map { field -> String in
                    switch table[field]?[id] {
                    case .value(.number(let n))?: n == n.rounded() ? String(Int(n)) : String(n)
                    case .value(.text(let s))?: s
                    default: "-"
                    }
                }
                lines.append(([id.artist, id.name] + row).joined(separator: "\t"))
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    private static func number(_ cell: QueryCell?) -> Double? {
        if case .value(.number(let n))? = cell { return n } else { return nil }
    }

    private static func text(_ cell: QueryCell?) -> String? {
        if case .value(.text(let s))? = cell { return s } else { return nil }
    }

    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_HELP_CLAIMS"] != nil else { return }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail().isEmpty ? "" : " — " + detail())")
            if !ok { failures += 1 }
        }
        let asOf = date(2025, 6, 15, 12)

        // Recency: whole days, rounded down.
        do {
            let plays = [play("ds", date(2025, 6, 1, 13)), play("ds", date(2025, 6, 12, 18))]
            check("daysSinceLastPlayed floors (2 d 18 h → 2)", number(values(QueryFieldRef("daysSinceLastPlayed"), plays: plays, asOf: asOf)["ds"]) == 2)
            check("daysSinceFirstPlayed floors (13 d 23 h → 13)", number(values(QueryFieldRef("daysSinceFirstPlayed"), plays: plays, asOf: asOf)["ds"]) == 13)
        }

        // Active days / weeks (Monday start) / months.
        do {
            let days = [play("ad", date(2025, 6, 1, 10)), play("ad", date(2025, 6, 1, 22)), play("ad", date(2025, 6, 2, 9))]
            check("activeDays counts distinct days (3 plays on 2 days → 2)", number(values(QueryFieldRef("activeDays"), plays: days, asOf: asOf)["ad"]) == 2)
            let months = [play("am", date(2025, 5, 31)), play("am", date(2025, 6, 1))]
            check("activeMonths counts distinct months (31 May + 1 June → 2)", number(values(QueryFieldRef("activeMonths"), plays: months, asOf: asOf)["am"]) == 2)
            let span = [play("ps", date(2025, 1, 10, 22)), play("ps", date(2025, 1, 12, 1))]
            check("playSpanDays counts start-of-day to start-of-day (10th 22:00 → 12th 01:00 = 2)", number(values(QueryFieldRef("playSpanDays"), plays: span, asOf: asOf)["ps"]) == 2)
        }

        // The week-start setting: Monday, Sunday and Friday each cut weeks, "this/last week" scopes and Time Machine's week
        // at the right day. Plays on Fri 13 – Tue 17 June 2025; "now" is Wed 18 June.
        do {
            func weekCalendar(_ start: WeekStart) -> Calendar {
                var c = calendar
                c.firstWeekday = start.rawValue
                return c
            }
            let now = date(2025, 6, 18, 12)
            let daily = (13...17).map { play("wk", date(2025, 6, $0)) }
            let straddle = (13...16).map { play("sw", date(2025, 6, $0)) }   // Fri, Sat, Sun, Mon
            // (this week, last week, active weeks over Fri–Mon) for each setting, worked out by hand.
            let expected: [(WeekStart, Double, Double, Double)] = [(.monday, 2, 3, 2), (.sunday, 3, 2, 2), (.friday, 5, 0, 1)]
            for (start, thisWeek, lastWeek, active) in expected {
                let c = weekCalendar(start)
                let this = number(values(QueryFieldRef("plays", scope: .calendar(.week)), plays: daily, asOf: now, calendar: c)["wk"])
                let last = number(values(QueryFieldRef("plays", scope: QueryScope.calendar(.week).shifted(back: 1, .week)), plays: daily, asOf: now, calendar: c)["wk"])
                check("\(start.label)-start: “this week” holds \(Int(thisWeek)) of the plays", this == thisWeek, "\(this as Any)")
                check("\(start.label)-start: “last week” holds \(Int(lastWeek))", (last ?? 0) == lastWeek, "\(last as Any)")
                check("\(start.label)-start: Fri–Mon plays fall in \(Int(active)) active week(s)", number(values(QueryFieldRef("activeWeeks"), plays: straddle, asOf: now, calendar: c)["sw"]) == active)
            }
            // Time Machine's Week mode: the reference week as month/day pairs, matched in other years.
            let past = [(13, "tm13"), (15, "tm15"), (16, "tm16"), (22, "tm22")].map { play($0.1, date(2024, 6, $0.0)) }
            let timeMachine: [(WeekStart, Set<String>)] = [(.monday, ["tm16", "tm22"]), (.sunday, ["tm15", "tm16"]), (.friday, ["tm13", "tm15", "tm16"])]
            for (start, tracks) in timeMachine {
                let result = OnThisDayEngine.timeMachine(scrobbles: past, referenceDate: now, period: .week, year: nil, calendar: weekCalendar(start))
                check("\(start.label)-start: Time Machine’s week covers \(tracks.sorted())", Set(result.entries.map(\.track)) == tracks, "\(result.entries.map(\.track))")
            }
        }

        // Rank ties.
        do {
            func n(_ track: String, _ artist: String, _ count: Int) -> [ScrobbleSnapshot] {
                (0..<count).map { play(track, date(2025, 5, 1 + $0), artist: artist) }
            }
            let plays = n("rk-x", "Artist A", 3) + n("rk-y", "Artist B", 2) + n("rk-z", "Artist A", 2) + n("rk-w", "Artist C", 1)
            let broken = values(QueryFieldRef("playRank"), plays: plays, asOf: asOf)
            check("playRank breaks ties by artist then title (1, 2, 3, 4)", [number(broken["rk-x"]), number(broken["rk-z"]), number(broken["rk-y"]), number(broken["rk-w"])] == [1, 2, 3, 4], "\(broken)")
            let shared = values(QueryFieldRef("playRank", parameters: ["ties": .text("shared")]), plays: plays, asOf: asOf)
            check("playRank “shared” gives equal plays one rank (1, 2, 2, 4)", [number(shared["rk-x"]), number(shared["rk-y"]), number(shared["rk-z"]), number(shared["rk-w"])] == [1, 2, 2, 4], "\(shared)")
        }

        // Comparison fields.
        do {
            let may = QueryScope.absolute(from: date(2025, 5, 1, 0), to: date(2025, 5, 31, 23, 59))
            let june = QueryScope.absolute(from: date(2025, 6, 1, 0), to: date(2025, 6, 30, 23, 59))
            func n(_ track: String, _ month: Int, _ count: Int) -> [ScrobbleSnapshot] {
                (0..<count).map { play(track, date(2025, month, 1 + $0)) }
            }
            let plays = n("pc-a", 5, 2) + n("pc-a", 6, 3) + n("pc-b", 5, 3) + n("pc-b", 6, 5) + n("pc-c", 6, 2)
            let percent = values(QueryFieldRef("playsChangePercent", scope: june, baseline: may), plays: plays, asOf: asOf)
            check("playsChangePercent: 2 → 3 plays is 50", number(percent["pc-a"]) == 50, "\(percent["pc-a"] as Any)")
            check("playsChangePercent rounds to a whole number: 3 → 5 is 67", number(percent["pc-b"]) == 67, "\(percent["pc-b"] as Any)")
            check("playsChangePercent has no value when the baseline had no plays", percent["pc-c"] == .missing)
            let change = values(QueryFieldRef("playsChange", scope: june, baseline: may), plays: plays, asOf: asOf)
            check("playsChange is plays now minus plays before (0 counts as 0)", number(change["pc-a"]) == 1 && number(change["pc-c"]) == 2)

            // Rank movement = baseline rank − current rank; no value unless ranked in both.
            let ranked = n("rm-a", 5, 1) + n("rm-a", 6, 5) + n("rm-b", 5, 2) + n("rm-b", 6, 1) + n("rm-c", 5, 3)
            let movement = values(QueryFieldRef("rankMovement", scope: june, baseline: may), plays: ranked, asOf: asOf)
            check("rankMovement = baseline rank − current rank (rank 3 → 1 is +2; 2 → 2 is 0)", number(movement["rm-a"]) == 2 && number(movement["rm-b"]) == 0, "\(movement)")
            check("rankMovement has no value unless ranked in both periods", movement["rm-c"] == .missing)
        }

        // Time of day / weekday.
        do {
            let hours: [(String, Int)] = [("h21", 21), ("h4", 4), ("h5", 5), ("h11", 11), ("h12", 12), ("h16", 16), ("h17", 17), ("h20", 20)]
            let plays = hours.map { play($0.0, date(2025, 6, 10, $0.1)) } + [play("tie", date(2025, 6, 10, 9)), play("tie", date(2025, 6, 11, 22))]
            let v = values(QueryFieldRef("peakTimeOfDay"), plays: plays, asOf: asOf)
            let expected = ["h21": "Night", "h4": "Night", "h5": "Morning", "h11": "Morning", "h12": "Afternoon", "h16": "Afternoon", "h17": "Evening", "h20": "Evening", "tie": "Night"]
            check("peakTimeOfDay buckets: Night 21–4, Morning 5–11, Afternoon 12–16, Evening 17–20; a tie goes to the earliest", expected.allSatisfy { text(v[$0.key]) == $0.value }, "\(v)")

            let dow = [play("dw", date(2025, 6, 11)), play("dw", date(2025, 6, 15))]   // Wednesday + Sunday
            check("dayOfWeek: a tie goes to the earlier day, Sunday first", text(values(QueryFieldRef("dayOfWeek"), plays: dow, asOf: asOf)["dw"]) == "Sunday")
            let tied = [play("wk", date(2025, 6, 14)), play("wk", date(2025, 6, 9))]   // Saturday + Monday
            check("weekdayOrWeekend: a tie is Weekday", text(values(QueryFieldRef("weekdayOrWeekend"), plays: tied, asOf: asOf)["wk"]) == "Weekday")
            let weekend = tied + [play("wk", date(2025, 6, 15))]
            check("weekdayOrWeekend: more weekend plays is Weekend", text(values(QueryFieldRef("weekdayOrWeekend"), plays: weekend, asOf: asOf)["wk"]) == "Weekend")
            let seasons = [("dec", 12), ("jan", 1), ("feb", 2), ("mar", 3), ("may", 5), ("jun", 6), ("aug", 8), ("sep", 9), ("nov", 11)].map { play($0.0, date(2025, $0.1, 10, 12)) }
            let seasonValues = values(QueryFieldRef("peakSeason"), plays: seasons, asOf: asOf)
            let seasonExpected = ["dec": "Winter", "jan": "Winter", "feb": "Winter", "mar": "Spring", "may": "Spring", "jun": "Summer", "aug": "Summer", "sep": "Autumn", "nov": "Autumn"]
            check("peakSeason (northern): Dec–Feb winter, Mar–May spring, Jun–Aug summer, Sep–Nov autumn", seasonExpected.allSatisfy { text(seasonValues[$0.key]) == $0.value }, "\(seasonValues)")
            let seasonTie = [play("st", date(2025, 7, 10, 12)), play("st", date(2025, 1, 10, 12))]   // one summer + one winter play
            check("peakSeason: a tie goes to the earlier of Winter, Spring, Summer, Autumn", text(values(QueryFieldRef("peakSeason"), plays: seasonTie, asOf: asOf)["st"]) == "Winter")
        }

        // Milestones.
        do {
            func n(_ track: String, _ count: Int, start: Date = date(2024, 1, 1, 0)) -> [ScrobbleSnapshot] {
                (0..<count).map { play(track, start.addingTimeInterval(Double($0) * 3600)) }
            }
            let plays = n("m99", 99) + n("m100", 100) + n("m249", 249) + n("m250", 250) + n("m2500", 2500)
            let next = values(QueryFieldRef("nextMilestone"), plays: plays, asOf: asOf)
            check("nextMilestone: 99→100, 100→250, 249→250, 250→500, 2,500→5,000",
                  [number(next["m99"]), number(next["m100"]), number(next["m249"]), number(next["m250"]), number(next["m2500"])] == [100, 250, 250, 500, 5000], "\(next)")
            check("toNextMilestone counts down (99 plays → 1)", number(values(QueryFieldRef("toNextMilestone"), plays: plays, asOf: asOf)["m99"]) == 1)
            let reached = values(QueryFieldRef("milestonesReached"), plays: plays, asOf: asOf)
            check("milestonesReached: 99→0, 100→1, 250→2, 2,500→5", [number(reached["m99"]), number(reached["m100"]), number(reached["m250"]), number(reached["m2500"])] == [0, 1, 2, 5], "\(reached)")
            let last = values(QueryFieldRef("lastMilestone"), plays: plays, asOf: asOf)
            check("lastMilestone has no value below 100 plays", last["m99"] == .missing && number(last["m100"]) == 100 && number(last["m249"]) == 100)

            // ETA = remaining × 30 ÷ plays in the last 30 days, rounded up.
            let recent = n("eta", 90, start: date(2024, 1, 1, 0)) + n("eta", 10, start: date(2025, 6, 10, 0))
            let quiet = n("quiet", 100, start: date(2024, 1, 1, 0))
            let eta = values(QueryFieldRef("milestoneEta"), plays: recent + quiet, asOf: asOf)
            check("milestoneEta = ceil(150 × 30 ÷ 10) = 450", number(eta["eta"]) == 450, "\(eta["eta"] as Any)")
            check("milestoneEta has no value with no plays in the last 30 days", eta["quiet"] == .missing)

            // Missing-value semantics.
            func matched(_ condition: QueryCondition) -> Set<String> {
                var spec = QuerySpec(target: .track)
                spec.groups = [[condition]]
                let sorted = plays.sorted { $0.playedAt < $1.playedAt }
                guard let validated = try? spec.validate(against: .standard) else { return ["<invalid>"] }
                let run = QueryRun(target: .track, asOf: asOf, calendar: calendar, scrobbles: sorted, allTimeScrobbles: sorted)
                return Set(QueryEngine.evaluate(validated, run: run).rows.map(\.entity.id.name))
            }
            check("“is missing” matches only items with no value", matched(QueryCondition("lastMilestone", .isMissing)) == ["m99"])
            check("“has a value” excludes items with no value", matched(QueryCondition("lastMilestone", .hasValue)) == ["m100", "m249", "m250", "m2500"])
            check("“≠” does not match items with no value", matched(QueryCondition("lastMilestone", .notEquals, [.number(100)])) == ["m250", "m2500"])
            check("“between” is inclusive at both ends", matched(QueryCondition("plays", .between, [.number(100), .number(249)])) == ["m100", "m249"])
        }

        // Fading Favorites, and percentage-style fields holding fractions.
        do {
            let peak = (1...5).map { play("fd", date(2025, 1, $0)) }
            let plays = peak + [play("fd", date(2025, 6, 10))]
            let ref = { (id: String) in QueryFieldRef(id, parameters: ["windowDays": .number(90)]) }
            check("fadingPeak = 5 plays in one stretch", number(values(ref("fadingPeak"), plays: plays, asOf: asOf)["fd"]) == 5)
            check("fadingRecent = plays in the 90 days up to now", number(values(ref("fadingRecent"), plays: plays, asOf: asOf)["fd"]) == 1)
            let decay = number(values(ref("fadingDecay"), plays: plays, asOf: asOf)["fd"])
            check("fadingDecay is a fraction (1 ÷ 5 = 0.2)", decay.map { abs($0 - 0.2) < 1e-9 } == true, "\(decay as Any)")
            let score = number(values(ref("rediscoveryScore"), plays: plays, asOf: asOf)["fd"])
            check("rediscoveryScore = peak × (1 − fade ratio) = 4", score.map { abs($0 - 4) < 1e-9 } == true, "\(score as Any)")
            let matchedFraction = values(ref("fadingDecay"), plays: plays, asOf: asOf, groups: [[QueryCondition(ref("fadingDecay"), .lessThanOrEqual, [.number(0.25)])]])
            check("typing 0.25 (a fraction) keeps a track at 20%", matchedFraction["fd"] != nil)
        }

        // Identity.
        do {
            let plays = [play("a", date(2025, 1, 1), artist: "Artist A"), play("b", date(2025, 1, 2), artist: "Artist A"), play("c", date(2025, 1, 3), artist: "artist a")]
            let canonical = QueryIdentity.canonicalizingArtists(plays)
            check("artist spellings are combined into the most-played one", Set(canonical.map(\.artistName)) == ["Artist A"])
        }

        // Tags: absence is an empty list.
        do {
            let matcher = QueryMatcher(calendar: calendar)
            check("tags: “is none of” includes an item with no tags", matcher.matches(.missing, op: .tagsIsNotAny, operands: [.tags(["rock"])]))
            check("tags: a pending item matches nothing", !matcher.matches(.pending, op: .tagsIsNotAny, operands: [.tags(["rock"])]))
        }

        print(failures == 0 ? "ALL CLAIMS HELD" : "\(failures) CLAIM(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
