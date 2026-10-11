import Foundation

/// A released version: three whole numbers, such as `0.9.1` (a leading `v`, as in a Git tag, is accepted).
struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        parts = numbers
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    var description: String { parts.map(String.init).joined(separator: ".") }

    /// The version of the running app.
    static var running: AppVersion {
        #if DEBUG
        if let pretend = ProcessInfo.processInfo.environment["SCROBLYTICS_UPDATE_CURRENT_VERSION"], let version = AppVersion(pretend) { return version }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init) ?? AppVersion("0.0.0")!
    }
}

/// One published release, as far as the update notice cares.
struct ReleaseInfo: Equatable, Sendable {
    let version: AppVersion
    let tag: String
    let pageURL: URL
    let isPrerelease: Bool
}

enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(ReleaseInfo)
    /// Offline mode is on; nothing was sent.
    case offline
    case failed(String)
}

/// Reads GitHub's public list of this project's releases. Read-only, no sign-in, nothing identifying is sent beyond the app's
/// name and version (which GitHub asks every client to send). It never downloads or installs anything.
enum UpdateFeed {
    /// Release pages must live in this repository; an answer pointing anywhere else is ignored.
    static let releasePagePrefix = "https://github.com/scrobl/Scroblytics/"
    /// `releases/latest` skips pre-releases, so the list is read and the highest version chosen.
    static let defaultURL = URL(string: "https://api.github.com/repos/scrobl/Scroblytics/releases?per_page=10")!

    private struct Entry: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
    }

    /// The usable releases in an answer (drafts, tags that aren't `vX.Y.Z` and pages outside this repository are left out), or nil
    /// when the answer isn't a release list at all.
    static func parse(_ data: Data) -> [ReleaseInfo]? {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        return entries.compactMap { entry in
            guard !entry.draft, let version = AppVersion(entry.tag_name), entry.html_url.hasPrefix(releasePagePrefix),
                  let url = URL(string: entry.html_url) else { return nil }
            return ReleaseInfo(version: version, tag: entry.tag_name, pageURL: url, isPrerelease: entry.prerelease)
        }
    }

    static func newest(in releases: [ReleaseInfo]) -> ReleaseInfo? { releases.max { $0.version < $1.version } }
}

enum UpdateChecker {
    /// Asks GitHub whether a version newer than `current` exists. Stops at once, sending nothing, while Offline mode is on.
    static func check(current: AppVersion, feedURL: URL = UpdateFeed.defaultURL, session: URLSession = makeSession()) async -> UpdateCheckResult {
        do { try ConnectivityGate.check(host: feedURL.host) } catch { return .offline }
        var request = URLRequest(url: feedURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Scroblytics/\(current)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch is CancellationError {
            return .failed("Cancelled.")
        } catch {
            return .failed("Couldn’t reach GitHub. Check your internet connection.")
        }
        guard let http = response as? HTTPURLResponse else { return .failed("GitHub sent an answer the app couldn’t read.") }
        switch http.statusCode {
        case 200: break
        case 403, 429: return .failed("GitHub is limiting requests right now. Try again later.")
        case 404: return .failed("The list of releases wasn’t found.")
        default: return .failed("GitHub answered with an error (\(http.statusCode)).")
        }
        guard let releases = UpdateFeed.parse(data) else { return .failed("GitHub sent an answer the app couldn’t read.") }
        guard let newest = UpdateFeed.newest(in: releases), newest.version > current else { return .upToDate }
        return .available(newest)
    }

    /// A session with no cookies, cache or stored credentials.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }
}
