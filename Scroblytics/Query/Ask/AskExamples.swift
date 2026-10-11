import Foundation

/// Worked examples shown to the model. They name real field ids, so they are the one place a field
/// rename could leave the prompt stale — which is why they are never trusted as written:
/// `AskExamples.valid(...)` runs every example through the same interpreter that reads the model's
/// answers, and an example that no longer passes is left out of the prompt (and appears in
/// `AskExamples.staleExamples`, which the checks require to be empty). Examples are typed values, not prose.
enum AskExamples {
    struct Example {
        let request: String
        let target: QueryTarget
        /// Whether the request asks for an order — examples are shown in the mode the schema is in.
        let ordered: Bool
        var scoped: Bool { query.groups.contains { $0.contains { $0.scope != nil } } || (query.sorts ?? []).contains { $0.scope != nil } }
        let query: AskWire.Query
        /// Vague phrases the answer turned into numbers (shown to model engines only).
        var resolvedTerms: [AskResolvedTerm] = []
    }

    private static func cond(_ field: String, _ op: String, value: Double? = nil, valueTo: Double? = nil, text: String? = nil, date: String? = nil, dateTo: String? = nil,
                             scope: AskWire.Scope? = nil, comparedAgo: AskWire.Shift? = nil) -> AskWire.Condition {
        AskWire.Condition(field: field, op: op, value: value, valueTo: valueTo, text: text, date: date, dateTo: dateTo, scope: scope, comparedAgo: comparedAgo)
    }

    private static let thisMonth = AskWire.Scope(kind: "calendar", unit: "month")
    private static let thisYear = AskWire.Scope(kind: "calendar", unit: "year")
    private static let yearAgo = AskWire.Shift(count: 1, unit: "year")

    static let all: [Example] = [
        Example(request: "artists I've played more than 100 times", target: .artist, ordered: false, query: AskWire.Query(
            groups: [[cond("plays", "greaterThan", value: 100)]], unsupported: [])),
        Example(request: "tracks longer than 6 minutes that I loved", target: .track, ordered: false, query: AskWire.Query(
            groups: [[cond("duration", "greaterThan", value: 6), cond("loved", "isTrue")]], unsupported: [])),
        Example(request: "artists I've played over 500 times or first played before 2015", target: .artist, ordered: false, query: AskWire.Query(
            groups: [[cond("plays", "greaterThan", value: 500)], [cond("firstPlayed", "before", date: "2015-01-01")]], unsupported: [])),
        Example(request: "albums released before 1990", target: .album, ordered: false, query: AskWire.Query(
            groups: [[cond("releaseYear", "lessThan", value: 1990)]], unsupported: [])),
        Example(request: "tracks I played more this month than the same month last year", target: .track, ordered: false, query: AskWire.Query(
            groups: [[cond("playsChange", "greaterThan", value: 0, scope: thisMonth, comparedAgo: yearAgo)]], unsupported: [])),
        Example(request: "artists I discovered in 2023", target: .artist, ordered: false, query: AskWire.Query(
            groups: [[cond("firstPlayed", "dateBetween", date: "2023-01-01", dateTo: "2023-12-31")]], unsupported: [])),
        Example(request: "tracks I played at least 5 times in the last 30 days", target: .track, ordered: false, query: AskWire.Query(
            groups: [[cond("plays", "greaterThanOrEqual", value: 5, scope: .init(kind: "trailing", days: 30))]], unsupported: [])),
        Example(request: "tracks I mostly play in the evening", target: .track, ordered: false, query: AskWire.Query(
            groups: [[cond("peakTimeOfDay", "textIs", text: "Evening")]], unsupported: [])),
        Example(request: "artists I mostly play on Fridays", target: .artist, ordered: false, query: AskWire.Query(
            groups: [[cond("dayOfWeek", "textIs", text: "Friday")]], unsupported: [])),
        Example(request: "artists I mostly play on Sunday mornings", target: .artist, ordered: false, query: AskWire.Query(
            groups: [[cond("dayOfWeek", "textIs", text: "Sunday"), cond("peakTimeOfDay", "textIs", text: "Morning")]], unsupported: [])),
        Example(request: "top songs I play on Friday nights", target: .track, ordered: true, query: AskWire.Query(
            groups: [[cond("dayOfWeek", "textIs", text: "Friday"), cond("peakTimeOfDay", "textIs", text: "Night")]],
            sorts: [.init(field: "plays", direction: "descending")], unsupported: [])),
        Example(request: "songs tagged running that I haven't loved", target: .track, ordered: false, query: AskWire.Query(
            groups: [[AskWire.Condition(field: "tags", op: "tagsIsAny", tags: ["running"]), cond("loved", "isFalse")]], unsupported: [])),
        Example(request: "songs that give me chills", target: .track, ordered: false, query: AskWire.Query(
            groups: [], unsupported: ["songs that give me chills — there is no field for how a song feels"])),
        Example(request: "my 10 most played albums in the last 30 days", target: .album, ordered: true, query: AskWire.Query(
            groups: [[cond("plays", "greaterThan", value: 0, scope: .init(kind: "trailing", days: 30))]],
            sorts: [.init(field: "plays", direction: "descending", scope: .init(kind: "trailing", days: 30))], unsupported: [])),
        Example(request: "tracks I haven't played in ages, longest gap first", target: .track, ordered: true, query: AskWire.Query(
            groups: [[cond("daysSinceLastPlayed", "greaterThan", value: 365)]],
            sorts: [.init(field: "daysSinceLastPlayed", direction: "descending")], unsupported: [])),
        Example(request: "which tracks climbed the most in rank this year compared to last year", target: .track, ordered: true, query: AskWire.Query(
            groups: [[cond("rankMovement", "greaterThan", value: 0, scope: thisYear, comparedAgo: yearAgo)]],
            sorts: [.init(field: "rankMovement", direction: "descending", scope: thisYear, comparedAgo: yearAgo)], unsupported: [])),
        Example(request: "my top 25 artists of all time", target: .artist, ordered: true, query: AskWire.Query(
            groups: [], sorts: [.init(field: "plays", direction: "descending")], unsupported: [])),
    ]

    /// More worked examples, shown only to the hosted/local model engines. They exercise the idioms the system prompt
    /// describes. Deliberately different sentences from the evaluation set (`AskEval`), so a high score there means the
    /// model generalised, not that it was shown the answer.
    static let modelExtras: [Example] = [
        Example(request: "show me the top song from each album by Artist A", target: .track, ordered: true, query: AskWire.Query(
            groups: [[cond("artist", "textIs", text: "Artist A")]], sorts: [.init(field: "plays", direction: "descending")], unsupported: [], perAlbum: 1)),
        Example(request: "my most played album from every release year", target: .album, ordered: true, query: AskWire.Query(
            groups: [], sorts: [.init(field: "plays", direction: "descending")], unsupported: [], perReleaseYear: 1)),
        Example(request: "top 10 loved songs released in 2001", target: .track, ordered: true, query: AskWire.Query(
            groups: [[cond("loved", "isTrue"), cond("releaseYear", "equals", value: 2001)]], sorts: [.init(field: "plays", direction: "descending")], limit: 10, unsupported: [])),
        Example(request: "records that came out in the 70s", target: .album, ordered: false, query: AskWire.Query(
            groups: [[cond("releaseYear", "between", value: 1970, valueTo: 1979)]], unsupported: [])),
        Example(request: "songs with night in the name", target: .track, ordered: false, query: AskWire.Query(
            groups: [[cond("name", "wholeWord", text: "night")]], unsupported: [])),
        Example(request: "bands whose name starts with the letter M", target: .artist, ordered: false, query: AskWire.Query(
            groups: [[cond("name", "startsWith", text: "M")]], unsupported: [])),
        Example(request: "the song I've played most by Wilco", target: .track, ordered: true, query: AskWire.Query(
            groups: [[cond("artist", "textIs", text: "Wilco")]], sorts: [.init(field: "plays", direction: "descending")], limit: 1, unsupported: [])),
        Example(request: "my top 3 tracks in the last 7 days", target: .track, ordered: true, query: AskWire.Query(
            groups: [], sorts: [.init(field: "plays", direction: "descending", scope: .init(kind: "trailing", days: 7))], limit: 3, unsupported: [])),
        Example(request: "songs I haven't heard in over two years that I loved", target: .track, ordered: false, query: AskWire.Query(
            groups: [[cond("loved", "isTrue"), cond("daysSinceLastPlayed", "greaterThan", value: 730)]], unsupported: [])),
        Example(request: "albums I've played once or twice", target: .album, ordered: false, query: AskWire.Query(
            groups: [[cond("plays", "between", value: 1, valueTo: 2)]], unsupported: [])),
        Example(request: "tracks from artists in my top 20", target: .track, ordered: false, query: AskWire.Query(
            groups: [[cond("artistPlayRank", "lessThanOrEqual", value: 20)]], unsupported: [])),
        Example(request: "tunes shorter than 90 seconds", target: .track, ordered: false, query: AskWire.Query(
            groups: [[cond("duration", "lessThan", value: 1.5)]], unsupported: [])),
        Example(request: "songs tagged jazz but not blues", target: .track, ordered: false, query: AskWire.Query(
            groups: [[AskWire.Condition(field: "tags", op: "tagsIsAny", tags: ["jazz"]), AskWire.Condition(field: "tags", op: "tagsIsNotAny", tags: ["blues"])]], unsupported: [])),
        Example(request: "tracks I overplayed during one short stretch", target: .track, ordered: false, query: AskWire.Query(
            groups: [[cond("plays", "greaterThanOrEqual", value: 30), cond("activeDays", "lessThanOrEqual", value: 3)]], unsupported: []),
            resolvedTerms: [AskResolvedTerm(phrase: "overplayed", meaning: "at least 30 plays"), AskResolvedTerm(phrase: "short stretch", meaning: "played on at most 3 different days")]),
        Example(request: "artists I've kept coming back to for years", target: .artist, ordered: false, query: AskWire.Query(
            groups: [[cond("playSpanDays", "greaterThan", value: 1095)]], unsupported: []),
            resolvedTerms: [AskResolvedTerm(phrase: "for years", meaning: "first and last play more than 3 years apart")]),
        Example(request: "songs that remind me of summer", target: .track, ordered: false, query: AskWire.Query(
            groups: [], unsupported: ["songs that remind me of summer — no field measures how a song feels"])),
        Example(request: "artists I started listening to last year", target: .artist, ordered: false, query: AskWire.Query(
            groups: [[cond("firstPlayed", "dateBetween", date: "2025-01-01", dateTo: "2025-12-31")]], unsupported: [])),
        Example(request: "albums I play a lot", target: .album, ordered: false, query: AskWire.Query(
            groups: [[cond("plays", "greaterThanOrEqual", value: 50)]], unsupported: []),
            resolvedTerms: [AskResolvedTerm(phrase: "a lot", meaning: "at least 50 plays")]),
    ]

    /// Every example that still validates, as the model engines' prompt shows it — the same flat shape the schema asks for.
    static func renderedForModels(registry: QueryFieldRegistry) -> String {
        let encoder = JSONEncoder()
        return (all + modelExtras).filter { isValid($0, registry: registry) }.map { example in
            var object = ((try? JSONSerialization.jsonObject(with: encoder.encode(example.query))) as? [String: Any]) ?? [:]
            object["target"] = example.target.rawValue
            if !example.resolvedTerms.isEmpty { object["resolvedTerms"] = example.resolvedTerms.map { ["phrase": $0.phrase, "meaning": $0.meaning] } }
            let json = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "Request: \(example.request)\nAnswer: \(json)"
        }.joined(separator: "\n\n")
    }

    /// The examples for `target` in the given mode that still pass the interpreter — plus the "can't express it"
    /// example, which shows the same answer shape whatever the target.
    static func valid(for target: QueryTarget, ordered: Bool, scoped: Bool, registry: QueryFieldRegistry) -> [Example] {
        all.filter { ($0.target == target || $0.query.groups.isEmpty && $0.query.sorts == nil) && $0.ordered == ordered && $0.scoped == scoped }
            .filter { isValid($0, registry: registry) }
    }

    /// Examples that no longer interpret cleanly against the registry — must be empty.
    static func staleExamples(registry: QueryFieldRegistry) -> [Example] {
        (all + modelExtras).filter { !isValid($0, registry: registry) }
    }

    private static func isValid(_ example: Example, registry: QueryFieldRegistry) -> Bool {
        AskInterpreter.interpret(example.query, target: example.target, registry: registry, now: Date()).dropped.isEmpty
    }

    static func rendered(for target: QueryTarget, ordered: Bool, scoped: Bool, registry: QueryFieldRegistry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return valid(for: target, ordered: ordered, scoped: scoped, registry: registry).map { example in
            let json = (try? String(data: encoder.encode(example.query), encoding: .utf8)) ?? "{}"
            return "Request: \(example.request)\nAnswer: \(json)"
        }.joined(separator: "\n\n")
    }
}
