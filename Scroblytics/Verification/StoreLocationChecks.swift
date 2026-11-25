import CryptoKit
import Foundation
import SQLite3
import SwiftData

#if DEBUG
/// `SCROBLYTICS_STORELOCATION_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the app's own database file and the
/// one-time copy from the shared `default.store`, on made-up data in temporary folders. Nothing here touches the real
/// Application Support folder or the real preferences. Exits 0 on success.
///
/// `SCROBLYTICS_STORELOCATION_REAL=<path to a COPY of a default.store>` runs the copy on that file in a temporary folder and
/// prints every table's row count, to be compared against an independent `sqlite3` count.
enum StoreLocationChecks {
    @MainActor
    static func runHeadlessIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        if let real = environment["SCROBLYTICS_STORELOCATION_REAL"] {
            runReal(copyOf: URL(fileURLWithPath: real))
        }
        guard environment["SCROBLYTICS_STORELOCATION_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let manager = FileManager.default
            let root = manager.temporaryDirectory.appending(path: "scroblytics-storeloc-\(UUID().uuidString)")
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: root) }
            var suiteCounter = 0
            func freshDefaults() -> UserDefaults {
                suiteCounter += 1
                let name = "scroblytics.storeloc.check.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: name)!
                defaults.removePersistentDomain(forName: name)
                return defaults
            }
            func newSupport(_ label: String) -> URL {
                let url = root.appending(path: label, directoryHint: .isDirectory)
                try? manager.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            }
            func hash(of url: URL) -> String? {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }

            // MARK: Where the file lives
            let support = newSupport("paths")
            check("the new file is Scroblytics/Scroblytics.store inside Application Support",
                  StoreLocation.url(support: support).path == support.appending(path: "Scroblytics/Scroblytics.store").path)
            check("the earlier file is default.store beside that folder", StoreLocation.legacyURL(support: support).path == support.appending(path: "default.store").path)
            check("the real location is never the shared default.store name", StoreLocation.url().lastPathComponent != StoreLocation.legacyFileName)

            // MARK: A first run: nothing earlier
            do {
                let home = newSupport("fresh")
                let defaults = freshDefaults()
                let resolution = StoreLocation.resolve(support: home, defaults: defaults)
                check("with no earlier file a new one is used", resolution.outcome == .fresh && resolution.url == StoreLocation.url(support: home))
                check("…its folder exists and no database file was created yet", manager.fileExists(atPath: resolution.url.deletingLastPathComponent().path) && !manager.fileExists(atPath: resolution.url.path))
                check("…and the decision is remembered", defaults.bool(forKey: StoreLocation.decidedKey))
            }

            // MARK: Copying a real app database, with data still in its write-ahead log
            let schema = Schema(AppSchema.modelTypes)
            let migrateHome = newSupport("migrate")
            let legacy = StoreLocation.legacyURL(support: migrateHome)
            var legacyContainer: ModelContainer? = try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: legacy))
            check("a database in the earlier shared file can be created for the test", legacyContainer != nil)
            if let legacyContainer {
                let context = ModelContext(legacyContainer)
                let base = Date(timeIntervalSince1970: 1_700_000_000)
                for index in 0..<600 {
                    context.insert(Scrobble(artistName: "Artist \(index % 7)", albumName: "Album \(index % 11)", trackName: "Track \(index)", imageURL: nil, playedAt: base.addingTimeInterval(Double(index) * 60), lastConfirmedAt: base))
                }
                context.insert(SyncState(username: "SomeOne"))
                for index in 0..<25 { context.insert(LovedTrackEntry(cacheKey: "artist a\u{1F}track \(index)", artist: "Artist A", track: "Track \(index)")) }
                try? context.save()
            }
            check("the test database has data waiting in its log, as a live app's would", (try? manager.attributesOfItem(atPath: legacy.path + "-wal")[.size] as? Int).map { ($0 ?? 0) > 0 } ?? false)
            let before = (main: hash(of: legacy), wal: hash(of: URL(fileURLWithPath: legacy.path + "-wal")))
            let migrateDefaults = freshDefaults()
            let migrated = StoreLocation.resolve(support: migrateHome, defaults: migrateDefaults)
            if case .migrated(let tables, let rows) = migrated.outcome {
                check("the earlier database is copied", tables > 10 && rows >= 600 + 1 + 25, "tables \(tables), rows \(rows)")
            } else {
                check("the earlier database is copied", false, "\(migrated.outcome)")
            }
            check("the copy is the new file", migrated.url == StoreLocation.url(support: migrateHome) && manager.fileExists(atPath: migrated.url.path))
            check("no temporary or log files are left beside it", !manager.fileExists(atPath: migrated.url.path + ".migrating")
                  && !manager.fileExists(atPath: migrated.url.path + "-wal") && !manager.fileExists(atPath: migrated.url.path + "-shm"))
            check("the earlier file's contents were not changed", hash(of: legacy) == before.main && hash(of: URL(fileURLWithPath: legacy.path + "-wal")) == before.wal)
            if let copy = try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: migrated.url)) {
                let context = ModelContext(copy)
                check("the app opens the copy with its schema", true)
                check("it has every scrobble, including those that were only in the log", (try? context.fetchCount(FetchDescriptor<Scrobble>())) == 600)
                check("it has the sync state and loved tracks", (try? context.fetchCount(FetchDescriptor<SyncState>())) == 1 && (try? context.fetchCount(FetchDescriptor<LovedTrackEntry>())) == 25)
                let sample = (try? context.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])))?.first
                check("a row keeps its contents", sample?.trackName == "Track 0" && sample?.artistName == "Artist 0")
            } else {
                check("the app opens the copy with its schema", false)
            }
            check("the decision is remembered", migrateDefaults.bool(forKey: StoreLocation.decidedKey))

            // New rows go to the new file only
            if let copy = try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: migrated.url)) {
                let context = ModelContext(copy)
                context.insert(Scrobble(artistName: "Artist Z", albumName: "Album Z", trackName: "Only In The New File", imageURL: nil, playedAt: Date(), lastConfirmedAt: Date()))
                try? context.save()
            }
            if let legacyContainer {
                check("the earlier file does not receive new rows", (try? ModelContext(legacyContainer).fetchCount(FetchDescriptor<Scrobble>())) == 600)
            }
            legacyContainer = nil

            // A later launch uses the new file and leaves it alone
            do {
                let beforeNew = hash(of: migrated.url)
                let again = StoreLocation.resolve(support: migrateHome, defaults: migrateDefaults)
                check("a later launch uses the new file", again.outcome == .existing && again.url == migrated.url)
                check("…and does not copy the earlier file over it", hash(of: migrated.url) == beforeNew)
            }

            // MARK: Removing the new file to start over does not bring the old data back
            do {
                try? manager.removeItem(at: migrated.url)
                let afterRemoval = StoreLocation.resolve(support: migrateHome, defaults: migrateDefaults)
                check("with the new file removed, a new one is started, not the old data", afterRemoval.outcome == .fresh && !manager.fileExists(atPath: afterRemoval.url.path))
            }

            // MARK: A different program's default.store is left alone
            do {
                let home = newSupport("foreign")
                let foreign = StoreLocation.legacyURL(support: home)
                var database: OpaquePointer?
                sqlite3_open(foreign.path, &database)
                sqlite3_exec(database, "CREATE TABLE ZAPIREQUESTMODEL (Z_PK INTEGER PRIMARY KEY, ZKEY VARCHAR); INSERT INTO ZAPIREQUESTMODEL (ZKEY) VALUES ('x');", nil, nil, nil)
                sqlite3_close(database)
                let beforeForeign = hash(of: foreign)
                let defaults = freshDefaults()
                let resolution = StoreLocation.resolve(support: home, defaults: defaults)
                check("another program's database is recognised and not copied", resolution.outcome == .legacyNotOurs && !manager.fileExists(atPath: resolution.url.path))
                check("…it is left exactly as it was", hash(of: foreign) == beforeForeign)
                check("…and the app uses its own new file", resolution.url == StoreLocation.url(support: home))
            }

            // MARK: A damaged earlier file does not lose anything: it is used as before and tried again
            do {
                let home = newSupport("damaged")
                let damaged = StoreLocation.legacyURL(support: home)
                try? Data(repeating: 0x41, count: 5000).write(to: damaged)
                let defaults = freshDefaults()
                let resolution = StoreLocation.resolve(support: home, defaults: defaults)
                if case .failed = resolution.outcome { check("an unreadable earlier file is reported as a failure", true) } else { check("an unreadable earlier file is reported as a failure", false, "\(resolution.outcome)") }
                check("…the earlier file is still the one opened", resolution.url == damaged)
                check("…no new or temporary file is left", !manager.fileExists(atPath: StoreLocation.url(support: home).path) && !manager.fileExists(atPath: StoreLocation.url(support: home).path + ".migrating"))
                check("…the decision is not remembered, so the next launch tries again", !defaults.bool(forKey: StoreLocation.decidedKey))
            }

            // MARK: A temporary file left by an interrupted copy is cleaned up
            do {
                let home = newSupport("interrupted")
                let source = StoreLocation.legacyURL(support: home)
                if let container = try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: source)) {
                    let context = ModelContext(container)
                    context.insert(Scrobble(artistName: "Artist A", albumName: "Album One", trackName: "Track One", imageURL: nil, playedAt: Date(), lastConfirmedAt: Date()))
                    try? context.save()
                }
                let target = StoreLocation.url(support: home)
                try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(repeating: 0x42, count: 4096).write(to: URL(fileURLWithPath: target.path + ".migrating"))
                let resolution = StoreLocation.resolve(support: home, defaults: freshDefaults())
                if case .migrated(_, let rows) = resolution.outcome { check("a copy interrupted earlier is redone", rows >= 1) } else { check("a copy interrupted earlier is redone", false, "\(resolution.outcome)") }
            }

            HeadlessTask.finish(failures)
        }
    }

    /// Copies the given file (a COPY of a real `default.store`) to a temporary support folder through the real code and prints
    /// each table's row count in the copy, for comparison with an independent count.
    @MainActor
    private static func runReal(copyOf source: URL) {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appending(path: "scroblytics-storeloc-real-\(UUID().uuidString)")
        try? manager.createDirectory(at: home, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let part = URL(fileURLWithPath: source.path + suffix)
            if manager.fileExists(atPath: part.path) { try? manager.copyItem(at: part, to: URL(fileURLWithPath: StoreLocation.legacyURL(support: home).path + suffix)) }
        }
        let name = "scroblytics.storeloc.real.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let started = Date()
        let resolution = StoreLocation.resolve(support: home, defaults: defaults)
        print("REAL outcome: \(resolution.outcome) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        print("REAL new file: \(resolution.url.path)")
        defaults.removePersistentDomain(forName: name)
        // Leave the folder for the caller's independent sqlite3 count; the caller removes it.
        HeadlessTask.finish(0)
    }
}
#endif
