import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_OVERVIEWDRILL_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): what a click on a cell of Overview's "Last 24
/// Hours" or "Current streak" strip hands to Query. The hour and day specs, and (through the real query code, on made-up plays at the
/// edges of an hour and a day, and on a copy of a library when there is one) that they count exactly the plays in that hour or day.
/// Exits 0 on success.
enum OverviewDrillChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_OVERVIEWDRILL_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let calendar = AppCalendars.listening

            /// Total plays over the rows a spec returns, run the way Query runs it: only the plays the spec counts form the universe.
            func totalPlays(_ spec: QuerySpec, over all: [ScrobbleSnapshot]) -> (plays: Int, rows: Int)? {
                guard let validated = try? spec.validate(against: .standard) else { return nil }
                let run = QueryRun(target: spec.target, asOf: Date(), scrobbles: spec.countedPlays(all), allTimeScrobbles: all, snapshots: QuerySnapshots())
                let result = QueryEngine.evaluate(validated, run: run)
                // Each row of a scrobble query is one play, so the plays are the rows that match (before any limit).
                if spec.target == .scrobble { return (result.matchedCount, result.rows.count) }
                guard let key = result.columns.first(where: { $0.field.id == "plays" })?.cacheKey else { return nil }
                let plays = result.rows.reduce(0) { sum, row in
                    if case .value(.number(let n))? = row.cells[key] { return sum + Int(n) }
                    return sum
                }
                return (plays, result.rows.count)
            }

            // MARK: The specs
            let day = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15))!   // a mid-June day: no clock change
            let startOfDay = calendar.startOfDay(for: day)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.addingTimeInterval(-1)
            let slot = startOfDay.addingTimeInterval(15 * 3600 + 30 * 60)   // 3:30 PM

            let hourDrill = OverviewDrill.hour(slotDate: slot, hour: 15)
            check("an hour opens that day as the period", hourDrill.spec.period == QueryPeriod(from: startOfDay, to: endOfDay))
            check("and filters the plays to exactly that clock hour, any weekday", hourDrill.spec.playFilter == QueryPlayFilter(weekdays: nil, fromHour: 15, toHour: 15))
            check("lists the plays themselves, newest first, with the time as a column", hourDrill.spec.target == .scrobble && hourDrill.spec.groups.isEmpty && hourDrill.spec.sorts.count == 1 && hourDrill.spec.columns == [QueryFieldRef("playedAt")] && hourDrill.spec.limit == QuerySpec.scrobbleLimit)
            check("the hour is named for Query's header", hourDrill.detail.hasPrefix("Scrobbles · ") && hourDrill.detail.contains("3 PM"), hourDrill.detail)

            let dayDrill = OverviewDrill.day(key: "2026-06-15")
            check("a streak day opens exactly that local day", dayDrill?.spec.period == QueryPeriod(from: startOfDay, to: endOfDay) && dayDrill?.spec.playFilter == nil)
            check("and is named for Query's header", dayDrill?.detail.hasPrefix("Scrobbles · ") == true && dayDrill?.detail.contains("2026") == true, dayDrill?.detail ?? "none")
            check("a day name that isn't a date opens nothing", OverviewDrill.day(key: "") == nil && OverviewDrill.day(key: "2026-06") == nil && OverviewDrill.day(key: "soon") == nil)
            check("a day's range is a day, to the last second", { let r = OverviewDrill.dayRange(containing: slot, calendar: calendar); return r.from == startOfDay && r.to == endOfDay }())

            // The clock changes: a day is 23 or 25 hours long, and the range follows the calendar rather than 86,400 seconds.
            var newYork = Calendar(identifier: .gregorian)
            newYork.timeZone = TimeZone(identifier: "America/New_York")!
            let springDay = newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
            let fallDay = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
            let spring = OverviewDrill.dayRange(containing: springDay, calendar: newYork)
            let fall = OverviewDrill.dayRange(containing: fallDay, calendar: newYork)
            check("the day the clocks go forward is 23 hours, ending at its own last second", spring.to.timeIntervalSince(spring.from) == 23 * 3600 - 1 && newYork.component(.hour, from: spring.to) == 23)
            check("the day they go back is 25 hours, ending at its own last second", fall.to.timeIntervalSince(fall.from) == 25 * 3600 - 1 && newYork.component(.hour, from: fall.to) == 23)

            // MARK: The counts, through the real query code, on plays at the edges
            func play(_ offset: TimeInterval, _ track: String, _ artist: String = "Artist A") -> ScrobbleSnapshot {
                ScrobbleSnapshot(artistName: artist, albumName: "Album", trackName: track, imageURL: nil, playedAt: startOfDay.addingTimeInterval(offset))
            }
            let plays: [ScrobbleSnapshot] = [
                play(-1, "Before"), play(0, "Midnight"), play(1, "Midnight +1s"), play(14 * 3600 + 59 * 60 + 59, "Before the hour"),
                play(15 * 3600, "Hour start"), play(15 * 3600 + 1800, "Hour middle"), play(15 * 3600 + 1800, "Hour middle", "Artist B"),
                play(15 * 3600 + 3599, "Hour end"), play(16 * 3600, "After the hour"), play(23 * 3600 + 3599, "Last second"),
                play(24 * 3600, "Next day"),
            ]
            let dayCount = plays.filter { $0.playedAt >= startOfDay && $0.playedAt <= endOfDay }.count
            let hourCount = plays.filter { calendar.startOfDay(for: $0.playedAt) == startOfDay && calendar.component(.hour, from: $0.playedAt) == 15 }.count
            let dayResult = dayDrill.flatMap { totalPlays($0.spec, over: plays) }
            let hourResult = totalPlays(hourDrill.spec, over: plays)
            check("the day's query counts every play in the day and none outside it (\(dayCount))", dayResult?.plays == dayCount, "\(dayResult?.plays ?? -1) vs \(dayCount)")
            check("the hour's query counts exactly the plays in that hour of that day (\(hourCount))", hourResult?.plays == hourCount, "\(hourResult?.plays ?? -1) vs \(hourCount)")
            check("the made-up plays are as intended: nine in the day (both edge seconds included), four in the hour", dayCount == 9 && hourCount == 4, "\(dayCount) \(hourCount)")
            let nextDay = OverviewDrill.day(key: "2026-06-16").flatMap { totalPlays($0.spec, over: plays) }
            check("the next day's cell counts only its own play", nextDay?.plays == 1, "\(nextDay?.plays ?? -1)")

            // MARK: A copy of a real library, when there is one: the busiest day and the busiest hour in it
            let history = (try? await ScrobbleHistoryCache.shared.snapshots(container: container)) ?? []
            if history.count > 1000 {
                var perDay: [String: Int] = [:]
                for s in history { perDay[ListeningStreakEngine.dayKey(s.playedAt, calendar: calendar), default: 0] += 1 }
                if let busiest = perDay.max(by: { $0.value < $1.value }), let drill = OverviewDrill.day(key: busiest.key) {
                    let counted = totalPlays(drill.spec, over: history)
                    check("real library: the busiest day's query counts the same plays as the streak strip would show (\(busiest.value))", counted?.plays == busiest.value, "\(counted?.plays ?? -1) vs \(busiest.value)")
                    let inDay = history.filter { ListeningStreakEngine.dayKey($0.playedAt, calendar: calendar) == busiest.key }
                    var perHour: [Int: Int] = [:]
                    for s in inDay { perHour[calendar.component(.hour, from: s.playedAt), default: 0] += 1 }
                    if let hour = perHour.max(by: { $0.value < $1.value }), let first = inDay.first {
                        let hourly = OverviewDrill.hour(slotDate: first.playedAt, hour: hour.key)
                        let counted = totalPlays(hourly.spec, over: history)
                        check("real library: that day's busiest hour counts exactly its plays (\(hour.value))", counted?.plays == hour.value, "\(counted?.plays ?? -1) vs \(hour.value)")
                    }
                }
            } else {
                print("      (no library copy here: the real-data cross-check was skipped)")
            }

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
