import Foundation
import Observation

enum NowPlayingPreference {
    static let showsShelfKey = "showsNowPlayingShelf"

    /// Whether the shelf is switched on (View › Show Now Playing). On unless the user turned it off.
    static var isOn: Bool { UserDefaults.standard.object(forKey: showsShelfKey) as? Bool ?? true }
}

@MainActor
@Observable
final class NowPlayingStore {
    private(set) var track: NowPlayingTrack?

    private let pollingInterval: Duration = .seconds(15)
    private let staleInterval: TimeInterval = 120
    private var activeWindows: Set<UUID> = []
    private var pollingTask: Task<Void, Never>?
    private var lastSuccessfulRefresh: Date?
    private var consecutiveFailures = 0
    private var wasOn = NowPlayingPreference.isOn

    init() {
        // The View menu toggle is a plain preference; follow it directly so hiding the shelf also stops the polling.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceMayHaveChanged() }
        }
        NotificationCenter.default.addObserver(forName: .offlineModeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.offlineModeChanged() }
        }
        NotificationCenter.default.addObserver(forName: .lastfmCredentialsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.credentialsDidChange() }
        }
    }

    /// Offline mode switched on or off: stop (and clear) or resume.
    private func offlineModeChanged() {
        if ConnectivityGate.isOffline {
            track = nil
            lastSuccessfulRefresh = nil
            consecutiveFailures = 0
        }
        updatePolling()
    }

    /// The Last.fm account was added or removed: drop what's showing and look again straight away.
    func credentialsDidChange() {
        track = nil
        lastSuccessfulRefresh = nil
        consecutiveFailures = 0
        pollingTask?.cancel()
        pollingTask = nil
        updatePolling()
    }

    private func preferenceMayHaveChanged() {
        let isOn = NowPlayingPreference.isOn
        guard isOn != wasOn else { return }
        wasOn = isOn
        if !isOn {
            track = nil
            lastSuccessfulRefresh = nil
            consecutiveFailures = 0
        }
        updatePolling()
    }

    func setWindow(_ id: UUID, isActive: Bool) {
        if isActive {
            activeWindows.insert(id)
        } else {
            activeWindows.remove(id)
        }
        updatePolling()
    }

    func removeWindow(_ id: UUID) {
        activeWindows.remove(id)
        updatePolling()
    }

    private func updatePolling() {
        guard NowPlayingPreference.isOn, !ConnectivityGate.isOffline, !activeWindows.isEmpty else {
            pollingTask?.cancel()
            pollingTask = nil
            return
        }
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await refresh()
                let delaySeconds = min(15 * (1 << min(consecutiveFailures, 3)), 120)
                do {
                    try await Task.sleep(for: consecutiveFailures == 0 ? pollingInterval : .seconds(delaySeconds))
                } catch {
                    break
                }
            }
        }
    }

    private func refresh() async {
        guard let credentials = LastfmCredentialsStore.load() else {
            track = nil
            lastSuccessfulRefresh = nil
            consecutiveFailures = 0
            return
        }

        do {
            let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
            let fetched = try await client.fetchNowPlaying()
            // Hidden while the request was in flight: don't bring the track back.
            guard NowPlayingPreference.isOn, !ConnectivityGate.isOffline else { return }
            track = fetched
            lastSuccessfulRefresh = Date()
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            if let lastSuccessfulRefresh,
               Date().timeIntervalSince(lastSuccessfulRefresh) >= staleInterval {
                track = nil
            }
        }
    }
}
