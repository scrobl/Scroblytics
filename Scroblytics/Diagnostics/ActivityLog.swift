import Foundation

/// Cleans text before it is written to the activity log or shown in a diagnostic summary, so a report a person shares
/// carries no keys, no account names and no home-folder paths. It works on patterns (so it also catches what it was
/// not told about) and on exact values (the saved Last.fm username and keys, when the caller knows them).
enum DiagnosticRedactor {
    /// A value that must never appear in shared text, and what to show in its place.
    struct Secret: Sendable {
        let value: String
        let label: String
    }

    static let maxLineLength = 300

    private static let hex32 = try! NSRegularExpression(pattern: "\\b[0-9a-fA-F]{32}\\b")
    private static let email = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private static let urlKeys = try! NSRegularExpression(pattern: "\\b(api_key|apikey|api_sig|sk|token|key|secret)=([^&\\s\"']+)", options: .caseInsensitive)
    private static let otherHome = try! NSRegularExpression(pattern: "/Users/[^/\\s\"']+")

    /// One line, cleaned and cut to a sensible length.
    static func clean(_ text: String, secrets: [Secret] = []) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: " | ")
            .replacingOccurrences(of: "\n", with: " | ")
            .replacingOccurrences(of: "\r", with: " | ")
        // Exact values first: they are the surest.
        for secret in secrets where secret.value.count >= 3 {
            s = s.replacingOccurrences(of: secret.value, with: "«\(secret.label)»")
        }
        let home = NSHomeDirectory()
        if home.count > 1 { s = s.replacingOccurrences(of: home, with: "~") }
        s = replace(otherHome, in: s, with: "/Users/«user»")
        let account = NSUserName()
        if account.count >= 3 { s = s.replacingOccurrences(of: account, with: "«mac-user»") }
        s = replace(urlKeys, in: s, with: "$1=«hidden»")
        s = replace(email, in: s, with: "«email»")
        s = replace(hex32, in: s, with: "«key»")
        if s.count > maxLineLength { s = String(s.prefix(maxLineLength - 1)) + "…" }
        return s
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

/// A small rolling activity log on this Mac: what the app did and what went wrong, in plain words, so a person who hits a
/// problem has something to send besides "it didn't work". It records no music (no artist, album, track, tag or query text),
/// no account name and no keys, and it is only ever read by the person, through Help › Report a Problem. Nothing leaves the
/// Mac by itself. It keeps the newest few hundred lines.
final class ActivityLog: @unchecked Sendable {
    static let shared = ActivityLog()

    enum Category: String, Sendable {
        case app, sync, account, network, update, startup
    }

    /// Lines kept after a trim, and the size at which a trim happens.
    static let maxLines = 500
    static let trimBytes = 200_000

    private let queue = DispatchQueue(label: "app.scroblytics.activity-log", qos: .utility)
    private let fileURL: URL
    private var appendsSinceTrim = 0

    /// Where the log lives: next to the images in Application Support. A headless run on a scratch store keeps it beside that
    /// store, so a test never writes to the real log.
    static func defaultDirectory() -> URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SCROBLYTICS_STORE_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Scroblytics", directoryHint: .isDirectory)
    }

    init(directory: URL = ActivityLog.defaultDirectory()) {
        fileURL = directory.appending(path: "activity.log")
        queue.async { [self] in trimIfNeeded(force: true) }
    }

    var url: URL { fileURL }

    /// Adds one event. Never throws and never waits for the disk.
    func record(_ category: Category, _ message: String) {
        let line = "\(Self.timestamp()) [\(category.rawValue)] \(DiagnosticRedactor.clean(message))"
        queue.async { [self] in append(line) }
    }

    static func record(_ category: Category, _ message: String) {
        shared.record(category, message)
    }

    /// The newest `count` lines, oldest first.
    func recentLines(_ count: Int) -> [String] {
        queue.sync { Array(readLines().suffix(count)) }
    }

    var lineCount: Int { queue.sync { readLines().count } }

    /// Waits until everything recorded so far is on disk (for checks).
    func flush() { queue.sync {} }

    /// Empties the log (the Clear button).
    func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - Disk

    private func append(_ line: String) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: fileURL.path) { manager.createFile(atPath: fileURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            return // The log is a convenience; a full disk or a locked folder must never become the app's problem.
        }
        appendsSinceTrim += 1
        if appendsSinceTrim >= 50 { trimIfNeeded(force: false) }
    }

    private func readLines() -> [String] {
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Keeps the newest `maxLines` once the file has grown past the limit (always at launch, when the size is unknown).
    private func trimIfNeeded(force: Bool) {
        appendsSinceTrim = 0
        let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard size > 0, force || size > Self.trimBytes else { return }
        let lines = readLines()
        guard lines.count > Self.maxLines || size > Self.trimBytes else { return }
        let kept = lines.suffix(Self.maxLines).joined(separator: "\n") + "\n"
        try? Data(kept.utf8).write(to: fileURL, options: .atomic)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
