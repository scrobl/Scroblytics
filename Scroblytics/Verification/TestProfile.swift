import Foundation
import SwiftUI

#if DEBUG
/// A named, isolated copy of the app's world, for testing the first run without touching real data.
/// `scripts/first-run-profile.sh <name>` launches a copy of the Debug app that has its own bundle identifier (so its
/// preferences are separate), a redirected home folder (`CFFIXED_USER_HOME`, so the store, images and caches are
/// separate) and, through `AppIdentity.keychainService`, its own Keychain items.
///
/// Because a mistake here would mean a "test" opening the real store, `enforce` runs before the store is created and
/// stops the app unless every one of those is actually isolated.
enum TestProfile {
    /// The profile name from `SCROBLYTICS_PROFILE`, or nil for a normal run. A malformed name stops the app.
    static let name: String? = {
        guard let raw = ProcessInfo.processInfo.environment["SCROBLYTICS_PROFILE"], !raw.isEmpty else { return nil }
        guard isValid(name: raw) else { stop("SCROBLYTICS_PROFILE must be lowercase letters, digits and hyphens (got “\(raw)”).") }
        return raw
    }()

    static func isValid(name: String) -> Bool {
        name.range(of: "^[a-z0-9][a-z0-9-]{0,30}$", options: .regularExpression) != nil
    }

    /// The loopback address a stand-in Last.fm server listens on (`SCROBLYTICS_LASTFM_BASE_URL`), if one was given.
    /// Anything that isn't this Mac stops the app, so a test can never be pointed at someone else's server.
    static let lastfmBaseURLOverride: String? = {
        guard let raw = ProcessInfo.processInfo.environment["SCROBLYTICS_LASTFM_BASE_URL"], !raw.isEmpty else { return nil }
        guard name != nil else { stop("SCROBLYTICS_LASTFM_BASE_URL only works under a test profile (SCROBLYTICS_PROFILE).") }
        guard let url = URL(string: raw), ConnectivityGate.isLoopback(host: url.host) else {
            stop("SCROBLYTICS_LASTFM_BASE_URL must point at this Mac (localhost / 127.0.0.1).")
        }
        return raw.hasSuffix("/") ? raw : raw + "/"
    }()

    /// Where the update notice asks for the list of releases (`SCROBLYTICS_UPDATE_FEED_URL`), for testing it against a stand-in on
    /// this Mac. Only under a test profile and only a loopback address, so a test can never be pointed at anyone else.
    static let updateFeedURLOverride: URL? = {
        guard let raw = ProcessInfo.processInfo.environment["SCROBLYTICS_UPDATE_FEED_URL"], !raw.isEmpty else { return nil }
        guard name != nil else { stop("SCROBLYTICS_UPDATE_FEED_URL only works under a test profile (SCROBLYTICS_PROFILE).") }
        guard let url = URL(string: raw), ConnectivityGate.isLoopback(host: url.host) else {
            stop("SCROBLYTICS_UPDATE_FEED_URL must point at this Mac (localhost / 127.0.0.1).")
        }
        return url
    }()

    /// Where the crash-report finder looks (`SCROBLYTICS_DIAGNOSTIC_REPORTS_DIR`), so the "quit unexpectedly" notice can be tested with
    /// made-up report files. Only under a test profile and only a folder inside /tmp, never the real reports folder.
    static let crashReportsFolderOverride: URL? = {
        guard let raw = ProcessInfo.processInfo.environment["SCROBLYTICS_DIAGNOSTIC_REPORTS_DIR"], !raw.isEmpty else { return nil }
        guard name != nil else { stop("SCROBLYTICS_DIAGNOSTIC_REPORTS_DIR only works under a test profile (SCROBLYTICS_PROFILE).") }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        guard url.path.hasPrefix("/tmp/") || url.path.hasPrefix("/private/tmp/") else { stop("SCROBLYTICS_DIAGNOSTIC_REPORTS_DIR must be a folder inside /tmp.") }
        return url
    }()

    /// With `SCROBLYTICS_PROFILE_SEED_ACCOUNT=1`, a stand-in Last.fm server and a profile that has no account yet, saves
    /// made-up credentials (the app writes its own Keychain item, so macOS doesn't ask about access) so the app starts
    /// syncing at launch. Real credentials are never touched: a profile has its own item, and the stand-in server is
    /// the only thing that accepts these values.
    static func seedAccountIfRequested() {
        guard name != nil, lastfmBaseURLOverride != nil,
              ProcessInfo.processInfo.environment["SCROBLYTICS_PROFILE_SEED_ACCOUNT"] != nil,
              LastfmCredentialsStore.load() == nil else { return }
        try? LastfmCredentialsStore.save(LastfmCredentials(
            username: "tester", apiKey: "0123456789abcdef0123456789abcdef", apiSecret: nil, sessionKey: nil
        ))
    }

    /// With `SCROBLYTICS_PROFILE_SEED_LASTFM=username:apikey`, saves a REAL Last.fm account into the test profile's own Keychain item (never
    /// the real one: the profile has its own), so a profile can run a true, read-only first import without typing into the Welcome screen.
    /// Only under a test profile, and only while the profile has no account yet. Nothing is written to Last.fm.
    static func seedRealLastfmAccountIfRequested() {
        guard name != nil, let pair = ProcessInfo.processInfo.environment["SCROBLYTICS_PROFILE_SEED_LASTFM"],
              LastfmCredentialsStore.load() == nil else { return }
        let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return }
        try? LastfmCredentialsStore.save(LastfmCredentials(username: parts[0], apiKey: parts[1], apiSecret: nil, sessionKey: nil))
    }

    /// With `SCROBLYTICS_PROFILE_AUTOCONNECT=username:apikey` (stand-in server only), fills in the account form and presses
    /// Test & Save a few seconds after launch, as a person would, and prints what happened. For repeatable first-run
    /// tests of each stand-in scenario without typing.
    @MainActor
    static func autoConnectIfRequested() {
        guard name != nil, lastfmBaseURLOverride != nil,
              let pair = ProcessInfo.processInfo.environment["SCROBLYTICS_PROFILE_AUTOCONNECT"] else { return }
        let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            let form = LastfmAccountForm()
            form.username = parts[0]
            form.apiKey = parts[1]
            let ok = await form.testAndSave()
            FileHandle.standardError.write(Data("AUTOCONNECT saved=\(ok) result=\(form.phase)\n".utf8))
        }
    }

    /// A line on stderr, only under a test profile, so a scripted run can see what the app decided.
    static func log(_ message: String) {
        guard name != nil else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// With `SCROBLYTICS_PROFILE_STOP_AFTER=<seconds>`, presses Stop that many seconds after launch.
    @MainActor
    static func stopAfterIfRequested() {
        guard name != nil, let raw = ProcessInfo.processInfo.environment["SCROBLYTICS_PROFILE_STOP_AFTER"], let seconds = Double(raw) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            log("STOP requested")
            NotificationCenter.default.post(name: .syncStopRequested, object: nil)
        }
    }

    /// With `SCROBLYTICS_PROFILE_RETRY_AFTER=<seconds>`, presses Retry/Sync (a normal sync request) that long after launch.
    @MainActor
    static func retryAfterIfRequested() {
        guard name != nil, let raw = ProcessInfo.processInfo.environment["SCROBLYTICS_PROFILE_RETRY_AFTER"], let seconds = Double(raw) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            log("RETRY requested")
            NotificationCenter.default.post(name: .syncRequested, object: nil)
        }
    }

    /// This user's real home folder, which a profile must never use.
    static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Where a profile keeps its database: under the (redirected) Application Support folder.
    static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// The facts `enforce` checks, separated out so the check can be tested with made-up values.
    struct Environment {
        var profile: String
        var home: String
        var realHome: String
        var bundleID: String
        var storePath: String
        var keychainService: String
    }

    /// A path with `.`/`..` removed and the `/private` prefix of /tmp and /var dropped, so the two spellings compare equal.
    static func normalized(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        for root in ["/private/tmp", "/private/var"] where p == root || p.hasPrefix(root + "/") { p.removeFirst("/private".count) }
        return p
    }

    /// The reasons this environment is not isolated from the real one; empty when it is safe.
    static func problems(in env: Environment) -> [String] {
        var found: [String] = []
        let home = normalized(env.home)
        let real = normalized(env.realHome)
        let allowedRoots = ["/tmp/", "/var/folders/"]
        if home == real { found.append("home folder is your real home folder") }
        if !allowedRoots.contains(where: { (home + "/").hasPrefix($0) }) {
            found.append("home folder isn’t under /tmp or a temporary folder (\(home))")
        }
        if env.bundleID != "\(AppIdentity.bundleID).profile.\(env.profile)" {
            found.append("bundle identifier is \(env.bundleID), so preferences are not separate")
        }
        let store = normalized(env.storePath)
        if !store.hasPrefix(home + "/") { found.append("database isn’t inside the profile’s home folder (\(store))") }
        if !env.keychainService.hasSuffix(".profile.\(env.profile)") { found.append("Keychain items aren’t profile-specific") }
        return found
    }

    /// Call before anything opens the store. A normal run (no profile) does nothing.
    static func enforce(storePath: String) {
        guard let name else { return }
        let env = Environment(
            profile: name, home: NSHomeDirectory(), realHome: realHome,
            bundleID: Bundle.main.bundleIdentifier ?? "", storePath: storePath,
            keychainService: AppIdentity.keychainService("lastfm")
        )
        let problems = problems(in: env)
        if !problems.isEmpty {
            stop("Test profile “\(name)” is not isolated from your real data:\n  - " + problems.joined(separator: "\n  - ")
                + "\nStart it with scripts/first-run-profile.sh \(name).")
        }
        FileHandle.standardError.write(Data("""
        TEST PROFILE “\(name)” — isolated.
          home:      \(env.home)
          database:  \(env.storePath)
          bundle id: \(env.bundleID)
          keychain:  \(env.keychainService)
          last.fm:   \(lastfmBaseURLOverride ?? "real Last.fm")

        """.utf8))
    }

    private static func stop(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\n[TestProfile] \(message)\n".utf8))
        exit(2)
    }
}

/// A coloured strip across the top of a test-profile window, so it can't be mistaken for the real app.
/// Runs a headless hook's work on the main actor and reports an error it throws (and exits with failure), instead of leaving the
/// unused task to swallow it and the hook sitting there.
enum HeadlessTask {
    /// The last lines of a headless check run: what release.sh looks for, then the exit status.
    nonisolated static func finish(_ failures: Int) -> Never {
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    nonisolated static func run(_ name: String, _ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await body() } catch {
                print("[\(name)] failed: \(error)")
                exit(1)
            }
        }
    }
}

struct TestProfileStrip: View {
    var body: some View {
        if let name = TestProfile.name {
            Text("TEST PROFILE “\(name)” — separate database, preferences and Keychain items\(TestProfile.lastfmBaseURLOverride == nil ? "" : " · stand-in Last.fm")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Color.yellow)
        }
    }
}

/// `SCROBLYTICS_PROFILE_CHECK=1`: the isolation rules, tried on made-up environments. Exits 0 on success, 1 on failure.
enum TestProfileChecks {
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_PROFILE_CHECK"] != nil else { return }
        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            print((ok ? "PASS  " : "FAIL  ") + label)
            if !ok { failures += 1 }
        }
        let good = TestProfile.Environment(
            profile: "t1", home: "/private/tmp/scroblytics-profiles/t1/home", realHome: "/Users/someone",
            bundleID: "\(AppIdentity.bundleID).profile.t1",
            storePath: "/private/tmp/scroblytics-profiles/t1/home/Library/Application Support/default.store",
            keychainService: "\(AppIdentity.bundleID).lastfm.profile.t1"
        )
        check("an isolated environment has no problems", TestProfile.problems(in: good).isEmpty)
        TestProfile.problems(in: good).forEach { print("      problem: \($0)") }
        var env = good; env.home = "/tmp/scroblytics-profiles/t1/home"
        env.storePath = "/tmp/scroblytics-profiles/t1/home/Library/Application Support/default.store"
        check("the /tmp spelling of a profile folder is accepted", TestProfile.problems(in: env).isEmpty)
        env = good; env.home = "/Users/someone"
        check("real home folder is refused", !TestProfile.problems(in: env).isEmpty)
        env = good; env.home = "/Users/someone/Documents/fake"
        check("a home folder outside /tmp is refused", !TestProfile.problems(in: env).isEmpty)
        env = good; env.bundleID = AppIdentity.bundleID
        check("the real bundle identifier is refused (preferences would be shared)", !TestProfile.problems(in: env).isEmpty)
        env = good; env.bundleID = "\(AppIdentity.bundleID).profile.other"
        check("another profile’s bundle identifier is refused", !TestProfile.problems(in: env).isEmpty)
        env = good; env.storePath = "/Users/someone/Library/Application Support/default.store"
        check("the real database path is refused", !TestProfile.problems(in: env).isEmpty)
        env = good; env.keychainService = "\(AppIdentity.bundleID).lastfm"
        check("the real Keychain service name is refused", !TestProfile.problems(in: env).isEmpty)
        check("profile names: valid", TestProfile.isValid(name: "first-run-2"))
        check("profile names: path tricks refused", !TestProfile.isValid(name: "../x") && !TestProfile.isValid(name: "A b") && !TestProfile.isValid(name: ""))
        check("Keychain service names carry the profile only when one is set", TestProfile.name != nil || AppIdentity.keychainService("lastfm") == "\(AppIdentity.bundleID).lastfm")
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
