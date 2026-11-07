import Foundation
import Observation
import SwiftData

/// Runs the scrobbling check (`ScrobblerWatch`) and holds what the screen shows: the latest verdict, whether the warning is showing,
/// and why a check couldn't run. Off until the person turns it on. When on, it checks after a sync finishes (at most every 15 minutes),
/// and only when Music is already open: it never opens Music, never asks for permission by itself, and tells nobody outside the app.
/// A check reads only the songs Music played in the last few days (about half a second) and compares them with the history on this Mac.
@MainActor
@Observable
final class ScrobblerWatchStore {
    static let shared = ScrobblerWatchStore()

    private(set) var settings = ScrobblerWatch.Settings.load()
    private(set) var verdict: ScrobblerWatch.Verdict?
    private(set) var state = ScrobblerWatch.State()
    private(set) var lastCheckedAt: Date?
    private(set) var isChecking = false
    /// Why the last check couldn't run or finish, in plain words (Music closed, no permission); nil after a good one.
    private(set) var problem: String?

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    private static let firingKey = "scrobblerWatch.firing"
    private static let dismissedKey = "scrobblerWatch.dismissed"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = ScrobblerWatch.Settings.load(defaults: defaults)
        state = ScrobblerWatch.State(firing: defaults.bool(forKey: Self.firingKey), dismissed: defaults.bool(forKey: Self.dismissedKey))
    }

    /// True while the warning should be on screen.
    var isShowing: Bool { settings.enabled && verdict != nil && ScrobblerWatch.isShowing(state) }

    /// Starts listening for the end of a sync. Called once by the app window.
    func start(container: ModelContainer) {
        self.container = container
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .scrobbleSyncDidFinish, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check(force: false) }
        }
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        guard settings.enabled != on else { return }
        settings.enabled = on
        settings.save(defaults: defaults)
        problem = nil
        if on {
            check(force: true)
        } else {
            verdict = nil
            state = ScrobblerWatch.State()
            persistState()
        }
    }

    func setThreshold(_ value: Int) {
        settings.threshold = value
        settings = settings.clamped()
        settings.save(defaults: defaults)
        recheckSoon()
    }

    func setWindowDays(_ value: Int) {
        settings.windowDays = value
        settings = settings.clamped()
        settings.save(defaults: defaults)
        recheckSoon()
    }

    /// A changed setting is applied by checking again, once the person has stopped adjusting it.
    private func recheckSoon() {
        guard settings.enabled else { return }
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.check(force: true)
        }
    }

    // MARK: The warning

    /// "Dismiss": the warning stays away for as long as the problem continues, and comes back only after a check finds things healthy
    /// and then finds the problem again.
    func dismiss() {
        state.dismissed = true
        persistState()
    }

    func turnOff() { setEnabled(false) }

    private func persistState() {
        defaults.set(state.firing, forKey: Self.firingKey)
        defaults.set(state.dismissed, forKey: Self.dismissedKey)
    }

    // MARK: Checking

    /// Checks now (`force`) or when one is due. Does nothing when the check is off, one is running, the last was under 15 minutes ago, or
    /// Music isn't open.
    func check(force: Bool) {
        guard settings.enabled, !isChecking, let container else { return }
        if !force, let last = lastCheckedAt, Date().timeIntervalSince(last) < ScrobblerWatch.minimumInterval { return }
        guard AppleMusicFavoritesReader.isMusicRunning else {
            problem = "Music isn’t open, so there was nothing to check."
            return
        }
        isChecking = true
        let settings = settings
        Task { [weak self] in
            do {
                let recent = try await AppleMusicFavoritesReader.readRecentlyPlayed(days: settings.readDays)
                let (scrobbles, synced) = try await offMain {
                    let scrobbles = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
                    let synced = (try? ModelContext(container).fetch(FetchDescriptor<SyncState>()))?.first?.lastSyncedAt
                    return (scrobbles, synced)
                }
                let submitted = UnscrobbledPlaysLedger.load()
                let verdict = await Task.detached(priority: .utility) {
                    ScrobblerWatch.evaluate(recent: recent, scrobbles: scrobbles, syncedThrough: synced, submitted: submitted, settings: settings)
                }.value
                self?.apply(verdict)
            } catch {
                self?.fail(error)
            }
        }
    }

    private func apply(_ verdict: ScrobblerWatch.Verdict) {
        isChecking = false
        // Settings changed while the check ran: this answer is for the old ones, and a newer check is on its way.
        guard settings.enabled else { return }
        let (next, transition) = ScrobblerWatch.advance(state, with: verdict)
        state = next
        self.verdict = verdict
        lastCheckedAt = verdict.checkedAt
        problem = nil
        persistState()
        switch transition {
        case .began(let count)?:
            ActivityLog.record(.sync, "Scrobbling check: Music played \(count) songs in the last \(verdict.windowDays) days that aren’t in your Last.fm history (\(verdict.stillScrobblable) can still be scrobbled)")
        case .recovered?:
            ActivityLog.record(.sync, "Scrobbling check: caught up, Music’s recent plays are in your Last.fm history")
        case nil:
            break
        }
    }

    private func fail(_ error: Error) {
        isChecking = false
        problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The status line under the setting: when it last looked and what it found, or what stopped it.
    var statusText: String {
        if isChecking { return "Checking…" }
        if let problem { return problem }
        guard let lastCheckedAt, let verdict else { return "Not checked yet. It checks after each sync while Music is open." }
        let when = lastCheckedAt.formatted(.relative(presentation: .named))
        if verdict.count == 0 { return "Checked \(when): every song Music played in the last \(verdict.windowDays) days is in your history." }
        return "Checked \(when): \(verdict.count.formatted()) \(verdict.count == 1 ? "song" : "songs") Music played in the last \(verdict.windowDays) days \(verdict.count == 1 ? "isn’t" : "aren’t") in your history."
    }
}
