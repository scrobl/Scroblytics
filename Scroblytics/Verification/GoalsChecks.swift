import AppKit
import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_GOALS_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the Goals tool's burn-down, habit estimates and
/// forecasts on made-up data, each against a hand-worked answer. Exits 0 on success.
enum GoalsChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        if ProcessInfo.processInfo.environment["SCROBLYTICS_GOALS_DUMP"] != nil {
            dump(container: container)
            return
        }
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_GOALS_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let day0 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
            func at(_ day: Int, hour: Int = 12) -> Date {
                calendar.date(byAdding: .hour, value: day * 24 + hour, to: day0)!
            }
            let now = at(10)
            let goal = ListeningGoal(title: "Hear them all", start: at(0, hour: 9), deadline: at(30, hour: 20), lookbackDays: 30)

            // MARK: A small, hand-worked history
            // Ten loved tracks: Song 1...8 are loved from before the goal (no date known), Song 9 on day 5, Song 10 on day 8.
            func love(_ n: Int, on day: Int? = nil) -> GoalLove {
                GoalLove(
                    key: TextNormalization.lovedKey(artist: "Artist A", track: "Song \(n)"), artist: "Artist A", track: "Song \(n)",
                    lovedAt: day.map { at($0) }
                )
            }
            let loves = (1...8).map { love($0) } + [love(9, on: 5), love(10, on: 8)]
            var plays: [ScrobbleSnapshot] = []
            func play(_ track: String, day: Int, artist: String = "Artist A") {
                plays.append(ScrobbleSnapshot(artistName: artist, albumName: "", trackName: track, imageURL: nil, playedAt: at(day, hour: 10)))
            }
            play("Song 6", day: -3)                                  // before the goal: not a hear, but it tells the rate
            play("Song 1", day: 0); play("Song 2", day: 0)
            play("Song 1", day: 2); play("Song 3", day: 2)
            play("Song 4", day: 3)
            play("Song 9", day: 4)                                   // heard the day before it was loved: never owed
            play("Song 5", day: 6)
            play("Song 10", day: 9)                                  // loved on day 8, heard on day 9: owed for one day
            for d in 0...9 { play("Other", day: d, artist: "Artist Z"); play("Other 2", day: d, artist: "Artist Z") }
            plays.sort { $0.playedAt < $1.playedAt }

            let analysis = GoalEngine.analyze(goal: goal, loves: loves, plays: plays, now: now, calendar: calendar)
            check("today is day 10 and the deadline day 30", analysis.todayIndex == 10 && analysis.deadlineIndex == 30 && analysis.daysLeft == 20,
                  "\(analysis.todayIndex) \(analysis.deadlineIndex) \(analysis.daysLeft)")
            check("the burn-down matches the hand-worked list", analysis.actual == [6, 6, 5, 4, 4, 4, 3, 3, 4, 3, 3], "\(analysis.actual)")
            check("loved tracks that belong to the goal grow as loves are added", analysis.members == [8, 8, 8, 8, 8, 9, 9, 9, 10, 10, 10], "\(analysis.members)")
            check("a track heard before it was loved is never owed", analysis.actual[4] == analysis.actual[5])
            check("the counts add up", analysis.baselineAtStart == 8 && analysis.membersNow == 10 && analysis.remainingNow == 3 && analysis.heardNow == 7)
            check("the straight plan runs from the starting tracks to nothing at the end of the deadline day",
                  abs(analysis.plan[0] - 8.0 * 30.0 / 31.0) < 1e-9 && abs(analysis.plan[30]) < 1e-9 && analysis.plan.count == 31)
            check("the unheard tracks are listed", analysis.remaining.map(\.track) == ["Song 6", "Song 7", "Song 8"], "\(analysis.remaining.map(\.track))")
            check("the pace needed counts today", abs(analysis.requiredPerDay - 3.0 / 21.0) < 1e-9)

            let habits = analysis.habits
            let totalInLookback = plays.count          // every play is inside the 30 days before day 10
            let lovedInLookback = plays.filter { $0.artistName == "Artist A" }.count
            check("plays a day come from the lookback", abs(habits.playsPerDay - Double(totalInLookback) / 30) < 1e-9, "\(habits.playsPerDay)")
            check("loved plays a day come from the lookback", abs(habits.lovedPlaysPerDay - Double(lovedInLookback) / 30) < 1e-9, "\(habits.lovedPlaysPerDay)")
            // Song 6 was played once before the goal (inside the lookback): it keeps its own rate; the others take the dormant one.
            // Of the 8 loved from the start, 6 were played in the lookback (Songs 1-6), so 6 of 8 came back.
            check("a track played before the goal keeps its own rate", abs(habits.remainingRates[0] - 1.0 / 30) < 1e-9, "\(habits.remainingRates)")
            let expectedDormant = -log(1 - 0.75) / 30
            check("tracks with no recent plays take the rate at which dormant ones came back", abs(habits.dormantRate - expectedDormant) < 1e-9
                    && habits.dormantSample == 8 && abs(habits.remainingRates[1] - expectedDormant) < 1e-9, "\(habits.dormantRate) \(habits.dormantSample)")
            check("recent loves and the share still unplayed when loved are read from the dates",
                  habits.hasLoveDates && habits.lovesInLookback == 2 && abs(habits.unplayedShareOfLoves - 0.5) < 1e-9 && abs(habits.newLovesPerDay - 2.0 / 30) < 1e-9,
                  "\(habits.lovesInLookback) \(habits.unplayedShareOfLoves)")

            let noDates = GoalEngine.analyze(goal: goal, loves: (1...8).map { love($0) }, plays: plays, now: now, calendar: calendar)
            check("without love dates the loves count from the first day and nothing is expected to arrive",
                  !noDates.habits.hasLoveDates && noDates.members.allSatisfy { $0 == 8 }
                    && GoalSimulator.setup(from: noDates, goal: goal).newLovesPerDay == 0)
            let overdue = GoalEngine.analyze(goal: goal, loves: loves, plays: plays, now: at(40), calendar: calendar)
            check("after the deadline nothing is left to forecast", overdue.daysLeft == 0 && overdue.todayIndex == 40)
            let done = GoalEngine.analyze(goal: goal, loves: (1...2).map { love($0) }, plays: plays, now: now, calendar: calendar)
            check("a finished goal says when", done.remainingNow == 0 && done.completedIndex == 0, "\(String(describing: done.completedIndex))")

            // MARK: A bulk day of loves
            // 60 more loves, all dated day 4 (an import), alongside the ten above.
            let bulk = (11...70).map { love($0, on: 4) }
            let withBulk = GoalEngine.analyze(goal: goal, loves: loves + bulk, plays: plays, now: now, calendar: calendar)
            check("a bulk day of loves counts as loved from the first day",
                  withBulk.bulkLoves == 60 && withBulk.bulkLoveDays.count == 1 && withBulk.baselineAtStart == 8 + 60
                    && withBulk.members.first == 68 && withBulk.members.allSatisfy { $0 >= 68 } && withBulk.remainingNow == 3 + 60,
                  "\(withBulk.bulkLoves) \(withBulk.baselineAtStart) \(String(describing: withBulk.members.first)) \(withBulk.remainingNow)")
            let separate = ListeningGoal(title: "x", start: goal.start, deadline: goal.deadline, lookbackDays: 30, countBulkLovesFromStart: false)
            let asDated = GoalEngine.analyze(goal: separate, loves: loves + bulk, plays: plays, now: now, calendar: calendar)
            check("with the setting off, they join on their date as a jump",
                  asDated.bulkLoves == 60 && asDated.members[3] == 8 && asDated.members[4] == 68 && asDated.actual[4] == analysis.actual[4] + 60,
                  "\(asDated.members[3]) \(asDated.members[4]) \(asDated.actual[4])")
            check("a bulk day is left out of the rate of new loves",
                  withBulk.habits.lovesInLookback == 2 && withBulk.habits.hasLoveDates, "\(withBulk.habits.lovesInLookback)")
            check("a few loves on a day are not a bulk day", analysis.bulkLoves == 0 && analysis.bulkLoveDays.isEmpty)

            // MARK: Only tracks in the Apple Music library
            var presence = LibraryPresenceSnapshot()
            presence.checkedAt = now
            func status(_ n: Int, inLibrary: Bool, near: Bool = false) {
                presence.entries[LibraryGapsEngine.key(artist: "Artist A", track: "Song \(n)")] = .init(inLibrary: inLibrary, hasNearMatch: near, lastSeenAt: nil)
            }
            status(6, inLibrary: false)                       // still to hear, not in the library
            status(7, inLibrary: false, near: true)           // a close variant counts as in it
            status(1, inLibrary: false)                       // already heard, not in the library
            // Song 8 has no status at all.
            var libraryGoal = goal
            libraryGoal.inAppleLibraryOnly = true
            let libraryOnly = GoalCompute.run(goal: libraryGoal, loves: loves, plays: plays, presence: presence, now: now, calendar: calendar)
            check("tracks known to be missing from the library are left out, heard or not",
                  libraryOnly.leftOutOfLibrary == 2 && libraryOnly.analysis.membersNow == 8 && libraryOnly.analysis.remaining.map(\.track) == ["Song 7", "Song 8"],
                  "\(libraryOnly.leftOutOfLibrary) \(libraryOnly.analysis.membersNow) \(libraryOnly.analysis.remaining.map(\.track))")
            check("a track with no saved status stays in", libraryOnly.analysis.remaining.contains { $0.track == "Song 8" })
            let unchecked = GoalCompute.run(goal: libraryGoal, loves: loves, plays: plays, presence: LibraryPresenceSnapshot(), now: now, calendar: calendar)
            check("when the library was never checked nothing is left out and the page says so",
                  unchecked.libraryNeverChecked && unchecked.leftOutOfLibrary == 0 && unchecked.analysis.membersNow == 10)
            let notAsked = GoalCompute.run(goal: goal, loves: loves, plays: plays, presence: presence, now: now, calendar: calendar)
            check("a goal that doesn't ask for it ignores the library", notAsked.leftOutOfLibrary == 0 && notAsked.analysis.membersNow == 10 && !notAsked.libraryNeverChecked)
            check("the setting is saved and defaults to off",
                  (try? JSONDecoder().decode(ListeningGoal.self, from: JSONEncoder().encode(libraryGoal)))?.inAppleLibraryOnly == true
                    && (try? JSONDecoder().decode(GoalsState.self, from: Data("{\"goals\":[{\"id\":\"\(goal.id.uuidString)\",\"title\":\"x\",\"start\":0,\"deadline\":86400}]}".utf8)))?.goals.first?.inAppleLibraryOnly == false)
            // MARK: Every assumption changes the answer
            let base = GoalCompute.run(goal: goal, loves: loves, plays: plays, presence: nil, now: now, calendar: calendar)
            var manyLoves = goal; manyLoves.lovesPerMonth = 300
            var noLoves = goal; noLoves.lovesPerMonth = 0
            var tinyShare = goal; tinyShare.dedicatedShare = 0.02
            var fullShare = goal; fullShare.dedicatedShare = 1
            var shortLookback = goal; shortLookback.lookbackDays = 14
            var longLookback = goal; longLookback.lookbackDays = 120
            var offLoves = goal; offLoves.expectNewLoves = false
            func run(_ g: ListeningGoal) -> GoalResult {
                GoalCompute.run(goal: g, loves: loves, plays: plays, presence: nil, now: now, calendar: calendar)
            }
            let heavy = run(manyLoves), none = run(noLoves)
            check("loves a month changes the forecast and the loves expected",
                  heavy.expectedLovesPerDay > none.expectedLovesPerDay && heavy.forecasts[.habits] != none.forecasts[.habits],
                  "\(heavy.expectedLovesPerDay) \(none.expectedLovesPerDay)")
            check("turning off expected loves drops them to zero", run(offLoves).expectedLovesPerDay == 0)
            check("the share of listening for unheard tracks changes the habits and shuffle lines, not unplayed first",
                  run(tinyShare).forecasts[.habits] != run(fullShare).forecasts[.habits]
                    && run(tinyShare).forecasts[.shuffle] != run(fullShare).forecasts[.shuffle]
                    && run(tinyShare).forecasts[.dedicated] == run(fullShare).forecasts[.dedicated],
                  "")
            check("with the setting off nothing is added to habits and shuffle",
                  run(goal).dedicatedPerDay == 0 && run(fullShare).dedicatedPerDay == run(fullShare).analysis.habits.playsPerDay)
            check("the lookback changes the habits it learns",
                  run(shortLookback).analysis.habits != run(longLookback).analysis.habits)
            check("an unchanged goal gives an identical answer", base.forecasts == run(goal).forecasts)

            // MARK: A goal that starts in the future
            var future = ListeningGoal(title: "Later", start: at(40, hour: 9), deadline: at(100, hour: 20), lookbackDays: 30)
            future.lovesPerMonth = 30.4375
            let early = GoalCompute.run(goal: future, loves: loves, plays: plays, now: now, calendar: calendar)
            let fa = early.analysis
            check("a goal that hasn't started says how long until it does and counts from its first day",
                  fa.daysUntilStart == 30 && fa.todayIndex == 0 && fa.daysLeft == 60 && fa.deadlineIndex == 60, "\(fa.daysUntilStart) \(fa.todayIndex) \(fa.daysLeft)")
            check("before the start every loved track is still owed, whatever was played earlier",
                  fa.actual == [10] && fa.remainingNow == 10 && fa.heardNow == 0 && fa.membersNow == 10 && fa.baselineAtStart == 10, "\(fa.actual) \(fa.remainingNow)")
            check("the loves expected before it starts are counted: a love a day for thirty days",
                  early.leadLoves == 30, "\(early.leadLoves)")
            var noneExpected = future; noneExpected.expectNewLoves = false
            check("none are counted when new loves aren't expected", GoalCompute.run(goal: noneExpected, loves: loves, plays: plays, now: now, calendar: calendar).leadLoves == 0)
            check("an ordinary goal has no lead time", GoalCompute.run(goal: goal, loves: loves, plays: plays, now: now, calendar: calendar).analysis.daysUntilStart == 0
                  && GoalCompute.run(goal: goal, loves: loves, plays: plays, now: now, calendar: calendar).leadLoves == 0)
            let moreToHear = early.forecasts[.habits]!
            let nowStarted = GoalCompute.run(goal: noneExpected, loves: loves, plays: plays, now: now, calendar: calendar).forecasts[.habits]!
            check("the extra loves make the forecast start higher than it would without them", moreToHear.median.first! > nowStarted.median.first!, "\(moreToHear.median.first!) \(nowStarted.median.first!)")

            // MARK: The landing page's cards
            func status(_ g: ListeningGoal, plays p: [ScrobbleSnapshot] = plays, now n: Date = now) -> (GoalCardStatus, GoalAnalysis) {
                let a = GoalCompute.analysis(goal: g, loves: loves, plays: p, now: n, calendar: calendar)
                return (GoalCardStatus(a), a)
            }
            let (futureStatus, futureAnalysis) = status(future)
            check("a goal that hasn't started says so and shows no progress",
                  futureStatus.kind == .notStarted && futureStatus.headline == "Starts in 30 days" && futureStatus.heardShare == 0 && futureStatus.planShare == 0,
                  "\(futureStatus)")
            check("the summary needs no forecast: it equals the full result's burn-down",
                  futureAnalysis.actual == early.analysis.actual && futureAnalysis.remainingNow == early.analysis.remainingNow)
            let (activeStatus, activeAnalysis) = status(goal)
            let planToday = activeAnalysis.plan[activeAnalysis.todayIndex]
            let gap = Int((planToday - Double(activeAnalysis.remainingNow)).rounded())
            check("an active goal compares what is left with the straight-line plan",
                  [GoalCardStatus.Kind.ahead, .behind, .onPlan].contains(activeStatus.kind)
                    && activeStatus.heardShare == Double(activeAnalysis.heardNow) / Double(activeAnalysis.membersNow)
                    && (activeStatus.kind == .ahead ? gap >= 1 : activeStatus.kind == .behind ? gap <= -1 : abs(gap) < 1),
                  "\(activeStatus) plan \(planToday) left \(activeAnalysis.remainingNow)")
            let allHeard = plays + loves.map { ScrobbleSnapshot(artistName: $0.artist, albumName: "", trackName: $0.track, imageURL: nil, playedAt: at(9)) }
            check("a goal with nothing left is achieved", status(goal, plays: allHeard.sorted { $0.playedAt < $1.playedAt }).0.kind == .complete
                  && status(goal, plays: allHeard.sorted { $0.playedAt < $1.playedAt }).0.headline == "Achieved")
            check("a goal past its deadline with tracks left is missed",
                  status(goal, now: at(60)).0.kind == .missed && status(goal, now: at(60)).0.headline == "Deadline passed", "\(status(goal, now: at(60)).0)")
            check("with no loved tracks the card says so", GoalCardStatus(GoalCompute.analysis(goal: goal, loves: [], plays: plays, now: now, calendar: calendar)).kind == .empty)
            let nearly = GoalCompute.analysis(goal: goal, loves: loves, plays: plays, now: now, calendar: calendar)
            check("the percent heard is never 100 while a track is left, and is 100 when none is",
                  GoalCardStatus.percent(nearly) < 100 && GoalCardStatus.percent(GoalCompute.analysis(goal: goal, loves: loves, plays: allHeard.sorted { $0.playedAt < $1.playedAt }, now: now, calendar: calendar)) == 100)
            // The landing page's two lists.
            let doneGoal = ListeningGoal(title: "Done", start: at(-20), deadline: at(30, hour: 20))
            let newer = ListeningGoal(title: "Newer", start: at(2), deadline: at(30, hour: 20))
            let older = ListeningGoal(title: "Older", start: at(-5), deadline: at(30, hour: 20))
            let lapsed = ListeningGoal(title: "Lapsed", start: at(-8), deadline: at(5, hour: 20))
            let sectionAnalyses: [UUID: GoalAnalysis] = [
                doneGoal.id: GoalCompute.analysis(goal: doneGoal, loves: loves, plays: allHeard.sorted { $0.playedAt < $1.playedAt }, now: now, calendar: calendar),
                newer.id: GoalCompute.analysis(goal: newer, loves: loves, plays: plays, now: now, calendar: calendar),
                older.id: GoalCompute.analysis(goal: older, loves: loves, plays: plays, now: now, calendar: calendar),
                lapsed.id: GoalCompute.analysis(goal: lapsed, loves: loves, plays: plays, now: now, calendar: calendar),
            ]
            let split = GoalSections.split(goals: [older, doneGoal, newer, lapsed], analyses: sectionAnalyses)
            check("active goals (running or not started) are listed newest start first",
                  split.active.map(\.title) == ["Newer", "Older"], "\(split.active.map(\.title))")
            check("achieved goals and goals past their deadline are completed, newest start first",
                  split.completed.map(\.title) == ["Lapsed", "Done"], "\(split.completed.map(\.title))")
            check("a goal not yet worked out is listed as active",
                  GoalSections.split(goals: [doneGoal], analyses: [:]).active.map(\.title) == ["Done"])
            check("the plan tick is a share between 0 and 1", activeStatus.planShare >= 0 && activeStatus.planShare <= 1)

            // MARK: Tracks set aside from a goal
            var aside = goal
            let song7 = loves.first { $0.track == "Song 7" }!, song1 = loves.first { $0.track == "Song 1" }!
            aside.setAside = [GoalSetAside(key: song7.key, artist: song7.artist, track: song7.track)]
            let withAside = GoalCompute.run(goal: aside, loves: loves, plays: plays, now: now, calendar: calendar)
            let without = GoalCompute.run(goal: goal, loves: loves, plays: plays, now: now, calendar: calendar)
            check("a track set aside is not counted: not a member, not still to hear",
                  withAside.analysis.membersNow == without.analysis.membersNow - 1
                    && withAside.analysis.remainingNow == without.analysis.remainingNow - 1
                    && !withAside.analysis.remaining.contains { $0.track == "Song 7" }
                    && withAside.analysis.remaining.count == without.analysis.remaining.count - 1,
                  "\(withAside.analysis.membersNow) \(withAside.analysis.remainingNow)")
            aside.setAside.append(GoalSetAside(key: song1.key, artist: song1.artist, track: song1.track))
            let heardAside = GoalCompute.run(goal: aside, loves: loves, plays: plays, now: now, calendar: calendar)
            check("setting aside a track already heard removes it from both counts",
                  heardAside.analysis.membersNow == without.analysis.membersNow - 2 && heardAside.analysis.heardNow == without.analysis.heardNow - 1,
                  "\(heardAside.analysis.membersNow) \(heardAside.analysis.heardNow)")
            check("the burn-down is consistent after setting tracks aside",
                  heardAside.analysis.actual.last == heardAside.analysis.remainingNow && heardAside.analysis.heardNow + heardAside.analysis.remainingNow == heardAside.analysis.membersNow)
            check("the summary card sees the same numbers",
                  GoalCompute.analysis(goal: aside, loves: loves, plays: plays, now: now, calendar: calendar).remainingNow == heardAside.analysis.remainingNow)
            var asideLibrary = aside; asideLibrary.inAppleLibraryOnly = true
            let withLibrary = GoalCompute.run(goal: asideLibrary, loves: loves, plays: plays, presence: presence, now: now, calendar: calendar)
            check("a track set aside is not also counted as left out of the library",
                  withLibrary.leftOutOfLibrary == 1 && withLibrary.analysis.membersNow == 7, "\(withLibrary.leftOutOfLibrary) \(withLibrary.analysis.membersNow)")
            let savedAside = try? JSONDecoder().decode(ListeningGoal.self, from: JSONEncoder().encode(aside))
            check("tracks set aside are saved, and an older goal has none", savedAside?.setAside == aside.setAside
                    && (try? JSONDecoder().decode(GoalsState.self, from: Data("{\"goals\":[{\"id\":\"\(goal.id.uuidString)\",\"title\":\"x\",\"start\":0,\"deadline\":86400}]}".utf8)))?.goals.first?.setAside.isEmpty == true)

            // MARK: Goals about other tracks: artists, tags, not loved, all
            let history = GoalMembership.historyTracks(plays: plays)
            let lovedKeys = Set(loves.map(\.key))
            func members(_ criteria: GoalCriteria, tags: EntityTagsSnapshot = .empty) -> GoalMembers {
                var g = goal; g.criteria = criteria
                return GoalMembership.members(goal: g, loved: loves, history: history, tags: tags)
            }
            check("the history lists each played track once, with its first play",
                  history.count == Set(history.map(\.key)).count && history.first { $0.track == "Song 6" }?.firstPlayed == at(-3, hour: 10)
                    && history.first { $0.track == "Other" }?.firstPlayed == at(0, hour: 10), "\(history.count)")
            let lovedMembers = members(GoalCriteria())
            check("the default is every loved track, joining on the day it was loved",
                  lovedMembers.loves == loves && !lovedMembers.joinsOnPlay && GoalCriteria().isLovedOnly)
            check("loved tracks can be narrowed to an artist, in any case",
                  members(GoalCriteria(artists: ["artist a"])).loves.count == 10 && members(GoalCriteria(artists: ["Artist Z"])).loves.isEmpty)
            let unloved = members(GoalCriteria(loved: .notLoved))
            check("not loved: tracks in the history that aren't loved, joining on their first play",
                  unloved.joinsOnPlay && Set(unloved.loves.map(\.track)) == ["Other", "Other 2"] && unloved.loves.allSatisfy { !lovedKeys.contains($0.key) },
                  "\(unloved.loves.map(\.track))")
            let everything = members(GoalCriteria(loved: .any))
            check("all tracks: every played track, loved or not (an unplayed love isn't known)",
                  Set(everything.loves.map(\.track)) == ["Song 1", "Song 2", "Song 3", "Song 4", "Song 5", "Song 6", "Song 9", "Song 10", "Other", "Other 2"],
                  "\(everything.loves.map(\.track))")
            check("an artist narrows the history too", members(GoalCriteria(loved: .any, artists: ["Artist Z"])).loves.count == 2)
            // Tags: Artist Z has its tags looked up, Artist A has none yet.
            var known = EntityTagsSnapshot()
            known.artistCommunity[EntityTagsSnapshot.artistKey("Artist Z")] = ["Indie", "lo-fi"]
            let tagged = members(GoalCriteria(loved: .any, tags: ["indie"]), tags: known)
            check("a tag keeps tracks whose artist has it, and counts the ones that can't be told yet",
                  Set(tagged.loves.map(\.artist)) == ["Artist Z"] && tagged.pendingTags == 8, "\(tagged.loves.count) pending \(tagged.pendingTags)")
            check("a tag nobody has matches nothing", members(GoalCriteria(loved: .any, tags: ["metal"]), tags: known).loves.isEmpty)
            known.entityCommunity[EntityTagKey.make(kind: .track, artist: "Artist Z", name: "Other")] = ["metal"]
            check("a track's own tags win over its artist's",
                  members(GoalCriteria(loved: .any, tags: ["metal"]), tags: known).loves.map(\.track) == ["Other"]
                    && members(GoalCriteria(loved: .any, tags: ["indie"]), tags: known).loves.map(\.track) == ["Other 2"])
            // The burn-down of a goal about played tracks, starting on day 5.
            var anyGoal = ListeningGoal(title: "All", start: at(5, hour: 9), deadline: at(30, hour: 20), lookbackDays: 30, criteria: GoalCriteria(loved: .any))
            let everyone = GoalCompute.run(goal: anyGoal, members: members(anyGoal.criteria), plays: plays, now: now, calendar: calendar)
            check("played tracks owe a play since the start; ones played after it are heard",
                  everyone.analysis.membersNow == 10 && everyone.analysis.remainingNow == 6
                    && Set(everyone.analysis.remaining.map(\.track)) == ["Song 1", "Song 2", "Song 3", "Song 4", "Song 6", "Song 9"],
                  "\(everyone.analysis.remainingNow) \(everyone.analysis.remaining.map(\.track))")
            check("no new tracks are ever owed: no expected loves, no love dates, no bulk loves",
                  everyone.expectedLovesPerDay == 0 && !everyone.analysis.habits.hasLoveDates && everyone.analysis.bulkLoves == 0 && everyone.leadLoves == 0
                    && everyone.analysis.joinsOnPlay)
            // A day of sixty first plays is discovery, not a bulk love.
            var discovery = plays
            for i in 0..<60 { discovery.append(ScrobbleSnapshot(artistName: "Artist D", albumName: "", trackName: "New \(i)", imageURL: nil, playedAt: at(6, hour: 11))) }
            discovery.sort { $0.playedAt < $1.playedAt }
            let discoveryHistory = GoalMembership.historyTracks(plays: discovery)
            anyGoal.criteria = GoalCriteria(loved: .any)
            let found = GoalCompute.run(
                goal: anyGoal, members: GoalMembership.members(goal: anyGoal, loved: loves, history: discoveryHistory, tags: .empty), plays: discovery, now: now, calendar: calendar
            )
            check("a day of many first plays is not treated as a bulk day", found.analysis.bulkLoves == 0 && found.analysis.remainingNow == 6 && found.analysis.membersNow == 70,
                  "\(found.analysis.bulkLoves) \(found.analysis.remainingNow) \(found.analysis.membersNow)")
            let allHeardToo = found.analysis.actual
            check("a track first played after the start is never owed", allHeardToo.allSatisfy { $0 <= 6 }, "\(allHeardToo)")
            // Saving and describing.
            var shaped = goal; shaped.criteria = GoalCriteria(loved: .notLoved, artists: ["A", "B", "C"], tags: ["x"])
            check("criteria are saved, and an older goal means every loved track",
                  (try? JSONDecoder().decode(ListeningGoal.self, from: JSONEncoder().encode(shaped)))?.criteria == shaped.criteria
                    && (try? JSONDecoder().decode(GoalsState.self, from: Data("{\"goals\":[{\"id\":\"\(goal.id.uuidString)\",\"title\":\"x\",\"start\":0,\"deadline\":86400}]}".utf8)))?.goals.first?.criteria.isLovedOnly == true)
            check("criteria are described in words",
                  shaped.criteria.summary == "Tracks you haven't loved by A, B and 1 more tagged x" && GoalCriteria().suggestedTitle == "Hear all my loved tracks"
                    && GoalCriteria(loved: .any, artists: ["Artist A"]).suggestedTitle == "Hear all my tracks by Artist A",
                  shaped.criteria.summary)
            let wildCriteria = Data("{\"loved\":\"nonsense\",\"artists\":[\"A\"]}".utf8)
            check("an unknown loved setting reads as loved", (try? JSONDecoder().decode(GoalCriteria.self, from: wildCriteria))?.loved == .loved)

            // MARK: Sharing a goal
            let shareResult = GoalCompute.run(goal: goal, loves: loves, plays: plays, now: now, calendar: calendar)
            let shared = GoalShareCards.card(goal: goal, analysis: shareResult.analysis, result: shareResult, calendar: calendar, now: now)
            check("a goal becomes a native chart card with its name, dates and what it counts",
                  shared?.title == "Hear them all" && shared?.native != nil && shared?.measure == "Loved tracks" && shared?.kindID == "goal.burndown"
                    && shared?.period.contains("–") == true && shared?.defaultOptions.size == .wide)
            check("its sentence says where the goal stands, and its text lines carry the numbers",
                  shared?.native?.caption.hasPrefix("7 of 10 loved tracks heard (70%): 3 to go") == true
                    && shared?.native?.textLines.contains("Heard: 7 of 10") == true && shared?.native?.textLines.contains("To hear: 3") == true
                    && shared?.native?.textLines.contains { $0.hasPrefix("Your habits:") && $0.hasSuffix("chance of finishing by the deadline") } == true,
                  "\(shared?.native?.caption ?? "nil") \(shared?.native?.textLines ?? [])")
            check("the forecasts can be left out of the card, and the card from a list has none to offer",
                  Set(shared?.native?.controls.map(\.id) ?? []) == ["plan", "forecasts", "bands", "legend"]
                    && Set(GoalShareCards.card(goal: goal, analysis: shareResult.analysis, result: nil, calendar: calendar)?.native?.controls.map(\.id) ?? []) == ["plan", "legend"])
            let futureCard = GoalShareCards.card(goal: future, analysis: early.analysis, result: early, calendar: calendar, now: now)
            check("a goal that hasn't started says when it does", futureCard?.native?.caption.hasPrefix("Starts ") == true && futureCard?.native?.caption.contains("10 loved tracks to hear by") == true,
                  "\(futureCard?.native?.caption ?? "nil")")
            let doneCard = GoalShareCards.card(goal: goal, analysis: GoalCompute.analysis(goal: goal, loves: loves, plays: allHeard.sorted { $0.playedAt < $1.playedAt }, now: now, calendar: calendar), result: nil, calendar: calendar, now: now)
            check("an achieved goal says so, with how early", doneCard?.native?.caption.hasPrefix("Achieved: all 10 loved tracks heard by") == true && doneCard?.native?.caption.contains("days early") == true,
                  "\(doneCard?.native?.caption ?? "nil")")
            check("a goal with no tracks makes no card", GoalShareCards.card(goal: goal, analysis: GoalCompute.analysis(goal: goal, loves: [], plays: plays, now: now, calendar: calendar), result: nil, calendar: calendar) == nil)
            if let shared {
                for size in ShareSize.allCases {
                    var o = shared.defaultOptions; o.size = size
                    let png = ShareRenderer.png(card: shared, options: o, identity: .anonymous, images: [:], scale: 1)
                    let rep = png.flatMap { NSBitmapImageRep(data: $0) }
                    check("the goal card renders as a PNG at the \(size.label.lowercased()) size", rep?.pixelsWide == Int(size.points.width) && rep?.pixelsHigh == Int(size.points.height))
                }
                var withForecasts = shared.defaultOptions; withForecasts.flags["forecasts"] = true
                var without = shared.defaultOptions; without.flags["forecasts"] = false
                let a = ShareRenderer.png(card: shared, options: withForecasts, identity: .anonymous, images: [:], scale: 1)
                let b = ShareRenderer.png(card: shared, options: without, identity: .anonymous, images: [:], scale: 1)
                check("leaving the forecasts out changes the picture", a != nil && b != nil && a != b)
            }

            // MARK: Goals on the Overview
            func chosen(_ title: String, start: Int, on: Bool) -> ListeningGoal {
                var g = ListeningGoal(title: title, start: at(start), deadline: at(start + 100)); g.showOnOverview = on; return g
            }
            let overviewState = GoalsState(goals: [chosen("A", start: -30, on: true), chosen("B", start: -10, on: true), chosen("C", start: -20, on: false),
                                                   chosen("D", start: -50, on: true), chosen("E", start: -5, on: true)])
            check("the Overview takes the chosen goals, the most recently started first, and no more than three",
                  overviewState.overviewGoals.map(\.title) == ["E", "B", "A"], "\(overviewState.overviewGoals.map(\.title))")
            check("no goal is on the Overview until it is chosen, and the choice is saved",
                  !chosen("x", start: 0, on: false).showOnOverview
                    && (try? JSONDecoder().decode(ListeningGoal.self, from: JSONEncoder().encode(chosen("x", start: 0, on: true))))?.showOnOverview == true
                    && (try? JSONDecoder().decode(GoalsState.self, from: Data("{\"goals\":[{\"id\":\"\(goal.id.uuidString)\",\"title\":\"x\",\"start\":0,\"deadline\":86400}]}".utf8)))?.goals.first?.showOnOverview == false)
            check("with none chosen the Overview has nothing to show", GoalsState(goals: [chosen("A", start: -3, on: false)]).overviewGoals.isEmpty && GoalsState().overviewGoals.isEmpty)

            // MARK: The "Still to hear" list: history, filters, sorts
            // Still to hear here: Songs 6, 7, 8 (heard before the goal or never). Song 6 has one play, on day -3.
            var withPictures = plays
            withPictures.append(ScrobbleSnapshot(artistName: "Artist A", albumName: "Record", trackName: "Song 7", imageURL: "https://example.invalid/a.png", playedAt: at(-40)))
            withPictures.append(ScrobbleSnapshot(artistName: "Artist A", albumName: "Record", trackName: "Song 7", imageURL: "https://example.invalid/placeholder-2a96cbd8b46e442fc41c2b86b821562f.png", playedAt: at(-20)))
            withPictures.sort { $0.playedAt < $1.playedAt }
            let listed = GoalCompute.run(goal: goal, loves: loves, plays: withPictures, now: now, calendar: calendar)
            let left = listed.analysis.remaining
            let h6 = listed.history[left.first { $0.track == "Song 6" }!.key]
            let h7 = listed.history[left.first { $0.track == "Song 7" }!.key]
            check("history counts every play and finds the last one",
                  h6?.plays == 1 && h6?.lastPlayed == at(-3, hour: 10) && h7?.plays == 2 && h7?.lastPlayed == at(-20),
                  "\(String(describing: h6)) \(String(describing: h7))")
            check("a track's picture and album come from its plays, never a placeholder",
                  h7?.album == "Record" && h7?.imageURL == "https://example.invalid/a.png", "\(String(describing: h7))")
            check("a never-played track has no history", listed.history[left.first { $0.track == "Song 8" }!.key] == nil)
            func titles(_ filter: GoalRemainingFilter = .all, _ sort: GoalRemainingSort = .recentlyLoved, _ search: String = "") -> [String] {
                GoalRemainingList.apply(left, history: listed.history, filter: filter, sort: sort, search: search).map(\.track)
            }
            check("filters split played and never-played", titles(.playedBefore).sorted() == ["Song 6", "Song 7"] && titles(.neverPlayed) == ["Song 8"], "\(titles(.playedBefore)) \(titles(.neverPlayed))")
            check("search matches track or artist, ignoring case", titles(.all, .recentlyLoved, "song 7") == ["Song 7"] && titles(.all, .recentlyLoved, "ARTIST a").count == 3 && titles(.all, .recentlyLoved, "zzz").isEmpty)
            check("most played puts the track with more plays first", titles(.all, .mostPlayed).first == "Song 7")
            check("heard longest ago puts the older last play first and never-played last", titles(.all, .lastHeard) == ["Song 7", "Song 6", "Song 8"], "\(titles(.all, .lastHeard))")
            check("track order is alphabetical", titles(.all, .track) == ["Song 6", "Song 7", "Song 8"])
            check("sorting keeps every track exactly once", Set(GoalRemainingSort.allCases.flatMap { titles(.all, $0) }) == Set(left.map(\.track)) && titles(.all, .oldestLoved).count == left.count)

            check("the chart's zoom starts where it says",
                  GoalChartRange.whole.firstDay(todayIndex: 200) == 0 && GoalChartRange.back90.firstDay(todayIndex: 200) == 110
                    && GoalChartRange.back30.firstDay(todayIndex: 20) == 0 && GoalChartRange.back7.firstDay(todayIndex: 200) == 193 && GoalChartRange.back7.firstDay(todayIndex: 3) == 0 && GoalChartRange.ahead.firstDay(todayIndex: 200) == 200)

            // MARK: Forecasts
            func setup(rates: [Double], members: Int? = nil, lovedPerDay: Double = 0, perDay: Double = 10, arrivals: Double = 0, daysLeft: Int = 20) -> GoalSimulationSetup {
                GoalSimulationSetup(
                    remainingRates: rates, memberCount: members ?? rates.count, lovedPlaysPerDay: lovedPerDay, playsPerDay: perDay,
                    newLovesPerDay: arrivals, daysLeft: daysLeft, horizon: GoalSimulator.horizon(daysLeft: daysLeft)
                )
            }
            let hundred = [Double](repeating: 0, count: 100)
            let straight = GoalSimulator.forecast(.habits, setup: setup(rates: hundred), dedicatedPlaysPerDay: 5, seed: 7)
            check("giving five plays a day to a hundred unheard tracks is a straight line to zero",
                  straight.median[0] == 100 && straight.median[10] == 50 && straight.median[20] == 0 && straight.chanceByDeadline == 1
                    && straight.finishMedian == 20, "\(straight.median[10]) \(straight.median[20]) \(String(describing: straight.finishMedian))")
            check("half and nine tenths are reached on the straight line's days", straight.halfMedian == 10 && straight.ninetyMedian == 18,
                  "\(String(describing: straight.halfMedian)) \(String(describing: straight.ninetyMedian))")

            let shuffle = GoalSimulator.forecast(.shuffle, setup: setup(rates: [Double](repeating: 0.05, count: 100), lovedPerDay: 5), sims: 400, seed: 11)
            let expected20: Double = 100.0 * exp(-1.0 as Double)
            check("shuffling loved tracks empties the list as e^(-rate x days)", abs(shuffle.median[20] - expected20) < 5 && abs(shuffle.median[10] - 100.0 * exp(-0.5 as Double)) < 6,
                  "\(shuffle.median[10]) \(shuffle.median[20]) vs \(100.0 * exp(-0.5 as Double)) \(expected20)")
            check("shuffling takes far longer than playing each once: the last tenth is the slow part",
                  shuffle.chanceByDeadline < 0.05 && (shuffle.ninetyMedian ?? 0) > 40,
                  "\(shuffle.chanceByDeadline) \(String(describing: shuffle.ninetyMedian)) \(String(describing: shuffle.finishMedian))")
            check("a forecast's range holds its middle line and never rises without new loves",
                  zip(shuffle.low, zip(shuffle.median, shuffle.high)).allSatisfy { $0 <= $1.0 && $1.0 <= $1.1 }
                    && zip(shuffle.median, shuffle.median.dropFirst()).allSatisfy { $0 >= $1 })

            let again = GoalSimulator.forecast(.shuffle, setup: setup(rates: [Double](repeating: 0.05, count: 100), lovedPerDay: 5), sims: 400, seed: 11)
            let other = GoalSimulator.forecast(.shuffle, setup: setup(rates: [Double](repeating: 0.05, count: 100), lovedPerDay: 5), sims: 400, seed: 12)
            check("the same seed gives the same forecast, another gives another", again == shuffle && other != shuffle)

            let growing = GoalSimulator.forecast(.habits, setup: setup(rates: hundred, arrivals: 2), sims: 200, seed: 5)
            check("expected new loves add to what is left", growing.median[20] > 100 + 25 && growing.median[20] < 100 + 55, "\(growing.median[20])")
            let habitsOnly = GoalSimulator.forecast(.habits, setup: setup(rates: [Double](repeating: 0.05, count: 50)), sims: 300, seed: 3)
            check("habits use each track's own rate", abs(habitsOnly.median[20] - 50.0 * exp(-1.0 as Double)) < 5, "\(habitsOnly.median[20]) vs \(50.0 * exp(-1.0 as Double))")
            let mixed = GoalSimulator.forecast(.habits, setup: setup(rates: [Double](repeating: 0.05, count: 50)), dedicatedPlaysPerDay: 1, sims: 300, seed: 3)
            check("plays set aside for unheard tracks go on top of habits", mixed.median[20] < habitsOnly.median[20] - 5, "\(mixed.median[20]) \(habitsOnly.median[20])")
            let shuffleSetup = setup(rates: [Double](repeating: 0.05, count: 100), lovedPerDay: 5)
            let shuffleBase = GoalSimulator.forecast(.shuffle, setup: shuffleSetup, sims: 300, seed: 4)
            let shuffleMixed = GoalSimulator.forecast(.shuffle, setup: shuffleSetup, dedicatedPlaysPerDay: 2, sims: 300, seed: 4)
            check("the same plays go on top of a shuffle too", shuffleMixed.median[20] < shuffleBase.median[20] - 5, "\(shuffleMixed.median[20]) \(shuffleBase.median[20])")
            // Unplayed first is literal: every play (here ten a day) is a new track, whatever the habits or the dial say.
            let literalSetup = setup(rates: [Double](repeating: 0.3, count: 100), perDay: 10)
            let literal = GoalSimulator.forecast(.dedicated, setup: literalSetup, dedicatedPlaysPerDay: 1, sims: 100, seed: 8)
            check("unplayed first plays a new track with every play: a hundred tracks at ten plays a day take ten days",
                  literal.median[0] == 100 && literal.median[5] == 50 && literal.median[10] == 0 && literal.finishMedian == 10 && literal.chanceByDeadline == 1,
                  "\(literal.median[5]) \(literal.median[10]) \(String(describing: literal.finishMedian))")
            let literalWith = GoalSimulator.forecast(.dedicated, setup: literalSetup, dedicatedPlaysPerDay: 8, sims: 100, seed: 8)
            check("the amount set aside doesn't change unplayed first", literalWith == literal)

            // MARK: How much to give it
            let needed = GoalSimulator.neededDedicatedPlaysPerDay(setup: setup(rates: hundred, perDay: 10), seed: 9)
            check("a hundred unheard tracks in twenty days need five plays a day", needed.map { $0 >= 4.99 && $0 <= 5.1 } ?? false, "\(String(describing: needed))")
            check("when all of your listening isn't enough, there is no such amount", GoalSimulator.neededDedicatedPlaysPerDay(setup: setup(rates: hundred, perDay: 1), seed: 9) == nil)
            check("a goal already on course needs nothing extra",
                  GoalSimulator.neededDedicatedPlaysPerDay(setup: setup(rates: [Double](repeating: 1, count: 20), perDay: 10), seed: 9) == 0)

            // MARK: Saving
            let state = GoalsState(goals: [goal], selected: goal.id)
            let data = try? JSONEncoder().encode(state)
            check("goals survive being saved", data.flatMap { try? JSONDecoder().decode(GoalsState.self, from: $0) } == state)
            let old = Data("""
            {"goals":[{"id":"\(goal.id.uuidString)","title":"Old","start":0,"deadline":86400}]}
            """.utf8)
            let decodedOld = try? JSONDecoder().decode(GoalsState.self, from: old)
            check("a goal saved with fewer fields reads with the usual settings",
                  decodedOld?.goals.first.map { $0.lookbackDays == 90 && $0.expectNewLoves && $0.dedicatedShare == nil && $0.lovesPerMonth == nil } == true)
            let wild = Data("""
            {"goals":[{"id":"\(goal.id.uuidString)","title":"Wild","start":0,"deadline":86400,"lookbackDays":2,"dedicatedShare":4,"lovesPerMonth":-3}]}
            """.utf8)
            let decodedWild = try? JSONDecoder().decode(GoalsState.self, from: wild)
            check("out-of-range settings are brought back in range",
                  decodedWild?.goals.first.map { $0.lookbackDays == 14 && $0.dedicatedShare == 1 && $0.lovesPerMonth == 0 } == true)

            // MARK: Last.fm's loved list
            let json = Data("""
            {"lovedtracks":{"track":{"name":"Song 1","artist":{"name":"Artist A"},"date":{"uts":"1700000000","#text":"14 Nov 2023"}},
            "@attr":{"page":"1","perPage":"50","totalPages":"1","total":"1"}}}
            """.utf8)
            let page = try? LastfmAPIClient.lovedPage(fromJSON: json)
            check("a loved track's date is read (also when there is only one track)",
                  page?.tracks.count == 1 && page?.dates.first == Date(timeIntervalSince1970: 1_700_000_000), "\(String(describing: page?.dates))")
            let two = Data("""
            {"lovedtracks":{"track":[{"name":"A","artist":{"name":"X"},"date":{"uts":"1700000100","#text":""}},{"name":"B","artist":{"name":"Y"}}],
            "@attr":{"page":"1","perPage":"50","totalPages":"1","total":"2"}}}
            """.utf8)
            let pageTwo = try? LastfmAPIClient.lovedPage(fromJSON: two)
            check("a love with no date reads as unknown", pageTwo?.dates.count == 2 && pageTwo?.dates[0] != nil && pageTwo?.dates[1] == nil)

            // MARK: Love dates in the store
            let context = ModelContext(container)
            let entry = LovedTrackEntry(cacheKey: "goals check", artist: "Artist A", track: "Song 1")
            check("a love saved without a date has none", entry.lovedAt == nil)
            context.insert(entry)
            entry.lovedAt = Date(timeIntervalSince1970: 1_700_000_000)
            try? context.save()
            let fetched = (try? context.fetch(FetchDescriptor<LovedTrackEntry>(predicate: #Predicate { $0.cacheKey == "goals check" })))?.first
            check("a love's date is kept", fetched?.lovedAt == Date(timeIntervalSince1970: 1_700_000_000))
            if let fetched { context.delete(fetched); try? context.save() }

            // MARK: A large library
            var big: [ScrobbleSnapshot] = []
            big.reserveCapacity(400_000)
            let bigStart = at(-1200)
            for i in 0..<400_000 {
                let track = (i * 7919) % 5_000
                big.append(ScrobbleSnapshot(
                    artistName: "Artist \(track % 300)", albumName: "", trackName: "Track \(track)", imageURL: nil,
                    playedAt: bigStart.addingTimeInterval(Double(i) * 259)
                ))
            }
            big.sort { $0.playedAt < $1.playedAt }
            // A quarter of the loved tracks are ones that were played; the rest are never played.
            let bigLoves = (0..<800).map { i -> GoalLove in
                let played = i % 4 == 0
                let track = played ? "Track \((i * 6) % 5_000)" : "Loved \(i)"
                let artist = played ? "Artist \(((i * 6) % 5_000) % 300)" : "Artist \(i % 300)"
                return GoalLove(
                    key: TextNormalization.lovedKey(artist: artist, track: track), artist: artist, track: track,
                    lovedAt: i % 3 == 0 ? at(-Int.random(in: 0..<400)) : nil
                )
            }
            let bigGoal = ListeningGoal(title: "Big", start: at(-300), deadline: at(60))
            let started = Date()
            let bigAnalysis = GoalEngine.analyze(goal: bigGoal, loves: bigLoves, plays: big, now: now, calendar: calendar)
            let analyzeTime = Date().timeIntervalSince(started)
            let simStarted = Date()
            let bigSetup = GoalSimulator.setup(from: bigAnalysis, goal: bigGoal)
            let bigForecast = GoalSimulator.forecast(.habits, setup: bigSetup, seed: 1)
            let simTime = Date().timeIntervalSince(simStarted)
            let historyStarted = Date()
            let bigHistory = GoalCompute.history(of: bigAnalysis.remaining, plays: big)
            let historyTime = Date().timeIntervalSince(historyStarted)
            let poolStarted = Date()
            let bigPool = GoalMembership.historyTracks(plays: big)
            let poolTime = Date().timeIntervalSince(poolStarted)
            print(String(format: "      the same plays as a list of %d distinct tracks: %.2f s", bigPool.count, poolTime))
            check("the history of a large library is listed quickly", poolTime < 6 && !bigPool.isEmpty)
            print(String(format: "      400,000 plays and 800 loved tracks: analysis %.2f s, one 300-run forecast %.2f s, list history %.2f s (remaining now %d)", analyzeTime, simTime, historyTime, bigAnalysis.remainingNow))
            check("a large library is analysed quickly", analyzeTime < 6 && simTime < 6 && historyTime < 6 && bigAnalysis.remainingNow > 400, "\(bigAnalysis.remainingNow)")
            check("the list's history covers only tracks still to hear", bigHistory.keys.allSatisfy { key in bigAnalysis.remaining.contains { $0.key == key } })
            check("the large forecast starts where the burn-down ends", bigForecast.median.first == Double(bigAnalysis.remainingNow))

            print(failures == 0 ? "ALL GOALS CHECKS PASSED" : "\(failures) GOALS CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// `SCROBLYTICS_GOALS_DUMP=1` on a COPY of a real store (with `SCROBLYTICS_OFFLINE=1`): the burn-down for goals starting a month, three
    /// months and a year ago, against an independent recount (a set of loved tracks minus a set of the tracks played since the start).
    @MainActor
    private static func dump(container: ModelContainer) {
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let context = ModelContext(container)
            let stored = (try? context.fetch(FetchDescriptor<LovedTrackEntry>())) ?? []
            let loves = stored.map { GoalLove(key: $0.cacheKey, artist: $0.artist, track: $0.track, lovedAt: $0.lovedAt) }
            guard let plays = try? await ScrobbleHistoryCache.shared.snapshots(container: container) else { print("could not read the history"); exit(1) }
            let calendar = AppCalendars.listening
            let now = Date()
            print("loved tracks \(loves.count) (with a date: \(loves.filter { $0.lovedAt != nil }.count)), plays \(plays.count)")
            for days in [30, 90, 183, 365] {
                let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
                let goal = ListeningGoal(title: "Dump", start: start, deadline: calendar.date(byAdding: .day, value: 60, to: now)!)
                let began = Date()
                let result = GoalCompute.run(goal: goal, loves: loves, plays: plays, now: now, calendar: calendar)
                let took = Date().timeIntervalSince(began)
                // Independent: which loved tracks have a play on or after the start day?
                let keys = Set(loves.map(\.key))
                var played = Set<String>()
                for play in plays where play.playedAt >= start {
                    let key = TextNormalization.lovedKey(artist: play.artistName, track: play.trackName)
                    if keys.contains(key) { played.insert(key) }
                }
                let expectedRemaining = keys.subtracting(played)
                let a = result.analysis
                print(String(format: "  since %d days ago: %d heard, %d to hear, needed %@ a day, 'habits' %@ by the deadline (%.2f s)",
                             days, a.heardNow, a.remainingNow, result.neededPerDay.map { String(format: "%.1f", $0) } ?? "n/a",
                             result.forecasts[.habits].map { String(format: "%.0f%%", $0.chanceByDeadline * 100) } ?? "n/a", took))
                let biggestRise = zip(a.actual, a.actual.dropFirst()).map { $1 - $0 }.max() ?? 0
                print("      bulk-dated loves \(a.bulkLoves) on \(a.bulkLoveDays.count) day(s); baseline \(a.baselineAtStart); biggest one-day rise in what's left: \(biggestRise)")
                check("\(days) days: the tracks still to hear are exactly the loved ones not played since the start",
                      Set(a.remaining.map(\.key)) == expectedRemaining && a.remainingNow == expectedRemaining.count,
                      "\(a.remainingNow) vs \(expectedRemaining.count)")
                check("\(days) days: the last burn-down point is today's count and loved tracks add up", a.actual.last == a.remainingNow && a.heardNow + a.remainingNow == a.membersNow && a.membersNow == keys.count)
                check("\(days) days: the burn-down never rises without loves added",
                      zip(a.actual, zip(a.members, zip(a.actual.dropFirst(), a.members.dropFirst()))).allSatisfy { $0 >= $1.1.0 || $1.1.1 > $1.0 })
            }
            // How well the saved Apple Music library status covers the tracks still to hear.
            let presence = LibraryPresenceSnapshot.load(context: context)
            let goal = ListeningGoal(title: "Coverage", start: calendar.date(byAdding: .day, value: -183, to: calendar.startOfDay(for: now))!, deadline: calendar.date(byAdding: .day, value: 60, to: now)!)
            let analysis = GoalEngine.analyze(goal: goal, loves: loves, plays: plays, now: now, calendar: calendar)
            var everPlayed = Set<String>()
            for play in plays { everPlayed.insert(TextNormalization.lovedKey(artist: play.artistName, track: play.trackName)) }
            var inLibrary = 0, notIn = 0, unknown = 0, neverPlayed = 0, neverPlayedUnknown = 0
            for love in analysis.remaining {
                let entry = presence.entries[LibraryGapsEngine.key(artist: love.artist, track: love.track)]
                let never = !everPlayed.contains(love.key)
                if never { neverPlayed += 1 }
                if let entry { if entry.inLibrary || entry.hasNearMatch { inLibrary += 1 } else { notIn += 1 } } else { unknown += 1; if never { neverPlayedUnknown += 1 } }
            }
            print("library status checked at \(String(describing: presence.checkedAt)); of \(analysis.remaining.count) still to hear: in library \(inLibrary), not in library \(notIn), no status \(unknown); never played at all \(neverPlayed), of which no status \(neverPlayedUnknown)")
            // Pictures for the tracks still to hear: the new way (its newest play's album and picture, then the artist) against the old (track alone).
            let lookup = (try? ImageResolutionEngine.imageLookup(context: context)) ?? [:]
            let shown = GoalCompute.run(goal: goal, loves: loves, plays: plays, now: now, calendar: calendar)
            var oldWay = 0, newWay = 0
            for love in shown.analysis.remaining {
                let info = shown.history[love.key]
                if ImageResolutionEngine.effectiveImageURL(for: ImageTarget(kind: .track, artist: love.artist, album: nil, track: love.track), lookup: lookup, fallbackURL: nil) != nil { oldWay += 1 }
                let url = ImageResolutionEngine.effectiveImageURL(for: ImageTarget(kind: .track, artist: love.artist, album: info?.album, track: love.track), lookup: lookup, fallbackURL: info?.imageURL)
                    ?? ImageResolutionEngine.effectiveImageURL(for: ImageTarget(kind: .artist, artist: love.artist, album: nil, track: nil), lookup: lookup)
                if url != nil { newWay += 1 }
            }
            var independentPlays = 0
            let remainingKeys = Set(shown.analysis.remaining.map(\.key))
            for play in plays where remainingKeys.contains(TextNormalization.lovedKey(artist: play.artistName, track: play.trackName)) { independentPlays += 1 }
            print("pictures for \(shown.analysis.remaining.count) still to hear: before \(oldWay), now \(newWay); plays of those tracks \(independentPlays)")
            check("the list's play counts add up to an independent count", shown.history.values.reduce(0) { $0 + $1.plays } == independentPlays)
            // Goals about other tracks, against an independent count over the same history.
            let startAny = calendar.date(byAdding: .day, value: -183, to: calendar.startOfDay(for: now))!
            var played = [String: Date](), firstSeen = [String: Date](), artistOf = [String: String]()
            for play in plays {
                let key = TextNormalization.lovedKey(artist: play.artistName, track: play.trackName)
                if firstSeen[key] == nil { firstSeen[key] = play.playedAt; artistOf[key] = play.artistName }
                if play.playedAt >= startAny, played[key] == nil { played[key] = play.playedAt }
            }
            let lovedSet = Set(loves.map(\.key))
            var plays1 = [String: Int]()
            for play in plays { plays1[play.artistName, default: 0] += 1 }
            let topArtist = plays1.max { $0.value < $1.value }?.key ?? ""
            let tagSnapshot = EntityTagsEngine.loadSnapshot(context: context)
            let topTag = tagSnapshot.vocabulary.first?.tag ?? ""
            let cases: [(String, GoalCriteria, Set<String>)] = [
                ("all tracks", GoalCriteria(loved: .any), Set(firstSeen.keys)),
                ("not loved", GoalCriteria(loved: .notLoved), Set(firstSeen.keys).subtracting(lovedSet)),
                ("loved and played", GoalCriteria(loved: .loved), lovedSet),
                ("all tracks by the most played artist", GoalCriteria(loved: .any, artists: [topArtist]),
                 Set(firstSeen.keys.filter { TextNormalization.artistIdentityKey(artistOf[$0] ?? "") == TextNormalization.artistIdentityKey(topArtist) })),
            ]
            for (label, criteria, expectedMembers) in cases {
                var g = ListeningGoal(title: label, start: startAny, deadline: calendar.date(byAdding: .day, value: 60, to: now)!, criteria: criteria)
                g.expectNewLoves = true
                let began = Date()
                let members = GoalMembership.members(for: [g], loved: loves, plays: plays, tags: tagSnapshot)[g.id]!
                let r = GoalCompute.run(goal: g, members: members, plays: plays, now: now, calendar: calendar)
                let took = Date().timeIntervalSince(began)
                let stillOwed = expectedMembers.filter { played[$0] == nil }
                print(String(format: "  %@: %d tracks, %d still to hear, forecasts included (%.2f s)", label, r.analysis.membersNow, r.analysis.remainingNow, took))
                check("\(label): the tracks and what is left match an independent count",
                      criteria.loved == .loved ? r.analysis.membersNow == lovedSet.count
                        : r.analysis.membersNow == expectedMembers.count && Set(r.analysis.remaining.map(\.key)) == stillOwed,
                      "\(r.analysis.membersNow) vs \(expectedMembers.count); \(r.analysis.remainingNow) vs \(stillOwed.count)")
            }
            if !topTag.isEmpty {
                var g = ListeningGoal(title: "tag", start: startAny, deadline: calendar.date(byAdding: .day, value: 60, to: now)!, criteria: GoalCriteria(loved: .any, tags: [topTag]))
                g.expectNewLoves = true
                let members = GoalMembership.members(for: [g], loved: loves, plays: plays, tags: tagSnapshot)[g.id]!
                print("  tag '\(topTag)': \(members.loves.count) tracks counted, \(members.pendingTags) not looked up yet (of \(firstSeen.count))")
                check("a tag counts only tracks that can be told", members.loves.count + members.pendingTags <= firstSeen.count)
            }
            print(failures == 0 ? "GOALS DUMP OK" : "\(failures) GOALS DUMP CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
