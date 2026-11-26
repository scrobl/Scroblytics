import AppKit
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

/// What the app remembers about backups, in the preferences: when the last one was made, whether reminders are wanted, and the
/// optional automatic backup (on or off, and the folder it writes to). Nothing here is sent anywhere.
struct BackupPreferences {
    enum Key {
        static let lastAt = "backup.lastBackupAt"
        static let lastKind = "backup.lastBackupKind"
        static let remindersOn = "backup.reminders.on"
        static let snoozedUntil = "backup.reminders.snoozedUntil"
        static let dataFirstSeen = "backup.dataFirstSeenAt"
        static let automaticOn = "backup.auto.on"
        static let automaticFolder = "backup.auto.folder"
        static let automaticError = "backup.auto.lastError"
        static let automaticFingerprint = "backup.auto.fingerprint"
        static let upToDateAt = "backup.upToDateAt"
    }

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var lastBackupAt: Date? {
        get { defaults.object(forKey: Key.lastAt) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.lastAt) }
    }
    /// `"manual"` or `"automatic"`, for the line in Settings.
    var lastKind: String? {
        get { defaults.string(forKey: Key.lastKind) }
        nonmutating set { defaults.set(newValue, forKey: Key.lastKind) }
    }
    var remindersOn: Bool {
        get { defaults.object(forKey: Key.remindersOn) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.remindersOn) }
    }
    var snoozedUntil: Date? {
        get { defaults.object(forKey: Key.snoozedUntil) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.snoozedUntil) }
    }
    /// The first time the app saw that you had created something worth keeping; a person who has never backed up is reminded a
    /// couple of weeks after that, not on the first day.
    var dataFirstSeenAt: Date? {
        get { defaults.object(forKey: Key.dataFirstSeen) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.dataFirstSeen) }
    }
    var automaticOn: Bool {
        get { defaults.bool(forKey: Key.automaticOn) }
        nonmutating set { defaults.set(newValue, forKey: Key.automaticOn) }
    }
    var automaticFolderPath: String? {
        get { defaults.string(forKey: Key.automaticFolder) }
        nonmutating set { defaults.set(newValue, forKey: Key.automaticFolder) }
    }
    var automaticError: String? {
        get { defaults.string(forKey: Key.automaticError) }
        nonmutating set { defaults.set(newValue, forKey: Key.automaticError) }
    }
    /// What the newest automatic backup held (`NativeBackupEngine.fingerprint`), so a week with no changes writes no new file.
    var automaticFingerprint: String? {
        get { defaults.string(forKey: Key.automaticFingerprint) }
        nonmutating set { defaults.set(newValue, forKey: Key.automaticFingerprint) }
    }
    /// The last time an automatic check found nothing had changed since the newest backup: the data is as safe as that backup.
    var upToDateAt: Date? {
        get { defaults.object(forKey: Key.upToDateAt) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.upToDateAt) }
    }
}

/// What the strip under the toolbar can say.
enum BackupReminder: Equatable {
    case neverBackedUp
    case stale(days: Int)
    case automaticFailed(reason: String)

    var text: String {
        switch self {
        case .neverBackedUp:
            "You haven’t backed up what you’ve created in Scroblytics (corrections, saved queries, edits and so on)."
        case .stale(let days):
            "Your last Scroblytics backup was \(days) days ago."
        case .automaticFailed(let reason):
            "Automatic backup couldn’t run: \(reason)"
        }
    }
}

/// When to remind. A pure function of what is known, so every case can be checked without a window or a clock.
enum BackupReminderPolicy {
    /// A person who has never backed up is reminded this long after they first created something worth saving.
    static let neverBackedUpGrace: TimeInterval = 14 * 86_400
    /// A backup older than this is stale.
    static let staleAfter: TimeInterval = 30 * 86_400
    /// "Remind Me Later".
    static let snoozeLength: TimeInterval = 7 * 86_400
    /// An automatic backup that keeps failing is mentioned once the newest backup is this old (the weekly run missed once).
    static let automaticFailureAfter: TimeInterval = 8 * 86_400

    struct Input {
        var now: Date
        var lastBackupAt: Date?
        var dataFirstSeenAt: Date?
        var hasWorthSaving: Bool
        var remindersOn: Bool
        var snoozedUntil: Date?
        var automaticOn: Bool
        var automaticError: String?
    }

    static func reminder(for input: Input) -> BackupReminder? {
        // Nothing you created, nothing to lose: never nag.
        guard input.hasWorthSaving else { return nil }
        if let snoozed = input.snoozedUntil, snoozed > input.now { return nil }
        // A failing automatic backup is something the person asked for, so it is said even when reminders are off.
        if input.automaticOn, let reason = input.automaticError {
            let overdue = input.lastBackupAt.map { input.now.timeIntervalSince($0) >= automaticFailureAfter } ?? true
            if overdue { return .automaticFailed(reason: reason) }
        }
        guard input.remindersOn else { return nil }
        if let last = input.lastBackupAt {
            let age = input.now.timeIntervalSince(last)
            return age >= staleAfter ? .stale(days: Int(age / 86_400)) : nil
        }
        if let first = input.dataFirstSeenAt, input.now.timeIntervalSince(first) >= neverBackedUpGrace { return .neverBackedUp }
        return nil
    }
}

/// The optional automatic backup: a dated file in a folder the person chose, at most weekly and only when something has changed,
/// keeping the newest few. It uses the same backup as File › Back Up Scroblytics Data, reads each file back to be sure it is whole,
/// and never touches a file it didn't make (its names start with "Scroblytics Automatic Backup").
///
/// A backup holds your custom pictures, so it can be large; that is why it is written only when the content differs from the
/// newest one, and why only three are kept.
enum AutomaticBackupEngine {
    static let namePrefix = "Scroblytics Automatic Backup "
    static let fileExtension = "scroblyticsbackup"
    static let keep = 3
    static let interval: TimeInterval = 7 * 86_400

    enum Result: Equatable {
        case wrote(URL, items: Int, fingerprint: String)
        /// Nothing differs from the newest backup, so no new file was written.
        case unchanged(fingerprint: String)
        case notDue
        case nothingToSave
        case failed(String)
    }

    /// The files this feature made in a folder, newest first.
    static func files(in folder: URL, fileManager: FileManager = .default) -> [(url: URL, modified: Date, bytes: Int64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix(namePrefix) && $0.pathExtension == fileExtension }
            .map { url -> (URL, Date, Int64) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }
    }

    static func fileName(for date: Date, suffix: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let extra = suffix > 0 ? " \(suffix + 1)" : ""
        return namePrefix + formatter.string(from: date) + extra + "." + fileExtension
    }

    /// Reading the database and the pictures happens here, on the main actor; encoding, checking and writing happen off it.
    /// `force` skips both the weekly schedule and the "nothing changed" shortcut (Back Up Now).
    @MainActor
    static func run(
        context: ModelContext,
        folder: URL,
        now: Date = Date(),
        force: Bool = false,
        lastFingerprint: String? = nil,
        lastCheckedAt: Date? = nil,
        fileManager: FileManager = .default
    ) async -> Result {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed("the backup folder can’t be found. Choose it again in Settings.")
        }
        guard fileManager.isWritableFile(atPath: folder.path) else {
            return .failed("the backup folder can’t be written to. Choose another one in Settings.")
        }
        // Due is judged by the folder itself (and the last time it was found up to date), so choosing a new folder, or emptying it,
        // makes the next run write at once.
        let newest = files(in: folder, fileManager: fileManager).first
        if !force, let newest {
            let last = max(newest.modified, lastCheckedAt ?? .distantPast)
            if now.timeIntervalSince(last) < interval { return .notDue }
        }
        let archive: NativeBackupFormat.Archive
        do { archive = try NativeBackupEngine.makeArchive(context: context) } catch {
            return .failed("the backup couldn’t be made (\(error.localizedDescription)).")
        }
        let box = ArchiveBox(archive: archive)
        let hadBackup = newest != nil
        return await Task.detached(priority: .utility) {
            produce(box, folder: folder, now: now, force: force, lastFingerprint: lastFingerprint, hadBackup: hadBackup)
        }.value
    }

    private struct ArchiveBox: @unchecked Sendable { let archive: NativeBackupFormat.Archive }

    nonisolated private static func produce(_ box: ArchiveBox, folder: URL, now: Date, force: Bool, lastFingerprint: String?, hadBackup: Bool) -> Result {
        let fileManager = FileManager.default
        let archive = box.archive
        guard NativeBackupEngine.hasContent(archive) else { return .nothingToSave }
        let fingerprint: String
        do { fingerprint = try NativeBackupEngine.fingerprint(of: archive) } catch {
            return .failed("the backup couldn’t be made (\(error.localizedDescription)).")
        }
        if !force, hadBackup, fingerprint == lastFingerprint { return .unchanged(fingerprint: fingerprint) }
        let made: NativeBackupEngine.EncodedBackup
        do { made = try NativeBackupEngine.encodeVerified(archive) } catch {
            return .failed("the backup couldn’t be made (\(error.localizedDescription)).")
        }
        var suffix = 0
        var url = folder.appending(path: fileName(for: now, suffix: suffix))
        while fileManager.fileExists(atPath: url.path) {
            suffix += 1
            url = folder.appending(path: fileName(for: now, suffix: suffix))
        }
        do {
            try made.data.write(to: url, options: .atomic)
            // Mapped, so a large file isn't read into memory a second time just to be compared.
            guard try Data(contentsOf: url, options: .mappedIfSafe) == made.data else {
                try? fileManager.removeItem(at: url)
                return .failed("the file didn’t read back the same, so it was removed.")
            }
        } catch {
            try? fileManager.removeItem(at: url)
            return .failed("the backup couldn’t be saved (\(error.localizedDescription)).")
        }
        prune(folder: folder, keeping: url, fileManager: fileManager)
        return .wrote(url, items: made.summary.total, fingerprint: fingerprint)
    }

    /// Deletes this feature's files beyond the newest `keep`, never the one just written.
    static func prune(folder: URL, keeping newest: URL, fileManager: FileManager = .default) {
        let all = files(in: folder, fileManager: fileManager)
        for stale in all.dropFirst(keep) where stale.url.lastPathComponent != newest.lastPathComponent {
            try? fileManager.removeItem(at: stale.url)
        }
    }
}

/// What the strip, Settings and the launch task talk to: the state of backups on this Mac and the actions on it.
@MainActor
@Observable
final class BackupScheduler {
    static let shared = BackupScheduler()

    private let prefs: BackupPreferences
    private(set) var lastBackupAt: Date?
    /// The last time a check found nothing had changed since the newest backup.
    private(set) var upToDateAt: Date?
    private(set) var lastKind: String?
    private(set) var reminder: BackupReminder?
    private(set) var isWorking = false
    private(set) var automaticError: String?
    private(set) var automaticOn: Bool
    private(set) var folderPath: String?
    /// What the last button press did, for Settings to show.
    var message: String?

    var remindersOn: Bool {
        didSet {
            prefs.remindersOn = remindersOn
            guard !remindersOn else { return }
            // Turning reminders off hides the "it's been a while" kind at once; a failing automatic backup is still said.
            if case .automaticFailed? = reminder { return }
            reminder = nil
        }
    }

    init(defaults: UserDefaults = .standard) {
        prefs = BackupPreferences(defaults: defaults)
        lastBackupAt = prefs.lastBackupAt
        upToDateAt = prefs.upToDateAt
        lastKind = prefs.lastKind
        automaticError = prefs.automaticError
        automaticOn = prefs.automaticOn
        folderPath = prefs.automaticFolderPath
        remindersOn = prefs.remindersOn
    }

    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// How recent the data's safety is: the newest backup, or the last time nothing had changed since it.
    var coveredAt: Date? {
        switch (lastBackupAt, upToDateAt) {
        case (let a?, let b?): max(a, b)
        case (let a?, nil): a
        case (nil, let b?): b
        case (nil, nil): nil
        }
    }

    // MARK: - Bookkeeping

    /// Any successful backup, by hand or automatic.
    func recordBackup(manual: Bool, now: Date = Date()) {
        prefs.lastBackupAt = now
        prefs.lastKind = manual ? "manual" : "automatic"
        prefs.snoozedUntil = nil
        lastBackupAt = now
        lastKind = prefs.lastKind
        reminder = nil
    }

    func snooze(now: Date = Date()) {
        prefs.snoozedUntil = now.addingTimeInterval(BackupReminderPolicy.snoozeLength)
        reminder = nil
    }

    func turnOffReminders() {
        remindersOn = false
    }

    // MARK: - Reminder

    /// Works out whether the strip should show. The expensive part (looking for anything worth saving) only runs when a reminder
    /// could be due at all, so the common case, a recent backup, costs nothing.
    func refreshReminder(now: Date = Date(), hasWorthSaving: () -> Bool) {
        let timeDue = coveredAt.map { now.timeIntervalSince($0) >= BackupReminderPolicy.staleAfter } ?? true
        let automaticTrouble = automaticOn && automaticError != nil
        guard timeDue || automaticTrouble else { reminder = nil; return }
        let worth = hasWorthSaving()
        if worth, prefs.dataFirstSeenAt == nil { prefs.dataFirstSeenAt = now }
        reminder = BackupReminderPolicy.reminder(for: .init(
            now: now, lastBackupAt: coveredAt, dataFirstSeenAt: prefs.dataFirstSeenAt, hasWorthSaving: worth,
            remindersOn: remindersOn, snoozedUntil: prefs.snoozedUntil, automaticOn: automaticOn, automaticError: automaticError
        ))
    }

    // MARK: - Automatic backup

    /// Chooses the folder; true when one was chosen.
    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for Automatic Backups"
        panel.message = "Pick a folder that is itself backed up or on another disk, such as iCloud Drive or an external drive."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        setFolder(url)
        return true
    }

    func setFolder(_ url: URL) {
        prefs.automaticFolderPath = url.path
        folderPath = url.path
        setAutomaticError(nil)
    }

    /// Turns automatic backup on (choosing a folder first when there is none) or off. True when it ends up on.
    @discardableResult
    func setAutomatic(_ on: Bool) -> Bool {
        if on, folderPath == nil, !chooseFolder() { return false }
        prefs.automaticOn = on
        automaticOn = on
        if !on { setAutomaticError(nil) }
        return on
    }

    private func setAutomaticError(_ text: String?) {
        prefs.automaticError = text
        automaticError = text
    }

    /// The weekly run: writes a backup when the folder has none newer than a week and something has changed. Quiet unless something
    /// goes wrong.
    func runAutomaticIfDue(context: ModelContext, now: Date = Date(), force: Bool = false) async {
        guard automaticOn, let folder = folderURL, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let result = await AutomaticBackupEngine.run(context: context, folder: folder, now: now, force: force,
                                                     lastFingerprint: prefs.automaticFingerprint, lastCheckedAt: upToDateAt)
        apply(result, now: now, manual: false)
    }

    private func apply(_ result: AutomaticBackupEngine.Result, now: Date, manual: Bool) {
        switch result {
        case .wrote(_, let items, let fingerprint):
            prefs.automaticFingerprint = fingerprint
            recordBackup(manual: manual, now: now)
            setAutomaticError(nil)
            ActivityLog.record(.app, "Automatic backup written (\(items) items)")
        case .unchanged:
            prefs.upToDateAt = now
            upToDateAt = now
            setAutomaticError(nil)
        case .failed(let reason):
            setAutomaticError(reason)
            ActivityLog.record(.app, "Automatic backup failed: \(reason)")
        case .nothingToSave:
            setAutomaticError(nil)
        case .notDue:
            break
        }
    }

    // MARK: - Back up now

    /// The "Back Up Now" button: into the automatic folder when that is set up, otherwise a Save panel.
    func backUpNow(context: ModelContext, now: Date = Date()) async {
        message = nil
        guard automaticOn, let folder = folderURL else {
            saveWithPanel(context: context, now: now)
            return
        }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let result = await AutomaticBackupEngine.run(context: context, folder: folder, now: now, force: true,
                                                     lastFingerprint: prefs.automaticFingerprint, lastCheckedAt: upToDateAt)
        switch result {
        case .wrote(let url, let items, _):
            apply(result, now: now, manual: true)
            message = "Backup saved (\(items) items) in \(url.deletingLastPathComponent().lastPathComponent)."
        case .nothingToSave:
            message = "There’s nothing you’ve created yet to back up."
        case .failed(let reason):
            apply(result, now: now, manual: true)
            message = "Couldn’t save the backup: \(reason)"
        case .unchanged, .notDue:
            break
        }
    }

    private func saveWithPanel(context: ModelContext, now: Date) {
        do {
            let made = try NativeBackupEngine.makeVerifiedBackup(context: context)
            guard made.savesAnything else {
                message = "There’s nothing you’ve created yet to back up."
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.scroblyticsBackup]
            panel.canCreateDirectories = true
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            panel.nameFieldStringValue = "Scroblytics Backup \(formatter.string(from: now)).\(AutomaticBackupEngine.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try made.data.write(to: url, options: .atomic)
            recordBackup(manual: true, now: now)
            message = "Backup saved (\(made.summary.total) items)."
        } catch {
            message = "Couldn’t save the backup: \(error.localizedDescription)"
        }
    }

    // MARK: - Launch and long sessions

    /// What runs a little after launch and then every few hours while the app stays open: the automatic backup if it is due, then
    /// the reminder.
    func runLoop(container: ModelContainer) async {
        try? await Task.sleep(for: .seconds(20))
        while !Task.isCancelled {
            let context = container.mainContext
            await runAutomaticIfDue(context: context)
            refreshReminder { NativeBackupEngine.hasContentWorthSaving(context: context) }
            try? await Task.sleep(for: .seconds(6 * 3600))
        }
    }
}
