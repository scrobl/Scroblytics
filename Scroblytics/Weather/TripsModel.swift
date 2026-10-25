import Foundation
import Observation

extension Notification.Name {
    /// Something outside the Tools page (Settings, a Trends card) asks the app to open a tool. `object` is a `ToolDescriptor.Kind`.
    static let openToolRequested = Notification.Name("OpenToolRequested")
}

/// The trips a person has recorded, and what can be done to them: add, edit, remove, end the ones still open. A trip is where you were and
/// for which days, kept so what you listened to then can be looked at; with weather on, each also uses the weather where you were.
/// Saved to a small file beside the weather folder (see `WeatherTripStore`), so every screen reads the same list.
@MainActor
@Observable
final class TripsModel {
    private(set) var trips: [WeatherTrip]
    /// Changes whenever the list does, for views that recompute from it.
    private(set) var revision = 0

    private let calendar: Calendar
    private let file: URL

    init(file: URL = WeatherTripStore.defaultFile(), calendar: Calendar = AppCalendars.listening) {
        self.file = file
        self.calendar = calendar
        self.trips = WeatherTripStore.load(file: file)
    }

    /// Reads the file again (another screen, or a restored backup, may have changed it).
    func reload() {
        trips = WeatherTripStore.load(file: file)
        revision += 1
    }

    var openTrips: [WeatherTrip] { trips.filter { $0.until == nil } }
    var currentTrip: WeatherTrip? { WeatherTrip.effective(at: Date(), in: trips) }

    /// The trips that share some of their time with another trip (an open-ended trip runs on without end).
    static func overlappingTrips(in trips: [WeatherTrip]) -> Set<UUID> {
        var found = Set<UUID>()
        for (index, trip) in trips.enumerated() {
            for other in trips.dropFirst(index + 1) where trip.overlaps(other) { found.insert(trip.id); found.insert(other.id) }
        }
        return found
    }

    var overlapping: Set<UUID> { Self.overlappingTrips(in: trips) }

    /// The last day of a trip (it ends at the start of the day after).
    func lastDay(of trip: WeatherTrip) -> Date {
        guard let until = trip.until else { return Date() }
        return calendar.date(byAdding: .day, value: -1, to: until) ?? until
    }

    func dates(_ trip: WeatherTrip) -> String {
        let from = trip.from.formatted(date: .abbreviated, time: .omitted)
        guard trip.until != nil else { return "Since \(from), still there" }
        return "\(from) – \(lastDay(of: trip).formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: Changing trips

    /// Saves a new trip, or the changes to one. A changed place or dates throw away that trip's downloaded weather, so it is fetched again.
    func save(_ draft: TripDraft) {
        guard let place = draft.place else { return }
        let from = calendar.startOfDay(for: draft.from)
        let until: Date? = draft.stillThere ? nil : calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(draft.lastDay, draft.from)))
        var updated = trips
        if let id = draft.tripID, let index = updated.firstIndex(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: WeatherTripStore.cacheDirectory(for: updated[index]))
            updated[index].place = place
            updated[index].from = from
            updated[index].until = until
        } else {
            updated.append(WeatherTrip(place: place, from: from, until: until))
        }
        persist(updated)
    }

    func remove(_ trip: WeatherTrip) {
        try? FileManager.default.removeItem(at: WeatherTripStore.cacheDirectory(for: trip))
        persist(trips.filter { $0.id != trip.id })
    }

    /// Ends every trip that has no end, with today as its last day.
    func backHome() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        persist(trips.map { trip in
            var trip = trip
            if trip.until == nil { trip.until = tomorrow }
            return trip
        })
    }

    private func persist(_ new: [WeatherTrip]) {
        trips = new
        revision += 1
        WeatherTripStore.save(new, file: file)
        // Query's list of cities, Trends and the tool itself read the trips again; with weather on, the new trip's weather is fetched now.
        NotificationCenter.default.post(name: .weatherDidUpdate, object: nil)
        if WeatherSettings.isEnabled() { WeatherStatus.shared.update(force: true) }
    }
}
