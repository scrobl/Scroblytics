import SwiftUI

/// The Location and Weather cells of one play in a list: where you were and the weather there at that hour ("Munich", "Rain · 8 °C"),
/// or dashes when there is no weather for that time. The place is the trip's for a play made on a trip, else home's.
struct PlayWeatherCells: View {
    let date: Date
    let weather: WeatherSnapshot
    let unit: TemperatureUnit
    var showsLocation = true

    static let locationWidth: CGFloat = 96
    static let weatherWidth: CGFloat = 150

    var body: some View {
        let sample = weather.sample(at: date)
        let location = weather.locationName(at: date)
        HStack(spacing: 10) {
            if showsLocation {
                Text(location ?? "—")
                    .font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: Self.locationWidth, alignment: .leading)
            }
            HStack(spacing: 5) {
                if let condition = sample?.condition {
                    Image(systemName: condition.symbolName).foregroundStyle(.secondary)
                }
                Text(sample?.summary(unit: unit) ?? "—").lineLimit(1)
            }
            .font(AppTypography.metadata).foregroundStyle(.secondary)
            .frame(width: Self.weatherWidth, alignment: .leading)
        }
        .help([location, sample?.condition?.rawValue].compactMap { $0 }.joined(separator: " · "))
    }
}
