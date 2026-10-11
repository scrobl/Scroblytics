import Foundation

#if DEBUG
/// The evaluation set for Ask: real requests with what a correct reading looks like, and a scorer that compares
/// the interpreted query with it. Any engine runs through the same cases, so engines are compared on identical
/// requests. Expected answers are written as `AskWire` queries and passed through `AskInterpreter` like a model's
/// answer would be, so an expected answer that doesn't validate against the registry shows up as an authoring
/// error rather than as an engine failure.
///
/// A request is correct when the interpreted query has the same target, the same set of OR-groups of conditions
/// (order inside a group doesn't matter), the same sorts and the same limit as ONE of the accepted readings.
/// Ignored: which columns are shown, and "plays > 0" (a filter that matches everything played).
enum AskEval {
    struct Reading {
        let groups: [[AskWire.Condition]]
        let sorts: [AskWire.Sort]
        let limit: Int?
        let perArtist: Int?
        let perAlbum: Int?
        let perReleaseYear: Int?

        init(_ groups: [[AskWire.Condition]] = [], sorts: [AskWire.Sort] = [], limit: Int? = nil,
             perArtist: Int? = nil, perAlbum: Int? = nil, perReleaseYear: Int? = nil) {
            self.groups = groups
            self.sorts = sorts
            self.limit = limit
            self.perArtist = perArtist
            self.perAlbum = perAlbum
            self.perReleaseYear = perReleaseYear
        }
    }

    struct Case {
        let request: String
        let target: QueryTarget
        /// Each is an acceptable reading; ambiguous phrasings list more than one.
        let accepted: [Reading]
        /// True when the right answer is "this can't be expressed": no conditions and something flagged unsupported.
        let expectsUnsupported: Bool
        let category: String
        let note: String?
        /// For a request whose numbers are a judgment call ("a lot", "a few days"): correct when the conditions use exactly
        /// one of these sets of fields, whatever the thresholds. Used instead of `accepted` when non-empty.
        var acceptedFieldSets: [Set<String>] = []
        /// A request for NEW music similar to a seed (a Similar Sounds search), not a filter.
        var expectsSimilar: SimilarExpectation?
    }

    struct SimilarExpectation {
        let seed: String
        let limit: Int
        /// Kinds the seed may reasonably be read as (empty = any).
        let kinds: Set<SimilarSeed.Kind>
    }

    // MARK: - Authoring helpers

    private static func c(_ field: String, _ op: String, _ value: Double? = nil, _ valueTo: Double? = nil, text: String? = nil,
                          date: String? = nil, dateTo: String? = nil, tags: [String]? = nil, scope: AskWire.Scope? = nil,
                          ago: AskWire.Shift? = nil) -> AskWire.Condition {
        AskWire.Condition(field: field, op: op, value: value, valueTo: valueTo, text: text, date: date, dateTo: dateTo, tags: tags, scope: scope, comparedAgo: ago)
    }

    private static func sort(_ field: String, _ direction: String = "descending", scope: AskWire.Scope? = nil, ago: AskWire.Shift? = nil) -> AskWire.Sort {
        AskWire.Sort(field: field, direction: direction, scope: scope, comparedAgo: ago)
    }

    private static let thisYear = AskWire.Scope(kind: "calendar", unit: "year")
    private static let thisMonth = AskWire.Scope(kind: "calendar", unit: "month")
    private static let lastMonth = AskWire.Scope(kind: "calendar", unit: "month", shiftCount: 1, shiftUnit: "month")
    private static let last30 = AskWire.Scope(kind: "trailing", days: 30)
    private static func year(_ y: Int) -> AskWire.Scope { AskWire.Scope(kind: "absolute", from: "\(y)-01-01", to: "\(y)-12-31") }
    private static let yearAgo = AskWire.Shift(count: 1, unit: "year")

    private static func make(_ request: String, _ target: QueryTarget, _ category: String, note: String? = nil, _ accepted: Reading...) -> Case {
        Case(request: request, target: target, accepted: accepted, expectsUnsupported: false, category: category, note: note)
    }

    private static func byFields(_ request: String, _ target: QueryTarget, _ category: String, _ sets: [Set<String>]) -> Case {
        Case(request: request, target: target, accepted: [], expectsUnsupported: false, category: category, note: "thresholds are a judgment call", acceptedFieldSets: sets)
    }

    private static func similar(_ request: String, seed: String, limit: Int, kinds: Set<SimilarSeed.Kind> = []) -> Case {
        Case(request: request, target: .track, accepted: [], expectsUnsupported: false, category: "similar", note: nil,
             expectsSimilar: SimilarExpectation(seed: seed, limit: limit, kinds: kinds))
    }

    private static func unsupported(_ request: String, _ target: QueryTarget) -> Case {
        Case(request: request, target: target, accepted: [], expectsUnsupported: true, category: "unsupported", note: nil)
    }

    // MARK: - The set

    static let cases: [Case] = [
        // Thresholds and counts
        make("artists I've played more than 100 times", .artist, "threshold", Reading([[c("plays", "greaterThan", 100)]])),
        make("tracks I've played at least 50 times", .track, "threshold", Reading([[c("plays", "greaterThanOrEqual", 50)]])),
        make("albums I've played fewer than 5 times", .album, "threshold", Reading([[c("plays", "lessThan", 5)]])),
        make("songs I've played exactly once", .track, "threshold", Reading([[c("plays", "equals", 1)]])),
        make("tracks longer than 6 minutes", .track, "threshold", Reading([[c("duration", "greaterThan", 6)]])),
        make("tracks shorter than 2 minutes", .track, "threshold", Reading([[c("duration", "lessThan", 2)]])),
        make("songs between 3 and 4 minutes long", .track, "threshold", Reading([[c("duration", "between", 3, 4)]])),
        make("albums with more than 10 tracks", .album, "threshold", Reading([[c("turnoverTracks", "greaterThan", 10)]])),

        // Loved, popular, flagged
        make("loved tracks I've played more than 50 times", .track, "loved", Reading([[c("loved", "isTrue"), c("plays", "greaterThan", 50)]])),
        make("songs that aren't loved with more than 20 plays", .track, "loved", Reading([[c("loved", "isFalse"), c("plays", "greaterThan", 20)]])),
        make("songs I haven't loved", .track, "loved", Reading([[c("loved", "isFalse")]])),
        make("popular songs I haven't loved", .track, "loved", Reading([[c("popular", "isTrue"), c("loved", "isFalse")]])),
        make("top 25 loved tracks released in 1994", .track, "loved",
             Reading([[c("loved", "isTrue"), c("releaseYear", "equals", 1994)]], sorts: [sort("plays")], limit: 25)),
        make("loved songs from the 80s", .track, "loved",
             Reading([[c("loved", "isTrue"), c("releaseYear", "between", 1980, 1989)]])),
        make("flagged tracks", .track, "loved", Reading([[c("flagged", "isTrue")]])),

        // Release dates
        make("albums released before 1990", .album, "release", Reading([[c("releaseYear", "lessThan", 1990)]])),
        make("albums released in the 90s", .album, "release", Reading([[c("releaseYear", "between", 1990, 1999)]])),
        make("tracks with no release date", .track, "release", Reading([[c("releaseDate", "isMissing")]])),
        make("albums released after 2015", .album, "release", Reading([[c("releaseYear", "greaterThan", 2015)]])),
        make("top 20 songs from 2023", .track, "release", note: "ambiguous: released in 2023, or played in 2023",
             Reading([[c("releaseYear", "equals", 2023)]], sorts: [sort("plays")], limit: 20),
             Reading([[]], sorts: [sort("plays", scope: year(2023))], limit: 20)),

        // Relative time and periods
        make("my top 10 albums this year", .album, "period", Reading([], sorts: [sort("plays", scope: thisYear)], limit: 10)),
        make("tracks I haven't played in a year", .track, "period", Reading([[c("daysSinceLastPlayed", "greaterThan", 365)]])),
        make("loved tracks I haven't played in a year", .track, "period", Reading([[c("loved", "isTrue"), c("daysSinceLastPlayed", "greaterThan", 365)]])),
        make("artists I haven't listened to in 6 months", .artist, "period",
             Reading([[c("daysSinceLastPlayed", "greaterThan", 180)]]), Reading([[c("daysSinceLastPlayed", "greaterThan", 182)]]),
             Reading([[c("daysSinceLastPlayed", "greaterThan", 183)]])),
        make("tracks I played at least 5 times in the last 30 days", .track, "period", Reading([[c("plays", "greaterThanOrEqual", 5, scope: last30)]])),
        make("my top 5 artists last month", .artist, "period", note: "last month: the previous calendar month, or the last 30 days",
             Reading([], sorts: [sort("plays", scope: lastMonth)], limit: 5), Reading([], sorts: [sort("plays", scope: last30)], limit: 5)),
        make("most played song by Radiohead", .track, "period",
             Reading([[c("artist", "textIs", text: "Radiohead")]], sorts: [sort("plays")], limit: 1),
             Reading([[c("artist", "textIs", text: "Radiohead")]], sorts: [sort("plays")])),
        make("artists I discovered in 2024", .artist, "period", Reading([[c("firstPlayed", "dateBetween", date: "2024-01-01", dateTo: "2024-12-31")]])),
        make("tracks I played more this month than the same month last year", .track, "period",
             Reading([[c("playsChange", "greaterThan", 0, scope: thisMonth, ago: yearAgo)]])),
        make("which tracks climbed the most in rank this year compared to last year", .track, "period",
             Reading([[c("rankMovement", "greaterThan", 0, scope: thisYear, ago: yearAgo)]], sorts: [sort("rankMovement", scope: thisYear, ago: yearAgo)])),

        // Tags
        make("songs tagged running", .track, "tags", note: "Last.fm genre tags or your own",
             Reading([[c("tags", "tagsIsAny", tags: ["running"])]]), Reading([[c("myTags", "tagsIsAny", tags: ["running"])]])),
        make("artists tagged indie or folk", .artist, "tags", Reading([[c("tags", "tagsIsAny", tags: ["indie", "folk"])]])),
        make("songs tagged both rock and 90s", .track, "tags", Reading([[c("tags", "tagsIsAll", tags: ["rock", "90s"])]])),
        make("tracks not tagged workout", .track, "tags",
             Reading([[c("tags", "tagsIsNotAny", tags: ["workout"])]]), Reading([[c("myTags", "tagsIsNotAny", tags: ["workout"])]])),

        // Names
        make("songs with love in the title", .track, "names",
             Reading([[c("name", "wholeWord", text: "love")]]), Reading([[c("name", "contains", text: "love")]])),
        make("albums with live in the title", .album, "names",
             Reading([[c("name", "wholeWord", text: "live")]]), Reading([[c("name", "contains", text: "live")]])),
        make("artists starting with the letter B", .artist, "names", Reading([[c("name", "startsWith", text: "B")]])),
        make("tracks that don't have remix in the name", .track, "names", Reading([[c("name", "doesNotContain", text: "remix")]])),
        make("tracks by Radiohead", .track, "names",
             Reading([[c("artist", "textIs", text: "Radiohead")]]), Reading([[c("artist", "contains", text: "Radiohead")]])),

        // Time of day and week
        make("songs I play mostly at night", .track, "daypart", Reading([[c("peakTimeOfDay", "textIs", text: "Night")]])),
        make("artists I mostly listen to on weekends", .artist, "daypart", Reading([[c("weekdayOrWeekend", "textIs", text: "Weekend")]])),
        make("my Sunday morning artists", .artist, "daypart",
             Reading([[c("dayOfWeek", "textIs", text: "Sunday"), c("peakTimeOfDay", "textIs", text: "Morning")]])),
        make("top songs I play on Friday nights", .track, "daypart",
             Reading([[c("dayOfWeek", "textIs", text: "Friday"), c("peakTimeOfDay", "textIs", text: "Night")]], sorts: [sort("plays")])),

        // Ordering and counts
        make("top 50 tracks of all time", .track, "ranking", Reading([], sorts: [sort("plays")], limit: 50)),
        make("my top 25 artists of all time", .artist, "ranking", Reading([], sorts: [sort("plays")], limit: 25)),
        make("least played albums", .album, "ranking", Reading([], sorts: [sort("plays", "ascending")])),
        make("newest albums I own", .album, "ranking", Reading([], sorts: [sort("releaseDate")])),
        make("10 most recently played tracks", .track, "ranking", Reading([], sorts: [sort("lastPlayed")], limit: 10)),
        make("longest songs", .track, "ranking", Reading([], sorts: [sort("duration")])),
        make("albums by my top 10 artists", .album, "ranking", Reading([[c("artistPlayRank", "lessThanOrEqual", 10)]])),

        // Albums, turnover, popularity
        make("albums I've never listened all the way through", .album, "album", Reading([[c("turnoverCycles", "equals", 0)]])),
        make("albums with the fewest turnovers", .album, "album", Reading([], sorts: [sort("turnoverCycles", "ascending")])),
        make("obscure albums", .album, "album", Reading([[c("popular", "isFalse")]])),
        make("most popular songs by The National", .track, "album",
             Reading([[c("artist", "textIs", text: "The National")]], sorts: [sort("popularityScore")])),

        // Spread of listening over time (example families)
        byFields("albums I played a lot but only over a few days", .album, "spread", [["plays", "activeDays"], ["plays", "playSpanDays"]]),
        byFields("artists I've listened to on more than 200 different days", .artist, "spread", [["activeDays"]]),
        byFields("tracks I got into and dropped within a couple of weeks", .track, "spread", [["playSpanDays"], ["playSpanDays", "daysSinceLastPlayed"], ["plays", "playSpanDays"], ["plays", "playSpanDays", "daysSinceLastPlayed"]]),

        // New music like something (routed to Similar Sounds)
        similar("find 25 songs similar to \"Sweetness Follows\"", seed: "Sweetness Follows", limit: 25, kinds: [.track]),
        similar("recommend some music like Big Thief", seed: "Big Thief", limit: AskSimilarIntent.defaultLimit, kinds: [.artist]),
        similar("40 tracks similar to Hounds of Love by Kate Bush", seed: "Hounds of Love", limit: 40, kinds: [.album, .track]),
        similar("what should I listen to if I like the album Wowee Zowee", seed: "Wowee Zowee", limit: AskSimilarIntent.defaultLimit, kinds: [.album]),

        // Honest "can't"
        unsupported("songs that give me chills", .track),
        unsupported("upbeat songs for a road trip", .track),
        similar("artists that sound like Radiohead", seed: "Radiohead", limit: AskSimilarIntent.defaultLimit, kinds: [.artist]),
        unsupported("songs that sound angry", .track),
        unsupported("songs with sad lyrics", .track),
    ]

    // MARK: - Signatures

    /// Compact, order-independent text for what a query asks: `target | groups | sorts | limit`.
    static func signature(of spec: QuerySpec, calendar: Calendar = AppCalendars.listening) -> String {
        let groups = spec.groups
            .map { group in group.compactMap { condition($0, calendar: calendar) }.sorted().joined(separator: " & ") }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: " OR ")
        let sorts = spec.sorts.map { sort in
            switch sort.key {
            case .field(let field): "\(ref(field, calendar: calendar)) \(sort.direction == .ascending ? "asc" : "desc")"
            case .shuffle: "shuffle"
            }
        }.joined(separator: ", ")
        var text = "\(spec.target.rawValue) | \(groups) | \(sorts) | \(spec.limit.map(String.init) ?? "")"
        // A diversity cap is part of the reading; nothing is added when there is none, so older signatures are unchanged.
        if let caps = spec.groupLimit, !caps.isEmpty {
            text += " | cap " + [caps.perArtist.map { "artist\($0)" }, caps.perAlbum.map { "album\($0)" }, caps.perReleaseYear.map { "year\($0)" }].compactMap { $0 }.joined(separator: ",")
        }
        return text
    }

    private static func condition(_ condition: QueryCondition, calendar: Calendar) -> String? {
        // "Played at all" is true of everything in a played-things list: not a filter.
        if condition.field.id == "plays", condition.op == .greaterThan, condition.operands == [.number(0)] { return nil }
        let operands = condition.operands.map { operand($0, calendar: calendar) }.joined(separator: " ")
        return "\(ref(condition.field, calendar: calendar)) \(condition.op.rawValue) \(operands)".trimmingCharacters(in: .whitespaces)
    }

    private static func ref(_ ref: QueryFieldRef, calendar: Calendar) -> String {
        var text = ref.id
        if let scope = ref.scope { text += "@" + scopeText(scope, calendar: calendar) }
        if let baseline = ref.baseline { text += "~" + scopeText(baseline, calendar: calendar) }
        return text
    }

    private static func scopeText(_ scope: QueryScope, calendar: Calendar) -> String {
        var text: String
        switch scope.kind {
        case .allTime: text = "all"
        case .upToNow: text = "now"
        case .trailing: text = "last\(scope.days ?? 0)"
        case .calendar: text = "cal:\(scope.unit?.rawValue ?? "")"
        case .absolute: text = "abs:\(scope.from.map { day($0, calendar) } ?? "")..\(scope.to.map { day($0, calendar) } ?? "")"
        }
        if scope.shiftCount > 0 { text += "-\(scope.shiftCount)\(scope.shiftUnit.rawValue)" }
        return text
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func operand(_ value: QueryValue, calendar: Calendar) -> String {
        switch value {
        // A model can write an absurd number (1e99); `Int(n)` would trap on it.
        case .number(let n): (n == n.rounded() && abs(n) < 1e15) ? String(Int(n)) : String(format: "%.4g", n)
        case .text(let t): t.lowercased()
        case .bool(let b): String(b)
        case .date(let d): day(d, calendar)
        case .tags(let tags): tags.sorted().joined(separator: ",")
        }
    }

    // MARK: - Scoring

    /// True when the request appears word for word among the worked examples a prompt shows — those are not a test of
    /// anything, so scores are reported with and without them.
    static func isShownInPrompts(_ request: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let shown = Set((AskExamples.all + AskExamples.modelExtras).map { norm($0.request) })
        return shown.contains(norm(request))
    }

    struct Verdict {
        let passed: Bool
        let actual: String
        let accepted: [String]
        /// Authoring problems in the expected answer itself (it didn't validate against the registry).
        let authoringErrors: [String]
        let reason: String
    }

    static func expectedSignatures(for item: Case, registry: QueryFieldRegistry, now: Date) -> (signatures: [String], errors: [String]) {
        var signatures: [String] = []
        var errors: [String] = []
        for reading in item.accepted {
            let wire = AskWire.Query(groups: reading.groups.filter { !$0.isEmpty }, sorts: reading.sorts, limit: reading.limit, unsupported: [],
                                     perArtist: reading.perArtist, perAlbum: reading.perAlbum, perReleaseYear: reading.perReleaseYear)
            let interpreted = AskInterpreter.interpret(wire, target: item.target, registry: registry, now: now)
            if !interpreted.dropped.isEmpty { errors.append(contentsOf: interpreted.dropped.map { "\($0.what): \($0.reason)" }) }
            signatures.append(signature(of: interpreted.spec))
        }
        return (signatures, errors)
    }

    static func score(_ item: Case, interpretation: AskInterpretation, target: QueryTarget, registry: QueryFieldRegistry, now: Date, similar: AskSimilarIntent? = nil) -> Verdict {
        let actual = signature(of: interpretation.spec)
        if let expected = item.expectsSimilar {
            func fold(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
            guard let similar else { return Verdict(passed: false, actual: actual, accepted: ["similar to \(expected.seed)"], authoringErrors: [], reason: "treated as a filter, not a similar-music request") }
            let seedOK = fold(similar.seedText) == fold(expected.seed)
            let limitOK = similar.limit == expected.limit
            let kindOK = expected.kinds.isEmpty || similar.kind.map { expected.kinds.contains($0) } ?? true
            let ok = seedOK && limitOK && kindOK && interpretation.spec.groups.isEmpty
            return Verdict(passed: ok, actual: "similar: \(similar.seedText) [\(similar.kind?.rawValue ?? "?")] artist=\(similar.artistHint ?? "-") limit=\(similar.limit)",
                           accepted: ["similar: \(expected.seed) limit \(expected.limit)"], authoringErrors: [], reason: ok ? "match" : "differs")
        }
        if similar != nil {
            return Verdict(passed: false, actual: "similar: \(similar!.seedText)", accepted: [], authoringErrors: [], reason: "treated an ordinary request as a similar-music request")
        }
        if item.expectsUnsupported {
            let ok = interpretation.spec.groups.isEmpty && !interpretation.unsupported.isEmpty
            return Verdict(passed: ok, actual: actual, accepted: ["(unsupported, no conditions)"], authoringErrors: [],
                           reason: ok ? "flagged unsupported" : (interpretation.unsupported.isEmpty ? "invented a query instead of saying it can't" : "kept conditions"))
        }
        if !item.acceptedFieldSets.isEmpty {
            let used = Set(interpretation.spec.groups.flatMap { $0 }.map(\.field.id))
            let ok = target == item.target && item.acceptedFieldSets.contains(used)
            return Verdict(passed: ok, actual: actual, accepted: item.acceptedFieldSets.map { "fields: " + $0.sorted().joined(separator: "+") }, authoringErrors: [],
                           reason: ok ? "match" : (target == item.target ? "uses fields \(used.sorted())" : "wrong kind of thing (\(target.rawValue))"))
        }
        let (expected, errors) = expectedSignatures(for: item, registry: registry, now: now)
        guard target == item.target else {
            return Verdict(passed: false, actual: actual, accepted: expected, authoringErrors: errors, reason: "wrong kind of thing (\(target.rawValue))")
        }
        let passed = expected.contains(actual)
        return Verdict(passed: passed, actual: actual, accepted: expected, authoringErrors: errors, reason: passed ? "match" : "differs")
    }
}
#endif
