import Foundation

/// Fields for a query that finds listening sessions: each row is one session of the history, which is a run of plays each started within
/// the query's gap (30 minutes to begin with) of the one before. A period or a play filter picks sessions by where they started: a session
/// is counted when its first play is among the plays the query keeps; the whole session is then measured, all of its plays.
extension QueryFieldRegistry {
    private static let dayNames = QueryPlayFilter.dayNames

    /// Each session of the run by its start, with the session before it, built once.
    private static func sessionLookup(_ run: QueryRun) -> (byStart: [Double: ListeningSession], previousEnd: [Double: Double]) {
        run.memoized("sessionLookup") {
            var byStart: [Double: ListeningSession] = [:]
            var previousEnd: [Double: Double] = [:]
            var previous: ListeningSession?
            for session in sessionList(run, gapMinutes: run.sessionGapMinutes) {
                byStart[session.start] = session
                if let previous { previousEnd[session.start] = previous.end }
                previous = session
            }
            return (byStart, previousEnd)
        }
    }

    private static func sessionField(
        id: String, name: String, type: QueryValueType, column: QueryColumnSpec? = nil, choices: [String]? = nil, help: String,
        value: @escaping @Sendable (QueryRun, ListeningSession, Double) -> QueryValue?
    ) -> QueryField {
        var field = QueryField(id: id, name: name, group: .session, type: type, targets: [.session], column: column, help: help) { run, _, entities in
            let lookup = sessionLookup(run)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                let cell: QueryCell = lookup.byStart[entity.id.at].flatMap { value(run, $0, entity.id.at) }.map { .value($0) } ?? .missing
                return (entity.id, cell)
            })
        }
        field.choices = choices
        field.askable = false
        field.askableByLargeModels = true
        return field
    }

    private static func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    static let sessionFields: [QueryField] = [
        sessionField(
            id: "sessionBegan", name: "Started", type: .date, column: .standard(for: .date, width: 170),
            help: "When the session began: the start of its first play, in your local time."
        ) { _, session, _ in .date(time(session.start)) },
        sessionField(
            id: "sessionEnded", name: "Last play started", type: .date, column: .standard(for: .date, width: 170),
            help: "When the last play of the session began (a scrobble records only when a play began, so this is not when the last song finished)."
        ) { _, session, _ in .date(time(session.end)) },
        sessionField(
            id: "sessionDuration", name: "Length", type: .numeric, column: .standard(for: .numeric, style: .listeningTime, width: 130),
            help: "How long the session lasted, from the start of its first play to the start of its last (0 for a session of one play). It does not include the length of the last song."
        ) { _, session, _ in .number(session.end - session.start) },
        sessionField(
            id: "sessionPlays", name: "Plays", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 80),
            help: "How many plays the session has, counting every play of it."
        ) { _, session, _ in .number(Double(session.size)) },
        sessionField(
            id: "sessionDistinctArtists", name: "Artists", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 80),
            help: "How many different artists the session has."
        ) { _, session, _ in .number(Double(session.artists)) },
        sessionField(
            id: "sessionDistinctSongs", name: "Different songs", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 110),
            help: "How many different songs (an artist and a title) the session has: fewer than its plays when something was played more than once."
        ) { _, session, _ in .number(Double(session.tracks)) },
        sessionField(
            id: "sessionTopArtist", name: "Most played artist", type: .text, column: .standard(for: .text, width: 170),
            help: "The artist with the most plays in the session (the first alphabetically on a tie)."
        ) { _, session, _ in .text(session.topArtist) },
        sessionField(
            id: "sessionTopArtistShare", name: "Share of the most played artist", type: .numeric, column: .standard(for: .numeric, style: .percent, width: 130),
            help: "The most played artist's share of the session's plays, as a percentage. 100% means the whole session was one artist; type a condition as a fraction (0.5 for half)."
        ) { _, session, _ in .number(Double(session.topArtistPlays) / Double(max(1, session.size))) },
        sessionField(
            id: "sessionOpening", name: "Opening song", type: .text, column: .standard(for: .text, width: 220),
            help: "The song the session began with, as “Artist – Title”."
        ) { run, session, _ in
            let play = run.allTimeScrobbles[session.first]
            return .text(play.artistName + " – " + play.trackName)
        },
        sessionField(
            id: "sessionClosing", name: "Closing song", type: .text, column: .standard(for: .text, width: 220),
            help: "The last song of the session, as “Artist – Title”: what you were listening to when you stopped."
        ) { run, session, _ in
            let play = run.allTimeScrobbles[session.last]
            return .text(play.artistName + " – " + play.trackName)
        },
        sessionField(
            id: "sessionWeekday", name: "Day of week started", type: .text, column: .standard(for: .text, width: 120), choices: dayNames,
            help: "The day of the week the session began on, in your local time."
        ) { run, session, _ in .text(dayNames[run.calendar.component(.weekday, from: time(session.start)) - 1]) },
        sessionField(
            id: "sessionHour", name: "Hour started", type: .numeric, column: .standard(for: .numeric, style: .integer, width: 90),
            help: "The hour the session began in, 0 to 23, in your local time (0 is midnight to 1 AM, 23 is 11 PM to midnight)."
        ) { run, session, _ in .number(Double(run.calendar.component(.hour, from: time(session.start)))) },
        sessionField(
            id: "sessionGapBefore", name: "Since the previous session", type: .numeric, column: .standard(for: .numeric, style: .listeningTime, width: 140),
            help: "How long after the last play of the session before it this one began. No value for your very first session."
        ) { run, session, start in sessionLookup(run).previousEnd[start].map { .number(session.start - $0) } },
        sessionField(
            id: "sessionCity", name: "City", type: .text, column: .standard(for: .text, width: 130),
            help: "The city you were in when the session began: the trip you were on, or your home place (“Home” when none is chosen). See Tools › Trips."
        ) { run, session, _ in run.snapshots.weather.city(at: time(session.start)).map { .text($0) } },
        sessionField(
            id: "sessionRegion", name: "State / region", type: .text, column: .standard(for: .text, width: 130),
            help: "The state or region you were in when the session began, where the place is known to be in one (a place chosen from the city search records it)."
        ) { run, session, _ in run.snapshots.weather.regionAndCountry(at: time(session.start)).region.map { .text($0) } },
        sessionField(
            id: "sessionCountry", name: "Country", type: .text, column: .standard(for: .text, width: 130),
            help: "The country you were in when the session began, where the place is known to be in one (a place chosen from the city search records it)."
        ) { run, session, _ in run.snapshots.weather.regionAndCountry(at: time(session.start)).country.map { .text($0) } },
        sessionField(
            id: "sessionWeather", name: "Weather when it began", type: .text, column: .standard(for: .text, width: 140),
            help: "The weather in the hour the session began, where you were. Needs weather turned on in Settings › Weather and downloaded."
        ) { run, session, _ in run.snapshots.weather.sample(at: time(session.start))?.condition.map { .text($0.rawValue) } },
        sessionField(
            id: "sessionTemperature", name: "Temperature when it began", type: .numeric, column: .standard(for: .numeric, style: .temperature, width: 140),
            help: "The temperature in the hour the session began, where you were, in the unit chosen in Settings › Weather. Needs weather turned on and downloaded."
        ) { run, session, _ in
            run.snapshots.weather.sample(at: time(session.start))?.temperature.map { .number(run.snapshots.weather.unit.fromCelsius($0)) }
        },
    ]
}
