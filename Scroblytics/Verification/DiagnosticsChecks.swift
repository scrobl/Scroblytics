import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_DIAGNOSTICS_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): Help › Report a Problem. The text cleaner,
/// the activity log, the crash-report finder and notice, and the summary, on made-up data, with no network and no Mail. Exits 0
/// on success.
enum DiagnosticsChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_DIAGNOSTICS_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let manager = FileManager.default
            let scratch = manager.temporaryDirectory.appending(path: "scroblytics-diag-check-\(UUID().uuidString)")
            try? manager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: scratch) }

            // MARK: The cleaner
            let mac = NSUserName()
            let key32 = "0123456789abcdef0123456789ABCDEF"
            let hostile = "Failed at \(NSHomeDirectory())/Library/x and /Users/someoneelse/Documents for \(mac), listener42 wrote jb@example.com, key=\(key32) api_key=ZZTOP9 sk=SESSIONVALUE api_sig=SIGVALUE token=TOK1 and a bare \(key32)"
            let secrets = [DiagnosticRedactor.Secret(value: "listener42", label: "username"), .init(value: "SECRETSHARED", label: "key")]
            let cleaned = DiagnosticRedactor.clean(hostile, secrets: secrets)
            check("the cleaner removes the home folder and other users' folders", !cleaned.contains(NSHomeDirectory()) && !cleaned.contains("someoneelse"), cleaned)
            check("it removes the Mac account name", mac.count < 3 || !cleaned.contains(mac), cleaned)
            check("it removes a known username", !cleaned.contains("listener42") && cleaned.contains("«username»"), cleaned)
            check("it removes an email address", !cleaned.contains("jb@example.com"), cleaned)
            check("it removes keys given as URL values", !cleaned.contains("ZZTOP9") && !cleaned.contains("SESSIONVALUE") && !cleaned.contains("SIGVALUE") && !cleaned.contains("TOK1"), cleaned)
            check("it removes a bare 32-digit key", !cleaned.contains(key32), cleaned)
            check("it removes a known secret", !DiagnosticRedactor.clean("x SECRETSHARED y", secrets: secrets).contains("SECRETSHARED"))
            check("a long line is cut to the limit", DiagnosticRedactor.clean(String(repeating: "word ", count: 200)).count <= DiagnosticRedactor.maxLineLength)
            check("a message with line breaks becomes one line", !DiagnosticRedactor.clean("one\ntwo\r\nthree").contains("\n"))
            check("ordinary text is left alone", DiagnosticRedactor.clean("Sync started (the first import)") == "Sync started (the first import)")

            // MARK: The log
            let logDir = scratch.appending(path: "log")
            let log = ActivityLog(directory: logDir)
            log.record(.sync, "first line")
            log.record(.network, hostile)
            log.flush()
            let lines = log.recentLines(10)
            let stamp = try! NSRegularExpression(pattern: "^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ \\[(sync|network|app)\\] ")
            check("a line has a timestamp and a category", lines.count == 2 && lines.allSatisfy { stamp.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }, "\(lines)")
            check("the log cleans each line when it is written", !(lines.last ?? "").contains(key32) && !(lines.last ?? "").contains(NSHomeDirectory()), lines.last ?? "")
            DispatchQueue.concurrentPerform(iterations: 8) { worker in
                for n in 0..<200 { log.record(.sync, "concurrent \(worker)-\(n)") }
            }
            log.flush()
            let all = log.recentLines(5000)
            check("1,600 writes from 8 threads all land, whole", all.count == 1602 && all.suffix(1600).allSatisfy { $0.range(of: "\\[sync\\] concurrent \\d-\\d+$", options: .regularExpression) != nil }, "\(all.count)")
            log.clear()
            check("clearing empties the log", log.lineCount == 0)

            // Trimming: more than the cap, written at launch and while running.
            let trimURL = scratch.appending(path: "trim")
            try? manager.createDirectory(at: trimURL, withIntermediateDirectories: true)
            let seeded = (0..<700).map { "2026-01-01T00:00:00Z [sync] seeded \($0)" }.joined(separator: "\n") + "\n"
            try? seeded.write(to: trimURL.appending(path: "activity.log"), atomically: true, encoding: .utf8)
            let trimmed = ActivityLog(directory: trimURL)
            trimmed.flush()
            let kept = trimmed.recentLines(5000)
            check("opening a log longer than the cap keeps the newest \(ActivityLog.maxLines)", kept.count == ActivityLog.maxLines && kept.last?.hasSuffix("seeded 699") == true && kept.first?.hasSuffix("seeded 200") == true, "\(kept.count) \(kept.first ?? "")")
            let bigDir = scratch.appending(path: "big")
            let big = ActivityLog(directory: bigDir)
            for n in 0..<900 { big.record(.sync, "n\(n) " + String(repeating: "x", count: 280)) }
            big.flush()
            let bigLines = big.recentLines(5000)
            check("a log that grows past its size limit is trimmed while running", bigLines.count < 700 && bigLines.last?.contains("n899 ") == true, "\(bigLines.count)")

            // MARK: Crash reports
            let reportsDir = scratch.appending(path: "reports")
            try? manager.createDirectory(at: reportsDir, withIntermediateDirectories: true)
            let now = Date()
            func make(_ name: String, ago: TimeInterval) {
                let url = reportsDir.appending(path: name)
                manager.createFile(atPath: url.path, contents: Data("x".utf8))
                try? manager.setAttributes([.modificationDate: now.addingTimeInterval(-ago)], ofItemAtPath: url.path)
            }
            make("Scroblytics-2026-10-11-100000.ips", ago: 3 * 3600)
            make("Scroblytics-2026-10-11-120000.ips", ago: 3600)
            make("Scroblytics_2026-10-06.crash", ago: 5 * 86400)
            make("OtherApp-2026-10-11-110000.ips", ago: 1800)
            make("Scroblytics-notes.txt", ago: 60)
            let found = CrashReports.find(in: reportsDir)
            check("only this app's reports are listed, newest first", found.map(\.name) == ["Scroblytics-2026-10-11-120000.ips", "Scroblytics-2026-10-11-100000.ips", "Scroblytics_2026-10-06.crash"], "\(found.map(\.name))")
            check("the limit is honoured", CrashReports.find(in: reportsDir, limit: 1).count == 1)
            check("a missing folder means none", CrashReports.find(in: scratch.appending(path: "nowhere")).isEmpty)
            check("a report after the previous launch counts, one before does not",
                  CrashReports.newest(after: now.addingTimeInterval(-7200), in: found)?.name == "Scroblytics-2026-10-11-120000.ips" && CrashReports.newest(after: now, in: found) == nil)
            check("with no previous launch there is no notice", CrashReports.newest(after: nil, in: found) == nil)
            check("finding reports never needs their contents (names and dates only)", found.allSatisfy { $0.date <= now })

            // The notice.
            let suite = "diag-check-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let t0 = Date()
            let first = CrashNoticeStore(defaults: defaults, now: t0, reports: found)
            check("the first launch ever shows no notice", first.pending == nil)
            let crash = CrashReportFile(url: reportsDir.appending(path: "Scroblytics-new.ips"), date: t0.addingTimeInterval(10))
            let second = CrashNoticeStore(defaults: defaults, now: t0.addingTimeInterval(20), reports: [crash] + found)
            check("a report written after the previous launch shows the notice", second.pending == crash)
            second.dismiss()
            check("dismissing hides it", second.pending == nil)
            let third = CrashNoticeStore(defaults: defaults, now: t0.addingTimeInterval(30), reports: [crash] + found)
            check("the next launch does not show it again", third.pending == nil)

            // MARK: The summary
            var inputs = DiagnosticSummary.Inputs()
            inputs.version = "9.9.9"; inputs.build = "42"; inputs.macOS = "Version 15.0"; inputs.architecture = "Apple silicon"
            inputs.model = "Mac99,1"; inputs.memoryGB = 16; inputs.scrobbles = 1234; inputs.artists = 56; inputs.accountConnected = true
            inputs.offline = true; inputs.askEngine = "Apple on-device"; inputs.resumePage = 12; inputs.resumeTotalPages = 340
            inputs.crashReports = found
            inputs.appMemoryMB = 412; inputs.appMemoryPeakMB = 916
            inputs.activity = ["2026-01-01T00:00:00Z [sync] user listener42 failed with key \(key32) at \(NSHomeDirectory())/x", "2026-01-01T00:00:01Z [sync] Sync started"]
            let text = DiagnosticSummary.render(inputs, secrets: secrets)
            check("the summary has the version, Mac, counts, resume point and Offline state",
                  text.contains("9.9.9 (build 42)") && text.contains("Mac99,1") && text.contains("1234 scrobbles, 56 artists") && text.contains("page 12 of 340") && text.contains("Offline mode: on"))
            check("the summary lists crash report names, not contents", text.contains("Scroblytics-2026-10-11-120000.ips") && !text.contains("\"x\""))
            check("the summary carries none of the seeded secrets", !text.contains("listener42") && !text.contains(key32) && !text.contains(NSHomeDirectory()), text)
            check("the summary shows the app's memory now and at its highest", text.contains("Memory in use by the app: 412 MB (highest 916 MB)"))
            let live = DiagnosticSummary.appMemory()
            check("the app can read its own memory footprint", (live.current ?? 0) > 10 && (live.peak ?? 0) >= (live.current ?? 0), "\(live)")
            check("the summary says the account is connected without naming it", text.contains("Last.fm account: connected"))
            var locked = inputs
            locked.accountConnected = false; locked.keychainProblem = errSecInteractionNotAllowed
            let lockedText = DiagnosticSummary.render(locked, secrets: secrets)
            check("a Keychain that can't be read is reported with its status, not as 'not connected'", lockedText.contains("Last.fm account: saved, but the Keychain can't be read (status \(errSecInteractionNotAllowed))") && !lockedText.contains("not connected"))
            var absent = inputs
            absent.accountConnected = false; absent.keychainProblem = nil
            check("no account and no problem still says not connected", DiagnosticSummary.render(absent, secrets: secrets).contains("Last.fm account: not connected"))
            var huge = inputs
            huge.activity = (0..<4000).map { "2026-01-01T00:00:00Z [sync] filler \($0) " + String(repeating: "y", count: 250) }
            let hugeText = DiagnosticSummary.render(huge, secrets: secrets)
            check("a huge log still gives a summary under the size cap, with the top intact", hugeText.utf8.count <= DiagnosticSummary.maxBytes && hugeText.contains("9.9.9 (build 42)"), "\(hugeText.utf8.count)")

            let real = await DiagnosticSummary.gather(container: container, loadCredentials: { LastfmCredentials(username: "listener42", apiKey: key32, apiSecret: nil, sessionKey: nil) })
            check("gathering from a store gives a summary for this version", real.text.contains("problem report summary") && real.inputs.accountConnected && !real.text.contains("listener42") && !real.text.contains(key32))
            check("gathering reads the real count from the store", real.inputs.scrobbles == ((try? container.mainContext.fetchCount(FetchDescriptor<Scrobble>())) ?? -1))

            // MARK: Nothing about music or the account reaches the log
            let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            var scanned = 0
            var offenders: [String] = []
            let interpolation = try! NSRegularExpression(pattern: "\\\\\\(([^)]*)\\)")
            let sensitive = try! NSRegularExpression(pattern: "\\b(artist|artists|album|albums|track|tracks|tag|tags|query|username|user|title|name)\\b", options: .caseInsensitive)
            if let subpaths = try? manager.subpathsOfDirectory(atPath: sourceRoot.path) {
                for url in subpaths.map({ sourceRoot.appending(path: $0) }) where url.pathExtension == "swift" && !url.path.contains("/Verification/") {
                    guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    for line in source.split(separator: "\n") where line.contains("ActivityLog.record(") {
                        scanned += 1
                        let text = String(line)
                        for match in interpolation.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                            guard let range = Range(match.range(at: 1), in: text) else { continue }
                            let inside = String(text[range])
                            if sensitive.firstMatch(in: inside, range: NSRange(inside.startIndex..., in: inside)) != nil { offenders.append("\(url.lastPathComponent): \(text.trimmingCharacters(in: .whitespaces))") }
                        }
                    }
                }
            }
            check("no log call interpolates an artist, album, track, tag, query, title or account name (\(scanned) calls read)", scanned > 5 && offenders.isEmpty, offenders.joined(separator: "; "))

            // MARK: This Mac's real reports folder (read-only)
            let onDisk = CrashReports.find(limit: 50)
            check("the real reports folder lists in date order", zip(onDisk, onDisk.dropFirst()).allSatisfy { $0.date >= $1.date })
            print("      (\(onDisk.count) Scroblytics crash report(s) found on this Mac)")

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
