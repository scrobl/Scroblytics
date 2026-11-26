import Foundation
import SQLite3

/// Looks at the database file before it is opened, to tell a hollowed-out one from a healthy or brand-new one.
///
/// Core Data quietly recreates any table that is missing, so a database whose tables were dropped (for example by another
/// program that opened the same file with a different schema) would open as an empty, working one and start a full import,
/// with nothing to say that years of history had just disappeared. This reads the file's structure directly (read-only) and
/// reports what it finds, so the app can stop and say so first. Nothing in the file is changed.
enum StoreIntegrity {
    /// A file smaller than this is treated as new: a database that has held a history is far larger.
    static let defaultMinimumBytes = 1_000_000
    /// How much of the file must be unused pages for an empty history to count as "removed" rather than "never filled".
    static let hollowShare = 0.5

    struct Report: Equatable, Sendable {
        var exists = false
        var bytes = 0
        var pages = 0
        var freePages = 0
        var tables: [String] = []
        /// Rows in the scrobbles table, nil when that table isn't there.
        var scrobbles: Int?
        var readable = true
    }

    enum Verdict: Equatable, Sendable {
        /// Nothing to worry about: no file, a new small one, or one that holds a history.
        case ok
        /// A large file with no listening history: its tables were removed or its rows deleted.
        case emptied(Report)
    }

    static func inspect(_ url: URL) -> Report {
        var report = Report()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int else { return report }
        report.exists = true
        report.bytes = size
        // A cleanly closed database has no log files, and SQLite can't open such a file read-only without creating one, so it
        // is opened as immutable (no log exists to be missed). When a log is waiting it holds changes the main file doesn't
        // yet, so the file is opened normally and SQLite applies the log, exactly as the app's own open would moments later.
        let logSize = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? Int) ?? nil
        var database: OpaquePointer?
        let opened: Int32
        if (logSize ?? 0) > 0 {
            opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
        } else {
            opened = sqlite3_open_v2("\(url.absoluteString)?immutable=1", &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        }
        guard opened == SQLITE_OK, let database else {
            sqlite3_close(database)
            report.readable = false
            return report
        }
        defer { sqlite3_close(database) }
        guard let pages = integer(database, "PRAGMA page_count"), let free = integer(database, "PRAGMA freelist_count"),
              let names = names(database) else {
            report.readable = false
            return report
        }
        report.pages = pages
        report.freePages = free
        report.tables = names
        if names.contains("ZSCROBBLE") { report.scrobbles = integer(database, "SELECT COUNT(*) FROM ZSCROBBLE") }
        return report
    }

    static func verdict(for report: Report, minimumBytes: Int = defaultMinimumBytes) -> Verdict {
        guard report.exists, report.readable, report.bytes >= minimumBytes else { return .ok }
        if let scrobbles = report.scrobbles {
            guard scrobbles == 0 else { return .ok }
            // The table is there but empty: only a problem when most of a large file is unused pages.
            let share = report.pages > 0 ? Double(report.freePages) / Double(report.pages) : 0
            return share >= hollowShare ? .emptied(report) : .ok
        }
        // No scrobbles table at all in a large file.
        return .emptied(report)
    }

    static func verdict(for url: URL, minimumBytes: Int = defaultMinimumBytes) -> Verdict {
        verdict(for: inspect(url), minimumBytes: minimumBytes)
    }

    /// Moves the database file and its companions into a `Recovered Databases` folder beside it, so a new one can start and
    /// the old one is still there to recover from. Nothing is deleted. Returns the new location of the main file.
    @discardableResult
    static func setAside(_ url: URL, now: Date = Date()) throws -> URL {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent().appending(path: "Recovered Databases", directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let moved = folder.appending(path: "\(url.lastPathComponent).\(stamp)")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            try manager.moveItem(at: source, to: URL(fileURLWithPath: moved.path + suffix))
        }
        return moved
    }

    // MARK: SQLite helpers

    private static func integer(_ database: OpaquePointer, _ sql: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func names(_ database: OpaquePointer) -> [String]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                result.append(String(cString: text))
            } else if step == SQLITE_DONE {
                return result
            } else {
                return nil
            }
        }
    }
}
