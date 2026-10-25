#if DEBUG
import Foundation
import SwiftData

/// `SCROBLYTICS_WEATHERGAPS_DUMP=1` (with `SCROBLYTICS_STORE_PATH` on a COPY of a library that has the `Weather` folder and `WeatherTrips.json` beside
/// it): which plays have no weather, and why. Counts only (no names), grouped by where the play was made and by month.
enum WeatherGapDump {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_WEATHERGAPS_DUMP"] != nil else { return }
        Task { @MainActor in
            let plays = (try? await ScrobbleHistoryCache.shared.snapshots(container: container)) ?? []
            let weather = WeatherSnapshot.load()
            let now = Date()
            print("plays: \(plays.count.formatted()); home place saved: \(weather.homePlace != nil); trips: \(weather.trips.count)")
            if let series = weather.series {
                print("home weather: hours \(series.startHour)…\(series.endHour), through \(WeatherSeries.date(ofHour: series.endHour)) UTC; now \(now)")
            } else { print("home weather: none loaded") }
            struct Tally { var count = 0; var first = Date.distantFuture; var last = Date.distantPast; var months: [String: Int] = [:] }
            var tallies: [String: Tally] = [:]
            let month = DateFormatter(); month.dateFormat = "yyyy-MM"
            var withWeather = 0
            for play in plays {
                if weather.sample(at: play.playedAt) != nil { withWeather += 1; continue }
                let reason: String
                if let trip = WeatherTrip.effective(at: play.playedAt, in: weather.trips.map(\.trip)) {
                    let entry = weather.trips.first { $0.trip.id == trip.id }
                    if !trip.place.hasCoordinates { reason = "on a trip that is only a typed name (no weather by design)" }
                    else if entry?.series == nil { reason = "on a trip with no weather series (weather off or no home place)" }
                    else if (entry?.series?.count ?? 0) == 0 { reason = "on a trip whose weather is not downloaded yet" }
                    else { reason = "on a trip, hour missing from its downloaded weather" }
                } else if weather.series == nil { reason = "at home, no home weather loaded" }
                else if let series = weather.series, play.playedAt > WeatherSeries.date(ofHour: series.endHour) { reason = "at home, after the last downloaded hour" }
                else if let series = weather.series, WeatherSeries.hour(of: play.playedAt) < series.startHour { reason = "at home, before the first downloaded hour" }
                else { reason = "at home, a gap inside the downloaded range" }
                var tally = tallies[reason] ?? Tally()
                tally.count += 1
                tally.first = min(tally.first, play.playedAt)
                tally.last = max(tally.last, play.playedAt)
                tally.months[month.string(from: play.playedAt), default: 0] += 1
                tallies[reason] = tally
            }
            print("with weather: \(withWeather.formatted()) of \(plays.count.formatted()); without: \((plays.count - withWeather).formatted())")
            for (reason, tally) in tallies.sorted(by: { $0.value.count > $1.value.count }) {
                let top = tally.months.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                print("- \(reason): \(tally.count.formatted()) plays, from \(tally.first) to \(tally.last); busiest months: \(top)")
            }
            let recent = plays.filter { $0.playedAt > now.addingTimeInterval(-30 * 86_400) }
            print("last 30 days: \(recent.filter { weather.sample(at: $0.playedAt) == nil }.count) of \(recent.count) without weather")
            exit(0)
        }
    }
}
#endif
