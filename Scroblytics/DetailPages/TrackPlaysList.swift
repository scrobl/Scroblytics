import SwiftUI

/// A track's plays, newest first: the date and album, and the time. With weather turned on and downloaded (Settings › Weather) each
/// play also shows the place the weather was taken for and the weather at that hour; without it the list is exactly the plain one.
struct TrackPlaysList: View {
    let history: [ScrobbleHistoryEntry]
    let weather: WeatherSnapshot
    let unit: TemperatureUnit

    private static let locationColumnWidth: CGFloat = 96
    private static let weatherColumnWidth: CGFloat = 150
    private static let timeColumnWidth: CGFloat = 70

    /// Below this width the Location column goes (the weather says the place in its tooltip row by row): the date would otherwise be cut short.
    private static let locationMinimumWidth: CGFloat = 500

    @State private var availableWidth: CGFloat = 1000

    private var showsWeather: Bool { !weather.isEmpty }
    private var showsLocation: Bool { showsWeather && availableWidth >= Self.locationMinimumWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(history.count.formatted()) plays").font(AppTypography.sectionTitle)
            if showsWeather { header }
            VStack(spacing: 0) {
                ForEach(history) { entry in
                    row(entry)
                    if entry.id != history.last?.id { Divider() }
                }
            }
            if showsWeather {
                Text("Weather is for where you were at the hour of each play: your home place, or a trip you added in Settings › Weather. \(WeatherAttribution.text).")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 14, height: 1)
            Text("Date").frame(maxWidth: .infinity, alignment: .leading)
            if showsLocation { Text("Location").frame(width: Self.locationColumnWidth, alignment: .leading) }
            Text("Weather").frame(width: Self.weatherColumnWidth, alignment: .leading)
            Text("Time").frame(width: Self.timeColumnWidth, alignment: .trailing)
        }
        .font(AppTypography.compactMetadata)
        .foregroundStyle(.secondary)
    }

    private func row(_ entry: ScrobbleHistoryEntry) -> some View {
        let sample = showsWeather ? weather.sample(at: entry.playedAt) : nil
        return HStack(spacing: 10) {
            Image(systemName: "clock").font(AppTypography.supporting).foregroundStyle(.tertiary)
            Text(entry.playedAt.formatted(date: .abbreviated, time: .omitted) + (entry.album.map { " · \($0)" } ?? ""))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsLocation {
                Text(weather.locationName(at: entry.playedAt) ?? "—")
                    .font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: Self.locationColumnWidth, alignment: .leading)
                    .help(weather.placeName ?? "")
            }
            if showsWeather {
                HStack(spacing: 5) {
                    if let condition = sample?.condition {
                        Image(systemName: condition.symbolName).foregroundStyle(.secondary).help(condition.rawValue)
                    }
                    Text(sample?.summary(unit: unit) ?? "—").lineLimit(1)
                }
                .font(AppTypography.metadata).foregroundStyle(.secondary)
                .frame(width: Self.weatherColumnWidth, alignment: .leading)
                .help(showsLocation ? "" : (weather.locationName(at: entry.playedAt).map { "Weather in \($0)" } ?? ""))
            }
            Text(entry.playedAt.formatted(date: .omitted, time: .shortened))
                .font(AppTypography.metadata).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: showsWeather ? Self.timeColumnWidth : nil, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}
