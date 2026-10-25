import Foundation
import SwiftData

/// The text a person can send when something goes wrong: what version and Mac, how much is imported, where the sync stands, and the
/// last few things the app did. It holds no username, no keys, no music (no artist, album or track names) and no file paths. It is
/// shown to the person before anything is sent.
struct DiagnosticSummary: Sendable {
    struct Inputs: Sendable {
        var version = ""
        var build = ""
        var macOS = ""
        var architecture = ""
        var model = ""
        var memoryGB = 0
        /// What the app itself holds now and at its highest (MB), so a report of "it uses too much memory" comes with the number.
        var appMemoryMB: Int?
        var appMemoryPeakMB: Int?
        var scrobbles = 0
        var artists = 0
        /// Plain words (with error codes, no data) when the database could not be counted; the counts above are then not real.
        var storeProblem: String?
        /// Free space on the disk holding the database, and the size of the database files (MB): a full disk is the first suspect when saving fails.
        var freeDiskMB: Int?
        var databaseMB: Int?
        var accountConnected = false
        /// The macOS status when the Keychain wouldn't give up the saved account (so "not connected" would be untrue).
        var keychainProblem: OSStatus?
        var lastSyncedAt: Date?
        /// Mid-import resume point: the page the import will continue from, of how many.
        var resumePage: Int?
        var resumeTotalPages: Int?
        var offline = false
        var askEngine = ""
        var updateChecks = true
        var activity: [String] = []
        var crashReports: [CrashReportFile] = []
    }

    /// The most text a summary holds, so a mail draft or a pasted issue stays manageable.
    static let maxBytes = 64 * 1024

    static func render(_ i: Inputs, secrets: [DiagnosticRedactor.Secret] = [], now: Date = Date()) -> String {
        func clean(_ s: String) -> String { DiagnosticRedactor.clean(s, secrets: secrets) }
        let stamp = ISO8601DateFormatter().string(from: now)
        var lines: [String] = []
        lines.append("Scroblytics \(i.version) (build \(i.build)) problem report summary")
        lines.append("Made \(stamp)")
        lines.append("")
        lines.append("This Mac")
        lines.append("  macOS: \(clean(i.macOS))")
        lines.append("  Processor: \(i.architecture)    Model: \(clean(i.model))    Memory: \(i.memoryGB) GB")
        lines.append("")
        lines.append("The app")
        if let now = i.appMemoryMB {
            lines.append("  Memory in use by the app: \(now) MB" + (i.appMemoryPeakMB.map { " (highest \($0) MB)" } ?? ""))
        }
        if let status = i.keychainProblem, !i.accountConnected {
            lines.append("  Last.fm account: saved, but the Keychain can't be read (status \(status))")
        } else {
            lines.append("  Last.fm account: \(i.accountConnected ? "connected" : "not connected")")
        }
        if let problem = i.storeProblem {
            lines.append("  Imported: unknown (the database could not be read: \(clean(problem)))")
        } else {
            lines.append("  Imported: \(i.scrobbles) scrobbles, \(i.artists) artists")
        }
        if let size = i.databaseMB { lines.append("  Database size: \(size) MB" + (i.freeDiskMB.map { ", free space on that disk: \($0) MB" } ?? "")) }
        else if let free = i.freeDiskMB { lines.append("  Free space on the disk: \(free) MB") }
        if let last = i.lastSyncedAt {
            lines.append("  Last completed sync: \(ISO8601DateFormatter().string(from: last))")
        } else {
            lines.append("  Last completed sync: never (the first import has not finished)")
        }
        if let page = i.resumePage {
            lines.append("  Import resumes at page \(page)" + (i.resumeTotalPages.map { " of \($0)" } ?? ""))
        }
        lines.append("  Offline mode: \(i.offline ? "on" : "off")")
        lines.append("  Ask engine: \(clean(i.askEngine))")
        lines.append("  Automatic update check: \(i.updateChecks ? "on" : "off")")
        lines.append("")
        lines.append("Crash reports found (names and dates only; the files are not included)")
        if i.crashReports.isEmpty {
            lines.append("  none")
        } else {
            for report in i.crashReports { lines.append("  \(clean(report.name))  \(ISO8601DateFormatter().string(from: report.date))") }
        }
        lines.append("")
        lines.append("Recent activity (newest last; no music or account details are recorded)")
        if i.activity.isEmpty {
            lines.append("  nothing recorded yet")
        } else {
            for line in i.activity { lines.append("  " + clean(line)) }
        }
        var text = lines.joined(separator: "\n") + "\n"
        if text.utf8.count > maxBytes {
            // Drop the oldest activity first; the top of the summary is the most useful part.
            var activity = i.activity
            while text.utf8.count > maxBytes, !activity.isEmpty {
                activity.removeFirst(max(1, activity.count / 4))
                var smaller = i
                smaller.activity = activity
                text = render(smaller, secrets: secrets, now: now)
            }
        }
        return text
    }

    // MARK: - Gathering

    /// Reads the current state of the app. Counts come from the store; the Keychain is read only to know whether an account exists
    /// and to scrub its values from the text.
    @MainActor
    static func gather(container: ModelContainer, now: Date = Date(), loadCredentials: @escaping @Sendable () -> LastfmCredentials? = { LastfmCredentialsStore.load() }) async -> (text: String, inputs: Inputs) {
        var i = Inputs()
        let info = Bundle.main.infoDictionary
        i.version = info?["CFBundleShortVersionString"] as? String ?? "?"
        i.build = info?["CFBundleVersion"] as? String ?? "?"
        i.macOS = ProcessInfo.processInfo.operatingSystemVersionString
        i.architecture = Self.architecture
        i.model = Self.hardwareModel
        i.memoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        (i.appMemoryMB, i.appMemoryPeakMB) = Self.appMemory()
        let context = container.mainContext
        do {
            i.scrobbles = try context.checkedCount(FetchDescriptor<Scrobble>())
            i.artists = try context.checkedCount(FetchDescriptor<Artist>())
        } catch {
            i.storeProblem = StoreProblem.describe(error) ?? "The database could not be read."
        }
        (i.freeDiskMB, i.databaseMB) = Self.diskFacts(container: container)
        if let state = try? context.fetch(FetchDescriptor<SyncState>()).first {
            i.lastSyncedAt = state.lastSyncedAt
            i.resumePage = state.backfillNextPage
            i.resumeTotalPages = state.backfillTotalPages
        }
        let credentials = await Task.detached(priority: .userInitiated) { loadCredentials() }.value
        i.accountConnected = credentials != nil
        i.keychainProblem = credentials == nil ? LastfmCredentialsStore.lastProblem : nil
        i.offline = ConnectivityGate.isOffline
        i.askEngine = AskSettingsStore.load().selected.label
        i.updateChecks = UpdateStore.shared.automaticChecks
        i.activity = ActivityLog.shared.recentLines(60)
        i.crashReports = CrashReports.find()
        var secrets: [DiagnosticRedactor.Secret] = []
        if let credentials {
            secrets.append(.init(value: credentials.username, label: "username"))
            secrets.append(.init(value: credentials.apiKey, label: "key"))
            if let value = credentials.apiSecret { secrets.append(.init(value: value, label: "key")) }
            if let value = credentials.sessionKey { secrets.append(.init(value: value, label: "key")) }
        }
        return (render(i, secrets: secrets, now: now), i)
    }

    /// Free space on the volume holding the database and the combined size of its files (the store plus its -wal and -shm files), in MB.
    /// Sizes only: no path leaves this function.
    static func diskFacts(container: ModelContainer) -> (freeMB: Int?, databaseMB: Int?) {
        guard let url = container.configurations.first?.url else { return (nil, nil) }
        let free = (try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        var bytes: Int64 = 0
        var found = false
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { bytes += Int64(size); found = true }
        }
        return (free.map { Int($0 / 1_048_576) }, found ? Int(bytes / 1_048_576) : nil)
    }

    /// The app's own memory footprint now and at its peak, in MB (what Activity Monitor's Memory column is based on).
    static func appMemory() -> (current: Int?, peak: Int?) {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        guard result == 0 else { return (nil, nil) }
        return (Int(info.ri_phys_footprint / 1_048_576), Int(info.ri_lifetime_max_phys_footprint / 1_048_576))
    }

    static var architecture: String {
        #if arch(arm64)
        return "Apple silicon"
        #else
        return "Intel"
        #endif
    }

    /// The Mac's model identifier (for example "Mac14,2"), which says nothing about the person.
    static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 1 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
