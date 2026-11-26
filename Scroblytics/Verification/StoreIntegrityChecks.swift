import CryptoKit
import Foundation
import SQLite3
import SwiftData

#if DEBUG
/// `SCROBLYTICS_STOREINTEGRITY_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the startup look at the database file.
/// A healthy history is left alone; a large file whose tables were dropped or whose rows were deleted is reported and not opened;
/// a new or small file is not mistaken for one. On made-up data in temporary folders. Exits 0 on success.
///
/// `SCROBLYTICS_STOREINTEGRITY_REAL=<path>,<path>…` prints the verdict for each given file (COPIES of real databases).
enum StoreIntegrityChecks {
    @MainActor
    static func runHeadlessIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        if let real = environment["SCROBLYTICS_STOREINTEGRITY_REAL"] {
            for path in real.split(separator: ",").map(String.init) {
                let report = StoreIntegrity.inspect(URL(fileURLWithPath: path))
                print("REAL \((path as NSString).lastPathComponent): verdict=\(StoreIntegrity.verdict(for: report)) bytes=\(report.bytes) pages=\(report.pages) free=\(report.freePages) scrobbles=\(report.scrobbles.map(String.init) ?? "no table") tables=\(report.tables.count)")
            }
            HeadlessTask.finish(0)
        }
        guard environment["SCROBLYTICS_STOREINTEGRITY_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let manager = FileManager.default
            let root = manager.temporaryDirectory.appending(path: "scroblytics-integrity-\(UUID().uuidString)")
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: root) }
            let schema = Schema(AppSchema.modelTypes)
            func hash(of url: URL) -> String? {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            /// A real app database with `rows` scrobbles, closed and folded into one file.
            func makeStore(_ name: String, rows: Int) -> URL {
                let url = root.appending(path: name)
                var holder: ModelContainer? = try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
                defer { holder = nil }
                if let container = holder {
                    let context = ModelContext(container)
                    context.insert(SyncState(username: "SomeOne"))
                    let base = Date(timeIntervalSince1970: 1_700_000_000)
                    for index in 0..<rows {
                        context.insert(Scrobble(artistName: "Artist \(index % 40)", albumName: "Album number \(index % 90) of the made-up collection", trackName: "Track \(index) with a reasonably long made-up title", imageURL: "https://example.invalid/image/\(index).png", playedAt: base.addingTimeInterval(Double(index) * 90), lastConfirmedAt: base))
                    }
                    try? context.save()
                }
                if rows > 0 { StoreLocationChecks.waitForRows(url, table: "ZSCROBBLE", atLeast: rows) }
                holder = nil
                fold(url)
                return url
            }
            /// Folds the log into the main file and removes the companions, so the file stands alone.
            func fold(_ url: URL) { StoreLocationChecks.foldLog(url) }
            func run(_ url: URL, _ sql: String) {
                var database: OpaquePointer?
                if sqlite3_open(url.path, &database) == SQLITE_OK { sqlite3_exec(database, sql, nil, nil, nil) }
                sqlite3_close(database)
                fold(url)
            }
            func tableNames(_ url: URL) -> [String] { StoreIntegrity.inspect(url).tables }

            // MARK: Verdicts
            let healthy = makeStore("healthy.store", rows: 12_000)
            let healthyReport = StoreIntegrity.inspect(healthy)
            check("the made-up history is large enough to count as a history", healthyReport.bytes >= StoreIntegrity.defaultMinimumBytes, "\(healthyReport.bytes) bytes")
            check("a healthy history is left alone", StoreIntegrity.verdict(for: healthy) == .ok)
            check("its scrobbles are counted", healthyReport.scrobbles == 12_000)

            let dropped = root.appending(path: "dropped.store")
            try? manager.copyItem(at: healthy, to: dropped)
            for table in tableNames(dropped) where table.hasPrefix("Z") && !table.hasPrefix("Z_") { run(dropped, "DROP TABLE \"\(table)\"") }
            run(dropped, "CREATE TABLE ZAPIREQUESTMODEL (Z_PK INTEGER PRIMARY KEY, ZKEY VARCHAR)")
            let droppedReport = StoreIntegrity.inspect(dropped)
            if case .emptied(let found) = StoreIntegrity.verdict(for: dropped) {
                check("a large file whose tables were dropped is reported", found.scrobbles == nil && found.freePages > found.pages / 2, "free \(found.freePages) of \(found.pages)")
            } else {
                check("a large file whose tables were dropped is reported", false, "\(droppedReport)")
            }

            let deleted = root.appending(path: "deleted.store")
            try? manager.copyItem(at: healthy, to: deleted)
            run(deleted, "DELETE FROM ZSCROBBLE")
            if case .emptied(let found) = StoreIntegrity.verdict(for: deleted) {
                check("a large file whose scrobbles were all deleted is reported", found.scrobbles == 0)
            } else {
                check("a large file whose scrobbles were all deleted is reported", false, "\(StoreIntegrity.inspect(deleted))")
            }

            let brandNew = makeStore("brandnew.store", rows: 0)
            check("a new, empty database is not mistaken for an emptied one", StoreIntegrity.verdict(for: brandNew) == .ok, "\(StoreIntegrity.inspect(brandNew).bytes) bytes")

            let smallHollow = makeStore("smallhollow.store", rows: 200)
            run(smallHollow, "DROP TABLE ZSCROBBLE")
            check("a small file is never reported, however empty", StoreIntegrity.verdict(for: smallHollow) == .ok)
            check("…unless the size limit is lowered", StoreIntegrity.verdict(for: smallHollow, minimumBytes: 1000) != .ok)

            check("a missing file is fine (a first run)", StoreIntegrity.verdict(for: root.appending(path: "absent.store")) == .ok)
            let garbage = root.appending(path: "garbage.store")
            try? Data(repeating: 0x41, count: 2_000_000).write(to: garbage)
            check("an unreadable file is left to the normal error path, not called emptied", StoreIntegrity.verdict(for: garbage) == .ok)

            let fewLeft = root.appending(path: "fewleft.store")
            try? manager.copyItem(at: healthy, to: fewLeft)
            run(fewLeft, "DELETE FROM ZSCROBBLE WHERE ZTRACKNAME NOT LIKE 'Track 1 %'")
            check("a history with some rows left is not reported", StoreIntegrity.verdict(for: fewLeft) == .ok, "\(StoreIntegrity.inspect(fewLeft).scrobbles ?? -1) rows")

            // MARK: Startup
            let before = hash(of: dropped)
            let siblingsBefore = (try? manager.contentsOfDirectory(atPath: root.path).sorted()) ?? []
            let opened = StoreStartup.open(schema: schema, configuration: ModelConfiguration(schema: schema, url: dropped), storePath: dropped.path)
            check("startup does not open an emptied file and says why", opened.failure?.cause == .emptied)
            check("…it starts on an in-memory stand-in, with no import", (try? ModelContext(opened.container).fetchCount(FetchDescriptor<Scrobble>())) == 0)
            check("…the file is exactly as it was", hash(of: dropped) == before)
            check("…and no new file appeared beside it", ((try? manager.contentsOfDirectory(atPath: root.path).sorted()) ?? []) == siblingsBefore)
            check("the explanation says nothing was changed and offers a way to start over",
                  (opened.failure?.advice.contains("has not opened it") ?? false) && (opened.failure?.advice.contains("Start Over") ?? false), opened.failure?.advice ?? "")
            check("it carries what was found", opened.failure?.details.contains("pages unused") ?? false, opened.failure?.details ?? "")

            let openedHealthy = StoreStartup.open(schema: schema, configuration: ModelConfiguration(schema: schema, url: healthy), storePath: healthy.path)
            check("startup opens a healthy history normally", openedHealthy.failure == nil && (try? ModelContext(openedHealthy.container).fetchCount(FetchDescriptor<Scrobble>())) == 12_000)

            // MARK: Starting over keeps the file
            do {
                let victim = root.appending(path: "victim.store")
                try? manager.copyItem(at: dropped, to: victim)
                try? Data("log".utf8).write(to: URL(fileURLWithPath: victim.path + "-wal"))
                let victimHash = hash(of: victim)
                let moved = try StoreIntegrity.setAside(victim, now: Date(timeIntervalSince1970: 1_700_000_000))
                check("starting over moves the file into Recovered Databases", moved.deletingLastPathComponent().lastPathComponent == "Recovered Databases" && manager.fileExists(atPath: moved.path))
                check("…its companions go with it", manager.fileExists(atPath: moved.path + "-wal"))
                check("…nothing is left behind and nothing is deleted", !manager.fileExists(atPath: victim.path) && !manager.fileExists(atPath: victim.path + "-wal") && hash(of: moved) == victimHash)
                let fresh = StoreStartup.open(schema: schema, configuration: ModelConfiguration(schema: schema, url: victim), storePath: victim.path)
                check("the next start makes a new database and does not warn", fresh.failure == nil && (try? ModelContext(fresh.container).fetchCount(FetchDescriptor<Scrobble>())) == 0)
            } catch {
                check("starting over works", false, "\(error)")
            }

            HeadlessTask.finish(failures)
        }
    }
}
#endif
