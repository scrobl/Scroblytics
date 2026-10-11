import Foundation
import Network
import Observation
import os

/// Thrown instead of making a network request while Offline mode is on. Callers treat it as "skip this, don't count it
/// as a failure, and don't record anything as missing".
struct OfflineError: Error, LocalizedError {
    var errorDescription: String? { "Offline mode is on. Go online to use this." }
}

extension Notification.Name {
    /// Offline mode was switched off: background lookups should pick their work back up.
    static let connectivityDidResume = Notification.Name("ConnectivityDidResume")
    /// Offline mode was switched on or off.
    static let offlineModeDidChange = Notification.Name("OfflineModeDidChange")
}

/// The synchronous answer to "may this code touch the network right now?", readable from any actor or thread.
enum ConnectivityGate {
    static let offlineModeKey = "offlineModeEnabled"

    private static let flag = OSAllocatedUnfairLock(initialState: UserDefaults.standard.bool(forKey: offlineModeKey))

    static var isOffline: Bool { flag.withLock { $0 } }

    static func set(offline: Bool) { flag.withLock { $0 = offline } }

    /// Addresses on this Mac, which Offline mode leaves alone (a local Ollama or compatible server).
    static func isLoopback(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    /// First line of every network call: throws `OfflineError` (and sends nothing) while Offline mode is on.
    static func check(host: String?) throws {
        if isOffline, !isLoopback(host: host) { throw OfflineError() }
    }

    /// Whether `error` means "couldn't connect at all" (as opposed to the server answering with an error).
    static func isConnectivityFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .timedOut, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }
}

extension ConnectivityGate {
    /// Whether `error` is, or wraps, "couldn't connect" (the clients wrap the system's `URLError` in their own cases).
    static func isConnectivityError(_ error: Error) -> Bool {
        if isConnectivityFailure(error) { return true }
        if let error = error as? LastfmAPIError, case .network(let underlying) = error { return isConnectivityFailure(underlying) }
        if let error = error as? DeezerAPIError, case .network(let underlying) = error { return isConnectivityFailure(underlying) }
        if let error = error as? MusicBrainzAPIError, case .network(let underlying) = error { return isConnectivityFailure(underlying) }
        return false
    }
}

/// Decides when a run of connection failures is worth asking the user about: not for one dropped request, but for a
/// burst across several kinds of lookup (what going offline looks like). Pure, so it can be tested with a fake clock.
struct ConnectivityPromptDecider {
    var window: TimeInterval = 2
    var snoozeSeconds: TimeInterval = 15 * 60
    private var events: [(at: Date, source: String)] = []
    private(set) var raised = false
    private var snoozedUntil: Date?
    private var suppressedForSession = false
    var pathUnsatisfied = false

    /// True exactly when a prompt should be shown now.
    mutating func record(source: String, now: Date) -> Bool {
        guard !raised, !suppressedForSession, (snoozedUntil ?? .distantPast) <= now else { return false }
        events.append((now, source))
        events.removeAll { now.timeIntervalSince($0.at) > window }
        let enough = Set(events.map(\.source)).count >= 2 || events.count >= 3 || pathUnsatisfied
        if enough {
            raised = true
            events = []
        }
        return enough
    }

    mutating func recordSuccess() { events = [] }

    mutating func answeredSwitched() { raised = false; events = [] }
    mutating func answeredNotNow(now: Date) { raised = false; events = []; snoozedUntil = now.addingTimeInterval(snoozeSeconds) }
    mutating func answeredDontAsk() { raised = false; events = []; suppressedForSession = true }
}

/// What the network code calls to report how a request went. Nonisolated, so actors and detached tasks can use it.
enum ConnectivityHub {
    private static let decider = OSAllocatedUnfairLock(initialState: ConnectivityPromptDecider())

    /// Call with the error a request threw (before wrapping it). Only connection failures to non-local hosts count.
    static func report(_ error: Error, host: String?, source: String) {
        guard !ConnectivityGate.isOffline, !ConnectivityGate.isLoopback(host: host), ConnectivityGate.isConnectivityFailure(error) else { return }
        let raise = decider.withLock { $0.record(source: source, now: Date()) }
        if raise { Task { @MainActor in Connectivity.shared.promptRaised() } }
    }

    static func reportSuccess() { decider.withLock { $0.recordSuccess() } }

    static func setPath(satisfied: Bool) { decider.withLock { $0.pathUnsatisfied = !satisfied } }
    static func answeredSwitched() { decider.withLock { $0.answeredSwitched() } }
    static func answeredNotNow() { decider.withLock { $0.answeredNotNow(now: Date()) } }
    static func answeredDontAsk() { decider.withLock { $0.answeredDontAsk() } }
}

/// The app-wide Offline mode state: one instance for every window.
@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var isOffline: Bool
    /// What the system says about having any network path at all (a hint; never switches the mode).
    private(set) var pathSatisfied = true
    /// A burst of connection failures was seen: ask the user whether to switch to Offline mode.
    private(set) var promptPending = false
    /// Offline mode is on but the Mac looks connected again.
    private(set) var backOnlineHintVisible = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var hintDismissed = false
    @ObservationIgnored private var resumeGeneration = 0
    @ObservationIgnored private var claimedGeneration = 0

    private init() {
        isOffline = UserDefaults.standard.bool(forKey: ConnectivityGate.offlineModeKey)
        ConnectivityGate.set(offline: isOffline)
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            ConnectivityHub.setPath(satisfied: satisfied)
            Task { @MainActor in Connectivity.shared.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "app.scroblytics.connectivity"))
    }

    func setOffline(_ offline: Bool) {
        guard offline != isOffline else { return }
        isOffline = offline
        UserDefaults.standard.set(offline, forKey: ConnectivityGate.offlineModeKey)
        ConnectivityGate.set(offline: offline)
        promptPending = false
        hintDismissed = false
        backOnlineHintVisible = offline && pathSatisfied
        NotificationCenter.default.post(name: .offlineModeDidChange, object: nil)
        if !offline {
            ConnectivityHub.answeredSwitched()
            resumeGeneration += 1
            NotificationCenter.default.post(name: .connectivityDidResume, object: nil)
        }
    }

    /// Several windows hear the "back online" notification; only the first to ask gets to start the catch-up sync.
    func claimResumeSync() -> Bool {
        guard claimedGeneration < resumeGeneration else { return false }
        claimedGeneration = resumeGeneration
        return true
    }

    func toggle() { setOffline(!isOffline) }

    // MARK: Prompt

    fileprivate func promptRaised() {
        guard !isOffline else { return }
        promptPending = true
    }

    func answerSwitchToOffline() {
        promptPending = false
        ConnectivityHub.answeredSwitched()
        setOffline(true)
    }

    func answerNotNow() {
        promptPending = false
        ConnectivityHub.answeredNotNow()
    }

    func answerDontAskAgain() {
        promptPending = false
        ConnectivityHub.answeredDontAsk()
    }

    // MARK: Back online hint

    func dismissBackOnlineHint() {
        hintDismissed = true
        backOnlineHintVisible = false
    }

    fileprivate func pathChanged(satisfied: Bool) {
        pathSatisfied = satisfied
        backOnlineHintVisible = isOffline && satisfied && !hintDismissed
    }
}
