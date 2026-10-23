import Foundation

/// The weather at the time of each play, from the weather downloaded for the person's home place (Settings › Weather). An item's value
/// is built from its plays that have weather, in the query's period or the column's own date scope; an item none of whose plays have
/// weather has no value, as does everything while weather is off or not downloaded yet.
extension QueryFieldRegistry {
    /// One item's plays, sorted into weather: how many had a known condition / temperature band, and which.
    struct WeatherTally: Sendable {
        var temperatureCount = 0
        var temperatureSum = 0.0
        var conditionKnown = 0
        var conditions = [Int](repeating: 0, count: WeatherCondition.allCases.count)
        var bandKnown = 0
        var bands = [Int](repeating: 0, count: TemperatureBand.allCases.count)

        mutating func add(_ sample: WeatherSample, band: TemperatureBand?) {
            if let temperature = sample.temperature { temperatureCount += 1; temperatureSum += temperature }
            if let condition = sample.condition, let index = WeatherCondition.allCases.firstIndex(of: condition) { conditionKnown += 1; conditions[index] += 1 }
            if let band, let index = TemperatureBand.allCases.firstIndex(of: band) { bandKnown += 1; bands[index] += 1 }
        }

        /// The share of plays in one weather ("Rain", "Hot"…), among the plays that have that kind of information.
        func share(of weather: String) -> Double? {
            if let index = WeatherCondition.allCases.firstIndex(where: { $0.rawValue == weather }) {
                return conditionKnown == 0 ? nil : Double(conditions[index]) / Double(conditionKnown)
            }
            if let index = TemperatureBand.allCases.firstIndex(where: { $0.rawValue == weather }) {
                return bandKnown == 0 ? nil : Double(bands[index]) / Double(bandKnown)
            }
            return nil
        }
    }

    /// Every play's weather, tallied per item and for all the plays in the same scope (the baseline a "lift" compares with).
    static func weatherTallies(_ run: QueryRun, scope: QueryScope?) -> (perEntity: [QueryEntityID: WeatherTally], all: WeatherTally) {
        run.memoized("weatherTallies.\(scope?.cacheKey ?? "-")") {
            let weather = run.snapshots.weather
            guard !weather.isEmpty else { return ([:], WeatherTally()) }
            var perEntity: [QueryEntityID: WeatherTally] = [:]
            var all = WeatherTally()
            for (id, scrobbles) in run.scopedScrobblesByEntity(scope) {
                var tally = WeatherTally()
                for scrobble in scrobbles {
                    guard let sample = weather.sample(at: scrobble.playedAt) else { continue }
                    let band = weather.band(for: sample)
                    tally.add(sample, band: band)
                    all.add(sample, band: band)
                }
                perEntity[id] = tally
            }
            return (perEntity, all)
        }
    }

    /// Every play's city, tallied per item: how many of its plays were made in each city (from the settings alone, so a trip's plays count
    /// whether or not its weather has been downloaded).
    static func cityTallies(_ run: QueryRun, scope: QueryScope?) -> [QueryEntityID: [String: Int]] {
        run.memoized("cityTallies.\(scope?.cacheKey ?? "-")") {
            let weather = run.snapshots.weather
            guard !weather.isEmpty else { return [:] }
            var perEntity: [QueryEntityID: [String: Int]] = [:]
            for (id, scrobbles) in run.scopedScrobblesByEntity(scope) {
                var counts: [String: Int] = [:]
                for scrobble in scrobbles {
                    guard let city = weather.city(at: scrobble.playedAt) else { continue }
                    counts[city, default: 0] += 1
                }
                perEntity[id] = counts
            }
            return perEntity
        }
    }

    private static let weatherChoices = (WeatherCondition.allCases.map(\.rawValue) + TemperatureBand.allCases.map(\.rawValue))

    private static let weatherParameter = QueryFieldParameter(
        id: "weather", label: "Weather", options: weatherChoices.map { .text($0) }, defaultValue: .text("Rain"), showsDefaultInTitle: true,
        help: "Which weather to measure: a condition (Rain, Snow, Fog, Thunderstorm, Clear, Cloudy) or how warm it was for your place (Cold, Mild, Hot).")

    private static func chosenWeather(_ parameters: [String: QueryValue]) -> String {
        if case .text(let text)? = parameters["weather"] { return text }
        return "Rain"
    }

    private static func peakText(_ counts: [Int], labels: [String]) -> QueryCell {
        guard let top = counts.max(), top > 0, let index = counts.firstIndex(of: top) else { return .missing }
        return .value(.text(labels[index]))
    }

    static let weatherFields: [QueryField] = {
        let all: Set<QueryTarget> = [.artist, .album, .track]
        func scoped(_ field: QueryField) -> QueryField { var field = field; field.askable = false; field.askableByLargeModels = true; return field }

        var condition = QueryField(
            id: "weatherCondition", name: "Weather", group: .context, type: .text, targets: all,
            help: "The kind of weather most of its plays were made in: Clear, Cloudy, Fog, Rain, Snow or Thunderstorm, where you were (your home place, or the trip you were on), from the hour of each play. A tie goes to the first in that order. Needs weather turned on and downloaded in Settings › Weather. Uses the query’s period or this column’s date scope.",
            scopedCompute: { run, _, scope, entities in
                let tallies = weatherTallies(run, scope: scope).perEntity
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    (entity.id, tallies[entity.id].map { peakText($0.conditions, labels: WeatherCondition.allCases.map(\.rawValue)) } ?? .missing)
                })
            })
        condition.choices = WeatherCondition.allCases.map(\.rawValue)
        condition.caveat = "The weather field matches each item’s most common weather, not every one of its plays."

        var band = QueryField(
            id: "weatherTemperatureBand", name: "Temperature (relative)", group: .context, type: .text, targets: all,
            help: "How warm it usually was when it was played: Cold, Mild or Hot, judged against your own place’s hourly temperatures (by default the coldest 20% of hours are Cold and the warmest 20% Hot; change the percentages in Settings › Weather). A tie goes to Cold, then Mild. Uses the query’s period or this column’s date scope.",
            scopedCompute: { run, _, scope, entities in
                let tallies = weatherTallies(run, scope: scope).perEntity
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    (entity.id, tallies[entity.id].map { peakText($0.bands, labels: TemperatureBand.allCases.map(\.rawValue)) } ?? .missing)
                })
            })
        band.choices = TemperatureBand.allCases.map(\.rawValue)
        band.caveat = "The temperature field matches each item’s most common band, not every one of its plays."

        let average = QueryField(
            id: "weatherAverageTemperature", name: "Average temperature when played", group: .context, type: .numeric, targets: all,
            column: .standard(for: .numeric, style: .temperature, width: 120),
            help: "The average outdoor temperature at the hours of its plays, where you were (home, or the trip you were on), in the unit chosen in Settings › Weather (Celsius or Fahrenheit; a condition on it is typed in that unit, so changing the unit changes what a saved number means). For hot and cold judged against your own climate in either unit, use Temperature (relative). Uses the query’s period or this column’s date scope.",
            scopedCompute: { run, _, scope, entities in
                let tallies = weatherTallies(run, scope: scope).perEntity
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    guard let tally = tallies[entity.id], tally.temperatureCount > 0 else { return (entity.id, .missing) }
                    return (entity.id, .value(.number(run.snapshots.weather.unit.fromCelsius(tally.temperatureSum / Double(tally.temperatureCount)))))
                })
            })

        let share = QueryField(
            id: "weatherShare", name: "Share of plays in weather", group: .context, type: .numeric, targets: all,
            parameters: [weatherParameter], column: .standard(for: .numeric, style: .percent, width: 110),
            help: "The share of its plays made in the chosen weather (Rain, Snow, Fog, Thunderstorm, Clear, Cloudy, or Cold, Mild, Hot for your place). A share built on a few plays is noisy: pair it with a minimum number of plays. For how much more (or less) than usual, use Weather lift. Uses the query’s period or this column’s date scope.",
            scopedCompute: { run, parameters, scope, entities in
                let tallies = weatherTallies(run, scope: scope).perEntity
                let weather = chosenWeather(parameters)
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    (entity.id, tallies[entity.id]?.share(of: weather).map { .value(.number($0)) } ?? .missing)
                })
            })

        let lift = QueryField(
            id: "weatherLift", name: "Weather lift", group: .context, type: .numeric, targets: all,
            parameters: [weatherParameter], column: .standard(for: .numeric, style: .decimal(2), width: 100),
            help: "How much more (or less) than usual it is played in the chosen weather: its share of plays in that weather divided by the share across all the plays in the same period. 1.00 is typical, 2.00 is twice as often as usual, 0.50 half as often. It already allows for how rare that weather is (and, in a narrow period, for the season). No value if that weather never occurs in the period. Noisy for items with few plays, so pair it with a minimum number of plays.",
            scopedCompute: { run, parameters, scope, entities in
                let (tallies, baseline) = weatherTallies(run, scope: scope)
                let weather = chosenWeather(parameters)
                guard let typical = baseline.share(of: weather), typical > 0 else { return Dictionary(uniqueKeysWithValues: entities.map { ($0.id, .missing) }) }
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    (entity.id, tallies[entity.id]?.share(of: weather).map { .value(.number($0 / typical)) } ?? .missing)
                })
            })

        let city = QueryField(
            id: "playCity", name: "City", group: .context, type: .text, targets: all,
            help: "The city most of its plays were made in: your home place, or the trip you were on at the time of each play (Settings › Weather › Trips). A tie goes to the city that comes first alphabetically. Needs a home place chosen in Settings › Weather; without it there is no value. It describes the most common city, not every play: to count only the plays made in a city, use the play filter’s Cities. Uses the query’s period or this column’s date scope.",
            scopedCompute: { run, _, scope, entities in
                let tallies = cityTallies(run, scope: scope)
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    guard let counts = tallies[entity.id], let top = counts.values.max() else { return (entity.id, .missing) }
                    let name = counts.filter { $0.value == top }.keys.sorted { PlaceNames.key($0) < PlaceNames.key($1) }[0]
                    return (entity.id, .value(.text(name)))
                })
            })

        let cityCount = QueryField(
            id: "playCityCount", name: "Cities played in", group: .context, type: .numeric, targets: all,
            column: .standard(for: .numeric, style: .integer, width: 100),
            help: "How many different cities its plays were made in (your home place and each trip place counts once, by name). 1 means it was only ever played in one place. Needs a home place chosen in Settings › Weather. Uses the query’s period or this column’s date scope.",
            scopedCompute: { run, _, scope, entities in
                let tallies = cityTallies(run, scope: scope)
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    guard let counts = tallies[entity.id], !counts.isEmpty else { return (entity.id, .missing) }
                    return (entity.id, .value(.number(Double(Set(counts.keys.map(PlaceNames.key)).count))))
                })
            })

        // Kept out of the on-device model's small vocabulary (a weather condition would match nothing while weather is off); the larger
        // models are offered them.
        return [scoped(condition), scoped(band), scoped(average), scoped(share), scoped(lift), scoped(city), scoped(cityCount)]
    }()
}
