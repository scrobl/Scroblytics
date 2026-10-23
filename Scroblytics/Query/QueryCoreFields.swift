import Foundation

/// The identity and play-history fields every target has. These are the one
/// group with no existing bulk engine to wrap (each Overview engine groups its
/// own scrobbles privately), so they read the single grouping pass the query
/// universe already does — one place, not a per-field re-derivation.
extension QueryFieldRegistry {
    /// Reads a field's cells from the per-entity aggregates over `scope` (nil = the query's period).
    /// An entity with no plays in the scope gets `absent`.
    private static func lookup(
        _ run: QueryRun, _ scope: QueryScope?, _ entities: [QueryEntity], absent: QueryCell = .missing,
        _ body: (QueryEntity, QueryRun.Universe.Aggregate) -> QueryCell
    ) -> [QueryEntityID: QueryCell] {
        let aggregates = run.scopedAggregates(scope)
        return Dictionary(uniqueKeysWithValues: entities.map { entity in
            (entity.id, aggregates[entity.id].map { body(entity, $0) } ?? absent)
        })
    }

    /// How many distinct calendar days / weeks (per the week-start setting) / months each entity was played in, over `scope`
    /// (nil = the query's period), in local time. No value for an entity with no plays there.
    private static func activeCount(_ run: QueryRun, _ scope: QueryScope?, _ entities: [QueryEntity], _ unit: Calendar.Component) -> [QueryEntityID: QueryCell] {
        let calendar = run.calendar
        let groups = run.scopedScrobblesByEntity(scope)
        // One calendar lookup per distinct day, not per play.
        var bucketOfDay: [Date: Date] = [:]
        func bucket(_ date: Date) -> Date {
            let day = calendar.startOfDay(for: date)
            switch unit {
            case .day: return day
            default:
                if let cached = bucketOfDay[day] { return cached }
                let start = calendar.dateInterval(of: unit, for: day)?.start ?? day
                bucketOfDay[day] = start
                return start
            }
        }
        return Dictionary(uniqueKeysWithValues: entities.map { entity in
            guard let plays = groups[entity.id], !plays.isEmpty else { return (entity.id, QueryCell.missing) }
            return (entity.id, .value(.number(Double(Set(plays.map { bucket($0.playedAt) }).count))))
        })
    }

    /// Plays over the WHOLE library per entity, ignoring the query's period.
    private static func allTimePlays(_ run: QueryRun) -> [QueryEntityID: Int] {
        run.memoized("allTimePlays") {
            var counts: [QueryEntityID: Int] = [:]
            for s in run.allTimeScrobbles { if let id = run.entityID(for: s) { counts[id, default: 0] += 1 } }
            return counts
        }
    }

    /// The trailing-window parameter shared by the "in the last N days" fields.
    static let recentWindow = QueryFieldParameter(
        id: "windowDays", label: "Window (days)",
        options: [30, 60, 90, 180, 365].map { .number(Double($0)) }, defaultValue: .number(90), suffix: "d",
        help: "How many days back from “now” to count plays."
    )

    /// Plays in the trailing window ending at the run's "now" — `playedAt > now − N days`,
    /// the boundary the Climbing and Fading Favorites engines use.
    private static func recentPlays(_ run: QueryRun, days: Int) -> [QueryEntityID: Int] {
        run.memoized("recentPlays.\(days)") {
            let cutoff = run.asOf.addingTimeInterval(-Double(days) * 86400)
            var counts: [QueryEntityID: Int] = [:]
            for s in run.scrobbles where s.playedAt > cutoff {
                if let id = run.entityID(for: s) { counts[id, default: 0] += 1 }
            }
            return counts
        }
    }

    /// 1-based rank by plays over `scope` (nil = the query's period) among EVERY entity with plays
    /// there — not just the query's rows — using Top Charts' documented tie-break: plays desc, then
    /// artist name, then (tracks) track name. Album ties beyond artist fall back to first-scrobbled.
    /// `shared` gives equal plays the same rank (1, 2, 2, 4) instead of Top Charts' broken ties.
    private static func playRanks(_ run: QueryRun, scope: QueryScope?, shared: Bool = false) -> [QueryEntityID: Int] {
        run.memoized("playRanks.\(scope?.cacheKey ?? "-").\(shared)") {
            let aggregates = run.scopedAggregates(scope)
            let ordered = aggregates.keys.sorted { a, b in
                let (pa, pb) = (aggregates[a]!, aggregates[b]!)
                if pa.plays != pb.plays { return pa.plays > pb.plays }
                if a.target != .artist, a.artist != b.artist { return a.artist < b.artist }
                switch a.target {
                case .artist: return a.name < b.name
                case .track: return a.name < b.name
                case .album:
                    if pa.first != pb.first { return pa.first < pb.first }
                    return a.name < b.name
                }
            }
            guard shared else { return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0 + 1) }) }
            var ranks: [QueryEntityID: Int] = [:]
            var rank = 1, previousPlays = -1
            for (index, id) in ordered.enumerated() {
                let plays = aggregates[id]!.plays
                if plays != previousPlays { rank = index + 1; previousPlays = plays }
                ranks[id] = rank
            }
            return ranks
        }
    }

    static let rankTies = QueryFieldParameter(
        id: "ties", label: "Ties", options: [.text("broken"), .text("shared")], defaultValue: .text("broken"), showsDefaultInTitle: false,
        help: "broken: equal plays are ordered by artist, then title, as in Top Charts (every rank is unique). shared: equal plays get the same rank (1, 2, 2, 4).")

    private static func tiesShared(_ parameters: [String: QueryValue]) -> Bool {
        if case .text("shared")? = parameters["ties"] { return true }
        return false
    }

    /// Each artist's rank by plays over `scope` among ALL artists there (plays desc, then name), read
    /// by album and track queries — "songs by my top 25 artists".
    private static func artistPlayRanks(_ run: QueryRun, scope: QueryScope?) -> [String: Int] {
        run.memoized("artistPlayRanks.\(scope?.cacheKey ?? "-")") {
            var counts: [String: Int] = [:]
            for s in run.scopedScrobbles(scope) { counts[s.artistName, default: 0] += 1 }
            let ordered = counts.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.key, $0 + 1) })
        }
    }

    /// Number of distinct, non-empty album names seen for each artist across the whole library.
    private static func artistDiscographySizes(_ run: QueryRun) -> [String: Int] {
        run.memoized("artistDiscographySizes") {
            var albumsByArtist: [String: Set<String>] = [:]
            for scrobble in run.allTimeScrobbles where !scrobble.albumName.isEmpty {
                albumsByArtist[scrobble.artistName, default: []].insert(scrobble.albumName)
            }
            return albumsByArtist.mapValues(\.count)
        }
    }

    private static func peakBucket(
        _ run: QueryRun, scope: QueryScope?, bucketCount: Int,
        bucket: (ScrobbleSnapshot) -> Int
    ) -> [QueryEntityID: Int] {
        Dictionary(uniqueKeysWithValues: run.scopedScrobblesByEntity(scope).map { id, scrobbles in
            var counts = Array(repeating: 0, count: bucketCount)
            for scrobble in scrobbles { counts[bucket(scrobble)] += 1 }
            var peak = 0
            for index in counts.indices where counts[index] > counts[peak] { peak = index }
            return (id, peak)
        })
    }

    /// The values the "peak" text fields can hold — the one list both the field's computation and the condition
    /// editor's pick-list read, so a condition can only ask for a value the field can actually have.
    static let timeOfDayLabels = ["Night", "Morning", "Afternoon", "Evening"]
    static let dayOfWeekLabels = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let weekdayOrWeekendLabels = ["Weekday", "Weekend"]
    static let seasonLabels = Season.allCases.map(\.label)

    /// The "peak" fields describe an item's most common day / time, not every play — worth saying wherever a
    /// request like "songs I play on Sunday mornings" is turned into them.
    private static let peakCaveat = "Day and time fields match each item’s most common day or time of day, not every one of its plays."

    private static func withChoices(_ choices: [String], _ field: QueryField) -> QueryField {
        var field = field
        field.choices = choices
        field.caveat = peakCaveat
        return field
    }

    /// The season with the most plays, by the hemisphere chosen in Settings. Whole calendar months, so it never depends on the exact solstice.
    private static func seasonField(all: Set<QueryTarget>) -> QueryField {
        var field = withChoices(seasonLabels, QueryField(
            id: "peakSeason", name: "Season", group: .context, type: .text, targets: all,
            help: "The season with the most plays: Winter, Spring, Summer or Autumn, as whole calendar months for the hemisphere chosen in Settings › General (northern: winter is December–February; southern: June–August). A tie goes to the first of Winter, Spring, Summer, Autumn. Uses the query’s period or this column’s date scope.",
            scopedCompute: { run, _, scope, entities in
                let labels = seasonLabels
                let hemisphere = SeasonSettings.hemisphere
                let peaks = peakBucket(run, scope: scope, bucketCount: labels.count) {
                    Season.of(month: run.calendar.component(.month, from: $0.playedAt), in: hemisphere).rawValue
                }
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    (entity.id, peaks[entity.id].map { .value(.text(labels[$0])) } ?? .missing)
                })
            }))
        field.caveat = "The season field matches each item’s most common season, not every one of its plays. To count only the plays made in a season, use “Only count plays on certain days, months or hours” in the scope."
        return field
    }

    /// "In how many different days / weeks / months was it played" — a measure of how spread out listening is, which
    /// the number of plays alone can't tell (30 plays in one evening vs. one play a week for 30 weeks).
    private static func activeField(id: String, name: String, unit: Calendar.Component, word: String) -> QueryField {
        var field = QueryField(
            id: id, name: name, group: .volume, type: .numeric, targets: [.artist, .album, .track],
            help: "The number of different \(word) it was played in, in the query’s period or this column’s own date scope (local time). 30 plays in one evening is 1; a play a week for 30 weeks is 30. No value if it had no plays there.",
            scopedCompute: { run, _, scope, entities in activeCount(run, scope, entities, unit) }
        )
        field.askable = false
        field.askableByLargeModels = true
        return field
    }

    /// Calendar days between the first and the last play in the period (0 when every play was on one day): how long it
    /// stayed in rotation, whatever the number of plays.
    private static let spanField: QueryField = {
        var field = QueryField(
            id: "playSpanDays", name: "Days between first and last play", group: .recency, type: .numeric, targets: [.artist, .album, .track],
            help: "How many calendar days lie between its first and its last play in the query’s period (or this column’s own date scope): 0 if every play was on one day, 300 if it was heard in January and again in November. No value if it had no plays there.",
            scopedCompute: { run, _, scope, entities in
                lookup(run, scope, entities) { _, a in
                    let days = run.calendar.dateComponents([.day], from: run.calendar.startOfDay(for: a.first), to: run.calendar.startOfDay(for: a.last)).day ?? 0
                    return .value(.number(Double(days)))
                }
            }
        )
        field.askable = false
        field.askableByLargeModels = true
        return field
    }()

    static let coreFields: [QueryField] = {
        let all: Set<QueryTarget> = [.artist, .album, .track]

        return [
            QueryField(id: "name", name: "Name", group: .identity, type: .text, targets: all,
                       help: "The artist, album or track name.") { _, _, entities in
                Dictionary(uniqueKeysWithValues: entities.map { ($0.id, .value(.text($0.name))) })
            },
            QueryField(id: "artist", name: "Artist", group: .identity, type: .text, targets: [.album, .track],
                       help: "The artist an album or track belongs to.") { _, _, entities in
                Dictionary(uniqueKeysWithValues: entities.map { ($0.id, .value(.text($0.artist))) })
            },
            QueryField(id: "artistDiscographySize", name: "Artist discography size", group: .context, type: .numeric, targets: all,
                       help: "The number of distinct albums by this item’s artist in your whole scrobble library. Album-less scrobbles are ignored.") { run, _, entities in
                let sizes = artistDiscographySizes(run)
                return Dictionary(uniqueKeysWithValues: entities.map { ($0.id, .value(.number(Double(sizes[$0.artist] ?? 0)))) })
            },
            QueryField(id: "plays", name: "Plays", group: .volume, type: .numeric, targets: all,
                       help: "Scrobbles in the query’s period — or in this column’s own date scope, when it has one (0 if there were none).",
                       scopedCompute: { run, _, scope, entities in
                lookup(run, scope, entities, absent: .value(.number(0))) { _, a in .value(.number(Double(a.plays))) }
            }),
            QueryField(id: "allTimePlays", name: "All-time plays", group: .volume, type: .numeric, targets: all,
                       help: "Every scrobble of it, however the query’s period is set — “Plays” counts only the period.") { run, _, entities in
                let counts = allTimePlays(run)
                return Dictionary(uniqueKeysWithValues: entities.map { ($0.id, .value(.number(Double(counts[$0.id] ?? 0)))) })
            },
            QueryField(id: "playsInLast", name: "Plays in last N days", group: .volume, type: .numeric, targets: all,
                       parameters: [recentWindow],
                       help: "Scrobbles in the trailing window ending at the query’s “now”.") { run, parameters, entities in
                guard case .number(let days)? = parameters["windowDays"] else { preconditionFailure("windowDays defaults are always resolved") }
                let counts = recentPlays(run, days: Int(days))
                return Dictionary(uniqueKeysWithValues: entities.map { ($0.id, .value(.number(Double(counts[$0.id] ?? 0)))) })
            },
            QueryField(id: "playRank", name: "Play rank", group: .ranking, type: .numeric, targets: all,
                       parameters: [rankTies],
                       column: .standard(for: .numeric, style: .integer, width: 80),
                       help: "Position by plays in the query’s period, or in this column’s own date scope (1 = most played). Ties break by artist, then title, as in Top Charts — or choose “shared” to give equal plays the same rank. No value if it had no plays in that scope.",
                       scopedCompute: { run, parameters, scope, entities in
                let ranks = playRanks(run, scope: scope, shared: tiesShared(parameters))
                return Dictionary(uniqueKeysWithValues: entities.map { ($0.id, ranks[$0.id].map { .value(.number(Double($0))) } ?? .missing) })
            }),
            QueryField(id: "playsChange", name: "Plays change", group: .ranking, type: .numeric, targets: all,
                       column: .standard(for: .numeric, style: .integer, width: 90),
                       help: "Plays in this period minus plays in the comparison period (0 plays counts as 0).",
                       comparedCompute: { run, _, scope, baseline, entities in
                let now = run.scopedAggregates(scope), then = run.scopedAggregates(baseline)
                return Dictionary(uniqueKeysWithValues: entities.map {
                    ($0.id, .value(.number(Double((now[$0.id]?.plays ?? 0) - (then[$0.id]?.plays ?? 0)))))
                })
            }),
            QueryField(id: "playsChangePercent", name: "Plays change %", group: .ranking, type: .numeric, targets: all,
                       column: .standard(for: .numeric, style: .integer, width: 100),
                       help: "Change in plays as a percent of the comparison period’s plays. No value when it had no plays in the comparison period (nothing to be a percent of).",
                       comparedCompute: { run, _, scope, baseline, entities in
                let now = run.scopedAggregates(scope), then = run.scopedAggregates(baseline)
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    let before = then[entity.id]?.plays ?? 0
                    guard before > 0 else { return (entity.id, .missing) }
                    let after = now[entity.id]?.plays ?? 0
                    return (entity.id, .value(.number((Double(after - before) / Double(before) * 100).rounded())))
                })
            }),
            QueryField(id: "rankMovement", name: "Rank movement", group: .ranking, type: .numeric, targets: all,
                       parameters: [rankTies],
                       column: .standard(for: .numeric, style: .integer, width: 100),
                       help: "Places gained (+) or lost (−) in the play ranking versus the comparison period — comparison rank minus this rank, as Top Charts’ Move. No value when it wasn’t ranked in both.",
                       comparedCompute: { run, parameters, scope, baseline, entities in
                let shared = tiesShared(parameters)
                let now = playRanks(run, scope: scope, shared: shared), then = playRanks(run, scope: baseline, shared: shared)
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    guard let a = now[entity.id], let b = then[entity.id] else { return (entity.id, .missing) }
                    return (entity.id, .value(.number(Double(b - a))))
                })
            }),
            QueryField(id: "artistPlayRank", name: "Artist’s play rank", group: .ranking, type: .numeric, targets: [.album, .track],
                       column: .standard(for: .numeric, style: .integer, width: 110),
                       help: "Where this item’s artist ranks among all your artists by plays in the period, or in this column’s own date scope (1 = most played). “Artist’s play rank ≤ 25” = items by your top 25 artists.",
                       scopedCompute: { run, _, scope, entities in
                let ranks = artistPlayRanks(run, scope: scope)
                return Dictionary(uniqueKeysWithValues: entities.map { ($0.id, ranks[$0.artist].map { .value(.number(Double($0))) } ?? .missing) })
            }),
            spanField,
            activeField(id: "activeDays", name: "Active days", unit: .day, word: "calendar days"),
            activeField(id: "activeWeeks", name: "Active weeks", unit: .weekOfYear, word: "weeks (Monday to Sunday)"),
            activeField(id: "activeMonths", name: "Active months", unit: .month, word: "calendar months"),
            QueryField(id: "daysSinceLastPlayed", name: "Days since last played", group: .recency, type: .numeric, targets: all,
                       help: "Whole days between its last play (in the period, or this column’s date scope) and the query’s “now”. No value if it had no plays there.",
                       scopedCompute: { run, _, scope, entities in
                lookup(run, scope, entities) { _, a in .value(.number((run.asOf.timeIntervalSince(a.last) / 86400).rounded(.down))) }
            }),
            QueryField(id: "daysSinceFirstPlayed", name: "Days since first played", group: .recency, type: .numeric, targets: all,
                       help: "Whole days between its first play (in the period, or this column’s date scope) and the query’s “now”. No value if it had no plays there.",
                       scopedCompute: { run, _, scope, entities in
                lookup(run, scope, entities) { _, a in .value(.number((run.asOf.timeIntervalSince(a.first) / 86400).rounded(.down))) }
            }),
            QueryField(id: "firstPlayed", name: "First played", group: .dates, type: .date, targets: all,
                       help: "The day of its earliest play in the query’s period, or in this column’s own date scope. No value if it had no plays there.",
                       scopedCompute: { run, _, scope, entities in
                lookup(run, scope, entities) { _, a in .value(.date(a.first)) }
            }),
            QueryField(id: "lastPlayed", name: "Last played", group: .dates, type: .date, targets: all,
                       help: "The day of its most recent play in the query’s period, or in this column’s own date scope. No value if it had no plays there.",
                       scopedCompute: { run, _, scope, entities in
                lookup(run, scope, entities) { _, a in .value(.date(a.last)) }
            }),
            withChoices(timeOfDayLabels, QueryField(id: "peakTimeOfDay", name: "Peak time of day", group: .context, type: .text, targets: all,
                       help: "The time-of-day period with the most plays: Night (9 PM–5 AM), Morning (5 AM–noon), Afternoon (noon–5 PM), or Evening (5–9 PM). Uses the query’s period or this column’s date scope.",
                       scopedCompute: { run, _, scope, entities in
                let labels = timeOfDayLabels
                let peaks = peakBucket(run, scope: scope, bucketCount: labels.count) { scrobble in
                    switch run.calendar.component(.hour, from: scrobble.playedAt) {
                    case 5..<12: 1
                    case 12..<17: 2
                    case 17..<21: 3
                    default: 0
                    }
                }
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    (entity.id, peaks[entity.id].map { .value(.text(labels[$0])) } ?? .missing)
                })
            })),
            withChoices(dayOfWeekLabels, QueryField(id: "dayOfWeek", name: "Day of week", group: .context, type: .text, targets: all,
                       help: "The day of the week on which this item was played most often. Uses the query’s period or this column’s date scope.",
                       scopedCompute: { run, _, scope, entities in
                let labels = dayOfWeekLabels
                let peaks = peakBucket(run, scope: scope, bucketCount: labels.count) {
                    run.calendar.component(.weekday, from: $0.playedAt) - 1
                }
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    (entity.id, peaks[entity.id].map { .value(.text(labels[$0])) } ?? .missing)
                })
            })),
            withChoices(weekdayOrWeekendLabels, QueryField(id: "weekdayOrWeekend", name: "Weekday / weekend", group: .context, type: .text, targets: all,
                       help: "Whether more plays occurred on weekdays or weekends. A tie is shown as Weekday. Uses the query’s period or this column’s date scope.",
                       scopedCompute: { run, _, scope, entities in
                let labels = weekdayOrWeekendLabels
                let peaks = peakBucket(run, scope: scope, bucketCount: labels.count) {
                    let weekday = run.calendar.component(.weekday, from: $0.playedAt)
                    return weekday == 1 || weekday == 7 ? 1 : 0
                }
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    (entity.id, peaks[entity.id].map { .value(.text(labels[$0])) } ?? .missing)
                })
            })),
            seasonField(all: all),
        ]
    }()
}
