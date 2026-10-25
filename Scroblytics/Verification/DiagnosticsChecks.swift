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

            // MARK: The sync's own lines say what kind of sync it was and why
            typealias W = SyncLogWording
            check("a quick sync that found everything Last.fm added does not escalate, and neither does a first look at a matching total", W.escalation(previousTotal: 100, remoteTotal: 110, found: 10, onThisMac: 100) == nil && W.escalation(previousTotal: 100, remoteTotal: 100, found: 0, onThisMac: 100) == nil && W.escalation(previousTotal: nil, remoteTotal: 100, found: 0, onThisMac: 100) == nil)
            check("Last.fm's total rising by more than the quick sync found escalates, and says by how much (late plays)", W.escalation(previousTotal: 100, remoteTotal: 110, found: 3, onThisMac: 103) == .totalGrewMoreThanFound(grew: 10, found: 3))
            check("Last.fm's total falling escalates (deleted plays)", W.escalation(previousTotal: 100, remoteTotal: 95, found: 0, onThisMac: 100) == .totalFell(by: 5))
            check("with no earlier total, fewer plays here than on Last.fm escalates", W.escalation(previousTotal: nil, remoteTotal: 100, found: 0, onThisMac: 90) == .fewerHereThanLastfm(onThisMac: 90, onLastfm: 100))
            let syncLines = [
                W.planLine(mode: .incremental, requestedFull: false, onThisMac: 1_234, onLastfm: 1_240, resumePage: nil),
                W.planLine(mode: .full, requestedFull: false, onThisMac: 0, onLastfm: 5_000, resumePage: nil),
                W.planLine(mode: .full, requestedFull: true, onThisMac: 1_234, onLastfm: 1_240, resumePage: nil),
                W.planLine(mode: .resumedBackfill, requestedFull: false, onThisMac: 800, onLastfm: 5_000, resumePage: 7),
                W.escalationLine(.totalGrewMoreThanFound(grew: 10, found: 3)), W.escalationLine(.totalFell(by: 5)), W.escalationLine(.fewerHereThanLastfm(onThisMac: 90, onLastfm: 100)),
                W.recheckResultLine(added: 7, updated: 0, removed: 2, complete: true), W.recheckResultLine(added: 0, updated: 0, removed: 0, complete: false),
            ]
            check("each kind of sync has its own plan line with both totals", syncLines[0].contains("quick check") && syncLines[0].contains("1,234") && syncLines[0].contains("1,240") && syncLines[1].contains("first import") && syncLines[2].contains("full resync, as asked") && syncLines[3].contains("resuming") && syncLines[3].contains("page 7"), syncLines.prefix(4).joined(separator: " | "))
            check("the escalation lines give the reason in numbers, and the result line says what the re-check changed", syncLines[4].contains("went up by 10") && syncLines[4].contains("found 3 new plays") && syncLines[5].contains("went down by 5") && syncLines[6].contains("90") && syncLines[7].contains("added 7") && syncLines[7].contains("removed 2") && syncLines[7].contains("finished") && syncLines[8].contains("paused"), syncLines.dropFirst(4).joined(separator: " | "))
            let sensitiveWords = try! NSRegularExpression(pattern: "\\b(artist|artists|album|albums|track|tracks|tag|tags|query|username|user|title|name)\\b", options: .caseInsensitive)
            check("none of those lines can carry music or account words", syncLines.allSatisfy { sensitiveWords.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }, syncLines.joined(separator: " | "))

            // MARK: Re-checking only the recent stretch
            typealias P = SyncRecheckPlan
            let now0 = Date(timeIntervalSince1970: 1_800_000_000)
            let twoDaysAgo = now0.addingTimeInterval(-2 * 86_400)
            let grew = SyncLogWording.Escalation.totalGrewMoreThanFound(grew: 10, found: 3)
            let start = P.windowStart(escalation: grew, lastSyncedAt: twoDaysAgo, now: now0)
            check("the window starts 15 days before the last sync (late plays are at most two weeks old, plus a day), and is 17 days long here", start == Int(twoDaysAgo.timeIntervalSince1970) - 15 * 86_400 && start.map { P.days(from: $0, to: Int(now0.timeIntervalSince1970)) } == 17, "\(String(describing: start))")
            check("a deletion is also looked for in the window", P.windowStart(escalation: .totalFell(by: 2), lastSyncedAt: twoDaysAgo, now: now0) != nil)
            check("no window without an earlier sync, or for a first comparison of totals", P.windowStart(escalation: grew, lastSyncedAt: nil, now: now0) == nil && P.windowStart(escalation: .fewerHereThanLastfm(onThisMac: 1, onLastfm: 2), lastSyncedAt: twoDaysAgo, now: now0) == nil)
            check("a window is tried when the last sync was 40 days ago (55 days) but not 50 days ago (65 days, over 60)", P.windowStart(escalation: grew, lastSyncedAt: now0.addingTimeInterval(-40 * 86_400), now: now0) != nil && P.windowStart(escalation: grew, lastSyncedAt: now0.addingTimeInterval(-50 * 86_400), now: now0) == nil)
            check("the totals match when the change in Last.fm's total is what was added less what was removed: +10 = 10 added, +10 = 12 added and 2 removed, −5 = 5 removed", P.totalsMatch(previousTotal: 100, remoteTotal: 110, added: 10, removed: 0) && P.totalsMatch(previousTotal: 100, remoteTotal: 110, added: 12, removed: 2) && P.totalsMatch(previousTotal: 100, remoteTotal: 95, added: 0, removed: 5))
            check("they don't match when something is still missing: +10 with only 3 found, −5 with nothing removed, +10 with 12 found and none removed", !P.totalsMatch(previousTotal: 100, remoteTotal: 110, added: 3, removed: 0) && !P.totalsMatch(previousTotal: 100, remoteTotal: 95, added: 0, removed: 0) && !P.totalsMatch(previousTotal: 100, remoteTotal: 110, added: 12, removed: 0))
            let windowLines = [
                SyncLogWording.windowStartLine(days: 17),
                SyncLogWording.windowResultLine(days: 17, matched: true, added: 7, removed: 0, expectedChange: 10, actualChange: 10),
                SyncLogWording.windowResultLine(days: 17, matched: false, added: 7, removed: 0, expectedChange: 10, actualChange: 7),
            ]
            check("the window lines say what was done and whether the totals then agreed, in numbers", windowLines[0].contains("last 17 days") && windowLines[1].contains("found 7 older plays") && windowLines[1].contains("agree") && windowLines[2].contains("still differ") && windowLines[2].contains("Last.fm +10") && windowLines[2].contains("here +7"), windowLines.joined(separator: " | "))
            check("none of the window lines carry music or account words", windowLines.allSatisfy { sensitiveWords.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil })

            // MARK: An unreadable database
            func sqliteError(_ code: Int, cocoa: Int = 256) -> NSError {
                NSError(domain: NSCocoaErrorDomain, code: cocoa, userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSSQLiteErrorDomain", code: code)])
            }
            let full = StoreProblem.classify(sqliteError(13))
            check("SQLite 'disk full' is reported as a full disk with its codes", full?.kind == .diskFull && full?.codes == "NSCocoaErrorDomain 256, SQLite 13", "\(String(describing: full))")
            check("an extended SQLite code (disk I/O error, 4874) is still an I/O error", StoreProblem.classify(sqliteError(4874))?.kind == .ioError)
            check("database locked and busy are 'locked'", StoreProblem.classify(sqliteError(5))?.kind == .locked && StoreProblem.classify(sqliteError(6))?.kind == .locked)
            check("a malformed database is 'corrupt'", StoreProblem.classify(sqliteError(11))?.kind == .corrupt)
            check("a missing file is 'missing'", StoreProblem.classify(NSError(domain: NSCocoaErrorDomain, code: 260))?.kind == .missing)
            check("a plain store-open failure with no SQLite code is 'unreadable'", StoreProblem.classify(NSError(domain: NSCocoaErrorDomain, code: 256))?.kind == .unreadable)
            check("errors that are not about the database are not classified", StoreProblem.classify(URLError(.notConnectedToInternet)) == nil && StoreProblem.classify(LastfmAPIError.http(500)) == nil && StoreProblem.describe(CancellationError()) == nil)
            let described = describeSyncError(sqliteError(13))
            check("the sync error text for a full disk says so in plain words and keeps the codes", described.contains("disk is full") && described.contains("SQLite 13"), described)
            check("…and contains no path or name", !described.contains("/") && !described.contains(NSUserName()))
            check("Last.fm errors keep their own wording", describeSyncError(LastfmAPIError.api(code: 10, message: "x")).contains("doesn’t recognise this API key"))
            check("the 'couldn't count' answer is an error with plain words", StoreProblem.describe(StoreUnreadableError()) != nil)
            check("a real count is never the 'not found' value", ((try? container.mainContext.checkedCount(FetchDescriptor<Scrobble>())) ?? NSNotFound) != NSNotFound)
            var broken = inputs
            broken.storeProblem = "Your disk is full, so Scroblytics can’t save. (SQLite 13)"
            broken.scrobbles = 0; broken.freeDiskMB = 12; broken.databaseMB = 840
            let brokenText = DiagnosticSummary.render(broken, secrets: secrets)
            check("the summary says the database could not be read instead of giving a count", brokenText.contains("Imported: unknown") && brokenText.contains("SQLite 13") && !brokenText.contains("0 scrobbles"))
            check("the summary shows the database size and the free space", brokenText.contains("Database size: 840 MB, free space on that disk: 12 MB"))
            check("a healthy summary has no 'unknown' count", !text.contains("Imported: unknown"))
            let facts = DiagnosticSummary.diskFacts(container: container)
            check("the free space and database size can be read for this store", (facts.freeMB ?? 0) > 0, "\(facts)")

            // MARK: Personal tag sync survives one artist Last.fm can't answer for
            let tagStub = URLSessionConfiguration.ephemeral
            tagStub.protocolClasses = [FirstRunChecks.StubTransport.self]
            let tagSession = URLSession(configuration: tagStub)
            func method(_ request: URLRequest) -> String? {
                request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "method" }?.value
            }
            func artistName(_ request: URLRequest) -> String? {
                request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "artist" }?.value
            }
            let artists = (1...6).map { "Artist \($0)" }
            func tagAnswer(failing: Set<String>, status: Int = 200, body: String = #"{"error": 6, "message": "Artist not found"}"#) -> (URLRequest) -> (status: Int, body: String)? {
                { request in
                    switch method(request) {
                    case "user.getTopTags": return (200, #"{"toptags": {"tag": [{"name": "calm", "count": "9"}]}}"#)
                    case "user.getPersonalTags":
                        let kind = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "taggingtype" }?.value
                        guard kind == "artist" else { return (200, #"{"taggings": ""}"#) }
                        let list = artists.map { #"{"name": "\#($0)"}"# }.joined(separator: ",")
                        return (200, #"{"taggings": {"artists": {"artist": [\#(list)]}, "@attr": {"totalPages": "1"}}}"#)
                    case "artist.getTags":
                        if let name = artistName(request), failing.contains(name) { return (status == 200 ? 404 : status, body) }
                        return (200, #"{"tags": {"tag": [{"name": "calm"}]}}"#)
                    default: return (200, "{}")
                    }
                }
            }
            let tagClient = LastfmAPIClient(apiKey: key32, username: "listener42", session: tagSession)
            let tagContext = container.mainContext
            FirstRunChecks.StubTransport.requests = 0
            FirstRunChecks.StubTransport.responder = tagAnswer(failing: ["Artist 3"])
            var tagFailure: Error?
            do { try await EntityTagsEngine.syncPersonalTags(client: tagClient, context: tagContext) } catch { tagFailure = error }
            check("one artist Last.fm can't answer for no longer aborts the personal tag sync", tagFailure == nil, tagFailure.map { describeSyncError($0) } ?? "")
            let cached = ((try? tagContext.fetch(FetchDescriptor<UserEntityTagCacheEntry>())) ?? []).count
            check("…and the other five artists' tags are kept", cached == 5, "\(cached)")
            FirstRunChecks.StubTransport.responder = tagAnswer(failing: Set(artists))
            var allFailed: Error?
            do { try await EntityTagsEngine.syncPersonalTags(client: tagClient, context: tagContext) } catch { allFailed = error }
            check("when most artists fail it is still a failure (so a broken connection is not cached as 'no tags')", allFailed != nil)
            check("…and the cache from the earlier good run is untouched", ((try? tagContext.fetch(FetchDescriptor<UserEntityTagCacheEntry>())) ?? []).count == 5)
            FirstRunChecks.StubTransport.responder = tagAnswer(failing: ["Artist 2"], status: 403, body: #"{"error": 10, "message": "Invalid API key"}"#)
            var badKey: Error?
            do { try await EntityTagsEngine.syncPersonalTags(client: tagClient, context: tagContext) } catch { badKey = error }
            check("an invalid key stops the tag sync at once instead of skipping", badKey != nil)
            for row in (try? tagContext.fetch(FetchDescriptor<UserEntityTagCacheEntry>())) ?? [] { tagContext.delete(row) }
            for row in (try? tagContext.fetch(FetchDescriptor<PersonalTagSyncState>())) ?? [] { tagContext.delete(row) }
            try? tagContext.save()

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
