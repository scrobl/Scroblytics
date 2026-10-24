import Foundation
import SwiftData

/// What weather an artist or album is played in more than usual: its share of plays in each kind of weather (and at each temperature
/// band) against the share across all plays in the same period. Shown as one tile on the Artist and Album pages.
enum EntityWeatherLean {
    struct Lean: Equatable, Sendable {
        /// "Rain", "Cold"…
        let name: String
        /// Its share of plays in this weather divided by everyone's: 1.34 is 34% more than usual.
        let lift: Double
        /// Plays made in this weather, out of all its plays that have weather for the same kind of information.
        let count: Int
        let total: Int
        /// True when the weather is how warm it was (Cold, Mild, Hot) rather than a kind of weather.
        let isTemperature: Bool
    }

    enum Result: Equatable, Sendable {
        /// Weather is off, or not downloaded for this period: no tile.
        case unavailable
        /// Too few plays with weather to say anything: no tile.
        case notEnough
        /// Plays follow the weather like everything else.
        case even(total: Int)
        case leans(Lean)
    }

    /// Plays with weather needed before a page says anything, and plays in one weather before it can be called a lean.
    static let minimumTotal = 20
    static let minimumCount = 5
    /// A lean must be at least this much more than usual (15%).
    static let minimumLift = 1.15

    /// `plays` are every play (any order); `isEntity` picks the page's own. Only plays inside `range` that have weather count.
    static func compute(plays: [ScrobbleSnapshot], range: DateRange, weather: WeatherSnapshot, isEntity: (ScrobbleSnapshot) -> Bool) -> Result {
        guard !weather.isEmpty else { return .unavailable }
        let conditions = WeatherCondition.allCases, bands = TemperatureBand.allCases
        var allCondition = [Int](repeating: 0, count: conditions.count), mineCondition = allCondition
        var allBand = [Int](repeating: 0, count: bands.count), mineBand = allBand
        var mineWithWeather = 0
        for play in plays where play.playedAt >= range.from && play.playedAt <= range.to {
            guard let sample = weather.sample(at: play.playedAt) else { continue }
            let mine = isEntity(play)
            let ci = sample.condition.flatMap { conditions.firstIndex(of: $0) }
            let bi = weather.band(for: sample).flatMap { bands.firstIndex(of: $0) }
            if let ci { allCondition[ci] += 1; if mine { mineCondition[ci] += 1 } }
            if let bi { allBand[bi] += 1; if mine { mineBand[bi] += 1 } }
            if mine { mineWithWeather += 1 }
        }
        guard mineWithWeather >= minimumTotal else { return mineWithWeather == 0 && allCondition.reduce(0, +) == 0 ? .unavailable : .notEnough }
        let allConditionTotal = allCondition.reduce(0, +), mineConditionTotal = mineCondition.reduce(0, +)
        let allBandTotal = allBand.reduce(0, +), mineBandTotal = mineBand.reduce(0, +)
        var best: Lean?
        func consider(name: String, mine: Int, all: Int, mineTotal: Int, allTotal: Int, isTemperature: Bool) {
            guard mine >= minimumCount, all > 0, allTotal > 0, mineTotal > 0 else { return }
            let lift = (Double(mine) / Double(mineTotal)) / (Double(all) / Double(allTotal))
            guard lift >= minimumLift else { return }
            if let current = best, (lift, mine) <= (current.lift, current.count) { return }
            best = Lean(name: name, lift: lift, count: mine, total: mineTotal, isTemperature: isTemperature)
        }
        for (i, condition) in conditions.enumerated() {
            consider(name: condition.rawValue, mine: mineCondition[i], all: allCondition[i], mineTotal: mineConditionTotal, allTotal: allConditionTotal, isTemperature: false)
        }
        for (i, band) in bands.enumerated() {
            consider(name: band.rawValue, mine: mineBand[i], all: allBand[i], mineTotal: mineBandTotal, allTotal: allBandTotal, isTemperature: true)
        }
        return best.map(Result.leans) ?? .even(total: mineWithWeather)
    }

    /// The tile for a page: nil when there is nothing to say.
    static func fact(for result: Result) -> DetailFact? {
        let help = "The weather this is played in more than usual: its share of plays in that weather, against the share across all your plays in the period shown (weather at the place you were, from Settings › Weather). It needs at least \(minimumTotal) plays with weather, and the weather in at least \(minimumCount) of them."
        switch result {
        case .unavailable, .notEnough:
            return nil
        case .even(let total):
            return DetailFact(id: "weather", label: "Weather", value: .text("No standout"), detail: "\(total.formatted()) plays, even across weather", mayHaveDetail: true, systemImage: "cloud.sun", help: help)
        case .leans(let lean):
            let detail = lean.isTemperature
                ? "\(lean.count.formatted()) of \(lean.total.formatted()) plays when it was \(lean.name.lowercased())"
                : "\(lean.count.formatted()) of \(lean.total.formatted()) plays"
            return DetailFact(id: "weather", label: "Weather", value: .text("\(lean.name) \(WeatherPalette.percent(lean.lift))"), detail: detail, mayHaveDetail: true, systemImage: "cloud.sun", help: help)
        }
    }
}

/// Reads what an artist or album leans into, off the main thread, from the same plays the page's own numbers count.
enum EntityWeatherLeanLoader {
    static func artist(container: ModelContainer, name: String, range: DateRange) async -> EntityWeatherLean.Result {
        let key = TextNormalization.artistIdentityKey(name)
        return await load(container: container, range: range) { TextNormalization.artistIdentityKey($0.artistName) == key }
    }

    static func album(container: ModelContainer, artist: String, album: String, range: DateRange) async -> EntityWeatherLean.Result {
        await load(container: container, range: range) { $0.albumName == album && TextNormalization.trackMatchesArtistContext(trackArtist: $0.artistName, context: artist) }
    }

    static func track(container: ModelContainer, artist: String, track: String, range: DateRange) async -> EntityWeatherLean.Result {
        let key = TextNormalization.artistIdentityKey(artist)
        return await load(container: container, range: range) { $0.trackName == track && TextNormalization.artistIdentityKey($0.artistName) == key }
    }

    private static func load(container: ModelContainer, range: DateRange, isEntity: @escaping @Sendable (ScrobbleSnapshot) -> Bool) async -> EntityWeatherLean.Result {
        await offMain {
            let weather = WeatherSnapshot.load()
            guard !weather.isEmpty, let all = try? await ScrobbleHistoryCache.shared.snapshots(container: container) else { return EntityWeatherLean.Result.unavailable }
            return EntityWeatherLean.compute(plays: all, range: range, weather: weather, isEntity: isEntity)
        }
    }
}
