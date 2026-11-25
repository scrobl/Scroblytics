import Foundation
import SQLite3

/// Where the database lives, and how it moved there.
///
/// SwiftData's default is `~/Library/Application Support/default.store`, a name every app that doesn't choose one shares. The
/// app has its own file, `Application Support/Scroblytics/Scroblytics.store`, beside its images and log, so another program can
/// never open it with a different schema (which drops the tables it doesn't know). A person upgrading from a version that used
/// `default.store` gets a verified copy made once at launch; the old file is never changed or deleted.
enum StoreLocation {
    static let folderName = "Scroblytics"
    static let fileName = "Scroblytics.store"
    static let legacyFileName = "default.store"
    /// Remembers that the location was decided, so removing the new file to start over doesn't bring the old data back.
    static let decidedKey = "store.location.decided"
    /// Tables only this app's database has. A `default.store` without both belongs to some other program.
    static let requiredTables = ["ZSCROBBLE", "ZSYNCSTATE"]

    static func url(support: URL = .applicationSupportDirectory) -> URL {
        support.appending(path: folderName, directoryHint: .isDirectory).appending(path: fileName)
    }

    static func legacyURL(support: URL = .applicationSupportDirectory) -> URL {
        support.appending(path: legacyFileName)
    }

    enum Outcome: Equatable, Sendable {
        /// The new file is already there.
        case existing
        /// No earlier database: a new one is created on first open.
        case fresh
        /// The earlier database was copied: the number of tables and rows checked.
        case migrated(tables: Int, rows: Int)
        /// A `default.store` exists but isn't this app's, so it was left alone.
        case legacyNotOurs
        /// The copy couldn't be made or didn't verify; the earlier file is used as before and the copy is tried again next launch.
        case failed(String)
    }

    struct Resolution: Sendable {
        let url: URL
        let outcome: Outcome
    }

    /// Decides which file to open, copying the earlier database over first when that's needed. Never throws and never changes
    /// or removes the earlier file.
    static func resolve(support: URL = .applicationSupportDirectory, defaults: UserDefaults = .standard) -> Resolution {
        let manager = FileManager.default
        let target = url(support: support)
        let legacy = legacyURL(support: support)
        try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        if manager.fileExists(atPath: target.path) {
            defaults.set(true, forKey: decidedKey)
            return Resolution(url: target, outcome: .existing)
        }
        guard !defaults.bool(forKey: decidedKey), manager.fileExists(atPath: legacy.path) else {
            defaults.set(true, forKey: decidedKey)
            return Resolution(url: target, outcome: .fresh)
        }
        switch copy(from: legacy, to: target) {
        case .success(let counts):
            defaults.set(true, forKey: decidedKey)
            return Resolution(url: target, outcome: .migrated(tables: counts.tables, rows: counts.rows))
        case .failure(.notOurs):
            defaults.set(true, forKey: decidedKey)
            return Resolution(url: target, outcome: .legacyNotOurs)
        case .failure(.failed(let message)):
            return Resolution(url: legacy, outcome: .failed(message))
        }
    }

    // MARK: The copy

    enum CopyFailure: Error, Equatable {
        case notOurs
        case failed(String)
    }

    /// Copies one SQLite database to a new file using SQLite's own backup, which reads the write-ahead log too, so
    /// changes that haven't reached the main file yet come along. The source is opened read-only. The copy is made under a
    /// temporary name, checked (integrity and the row count of every table against the source), and only then renamed into place.
    static func copy(from source: URL, to target: URL) -> Result<(tables: Int, rows: Int), CopyFailure> {
        let manager = FileManager.default
        let temporary = target.deletingLastPathComponent().appending(path: target.lastPathComponent + ".migrating")
        func removeTemporary() {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? manager.removeItem(atPath: temporary.path + suffix) }
        }
        removeTemporary()

        var from: OpaquePointer?
        guard sqlite3_open_v2(source.path, &from, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let from else {
            sqlite3_close(from)
            return .failure(.failed("the earlier database couldn't be opened"))
        }
        defer { sqlite3_close(from) }

        let present: [String]
        do { present = try tableNames(in: from) } catch { return .failure(.failed("the earlier database couldn't be read")) }
        guard requiredTables.allSatisfy({ present.contains($0) }) else { return .failure(.notOurs) }

        var into: OpaquePointer?
        guard sqlite3_open_v2(temporary.path, &into, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let into else {
            sqlite3_close(into)
            removeTemporary()
            return .failure(.failed("the new database file couldn't be created"))
        }
        var closedInto = false
        func closeInto() { if !closedInto { sqlite3_close(into); closedInto = true } }
        defer { closeInto() }

        guard let backup = sqlite3_backup_init(into, "main", from, "main") else {
            removeTemporary()
            return .failure(.failed("the copy couldn't start"))
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            closeInto()
            removeTemporary()
            return .failure(.failed("the copy didn't finish (\(step)/\(finish))"))
        }

        // Verify the copy against the source before it can be used.
        guard (try? singleText(in: into, "PRAGMA integrity_check")) == "ok" else {
            closeInto()
            removeTemporary()
            return .failure(.failed("the copy failed its integrity check"))
        }
        var tables = 0
        var rows = 0
        do {
            for name in present where !name.hasPrefix("sqlite_") {
                let expected = try count(in: from, table: name)
                let found = try count(in: into, table: name)
                guard expected == found else {
                    closeInto()
                    removeTemporary()
                    return .failure(.failed("the copy has \(found) rows where the original has \(expected)"))
                }
                tables += 1
                rows += expected
            }
        } catch {
            closeInto()
            removeTemporary()
            return .failure(.failed("the copy couldn't be checked"))
        }
        // Fold anything in the new file's log into the main file so the renamed file stands alone.
        _ = try? singleText(in: into, "PRAGMA wal_checkpoint(TRUNCATE)")
        closeInto()
        for suffix in ["-wal", "-shm", "-journal"] { try? manager.removeItem(atPath: temporary.path + suffix) }
        do {
            try manager.moveItem(at: temporary, to: target)
        } catch {
            removeTemporary()
            return .failure(.failed("the copy couldn't be put in place"))
        }
        return .success((tables, rows))
    }

    // MARK: SQLite helpers

    private struct SQLiteFailure: Error {}

    private static func tableNames(in database: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteFailure()
        }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                names.append(String(cString: text))
            } else if result == SQLITE_DONE {
                return names
            } else {
                throw SQLiteFailure()
            }
        }
    }

    private static func count(in database: OpaquePointer, table: String) throws -> Int {
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(quoted)", -1, &statement, nil) == SQLITE_OK else { throw SQLiteFailure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteFailure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func singleText(in database: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw SQLiteFailure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw SQLiteFailure() }
        return String(cString: text)
    }
}
