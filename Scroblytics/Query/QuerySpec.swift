import Foundation

/// One leaf: a field (with parameters), an operator, and its operand(s).
struct QueryCondition: Codable, Hashable, Sendable {
    var field: QueryFieldRef
    var op: QueryOperator
    var operands: [QueryValue]

    init(_ field: QueryFieldRef, _ op: QueryOperator, _ operands: [QueryValue] = []) {
        self.field = field
        self.op = op
        self.operands = operands
    }

    init(_ fieldID: String, _ op: QueryOperator, _ operands: [QueryValue] = []) {
        self.init(QueryFieldRef(fieldID), op, operands)
    }
}

enum QuerySortDirection: String, Codable, Sendable { case ascending, descending }

/// What to order by: a registry field, or a random shuffle (a real saved query
/// — "One ‘random’ song" — is exactly `shuffle` + limit 1). A nil seed means a
/// fresh shuffle every run.
enum QuerySortKey: Codable, Hashable, Sendable {
    case field(QueryFieldRef)
    case shuffle(seed: UInt64?)
}

struct QuerySort: Codable, Hashable, Sendable {
    var key: QuerySortKey
    var direction: QuerySortDirection = .descending
}

/// Which scrobbles count at all: plays outside [from, to] are ignored before
/// anything is aggregated ("Played Today" is this, not a
/// condition). Distinct from `asOf`, which only sets "now" for relative fields.
struct QueryPeriod: Codable, Hashable, Sendable {
    var from: Date
    var to: Date
}

/// Which plays count by WHEN in the week and day they happened (local time): only some weekdays, and / or only
/// some hours. Like `QueryPeriod` it is applied to the plays before anything is aggregated — so "Sunday mornings"
/// means the plays made then, not items whose most common time was then.
extension QuerySpec {
    /// How many plays a query that lists single plays shows to begin with (the other targets show a hundred).
    static let scrobbleLimit = 1000
}

struct QueryPlayFilter: Codable, Hashable, Sendable {
    /// 0 = Sunday … 6 = Saturday (the same numbering as the heatmap). nil = every day.
    var weekdays: [Int]?
    /// Whole hours, 0–23, inclusive at both ends. `fromHour > toHour` wraps midnight (21 → 5 is 9 PM through 5 AM).
    /// nil = every hour.
    var fromHour: Int?
    var toHour: Int?
    /// Calendar months, 1 = January … 12 = December, of any year ("winter" is 12, 1, 2). nil or empty = every month. Optional, and last, so
    /// sets saved before it existed decode unchanged.
    var months: [Int]?
    /// Only plays made in one of these kinds of weather (`WeatherCondition` names: "Rain", "Snow"…), at the home place's weather for the hour
    /// of the play. nil or empty = any weather.
    var weatherConditions: [String]?
    /// Only plays made when it was one of these for the place (`TemperatureBand` names: "Cold", "Mild", "Hot"). Combined with
    /// `weatherConditions` as "and": cold rain or cold snow.
    var temperatureBands: [String]?
    /// Only plays made when the temperature was at least `temperatureFrom` and below `temperatureTo` (°C, either may be left out). What
    /// a Trends weather cell opens: its own range of temperatures, which the three bands can't say. Not in the builder's chips.
    var temperatureFrom: Double?
    var temperatureTo: Double?
    /// Only plays made in one of these cities (the home place's or a trip's short name, "Seattle", "Munich"), wherever the person was at the
    /// time of the play. nil or empty = anywhere. Optional, and last, so sets saved before it existed decode unchanged.
    var cities: [String]?
    /// Only plays made in one of these states or regions ("Illinois", "Bavaria"), or countries ("Germany"), as the home place or the trip
    /// you were on knew them when it was chosen. Each list is "any of", and the lists (with the cities) must all hold. Optional, and last,
    /// so sets saved before they existed decode unchanged.
    var regions: [String]?
    var countries: [String]?

    var isEmpty: Bool { (weekdays ?? []).isEmpty && fromHour == nil && toHour == nil && (months ?? []).isEmpty && !usesWeather && !usesPlace }

    /// Whether the filter looks at a city.
    var usesCity: Bool { !(cities ?? []).isEmpty }

    /// Whether the filter looks at where the play was made (a city, state or region, or country), so counting plays needs the home place
    /// and trips.
    var usesPlace: Bool { usesCity || !(regions ?? []).isEmpty || !(countries ?? []).isEmpty }

    /// Whether the filter looks at the weather, so counting plays needs it.
    var usesWeather: Bool { !(weatherConditions ?? []).isEmpty || !(temperatureBands ?? []).isEmpty || temperatureFrom != nil || temperatureTo != nil }

    /// Whether a play at `date` passes. A weather filter needs the weather for that hour: with none (weather off, not downloaded, or an
    /// hour before the downloaded years) the play does not match, rather than being counted as if it did.
    func matches(_ date: Date, calendar: Calendar = AppCalendars.listening, weather: WeatherSnapshot = .empty) -> Bool {
        if let weekdays, !weekdays.isEmpty, !weekdays.contains(calendar.component(.weekday, from: date) - 1) { return false }
        if let months, !months.isEmpty, !months.contains(calendar.component(.month, from: date)) { return false }
        if let cities, !cities.isEmpty {
            guard let city = weather.city(at: date) else { return false }
            let key = PlaceNames.key(city)
            guard cities.contains(where: { PlaceNames.key($0) == key }) else { return false }
        }
        if let regions, !regions.isEmpty {
            guard let region = weather.regionAndCountry(at: date).region else { return false }
            let key = PlaceNames.key(region)
            guard regions.contains(where: { PlaceNames.key($0) == key }) else { return false }
        }
        if let countries, !countries.isEmpty {
            guard let country = weather.regionAndCountry(at: date).country else { return false }
            let key = PlaceNames.key(country)
            guard countries.contains(where: { PlaceNames.key($0) == key }) else { return false }
        }
        if usesWeather {
            guard let sample = weather.sample(at: date) else { return false }
            if let conditions = weatherConditions, !conditions.isEmpty {
                guard let condition = sample.condition, conditions.contains(condition.rawValue) else { return false }
            }
            if let bands = temperatureBands, !bands.isEmpty {
                guard let band = weather.band(for: sample), bands.contains(band.rawValue) else { return false }
            }
            if temperatureFrom != nil || temperatureTo != nil {
                guard let temperature = sample.temperature else { return false }
                if let temperatureFrom, temperature < temperatureFrom { return false }
                if let temperatureTo, temperature >= temperatureTo { return false }
            }
        }
        if let from = fromHour, let to = toHour {
            let hour = calendar.component(.hour, from: date)
            return from <= to ? (hour >= from && hour <= to) : (hour >= from || hour <= to)
        }
        return true
    }

    func validate() throws {
        if let weekdays, weekdays.contains(where: { !(0...6).contains($0) }) { throw QueryError.unsupported("a weekday outside Sunday–Saturday") }
        if let months, months.contains(where: { !(1...12).contains($0) }) { throw QueryError.unsupported("a month outside January–December") }
        if let weatherConditions, weatherConditions.contains(where: { WeatherCondition(rawValue: $0) == nil }) { throw QueryError.unsupported("a kind of weather that isn’t Clear, Cloudy, Fog, Rain, Snow or Thunderstorm") }
        if let temperatureBands, temperatureBands.contains(where: { TemperatureBand(rawValue: $0) == nil }) { throw QueryError.unsupported("a temperature band that isn’t Cold, Mild or Hot") }
        if let temperatureFrom, !temperatureFrom.isFinite { throw QueryError.unsupported("a temperature that isn’t a number") }
        if let temperatureTo, !temperatureTo.isFinite { throw QueryError.unsupported("a temperature that isn’t a number") }
        if let temperatureFrom, let temperatureTo, temperatureFrom >= temperatureTo { throw QueryError.unsupported("a temperature range that ends before it starts") }
        if let cities, cities.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { throw QueryError.unsupported("a city with no name") }
        if let regions, regions.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { throw QueryError.unsupported("a state or region with no name") }
        if let countries, countries.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { throw QueryError.unsupported("a country with no name") }
        if (fromHour == nil) != (toHour == nil) { throw QueryError.unsupported("an hour range needs both a start and an end") }
        if let fromHour, let toHour, !(0...23).contains(fromHour) || !(0...23).contains(toHour) { throw QueryError.unsupported("hours run from 0 to 23") }
    }

    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func hourLabel(_ hour: Int) -> String {
        hour == 0 ? "12 AM" : hour == 12 ? "12 PM" : hour < 12 ? "\(hour) AM" : "\(hour - 12) PM"
    }

    /// "Sunday, Saturday, Winter, 5 AM–11 AM" — how the filter reads in the builder and in chips. Three months that make up a season read as
    /// the season's name (in the hemisphere chosen in Settings).
    func label(hemisphere: Hemisphere = SeasonSettings.hemisphere) -> String {
        var parts: [String] = []
        if let weekdays, !weekdays.isEmpty {
            parts.append(weekdays.sorted().map { Self.dayNames[$0] }.joined(separator: ", "))
        }
        if let months, !months.isEmpty {
            if let season = Season.matching(months: months, in: hemisphere) {
                parts.append("\(season.label) (\(season.rangeLabel(in: hemisphere)))")
            } else {
                parts.append(Set(months).sorted().map { MonthNames.short[$0 - 1] }.joined(separator: ", "))
            }
        }
        if let fromHour, let toHour {
            parts.append(fromHour == toHour ? Self.hourLabel(fromHour) : "\(Self.hourLabel(fromHour))–\(Self.hourLabel(toHour))")
        }
        if let cities, !cities.isEmpty {
            parts.append("in " + cities.joined(separator: " or "))
        }
        if let regions, !regions.isEmpty {
            parts.append("in " + regions.joined(separator: " or "))
        }
        if let countries, !countries.isEmpty {
            parts.append("in " + countries.joined(separator: " or "))
        }
        if let conditions = weatherConditions, !conditions.isEmpty {
            let ordered = WeatherCondition.allCases.map(\.rawValue).filter(conditions.contains).map { $0.lowercased() }
            parts.append("in " + ordered.joined(separator: " or "))
        }
        if let bands = temperatureBands, !bands.isEmpty {
            let ordered = TemperatureBand.allCases.map(\.rawValue).filter(bands.contains).map { $0.lowercased() }
            parts.append("when " + ordered.joined(separator: " or "))
        }
        if temperatureFrom != nil || temperatureTo != nil {
            let unit = WeatherSettings.temperatureUnit()
            switch (temperatureFrom, temperatureTo) {
            case (let from?, let to?): parts.append("from \(unit.text(celsius: from)) to \(unit.text(celsius: to))")
            case (let from?, nil): parts.append("at \(unit.text(celsius: from)) or warmer")
            case (nil, let to?): parts.append("below \(unit.text(celsius: to))")
            case (nil, nil): break
            }
        }
        return parts.joined(separator: ", ")
    }

    var label: String { label() }
}

/// "For each calendar year": the query is evaluated separately over each year's plays. (One kind of period for now; the struct leaves room
/// for months or decades.)
struct QueryBreakdown: Codable, Hashable, Sendable {
    /// Newest year first. Nil/false: oldest first.
    var newestFirst: Bool?

    var showsNewestFirst: Bool { newestFirst == true }
}

/// Diversity caps: at most `perArtist` results may share the same artist, at most `perAlbum` results may
/// share the same album and/or at most `perReleaseYear` results may share the same release year,
/// simultaneously — applied after sorting, before the overall `limit` (`QueryEngine.applyGroupLimit`).
/// `perArtist` doesn't apply to an artist-target query (every row is already one artist); `perAlbum` only
/// ever applies to a track-target query (only a track carries a resolved album); `perReleaseYear` applies
/// to album and track queries (the Release year field exists only for those) — `validate()` rejects any
/// of them being set where it doesn't apply, rather than silently ignoring it.
struct QueryGroupLimit: Codable, Hashable, Sendable {
    var perArtist: Int?
    var perAlbum: Int?
    /// Optional, so a query saved before this cap existed decodes unchanged.
    var perReleaseYear: Int?

    var isEmpty: Bool { perArtist == nil && perAlbum == nil && perReleaseYear == nil }
}

/// A complete query, and the unit that gets saved. Boolean logic is DNF: the
/// query matches an entity when `groups` is empty, or when ANY group has ALL of
/// its conditions true (AND within a group, OR across groups).
struct QuerySpec: Codable, Hashable, Sendable {
    /// 2: a field reference may carry a date `scope`. 3: it may also carry a comparison `baseline`.
    /// Older sets decode unchanged (both are optional).
    /// 4: a `playFilter` (only plays on some weekdays / hours). Older sets decode unchanged.
    /// 5: `resultSorts` / `showInRankOrder` (the order the results are shown in, apart from the order that picks them) and `breakdown` (one
    /// evaluation per calendar year). Older sets decode unchanged.
    /// 6: a `playFilter` may also name calendar months (seasons). 7: it may also name kinds of weather and temperature bands. 8: and a range of
    /// temperatures. 9: and cities. 10: and states or regions and countries. Older sets decode unchanged.
    static let currentSchemaVersion = 10

    var schemaVersion: Int = QuerySpec.currentSchemaVersion
    var target: QueryTarget
    var period: QueryPeriod?
    /// Only plays on some weekdays / at some hours count (in addition to `period`).
    var playFilter: QueryPlayFilter?
    /// nil = "now" when the query runs.
    var asOf: Date?
    var groups: [[QueryCondition]] = []
    /// Applied in order; entities with no value for a sort field always sort
    /// last regardless of direction.
    var sorts: [QuerySort] = []
    var limit: Int?
    /// Ordered columns to display. Empty = the surface's default columns.
    var columns: [QueryFieldRef] = []
    var groupLimit: QueryGroupLimit?
    /// The order the surviving results are shown in, applied after the caps and the limit; `sorts` still decides which results survive.
    /// Empty/nil = automatic: the sorts' own order, except that a per-release-year cap shows its results by release year, oldest first.
    /// Optional, so a query saved before this existed decodes unchanged.
    var resultSorts: [QuerySort]?
    /// Keeps the sorts' own order even where the automatic order would be by release year (a per-release-year cap).
    var showInRankOrder: Bool?
    /// Runs the query once for each calendar year of the plays it counts, keeping `limit` results per year ("my top 3 artists of each
    /// year"). Each row is then an artist, album or track in a year, with that year's plays. Optional, so older queries decode unchanged.
    var breakdown: QueryBreakdown?

    init(target: QueryTarget) { self.target = target }
}

// MARK: - Persistence

extension QuerySpec {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    func encoded() throws -> Data { try Self.encoder().encode(self) }

    /// Refuses a spec written by a NEWER schema than this build understands,
    /// rather than decoding it into something subtly wrong.
    static func decode(_ data: Data) throws -> QuerySpec {
        let spec = try decoder().decode(QuerySpec.self, from: data)
        guard spec.schemaVersion <= currentSchemaVersion else {
            throw QueryError.unsupported("a saved set from a newer version (schema \(spec.schemaVersion))")
        }
        return spec
    }
}

// MARK: - Validation

/// A spec whose every reference has been checked against the registry.
struct ValidatedQuery: Sendable {
    let spec: QuerySpec
    let groups: [[ValidatedCondition]]
    let sorts: [ValidatedSort]
    /// The explicitly chosen display order (see `QuerySpec.resultSorts`).
    var resultSorts: [ValidatedSort] = []
    let columns: [ResolvedField]
    /// The Release year field, resolved once when the spec sets a per-release-year cap (nil otherwise).
    let releaseYearField: ResolvedField?
}

extension ValidatedQuery {
    /// The order the results are shown in once the caps and the limit have picked them: the one chosen, else (with a per-release-year cap)
    /// release year, oldest first, else none (the order they were picked in).
    var effectiveResultSorts: [ValidatedSort] {
        if !resultSorts.isEmpty { return resultSorts }
        if spec.groupLimit?.perReleaseYear != nil, spec.showInRankOrder != true, let year = releaseYearField {
            return [ValidatedSort(key: .field(year), direction: .ascending)]
        }
        return []
    }
}

struct ValidatedCondition: Sendable {
    let field: ResolvedField
    let op: QueryOperator
    let operands: [QueryValue]
}

struct ValidatedSort: Sendable {
    enum Key: Sendable {
        case field(ResolvedField)
        case shuffle(seed: UInt64?)
    }
    let key: Key
    let direction: QuerySortDirection
}

extension QuerySpec {
    /// Checks every field/operator/operand/parameter and throws the first
    /// problem — nothing is skipped or coerced.
    func validate(against registry: QueryFieldRegistry) throws -> ValidatedQuery {
        if let period, period.from > period.to { throw QueryError.rangeOutOfOrder }
        try playFilter?.validate()
        if let limit, limit < 1 { throw QueryError.unsupported("a limit below 1") }
        if let perArtist = groupLimit?.perArtist {
            guard perArtist >= 1 else { throw QueryError.unsupported("a per-artist cap below 1") }
            guard target != .artist else { throw QueryError.unsupported("a per-artist cap on an artist query — every row is already one artist") }
        }
        if let perAlbum = groupLimit?.perAlbum {
            guard perAlbum >= 1 else { throw QueryError.unsupported("a per-album cap below 1") }
            guard target == .track else { throw QueryError.unsupported("a per-album cap on an \(target.rawValue) query — only a track carries a resolved album") }
        }
        var releaseYearField: ResolvedField?
        if let perReleaseYear = groupLimit?.perReleaseYear {
            guard perReleaseYear >= 1 else { throw QueryError.unsupported("a per-release-year cap below 1") }
            guard target == .album || target == .track else { throw QueryError.unsupported("a per-release-year cap on \(target == .artist ? "an artist" : "a scrobble") query — only albums and tracks have a release year") }
            releaseYearField = try registry.resolve(QueryFieldRef("releaseYear"), target: target)
        }

        var validatedGroups: [[ValidatedCondition]] = []
        for group in groups {
            var validated: [ValidatedCondition] = []
            for condition in group {
                let resolved = try registry.resolve(condition.field, target: target)
                try QueryMatcher.validate(
                    fieldID: resolved.field.id, fieldType: resolved.field.type,
                    op: condition.op, operands: condition.operands
                )
                validated.append(ValidatedCondition(field: resolved, op: condition.op, operands: condition.operands))
            }
            validatedGroups.append(validated)
        }

        func validateSort(_ sort: QuerySort) throws -> ValidatedSort {
            switch sort.key {
            case .shuffle(let seed):
                return ValidatedSort(key: .shuffle(seed: seed), direction: sort.direction)
            case .field(let ref):
                let resolved = try registry.resolve(ref, target: target)
                guard resolved.field.type != .tags else { throw QueryError.unsupported("sorting by a tag list (“\(resolved.field.name)”)") }
                return ValidatedSort(key: .field(resolved), direction: sort.direction)
            }
        }
        let validatedSorts = try sorts.map(validateSort)
        let validatedResultSorts = try (resultSorts ?? []).map(validateSort)

        let resolvedColumns = try columns.map { try registry.resolve($0, target: target) }
        return ValidatedQuery(
            spec: self, groups: validatedGroups, sorts: validatedSorts, resultSorts: validatedResultSorts, columns: resolvedColumns,
            releaseYearField: releaseYearField
        )
    }
}


extension QuerySpec {
    /// The plays this query counts: those inside its `period` and matching its `playFilter`.
    func countedPlays(_ scrobbles: [ScrobbleSnapshot], weather: WeatherSnapshot = .empty) -> [ScrobbleSnapshot] {
        let filter = (playFilter?.isEmpty ?? true) ? nil : playFilter
        guard period != nil || filter != nil else { return scrobbles }
        let calendar = AppCalendars.listening
        return scrobbles.filter { s in
            if let period, s.playedAt < period.from || s.playedAt > period.to { return false }
            return filter?.matches(s.playedAt, calendar: calendar, weather: weather) ?? true
        }
    }
}
