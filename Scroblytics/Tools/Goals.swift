import Foundation

/// A loved track the person has taken out of one goal (a duplicate, another recording of a song, something they don't want to chase).
/// The names are kept so it can be listed and put back.
struct GoalSetAside: Codable, Equatable, Sendable, Identifiable {
    let key: String
    let artist: String
    let track: String
    var id: String { key }
}

/// A listening goal: hear every loved track at least once between `start` and the end of the `deadline` day. The chart, the
/// numbers and the forecasts are all worked out from the play history and the loved list; only the goal itself is saved.
struct ListeningGoal: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    /// Any moment on the first day; the day is what counts.
    var start: Date
    /// Any moment on the last day; the goal runs to the end of that day.
    var deadline: Date
    var createdAt: Date
    /// How many recent days the forecasts learn your habits from.
    var lookbackDays: Int
    /// The share of your listening given to loved tracks you haven't heard, on top of "Your habits" and "Shuffle your favorites"; nil = none.
    var dedicatedShare: Double?
    /// Whether the forecasts expect more tracks to be loved before the deadline.
    var expectNewLoves: Bool
    /// Loves per month to expect; nil = from the dates of your recent loves.
    var lovesPerMonth: Double?
    /// Loves dated on one day in bulk (a sync or import, not someone loving tracks) count as loved from the first day.
    var countBulkLovesFromStart: Bool
    /// Only loved tracks that are in the Apple Music library count (as of the last check in Library Gaps); tracks known to be missing from it are left out.
    var inAppleLibraryOnly: Bool
    /// Loved tracks taken out of this goal: they are not counted, heard or not.
    var setAside: [GoalSetAside]
    /// Which tracks the goal is about.
    var criteria: GoalCriteria

    init(
        id: UUID = UUID(), title: String, start: Date, deadline: Date, createdAt: Date = .now,
        lookbackDays: Int = 90, dedicatedShare: Double? = nil, expectNewLoves: Bool = true, lovesPerMonth: Double? = nil,
        countBulkLovesFromStart: Bool = true, inAppleLibraryOnly: Bool = false, setAside: [GoalSetAside] = [],
        criteria: GoalCriteria = GoalCriteria()
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.deadline = deadline
        self.createdAt = createdAt
        self.lookbackDays = lookbackDays
        self.dedicatedShare = dedicatedShare
        self.expectNewLoves = expectNewLoves
        self.lovesPerMonth = lovesPerMonth
        self.countBulkLovesFromStart = countBulkLovesFromStart
        self.inAppleLibraryOnly = inAppleLibraryOnly
        self.setAside = setAside
        self.criteria = criteria
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, start, deadline, createdAt, lookbackDays, dedicatedShare, expectNewLoves, lovesPerMonth, countBulkLovesFromStart, inAppleLibraryOnly, setAside, criteria
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        start = try c.decode(Date.self, forKey: .start)
        deadline = try c.decode(Date.self, forKey: .deadline)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? start
        lookbackDays = min(max(try c.decodeIfPresent(Int.self, forKey: .lookbackDays) ?? 90, 14), 365)
        dedicatedShare = try c.decodeIfPresent(Double.self, forKey: .dedicatedShare).map { min(max($0, 0), 1) }
        expectNewLoves = try c.decodeIfPresent(Bool.self, forKey: .expectNewLoves) ?? true
        lovesPerMonth = try c.decodeIfPresent(Double.self, forKey: .lovesPerMonth).map { max($0, 0) }
        countBulkLovesFromStart = try c.decodeIfPresent(Bool.self, forKey: .countBulkLovesFromStart) ?? true
        inAppleLibraryOnly = try c.decodeIfPresent(Bool.self, forKey: .inAppleLibraryOnly) ?? false
        setAside = try c.decodeIfPresent([GoalSetAside].self, forKey: .setAside) ?? []
        criteria = try c.decodeIfPresent(GoalCriteria.self, forKey: .criteria) ?? GoalCriteria()
    }
}

/// What the Goals tool saves (as one tool-options record, so backups carry it).
struct GoalsState: Codable, Equatable, Sendable {
    var goals: [ListeningGoal] = []
    var selected: UUID?

    init(goals: [ListeningGoal] = [], selected: UUID? = nil) {
        self.goals = goals
        self.selected = selected
    }

    private enum CodingKeys: String, CodingKey { case goals, selected }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goals = try c.decodeIfPresent([ListeningGoal].self, forKey: .goals) ?? []
        selected = try c.decodeIfPresent(UUID.self, forKey: .selected)
    }
}

/// One loved track as the goal sees it.
struct GoalLove: Sendable, Equatable {
    let key: String
    let artist: String
    let track: String
    /// nil = not known (a love from before dates were kept); the track then counts from the first day.
    let lovedAt: Date?
}

/// What the whole history says about a loved track that is still to hear: for ordering the list and for its picture.
struct GoalTrackHistory: Sendable, Equatable {
    var plays = 0
    var lastPlayed: Date?
    /// The album and picture of its newest plays that had them.
    var album: String?
    var imageURL: String?
}

enum GoalRemainingFilter: String, CaseIterable, Identifiable, Sendable {
    case all, playedBefore, neverPlayed

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .playedBefore: "Played before"
        case .neverPlayed: "Never played"
        }
    }
}

enum GoalRemainingSort: String, CaseIterable, Identifiable, Sendable {
    case recentlyLoved, oldestLoved, mostPlayed, lastHeard, artist, track

    var id: String { rawValue }
    func label(joinsOnPlay: Bool) -> String {
        switch self {
        case .recentlyLoved: joinsOnPlay ? "Newest first" : "Recently loved"
        case .oldestLoved: joinsOnPlay ? "Oldest first" : "Oldest loved"
        case .mostPlayed: "Most played before"
        case .lastHeard: "Heard longest ago"
        case .artist: "Artist A–Z"
        case .track: "Track A–Z"
        }
    }
}

/// The "Still to hear" list as the person has asked to see it.
enum GoalRemainingList {
    /// `loves` arrive most recently loved first; ties keep that order.
    static func apply(
        _ loves: [GoalLove], history: [String: GoalTrackHistory], filter: GoalRemainingFilter, sort: GoalRemainingSort, search: String
    ) -> [GoalLove] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = loves.enumerated().filter { _, love in
            let played = (history[love.key]?.plays ?? 0) > 0
            switch filter {
            case .all: break
            case .playedBefore: if !played { return false }
            case .neverPlayed: if played { return false }
            }
            return query.isEmpty || love.track.localizedStandardContains(query) || love.artist.localizedStandardContains(query)
        }
        func plays(_ love: GoalLove) -> Int { history[love.key]?.plays ?? 0 }
        let ordered = kept.sorted { a, b in
            let x = a.element, y = b.element
            switch sort {
            case .recentlyLoved: break
            case .oldestLoved:
                let (dx, dy) = (x.lovedAt ?? .distantPast, y.lovedAt ?? .distantPast)
                if dx != dy { return dx < dy }
            case .mostPlayed:
                if plays(x) != plays(y) { return plays(x) > plays(y) }
            case .lastHeard:
                // Never-played tracks have no last time; they go last (the filter lists them on their own).
                let (lx, ly) = (history[x.key]?.lastPlayed, history[y.key]?.lastPlayed)
                if lx != ly {
                    guard let lx else { return false }
                    guard let ly else { return true }
                    return lx < ly
                }
            case .artist:
                let c = x.artist.localizedStandardCompare(y.artist)
                if c != .orderedSame { return c == .orderedAscending }
                let t = x.track.localizedStandardCompare(y.track)
                if t != .orderedSame { return t == .orderedAscending }
            case .track:
                let c = x.track.localizedStandardCompare(y.track)
                if c != .orderedSame { return c == .orderedAscending }
                let t = x.artist.localizedStandardCompare(y.artist)
                if t != .orderedSame { return t == .orderedAscending }
            }
            return a.offset < b.offset
        }
        return ordered.map(\.element)
    }
}

enum GoalScenarioKind: String, CaseIterable, Identifiable, Sendable {
    case habits, shuffle, dedicated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .habits: "Your habits"
        case .shuffle: "Shuffle your favorites"
        case .dedicated: "Unplayed first"
        }
    }

    var explanation: String {
        switch self {
        case .habits:
            "You keep listening the way you have lately. Each track in the goal you haven't heard comes up at the rate it has been coming up for you; tracks you haven't touched in months come up rarely. If you set aside part of your listening for unheard tracks, those plays go on top."
        case .shuffle:
            "You play only tracks from this goal, at the rate you have been playing them, picked at random. Each play can land on one you've already heard, so the list empties quickly at first and slowly at the end. If you set aside part of your listening for unheard tracks, those plays go on top."
        case .dedicated:
            "Everything you play goes to tracks in the goal you haven't heard yet, each played once, before anything else. Nothing is wasted on repeats, so the line is straight: the fastest it can be done at your usual number of plays a day."
        }
    }
}

/// What the recent history says about how you listen, worked out once per analysis.
struct GoalHabits: Sendable, Equatable {
    /// Plays a day of anything, and of loved tracks, over the lookback.
    var playsPerDay: Double
    var lovedPlaysPerDay: Double
    /// Plays a day of one loved track you haven't heard in the goal's period, one rate per remaining track (same order as `remaining`).
    var remainingRates: [Double]
    /// The rate used for loved tracks with no plays in the lookback, learned from how often such tracks came back (per day).
    var dormantRate: Double
    /// How many tracks that estimate rests on.
    var dormantSample: Int
    /// New loves a day that arrive unplayed, and how it was reached.
    var newLovesPerDay: Double
    var lovesInLookback: Int
    var unplayedShareOfLoves: Double
    var hasLoveDates: Bool
}

struct GoalAnalysis: Sendable {
    /// The goal's tracks come from the play history (each joins when first played), not from the loved list.
    let joinsOnPlay: Bool
    /// Days until the first day of a goal that starts in the future; 0 once it has started. Until then `todayIndex` is 0 and the numbers
    /// describe the goal as it will begin.
    let daysUntilStart: Int
    let todayIndex: Int
    let deadlineIndex: Int
    /// Days after today up to and including the deadline day; 0 once the deadline day is today or past.
    let daysLeft: Int
    /// Tracks still to hear at the end of each day, day 0 = the first day, through today.
    let actual: [Int]
    /// Loved tracks that belonged to the goal at the end of each day.
    let members: [Int]
    /// The straight line from the loved tracks there were on the first day to nothing at the end of the deadline day.
    let plan: [Double]
    let baselineAtStart: Int
    let membersNow: Int
    let remainingNow: Int
    let heardNow: Int
    /// The loved tracks not yet heard, most recently loved first.
    let remaining: [GoalLove]
    let habits: GoalHabits
    let lookbackDays: Int
    /// The day (index) the count last reached zero, if it is zero now.
    let completedIndex: Int?
    let startDay: Date
    /// Loves dated on a day with `GoalEngine.bulkLoveDayThreshold` or more of them, and those days.
    let bulkLoves: Int
    let bulkLoveDays: [Date]

    /// Tracks a day from now on that finish the goal in a straight line, today included.
    var requiredPerDay: Double {
        let days = max(daysLeft + 1, 1)
        return Double(remainingNow) / Double(days)
    }
}

enum GoalEngine {
    static let lookbackChoices = [30, 60, 90, 180]
    /// A play within this long before a love means the track was already heard when it was loved.
    static let heardBeforeLoveDays = 7
    /// A day with this many loves or more is a bulk day (an import or a sync of favorites), not someone loving tracks one at a time.
    static let bulkLoveDayThreshold = 50

    static func dayIndex(_ date: Date, from startDay: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: startDay, to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// `plays` must be oldest first (the history cache's order).
    static func analyze(
        goal: ListeningGoal, loves: [GoalLove], plays: [ScrobbleSnapshot], joinsOnPlay: Bool = false, now: Date, calendar: Calendar
    ) -> GoalAnalysis {
        let startDay = calendar.startOfDay(for: goal.start)
        let daysUntilStart = max(0, -dayIndex(now, from: startDay, calendar: calendar))
        let todayIndex = max(0, dayIndex(now, from: startDay, calendar: calendar))
        let deadlineIndex = max(0, dayIndex(goal.deadline, from: startDay, calendar: calendar))
        let lookback = max(goal.lookbackDays, 1)
        let lookbackStart = calendar.date(byAdding: .day, value: -lookback, to: now) ?? now
        let previousStart = calendar.date(byAdding: .day, value: -2 * lookback, to: now) ?? now
        let weekBeforeLove = TimeInterval(heardBeforeLoveDays * 86_400)

        // One entry per track, in the order the loved list gave them.
        var index: [String: Int] = [:]
        var tracks: [GoalLove] = []
        for love in loves where index[love.key] == nil {
            index[love.key] = tracks.count
            tracks.append(love)
        }
        let hasLoveDates = !joinsOnPlay && tracks.contains { $0.lovedAt != nil }
        // Loves dated on a bulk day were not loved that day one by one; counted as loved from the first day when the goal says so.
        var lovesPerDay: [Date: Int] = [:]
        for love in tracks { if let at = love.lovedAt { lovesPerDay[calendar.startOfDay(for: at), default: 0] += 1 } }
        // Tracks that join on their first play are never "loved in bulk": a day with many new ones is just a day of discovery.
        let bulkDays = joinsOnPlay ? [] : Set(lovesPerDay.filter { $0.value >= bulkLoveDayThreshold }.keys)
        var bulkLoves = 0
        for i in tracks.indices {
            guard let at = tracks[i].lovedAt, bulkDays.contains(calendar.startOfDay(for: at)) else { continue }
            bulkLoves += 1
            if goal.countBulkLovesFromStart {
                tracks[i] = GoalLove(key: tracks[i].key, artist: tracks[i].artist, track: tracks[i].track, lovedAt: nil)
            }
        }

        var firstPlay = [Date?](repeating: nil, count: tracks.count)
        var lookbackCount = [Int](repeating: 0, count: tracks.count)
        var previousCount = [Int](repeating: 0, count: tracks.count)
        var heardBeforeLove = [Bool](repeating: false, count: tracks.count)
        var playsInLookback = 0
        var lovedPlaysInLookback = 0

        let scanFrom = min(startDay, previousStart)
        var position = lowerBound(plays, scanFrom)
        while position < plays.count {
            let play = plays[position]
            position += 1
            if play.playedAt > now { break }
            let inLookback = play.playedAt >= lookbackStart
            if inLookback { playsInLookback += 1 }
            guard let i = index[TextNormalization.lovedKey(artist: play.artistName, track: play.trackName)] else { continue }
            if play.playedAt >= startDay, firstPlay[i] == nil { firstPlay[i] = play.playedAt }
            if inLookback {
                lookbackCount[i] += 1
                lovedPlaysInLookback += 1
            } else if play.playedAt >= previousStart {
                previousCount[i] += 1
            }
            if let lovedAt = tracks[i].lovedAt, lovedAt >= lookbackStart,
               play.playedAt <= lovedAt, lovedAt.timeIntervalSince(play.playedAt) <= weekBeforeLove {
                heardBeforeLove[i] = true
            }
        }

        // The burn-down: a track is owed from the day it joined (or the first day) until the day of its first play.
        var remainingDelta = [Int](repeating: 0, count: todayIndex + 2)
        var memberDelta = [Int](repeating: 0, count: todayIndex + 2)
        var remaining: [(love: GoalLove, joined: Int)] = []
        for (i, love) in tracks.enumerated() {
            let joined = min(max(love.lovedAt.map { dayIndex($0, from: startDay, calendar: calendar) } ?? 0, 0), todayIndex)
            memberDelta[joined] += 1
            if let played = firstPlay[i] {
                let done = min(max(dayIndex(played, from: startDay, calendar: calendar), 0), todayIndex)
                if done >= joined {
                    remainingDelta[joined] += 1
                    remainingDelta[done] -= 1
                }
            } else {
                remainingDelta[joined] += 1
                remaining.append((love, joined))
            }
        }
        var actual: [Int] = []
        var members: [Int] = []
        var runningRemaining = 0
        var runningMembers = 0
        for d in 0...todayIndex {
            runningRemaining += remainingDelta[d]
            runningMembers += memberDelta[d]
            actual.append(runningRemaining)
            members.append(runningMembers)
        }
        let baseline = memberDelta[0]
        let plan: [Double] = (0...deadlineIndex).map { d in
            Double(baseline) * max(0, 1 - Double(d + 1) / Double(deadlineIndex + 1))
        }
        let remainingNow = actual[todayIndex]
        let membersNow = members[todayIndex]
        let completedIndex: Int? = {
            guard remainingNow == 0, membersNow > 0 else { return nil }
            var d = todayIndex
            while d > 0, actual[d - 1] == 0 { d -= 1 }
            return d
        }()

        // How you listen: the rate of each track still owed comes from its own plays in the lookback; a track with none borrows the
        // rate at which tracks like it (none in the window before) came back in the window.
        var dormant = 0
        var returned = 0
        for i in tracks.indices where previousCount[i] == 0 && (tracks[i].lovedAt.map { $0 < lookbackStart } ?? true) {
            dormant += 1
            if lookbackCount[i] > 0 { returned += 1 }
        }
        let returnShare = dormant > 0 ? Double(returned) / Double(dormant) : 0
        let flooredShare = min(max(returnShare, 0.5 / Double(max(dormant, 1))), 0.9)
        let dormantRate = -log(1 - flooredShare) / Double(lookback)

        let remainingTracks = remaining.sorted {
            switch ($0.love.lovedAt, $1.love.lovedAt) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return ($0.love.artist, $0.love.track) < ($1.love.artist, $1.love.track)
            }
        }.map(\.love)
        let remainingRates = remainingTracks.map { love -> Double in
            let k = index[love.key].map { lookbackCount[$0] } ?? 0
            return k > 0 ? Double(k) / Double(lookback) : dormantRate
        }

        var recentLoves = 0
        var unplayedLoves = 0
        for (i, love) in tracks.enumerated() {
            guard !joinsOnPlay, let lovedAt = love.lovedAt, lovedAt >= lookbackStart, lovedAt <= now else { continue }
            recentLoves += 1
            if !heardBeforeLove[i] { unplayedLoves += 1 }
        }
        let unplayedShare = recentLoves > 0 ? Double(unplayedLoves) / Double(recentLoves) : 0.5
        let habits = GoalHabits(
            playsPerDay: Double(playsInLookback) / Double(lookback),
            lovedPlaysPerDay: Double(lovedPlaysInLookback) / Double(lookback),
            remainingRates: remainingRates,
            dormantRate: dormantRate,
            dormantSample: dormant,
            newLovesPerDay: Double(recentLoves) / Double(lookback),
            lovesInLookback: recentLoves,
            unplayedShareOfLoves: unplayedShare,
            hasLoveDates: hasLoveDates
        )

        return GoalAnalysis(
            joinsOnPlay: joinsOnPlay, daysUntilStart: daysUntilStart, todayIndex: todayIndex, deadlineIndex: deadlineIndex,
            daysLeft: max(0, deadlineIndex - todayIndex), actual: actual, members: members, plan: plan,
            baselineAtStart: baseline, membersNow: membersNow, remainingNow: remainingNow,
            heardNow: membersNow - remainingNow, remaining: remainingTracks, habits: habits,
            lookbackDays: lookback, completedIndex: completedIndex, startDay: startDay,
            bulkLoves: bulkLoves, bulkLoveDays: bulkDays.sorted()
        )
    }

    /// First position whose play is at or after `date`.
    static func lowerBound(_ plays: [ScrobbleSnapshot], _ date: Date) -> Int {
        var low = 0
        var high = plays.count
        while low < high {
            let mid = (low + high) / 2
            if plays[mid].playedAt < date { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// One forecast: the tracks still owed over the days ahead, many runs of the same assumptions summarised.
struct GoalForecast: Sendable, Equatable {
    let kind: GoalScenarioKind
    /// Remaining tracks at the end of each day from today (offset 0) to the deadline, as the middle run and the range that holds
    /// four runs in five (the 10th and 90th percentile).
    let median: [Double]
    let low: [Double]
    let high: [Double]
    /// How many runs have nothing left at the end of the deadline day.
    let chanceByDeadline: Double
    /// Days from today until the middle run finishes / is half done / is nine tenths done; nil when it doesn't within the horizon.
    let finishMedian: Int?
    let halfMedian: Int?
    let ninetyMedian: Int?
    let horizon: Int
    let sims: Int
}

struct GoalSimulationSetup: Sendable {
    let remainingRates: [Double]
    let memberCount: Int
    let lovedPlaysPerDay: Double
    let playsPerDay: Double
    /// Unplayed loves arriving per day (0 = none expected).
    let newLovesPerDay: Double
    let daysLeft: Int
    let horizon: Int
}

enum GoalSimulator {
    static let confidence = 0.9
    static let defaultSims = 300

    /// How far past the deadline a run is followed to find when it finishes.
    static func horizon(daysLeft: Int) -> Int {
        min(max(daysLeft * 3, 180), 1100)
    }

    /// Loves a day, all of them, expected under the goal's settings (0 when none are expected or the dates aren't known).
    private static func lovesPerDay(analysis: GoalAnalysis, goal: ListeningGoal) -> Double {
        // Tracks that join when first played arrive already heard: nothing new is ever owed.
        guard goal.expectNewLoves, !analysis.joinsOnPlay else { return 0 }
        let habits = analysis.habits
        if let perMonth = goal.lovesPerMonth { return perMonth / 30.4375 }
        return habits.hasLoveDates ? habits.newLovesPerDay : 0
    }

    /// For a goal that hasn't started: the tracks expected to be loved before its first day. Every one of them is owed from the first day
    /// (plays before it don't count), so they are part of what has to be heard.
    static func leadLoves(analysis: GoalAnalysis, goal: ListeningGoal) -> Int {
        guard analysis.daysUntilStart > 0 else { return 0 }
        return Int((lovesPerDay(analysis: analysis, goal: goal) * Double(analysis.daysUntilStart)).rounded())
    }

    static func setup(from analysis: GoalAnalysis, goal: ListeningGoal) -> GoalSimulationSetup {
        let habits = analysis.habits
        var rates = habits.remainingRates
        let lead = leadLoves(analysis: analysis, goal: goal)
        if lead > 0 {
            let typical = rates.isEmpty ? habits.dormantRate : rates.reduce(0, +) / Double(rates.count)
            rates.append(contentsOf: repeatElement(typical, count: lead))
        }
        var arrivals = 0.0
        if goal.expectNewLoves, !analysis.joinsOnPlay {
            if let perMonth = goal.lovesPerMonth {
                arrivals = perMonth / 30.4375 * habits.unplayedShareOfLoves
            } else if habits.hasLoveDates {
                arrivals = habits.newLovesPerDay * habits.unplayedShareOfLoves
            }
        }
        return GoalSimulationSetup(
            remainingRates: rates, memberCount: analysis.membersNow + lead,
            lovedPlaysPerDay: habits.lovedPlaysPerDay, playsPerDay: habits.playsPerDay,
            newLovesPerDay: arrivals, daysLeft: analysis.daysLeft, horizon: horizon(daysLeft: analysis.daysLeft)
        )
    }

    static func seed(for goal: ListeningGoal, remaining: Int) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for byte in withUnsafeBytes(of: goal.id.uuid, { Array($0) }) { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return h ^ UInt64(truncatingIfNeeded: remaining) &* 0x9E37_79B9_7F4A_7C15
    }

    /// `dedicatedPlaysPerDay` is the number of plays a day that go to unheard loved tracks on top of `.habits` or `.shuffle`. `.dedicated`
    /// ("Unplayed first") is the extreme: every play you make goes to a track you haven't heard, so it ignores both.
    static func forecast(
        _ kind: GoalScenarioKind, setup: GoalSimulationSetup, dedicatedPlaysPerDay: Double = 0,
        sims: Int = defaultSims, seed: UInt64
    ) -> GoalForecast {
        let count = setup.remainingRates.count
        let shuffleRate = setup.memberCount > 0 ? setup.lovedPlaysPerDay / Double(setup.memberCount) : 0
        let literal = kind == .dedicated
        let rates: [Double] = literal ? [Double](repeating: 0, count: count)
            : kind == .shuffle ? [Double](repeating: shuffleRate, count: count) : setup.remainingRates
        let newRate: Double = literal ? 0
            : kind == .shuffle ? shuffleRate
            : (count > 0 ? setup.remainingRates.reduce(0, +) / Double(count) : 0)
        let perDay = literal ? max(setup.playsPerDay, 0) : max(dedicatedPlaysPerDay, 0)
        let chartDays = max(setup.daysLeft, 0)
        let horizon = max(setup.horizon, chartDays)

        var generator = SeededRandom(seed: seed)
        // values[day * sims + run]
        var values = [Int32](repeating: 0, count: (chartDays + 1) * sims)
        var finishDays: [Int] = []
        var halfDays: [Int] = []
        var ninetyDays: [Int] = []
        var finishedByDeadline = 0

        // Buffers reused by every run.
        var hear: [Int] = []
        var arrive: [Int] = []
        var arriveHead = [Int](repeating: -1, count: horizon + 2)
        var hearHead = [Int](repeating: -1, count: horizon + 2)
        var arriveNext: [Int] = []
        var hearNext: [Int] = []
        var alive: [Int] = []
        var position: [Int] = []

        for run in 0..<sims {
            hear.removeAll(keepingCapacity: true)
            arrive.removeAll(keepingCapacity: true)
            for i in 0..<count {
                arrive.append(0)
                hear.append(rates[i] > 0 ? hearDay(rate: rates[i], horizon: horizon, generator: &generator) : Int.max)
            }
            if setup.newLovesPerDay > 0 {
                for day in 1...max(horizon, 1) {
                    for _ in 0..<poisson(setup.newLovesPerDay, generator: &generator) {
                        arrive.append(day)
                        hear.append(newRate > 0 ? hearDayAfter(day, rate: newRate, horizon: horizon, generator: &generator) : Int.max)
                    }
                }
            }
            let total = hear.count
            for d in 0..<(horizon + 2) { arriveHead[d] = -1; hearHead[d] = -1 }
            arriveNext.removeAll(keepingCapacity: true)
            hearNext.removeAll(keepingCapacity: true)
            arriveNext.append(contentsOf: repeatElement(-1, count: total))
            hearNext.append(contentsOf: repeatElement(-1, count: total))
            for i in 0..<total {
                if arrive[i] > 0 { arriveNext[i] = arriveHead[arrive[i]]; arriveHead[arrive[i]] = i }
                if hear[i] <= horizon { hearNext[i] = hearHead[hear[i]]; hearHead[hear[i]] = i }
            }
            alive.removeAll(keepingCapacity: true)
            position.removeAll(keepingCapacity: true)
            position.append(contentsOf: repeatElement(-1, count: total))
            for i in 0..<count { position[i] = alive.count; alive.append(i) }

            let start = alive.count
            values[run] = Int32(start)
            var finish: Int? = start == 0 ? 0 : nil
            var half: Int? = nil
            var ninety: Int? = nil
            var carry = 0.0
            var day = 0
            while day < horizon {
                day += 1
                var i = arriveHead[day]
                while i >= 0 { position[i] = alive.count; alive.append(i); i = arriveNext[i] }
                i = hearHead[day]
                while i >= 0 {
                    removeAlive(i, alive: &alive, position: &position)
                    i = hearNext[i]
                }
                if perDay > 0 {
                    carry += perDay
                    var k = Int(carry)
                    carry -= Double(k)
                    while k > 0, !alive.isEmpty {
                        removeAlive(alive[Int.random(in: 0..<alive.count, using: &generator)], alive: &alive, position: &position)
                        k -= 1
                    }
                }
                if day <= chartDays { values[day * sims + run] = Int32(alive.count) }
                if start > 0 {
                    if half == nil, alive.count * 2 <= start { half = day }
                    if ninety == nil, alive.count * 10 <= start { ninety = day }
                }
                if finish == nil, alive.isEmpty { finish = day }
                if day >= chartDays, finish != nil { break }
            }
            if let finish { finishDays.append(finish) }
            if let half { halfDays.append(half) }
            if let ninety { ninetyDays.append(ninety) }
            if values[chartDays * sims + run] == 0 { finishedByDeadline += 1 }
        }

        var median: [Double] = []
        var low: [Double] = []
        var high: [Double] = []
        for day in 0...chartDays {
            let sorted = values[(day * sims)..<((day + 1) * sims)].sorted()
            median.append(quantile(sorted, 0.5))
            low.append(quantile(sorted, 0.1))
            high.append(quantile(sorted, 0.9))
        }
        return GoalForecast(
            kind: kind, median: median, low: low, high: high,
            chanceByDeadline: Double(finishedByDeadline) / Double(max(sims, 1)),
            finishMedian: medianDay(finishDays, sims: sims), halfMedian: medianDay(halfDays, sims: sims),
            ninetyMedian: medianDay(ninetyDays, sims: sims), horizon: horizon, sims: sims
        )
    }

    private static func removeAlive(_ i: Int, alive: inout [Int], position: inout [Int]) {
        let p = position[i]
        guard p >= 0 else { return }
        let last = alive[alive.count - 1]
        alive[p] = last
        position[last] = p
        alive.removeLast()
        position[i] = -1
    }

    /// The fewest plays a day, on top of your habits, given to unplayed loved tracks that finishes by the deadline in `confidence` of
    /// runs, or nil when even all of your listening would not.
    static func neededDedicatedPlaysPerDay(setup: GoalSimulationSetup, seed: UInt64) -> Double? {
        guard !setup.remainingRates.isEmpty else { return 0 }
        func chance(_ perDay: Double) -> Double {
            forecast(.habits, setup: setup, dedicatedPlaysPerDay: perDay, sims: 60, seed: seed).chanceByDeadline
        }
        if chance(0) >= confidence { return 0 }
        let ceilingPerDay = setup.playsPerDay
        guard ceilingPerDay > 0, chance(ceilingPerDay) >= confidence else { return nil }
        var lo = 0.0
        var hi = ceilingPerDay
        for _ in 0..<10 {
            let mid = (lo + hi) / 2
            if chance(mid) >= confidence { hi = mid } else { lo = mid }
        }
        return hi
    }

    // MARK: - Random draws

    private static func hearDay(rate: Double, horizon: Int, generator: inout SeededRandom) -> Int {
        hearDayAfter(0, rate: rate, horizon: horizon, generator: &generator)
    }

    private static func hearDayAfter(_ day: Int, rate: Double, horizon: Int, generator: inout SeededRandom) -> Int {
        let u = 1 - Double.random(in: 0..<1, using: &generator)
        let wait = -log(u) / rate
        let at = Double(day) + max(1, wait.rounded(.up))
        return at > Double(horizon) ? Int.max : Int(at)
    }

    private static func poisson(_ mean: Double, generator: inout SeededRandom) -> Int {
        let limit = exp(-mean)
        var n = 0
        var p = 1.0
        repeat {
            n += 1
            p *= Double.random(in: 0..<1, using: &generator)
        } while p > limit && n < 50
        return n - 1
    }

    private static func quantile(_ sorted: [Int32], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = q * Double(sorted.count - 1)
        let below = Int(position.rounded(.down))
        let above = min(below + 1, sorted.count - 1)
        let fraction = position - Double(below)
        return Double(sorted[below]) * (1 - fraction) + Double(sorted[above]) * fraction
    }

    /// The middle run's day, when more than half the runs got there; nil otherwise.
    private static func medianDay(_ days: [Int], sims: Int) -> Int? {
        guard days.count * 2 > sims else { return nil }
        return days.sorted()[sims / 2]
    }
}

/// Everything the Goals screen shows for one goal.
struct GoalResult: Sendable {
    let analysis: GoalAnalysis
    /// Empty once the goal is complete or its deadline has passed.
    let forecasts: [GoalScenarioKind: GoalForecast]
    /// The plays a day to give to unplayed loved tracks to finish by the deadline in `GoalSimulator.confidence` of runs; nil = not even
    /// all of your listening would do it.
    let neededPerDay: Double?
    /// The plays a day set aside for unheard tracks in "Your habits" and "Shuffle your favorites": the chosen share of your listening, or 0.
    let dedicatedPerDay: Double
    /// Unplayed new loves expected per day in the forecasts.
    let expectedLovesPerDay: Double
    /// Loved tracks left out because they are known not to be in the Apple Music library.
    let leftOutOfLibrary: Int
    /// The goal asks for library tracks only but the library has never been checked, so nothing could be left out.
    let libraryNeverChecked: Bool
    let libraryCheckedAt: Date?
    /// For each track in `analysis.remaining` that has any plays, by its key.
    let history: [String: GoalTrackHistory]
    /// Tracks expected to be loved before a goal that hasn't started begins, counted in the forecasts but not yet in the lists.
    let leadLoves: Int
    /// Tracks a tag test could not be applied to yet (no tags looked up for them or their artist), so they are not counted.
    let pendingTags: Int
}

enum GoalCompute {
    /// All-time plays, last play, album and picture of the tracks still to hear (one pass over the history, oldest first).
    static func history(of remaining: [GoalLove], plays: [ScrobbleSnapshot]) -> [String: GoalTrackHistory] {
        guard !remaining.isEmpty else { return [:] }
        let wanted = Set(remaining.map(\.key))
        var found: [String: GoalTrackHistory] = [:]
        for play in plays {
            let key = TextNormalization.lovedKey(artist: play.artistName, track: play.trackName)
            guard wanted.contains(key) else { continue }
            var entry = found[key] ?? GoalTrackHistory()
            entry.plays += 1
            entry.lastPlayed = play.playedAt
            if !play.albumName.isEmpty { entry.album = play.albumName }
            if let url = play.imageURL, !TextNormalization.isLastfmPlaceholderImage(url) { entry.imageURL = url }
            found[key] = entry
        }
        return found
    }

    /// The loved tracks a goal counts: all of them, or for a library-only goal those not known to be missing from the Apple Music library.
    /// `presence` is the saved library status; it only matters to a goal that counts library tracks only. A track with no saved status is
    /// kept: it was never checked, which is not the same as missing.
    private static func counted(
        goal: ListeningGoal, loves allLoves: [GoalLove], presence: LibraryPresenceSnapshot?
    ) -> (loves: [GoalLove], leftOut: Int, neverChecked: Bool) {
        // Tracks set aside are not part of the goal at all, so they are not "left out" of anything either.
        let aside = Set(goal.setAside.map(\.key))
        let allLoves = aside.isEmpty ? allLoves : allLoves.filter { !aside.contains($0.key) }
        guard goal.inAppleLibraryOnly else { return (allLoves, 0, false) }
        guard let presence, presence.checkedAt != nil else { return (allLoves, 0, true) }
        let kept = allLoves.filter { love in
            guard let entry = presence.entries[LibraryGapsEngine.key(artist: love.artist, track: love.track)] else { return true }
            return entry.inLibrary || entry.hasNearMatch
        }
        return (kept, allLoves.count - kept.count, false)
    }

    /// Just the burn-down and habits, without the forecasts: enough for a goal's summary card.
    static func analysis(
        goal: ListeningGoal, members: GoalMembers, plays: [ScrobbleSnapshot], presence: LibraryPresenceSnapshot? = nil,
        now: Date, calendar: Calendar
    ) -> GoalAnalysis {
        GoalEngine.analyze(
            goal: goal, loves: counted(goal: goal, loves: members.loves, presence: presence).loves, plays: plays, joinsOnPlay: members.joinsOnPlay,
            now: now, calendar: calendar
        )
    }

    /// For a goal about every loved track.
    static func analysis(
        goal: ListeningGoal, loves: [GoalLove], plays: [ScrobbleSnapshot], presence: LibraryPresenceSnapshot? = nil,
        now: Date, calendar: Calendar
    ) -> GoalAnalysis {
        analysis(goal: goal, members: GoalMembers(loves: loves), plays: plays, presence: presence, now: now, calendar: calendar)
    }

    /// For a goal about every loved track.
    static func run(
        goal: ListeningGoal, loves: [GoalLove], plays: [ScrobbleSnapshot], presence: LibraryPresenceSnapshot? = nil,
        now: Date, calendar: Calendar
    ) -> GoalResult {
        run(goal: goal, members: GoalMembers(loves: loves), plays: plays, presence: presence, now: now, calendar: calendar)
    }

    static func run(
        goal: ListeningGoal, members: GoalMembers, plays: [ScrobbleSnapshot], presence: LibraryPresenceSnapshot? = nil,
        now: Date, calendar: Calendar
    ) -> GoalResult {
        let (loves, leftOut, neverChecked) = counted(goal: goal, loves: members.loves, presence: presence)
        let analysis = GoalEngine.analyze(goal: goal, loves: loves, plays: plays, joinsOnPlay: members.joinsOnPlay, now: now, calendar: calendar)
        let setup = GoalSimulator.setup(from: analysis, goal: goal)
        let history = history(of: analysis.remaining, plays: plays)
        func result(_ forecasts: [GoalScenarioKind: GoalForecast], needed: Double?, dedicated: Double) -> GoalResult {
            GoalResult(
                analysis: analysis, forecasts: forecasts, neededPerDay: needed, dedicatedPerDay: dedicated, expectedLovesPerDay: setup.newLovesPerDay,
                leftOutOfLibrary: leftOut, libraryNeverChecked: neverChecked, libraryCheckedAt: presence?.checkedAt,
                history: history, leadLoves: GoalSimulator.leadLoves(analysis: analysis, goal: goal), pendingTags: members.pendingTags
            )
        }
        guard analysis.remainingNow > 0, analysis.daysLeft > 0 else { return result([:], needed: nil, dedicated: 0) }
        let seed = GoalSimulator.seed(for: goal, remaining: analysis.remainingNow)
        let needed = GoalSimulator.neededDedicatedPlaysPerDay(setup: setup, seed: seed)
        let dedicated = goal.dedicatedShare.map { $0 * setup.playsPerDay } ?? 0
        var forecasts: [GoalScenarioKind: GoalForecast] = [:]
        for kind in GoalScenarioKind.allCases {
            forecasts[kind] = GoalSimulator.forecast(kind, setup: setup, dedicatedPlaysPerDay: dedicated, seed: seed)
        }
        return result(forecasts, needed: needed, dedicated: dedicated)
    }
}
