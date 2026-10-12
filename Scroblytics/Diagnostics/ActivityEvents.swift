import Foundation

/// Writes the app's own announcements (a sync started, finished or failed, Offline mode changed, the account changed) to the
/// activity log, so those events are recorded in one place instead of at every site that causes them. Records wording only: no
/// artist, album, track, tag or query text, and no account name.
@MainActor
enum ActivityEvents {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        ActivityLog.record(.app, "Launched Scroblytics \(version) (build \(build)), \(ProcessInfo.processInfo.operatingSystemVersionString), \(DiagnosticSummary.architecture), \(DiagnosticSummary.hardwareModel)")

        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ body: @escaping @Sendable (Notification) -> Void) {
            center.addObserver(forName: name, object: nil, queue: nil, using: body)
        }
        observe(.scrobbleSyncDidStart) { note in
            let first = (note.userInfo?["first"] as? Bool) == true
            ActivityLog.record(.sync, first ? "Sync started (the first import)" : "Sync started")
        }
        observe(.scrobbleSyncDidFinish) { _ in ActivityLog.record(.sync, "Sync finished") }
        observe(.scrobbleSyncDidComplete) { note in
            if let summary = note.object as? SyncSummary { ActivityLog.record(.sync, "Sync added \(summary.added) scrobbles\(summary.isComplete ? "" : " (not complete)")") }
        }
        observe(.scrobbleSyncDidFail) { note in
            guard let failure = note.object as? HistoryStatus.Failure else { return }
            ActivityLog.record(.sync, "Sync failed (\(failure.kind == .fixAccount ? "needs the account fixed" : "can be retried")): \(failure.message)")
        }
        observe(.scrobbleSyncDidStop) { _ in ActivityLog.record(.sync, "Sync stopped; what was imported is kept") }
        observe(.firstImportDidFinish) { _ in ActivityLog.record(.sync, "The first import finished") }
        observe(.lastfmCredentialsDidChange) { _ in ActivityLog.record(.account, "Last.fm account settings changed") }
        observe(.offlineModeDidChange) { _ in ActivityLog.record(.network, "Offline mode turned \(ConnectivityGate.isOffline ? "on" : "off")") }
    }
}
