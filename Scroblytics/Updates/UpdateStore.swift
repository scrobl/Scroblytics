import AppKit
import Foundation
import Observation

/// What the app knows about newer versions: the settings (check automatically, which version was skipped), when it last
/// asked, and the newest release it has heard of. It only ever tells the person and opens the release page in their browser.
@MainActor
@Observable
final class UpdateStore {
    static let shared = UpdateStore()

    private enum Key {
        static let automatic = "updates.automaticChecks"
        static let lastChecked = "updates.lastCheckedAt"
        static let skipped = "updates.skippedVersion"
        static let knownTag = "updates.knownTag"
        static let knownURL = "updates.knownURL"
        static let knownPrerelease = "updates.knownPrerelease"
    }

    /// How often an automatic check may run.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let feedURL: URL
    private let currentVersion: AppVersion
    private let session: URLSession

    var automaticChecks: Bool {
        didSet { defaults.set(automaticChecks, forKey: Key.automatic) }
    }
    private(set) var lastCheckedAt: Date?
    private(set) var isChecking = false
    /// The newest release that is newer than this one, whether or not the person has skipped it.
    private(set) var newestKnown: ReleaseInfo?
    private var skippedVersion: AppVersion?
    private var dismissedThisSession = false

    init(defaults: UserDefaults = .standard, feedURL: URL? = nil, currentVersion: AppVersion = .running, session: URLSession = UpdateChecker.makeSession()) {
        self.defaults = defaults
        self.session = session
        var url = feedURL ?? UpdateFeed.defaultURL
        #if DEBUG
        if let override = TestProfile.updateFeedURLOverride { url = override }
        #endif
        self.feedURL = url
        self.currentVersion = currentVersion
        self.automaticChecks = defaults.object(forKey: Key.automatic) as? Bool ?? true
        self.lastCheckedAt = defaults.object(forKey: Key.lastChecked) as? Date
        self.skippedVersion = defaults.string(forKey: Key.skipped).flatMap(AppVersion.init)
        if let tag = defaults.string(forKey: Key.knownTag), let version = AppVersion(tag), version > currentVersion,
           let page = defaults.string(forKey: Key.knownURL), page.hasPrefix(UpdateFeed.releasePagePrefix), let pageURL = URL(string: page) {
            newestKnown = ReleaseInfo(version: version, tag: tag, pageURL: pageURL, isPrerelease: defaults.bool(forKey: Key.knownPrerelease))
        }
    }

    var current: AppVersion { currentVersion }

    /// The release to announce in the strip: newer than this one, not skipped, not dismissed for this session.
    var announced: ReleaseInfo? {
        guard let release = newestKnown, !dismissedThisSession, release.version != skippedVersion else { return nil }
        return release
    }

    // MARK: - Checking

    /// The quiet check at launch: only when allowed, due, and online; a failure is ignored (it is tried again next time).
    func checkAutomaticallyIfDue(now: Date = Date()) async {
        guard automaticChecks, !isChecking, !ConnectivityGate.isOffline else { return }
        if let last = lastCheckedAt, now.timeIntervalSince(last) < Self.checkInterval { return }
        _ = await runCheck(now: now)
    }

    /// A check the person asked for.
    @discardableResult
    func checkNow() async -> UpdateCheckResult {
        guard !isChecking else { return .failed("A check is already running.") }
        return await runCheck(now: Date())
    }

    private func runCheck(now: Date) async -> UpdateCheckResult {
        isChecking = true
        defer { isChecking = false }
        let result = await UpdateChecker.check(current: currentVersion, feedURL: feedURL, session: session)
        switch result {
        case .upToDate:
            record(checkedAt: now)
            forgetKnown()
        case .available(let release):
            record(checkedAt: now)
            remember(release)
        case .offline:
            break
        case .failed(let reason):
            ActivityLog.record(.update, "Update check failed: \(reason)")
        }
        #if DEBUG
        switch result {
        case .upToDate: TestProfile.log("UPDATE up to date (running \(currentVersion))")
        case .available(let release): TestProfile.log("UPDATE available \(release.version) (running \(currentVersion))")
        case .offline: TestProfile.log("UPDATE offline: nothing sent")
        case .failed(let reason): TestProfile.log("UPDATE check failed: \(reason)")
        }
        #endif
        return result
    }

    private func record(checkedAt date: Date) {
        lastCheckedAt = date
        defaults.set(date, forKey: Key.lastChecked)
    }

    private func remember(_ release: ReleaseInfo) {
        newestKnown = release
        defaults.set(release.tag, forKey: Key.knownTag)
        defaults.set(release.pageURL.absoluteString, forKey: Key.knownURL)
        defaults.set(release.isPrerelease, forKey: Key.knownPrerelease)
    }

    private func forgetKnown() {
        newestKnown = nil
        [Key.knownTag, Key.knownURL, Key.knownPrerelease].forEach { defaults.removeObject(forKey: $0) }
    }

    // MARK: - What the person does about it

    func skip(_ release: ReleaseInfo) {
        skippedVersion = release.version
        defaults.set(release.version.description, forKey: Key.skipped)
    }

    func dismissForNow() { dismissedThisSession = true }

    func viewRelease(_ release: ReleaseInfo) { NSWorkspace.shared.open(release.pageURL) }

    // MARK: - The menu command

    /// "Check for Updates…": checks now and answers in a standard alert, whatever the result.
    func checkNowAndTell() async {
        let result = await checkNow()
        let alert = NSAlert()
        switch result {
        case .upToDate:
            alert.messageText = "You’re up to date"
            alert.informativeText = "Scroblytics \(currentVersion) is the newest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .available(let release):
            alert.messageText = "Scroblytics \(release.version) is available"
            alert.informativeText = "You have \(currentVersion). The release page has the download and what changed. Updates are never installed automatically."
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Skip This Version")
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn: viewRelease(release)
            case .alertSecondButtonReturn: skip(release)
            default: break
            }
        case .offline:
            alert.messageText = "Offline mode is on"
            alert.informativeText = "Scroblytics can’t check for updates while Offline mode is on. Turn it off in Settings › General, then try again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .failed(let reason):
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = reason
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
