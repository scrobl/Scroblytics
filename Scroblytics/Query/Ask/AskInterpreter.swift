import Foundation

/// Turns what the model wrote into a real `QuerySpec` — and is the trust boundary: nothing the model
/// says reaches the query engine except through here. Every condition and sort is checked with the
/// registry's own `resolve` (real field, right target, real parameter values, valid scope, baseline where
/// required) and `QueryMatcher.validate` (operator allowed for the type, right operand count and kind) —
/// the same checks a hand-built query gets, not a second validator. A leaf that fails is dropped and
/// recorded in `dropped`; the rest of the query still runs ("fail the leaf, not the whole query").
struct AskInterpretation: Sendable {
    struct Dropped: Sendable, Equatable {
        let what: String
        let reason: String
    }

    var spec: QuerySpec
    /// Conditions and sorts that failed validation and were left out.
    var dropped: [Dropped]
    /// Parts of the request the model said it could not express — shown to the user, never silently lost.
    var unsupported: [String]
    /// True when the model gave nothing usable at all (no conditions, no sort, and nothing flagged).
    var isEmpty: Bool { spec.groups.isEmpty && spec.sorts.isEmpty && spec.limit == nil && unsupported.isEmpty && spec.playFilter == nil }
}

enum AskInterpreter {
    /// The columns shown beside the name when the model doesn't pick any: the two the query tool starts with.
    static let baseColumns = ["plays", "lastPlayed"]
    static let maxColumns = 6
    /// The field an asked-for order falls back to — most played first.
    static let defaultSortFieldID = "plays"
    static let maxConditionsPerGroup = 5

    /// `count` is the number of results the request asked for (found in stage 1), applied as the limit.
    static func interpret(
        _ query: AskWire.Query, target: QueryTarget, registry: QueryFieldRegistry, now: Date, calendar: Calendar = AppCalendars.listening, count: Int? = nil, ordered: Bool = false,
        knownTags: Set<String>? = nil, knownCities: [String]? = nil, knownRegions: [String]? = nil, knownCountries: [String]? = nil
    ) -> AskInterpretation {
        var dropped: [AskInterpretation.Dropped] = []
        var spec = QuerySpec(target: target)

        for group in query.groups {
            var leaves: [QueryCondition] = []
            for condition in group {
                do {
                    leaves.append(try makeCondition(condition, target: target, registry: registry, calendar: calendar, knownTags: knownTags))
                } catch {
                    dropped.append(.init(what: "condition on “\(condition.field)”", reason: "\(error)"))
                }
            }
            // A group states each thing once: a second condition on the same field, period and operator (a model
            // that repeats itself with other numbers) adds nothing but noise, and a request has only a few parts.
            var unique: [QueryCondition] = []
            var seen = Set<String>()
            for leaf in leaves {
                let key = ((try? registry.resolve(leaf.field, target: target).cacheKey) ?? leaf.field.id) + "|" + leaf.op.rawValue
                if seen.insert(key).inserted, unique.count < maxConditionsPerGroup { unique.append(leaf) }
            }
            // A group whose every condition failed is dropped whole: an empty group would match everything.
            if !unique.isEmpty { spec.groups.append(unique) }
        }

        for sort in query.sorts ?? [] {
            do {
                let ref = try makeRef(id: sort.field, parameters: sort.parameters, scope: sort.scope, baseline: sort.baseline, comparedAgo: sort.comparedAgo,
                                      target: target, registry: registry, calendar: calendar)
                let resolved = try registry.resolve(ref, target: target)
                guard resolved.field.type != .tags else { throw QueryError.unsupported("sorting by a tag list") }
                guard let direction = QuerySortDirection(rawValue: sort.direction) else { throw QueryError.unsupported("sort direction “\(sort.direction)”") }
                spec.sorts.append(QuerySort(key: .field(ref), direction: direction))
            } catch {
                dropped.append(.init(what: "sort by “\(sort.field)”", reason: "\(error)"))
            }
        }

        // A request that asks for an order ("top", "most") always gets one: when the model gave none that survived,
        // most-played first, over the same period as its conditions.
        if ordered, spec.sorts.isEmpty, let plays = try? registry.field(defaultSortFieldID), plays.targets.contains(target) {
            var ref = QueryFieldRef(defaultSortFieldID)
            if plays.supportsScope, let scope = spec.groups.flatMap({ $0 }).compactMap({ condition -> QueryScope? in
                (try? registry.field(condition.field.id))?.comparesPeriods == true ? nil : condition.field.scope
            }).first { ref.scope = scope }
            spec.sorts.append(QuerySort(key: .field(ref), direction: .descending))
        }

        if let limit = count ?? query.limit {
            if limit >= 1 { spec.limit = limit } else { dropped.append(.init(what: "limit \(limit)", reason: "a limit below 1")) }
        }

        spec.playFilter = playFilter(query.playFilter, dropped: &dropped, knownCities: knownCities, knownRegions: knownRegions, knownCountries: knownCountries)

        spec.groupLimit = groupLimit(perArtist: query.perArtist, perAlbum: query.perAlbum, perReleaseYear: query.perReleaseYear, target: target, dropped: &dropped)

        spec.columns = columns(for: spec, target: target, registry: registry)
        let unsupported = (query.unsupported ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.contains { $0.isLetter || $0.isNumber } }
        return AskInterpretation(spec: spec, dropped: dropped, unsupported: unsupported)
    }

    /// The plays to count, as the model named them, kept only where the app would accept them: day names become weekday numbers, months
    /// must be 1–12, hours 0–23 and both given, weather and temperature names one of the app's own. Anything that doesn't fit is dropped
    /// and explained, never kept; what is left still applies.
    static func playFilter(
        _ wire: AskWire.PlayFilter?, dropped: inout [AskInterpretation.Dropped], knownCities: [String]? = nil, knownRegions: [String]? = nil, knownCountries: [String]? = nil
    ) -> QueryPlayFilter? {
        guard let wire, !wire.isEmpty else { return nil }
        var filter = QueryPlayFilter(weekdays: nil, fromHour: nil, toHour: nil)

        var weekdays: [Int] = []
        for name in wire.weekdays ?? [] {
            let lowered = name.lowercased()
            if let index = QueryPlayFilter.dayNames.firstIndex(where: { $0.lowercased() == lowered || (lowered.count >= 3 && $0.lowercased().hasPrefix(lowered)) }) {
                if !weekdays.contains(index) { weekdays.append(index) }
            } else {
                dropped.append(.init(what: "the day “\(name)”", reason: "not a day of the week"))
            }
        }
        if !weekdays.isEmpty { filter.weekdays = weekdays.sorted() }

        var months: [Int] = []
        for month in wire.months ?? [] {
            if (1...12).contains(month) { if !months.contains(month) { months.append(month) } }
            else { dropped.append(.init(what: "the month \(month)", reason: "months run from 1 (January) to 12 (December)")) }
        }
        if !months.isEmpty { filter.months = months.sorted() }

        switch (wire.fromHour, wire.toHour) {
        case (nil, nil): break
        case (let from?, let to?) where (0...23).contains(from) && (0...23).contains(to):
            filter.fromHour = from
            filter.toHour = to
        case (let from?, let to?):
            dropped.append(.init(what: "the hours \(from) to \(to)", reason: "hours run from 0 to 23"))
        default:
            dropped.append(.init(what: "an hour range", reason: "an hour range needs both a start and an end"))
        }

        var conditions: [String] = []
        for name in wire.weather ?? [] {
            if let condition = weatherCondition(named: name) { if !conditions.contains(condition.rawValue) { conditions.append(condition.rawValue) } }
            else { dropped.append(.init(what: "the weather “\(name)”", reason: "not Clear, Cloudy, Fog, Rain, Snow or Thunderstorm")) }
        }
        if !conditions.isEmpty { filter.weatherConditions = WeatherCondition.allCases.map(\.rawValue).filter(conditions.contains) }

        var bands: [String] = []
        for name in wire.temperature ?? [] {
            if let band = TemperatureBand.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) { if !bands.contains(band.rawValue) { bands.append(band.rawValue) } }
            else { dropped.append(.init(what: "the temperature “\(name)”", reason: "not Cold, Mild or Hot")) }
        }
        if !bands.isEmpty { filter.temperatureBands = TemperatureBand.allCases.map(\.rawValue).filter(bands.contains) }

        // Places: only where the person has been (home and trips), matched ignoring case and accents, and written the app's way. A name
        // written under the wrong kind (a country in the state list, a city in the country list) is still found, under the kind it is.
        // Lists the caller gave are used as they are (and the others are empty); with none given they come from the settings.
        let given = knownCities != nil || knownRegions != nil || knownCountries != nil
        let known = (
            cities: knownCities ?? (given ? [] : WeatherLocations.knownCities()), regions: knownRegions ?? (given ? [] : WeatherLocations.knownRegions()),
            countries: knownCountries ?? (given ? [] : WeatherLocations.knownCountries())
        )
        var cities: [String] = [], regions: [String] = [], countries: [String] = []
        func place(_ name: String, first: PlaceKind) {
            for kind in [first] + PlaceKind.allCases.filter({ $0 != first }) {
                switch kind {
                case .city:
                    if let city = WeatherLocations.match(name, in: known.cities) { if !cities.contains(city) { cities.append(city) }; return }
                case .region:
                    if let region = WeatherLocations.match(name, in: known.regions) { if !regions.contains(region) { regions.append(region) }; return }
                case .country:
                    if let country = WeatherLocations.matchCountry(name, in: known.countries) { if !countries.contains(country) { countries.append(country) }; return }
                }
            }
            let kindName = first == .city ? "city" : (first == .region ? "state or region" : "country")
            let list = first == .city ? known.cities : (first == .region ? known.regions : known.countries)
            let places = known.cities.isEmpty ? "no home place or trip is recorded (Tools › Trips)" : (list.isEmpty ? "none of your places has a \(kindName) recorded" : "yours are " + list.joined(separator: ", "))
            dropped.append(.init(what: "the \(kindName) “\(name)”", reason: "not somewhere you have listened (\(places))"))
        }
        for name in wire.city ?? [] { place(name, first: .city) }
        for name in wire.region ?? [] { place(name, first: .region) }
        for name in wire.country ?? [] { place(name, first: .country) }
        if !cities.isEmpty { filter.cities = cities }
        if !regions.isEmpty { filter.regions = regions }
        if !countries.isEmpty { filter.countries = countries }

        return filter.isEmpty ? nil : filter
    }

    private enum PlaceKind: CaseIterable { case city, region, country }

    /// A weather word as a person or a model might write it: the app's own names, plus the ones that mean the same.
    private static func weatherCondition(named name: String) -> WeatherCondition? {
        let lowered = name.lowercased()
        if let exact = WeatherCondition.allCases.first(where: { $0.rawValue.lowercased() == lowered }) { return exact }
        switch lowered {
        case "rainy", "raining", "rains", "drizzle", "showers", "wet": return .rain
        case "snowy", "snowing", "snows": return .snow
        case "storm", "storms", "stormy", "thunder", "thunderstorms": return .thunderstorm
        case "sunny", "sun", "sunshine", "fine": return .clear
        case "overcast", "cloud", "clouds", "grey", "gray": return .cloudy
        case "foggy", "mist", "misty": return .fog
        default: return nil
        }
    }

    /// The most results one cap may keep.
    static let maxCap = 20

    /// The diversity caps a request or model named, kept only where the registry itself would accept them (the same
    /// rules as `QuerySpec.validate`): per artist isn't meaningful for an artist query, per album only applies to a
    /// track query, per release year not to an artist query. One that doesn't fit is dropped and explained, never kept.
    static func groupLimit(perArtist: Int?, perAlbum: Int?, perReleaseYear: Int?, target: QueryTarget, dropped: inout [AskInterpretation.Dropped]) -> QueryGroupLimit? {
        var caps = QueryGroupLimit()
        func take(_ value: Int?, _ label: String, fits: Bool, why: String, into slot: WritableKeyPath<QueryGroupLimit, Int?>) {
            guard let value else { return }
            guard value >= 1 else { dropped.append(.init(what: "“\(value) \(label)”", reason: "a cap below 1")); return }
            guard fits else { dropped.append(.init(what: "“\(value) \(label)”", reason: why)); return }
            caps[keyPath: slot] = min(value, maxCap)
        }
        take(perArtist, "per artist", fits: target != .artist, why: "every result here is already one artist", into: \.perArtist)
        take(perAlbum, "per album", fits: target == .track, why: "only a track has a resolved album", into: \.perAlbum)
        take(perReleaseYear, "per release year", fits: target != .artist, why: "only an album or a track has a release year", into: \.perReleaseYear)
        return caps.isEmpty ? nil : caps
    }

    // MARK: - Conditions

    static func makeCondition(_ c: AskWire.Condition, target: QueryTarget, registry: QueryFieldRegistry, calendar: Calendar, knownTags: Set<String>? = nil) throws -> QueryCondition {
        let ref = try makeRef(id: c.field, parameters: c.parameters, scope: c.scope, baseline: c.baseline, comparedAgo: c.comparedAgo,
                              target: target, registry: registry, calendar: calendar)
        let resolved = try registry.resolve(ref, target: target)
        guard let op = QueryOperator(rawValue: c.op) else { throw QueryError.unsupported("operator “\(c.op)”") }
        var operands = try operands(for: op, c, field: resolved.field, calendar: calendar)
        // A tag condition may only name tags that exist in this library — a made-up tag would quietly match nothing.
        if let knownTags, case .tags(let names)? = operands.first {
            let real = names.filter { knownTags.contains($0) }
            guard !real.isEmpty else { throw QueryError.unsupported("no tag called " + names.map { "“\($0)”" }.joined(separator: ", ") + " in your library") }
            operands = [.tags(real)]
        }
        try QueryMatcher.validate(fieldID: resolved.field.id, fieldType: resolved.field.type, op: op, operands: operands)
        return QueryCondition(ref, op, operands)
    }

    private static func operands(for op: QueryOperator, _ c: AskWire.Condition, field: QueryField, calendar: Calendar) throws -> [QueryValue] {
        switch op.arity {
        case .none: return []
        case .oneOrMore:
            return [QueryValue.tags(normalizing: c.tags ?? [])]
        case .one, .two:
            switch op.operandType {
            case .numeric?:
                guard let value = c.value else { throw QueryError.unsupported("“\(op.rawValue)” needs a number") }
                try checkReasonable(value)
                var out: [QueryValue] = [.number(AskOperand.stored(value, for: field))]
                if op.arity == .two {
                    guard let to = c.valueTo else { throw QueryError.unsupported("“between” needs two numbers") }
                    try checkReasonable(to)
                    out.append(.number(AskOperand.stored(to, for: field)))
                }
                return out
            case .text?:
                guard let text = c.text else { throw QueryError.unsupported("“\(op.rawValue)” needs text") }
                // A field with a fixed set of values only compares with one of them, by “is” / “is not” — as its pick-list does.
                if let choices = field.choices {
                    guard op == .textIs || op == .textIsNot else { throw QueryError.unsupported("“\(field.name)” is compared with “is” or “is not”, not “\(op.rawValue)”") }
                    guard let value = choices.first(where: { $0.caseInsensitiveCompare(text.trimmingCharacters(in: .whitespaces)) == .orderedSame }) else {
                        throw QueryError.unsupported("“\(text)” isn’t a value of “\(field.name)” (\(choices.joined(separator: ", ")))")
                    }
                    return [.text(value)]
                }
                return [.text(text)]
            case .date?:
                guard let raw = c.date, let day = parseDay(raw, calendar: calendar) else { throw QueryError.unsupported("“\(op.rawValue)” needs a date (\(AskWire.dateFormat))") }
                var out: [QueryValue] = [.date(day)]
                if op.arity == .two {
                    guard let rawTo = c.dateTo, let dayTo = parseDay(rawTo, calendar: calendar) else { throw QueryError.unsupported("“dateBetween” needs two dates") }
                    out.append(.date(dayTo))
                }
                return out
            default:
                throw QueryError.unsupported("operator “\(op.rawValue)”")
            }
        }
    }

    /// The largest number a request can sensibly name. A model that writes 10^99 (the on-device one has) is guessing, not
    /// reading; the condition is left out rather than run.
    static let maxOperand = 1e9

    private static func checkReasonable(_ value: Double) throws {
        guard value.isFinite, abs(value) <= maxOperand else {
            throw QueryError.unsupported("\(value.isFinite ? String(format: "%.3g", value) : "that number") isn’t a number your request could mean")
        }
    }

    // MARK: - Field references, parameters, scopes

    static func makeRef(
        id: String, parameters: [String: String]?, scope: AskWire.Scope?, baseline: AskWire.Scope?, comparedAgo: AskWire.Shift? = nil,
        target: QueryTarget, registry: QueryFieldRegistry, calendar: Calendar
    ) throws -> QueryFieldRef {
        let field = try registry.field(id)
        var ref = QueryFieldRef(field.id)
        for (key, shown) in parameters ?? [:] {
            guard let parameter = field.parameters.first(where: { $0.id == key }) else {
                throw QueryError.unknownParameter(field: field.id, parameter: key)
            }
            guard let option = parameter.options.first(where: { parameter.display($0) == shown }) else {
                throw QueryError.invalidParameterValue(field: field.id, parameter: key)
            }
            ref.parameters[key] = option
        }
        // A period on a field that measures no period (a name, a total) is a blank the model filled in, not something the person
        // asked for; it is ignored rather than failing the whole condition.
        guard field.supportsScope else { return ref }
        if let scope { ref.scope = try makeScope(scope, calendar: calendar) }
        if let baseline {
            ref.baseline = try makeScope(baseline, calendar: calendar)
        } else if let comparedAgo, let scope = ref.scope {
            // The earlier period is the recent one moved back — which is what "vs. a year ago" means.
            guard comparedAgo.count >= 1, let unit = QueryScope.Unit(rawValue: comparedAgo.unit) else {
                throw QueryError.invalidScope("can’t compare with “\(comparedAgo.count) \(comparedAgo.unit)” earlier")
            }
            guard scope.canShift else { throw QueryError.invalidScope("“\(scope.label)” can’t be moved back to compare") }
            ref.baseline = scope.shifted(back: comparedAgo.count, unit)
        }
        return ref
    }

    static func makeScope(_ s: AskWire.Scope, calendar: Calendar) throws -> QueryScope {
        guard let kind = QueryScope.Kind(rawValue: s.kind) else { throw QueryError.invalidScope("unknown period kind “\(s.kind)”") }
        var scope = QueryScope(kind: kind)
        scope.days = s.days
        if let unit = s.unit {
            guard let parsed = QueryScope.Unit(rawValue: unit) else { throw QueryError.invalidScope("unknown unit “\(unit)”") }
            scope.unit = parsed
        }
        if kind == .absolute {
            // Whole days: the first instant of the "from" day through the last instant of the "to" day.
            scope.from = try s.from.map { try day($0, calendar: calendar) }
            scope.to = try s.to.map { raw in
                let start = try day(raw, calendar: calendar)
                return calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
            }
        }
        if let count = s.shiftCount, count != 0 {
            scope.shiftCount = count
            if let unit = s.shiftUnit {
                guard let parsed = QueryScope.Unit(rawValue: unit) else { throw QueryError.invalidScope("unknown unit “\(unit)”") }
                scope.shiftUnit = parsed
            }
        }
        try scope.validate()
        return scope
    }

    private static func day(_ raw: String, calendar: Calendar) throws -> Date {
        guard let date = parseDay(raw, calendar: calendar) else { throw QueryError.invalidScope("“\(raw)” isn’t a date (\(AskWire.dateFormat))") }
        return date
    }

    static func parseDay(_ raw: String, calendar: Calendar) -> Date? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "-").map { Int($0) }
        guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2] else { return nil }
        var components = DateComponents(); components.year = y; components.month = m; components.day = d
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == d, calendar.component(.month, from: date) == m else { return nil }
        return calendar.startOfDay(for: date)
    }

    // MARK: - Columns

    /// The fields the query sorts on, filters on, or groups by (a per-release-year cap) are shown, so the results explain
    /// themselves. Artist and album need no column: every row already shows them under its name.
    static func columns(for spec: QuerySpec, target: QueryTarget, registry: QueryFieldRegistry) -> [QueryFieldRef] {
        var refs: [QueryFieldRef] = []
        var seen = Set<String>()
        func add(_ ref: QueryFieldRef) {
            guard refs.count < maxColumns, let resolved = try? registry.resolve(ref, target: target),
                  resolved.field.id != "name", resolved.field.id != "artist" else { return }
            if seen.insert(resolved.cacheKey).inserted { refs.append(ref) }
        }
        for sort in spec.sorts { if case .field(let ref) = sort.key { add(ref) } }
        for group in spec.groups { for condition in group { add(condition.field) } }
        // A cap filters and sorts on nothing, but the result can't be read without the thing it groups by.
        if spec.groupLimit?.perReleaseYear != nil { add(QueryFieldRef("releaseYear")) }
        for id in baseColumns where refs.count < 3 { add(QueryFieldRef(id)) }
        return refs
    }
}
