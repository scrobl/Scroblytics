import Foundation
import Observation
import SwiftData

/// The downloaded weather, one small file per place and year in the app's folder (`Weather/<place>/<year>.wx`). Files rather than
/// database rows: a year is one array of hours, it can be deleted without touching the database, and it is never part of a backup
/// because it can always be downloaded again.
struct WeatherFiles: Sendable {
    var directory: URL

    init(directory: URL = ActivityLog.defaultDirectory().appending(path: "Weather", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private func folder(_ place: WeatherPlace) -> URL { directory.appending(path: place.key, directoryHint: .isDirectory) }

    private func file(_ place: WeatherPlace, year: Int) -> URL { folder(place).appending(path: "\(year).wx") }

    func load(_ place: WeatherPlace, year: Int) -> WeatherSeries? {
        (try? Data(contentsOf: file(place, year: year))).flatMap(WeatherSeries.init(data:))
    }

    func save(_ series: WeatherSeries, place: WeatherPlace, year: Int) {
        try? FileManager.default.createDirectory(at: folder(place), withIntermediateDirectories: true)
        try? series.encoded().write(to: file(place, year: year), options: .atomic)
    }

    /// Every saved year for the place laid end to end, or nil if nothing is saved.
    func timeline(_ place: WeatherPlace) -> WeatherSeries? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(place).path)) ?? []
        let years = names.compactMap { name -> Int? in name.hasSuffix(".wx") ? Int(name.dropLast(3)) : nil }.sorted()
        return WeatherSeries.merged(years.compactMap { load(place, year: $0) })
    }

    /// Deletes every downloaded file, for every place.
    func removeAll() { try? FileManager.default.removeItem(at: directory) }

    /// The size on disk of everything downloaded.
    var bytesOnDisk: Int {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return enumerator.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)
    }
}

extension WeatherSnapshot {
    /// What a query reads about the weather and the places, from what is saved on this Mac. The places (the trips, and the home place if one
    /// was chosen) are always there, with or without weather: a trip is recorded to see what was listened to, whether or not weather is on.
    /// The weather is there only while weather is on and the home place's has been downloaded; empty and cheap otherwise.
    static func load(defaults: UserDefaults = .standard, files: WeatherFiles = WeatherFiles(), tripsFile: URL = WeatherTripStore.defaultFile()) -> WeatherSnapshot {
        let trips = WeatherTripStore.load(file: tripsFile)
        let home = WeatherSettings.place(defaults: defaults)
        var snapshot: WeatherSnapshot
        let weatherOn = WeatherSettings.isEnabled(defaults: defaults)
        if weatherOn, let home, let series = files.timeline(home) {
            snapshot = WeatherSnapshot(series: series, placeName: home.name, percentiles: WeatherSettings.percentiles(defaults: defaults),
                                       unit: WeatherSettings.temperatureUnit(defaults: defaults))
        } else {
            snapshot = WeatherSnapshot()
            snapshot.placeName = home?.name
            snapshot.unit = WeatherSettings.temperatureUnit(defaults: defaults)
        }
        // Each trip's weather from its own folder. A trip not downloaded yet is still on the snapshot, with no hours: its days show no weather
        // until it arrives, rather than quietly showing the home weather of a place you weren't in. With weather off, or for a trip that is
        // only a typed name, there is no weather (nil) but the trip still says where you were.
        for trip in trips {
            var tripSeries: WeatherSeries?
            if weatherOn, home != nil, trip.place.hasCoordinates {
                let tripFiles = WeatherFiles(directory: WeatherTripStore.cacheDirectory(for: trip, base: files.directory))
                tripSeries = tripFiles.timeline(trip.place) ?? WeatherSeries(startHour: WeatherSeries.hour(of: trip.from), count: 0)
            }
            snapshot.trips.append(WeatherSnapshot.TripWeather(trip: trip, series: tripSeries))
        }
        return snapshot
    }
}

/// The cities the person has listened in, from the settings alone (the home place and the trips), for the query builder and Ask to offer and
/// check names against.
enum WeatherLocations {
    static func knownCities(defaults: UserDefaults = .standard, tripsFile: URL = WeatherTripStore.defaultFile()) -> [String] {
        let trips = WeatherTripStore.load(file: tripsFile)
        let home = WeatherSettings.place(defaults: defaults)
        guard home != nil || !trips.isEmpty else { return [] }
        return PlaceNames.unique([home?.shortName ?? "Home"] + trips.map(\.shortName))
    }

    /// The city as the app names it (its own spelling), for a name a person or model typed; nil if it isn't one of `known`.
    static func match(_ name: String, in known: [String]) -> String? {
        let key = PlaceNames.key(name)
        return known.first { PlaceNames.key($0) == key }
    }
}

/// Downloads and tops up the weather for a place. Only the years the history spans are fetched, each at most once; after that only
/// the new days are asked for. Each year is saved as it completes, so a stop part-way (offline, a limit, quitting) loses nothing.
enum WeatherUpdater {
    struct Summary: Equatable, Sendable {
        var requests = 0
        var yearsCompleted = 0
    }

    /// The archive is settled about five days behind; the days after are asked of the forecast service's recent history instead.
    static let archiveLagDays = 7
    /// A little time between requests: one per year, not a flood.
    static let pause: Duration = .milliseconds(250)

    /// The last hour the archive is asked for: the end of the UTC day `archiveLagDays` days ago.
    static func archiveLimitHour(now: Date) -> Int {
        let day = WeatherSeries.hour(of: now) / 24 - archiveLagDays
        return day * 24 + 23
    }

    /// Downloads the weather for `place` from the day of `firstPlay` through `through` (nil: up to now). A trip passes the dates it covers,
    /// so only those days are asked for; home passes its first play.
    static func update(
        place: WeatherPlace, firstPlay: Date, through: Date? = nil, now: Date = Date(), client: WeatherClient, files: WeatherFiles,
        pause: Duration = WeatherUpdater.pause, progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> Summary {
        var summary = Summary()
        // A place that is only a typed name has no weather to ask for.
        guard place.hasCoordinates else { return summary }
        // `through` is where a trip ends (the start of the day after its last): the last hour wanted is the one before it.
        let end = min(now, through.map { $0.addingTimeInterval(-1) } ?? now)
        let realNowHour = WeatherSeries.hour(of: now)
        let nowHour = WeatherSeries.hour(of: end)
        let limit = archiveLimitHour(now: now)
        let utc = WeatherClientCalendar.utc
        let firstYear = utc.component(.year, from: firstPlay)
        let lastYear = utc.component(.year, from: end)
        guard firstPlay <= end, firstYear <= lastYear else { return summary }
        let firstPlayDayStart = (WeatherSeries.hour(of: firstPlay) / 24) * 24

        for year in firstYear...lastYear {
            try Task.checkCancellation()
            let yearStart = WeatherSeries.hour(of: utc.date(from: DateComponents(year: year, month: 1, day: 1))!)
            let yearEnd = WeatherSeries.hour(of: utc.date(from: DateComponents(year: year + 1, month: 1, day: 1))!) - 1
            var series = files.load(place, year: year) ?? WeatherSeries(startHour: yearStart, count: yearEnd - yearStart + 1)
            if series.startHour != yearStart || series.count != yearEnd - yearStart + 1 {
                series = WeatherSeries(startHour: yearStart, count: yearEnd - yearStart + 1)   // a file that doesn't fit this year is started over
            }
            var changed = false
            progress("Weather for \(year)")

            // Settled history from the archive.
            let archiveTarget = min(yearEnd, limit, nowHour)
            // From the end of what the archive has already given, not of what was asked for at all: the last days of an earlier update came
            // from the recent source, whose values the archive later replaces.
            let fromHour = max(series.settledThroughHour == Int.min ? yearStart : series.settledThroughHour + 1, yearStart, firstPlayDayStart)
            if archiveTarget >= fromHour, archiveTarget > series.settledThroughHour {
                if summary.requests > 0 { try await Task.sleep(for: pause) }
                let hours = try await client.fetchArchive(place: place, from: WeatherSeries.date(ofHour: fromHour), to: WeatherSeries.date(ofHour: archiveTarget))
                summary.requests += 1
                for (hour, sample) in hours where hour >= fromHour && hour <= archiveTarget { series.set(hour: hour, sample) }
                series.settledThroughHour = archiveTarget
                series.coveredThroughHour = max(series.coveredThroughHour, archiveTarget)
                changed = true
            }

            // The last days, which the archive doesn't have yet (only in the current year).
            if year == lastYear, series.coveredThroughHour < nowHour {
                // From the end of what is covered, or (nothing yet) from the first day wanted: not from January, which for a trip begun
                // last week made the request look 300 days long and be skipped.
                let wantedFrom = max(yearStart, firstPlayDayStart)
                // From the first hour the archive has not settled, so the recent source's earlier answers are asked for again.
                let recentFrom = series.settledThroughHour == Int.min ? wantedFrom : max(series.settledThroughHour + 1, wantedFrom)
                let days = (realNowHour - recentFrom) / 24 + 2
                if days <= 92 {
                    if summary.requests > 0 { try await Task.sleep(for: pause) }
                    let hours = try await client.fetchRecent(place: place, pastDays: days)
                    summary.requests += 1
                    for (hour, sample) in hours where hour >= recentFrom && hour <= nowHour { series.set(hour: hour, sample) }
                    series.coveredThroughHour = nowHour
                    changed = true
                }
            }

            if changed { files.save(series, place: place, year: year) }
            summary.yearsCompleted += 1
        }
        return summary
    }
}

enum WeatherClientCalendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

/// What Settings shows about the weather download, and the thing that starts it: when weather is turned on, a place is chosen, the
/// app opens, or a sync finishes (at most twice a day, and never in Offline mode).
@MainActor
@Observable
final class WeatherStatus {
    static let shared = WeatherStatus()

    enum State: Equatable {
        case idle
        case updating(String)
        case failed(String)
        case waitingForConnection
    }

    private(set) var state = State.idle
    private(set) var lastUpdatedAt: Date?
    private(set) var coverageText: String?
    private(set) var bytesOnDisk = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Twice a day is plenty: the archive moves a day at a time.
    static let minimumInterval: TimeInterval = 12 * 3600

    init() {
        lastUpdatedAt = UserDefaults.standard.object(forKey: WeatherSettings.lastUpdateKey) as? Date
    }

    func start(container: ModelContainer) {
        self.container = container
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .scrobbleSyncDidFinish, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update(force: false) }
        })
        // Back online after Offline mode: carry on with a download that was waiting, without needing a sync to start it.
        observers.append(NotificationCenter.default.addObserver(forName: .connectivityDidResume, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update(force: false) }
        })
        refreshCoverage()
        // A little after launch, so the window comes up first.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.update(force: false)
        }
    }

    var isEnabled: Bool { WeatherSettings.isEnabled() && WeatherSettings.place() != nil }

    /// Starts a download if weather is on and a place is chosen. `force` skips the twice-a-day limit (turning weather on, choosing a place).
    func update(force: Bool) {
        guard isEnabled, let place = WeatherSettings.place(), let container else { return }
        // A download is already running: a change made meanwhile (a trip added, a place chosen) must not be dropped, so it runs again after.
        guard task == nil else { if force { rerunRequested = true }; return }
        if !force, let last = lastUpdatedAt, Date().timeIntervalSince(last) < Self.minimumInterval { return }
        if ConnectivityGate.isOffline { state = .waitingForConnection; return }
        state = .updating("Starting…")
        let status = self
        task = Task { @MainActor [weak self] in
            defer {
                self?.task = nil
                if self?.rerunRequested == true { self?.rerunRequested = false; self?.update(force: true) }
            }
            do {
                guard let first = try await TopChartsEngine.fetchOldestScrobbleDate(container: container) else {
                    self?.state = .idle
                    return
                }
                var summary = try await WeatherUpdater.update(place: place, firstPlay: first, client: WeatherClient(), files: WeatherFiles(), progress: { text in
                    Task { @MainActor in status.state = .updating(text) }
                })
                // Then each trip, from its own dates: the days away, not the whole history.
                let trips = WeatherTripStore.load()
                for trip in trips where trip.from <= Date() && trip.place.hasCoordinates {
                    let tripSummary = try await WeatherUpdater.update(
                        place: trip.place, firstPlay: trip.from, through: trip.until, client: WeatherClient(),
                        files: WeatherFiles(directory: WeatherTripStore.cacheDirectory(for: trip)),
                        progress: { text in Task { @MainActor in status.state = .updating("\(trip.shortName): \(text)") } }
                    )
                    summary.requests += tripSummary.requests
                }
                Self.removeCaches(ofTripsNotIn: trips)
                UserDefaults.standard.set(Date(), forKey: WeatherSettings.lastUpdateKey)
                self?.lastUpdatedAt = Date()
                self?.state = .idle
                ActivityLog.record(.network, "Weather updated (\(summary.requests) request\(summary.requests == 1 ? "" : "s"))")
                NotificationCenter.default.post(name: .weatherDidUpdate, object: nil)
            } catch WeatherError.offline {
                self?.state = .waitingForConnection
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(describeWeatherError(error))
                ActivityLog.record(.network, "Weather update failed: \(describeWeatherError(error))")
            }
            self?.refreshCoverage()
        }
    }

    func stop() { task?.cancel() }

    /// Forgets the downloaded weather of trips that were removed (their folders are named by trip).
    nonisolated static func removeCaches(ofTripsNotIn trips: [WeatherTrip], base: URL = WeatherFiles().directory) {
        let folder = base.appending(path: "trips", directoryHint: .isDirectory)
        let keep = Set(trips.map(\.id.uuidString))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// Deletes everything downloaded, and forgets when it last ran.
    func removeDownloadedWeather() {
        task?.cancel()
        WeatherFiles().removeAll()
        UserDefaults.standard.removeObject(forKey: WeatherSettings.lastUpdateKey)
        lastUpdatedAt = nil
        state = .idle
        refreshCoverage()
        NotificationCenter.default.post(name: .weatherDidUpdate, object: nil)
    }

    func refreshCoverage() {
        let place = WeatherSettings.place()
        Task { @MainActor [weak self] in
            let result: (String?, Int) = await offMain {
                let files = WeatherFiles()
                guard let place, let series = files.timeline(place), let last = series.lastHourWithData else { return (nil, files.bytesOnDisk) }
                let first = WeatherClientCalendar.utc.component(.year, from: WeatherSeries.date(ofHour: series.startHour))
                let end = WeatherSeries.date(ofHour: last).formatted(date: .abbreviated, time: .omitted)
                return ("From \(first) to \(end)", files.bytesOnDisk)
            }
            self?.coverageText = result.0
            self?.bytesOnDisk = result.1
        }
    }
}

func describeWeatherError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

extension Notification.Name {
    /// Weather was downloaded, topped up or removed, so anything showing it should read it again.
    static let weatherDidUpdate = Notification.Name("WeatherDidUpdate")
}
