import AppKit
import Foundation
import Security
import SwiftData

#if DEBUG
/// `SCROBLYTICS_PROFILE_LAUNCHER_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): drives the same code the
/// Test Profiles window uses, end to end. Starts a profile against the stand-in server with a made-up account, waits for
/// the first import, and checks the import against the server's own totals, that the profile app never opened the real
/// database or preferences, that real files and real Keychain items didn't change, and that Reset removes the profile
/// and only the profile.
enum TestProfileLauncherChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_PROFILE_LAUNCHER_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let launcher = TestProfileLauncher.shared
            let name = "launcher-check"
            let fm = FileManager.default
            let support = fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
            let realFiles = [
                support.appending(path: "default.store"),
                support.appending(path: "default.store-wal"),
                fm.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(AppIdentity.bundleID).plist"),
            ]
            func fingerprint(of urls: [URL]) -> [String] {
                urls.map { url in
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    return "\(url.lastPathComponent) \(attrs?[.size] ?? "absent") \(String(describing: attrs?[.modificationDate]))"
                }
            }
            func realKeychainDates() -> [String] {
                ["lastfm", "ask", "getsongbpm"].map { kind in
                    let query: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: "\(AppIdentity.bundleID).\(kind)",
                        kSecReturnAttributes as String: true,
                        kSecMatchLimit as String: kSecMatchLimitOne,
                    ]
                    var item: CFTypeRef?
                    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let attrs = item as? [String: Any] else { return "\(kind): absent" }
                    return "\(kind): \(String(describing: attrs[kSecAttrModificationDate as String]))"
                }
            }
            // The real app may be running and writing its own files; fingerprints are compared only for sizes and
            // dates that this check could not have changed (the profile app is audited separately with lsof).
            let realBefore = fingerprint(of: realFiles)
            let keychainBefore = realKeychainDates()

            try? launcher.reset(name: name)
            await launcher.loadScenarios()
            check("the stand-in scenarios are listed", launcher.scenarios.contains { $0.name == "small" } && launcher.scenarios.count >= 8, "\(launcher.scenarios.count)")

            do {
                _ = try await launcher.launch(name: "Bad Name", scenario: nil, seedAccount: false)
                check("a misspelled profile name is refused", false)
            } catch {
                check("a misspelled profile name is refused", true)
            }

            do {
                let pid = try await launcher.launch(name: name, scenario: "small", seedAccount: true)
                check("the profile app launched", pid > 0, "pid \(pid)")
                check("it is reported as running", launcher.running.contains(name))
                do {
                    _ = try await launcher.launch(name: name, scenario: "small", seedAccount: true)
                    check("starting a running profile twice is refused", false)
                } catch { check("starting a running profile twice is refused", true) }

                // Wait for the import into the profile's database.
                let store = TestProfileLauncher.folder(name).appending(path: "home/Library/Application Support/default.store")
                var scrobbles = 0, artists = 0, lastOutput = ""
                for _ in 0..<60 {
                    try? await Task.sleep(for: .seconds(1))
                    let out = TestProfileLauncher.run("/usr/bin/sqlite3", ["-readonly", store.path, "select (select count(*) from ZSCROBBLE), (select count(*) from ZARTIST);"]).output
                    lastOutput = out
                    let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|").compactMap { Int($0) }
                    if parts.count == 2, parts[0] > 0 { scrobbles = parts[0]; artists = parts[1]; if scrobbles == 50 { break } }
                }
                let appLog = (try? String(contentsOf: TestProfileLauncher.folder(name).appending(path: "app.log"), encoding: .utf8)) ?? "(no log)"
                check("the profile imported the stand-in's 50 scrobbles", scrobbles == 50, "got \(scrobbles); sqlite said “\(lastOutput.prefix(80))”; log: \(appLog.prefix(300))")
                check("…and its 5 artists", artists == 5, "got \(artists)")

                // The profile app must have no handle on the real database or preferences.
                let lsof = TestProfileLauncher.run("/usr/sbin/lsof", ["-p", String(pid)]).output
                let realOpen = lsof.split(separator: "\n").filter {
                    ($0.contains("Library/Application Support/default.store") || $0.contains("Library/Preferences/\(AppIdentity.bundleID).plist"))
                        && !$0.contains(TestProfileLauncher.rootPath) && !$0.contains("/private\(TestProfileLauncher.rootPath)")
                }
                check("the profile app never had your real database or preferences open", realOpen.isEmpty, realOpen.first.map(String.init) ?? "")
                check("it keeps its database in its own folder", lsof.contains("scroblytics-profiles/\(name)/home/Library/Application Support/default.store"), String(lsof.split(separator: "\n").filter { $0.contains("default.store") }.first ?? "no default.store handle"))

                // Quit it and confirm the stand-in server is stopped too.
                NSRunningApplication(processIdentifier: pid)?.terminate()
                for _ in 0..<30 where launcher.running.contains(name) { try? await Task.sleep(for: .seconds(1)) }
                check("closing the profile app is noticed", !launcher.running.contains(name))
            } catch {
                check("the profile launched", false, error.localizedDescription)
            }

            try? launcher.reset(name: name)
            check("Reset removes the profile folder", !fm.fileExists(atPath: TestProfileLauncher.folder(name).path))
            let leftover = ["lastfm", "ask", "getsongbpm"].contains { kind in
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "\(AppIdentity.bundleID).\(kind).profile.\(name)"]
                return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
            }
            check("Reset removes the profile's Keychain items", !leftover)
            check("Reset removes the profile's preferences file", !fm.fileExists(atPath: fm.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(TestProfileLauncher.bundleID(name)).plist").path))
            check("your real Keychain items are unchanged", realKeychainDates() == keychainBefore)
            let realAfter = fingerprint(of: realFiles)
            // The real store may be written by a real app running at the same time; only the preferences file is compared strictly.
            check("your real preferences file is unchanged", realAfter.last == realBefore.last)
            print("      (real store before/after, informational: \(realBefore.first ?? "") → \(realAfter.first ?? ""))")
            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
