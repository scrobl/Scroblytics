import SwiftUI

/// Search for a city (the typed name goes to Open-Meteo's place search, nothing else) or enter coordinates, and hand back the place
/// chosen. Used for the home place and for each trip.
struct WeatherPlacePicker: View {
    let onChoose: (WeatherPlace) -> Void

    @State private var query = ""
    @State private var results: [GeocodeResult] = []
    @State private var isSearching = false
    @State private var searchMessage: String?
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var coordinateName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search for a city", text: $query)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).count < 2)
            }
            if let searchMessage { Text(searchMessage).font(AppTypography.supporting).foregroundStyle(.secondary) }
            ForEach(results) { result in
                Button {
                    onChoose(result.place)
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
        onChoose(WeatherPlace(name: name.isEmpty ? "My place" : name, latitude: lat, longitude: lon))
        latitudeText = ""; longitudeText = ""; coordinateName = ""
    }
}

/// Settings › Weather › Trips: where you were when you weren't at home. A trip replaces the home weather for the days it covers; no
/// scrobble is touched, so a trip can be added for the past and corrected at any time.
/// Settings › Weather › Trips: the trips live in Tools › Trips, which works with weather on or off. Here, only where to find them.
struct WeatherTripsSection: View {
    @AppStorage(WeatherSettings.enabledKey) private var enabled = false
    @State private var model = TripsModel()

    var body: some View {
        Section("Trips") {
            Text("Away from home? Record where you were and for which days in Tools › Trips, to see what you listened to on each trip. With weather on, each trip also uses the weather where you were, in place of your home weather. Your scrobbles are never changed.")
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
            if let current = model.currentTrip {
                Label("Away now: \(current.shortName)", systemImage: "airplane").foregroundStyle(.tint)
            }
            HStack {
                Text(model.trips.isEmpty ? "No trips recorded yet." : "\(model.trips.count) trip\(model.trips.count == 1 ? "" : "s") recorded.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
                Spacer()
                Button("Open Trips") { NotificationCenter.default.post(name: .openToolRequested, object: ToolDescriptor.Kind.trips) }
            }
            if !model.trips.isEmpty, !enabled {
                Text("Weather is off, so nothing is downloaded for the trips. They still show what you listened to.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .weatherDidUpdate)) { _ in model.reload() }
    }
}

/// What the trip sheet edits.
struct TripDraft: Identifiable {
    let id = UUID()
    var tripID: UUID?
    var place: WeatherPlace?
    var from: Date
    var stillThere: Bool
    var lastDay: Date
    /// Whether the person has picked the last day themselves; until they have, it follows the first day (a trip is added ahead of time or
    /// as it begins, so it never ends before it starts and rarely on today's date).
    var lastDayChosen = false

    /// The first day was changed: the last day follows it until it has been chosen, and never falls before it.
    mutating func firstDayChanged() {
        if !lastDayChosen || lastDay < from { lastDay = from }
    }

    static func awayNow(calendar: Calendar) -> TripDraft { TripDraft(place: nil, from: calendar.startOfDay(for: Date()), stillThere: true, lastDay: calendar.startOfDay(for: Date())) }
    static func new(calendar: Calendar) -> TripDraft { TripDraft(place: nil, from: calendar.startOfDay(for: Date()), stillThere: false, lastDay: calendar.startOfDay(for: Date())) }

    init(tripID: UUID? = nil, place: WeatherPlace?, from: Date, stillThere: Bool, lastDay: Date) {
        self.tripID = tripID
        self.place = place
        self.from = from
        self.stillThere = stillThere
        self.lastDay = lastDay
    }

    init(trip: WeatherTrip, calendar: Calendar) {
        self.init(
            tripID: trip.id, place: trip.place, from: trip.from, stillThere: trip.until == nil,
            lastDay: trip.until.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } ?? calendar.startOfDay(for: Date())
        )
        lastDayChosen = true   // an existing trip keeps the end it has
    }
}

struct TripEditor: View {
    @State var draft: TripDraft
    let onSave: (TripDraft) -> Void
    let onCancel: () -> Void
    /// Places already used by a trip, A to Z, to pick from instead of searching again.
    var knownPlaces: [WeatherPlace] = TripEditor.knownPlaces(in: WeatherTripStore.load())
    /// Searching for a place sends the name typed to the weather service, so it is offered only while weather is on; otherwise a place is a
    /// name typed here, kept on this Mac, and the trip has no weather.
    var weatherEnabled = WeatherSettings.isEnabled()
    @State private var typing = false
    @State private var typedName = ""

    private var typedPlace: WeatherPlace? {
        let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : WeatherPlace(typedName: name)
    }

    private var canSave: Bool { draft.place != nil || ((typing || !weatherEnabled) && typedPlace != nil) }

    private var nameOnly: Bool { !weatherEnabled || typing }

    /// The places of these trips, each once (by its key), in alphabetical order (the way names sort for a person: accents and capitals
    /// don't count, so "Åre" comes with the A's).
    static func knownPlaces(in trips: [WeatherTrip]) -> [WeatherPlace] {
        var seen = Set<String>()
        let unique = trips.sorted { $0.from > $1.from }.compactMap { seen.insert($0.place.key).inserted ? $0.place : nil }
        return unique.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.tripID == nil ? "Add a trip" : "Edit trip").font(AppTypography.sectionTitle)
            VStack(alignment: .leading, spacing: 6) {
                Text("Where").font(AppTypography.statLabel).foregroundStyle(.secondary)
                if let place = draft.place {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                            Text(place.coordinateLabel).font(AppTypography.supporting).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Change") {
                            if !place.hasCoordinates { typedName = place.name }
                            draft.place = nil
                        }
                    }
                } else {
                    if !knownPlaces.isEmpty {
                        Menu {
                            ForEach(knownPlaces, id: \.key) { place in
                                Button(place.name) { draft.place = place }
                            }
                        } label: {
                            Label("Choose a place you’ve been before", systemImage: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        Text("Or search for a new one:").font(AppTypography.supporting).foregroundStyle(.secondary)
                    }
                    if nameOnly {
                        TextField("Place name", text: $typedName).textFieldStyle(.roundedBorder)
                        Text(weatherEnabled
                             ? "A name only: nothing is looked up, so this trip has no weather."
                             : "A name only. Nothing is looked up or sent anywhere, and the trip has no weather. Turn on weather in Settings to search for places and get each trip’s weather.")
                            .font(AppTypography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if weatherEnabled { Button("Search for a place instead") { typing = false }.buttonStyle(.link) }
                    } else {
                        WeatherPlacePicker { draft.place = $0 }
                        Button("Type a name instead (no weather for this trip)") { typing = true }.buttonStyle(.link)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("First day", selection: $draft.from, displayedComponents: .date)
                    .onChange(of: draft.from) { draft.firstDayChanged() }
                Toggle("Still there", isOn: $draft.stillThere)
                if !draft.stillThere {
                    // Starts on the first day and follows it until you pick one.
                    DatePicker("Last day", selection: Binding(get: { draft.lastDay }, set: { draft.lastDay = $0; draft.lastDayChosen = true }), in: draft.from..., displayedComponents: .date)
                }
                Text(draft.stillThere ? "The trip stays open until you press Back Home or edit it." : "The last day counts in full.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var done = draft
                    if done.place == nil { done.place = typedPlace }
                    onSave(done)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
