import AppKit
import Foundation
import Security

#if DEBUG
/// Starts and resets test profiles (see `TestProfile`) from inside the Debug app, what `scripts/first-run-profile.sh`
/// does, without a terminal. It never changes the app it runs in: it makes a copy of this app with its own bundle
/// identifier, and launches that as a separate app with a redirected home folder. The copy refuses to start unless
/// everything is isolated (`TestProfile.enforce`).
@MainActor
@Observable
final class TestProfileLauncher {
    static let shared = TestProfileLauncher()

    struct Scenario: Identifiable, Hashable {
        let name: String
        let detail: String
        var id: String { name }
    }

    struct Profile: Identifiable {
        let name: String
        let modified: Date?
        var id: String { name }
    }

    enum LaunchError: LocalizedError {
        case badName, alreadyRunning, copyFailed(String), signFailed(String), standInFailed(String), launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .badName: "A profile name is lowercase letters, digits and hyphens."
            case .alreadyRunning: "That profile is already running."
            case .copyFailed(let why): "Couldn’t copy the app: \(why)"
            case .signFailed(let why): "Couldn’t sign the copy: \(why)"
            case .standInFailed(let why): "Couldn’t start the stand-in Last.fm server: \(why)"
            case .launchFailed(let why): "Couldn’t launch the profile: \(why)"
            }
        }
    }

    /// Where profiles live. The profile app refuses any home folder outside /tmp.
    nonisolated static let rootPath = "/tmp/scroblytics-profiles"
    nonisolated static func folder(_ name: String) -> URL { URL(fileURLWithPath: rootPath).appending(path: name) }
    nonisolated static func bundleID(_ name: String) -> String { "\(AppIdentity.bundleID).profile.\(name)" }

    /// The project folder, found from this source file's own location at compile time (Debug builds only).
    nonisolated static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    nonisolated static var standInScript: URL { projectRoot.appending(path: "scripts/fake-lastfm.py") }

    /// Set once at launch: Option was held, so the Test Profiles window should open by itself.
    nonisolated(unsafe) static var optionHeldAtLaunch = false
    private var openedForOption = false
    /// True the first time it's asked, if Option was held at launch.
    func consumeOptionRequest() -> Bool {
        guard Self.optionHeldAtLaunch, !openedForOption else { return false }
        openedForOption = true
        return true
    }

    private(set) var status = ""
    private(set) var isWorking = false
    private(set) var scenarios: [Scenario] = []
    private(set) var profiles: [Profile] = []
    private(set) var running: Set<String> = []

    private var standIns: [String: Process] = [:]

    // MARK: Listing

    func refresh() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Self.rootPath)) ?? []
        profiles = names.filter { TestProfile.isValid(name: $0) }.sorted().map { name in
            let attrs = try? fm.attributesOfItem(atPath: Self.folder(name).path)
            return Profile(name: name, modified: attrs?[.modificationDate] as? Date)
        }
    }

    func loadScenarios() async {
        guard scenarios.isEmpty else { return }
        let script = Self.standInScript.path
        let output = await Task.detached { Self.run("/usr/bin/env", ["python3", "-I", script, "--list"]).output }.value
        scenarios = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? Scenario(name: parts[0], detail: parts[1]) : nil
        }
    }

    // MARK: Launch

    /// Prepares and starts `name`. `scenario` nil = real Last.fm; otherwise a stand-in server with that scenario.
    /// Returns the process id of the profile app.
    @discardableResult
    func launch(name: String, scenario: String?, seedAccount: Bool) async throws -> pid_t {
        guard TestProfile.isValid(name: name) else { throw LaunchError.badName }
        guard !running.contains(name) else { throw LaunchError.alreadyRunning }
        isWorking = true
        defer { isWorking = false }

        status = "Preparing a copy of the app…"
        let folder = Self.folder(name)
        let home = folder.appending(path: "home")
        let appCopy = folder.appending(path: "Scroblytics.app")
        let source = Bundle.main.bundleURL
        let bundleID = Self.bundleID(name)
        let signError: String? = try await Task.detached { () -> String? in
            let fm = FileManager.default
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            if fm.fileExists(atPath: appCopy.path) { try fm.removeItem(at: appCopy) }
            do { try fm.copyItem(at: source, to: appCopy) } catch { throw LaunchError.copyFailed(error.localizedDescription) }
            let plistURL = appCopy.appending(path: "Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw LaunchError.copyFailed("Info.plist unreadable")
            }
            plist["CFBundleIdentifier"] = bundleID
            plist["CFBundleName"] = "Scroblytics-\(name)"
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
            let result = Self.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", appCopy.path])
            return result.status == 0 ? nil : result.output
        }.value
        if let signError { throw LaunchError.signFailed(signError) }

        var environment = [
            "CFFIXED_USER_HOME": home.path,
            "SCROBLYTICS_PROFILE": name,
        ]
        if let scenario {
            status = "Starting the stand-in Last.fm server (\(scenario))…"
            let port = try await startStandIn(for: name, scenario: scenario)
            environment["SCROBLYTICS_LASTFM_BASE_URL"] = "http://127.0.0.1:\(port)/2.0/"
            if seedAccount { environment["SCROBLYTICS_PROFILE_SEED_ACCOUNT"] = "1" }
        }

        status = "Launching…"
        // `open` starts the copy as its own app, with the environment below, and sends its startup message (or the
        // isolation check's refusal) to a log in the profile folder.
        let log = folder.appending(path: "app.log")
        try? FileManager.default.removeItem(at: log)
        var arguments = ["-n"]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { arguments += ["--env", "\(key)=\(value)"] }
        arguments += ["--stdout", log.path, "--stderr", log.path, appCopy.path]
        // A clean environment for `open`, so nothing from this app's own launch (a copied-store path, Offline mode, other
        // debug switches) leaks into the profile copy: it gets exactly the variables above.
        let opened = await Task.detached { Self.run("/usr/bin/open", arguments, environment: ["PATH": "/usr/bin:/bin"]) }.value
        guard opened.status == 0 else {
            stopStandIn(name)
            throw LaunchError.launchFailed(opened.output)
        }
        var found: NSRunningApplication?
        for _ in 0..<40 {
            found = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
            if found != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let app = found else {
            stopStandIn(name)
            let message = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LaunchError.launchFailed(message.isEmpty ? "the app didn’t start" : message)
        }
        running.insert(name)
        status = "“\(name)” is running\(scenario.map { " against the stand-in server (\($0))" } ?? " against real Last.fm")."
        refresh()
        Task { await watch(app, name: name) }
        return app.processIdentifier
    }

    /// Waits for the profile app to quit, then stops its stand-in server.
    private func watch(_ app: NSRunningApplication, name: String) async {
        while !app.isTerminated { try? await Task.sleep(for: .seconds(1)) }
        running.remove(name)
        stopStandIn(name)
        status = "“\(name)” closed."
        refresh()
    }

    // MARK: Stand-in server

    private func startStandIn(for name: String, scenario: String) async throws -> Int {
        stopStandIn(name)
        let script = Self.standInScript.path
        guard FileManager.default.fileExists(atPath: script) else { throw LaunchError.standInFailed("scripts/fake-lastfm.py not found") }
        guard let port = Self.freePort() else { throw LaunchError.standInFailed("no free port") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", script, "--scenario", scenario, "--port", String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw LaunchError.standInFailed(error.localizedDescription) }
        standIns[name] = process
        let url = URL(string: "http://127.0.0.1:\(port)/__stats")!
        for _ in 0..<40 {
            if (try? await URLSession.shared.data(from: url)) != nil { return port }
            try? await Task.sleep(for: .milliseconds(150))
        }
        stopStandIn(name)
        throw LaunchError.standInFailed("it didn’t answer")
    }

    private func stopStandIn(_ name: String) {
        standIns.removeValue(forKey: name)?.terminate()
    }

    /// What the stand-in server for `name` has served so far (`/__stats`), for checks.
    func standInStats(port: Int) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/__stats"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Reset

    /// Deletes the profile's data folder, its preferences and the Keychain items filed under its own service names,
    /// and nothing else. A running profile can't be reset.
    func reset(name: String) throws {
        guard TestProfile.isValid(name: name) else { throw LaunchError.badName }
        guard !running.contains(name) else { throw LaunchError.alreadyRunning }
        try? FileManager.default.removeItem(at: Self.folder(name))
        for kind in ["lastfm", "ask", "getsongbpm"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "\(AppIdentity.bundleID).\(kind).profile.\(name)",
            ]
            while SecItemDelete(query as CFDictionary) == errSecSuccess {}
        }
        let id = Self.bundleID(name)
        _ = Self.run("/usr/bin/defaults", ["delete", id])
        try? FileManager.default.removeItem(
            at: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(id).plist"))
        status = "Profile “\(name)” reset."
        refresh()
    }

    // MARK: Helpers

    nonisolated static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A port nothing on this Mac is listening on right now.
    nonisolated static func freePort() -> Int? {
        for port in 8800..<9000 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if bound == 0 { return port }
        }
        return nil
    }
}
#endif
