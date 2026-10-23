import Foundation

/// The parts of a request that follow a few fixed, unambiguous phrasings — "top 25", "this year", "tagged with X",
/// "more than 100 times", "not loved" — read by code, not by the language model. A small on-device model picks the
/// wrong field for these often enough to notice (a "top 25" became a rank filter, a tag became an artist name);
/// code gets them right every time and its answer is checked against the same registry as everything else.
/// Only phrasings that can't mean anything else are read here; anything looser is left to the model, and where the
/// two disagree about one of these parts the code wins.
struct AskHints: Sendable, Equatable {
    var target: QueryTarget?
    /// True when the request asks for an order ("top", "most played"); nil when it doesn't say.
    var ordered: Bool?
    var ascending = false
    var count: Int?
    /// The time window the request puts plays in, when it does.
    var scope: QueryScope?
    var tags: [String] = []
    var tagsOp: QueryOperator = .tagsIsAny
    var tagsFieldID = "tags"
    var loved: Bool?
    var plays: (op: QueryOperator, value: Double)?
    /// "Haven't played in N days" (a rolling gap, not a window).
    var gapDays: Double?
    /// "Haven't played this year": no plays inside the window.
    var unplayedInScope = false
    /// The request said how to order it ("… by duration"), so the code doesn't impose a plays order.
    var namesOwnOrder = false
    /// "Missing duration": the field asked about and how it was worded (so the model's "can't do that" note about it can go).
    var absent: (fieldID: String, phrase: String)?
    var missingImage = false
    /// An artist named in the request ("songs by X"), matched against the library's real names.
    var artist: String?
    /// Explicit sort keys named by field, in order ("by popularity then playcount") — a closed vocabulary, so this
    /// only ever fires on a name the request actually used.
    var sortFields: [(fieldID: String, ascending: Bool)] = []
    /// A diversity cap named outright ("2 per artist", "one song per album") or implied ("from each Band X album" —
    /// "each ... album" means 1 per album) — never a guess at a number nobody said.
    var perArtist: Int?
    var perAlbum: Int?
    var perReleaseYear: Int?

    static func == (a: AskHints, b: AskHints) -> Bool {
        a.target == b.target && a.ordered == b.ordered && a.ascending == b.ascending && a.count == b.count && a.scope == b.scope
            && a.tags == b.tags && a.tagsOp == b.tagsOp && a.tagsFieldID == b.tagsFieldID && a.loved == b.loved
            && a.plays?.op == b.plays?.op && a.plays?.value == b.plays?.value && a.gapDays == b.gapDays
            && a.unplayedInScope == b.unplayedInScope && a.namesOwnOrder == b.namesOwnOrder
            && a.absent?.fieldID == b.absent?.fieldID && a.missingImage == b.missingImage && a.artist == b.artist
            && a.sortFields.map(\.fieldID) == b.sortFields.map(\.fieldID) && a.sortFields.map(\.ascending) == b.sortFields.map(\.ascending)
            && a.perArtist == b.perArtist && a.perAlbum == b.perAlbum && a.perReleaseYear == b.perReleaseYear
    }

    var isEmpty: Bool { self == AskHints() }
}

enum AskPatterns {
    // MARK: - Reading

    static func read(_ request: String, knownTags: Set<String>?, knownArtists: Set<String>? = nil, calendar: Calendar = AppCalendars.listening) -> AskHints {
        let text = request.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        var hints = AskHints()

        hints.target = target(in: text)

        // Order and number of results.
        if let n = firstNumber(text, #"\b(?:top|first|best)\s+(\d+|\#(numberWords))\b"#) ?? firstNumber(text, #"\b(\d+|\#(numberWords))\s+(?:most|top|best)\b"#) {
            hints.count = n; hints.ordered = true
        }
        if matches(text, #"\b(?:top|most[- ](?:played|listened|scrobbled)|(?:played|listened to|scrobbled) the most|favou?rite|best)\b"#) { hints.ordered = true }
        if matches(text, #"\b(?:least[- ](?:played|listened|scrobbled)|fewest|(?:played|listened to|scrobbled) the least)\b"#) { hints.ordered = true; hints.ascending = true }
        hints.namesOwnOrder = matches(text, #"\b(?:sorted|ordered|sort|order|ranked)\b|\bby\s+(?:duration|length|release|year|date|name|title|rank)"#)

        let playedCue = matches(text, #"\b(?:played|listened|scrobbled|heard|plays|listens)\b"#)
        let negation = #"(?:haven'?t|have not|hasn'?t|has not|didn'?t|did not|not|never|no)"#

        // A rolling gap: "haven't played in a year", "not heard for 6 months", "in the last 30 days".
        if let (amount, unit) = firstAmount(text, #"\#(negation)\b[^.,;]{0,30}?\b(?:in|for|since)\s+(?:the\s+|over the\s+)?(?:(?:last|past)\s+)?(a|an|one|\d+)\s+(day|week|month|year)s?\b"#) {
            hints.gapDays = amount * unit
        }

        // A time window.
        var scope: QueryScope?
        if let (kind, unit) = firstWords(text, #"\bthis\s+(year|month|week|quarter)\b"#), kind == "this" { scope = .calendar(unit) }
        else if let (_, unit) = firstWords(text, #"\blast\s+(year|month|week|quarter)\b"#) { scope = QueryScope.calendar(unit).shifted(back: 1, unit) }
        else if hints.gapDays == nil, let (amount, days) = firstAmount(text, #"\b(?:last|past)\s+(\d+)\s+(day|week)s?\b"#) { scope = .trailing(days: Int(amount * days)) }
        else if let year = firstInt(text, #"\bin\s+(19\d\d|20\d\d)\b"#), let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) {
            // "discovered in 2023" is about when something began, not a window on plays.
            if !matches(text, #"\b(?:discover|first|start|began|begin|found|release|released|came out|new)\w*\b"#) {
                scope = .absolute(from: start, to: calendar.date(byAdding: .day, value: 1, to: end)!.addingTimeInterval(-1))
            }
        }

        // How many plays.
        if let (op, value) = playsCondition(text) { hints.plays = (op, value) }
        else if matches(text, #"\b(?:no|zero|0)\s+(?:plays|scrobbles|listens)\b|\bnever\s+(?:been\s+)?(?:played|listened)|\bunplayed\b"#) { hints.plays = (.equals, 0) }

        // Whether a window is about plays: the request orders by plays, counts them, or says "played".
        // A comparison ("doubled compared to last year") uses the period as a baseline, not a window on plays — the model's job.
        let compares = matches(text, #"\b(?:compared|comparing|versus|vs\.?|doubled|tripled|halved|changed?|grew|grown|dropped|fell|increased?|decreased?)\b"#)
        if let scope, !compares, !matches(text, #"\bdiscover\w*\b"#), hints.ordered == true || hints.plays != nil || playedCue {
            hints.scope = scope
            if hints.ordered != true, hints.plays == nil, hints.gapDays == nil, matches(text, #"\#(negation)\s+(?:\w+\s+){0,2}(?:played|listened|heard|scrobbled)\b"#) {
                hints.unplayedInScope = true
            }
        }

        hints.loved = loved(text)
        (hints.absent, hints.missingImage) = absence(text)
        if let knownTags, let found = tags(text, knownTags: knownTags) {
            hints.tags = found.names; hints.tagsOp = found.op; hints.tagsFieldID = found.fieldID
        }

        // "by <clause>" can name an artist ("songs by Aldous Harding") or a sort ("by popularity then playcount") —
        // each clause is tried against the closed sort vocabulary first, then against the library's real artists.
        var artistIndex: [String: String] = [:]
        if let knownArtists { for name in knownArtists { artistIndex[name.lowercased()] = name } }
        for clause in byClauses(text) {
            if hints.sortFields.isEmpty, let fields = sortFieldsIn(clause) { hints.sortFields = fields; hints.namesOwnOrder = true }
            else if hints.artist == nil, let name = artistIn(clause, index: artistIndex) { hints.artist = name }
        }
        (hints.perArtist, hints.perAlbum, hints.perReleaseYear) = groupLimitIn(text)
        return hints
    }

    // MARK: - Applying

    /// Folds what the code read into what the model produced. The code's parts replace the model's on the same
    /// subject; everything else the model wrote stays.
    static func apply(_ hints: AskHints, to interpretation: AskInterpretation, target: QueryTarget, registry: QueryFieldRegistry, request: String) -> AskInterpretation {
        var result = interpretation
        var spec = result.spec
        let lowered = request.lowercased()

        // A play-count threshold is always a number the person said. A small model fills one in from nowhere
        // ("plays > 100,000", "plays < 0"), so one that isn't in the wording is dropped, and shown as dropped.
        let said = numbers(in: lowered)
        spec.groups = spec.groups.map { group in
            group.filter { condition in
                guard condition.field.id == "plays" || condition.field.id == "allTimePlays" || condition.field.id == "recentPlays" else { return true }
                if condition.op == .isMissing || condition.op == .hasValue {
                    result.dropped.append(.init(what: "condition on “\(condition.field.id)”", reason: "plays are counted, never missing — “no plays” means zero plays"))
                    return false
                }
                let numeric = condition.operands.compactMap { operand -> Double? in if case .number(let n) = operand { return n } else { return nil } }
                if numeric.contains(where: { $0 < 0 }) || (condition.op == .lessThan && numeric.first == 0) {
                    result.dropped.append(.init(what: "condition on “\(condition.field.id)”", reason: "no item can have fewer than zero plays"))
                    return false
                }
                guard let bad = numeric.first(where: { $0 != 0 && !said.contains($0) }) else { return true }
                result.dropped.append(.init(what: "condition on “\(condition.field.id)”", reason: "\(bad.formatted()) isn’t a number in your request"))
                return false
            }
        }.filter { !$0.isEmpty }
        // Things the model says it couldn't express must be things the request mentions.
        let words = Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let handled = [hints.absent?.phrase, hints.missingImage ? "image" : nil].compactMap { $0 }
        result.unsupported = result.unsupported.filter { note in
            !handled.contains { note.lowercased().contains($0) } &&
            note.lowercased().split(whereSeparator: { !$0.isLetter }).contains { $0.count >= 4 && (words.contains(String($0)) || lowered.contains(String($0))) }
        }
        let statedCaps = Caps(perArtist: hints.perArtist, perAlbum: hints.perAlbum, perReleaseYear: hints.perReleaseYear)
        if !statedCaps.isEmpty { result.unsupported = result.unsupported.filter { !restatesCap($0, caps: statedCaps) } }
        // An order nobody asked for ("albums I've played more than 50 times, sorted by artist rank") is noise.
        if hints.ordered != true, !hints.namesOwnOrder, !impliesOrder(lowered) { spec.sorts = [] }
        guard !hints.isEmpty else {
            result.spec = spec
            result.spec.columns = AskInterpreter.columns(for: spec, target: target, registry: registry)
            return result
        }

        var replaced = Set<String>()
        if !hints.tags.isEmpty { replaced.formUnion(["tags", "myTags"]) }
        if hints.loved != nil { replaced.insert("loved") }
        if let absent = hints.absent { replaced.insert(absent.fieldID) }
        if hints.missingImage { replaced.insert("missingImage") }
        if hints.plays != nil { replaced.formUnion(["plays", "allTimePlays"]) }
        if hints.gapDays != nil { replaced.insert("daysSinceLastPlayed") }
        if hints.count != nil, !lowered.contains("rank") { replaced.formUnion(["playRank", "artistPlayRank"]) }
        if hints.unplayedInScope { replaced.formUnion(["plays", "lastPlayed"]) }
        // A window on plays replaces the model's own reading of it; and "top albums in 2023" isn't about release year.
        if hints.scope != nil { replaced.insert("plays") }
        if hints.scope != nil, hints.gapDays == nil, !lowered.contains("first") { replaced.formUnion(["daysSinceLastPlayed", "daysSinceFirstPlayed"]) }
        // "Top" and "favorite" mean most played; a popularity filter on top of that is the model guessing.
        if hints.ordered == true, !lowered.contains("popular") { replaced.formUnion(["popular", "popularForArtist", "popularityScore"]) }
        if hints.scope != nil, !lowered.contains("releas"), !lowered.contains("came out") { replaced.formUnion(["releaseYear", "releaseDate"]) }
        if hints.artist != nil, target != .artist { replaced.insert("artist") }
        // Each named sort key is only ever a sort — a filter the model built on the same field is its own confusion
        // ("playcount" read as a threshold instead of an order), so that field's conditions go too.
        let validatedSortFields: [(ref: QueryFieldRef, direction: QuerySortDirection)] = hints.sortFields.compactMap { entry in
            guard let field = try? registry.field(entry.fieldID), field.targets.contains(target) else {
                result.dropped.append(.init(what: "sort by “\(entry.fieldID)”", reason: "not a field of \(target.rawValue)s"))
                return nil
            }
            replaced.insert(entry.fieldID)
            if entry.fieldID == "plays" { replaced.insert("allTimePlays") }
            if entry.fieldID == "popularityScore" { replaced.formUnion(["popular", "popularForArtist"]) }
            return (QueryFieldRef(entry.fieldID), entry.ascending ? .ascending : .descending)
        }

        // A tag the model read as a name ("Artist contains running") is the same thing said wrongly.
        let tagWords = Set(hints.tags)
        func isTagAsText(_ c: QueryCondition) -> Bool {
            guard !tagWords.isEmpty, let field = try? registry.field(c.field.id), field.type == .text,
                  case .text(let t)? = c.operands.first else { return false }
            return tagWords.contains(t.lowercased())
        }
        spec.groups = spec.groups.map { $0.filter { !replaced.contains($0.field.id) && !isTagAsText($0) } }.filter { !$0.isEmpty }

        result.dropped.removeAll { d in replaced.contains { d.what.contains("“\($0)”") } && !d.reason.contains("plays") }
        var added: [QueryCondition] = []
        func add(_ condition: QueryCondition) {
            do {
                let resolved = try registry.resolve(condition.field, target: target)
                try QueryMatcher.validate(fieldID: resolved.field.id, fieldType: resolved.field.type, op: condition.op, operands: condition.operands)
                added.append(condition)
            } catch {
                result.dropped.append(.init(what: "“\(condition.field.id)” condition read from the wording", reason: "\(error)"))
            }
        }
        func scoped(_ id: String) -> QueryFieldRef {
            var ref = QueryFieldRef(id)
            if let scope = hints.scope, (try? registry.field(id))?.supportsScope == true { ref.scope = scope }
            return ref
        }

        if let artistName = hints.artist, target != .artist { add(QueryCondition("artist", .textIs, [.text(artistName)])) }
        if let absent = hints.absent { add(QueryCondition(absent.fieldID, .isMissing)) }
        if hints.missingImage { add(QueryCondition("missingImage", .isTrue)) }
        if !hints.tags.isEmpty { add(QueryCondition(hints.tagsFieldID, hints.tagsOp, [.tags(hints.tags)])) }
        if let loved = hints.loved, target == .track { add(QueryCondition("loved", loved ? .isTrue : .isFalse)) }
        if let plays = hints.plays { add(QueryCondition(scoped("plays"), plays.op, [.number(plays.value)])) }
        if let gap = hints.gapDays { add(QueryCondition("daysSinceLastPlayed", .greaterThan, [.number(gap)])) }
        if hints.unplayedInScope { add(QueryCondition(scoped("plays"), .equals, [.number(0)])) }
        else if hints.scope != nil, hints.ordered != true, hints.plays == nil { add(QueryCondition(scoped("plays"), .greaterThan, [.number(0)])) }
        // "Top … this year" means played this year: without it the list ends in items with no plays in the window.
        if hints.scope != nil, hints.ordered == true, !hints.ascending, hints.plays == nil {
            add(QueryCondition(scoped("plays"), .greaterThan, [.number(0)]))
        }

        if !added.isEmpty {
            if spec.groups.isEmpty { spec.groups = [added] }
            else { spec.groups = spec.groups.map { Array(($0 + added).prefix(AskInterpreter.maxConditionsPerGroup + added.count)) } }
        }

        if hints.ordered == true, !hints.namesOwnOrder {
            spec.sorts = [QuerySort(key: .field(scoped(AskInterpreter.defaultSortFieldID)), direction: hints.ascending ? .ascending : .descending)]
        } else if hints.ordered == true, spec.sorts.isEmpty {
            spec.sorts = [QuerySort(key: .field(scoped(AskInterpreter.defaultSortFieldID)), direction: hints.ascending ? .ascending : .descending)]
        }
        // Sort keys named outright always win — over both the model's own sort and the "top N" default above.
        if !validatedSortFields.isEmpty {
            spec.sorts = validatedSortFields.map { QuerySort(key: .field($0.ref), direction: $0.direction) }
        }
        if let count = hints.count { spec.limit = count }

        // A diversity cap only applies where the registry itself would accept it — named outright but on the wrong
        // target is dropped and explained, not silently kept or crashed on.
        if hints.perArtist != nil || hints.perAlbum != nil || hints.perReleaseYear != nil {
            spec.groupLimit = AskInterpreter.groupLimit(
                perArtist: hints.perArtist, perAlbum: hints.perAlbum, perReleaseYear: hints.perReleaseYear, target: target, dropped: &result.dropped
            )
        }

        applyBreakdown(to: &spec, request: request)
        applyYearOrder(to: &spec, request: request)
        spec.columns = AskInterpreter.columns(for: spec, target: target, registry: registry)
        result.spec = spec
        return result
    }

    /// The direction a request puts a per-release-year result in: "newest first", "latest to earliest" (newest first) or "oldest first",
    /// "chronologically" (oldest first). Nil when it says nothing, which leaves the automatic order (oldest first).
    static func yearOrder(in request: String) -> QuerySortDirection? {
        let text = request.lowercased()
        if matches(text, #"\b(?:newest|latest|most recent|recent)\s+(?:year\s+)?first\b|\b(?:newest|latest|most recent)\s+to\s+(?:oldest|earliest)\b|\b(?:reverse chronological|descending)\b|\bby year,?\s+(?:newest|latest)\b"#) { return .descending }
        if matches(text, #"\b(?:oldest|earliest)\s+(?:year\s+)?first\b|\b(?:oldest|earliest)\s+to\s+(?:newest|latest)\b|\bchronolog\w*\b|\bascending\b"#) { return .ascending }
        return nil
    }

    /// "my top 3 artists of each year", "most played album every year", "top song per year": the best of each calendar year of listening.
    /// "Each release year" is the other thing (the cap), and bare "by year" is as likely to mean sorted by year, so only the wordings that
    /// say each/every/per year (or a top thing "by year") count.
    static func breakdownByYear(in request: String) -> Bool {
        let text = request.lowercased()
        guard !matches(text, #"\b(?:release|released)\s+year\b|\byear\s+of\s+release\b"#) else { return false }
        return matches(text, #"\b(?:each|every|per)\s+(?:calendar\s+)?year\b|\byear\s+by\s+year\b|\bfor\s+each\s+year\b|\byearly\b|\bannual(?:ly)?\b"#)
            || matches(text, #"\b(?:top|best|most[- ]played|favou?rite)\s+(?:\d+\s+|\w+\s+)?(?:artist|album|track|song|tune)s?\s+(?:by|for|of|in)\s+(?:each\s+)?year\b"#)
    }

    /// An "unsupported" note that only restates "for each year".
    static func restatesBreakdown(_ note: String) -> Bool {
        matches(note.lowercased(), #"\b(?:each|every|per)\s+(?:calendar\s+)?year\b|\byear\s+by\s+year\b|\byearly\b|\bannual|\bby\s+year\b|\bgroup\w*\s+by\s+year\b"#)
    }

    /// A breakdown by calendar year stated in the request: the query runs once per year and the limit counts per year. With no number the
    /// request means the one ("my top artist each year") when it says a singular top thing, else a handful.
    static func applyBreakdown(to spec: inout QuerySpec, request: String) {
        guard breakdownByYear(in: request) else { return }
        spec.breakdown = QueryBreakdown(newestFirst: yearOrder(in: request) == .descending ? true : nil)
        if spec.limit == nil {
            let singular = matches(request.lowercased(), #"\b(?:my|the)?\s*(?:most[- ]played|top|favou?rite|best)\s+(?:song|track|album|artist|tune)\b(?!s)"#)
            spec.limit = singular ? 1 : (read(request, knownTags: nil).count ?? 10)
        }
        if spec.sorts.isEmpty { spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)] }
    }

    /// With a per-release-year cap, a stated direction for the years becomes the display order (the sorts still pick the winners).
    static func applyYearOrder(to spec: inout QuerySpec, request: String) {
        guard spec.groupLimit?.perReleaseYear != nil, spec.breakdown == nil, let direction = yearOrder(in: request) else { return }
        spec.resultSorts = [QuerySort(key: .field(QueryFieldRef("releaseYear")), direction: direction)]
    }

    /// Wording that asks for an order without the words "top" or "sorted": "longest", "newest", "most recent".
    static func impliesOrder(_ text: String) -> Bool {
        matches(text, #"\b(?:most|least|top|best|worst|first|last|latest|recent|recently|earliest|newest|oldest|longest|shortest|highest|lowest|biggest|smallest|fastest|slowest|favou?rites?|fewest)\b|\b\w{3,}est\b"#)
    }

    /// A number the model reports as the request's count only counts if the request said it.
    static func confirmed(count: Int?, in request: String) -> Int? {
        guard let count, numbers(in: request.lowercased()).contains(Double(count)) else { return nil }
        return count
    }

    /// Every number a request states: digits ("50", "1,000", "10k") and number words ("ten", "twice").
    static func numbers(in text: String) -> Set<Double> {
        var out = Set<Double>()
        if let expression = regex(#"(\d[\d,]*(?:\.\d+)?)\s*(k\b)?"#) {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text), var value = Double(text[range].replacingOccurrences(of: ",", with: "")) else { continue }
                if match.range(at: 2).location != NSNotFound { value *= 1000 }
                out.insert(value)
            }
        }
        for word in text.split(whereSeparator: { !$0.isLetter && $0 != "-" }) {
            if let value = wordValues[String(word)] ?? ["once": 1, "twice": 2, "thousand": 1000][String(word)] { out.insert(Double(value)) }
        }
        return out
    }

    // MARK: - Individual readers

    private static func target(in text: String) -> QueryTarget? {
        var found = Set<QueryTarget>()
        if matches(text, #"\b(?:artists?|bands?|musicians?)\b"#) { found.insert(.artist) }
        if matches(text, #"\b(?:albums?|records?|lps?)\b"#) { found.insert(.album) }
        if matches(text, #"\b(?:songs?|tracks?|tunes?)\b"#) { found.insert(.track) }
        return found.count == 1 ? found.first : nil
    }

    private static func playsCondition(_ text: String) -> (QueryOperator, Double)? {
        let number = #"(\d[\d,]*)"#
        let unit = #"(?:times|plays|scrobbles|listens)"#
        let table: [(String, QueryOperator)] = [
            (#"\b(?:more than|over|greater than|above)\s+\#(number)\s+\#(unit)\b"#, .greaterThan),
            (#"\bat least\s+\#(number)\s+\#(unit)\b"#, .greaterThanOrEqual),
            (#"\b\#(number)\s*\+\s*\#(unit)\b"#, .greaterThanOrEqual),
            (#"\b(?:fewer than|less than|under|below)\s+\#(number)\s+\#(unit)\b"#, .lessThan),
            (#"\b(?:at most|no more than|up to)\s+\#(number)\s+\#(unit)\b"#, .lessThanOrEqual),
            (#"\bexactly\s+\#(number)\s+\#(unit)\b"#, .equals),
        ]
        for (pattern, op) in table {
            if let raw = capture(text, pattern), let value = Double(raw.replacingOccurrences(of: ",", with: "")) { return (op, value) }
        }
        return nil
    }

    /// What a person calls each field they can ask about being missing. Only fields where "missing" means
    /// something (a value not found), so "no plays" is never read as a missing value.
    private static let missingAliases: [(id: String, phrases: [String])] = [
        ("releaseDate", ["release date", "release dates", "date released"]),
        ("releaseYear", ["release year", "year released"]),
        ("duration", ["duration", "durations", "length", "runtime", "run time", "track length"]),
        ("tags", ["tags", "tag", "genre", "genres"]),
    ]
    private static let imagePhrases = ["image", "images", "artwork", "cover", "cover art", "album art", "picture", "photo"]

    private static func absence(_ text: String) -> ((fieldID: String, phrase: String)?, Bool) {
        guard let tail = capture(text, #"\b(?:missing|without|lacks?|lacking|blank|unknown|unset|not set|no|(?:doesn'?t|don'?t|does not|do not)\s+have|has no|have no|with no)\s+(?:an?\s+|the\s+|any\s+)?(.{1,40})$"#) else { return (nil, false) }
        let words = " " + tail.trimmingCharacters(in: .punctuationCharacters) + " "
        if imagePhrases.contains(where: { words.contains(" \($0) ") }) { return (nil, true) }
        var best: (String, String)?
        for (id, phrases) in missingAliases {
            for phrase in phrases where words.contains(" \(phrase) ") && phrase.count > (best?.1.count ?? 0) { best = (id, phrase) }
        }
        return (best.map { (fieldID: $0.0, phrase: $0.1) }, false)
    }

    private static func loved(_ text: String) -> Bool? {
        if matches(text, #"\b(?:(?:aren'?t|are not|isn'?t|is not|haven'?t|have not|hasn'?t|has not|not|never)\s+(?:yet\s+|been\s+|ever\s+)?loved)\b|\bunloved\b"#) { return false }
        if matches(text, #"\bloved\b"#) { return true }
        return nil
    }

    /// Tags named after "tagged (with)": each comma / "or" / "and" piece that is a tag in this library. Names
    /// that aren't in the library are left to the model to flag, so a made-up tag never becomes a silent match-nothing.
    private static func tags(_ text: String, knownTags: Set<String>) -> (names: [String], op: QueryOperator, fieldID: String)? {
        guard let tail = capture(text, #"\btagged(?:\s+(?:with|as))?\s+(?:the\s+(?:tags?\s+)?)?(.+)$"#) ?? capture(text, #"\bwith the tags?\s+(.+)$"#) else { return nil }
        let negated = matches(text, #"\b(?:not|isn'?t|aren'?t|never|un)\s*tagged\b|\bwithout\b[^.]*\btag"#)
        var names: [String] = []
        var usedAnd = false
        let stops = [" that ", " which ", " i ", " i'", " but ", " this ", " last ", " in ", " from ", " played ", " sorted ", " by ", " with ", " for ", " since ", " over ", " more ", " less ", " and i", " who ", " where ", " ordered "]
        for piece in tail.components(separatedBy: CharacterSet(charactersIn: ",")).flatMap({ $0.components(separatedBy: " or ") }) {
            let segments = piece.components(separatedBy: " and ")
            if segments.count > 1 { usedAnd = true }
            for var segment in segments {
                segment = " " + segment.trimmingCharacters(in: .whitespaces) + " "
                for stop in stops { if let range = segment.range(of: stop) { segment = String(segment[..<range.lowerBound]) } }
                var name = segment.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                if name.hasSuffix(" music") { name = String(name.dropLast(6)) }
                if case .tags(let normalized) = QueryValue.tags(normalizing: [name]), let tag = normalized.first, knownTags.contains(tag), !names.contains(tag) { names.append(tag) }
            }
        }
        guard !names.isEmpty else { return nil }
        let mine = matches(text, #"\bmy tags?\b|\bi(?:'ve)?\s+tagged\b|\btagged by me\b"#)
        let op: QueryOperator = negated ? .tagsIsNotAny : (usedAnd && names.count > 1 ? .tagsIsAll : .tagsIsAny)
        return (names, op, mine ? "myTags" : "tags")
    }

    // MARK: - "by <clause>" — an artist, or an explicit sort

    /// What a person calls each sortable field, for "sort by X (then Y)" — a closed, enumerable vocabulary (the
    /// same reasoning as `missingAliases`), so a name that isn't here is simply left for the model.
    private static let sortAliases: [(id: String, phrases: [String])] = [
        ("plays", ["plays", "play count", "playcount", "times played", "number of plays", "scrobbles"]),
        ("allTimePlays", ["all-time plays", "all time plays", "lifetime plays"]),
        ("popularityScore", ["popularity"]),
        ("duration", ["duration", "length", "track length", "song length", "runtime"]),
        ("releaseYear", ["release year", "year released"]),
        ("releaseDate", ["release date", "date released", "released"]),
        ("lastPlayed", ["last played", "most recently played", "recently played"]),
        ("firstPlayed", ["first played", "date discovered", "when discovered"]),
        ("daysSinceLastPlayed", ["days since last played"]),
        ("name", ["name", "title", "alphabetically", "alphabetical"]),
        ("artist", ["artist name", "artist"]),
        ("artistDiscographySize", ["discography size", "number of albums"]),
    ]

    /// Every "by …" clause in the text, each running up to the next "by" or the end.
    private static func byClauses(_ text: String) -> [String] {
        guard let re = regex(#"\bby\s+(.+?)(?=\s+by\s|$)"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    /// Reads a clause as one or more sort keys ("popularity then playcount", "duration, then name") — only when
    /// EVERY piece names a real field; a clause that names anything else (an artist, "duration and vibe") isn't a
    /// sort at all, and is left alone.
    private static func sortFieldsIn(_ clause: String) -> [(fieldID: String, ascending: Bool)]? {
        let pieces = clause.components(separatedBy: CharacterSet(charactersIn: ",")).flatMap { $0.components(separatedBy: " and ") }.flatMap { $0.components(separatedBy: " then ") }
        var out: [(fieldID: String, ascending: Bool)] = []
        for raw in pieces {
            var piece = raw.trimmingCharacters(in: .whitespaces)
            var ascending = false
            if piece.hasSuffix(" ascending") { ascending = true; piece = String(piece.dropLast(10)).trimmingCharacters(in: .whitespaces) }
            else if piece.hasSuffix(" descending") { piece = String(piece.dropLast(11)).trimmingCharacters(in: .whitespaces) }
            guard !piece.isEmpty, let id = sortAliases.first(where: { $0.phrases.contains(piece) })?.id else { return nil }
            out.append((id, ascending))
        }
        return out.isEmpty ? nil : out
    }

    /// Trims a clause down to a candidate name (stopping at the first word that couldn't be part of one), then
    /// checks it against the library's real artists — never a guess, only ever an exact, validated match.
    private static func artistIn(_ clause: String, index: [String: String]) -> String? {
        var phrase = " " + clause.trimmingCharacters(in: .whitespaces) + " "
        let stops = [" that ", " which ", " this ", " last ", " in ", " since ", " from ", " played ", " sorted ", " ordered ", " ranked ", " for ", " with ", " over ", " and ", " then ", " who "]
        for stop in stops { if let r = phrase.range(of: stop) { phrase = String(phrase[..<r.lowerBound]) + " " } }
        let name = phrase.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        guard !name.isEmpty else { return nil }
        return index[name.lowercased()]
    }

    // MARK: - Diversity caps ("2 per artist", "from each Band X album", "one per release year")

    /// What a request says about diversity caps, as a closed vocabulary: no number is ever invented.
    struct Caps: Equatable, Sendable {
        var perArtist: Int?
        var perAlbum: Int?
        var perReleaseYear: Int?
        var isEmpty: Bool { perArtist == nil && perAlbum == nil && perReleaseYear == nil }
    }

    /// The caps a plain-English request states ("2 per artist", "the top song from each album", "one album per
    /// release year"). Bare "each year" is NOT read: it is as likely to mean the year it was played.
    static func groupLimit(in request: String) -> Caps {
        let text = request.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        let (artist, album, year) = groupLimitIn(text)
        return Caps(perArtist: artist, perAlbum: album, perReleaseYear: year)
    }

    /// "N per artist"/"N per album"/"N per release year" — a number, then up to two words (so "2 songs per album" and
    /// "1 track per artist" both match, not just a bare "N per album"), or "each"/"every ... artist/album" (or "each
    /// release year") with no number, which means 1. "each"/"every" only ever fires right next to the word itself.
    private static func groupLimitIn(_ text: String) -> (perArtist: Int?, perAlbum: Int?, perReleaseYear: Int?) {
        func explicit(_ axis: String) -> Int? {
            firstNumber(text, #"\b(\d+|\#(numberWords))\b(?:\s+\w+){0,2}?\s+per\s+\#(axis)s?\b"#)
        }
        func each(_ axis: String) -> Bool {
            matches(text, #"\b(?:each|every)\b(?:\s+\S+){0,4}?\s+\#(axis)s?\b"#)
        }
        let perArtist = explicit("artist") ?? (each("artist") ? 1 : nil)
        let perAlbum = explicit("album") ?? (each("album") ? 1 : nil)
        // Only the explicit wording: "release year", "year of release" ("each year" alone stays the model's call).
        let releaseYear = #"(?:(?:release|released)\s+year|year\s+of\s+release)"#
        let perYear = explicit(releaseYear) ?? (matches(text, #"\b(?:each|every)\s+\#(releaseYear)s?\b"#) || topOneByReleaseYear(text) ? 1 : nil)
        return (perArtist, perAlbum, perYear)
    }

    /// "Top album by release year", "best track of each release year": a singular superlative followed by "by / for / of / in (each) release year"
    /// asks for the best one of every year. The plural ("top albums by release year") could just as well mean sorted by year, so it is
    /// left to the model.
    static func topOneByReleaseYear(_ lowered: String) -> Bool {
        matches(lowered, #"\b(?:top|best|favou?rite|most[- ]played|#1)\s+(?:album|track|song|tune)\s+(?:by|for|of|in|from)\s+(?:(?:each|every)\s+)?(?:release|released)\s+year\b"#)
    }

    /// "my most played song", "the top album": a singular superlative asks for the one.
    static func asksForOne(_ request: String) -> Bool {
        let text = request.lowercased()
        // "the top song from each album" is one per album, not one in all.
        guard !mentionsDiversity(request) else { return false }
        return matches(text, #"\b(?:my|the)\s+(?:(?:most|least)[- ](?:played|listened(?: to)?|scrobbled)|top|favou?rite|best)\s+(?:song|track|album|artist|tune)\b(?!s)"#)
    }

    /// The number in "find 25 songs similar to X" / "40 tracks like X": a count, up to two words, then similar/like. Nil when there is none.
    static func similarCount(in request: String) -> Int? {
        let text = request.lowercased()
        guard let n = firstNumber(text, #"\b(\d+|\#(numberWords))\b(?:\s+\w+){0,2}?\s+(?:similar|like)\b"#), n >= 1, n <= 500 else { return nil }
        return n
    }

    /// True when the request has any wording about diversity (each, every, per, different, at most…). A cap the model sets with
    /// none of it is a guess.
    static func mentionsDiversity(_ request: String) -> Bool {
        let text = request.lowercased().replacingOccurrences(of: "’", with: "'")
        return matches(text, #"\b(?:per|each|every|distinct|different|unique|apiece)\b|\bat most\b|\bno more than\b|\bone (?:from|of each)\b|\bonly one\b|\bone track from\b"#)
            || topOneByReleaseYear(text)
    }

    /// An artist the request names after "by" ("songs by X"), matched against the library's real artist names; nil when it
    /// names none (or something that is a sort, "sorted by plays").
    static func namedArtist(in request: String, knownArtists: Set<String>) -> String? {
        let text = request.lowercased().replacingOccurrences(of: "’", with: "'")
        var index: [String: String] = [:]
        for name in knownArtists { index[name.lowercased().replacingOccurrences(of: "’", with: "'")] = name }
        for clause in byClauses(text) where sortFieldsIn(clause) == nil {
            if let name = artistIn(clause, index: index) { return name }
        }
        return nil
    }

    /// True when a note the model wrote under "unsupported" only restates a cap the app does support ("top song from
    /// each album — grouping by album isn't a field"): it names the thing being capped and a grouping word.
    static func restatesCap(_ note: String, caps: Caps) -> Bool {
        let lowered = note.lowercased()
        let grouping = matches(lowered, #"\b(?:each|every|per|group\w*|one|single|cap|limit\w*|top|best|most)\b"#)
        guard grouping else { return false }
        if caps.perArtist != nil, matches(lowered, #"\b(?:artist|band)s?\b"#) { return true }
        if caps.perAlbum != nil, matches(lowered, #"\balbums?\b"#) { return true }
        if caps.perReleaseYear != nil, matches(lowered, #"\b(?:release|released)\s+years?\b|\byears?\s+of\s+release\b|\byears?\b"#) { return true }
        return false
    }

    // MARK: - Regex helpers

    private static let numberWords = "one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|twenty-five|thirty|fifty|hundred"
    static let wordValues: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "twenty-five": 25, "thirty": 30, "fifty": 50, "hundred": 100]

    static func regex(_ pattern: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: pattern) }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        regex(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The first capture group of the first match.
    private static func capture(_ text: String, _ pattern: String, group: Int = 1) -> String? {
        guard let match = regex(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func firstInt(_ text: String, _ pattern: String) -> Int? { capture(text, pattern).flatMap { Int($0) } }

    private static func firstNumber(_ text: String, _ pattern: String) -> Int? {
        guard let raw = capture(text, pattern) else { return nil }
        return Int(raw) ?? wordValues[raw]
    }

    /// "(a|an|one|N) (day|week|month|year)" → the amount and the days one unit is worth.
    private static func firstAmount(_ text: String, _ pattern: String) -> (Double, Double)? {
        guard let amountText = capture(text, pattern), let unitText = capture(text, pattern, group: 2) else { return nil }
        let amount = Double(amountText) ?? 1
        let days: [String: Double] = ["day": 1, "week": 7, "month": 30, "year": 365]
        guard amount >= 1, let perUnit = days[unitText] else { return nil }
        return (amount, perUnit)
    }

    /// ("this"/"last", unit) for a "this year" style phrase.
    private static func firstWords(_ text: String, _ pattern: String) -> (String, QueryScope.Unit)? {
        guard let unitText = capture(text, pattern), let unit = QueryScope.Unit(rawValue: unitText) else { return nil }
        let word = pattern.contains("this") ? "this" : "last"
        return (word, unit)
    }
}
