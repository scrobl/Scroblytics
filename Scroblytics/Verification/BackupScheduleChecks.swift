import CryptoKit
import Foundation
import SQLite3
import SwiftData

#if DEBUG
/// `SCROBLYTICS_BACKUPSCHEDULE_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the backup reminder, the optional automatic
/// backup and the safety copy taken before an update, on made-up data in temporary folders and a throwaway preferences suite. Nothing
/// here touches the real Application Support folder, the real preferences or a real backup. Exits 0 on success.
enum BackupScheduleChecks {
    /// `SCROBLYTICS_BACKUPSCHEDULE_REAL=1` with `SCROBLYTICS_STORE_PATH` on a COPY of a real database: times what the app does on the main
    /// actor (looking for anything worth saving, reading the data and pictures, then encoding, checking and writing a backup), writes an
    /// automatic backup into a temporary folder, and prints the counts and the peak memory, to be compared with independent `sqlite3`
    /// counts of the same copy. It also puts the album picture overrides back into the copy and checks every one comes back under the
    /// same key. It never calls the full restore, which would rewrite the real pictures folder and weather places.
    @MainActor
    static func runRealIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_BACKUPSCHEDULE_REAL"] != nil else { return }
        HeadlessTask.run("backupschedule-real") {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            func peakMegabytes() -> Int {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Int(usage.ru_maxrss) / 1_048_576
            }
            func elapsed(_ since: ContinuousClock.Instant) -> String {
                let d = ContinuousClock.now - since
                return String(format: "%.3f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            }
            let context = container.mainContext
            print("INFO  memory before anything: peak \(peakMegabytes()) MB")
            var start = ContinuousClock.now
            let worth = NativeBackupEngine.hasContentWorthSaving(context: context)
            print("INFO  memory after looking (a one-off read of the data and pictures): peak \(peakMegabytes()) MB")
            print("INFO  looking for anything worth saving took \(elapsed(start)) (worth saving: \(worth))")
            let folder = FileManager.default.temporaryDirectory.appending(path: "scroblytics-backupreal-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            start = ContinuousClock.now
            var ticks = 0
            var longest = 0.0
            // How long the main actor is unavailable while the backup runs: a timer that should tick every 20 ms.
            let watcher = Task { @MainActor in
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                    let now = ContinuousClock.now
                    let gap = now - last
                    longest = max(longest, Double(gap.components.seconds) + Double(gap.components.attoseconds) / 1e18)
                    last = now
                    ticks += 1
                }
            }
            let result = await AutomaticBackupEngine.run(context: context, folder: folder, now: Date(), force: true)
            watcher.cancel()
            print("INFO  reading, encoding, checking and writing a backup took \(elapsed(start)); the main actor's longest pause meanwhile was \(String(format: "%.0f", longest * 1000)) ms; peak memory \(peakMegabytes()) MB")
            guard case .wrote(let url, let items, let fingerprint) = result else {
                check("an automatic backup is written from the real-sized copy", result == .nothingToSave && !worth, "\(result)")
                HeadlessTask.finish(failures)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("INFO  the file is \(size) bytes, \(items) items")
            let archive = try NativeBackupEngine.makeArchive(context: context)
            print("INFO  \(NativeBackupEngine.hasContent(archive) ? "has content" : "empty"); fingerprint \(fingerprint.prefix(12))…")
            check("the fingerprint is the same for the same data (read again)", try NativeBackupEngine.fingerprint(of: archive) == fingerprint)
            start = ContinuousClock.now
            let again = await AutomaticBackupEngine.run(context: context, folder: folder, now: Date().addingTimeInterval(8 * 86_400), lastFingerprint: fingerprint)
            print("INFO  a week later with nothing changed took \(elapsed(start))")
            check("a week later nothing has changed, so no second file is written", again == .unchanged(fingerprint: fingerprint) && AutomaticBackupEngine.files(in: folder).count == 1, "\(again)")
            let read = try NativeBackupEngine.inspect(document: NativeBackupDocument(data: try Data(contentsOf: url, options: .mappedIfSafe)))
            check("the written file reads back with the same counts as the data", read.1.description == (try NativeBackupEngine.makeVerifiedBackup(context: context)).summary.description)

            // Album picture overrides: every one comes back under the key the app finds it by.
            let before = try context.fetch(FetchDescriptor<AlbumImageOverride>())
            let keysBefore = Set(before.map(\.identityKey))
            let filenames = Dictionary(uniqueKeysWithValues: before.map { ($0.identityKey, $0.filename) })
            for item in before { context.delete(item) }
            NativeBackupEngine.restoreAlbumImageOverrides(read.0.albumImages, context: context)
            try context.save()
            let after = try context.fetch(FetchDescriptor<AlbumImageOverride>())
            print("INFO  album picture overrides: \(before.count) before, \(after.count) after putting them back")
            check("every album picture override comes back under the same key (none lost, none re-keyed)", Set(after.map(\.identityKey)) == keysBefore && after.count == before.count)
            check("…each with the same picture file", after.allSatisfy { filenames[$0.identityKey] == $0.filename })
            HeadlessTask.finish(failures)
        }
    }

    @MainActor
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_BACKUPSCHEDULE_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let manager = FileManager.default
            let root = manager.temporaryDirectory.appending(path: "scroblytics-backupsched-\(UUID().uuidString)")
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: root) }
            func freshDefaults() -> UserDefaults {
                let name = "scroblytics.backupsched.check.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: name)!
                defaults.removePersistentDomain(forName: name)
                return defaults
            }
            func folder(_ label: String) -> URL {
                let url = root.appending(path: label, directoryHint: .isDirectory)
                try? manager.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            }
            // Whole seconds, so sums and differences of days are exact.
            let now = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
            let day: TimeInterval = 86_400
            func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }
            func setModified(_ url: URL, _ date: Date) { try? manager.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }

            // MARK: When to remind
            func reminder(last: Date? = nil, first: Date? = nil, worth: Bool = true, on: Bool = true, snoozed: Date? = nil, auto: Bool = false, error: String? = nil) -> BackupReminder? {
                BackupReminderPolicy.reminder(for: .init(now: now, lastBackupAt: last, dataFirstSeenAt: first, hasWorthSaving: worth, remindersOn: on,
                                                         snoozedUntil: snoozed, automaticOn: auto, automaticError: error))
            }
            check("nothing created, nothing to remind about, however old the last backup", reminder(last: ago(400), worth: false) == nil && reminder(first: ago(90), worth: false) == nil)
            check("never backed up: quiet for the first two weeks after creating something", reminder(first: ago(3)) == nil && reminder(first: ago(13.9)) == nil)
            check("never backed up: a reminder after two weeks", reminder(first: ago(14)) == .neverBackedUp && reminder(first: ago(60)) == .neverBackedUp)
            check("never backed up and the data was never seen: no reminder yet", reminder(first: nil) == nil)
            check("a backup under a month old: quiet", reminder(last: ago(1)) == nil && reminder(last: ago(29.9)) == nil)
            check("a month old or more: a reminder that says how many days", reminder(last: ago(30)) == .stale(days: 30) && reminder(last: ago(41)) == .stale(days: 41))
            check("reminders off: nothing, even when stale or never done", reminder(last: ago(200), on: false) == nil && reminder(first: ago(90), on: false) == nil)
            check("remind me later hides it until the day it ends", reminder(last: ago(60), snoozed: now.addingTimeInterval(day)) == nil
                  && reminder(last: ago(60), snoozed: now.addingTimeInterval(-1)) == .stale(days: 60))
            check("an automatic backup that keeps failing is said once the newest backup is over a week old",
                  reminder(last: ago(9), auto: true, error: "folder missing") == .automaticFailed(reason: "folder missing"))
            check("…but not while the last backup is recent (one miss is not a problem)", reminder(last: ago(3), auto: true, error: "folder missing") == nil)
            check("…even with reminders off, since the person asked for the automatic backup", reminder(last: ago(9), on: false, auto: true, error: "x") == .automaticFailed(reason: "x"))
            check("…and when there has never been a backup", reminder(last: nil, auto: true, error: "x") == .automaticFailed(reason: "x"))
            check("an error from an automatic backup that is switched off is ignored", reminder(last: ago(9), auto: false, error: "x") == nil)
            check("remind me later also hides a failure", reminder(last: ago(9), snoozed: now.addingTimeInterval(day), auto: true, error: "x") == nil)
            check("the reminder text names the days and the reason", BackupReminder.stale(days: 41).text.contains("41 days")
                  && BackupReminder.automaticFailed(reason: "folder missing").text.contains("folder missing"))

            // MARK: The scheduler's bookkeeping
            do {
                let defaults = freshDefaults()
                let scheduler = BackupScheduler(defaults: defaults)
                var asked = 0
                scheduler.refreshReminder(now: now) { asked += 1; return true }
                check("with no backup yet the first look records when you first had something worth saving, and says nothing yet", scheduler.reminder == nil && asked == 1)
                scheduler.refreshReminder(now: now.addingTimeInterval(15 * day)) { true }
                check("…and two weeks later asks you to back up", scheduler.reminder == .neverBackedUp)
                check("…the first-seen date is kept, not reset by later looks", (defaults.object(forKey: BackupPreferences.Key.dataFirstSeen) as? Date) == now)
                scheduler.snooze(now: now.addingTimeInterval(15 * day))
                check("Remind Me Later hides the strip at once", scheduler.reminder == nil)
                scheduler.refreshReminder(now: now.addingTimeInterval(16 * day)) { true }
                check("…and it stays hidden for a week", scheduler.reminder == nil)
                scheduler.refreshReminder(now: now.addingTimeInterval(23 * day)) { true }
                check("…then comes back", scheduler.reminder == .neverBackedUp)
                scheduler.recordBackup(manual: true, now: now.addingTimeInterval(23 * day))
                check("a backup clears the strip, records the date and the way it was made, and ends a snooze",
                      scheduler.reminder == nil && scheduler.lastBackupAt == now.addingTimeInterval(23 * day) && scheduler.lastKind == "manual"
                      && defaults.object(forKey: BackupPreferences.Key.snoozedUntil) == nil)
                asked = 0
                scheduler.refreshReminder(now: now.addingTimeInterval(30 * day)) { asked += 1; return true }
                check("with a recent backup the data isn't even looked at", scheduler.reminder == nil && asked == 0)
                scheduler.refreshReminder(now: now.addingTimeInterval(60 * day)) { true }
                check("a month after it, it is stale", scheduler.reminder == .stale(days: 37))
                scheduler.turnOffReminders()
                check("Turn Off Reminders hides the strip and is remembered", scheduler.reminder == nil && !BackupScheduler(defaults: defaults).remindersOn)
                let reopened = BackupScheduler(defaults: defaults)
                check("a new session sees what was saved", reopened.lastBackupAt == now.addingTimeInterval(23 * day) && reopened.lastKind == "manual")
            }

            // MARK: The automatic backup
            let schema = Schema(AppSchema.modelTypes)
            guard let container = try? ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)) else {
                check("an in-memory database can be made for the test", false)
                print("\(failures + 1) CHECK(S) FAILED"); exit(1)
            }
            let context = container.mainContext
            let empty = folder("auto-empty")
            // Weather trips live in a file in the real Application Support folder, not the database; a Mac that has some saved would make
            // an "empty" database look non-empty, so those two checks only run where there are none.
            if WeatherTripStore.load().isEmpty {
                check("an empty database makes no file (nothing to save)", await AutomaticBackupEngine.run(context: context, folder: empty, now: now) == .nothingToSave && (try? manager.contentsOfDirectory(atPath: empty.path))?.isEmpty == true)
                check("nothing created counts as nothing worth saving", !NativeBackupEngine.hasContentWorthSaving(context: context))
            } else {
                print("SKIP  the empty-database checks (this Mac has saved weather trips, which every backup includes)")
            }

            for index in 0..<3 { context.insert(FlaggedTrack(artist: "Artist A", track: "Track \(index)", album: nil, flaggedAt: now)) }
            try? context.save()
            check("flagged tracks count as something worth saving", NativeBackupEngine.hasContentWorthSaving(context: context))

            let target = folder("auto")
            var firstFile: URL?
            if case .wrote(let url, let items, _) = await AutomaticBackupEngine.run(context: context, folder: target, now: now) {
                firstFile = url
                check("a backup is written with the date in its name", url.lastPathComponent == AutomaticBackupEngine.fileName(for: now) && url.lastPathComponent.hasPrefix("Scroblytics Automatic Backup "))
                check("…it counts what was saved", items == 3)
                let data = (try? Data(contentsOf: url)) ?? Data()
                let inspected = try? NativeBackupEngine.inspect(document: NativeBackupDocument(data: data))
                check("…it reads back as a backup with the same content", inspected?.1.flaggedTracks == 3 && inspected?.0.format == "Scroblytics Native Backup")
                check("…nothing but the file is left in the folder (no partial file)", (try? manager.contentsOfDirectory(atPath: target.path)) == [url.lastPathComponent])
            } else {
                check("a backup is written", false)
            }
            setModified(firstFile ?? target, now)
            check("a second run the same day isn't due", await AutomaticBackupEngine.run(context: context, folder: target, now: now.addingTimeInterval(3_600)) == .notDue)
            check("…six days later still not", await AutomaticBackupEngine.run(context: context, folder: target, now: now.addingTimeInterval(6 * day)) == .notDue)
            if case .wrote(let url, _, _) = await AutomaticBackupEngine.run(context: context, folder: target, now: now.addingTimeInterval(8 * day)) {
                check("…a week later it writes the next one", url != firstFile)
            } else {
                check("a week later it writes the next one", false)
            }
            if case .wrote(let url, _, _) = await AutomaticBackupEngine.run(context: context, folder: target, now: now.addingTimeInterval(8 * day), force: true) {
                check("two backups in the same minute get different names, nothing is overwritten", url.lastPathComponent.hasSuffix(" 2.scroblyticsbackup") && manager.fileExists(atPath: url.path))
            } else {
                check("two backups in the same minute get different names", false)
            }

            // Keeping the newest five, and only this feature's own files.
            let pruneFolder = folder("auto-prune")
            for index in 0..<8 {
                let url = pruneFolder.appending(path: AutomaticBackupEngine.fileName(for: ago(Double(40 - index * 3))))
                try? Data("old \(index)".utf8).write(to: url)
                setModified(url, ago(Double(40 - index * 3)))
            }
            let manualName = pruneFolder.appending(path: "Scroblytics Backup 2026-01-01.scroblyticsbackup")
            let noteName = pruneFolder.appending(path: "notes.txt")
            try? Data("mine".utf8).write(to: manualName)
            try? Data("mine".utf8).write(to: noteName)
            setModified(manualName, ago(300))
            setModified(noteName, ago(300))
            let written = await AutomaticBackupEngine.run(context: context, folder: pruneFolder, now: now, force: true)
            let remaining = AutomaticBackupEngine.files(in: pruneFolder)
            check("after a new backup only the newest three of the feature's files remain", remaining.count == AutomaticBackupEngine.keep, "\(remaining.count)")
            if case .wrote(let url, _, _) = written { check("…and the new one is among them", remaining.contains { $0.url.lastPathComponent == url.lastPathComponent }) }
            check("…the oldest ones were the ones deleted (nothing older than 22 days is left)", remaining.allSatisfy { $0.modified >= ago(22.5) })
            check("a backup you saved yourself in the same folder, and other files, are never touched", manager.fileExists(atPath: manualName.path) && manager.fileExists(atPath: noteName.path))

            // Failures say what's wrong and never throw.
            let missing = root.appending(path: "no-such-folder", directoryHint: .isDirectory)
            if case .failed(let reason) = await AutomaticBackupEngine.run(context: context, folder: missing, now: now) { check("a missing folder is a plain failure", reason.contains("can’t be found")) } else { check("a missing folder is a plain failure", false) }
            let locked = folder("auto-locked")
            try? manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            if case .failed(let reason) = await AutomaticBackupEngine.run(context: context, folder: locked, now: now) { check("a folder that can't be written to is a plain failure", reason.contains("can’t be written")) } else { check("a folder that can't be written to is a plain failure", false) }
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)

            // Through the scheduler.
            do {
                let defaults = freshDefaults()
                let scheduler = BackupScheduler(defaults: defaults)
                let good = folder("sched-good")
                await scheduler.runAutomaticIfDue(context: context, now: now)
                check("automatic backup does nothing while it is off", AutomaticBackupEngine.files(in: good).isEmpty && scheduler.lastBackupAt == nil)
                scheduler.setFolder(good)
                check("turning it on with a folder chosen works and is remembered", scheduler.setAutomatic(true) && BackupScheduler(defaults: defaults).automaticOn && BackupScheduler(defaults: defaults).folderPath == good.path)
                await scheduler.runAutomaticIfDue(context: context, now: now)
                check("a due run writes a file and records an automatic backup", AutomaticBackupEngine.files(in: good).count == 1 && scheduler.lastKind == "automatic" && scheduler.lastBackupAt == now && scheduler.automaticError == nil)
                await scheduler.runAutomaticIfDue(context: context, now: now.addingTimeInterval(day))
                check("the next day nothing more is written", AutomaticBackupEngine.files(in: good).count == 1)
                scheduler.setFolder(missing)
                await scheduler.runAutomaticIfDue(context: context, now: now.addingTimeInterval(10 * day))
                check("a folder that has gone is recorded as an error the Settings page and strip can show", scheduler.automaticError != nil)
                scheduler.refreshReminder(now: now.addingTimeInterval(10 * day)) { true }
                check("…and the strip says automatic backup couldn't run (the last backup is 10 days old)", { if case .automaticFailed? = scheduler.reminder { return true } else { return false } }())
                scheduler.setFolder(good)
                check("choosing a folder again clears the error", scheduler.automaticError == nil)
                await scheduler.backUpNow(context: context, now: now.addingTimeInterval(11 * day))
                check("Back Up Now with automatic backup set up writes into that folder, counted as a backup you made",
                      AutomaticBackupEngine.files(in: good).count == 2 && scheduler.lastKind == "manual" && scheduler.message?.contains("Backup saved") == true)
                _ = scheduler.setAutomatic(false)
                check("turning it off is remembered and clears errors", !BackupScheduler(defaults: defaults).automaticOn && scheduler.automaticError == nil)
            }

            // Nothing changed since the last backup: no new file.
            do {
                let quiet = folder("auto-unchanged")
                var print1 = ""
                if case .wrote(_, _, let fp) = await AutomaticBackupEngine.run(context: context, folder: quiet, now: now) { print1 = fp }
                check("a backup reports a fingerprint of what it holds", print1.count == 64)
                let a = try? NativeBackupEngine.makeArchive(context: context)
                let b = try? NativeBackupEngine.makeArchive(context: context)
                check("the fingerprint ignores when the backup was made", a != nil && b != nil && (try? NativeBackupEngine.fingerprint(of: a!)) == (try? NativeBackupEngine.fingerprint(of: b!)) && (try? NativeBackupEngine.fingerprint(of: a!)) == print1)
                if var withPicture = a {
                    let plain = try? NativeBackupEngine.fingerprint(of: withPicture)
                    withPicture.images["x.png"] = Data([1, 2, 3])
                    let one = try? NativeBackupEngine.fingerprint(of: withPicture)
                    withPicture.images["x.png"] = Data([1, 2, 4])
                    let two = try? NativeBackupEngine.fingerprint(of: withPicture)
                    check("adding a picture, or replacing one with different bytes, changes the fingerprint", plain != one && one != two && plain != two)
                }
                let week = now.addingTimeInterval(8 * day)
                check("a week later with nothing changed, no file is written", await AutomaticBackupEngine.run(context: context, folder: quiet, now: week, lastFingerprint: print1) == .unchanged(fingerprint: print1) && AutomaticBackupEngine.files(in: quiet).count == 1)
                check("…and having looked, it waits another week", await AutomaticBackupEngine.run(context: context, folder: quiet, now: week.addingTimeInterval(3 * day), lastFingerprint: print1, lastCheckedAt: week) == .notDue)
                var forced = false
                if case .wrote = await AutomaticBackupEngine.run(context: context, folder: quiet, now: week, force: true, lastFingerprint: print1) { forced = true }
                check("Back Up Now writes even when nothing has changed", forced)
                for file in AutomaticBackupEngine.files(in: quiet) { try? manager.removeItem(at: file.url) }
                var rewritten = false
                if case .wrote = await AutomaticBackupEngine.run(context: context, folder: quiet, now: week, lastFingerprint: print1) { rewritten = true }
                check("a folder emptied since is written to again, even with nothing changed", rewritten)
                context.insert(FlaggedTrack(artist: "Artist B", track: "A change", album: nil, flaggedAt: now))
                try? context.save()
                var changedPrint = ""
                if case .wrote(_, _, let fp) = await AutomaticBackupEngine.run(context: context, folder: quiet, now: week.addingTimeInterval(8 * day), lastFingerprint: print1) { changedPrint = fp }
                check("a change makes the next due backup write a new file", !changedPrint.isEmpty && changedPrint != print1)
            }

            // A restored picture override is found again by the app (its key), and editions keep their own.
            do {
                guard let roundTrip = try? ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)) else {
                    check("a second in-memory database can be made", false); print("\(failures + 1) CHECK(S) FAILED"); exit(1)
                }
                let rtc = roundTrip.mainContext
                let albums = ["Album One", "Album One - Single", "Album One (Deluxe Edition)"]
                let keys = albums.map { TextNormalization.albumArtworkIdentityKey(artist: "Artist A", album: $0) }
                for (album, key) in zip(albums, keys) { rtc.insert(AlbumImageOverride(identityKey: key, artist: "Artist A", album: album, filename: "check-\(UUID().uuidString).png")) }
                try? rtc.save()
                let archive = try? NativeBackupEngine.makeArchive(context: rtc)
                check("the backup lists each album picture override", archive?.albumImages.count == 3)
                for item in (try? rtc.fetch(FetchDescriptor<AlbumImageOverride>())) ?? [] { rtc.delete(item) }
                NativeBackupEngine.restoreAlbumImageOverrides(archive?.albumImages ?? [], context: rtc)
                try? rtc.save()
                let restored = (try? rtc.fetch(FetchDescriptor<AlbumImageOverride>())) ?? []
                check("restoring them puts back three, under the keys the app finds them by", Set(restored.map(\.identityKey)) == Set(keys) && restored.count == 3, "\(restored.map(\.identityKey))")
                check("…so an edition and its plain album keep separate pictures", Set(restored.map(\.filename)).count == 3)
            }

            // MARK: The safety copy before an update
            let appFolder = folder("app-folder")
            let storeURL = appFolder.appending(path: "Scroblytics.store")
            do {
                var fixture: ModelContainer? = try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
                check("a database for the safety copy test can be made", fixture != nil)
                if let fixture {
                    let ctx = ModelContext(fixture)
                    let base = Date(timeIntervalSince1970: 1_700_000_000)
                    for index in 0..<400 {
                        ctx.insert(Scrobble(artistName: "Artist \(index % 5)", albumName: "Album \(index % 9)", trackName: "Track \(index)", imageURL: nil, playedAt: base.addingTimeInterval(Double(index) * 60), lastConfirmedAt: base))
                    }
                    ctx.insert(SyncState(username: "SomeOne"))
                    try? ctx.save()
                }
                StoreLocationChecks.waitForRows(storeURL, table: "ZSCROBBLE", atLeast: 400)
                fixture = nil
                StoreLocationChecks.foldLog(storeURL)
                func hash() -> String? { (try? Data(contentsOf: storeURL)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }
                let before = hash()
                let safety = StoreSafetyCopy.folder(in: appFolder)
                check("the copies live in a folder called Safety Copies inside the app's folder", safety.lastPathComponent == "Safety Copies" && safety.deletingLastPathComponent().path == appFolder.path)

                let defaults = freshDefaults()
                func prepare(version: String = "9.9.9", build: String = "100", at date: Date = now, space: @escaping (URL) -> Int64? = { _ in 10_000_000_000 }, store: URL = storeURL, defaults d: UserDefaults? = nil) -> StoreSafetyCopy.Outcome {
                    StoreSafetyCopy.prepare(storeURL: store, appFolder: appFolder, version: version, build: build, defaults: d ?? defaults, now: date, availableSpace: space)
                }
                var madeURL: URL?
                if case .made(let url, let tables, let rows) = prepare() {
                    madeURL = url
                    check("the first launch of a build makes a copy", manager.fileExists(atPath: url.path) && url.lastPathComponent.hasPrefix("Scroblytics before 9.9.9 (100) ") && url.pathExtension == "store")
                    check("…it was checked table by table (tables and rows reported)", tables > 5 && rows >= 401, "\(tables) tables, \(rows) rows")
                    check("…the database itself was not changed", hash() == before)
                } else {
                    check("the first launch of a build makes a copy", false)
                }
                check("the same build again makes none", prepare() == .notNeeded && StoreSafetyCopy.copies(in: safety).count == 1)
                check("a copy reads as a database with the same rows", madeURL.map { StoreLocationChecks.waitForRows($0, table: "ZSCROBBLE", atLeast: 400) } ?? false)
                // Reading it here opened it read-write, which makes log files; fold them away so the folder holds only copies again.
                if let madeURL { StoreLocationChecks.foldLog(madeURL) }
                check("a new build makes a second copy", { if case .made = prepare(version: "9.9.10", build: "101", at: now.addingTimeInterval(60)) { return true } else { return false } }() && StoreSafetyCopy.copies(in: safety).count == 2)

                // Nothing yet: a first run.
                check("with no database yet there is nothing to copy, and the build is remembered", prepare(store: appFolder.appending(path: "none.store"), defaults: freshDefaults()) == .noStoreYet)
                let firstRunDefaults = freshDefaults()
                _ = StoreSafetyCopy.prepare(storeURL: appFolder.appending(path: "none.store"), appFolder: appFolder, version: "1", build: "1", defaults: firstRunDefaults, now: now)
                check("…so the launch after it counts as the same build", firstRunDefaults.string(forKey: StoreSafetyCopy.lastBuildKey) == "1 (1)")

                // Not the app's own database, not enough room, damaged.
                let foreign = appFolder.appending(path: "foreign.store")
                var other: OpaquePointer?
                sqlite3_open(foreign.path, &other); sqlite3_exec(other, "CREATE TABLE ZOTHER (Z_PK INTEGER); INSERT INTO ZOTHER VALUES (1);", nil, nil, nil); sqlite3_close(other)
                let countBefore = StoreSafetyCopy.copies(in: safety).count
                check("another program's database is not copied", prepare(version: "2", build: "2", store: foreign, defaults: freshDefaults()) == .skipped("the file isn’t the app’s own database"))
                check("not enough free space skips the copy", prepare(version: "3", build: "3", space: { _ in 1_000 }, defaults: freshDefaults()) == .skipped("not enough free disk space"))
                let damaged = appFolder.appending(path: "damaged.store")
                try? Data((0..<5_000).map { _ in UInt8.random(in: 0...255) }).write(to: damaged)
                if case .failed = prepare(version: "4", build: "4", store: damaged, defaults: freshDefaults()) { check("a damaged file fails without leaving a half copy", true) } else { check("a damaged file fails without leaving a half copy", false) }
                check("…none of those left a copy or a temporary file behind", StoreSafetyCopy.copies(in: safety).count == countBefore && ((try? manager.contentsOfDirectory(atPath: safety.path)) ?? []).allSatisfy { $0.hasSuffix(".store") },
                      "\(StoreSafetyCopy.copies(in: safety).count) copies vs \(countBefore); folder: \((try? manager.contentsOfDirectory(atPath: safety.path)) ?? [])")
                let failDefaults = freshDefaults()
                _ = prepare(version: "5", build: "5", store: damaged, defaults: failDefaults)
                check("a failed copy still marks the build as seen (a copy taken later would be after the update)", failDefaults.string(forKey: StoreSafetyCopy.lastBuildKey) == "5 (5)")

                // Keeping them.
                let keepFolder = folder("keep-app")
                func fill(_ ages: [Double]) -> [URL] {
                    let dest = StoreSafetyCopy.folder(in: keepFolder)
                    try? manager.removeItem(at: dest)
                    try? manager.createDirectory(at: dest, withIntermediateDirectories: true)
                    return ages.enumerated().map { index, age in
                        let url = dest.appending(path: "Scroblytics before 0.0.\(index) (1) 2026.store")
                        try? Data("x".utf8).write(to: url)
                        setModified(url, ago(age))
                        return url
                    }
                }
                _ = fill([30, 25, 20])
                StoreSafetyCopy.prune(in: StoreSafetyCopy.folder(in: keepFolder), now: now)
                check("copies older than two weeks go, but the two newest always stay", StoreSafetyCopy.copies(in: StoreSafetyCopy.folder(in: keepFolder)).count == 2)
                _ = fill([20, 3, 2])
                StoreSafetyCopy.prune(in: StoreSafetyCopy.folder(in: keepFolder), now: now)
                check("recent copies are all kept, an old third one goes", StoreSafetyCopy.copies(in: StoreSafetyCopy.folder(in: keepFolder)).count == 2)
                _ = fill([5, 4, 3, 2])
                StoreSafetyCopy.prune(in: StoreSafetyCopy.folder(in: keepFolder), now: now)
                check("nothing recent is ever deleted, however many", StoreSafetyCopy.copies(in: StoreSafetyCopy.folder(in: keepFolder)).count == 4)
                let stranger = StoreSafetyCopy.folder(in: keepFolder).appending(path: "other.store")
                try? Data("mine".utf8).write(to: stranger)
                StoreSafetyCopy.deleteAll(in: StoreSafetyCopy.folder(in: keepFolder))
                check("Delete Safety Copies removes only the copies the app made", StoreSafetyCopy.copies(in: StoreSafetyCopy.folder(in: keepFolder)).isEmpty && manager.fileExists(atPath: stranger.path))
            }

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
