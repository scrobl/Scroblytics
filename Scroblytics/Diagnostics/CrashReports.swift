import AppKit
import Foundation
import Observation

/// A crash report macOS wrote for Scroblytics.
struct CrashReportFile: Equatable, Identifiable, Sendable {
    let url: URL
    let date: Date
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Finds the crash reports macOS keeps in `~/Library/Logs/DiagnosticReports`. Only names and dates are looked at: the app never
/// opens a report, and never sends one anywhere. The person chooses whether to share it.
enum CrashReports {
    static var directory: URL {
        #if DEBUG
        if let override = TestProfile.crashReportsFolderOverride { return override }
        #endif
        return URL.libraryDirectory.appending(path: "Logs/DiagnosticReports", directoryHint: .isDirectory)
    }

    /// The newest reports whose file name starts with the app's name, newest first. A missing or unreadable folder is "none".
    static func find(in folder: URL = directory, limit: Int = 5) -> [CrashReportFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let reports: [CrashReportFile] = urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("Scroblytics-") || name.hasPrefix("Scroblytics_"), ["ips", "crash"].contains(url.pathExtension.lowercased()),
                  let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate else { return nil }
            return CrashReportFile(url: url, date: date)
        }
        return Array(reports.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// The newest report written after `since` (the start of the previous run), if any: the last run probably ended in a crash.
    static func newest(after since: Date?, in reports: [CrashReportFile]) -> CrashReportFile? {
        guard let since else { return nil }
        return reports.filter { $0.date > since }.max { $0.date < $1.date }
    }

    static func reveal(_ report: CrashReportFile) {
        NSWorkspace.shared.activateFileViewerSelecting([report.url])
    }
}

/// Whether the previous run of the app ended in a crash, for the one-line notice under the toolbar. Decided once per launch from
/// the report files' dates against the previous launch's start time; the person can dismiss it, and it is not shown again.
@MainActor
@Observable
final class CrashNoticeStore {
    static let shared = CrashNoticeStore()

    private enum Key {
        static let lastLaunch = "diagnostics.lastLaunchAt"
        static let dismissed = "diagnostics.dismissedReportAt"
    }

    private let defaults: UserDefaults
    private(set) var pending: CrashReportFile?

    init(defaults: UserDefaults = .standard, now: Date = Date(), reports: [CrashReportFile]? = nil) {
        self.defaults = defaults
        let previousLaunch = defaults.object(forKey: Key.lastLaunch) as? Date
        let dismissed = defaults.object(forKey: Key.dismissed) as? Date
        if let report = CrashReports.newest(after: previousLaunch, in: reports ?? CrashReports.find()), dismissed.map({ report.date > $0 }) ?? true {
            pending = report
        }
        defaults.set(now, forKey: Key.lastLaunch)
        #if DEBUG
        TestProfile.log("DIAG crash notice: \(pending.map { "pending for \($0.name)" } ?? "none")")
        #endif
    }

    /// Hides the notice for good (this report). A newer crash would show it again.
    func dismiss() {
        if let report = pending { defaults.set(report.date, forKey: Key.dismissed) }
        pending = nil
    }
}
