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
            help: "The kind of weather most of its plays were made in: Clear, Cloudy, Fog, Rain, Snow or Thunderstorm, at your home place, from the hour of each play. A tie goes to the first in that order. Needs weather turned on and downloaded in Settings › Weather. Uses the query’s period or this column’s date scope.",
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
            help: "The average outdoor temperature at the hours of its plays, at your home place, in the unit chosen in Settings › Weather (Celsius or Fahrenheit; a condition on it is typed in that unit, so changing the unit changes what a saved number means). For hot and cold judged against your own climate in either unit, use Temperature (relative). Uses the query’s period or this column’s date scope.",
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

        // Kept out of the on-device model's small vocabulary (a weather condition would match nothing while weather is off); the larger
        // models are offered them.
        return [scoped(condition), scoped(band), scoped(average), scoped(share), scoped(lift)]
    }()
}
