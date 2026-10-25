import Foundation

/// Fields for a query that finds single plays (the Scrobbles target), where every row is one listen.
///
/// What describes WHEN and WHERE a play happened is read from the play itself: its time, the weather and the place at that moment come
/// from the same snapshot the play filter uses, so a row and a filter never disagree. The day of the week, part of the day and season
/// are the existing fields' own computation, shown under play-level names (an entity of one play: "the day most of its plays were on"
/// is the day of that play). What describes the track, album or artist behind the play is a separate step (phase 2).
extension QueryFieldRegistry {
    /// An existing field's computation for a play, under its own id and a help text that says it plainly.
    private static func perPlay(_ id: String, from base: String, name: String, help: String) -> QueryField {
        guard let source = coreFields.first(where: { $0.id == base }) else { preconditionFailure("no core field “\(base)” to show per play") }
        var field = QueryField(
            id: id, name: name, group: .scrobble, type: source.type, targets: [.scrobble], parameters: source.parameters, column: source.column,
            help: help, isBackgroundResolved: source.isBackgroundResolved, inputUnit: source.inputUnit, resolver: source.resolver, compute: source.compute
        )
        field.choices = source.choices
        field.askable = false
        field.askableByLargeModels = true
        return field
    }

    static func playField(
        id: String, name: String, type: QueryValueType, parameters: [QueryFieldParameter] = [], column: QueryColumnSpec? = nil, help: String,
        compute: @escaping @Sendable (QueryRun, [String: QueryValue], QueryEntity) -> QueryCell
    ) -> QueryField {
        var field = QueryField(
            id: id, name: name, group: .scrobble, type: type, targets: [.scrobble], parameters: parameters, column: column, help: help
        ) { run, parameters, entities in
            Dictionary(uniqueKeysWithValues: entities.map { ($0.id, compute(run, parameters, $0)) })
        }
        field.askable = false
        field.askableByLargeModels = true
        return field
    }

    /// Each play's time since the play before it in the whole library (not just the plays the query keeps), in seconds, and which time it is
    /// that this track has been played (1 = the first). One walk over the history, oldest first, built once per run.
    private static func playSequence(_ run: QueryRun) -> (gap: [QueryEntityID: Double], listenNumber: [QueryEntityID: Int]) {
        run.memoized("scrobbleSequence") {
            var gap: [QueryEntityID: Double] = [:]
            var number: [QueryEntityID: Int] = [:]
            var seen: [String: Int] = [:]
            var previous: Date?
            for play in run.allTimeScrobbles {
                guard let id = run.entityID(for: play) else { continue }
                if let previous { gap[id] = max(0, play.playedAt.timeIntervalSince(previous)) }
                previous = play.playedAt
                let key = play.artistName + "\u{0}" + play.trackName
                let nth = (seen[key] ?? 0) + 1
                seen[key] = nth
                number[id] = nth
            }
            return (gap, number)
        }
    }

    private static func playField(
        id: String, name: String, type: QueryValueType, column: QueryColumnSpec? = nil, help: String,
        compute: @escaping @Sendable (QueryRun, QueryEntity) -> QueryCell
    ) -> QueryField {
        playField(id: id, name: name, type: type, parameters: [], column: column, help: help) { run, _, entity in compute(run, entity) }
    }

    private static func time(_ entity: QueryEntity) -> Date { Date(timeIntervalSince1970: entity.id.at) }

    static let scrobbleFields: [QueryField] = [
        playField(
            id: "playedAt", name: "Played at", type: .date, column: .standard(for: .date, width: 170),
            help: "The date and time of the play, in your local time."
        ) { _, entity in .value(.date(time(entity))) },
        playField(
            id: "playAlbum", name: "Album", type: .text, column: .standard(for: .text, width: 180),
            help: "The album the play was scrobbled under. No value for a play with no album."
        ) { run, entity in
            let album = run.playByEntity[entity.id]?.albumName ?? ""
            return album.isEmpty ? .missing : .value(.text(album))
        },
        playField(
            id: "hourOfDay", name: "Hour of day", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 90),
            help: "The hour the play started in, 0 to 23, in your local time (0 is midnight to 1 AM, 23 is 11 PM to midnight)."
        ) { run, entity in .value(.number(Double(run.calendar.component(.hour, from: time(entity))))) },
        perPlay("playDayOfWeek", from: "dayOfWeek", name: "Day of week", help: "The day of the week of the play, in your local time."),
        perPlay("playTimeOfDay", from: "peakTimeOfDay", name: "Time of day", help: "The part of the day of the play: Night (9 PM–5 AM), Morning (5 AM–noon), Afternoon (noon–5 PM) or Evening (5–9 PM), in your local time."),
        perPlay("playWeekdayOrWeekend", from: "weekdayOrWeekend", name: "Weekday / weekend", help: "Whether the play was on a weekday or a weekend, in your local time."),
        perPlay("playSeason", from: "peakSeason", name: "Season", help: "The season of the play, as whole calendar months for the hemisphere chosen in Settings › General."),
        playField(
            id: "playGap", name: "Since the previous play", type: .numeric,
            column: .standard(for: .numeric, style: .listeningTime, width: 130),
            help: "How long after the play before it this one started: the time between the two starts, whatever they were (a gap of a few minutes is the same listening session; a gap of hours or days is a new one). No value for your very first play."
        ) { run, entity in
            playSequence(run).gap[entity.id].map { .value(.number($0)) } ?? .missing
        },
        playField(
            id: "listenNumber", name: "Listen # of this track", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 110),
            help: "Which time you have played this track: 1 is the first time ever, 12 the twelfth. Counted over your whole history, not just the plays the query keeps."
        ) { run, entity in
            playSequence(run).listenNumber[entity.id].map { .value(.number(Double($0))) } ?? .missing
        },
        playField(
            id: "firstListen", name: "First time played", type: .boolean,
            help: "True when this is the first time you ever played the track, over your whole history."
        ) { run, entity in
            playSequence(run).listenNumber[entity.id].map { .value(.bool($0 == 1)) } ?? .missing
        },
        playField(
            id: "scrobbleCity", name: "City", type: .text, column: .standard(for: .text, width: 130),
            help: "The city you were in: the trip you were on, or your home place (“Home” when none is chosen). No value when no home place or trip is recorded. See Tools › Trips."
        ) { run, entity in
            run.snapshots.weather.city(at: time(entity)).map { .value(.text($0)) } ?? .missing
        },
        playField(
            id: "scrobbleRegion", name: "State / region", type: .text, column: .standard(for: .text, width: 130),
            help: "The state or region you were in, where the place is known to be in one (a place chosen from the city search records it; a typed name or coordinates have none)."
        ) { run, entity in
            run.snapshots.weather.regionAndCountry(at: time(entity)).region.map { .value(.text($0)) } ?? .missing
        },
        playField(
            id: "scrobbleCountry", name: "Country", type: .text, column: .standard(for: .text, width: 130),
            help: "The country you were in, where the place is known to be in one (a place chosen from the city search records it; a typed name or coordinates have none)."
        ) { run, entity in
            run.snapshots.weather.regionAndCountry(at: time(entity)).country.map { .value(.text($0)) } ?? .missing
        },
        playField(
            id: "playWeather", name: "Weather", type: .text, column: .standard(for: .text, width: 110),
            help: "The weather in the hour of the play, where you were (home, or the trip). Needs weather turned on in Settings › Weather and downloaded."
        ) { run, entity in
            run.snapshots.weather.sample(at: time(entity))?.condition.map { .value(.text($0.rawValue)) } ?? .missing
        },
        playField(
            id: "playTemperature", name: "Temperature", type: .numeric, column: .standard(for: .numeric, style: .temperature, width: 100),
            help: "The temperature in the hour of the play, where you were, in the unit chosen in Settings › Weather. Needs weather turned on and downloaded."
        ) { run, entity in
            run.snapshots.weather.sample(at: time(entity))?.temperature.map { .value(.number(run.snapshots.weather.unit.fromCelsius($0))) } ?? .missing
        },
    ]
}
