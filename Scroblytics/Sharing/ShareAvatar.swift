import AppKit
import CryptoKit
import SwiftUI

/// The account's Last.fm profile picture, for the card footer when the person chooses to show it with their name. It is asked of Last.fm
/// (`user.getInfo`, then the picture itself), kept as one small file in the app's folder and refreshed about once a week, so a card
/// never waits on the network once it has been fetched. Offline mode keeps whatever is already saved.
enum ShareAvatar {
    /// How long a saved picture is used before Last.fm is asked again.
    static let maxAge: TimeInterval = 7 * 86_400
    /// Bigger than any profile picture is (they are a few hundred pixels): anything larger isn't one.
    static let maxBytes = 3_000_000

    static func directory(base: URL = ActivityLog.defaultDirectory()) -> URL {
        base.appending(path: "ProfilePicture", directoryHint: .isDirectory)
    }

    /// One file per account name (hashed, so the name never appears in a file name).
    static func fileURL(username: String, base: URL = ActivityLog.defaultDirectory()) -> URL {
        let digest = SHA256.hash(data: Data(username.lowercased().utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return directory(base: base).appending(path: "\(digest).img")
    }

    /// The saved picture and how old it is, if there is one that is still a picture.
    static func cached(username: String, base: URL = ActivityLog.defaultDirectory(), now: Date = Date()) -> (data: Data, age: TimeInterval)? {
        let url = fileURL(username: username, base: base)
        guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return (data, max(0, now.timeIntervalSince(modified)))
    }

    /// The picture to draw: the saved one when it is fresh, otherwise a new one from Last.fm. A failed refresh (offline, rate-limited) still
    /// gives an older saved picture rather than none, and nothing is ever recorded as "no picture" because the network failed.
    @MainActor
    static func load(
        username: String,
        base: URL = ActivityLog.defaultDirectory(),
        now: Date = Date(),
        fetchURL: () async throws -> URL?,
        download: (URL) async throws -> Data
    ) async -> Data? {
        let saved = cached(username: username, base: base, now: now)
        if let saved, saved.age < maxAge { return saved.data }
        do {
            guard let url = try await fetchURL() else { return saved?.data }
            let data = try await download(url)
            guard data.count <= maxBytes, NSImage(data: data) != nil else { return saved?.data }
            let file = fileURL(username: username, base: base)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        } catch {
            return saved?.data
        }
    }

    /// `load` against Last.fm for the saved account. The Keychain is read (through the app's cached read) only when a fetch is needed.
    @MainActor
    static func loadFromLastfm(username: String) async -> Data? {
        await load(username: username, fetchURL: {
            guard let credentials = LastfmCredentialsStore.load() else { return nil }
            return try await LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username).fetchUserAvatarURL()
        }, download: { url in
            try ConnectivityGate.check(host: url.host)
            do {
                let data = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)).0
                ConnectivityHub.reportSuccess()
                return data
            } catch {
                ConnectivityHub.report(error, host: url.host, source: "Profile picture")
                throw error
            }
        })
    }
}

/// The profile picture as a circle, in front of the name in a card footer.
struct ShareAvatarView: View {
    let data: Data
    var size: CGFloat

    var body: some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.28), lineWidth: max(1, size / 24)) }
        }
    }
}
