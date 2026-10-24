import Foundation
import SwiftData

/// What the model is told about the query system — built ENTIRELY from `QueryFieldRegistry`, so
/// there is no second description of the fields to keep in step with it: a field added to the
/// registry appears here (and in `AskSchema`) with no other change, carrying its own `help` text.
/// Only the fixed prose about how conditions combine is written here, and it names no field.
enum AskVocabulary {
    /// One line per field a target can use: id, value type, how to express its number, and its `help`.
    static func fieldLines(target: QueryTarget, registry: QueryFieldRegistry) -> [String] {
        registry.askFields(for: target).map { line(for: $0) }
    }

    static func line(for field: QueryField) -> String {
        var notes: [String] = [field.type.rawValue]
        if let unit = AskOperand.unit(of: field) { notes.append("number in \(unit.label)") }
        if case .percent = field.column.style { notes.append("a fraction from 0 to 1 (25% = 0.25)") }
        if case .year = field.column.style { notes.append("a calendar year") }
        if field.type == .tags { notes.append("tag names such as indie or folk") }
        if let choices = field.choices { notes.append("one of: " + choices.joined(separator: ", ")) }
        for parameter in field.parameters {
            let options = parameter.options.map { parameter.display($0) }.joined(separator: "/")
            notes.append("parameter \(parameter.id): \(options), default \(parameter.display(parameter.defaultValue))")
        }
        if field.comparesPeriods { notes.append("compares two periods: give scope (the recent period) AND comparedAgo (how long before it to compare with)") }
        else if field.supportsScope { notes.append("can take a date scope") }
        return "\(field.id) [\(notes.joined(separator: "; "))] \(field.name): \(field.help)"
    }

    /// Which operators each value type accepts — read from `QueryValueType.operators`, the one list.
    static func operatorLines() -> [String] {
        [QueryValueType.numeric, .text, .date, .boolean, .tags].map { type in
            "\(type.rawValue): " + type.operators.map { "\($0.rawValue) (\(operatorMeaning[$0] ?? $0.label))" }.joined(separator: ", ")
        }
    }

    /// What each operator means, in a few words. This is about the FIXED operator set (`QueryOperator`), not about
    /// fields; the checks fail if an operator is missing here, so a new operator can't reach the model unexplained.
    static let operatorMeaning: [QueryOperator: String] = [
        .equals: "is exactly", .notEquals: "is not", .greaterThan: "more than", .greaterThanOrEqual: "at least",
        .lessThan: "less than", .lessThanOrEqual: "at most", .between: "between two numbers",
        .textIs: "is exactly", .textIsNot: "is not", .contains: "contains", .doesNotContain: "does not contain",
        .startsWith: "starts with", .doesNotStartWith: "does not start with", .endsWith: "ends with",
        .doesNotEndWith: "does not end with", .wholeWord: "contains this whole word",
        .before: "before the day", .after: "after the day", .on: "on the day", .dateBetween: "between two days",
        .isTrue: "yes", .isFalse: "no",
        .tagsIsAny: "has at least one of these tags", .tagsIsAll: "has all of these tags",
        .tagsIsNotAny: "has none of these tags", .tagsIsNotAll: "lacks at least one of these tags",
        .hasValue: "has any value", .isMissing: "has no value",
    ]

    static func targetInstructions() -> String {
        """
        You read a request about someone's music listening history and answer four things.
        1. The KIND OF THING it asks for. "artists", "bands" and "musicians" are artist requests. "albums", \
        "records", "LPs" and "releases" are album requests. "songs", "tracks" and "tunes" are track requests.
        2. "scoped": true ONLY if the request limits plays or activity to a time window — "in 2023", "the last 30 \
        days", "this month", "last year", "since March". A plain gap like "haven't played in a year" is not a window. \
        Otherwise false.
        3. "absence": true ONLY if the request asks about something that has NO VALUE — missing, blank, unknown, \
        not set, "no …", never. Being "not loved" or "not played much" is not absence. Otherwise false.
        4. "tagged": true ONLY if the request refers to a genre, style or tag — indie, folk, workout, 90s. Otherwise false.

        Request: artists I've played more than 100 times
        Answer: {"target":"artist","scoped":false,"absence":false,"tagged":false}
        Request: my top records this year
        Answer: {"target":"album","scoped":true,"absence":false,"tagged":false}
        Request: songs I loved but haven't heard in a while
        Answer: {"target":"track","scoped":false,"absence":false,"tagged":false}
        Request: songs I haven't loved yet
        Answer: {"target":"track","scoped":false,"absence":false,"tagged":false}
        Request: artists I discovered in 2023
        Answer: {"target":"artist","scoped":true,"absence":false,"tagged":false}
        Request: artists tagged indie or folk
        Answer: {"target":"artist","scoped":false,"absence":false,"tagged":true}
        Request: tracks with no release date
        Answer: {"target":"track","scoped":false,"absence":true,"tagged":false}
        """
    }

    /// Stage 1b: only the order / number-of-results question, with examples that all have other clauses around it.
    static func shapeInstructions() -> String {
        """
        You read a request about someone's music listening history and answer two things.
        1. "ordered": true if the request asks for the top, most, least, best, newest, oldest or biggest of \
        something — in ANY part of it, even beside other conditions. Otherwise false.
        2. "count": the number of results it asks for, if it names one — "top 10", "the 5 …", "25 most played". A number \
        that is a threshold ("more than 100 plays", "at least 20 times") is not a count.

        Request: artists I've played more than 100 times
        Answer: {"ordered":false}
        Request: albums I've played at least 20 times
        Answer: {"ordered":false}
        Request: tracks longer than 6 minutes that I've played 3 times
        Answer: {"ordered":false}
        Request: top 25 songs that aren't loved that are tagged with running
        Answer: {"ordered":true,"count":25}
        Request: my 10 most played records this year
        Answer: {"ordered":true,"count":10}
        Request: songs I loved but haven't heard in a while
        Answer: {"ordered":false}
        Request: the newest albums I own
        Answer: {"ordered":true}
        Request: 5 most played artists that are tagged folk
        Answer: {"ordered":true,"count":5}
        Request: songs tagged running that I haven't loved
        Answer: {"ordered":false}
        Request: top songs I play on Friday nights
        Answer: {"ordered":true}
        """
    }

    static func queryInstructions(
        target: QueryTarget, ordered: Bool, scoped: Bool, absence: Bool, tagged: Bool = false, registry: QueryFieldRegistry, now: Date,
        context: AskContext = .none, calendar: Calendar = AppCalendars.listening
    ) -> String {
        let today = now.formatted(.iso8601.year().month().day())
        let weekday = now.formatted(.dateTime.weekday(.wide))
        let earliestNote = context.earliest.map { " The listening history begins \($0.formatted(.iso8601.year().month().day()))." } ?? ""
        let hasTagField = registry.askFields(for: target).contains { $0.type == .tags }
        let tagNote = tagged && hasTagField && !context.tags.isEmpty
            ? "\n        - Tag names that exist in this library (use exactly these, never invent one): \(context.tags.joined(separator: ", "))."
            : ""
        let orderedNote = ordered
            ? " This request asks for an order: put it in \"sorts\" (with the same period on the sort field as the request has). Its number of results is applied for you."
            : ""
        return """
        You turn a request into a structured query over the user's \(target.rawValue)s. You only choose \
        fields and values; you never compute results. Today is \(today) (\(weekday)).\(earliestNote) Days and times are in the user's local time zone.

        How the query works:
        - "groups" is a list of alternatives (OR). Each group is a list of conditions that must all hold (AND). \
        Put ALL the conditions of a request in ONE group, unless the request explicitly says "or" between \
        alternatives.
        - Each condition names a field id from the list below, an operator valid for that field's type, and \
        its operand. Use only field ids from the list. Never invent a field.
        - Only include what the request says. Do not add conditions it did not ask for. Do not repeat a condition.\(orderedNote)
        - A request about a day of the week or a time of day ("my Sunday morning artists", "Friday night albums") is \
        expressed by combining the day-of-week field with the time-of-day field. A request about a season ("my winter \
        songs", "artists I play in summer") uses the season field with Winter, Spring, Summer or Autumn.\(tagNote)
        - If the request asks about something no field measures — mood, feeling, lyrics, how a song sounds, similarity \
        to another artist — write it in "unsupported" and do NOT substitute a different field for it.
        - Date operands are calendar days written \(dateFormat); "before 2022" ends at 2021-12-31, "in 2022" spans \
        2022-01-01 to 2022-12-31. "sorts" orders the results (direction \
        "descending" puts the biggest first); "limit" keeps the first N.
        - A field that "can take a date scope" can be measured over a period instead of all time: scope kinds are \
        allTime, upToNow, trailing (the last N days), calendar (this day/week/month/quarter/year so far), or \
        absolute (from/to dates). shiftCount with shiftUnit moves the period back ("a year ago" = shiftCount 1, \
        shiftUnit year). Without a scope a field covers the whole listening history.
        - For any request that compares one period with another ("vs.", "compared to", "more than last year", \
        "climbed", "dropped") use a field marked "compares two periods", with scope for the recent period and \
        baseline for the earlier one — never a single-period field.
        - If any part of the request cannot be expressed with the fields below (mood, lyrics, genre-by-feel, \
        anything not in the list), do not guess: leave it out and describe it in "unsupported".

        Operators by field type:
        \(operatorLines().joined(separator: "\n"))

        Fields you may use:
        \(fieldLines(target: target, registry: registry).joined(separator: "\n"))

        Examples of the answer format:
        \(AskExamples.rendered(for: target, ordered: ordered, scoped: scoped, registry: registry))
        """
    }

    private static let dateFormat = AskWire.dateFormat
}

/// What the model is told about THIS library beyond the field list, so relative phrases and tag names resolve to
/// real things (today's date, where the history begins,
/// the library's real tag names).
struct AskContext: Sendable {
    static let tagLimit = 60
    /// The most common tags — shown to the model when the request is about tags.
    var tags: [String] = []
    /// Every tag in the library: a tag condition may only name one of these (checked when the answer is read).
    var knownTags: Set<String>?
    /// Every artist name in the library, for validating a code-read "by <artist>" — never shown to the model.
    var knownArtists: Set<String>?
    /// The cities the person has set (home and trips), for checking a city a model names; nil reads them from the settings.
    var knownCities: [String]?
    var earliest: Date?
    /// For finding the library item a "similar to X" request names.
    var container: ModelContainer?
    static let none = AskContext()
}

/// The unit a numeric operand is written in, where it differs from how the value is stored (a runtime is
/// stored in seconds but a person says minutes). The builder's own condition editor reads the same
/// `QueryField.inputUnit`, so the model and the manual editor agree about what "3" means.
enum AskOperand {
    static func unit(of field: QueryField) -> QueryInputUnit? { field.inputUnit }

    /// Converts a number the model wrote (in the field's input unit) to the stored unit.
    static func stored(_ number: Double, for field: QueryField) -> Double {
        number * (field.inputUnit?.perUnit ?? 1)
    }

    /// The reverse, for showing a stored operand back to the user.
    static func shown(_ stored: Double, for field: QueryField) -> Double {
        stored / (field.inputUnit?.perUnit ?? 1)
    }
}

extension QueryFieldRegistry {
    /// The fields Ask describes to the model — every field of the target except those marked `askable = false`.
    func askFields(for target: QueryTarget) -> [QueryField] { fields(for: target).filter(\.askable) }

    /// What the larger models are shown: everything the on-device model gets, plus the fields held back from it only
    /// because its context is small.
    func modelAskFields(for target: QueryTarget) -> [QueryField] { fields(for: target).filter { $0.askable || $0.askableByLargeModels } }
}
