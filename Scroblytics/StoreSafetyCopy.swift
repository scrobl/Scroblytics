import Foundation

/// A full copy of the database, made just before the first launch of a new version of the app opens it. A new version can change
/// the database (a new table is added to the file when it opens), and a bug there would otherwise leave nothing to go back to
/// except the history imported again from Last.fm. The copy has everything, history included.
///
/// It is made with the same checked copy as the move to the app's own file (`StoreLocation.copy`: SQLite's backup interface, the
/// original never written, integrity and every table's row count verified), kept for two weeks (and never fewer than the two
/// newest), and listed in Settings › General › Backup, where it can be shown in Finder or deleted. Nothing leaves the Mac.
enum StoreSafetyCopy {
    static let folderName = "Safety Copies"
    static let lastBuildKey = "store.safetycopy.lastBuild"
    /// Copies older than this are deleted, but the newest `keepAtLeast` always stay.
    static let maxAge: TimeInterval = 14 * 86_400
    static let keepAtLeast = 2
    /// Free space needed beyond twice the database's size, so a copy never fills the disk.
    static let spaceMargin: Int64 = 500_000_000

    enum Outcome: Equatable, Sendable {
        /// The same build has opened the file before.
        case notNeeded
        /// There is no database yet (a first run).
        case noStoreYet
        case made(URL, tables: Int, rows: Int)
        /// Not made, for a reason that isn't a failure: not enough room, or the file isn't the app's own database.
        case skipped(String)
        case failed(String)
    }

    /// `…/Application Support/Scroblytics/Safety Copies`.
    static func folder(in appFolder: URL) -> URL {
        appFolder.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Makes the copy when this build hasn't opened the file yet. Call it before the database is opened. The build is marked as
    /// seen whatever happens: a copy made on a later launch would be taken after the new version had already changed the file,
    /// so it wouldn't be "before".
    static func prepare(
        storeURL: URL,
        appFolder: URL,
        version: String,
        build: String,
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        availableSpace: (URL) -> Int64? = StoreSafetyCopy.availableSpace,
        fileManager: FileManager = .default
    ) -> Outcome {
        let running = "\(version) (\(build))"
        if defaults.string(forKey: lastBuildKey) == running { return .notNeeded }
        defer { defaults.set(running, forKey: lastBuildKey) }
        guard fileManager.fileExists(atPath: storeURL.path) else { return .noStoreYet }

        let size = databaseSize(storeURL, fileManager: fileManager)
        let destination = folder(in: appFolder)
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        if let free = availableSpace(destination), free < size * 2 + spaceMargin {
            return .skipped("not enough free disk space")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = destination.appending(path: "Scroblytics before \(version) (\(build)) \(formatter.string(from: now)).store")
        switch StoreLocation.copy(from: storeURL, to: target) {
        case .success(let counts):
            prune(in: destination, now: now, fileManager: fileManager)
            return .made(target, tables: counts.tables, rows: counts.rows)
        case .failure(.notOurs):
            return .skipped("the file isn’t the app’s own database")
        case .failure(.failed(let reason)):
            return .failed(reason)
        }
    }

    /// The copies in the folder, newest first.
    static func copies(in destination: URL, fileManager: FileManager = .default) -> [(url: URL, modified: Date, bytes: Int64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == "store" && $0.lastPathComponent.hasPrefix("Scroblytics before ") }
            .map { url -> (URL, Date, Int64) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }
    }

    /// Deletes copies older than `maxAge`, keeping the newest `keepAtLeast` whatever their age.
    static func prune(in destination: URL, now: Date, fileManager: FileManager = .default) {
        for old in copies(in: destination, fileManager: fileManager).dropFirst(keepAtLeast) where now.timeIntervalSince(old.modified) > maxAge {
            try? fileManager.removeItem(at: old.url)
        }
    }

    /// Settings › Delete Safety Copies.
    static func deleteAll(in destination: URL, fileManager: FileManager = .default) {
        for copy in copies(in: destination, fileManager: fileManager) { try? fileManager.removeItem(at: copy.url) }
    }

    /// The database and its log, in bytes.
    static func databaseSize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
        ["", "-wal"].reduce(Int64(0)) { total, suffix in
            total + Int64((try? fileManager.attributesOfItem(atPath: url.path + suffix)[.size] as? Int) ?? 0)
        }
    }

    /// Free bytes on the volume holding `url`.
    static func availableSpace(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }
}
