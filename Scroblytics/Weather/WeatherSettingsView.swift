import SwiftUI

/// Settings › Weather: match the listening with the weather at a home place. Off until turned on, because turning it on sends the
/// place's rounded coordinate (never anything about the music) to the weather service.
struct WeatherSettingsView: View {
    @AppStorage(WeatherSettings.enabledKey) private var enabled = false
    @AppStorage(WeatherSettings.temperatureUnitKey) private var unitRaw = TemperatureUnit.automatic.rawValue
    @AppStorage(WeatherSettings.coldPercentileKey) private var coldPercentile = WeatherSettings.defaultColdPercentile
    @AppStorage(WeatherSettings.hotPercentileKey) private var hotPercentile = WeatherSettings.defaultHotPercentile
    @State private var status = WeatherStatus.shared
    @State private var place = WeatherSettings.place()
    @State private var query = ""
    @State private var results: [GeocodeResult] = []
    @State private var isSearching = false
    @State private var searchMessage: String?
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var coordinateName = ""
    @State private var cutoffs: (cold: Double, hot: Double)?

    var body: some View {
        Form {
            Section("Weather") {
                Toggle("Match my listening with the weather", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on { status.update(force: true) } else { status.stop() }
                        NotificationCenter.default.post(name: .weatherDidUpdate, object: nil)
                    }
                Text("Adds fields to Query and Ask for the weather at the time of each play: the kind of weather, how warm it was for where you live, and the temperature. To get it, the app asks the free Open-Meteo weather service for the hourly weather at your home place for the years you have scrobbles. It sends only the place’s coordinates, rounded to about 11 km, and the dates: never what you listened to. The weather is then kept on this Mac, and never leaves it.")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
            }

            Section("Home place") {
                if let place {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                            Text(place.coordinateLabel).font(AppTypography.supporting).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { choose(nil) }
                    }
                } else {
                    Text("No place chosen yet.").foregroundStyle(.secondary)
                }

                HStack {
                    TextField("Search for a city", text: $query)
                        .onSubmit { Task { await search() } }
                    Button("Search") { Task { await search() } }
                        .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).count < 2)
                }
                if let searchMessage { Text(searchMessage).font(AppTypography.supporting).foregroundStyle(.secondary) }
                ForEach(results) { result in
                    Button {
                        choose(result.place)
                        results = []
                        query = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.label)
                            Text(result.place.coordinateLabel).font(AppTypography.supporting).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text("The name you type is sent to Open-Meteo’s search, nothing else. The place you choose is kept as a rounded coordinate.")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Enter coordinates instead") {
                    TextField("Latitude (−90 to 90)", text: $latitudeText)
                    TextField("Longitude (−180 to 180)", text: $longitudeText)
                    TextField("Name (optional)", text: $coordinateName)
                    Button("Use these coordinates") { useCoordinates() }
                        .disabled(parsedCoordinates == nil)
                    Text("Coordinates are rounded to one decimal place (about 11 km).")
                        .font(AppTypography.supporting)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Temperature") {
                Picker("Show temperatures in", selection: $unitRaw) {
                    ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("Decides how temperatures are shown and typed in Query and here. The weather itself is kept in Celsius, so changing the unit never alters your data; it only changes what a saved number such as “average temperature above 15” means.")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
                Stepper(value: $coldPercentile, in: 1...49) {
                    Text("Cold: the coldest \(coldPercentile)% of hours")
                }
                Stepper(value: Binding(get: { 100 - hotPercentile }, set: { hotPercentile = 100 - $0 }), in: 1...49) {
                    Text("Hot: the warmest \(100 - hotPercentile)% of hours")
                }
                if let cutoffs {
                    Text("For your place that is cold at \(temperatureText(cutoffs.cold)) or below and hot at \(temperatureText(cutoffs.hot)) or above; everything between is mild.")
                        .font(AppTypography.supporting)
                        .foregroundStyle(.secondary)
                }
                Button("Use the defaults (20% and 20%)") {
                    coldPercentile = WeatherSettings.defaultColdPercentile
                    hotPercentile = WeatherSettings.defaultHotPercentile
                }
                .disabled(coldPercentile == WeatherSettings.defaultColdPercentile && hotPercentile == WeatherSettings.defaultHotPercentile)
                Text("Hot and cold are judged against your own place’s hourly temperatures across the years downloaded, so 15° can be warm in one climate and cold in another. They set the Temperature (relative) field and the Cold, Mild and Hot choices of the weather fields.")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
            }

            Section("Downloaded weather") {
                statusLine
                if let coverage = status.coverageText {
                    Text(coverage + " · " + ByteCountFormatter.string(fromByteCount: Int64(status.bytesOnDisk), countStyle: .file))
                        .font(AppTypography.supporting).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Update Now") { status.update(force: true) }
                        .disabled(!enabled || place == nil || isUpdating)
                    Button("Remove Downloaded Weather", role: .destructive) { status.removeDownloadedWeather() }
                        .disabled(status.bytesOnDisk == 0 && status.coverageText == nil)
                }
                HStack(spacing: 4) {
                    Link(WeatherAttribution.text, destination: WeatherAttribution.url)
                    Text("(CC BY 4.0)").foregroundStyle(.secondary)
                }
                .font(AppTypography.supporting)
                HelpLinkButton(articleID: "screen-weather", title: "About Weather")
            }
        }
        .formStyle(.grouped)
        .task { await loadCutoffs() }
        .onChange(of: coldPercentile) { Task { await loadCutoffs() }; NotificationCenter.default.post(name: .weatherDidUpdate, object: nil) }
        .onChange(of: hotPercentile) { Task { await loadCutoffs() }; NotificationCenter.default.post(name: .weatherDidUpdate, object: nil) }
        .onChange(of: unitRaw) { NotificationCenter.default.post(name: .weatherDidUpdate, object: nil) }
        .onReceive(NotificationCenter.default.publisher(for: .weatherDidUpdate)) { _ in Task { await loadCutoffs() } }
    }

    // MARK: Status

    private var isUpdating: Bool { if case .updating = status.state { return true }; return false }

    @ViewBuilder
    private var statusLine: some View {
        switch status.state {
        case .idle:
            if let last = status.lastUpdatedAt {
                Text("Updated \(last.formatted(date: .abbreviated, time: .shortened)).").foregroundStyle(.secondary)
            } else {
                Text(enabled && place != nil ? "Nothing downloaded yet." : "Turn weather on and choose a place to download it.").foregroundStyle(.secondary)
            }
        case .updating(let text):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text) }
        case .failed(let message):
            Text(message).foregroundStyle(.orange)
        case .waitingForConnection:
            Text("Waiting for a connection (Offline mode is on, or the network is down). It continues when you are online.").foregroundStyle(.orange)
        }
    }

    private func temperatureText(_ celsius: Double) -> String {
        (TemperatureUnit(rawValue: unitRaw) ?? .automatic).resolved().text(celsius: celsius)
    }

    private func loadCutoffs() async {
        let snapshot = await offMain { WeatherSnapshot.load() }
        if let cold = snapshot.coldAtOrBelow, let hot = snapshot.hotAtOrAbove { cutoffs = (cold, hot) } else { cutoffs = nil }
    }

    // MARK: Choosing a place

    private func choose(_ new: WeatherPlace?) {
        WeatherSettings.setPlace(new)
        place = new
        NotificationCenter.default.post(name: .weatherDidUpdate, object: nil)
        if new != nil, enabled { status.update(force: true) }
        status.refreshCoverage()
    }

    private func search() async {
        isSearching = true
        searchMessage = nil
        defer { isSearching = false }
        do {
            results = try await WeatherClient().search(name: query)
            if results.isEmpty { searchMessage = "No place found with that name. Try a bigger city nearby, or enter coordinates." }
        } catch {
            results = []
            searchMessage = describeWeatherError(error)
        }
    }

    private var parsedCoordinates: (Double, Double)? {
        func number(_ text: String) -> Double? { Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
        guard let lat = number(latitudeText), let lon = number(longitudeText), WeatherPlace.isValid(latitude: lat, longitude: lon) else { return nil }
        return (lat, lon)
    }

    private func useCoordinates() {
        guard let (lat, lon) = parsedCoordinates else { return }
        let name = coordinateName.trimmingCharacters(in: .whitespaces)
        let made = WeatherPlace(name: name.isEmpty ? "My place" : name, latitude: lat, longitude: lon)
        choose(made)
        latitudeText = ""; longitudeText = ""; coordinateName = ""
    }
}
