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
struct WeatherTripsSection: View {
    @AppStorage(WeatherSettings.enabledKey) private var enabled = false
    @State private var trips = WeatherTripStore.load()
    @State private var status = WeatherStatus.shared
    @State private var editing: TripDraft?

    private var calendar: Calendar { AppCalendars.listening }
    private var sorted: [WeatherTrip] { trips.sorted { $0.from > $1.from } }
    private var openTrips: [WeatherTrip] { trips.filter { $0.until == nil } }
    private var currentTrip: WeatherTrip? { WeatherTrip.effective(at: Date(), in: trips) }

    var body: some View {
        Section("Trips") {
            Text("Away from home? A trip uses the weather where you were for the days it covers, in place of your home weather. Your scrobbles are never changed: each play just looks up where you were when it was made, so you can add a trip for dates in the past, and change it later.")
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
            if let currentTrip {
                Label("Away now: \(currentTrip.shortName)\(currentTrip.until == nil ? "" : " until \(lastDay(of: currentTrip).formatted(date: .abbreviated, time: .omitted))")", systemImage: "airplane")
                    .foregroundStyle(.tint)
            }
            HStack {
                Button("I’m Away Now…") { editing = TripDraft.awayNow(calendar: calendar) }
                Button("Add a Trip…") { editing = TripDraft.new(calendar: calendar) }
                if !openTrips.isEmpty { Button("Back Home") { backHome() } }
            }
            ForEach(sorted) { trip in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trip.place.name)
                        Text(dates(trip)).font(AppTypography.supporting).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { editing = TripDraft(trip: trip, calendar: calendar) }
                    Button("Remove", role: .destructive) { remove(trip) }
                }
            }
            if sorted.enumerated().contains(where: { index, trip in sorted.dropFirst(index + 1).contains { trip.overlaps($0) } }) {
                Text("Some trips overlap. For the days they share, the trip that began later is used.")
                    .font(AppTypography.supporting).foregroundStyle(.orange)
            }
            if !trips.isEmpty, !enabled {
                Text("Weather is off, so trips are saved but nothing is downloaded for them yet.")
                    .font(AppTypography.supporting).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { draft in
            TripEditor(draft: draft, onSave: { save($0) }, onCancel: { editing = nil })
        }
    }

    // MARK: Wording

    /// The last day of a trip (it ends at the start of the day after).
    private func lastDay(of trip: WeatherTrip) -> Date {
        guard let until = trip.until else { return Date() }
        return calendar.date(byAdding: .day, value: -1, to: until) ?? until
    }

    private func dates(_ trip: WeatherTrip) -> String {
        let from = trip.from.formatted(date: .abbreviated, time: .omitted)
        guard trip.until != nil else { return "Since \(from), still there" }
        return "\(from) – \(lastDay(of: trip).formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: Changing trips

    private func persist(_ new: [WeatherTrip]) {
        trips = new
        WeatherTripStore.save(new)
        NotificationCenter.default.post(name: .weatherDidUpdate, object: nil)
        if enabled { status.update(force: true) }
    }

    private func save(_ draft: TripDraft) {
        guard let place = draft.place else { return }
        let from = calendar.startOfDay(for: draft.from)
        let until: Date? = draft.stillThere ? nil : calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(draft.lastDay, draft.from)))
        var updated = trips
        if let id = draft.tripID, let index = updated.firstIndex(where: { $0.id == id }) {
            // Changed dates or place: its downloaded weather no longer fits, so it is fetched again.
            try? FileManager.default.removeItem(at: WeatherTripStore.cacheDirectory(for: updated[index]))
            updated[index].place = place
            updated[index].from = from
            updated[index].until = until
        } else {
            updated.append(WeatherTrip(place: place, from: from, until: until))
        }
        editing = nil
        persist(updated)
    }

    private func remove(_ trip: WeatherTrip) {
        try? FileManager.default.removeItem(at: WeatherTripStore.cacheDirectory(for: trip))
        persist(trips.filter { $0.id != trip.id })
    }

    /// Ends every trip that has no end, with today as its last day.
    private func backHome() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        persist(trips.map { trip in
            var trip = trip
            if trip.until == nil { trip.until = tomorrow }
            return trip
        })
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
    /// Places already used by a trip, most recent first, to pick from instead of searching again.
    var knownPlaces: [WeatherPlace] = TripEditor.knownPlaces(in: WeatherTripStore.load())

    /// The places of these trips, each once (by its key), the most recently visited first.
    static func knownPlaces(in trips: [WeatherTrip]) -> [WeatherPlace] {
        var seen = Set<String>()
        return trips.sorted { $0.from > $1.from }.compactMap { seen.insert($0.place.key).inserted ? $0.place : nil }
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
                        Button("Change") { draft.place = nil }
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
                    WeatherPlacePicker { draft.place = $0 }
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
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.place == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
