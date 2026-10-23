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
    /// The weather a query reads, from what is saved on this Mac. Empty (and cheap) while weather is off or no place is chosen.
    static func load(defaults: UserDefaults = .standard, files: WeatherFiles = WeatherFiles()) -> WeatherSnapshot {
        guard WeatherSettings.isEnabled(defaults: defaults), let place = WeatherSettings.place(defaults: defaults),
              let series = files.timeline(place) else { return .empty }
        return WeatherSnapshot(series: series, placeName: place.name, percentiles: WeatherSettings.percentiles(defaults: defaults),
                               unit: WeatherSettings.temperatureUnit(defaults: defaults))
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

    static func update(
        place: WeatherPlace, firstPlay: Date, now: Date = Date(), client: WeatherClient, files: WeatherFiles,
        pause: Duration = WeatherUpdater.pause, progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> Summary {
        var summary = Summary()
        let nowHour = WeatherSeries.hour(of: now)
        let limit = archiveLimitHour(now: now)
        let utc = WeatherClientCalendar.utc
        let firstYear = utc.component(.year, from: firstPlay)
        let lastYear = utc.component(.year, from: now)
        guard firstYear <= lastYear else { return summary }
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
            let archiveTarget = min(yearEnd, limit)
            let fromHour = max(series.coveredThroughHour == Int.min ? yearStart : series.coveredThroughHour + 1, yearStart, firstPlayDayStart)
            if archiveTarget >= fromHour, archiveTarget > series.coveredThroughHour {
                if summary.requests > 0 { try await Task.sleep(for: pause) }
                let hours = try await client.fetchArchive(place: place, from: WeatherSeries.date(ofHour: fromHour), to: WeatherSeries.date(ofHour: archiveTarget))
                summary.requests += 1
                for (hour, sample) in hours where hour >= fromHour && hour <= archiveTarget { series.set(hour: hour, sample) }
                series.coveredThroughHour = archiveTarget
                changed = true
            }

            // The last days, which the archive doesn't have yet (only in the current year).
            if year == lastYear, series.coveredThroughHour < nowHour {
                let recentFrom = max(series.coveredThroughHour + 1, yearStart)
                let days = (nowHour - recentFrom) / 24 + 2
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
        guard isEnabled, let place = WeatherSettings.place(), let container, task == nil else { return }
        if !force, let last = lastUpdatedAt, Date().timeIntervalSince(last) < Self.minimumInterval { return }
        if ConnectivityGate.isOffline { state = .waitingForConnection; return }
        state = .updating("Starting…")
        let status = self
        task = Task { @MainActor [weak self] in
            defer { self?.task = nil }
            do {
                guard let first = try await TopChartsEngine.fetchOldestScrobbleDate(container: container) else {
                    self?.state = .idle
                    return
                }
                let summary = try await WeatherUpdater.update(place: place, firstPlay: first, client: WeatherClient(), files: WeatherFiles(), progress: { text in
                    Task { @MainActor in status.state = .updating(text) }
                })
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
