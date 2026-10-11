import Foundation

#if DEBUG
/// `SCROBLYTICS_UPDATE_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the "update available" notice, with canned GitHub
/// answers through a stub transport (no network). `SCROBLYTICS_UPDATE_LIVE=1` instead makes ONE real read-only request to GitHub's
/// public release list, to see that the real answer is understood. Exits 0 on success.
enum UpdateChecks {
    static func runHeadlessIfRequested() {
        let env = ProcessInfo.processInfo.environment
        let offlineChecks = env["SCROBLYTICS_UPDATE_CHECK"] != nil
        let live = env["SCROBLYTICS_UPDATE_LIVE"] != nil
        guard offlineChecks || live else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            if live {
                let running = AppVersion.running
                let now = await UpdateChecker.check(current: running)
                print("live: running \(running) →", now)
                let old = await UpdateChecker.check(current: AppVersion("0.0.1")!)
                print("live: pretending 0.0.1 →", old)
                if case .available(let release) = old {
                    check("the real list is understood: a newer release is found for 0.0.1", release.version >= AppVersion("0.9.0")!)
                    check("…and its page is in this project's repository", release.pageURL.absoluteString.hasPrefix(UpdateFeed.releasePagePrefix), release.pageURL.absoluteString)
                } else {
                    check("the real list is understood: a newer release is found for 0.0.1", false, "\(old)")
                }
                print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
                exit(failures == 0 ? 0 : 1)
            }

            // Versions.
            check("0.9.1 is newer than 0.9.0", AppVersion("0.9.1")! > AppVersion("0.9.0")!)
            check("0.9.10 is newer than 0.9.9 (numbers, not text)", AppVersion("0.9.10")! > AppVersion("0.9.9")!)
            check("1.0.0 is newer than 0.9.99", AppVersion("1.0.0")! > AppVersion("0.9.99")!)
            check("a leading v is accepted", AppVersion("v0.9.1") == AppVersion("0.9.1"))
            check("anything but three numbers is refused", ["0.9", "0.9.1.2", "v", "", "latest", "0.9.x", "0.9.-1", "0.9.+1", "1.0.0-beta"].allSatisfy { AppVersion($0) == nil })
            check("it prints as written", AppVersion("v10.2.3")!.description == "10.2.3")

            // Parsing GitHub's list.
            func entry(_ tag: String, draft: Bool = false, pre: Bool = false, page: String? = nil) -> String {
                #"{"tag_name": "\#(tag)", "html_url": "\#(page ?? "https://github.com/scrobl/Scroblytics/releases/tag/\(tag)")", "draft": \#(draft), "prerelease": \#(pre), "name": "x"}"#
            }
            func list(_ entries: [String]) -> Data { Data("[\(entries.joined(separator: ","))]".utf8) }
            let parsed = UpdateFeed.parse(list([entry("v0.9.0", pre: true), entry("v0.9.2", pre: true), entry("v0.9.1")]))
            check("the highest version wins, whatever the order, and pre-releases count", UpdateFeed.newest(in: parsed ?? [])?.tag == "v0.9.2")
            check("a draft is never offered", UpdateFeed.newest(in: UpdateFeed.parse(list([entry("v0.9.0"), entry("v9.9.9", draft: true)])) ?? [])?.tag == "v0.9.0")
            check("a tag that isn't a version is ignored", UpdateFeed.parse(list([entry("nightly"), entry("v0.9.0")]))?.count == 1)
            check("a release page outside this repository is ignored", UpdateFeed.parse(list([entry("v1.0.0", page: "https://example.com/evil")]))?.isEmpty == true)
            check("an empty list parses to nothing", UpdateFeed.parse(list([]))?.isEmpty == true)
            check("an answer that isn't a list is refused", UpdateFeed.parse(Data(#"{"message": "Not Found"}"#.utf8)) == nil && UpdateFeed.parse(Data("junk".utf8)) == nil)

            // The check itself, through a stub transport.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FirstRunChecks.StubTransport.self]
            let session = URLSession(configuration: configuration)
            final class Seen: @unchecked Sendable {
                private let lock = NSLock()
                private var agent: String?, accept: String?, cookies: Bool?
                func note(_ r: URLRequest) { lock.lock(); agent = r.value(forHTTPHeaderField: "User-Agent"); accept = r.value(forHTTPHeaderField: "Accept"); cookies = r.httpShouldHandleCookies; lock.unlock() }
                var values: (String?, String?, Bool?) { lock.lock(); defer { lock.unlock() }; return (agent, accept, cookies) }
            }
            let seen = Seen()
            func respond(_ status: Int, _ body: Data) {
                FirstRunChecks.StubTransport.requests = 0
                FirstRunChecks.StubTransport.responder = { request in seen.note(request); return (status, String(decoding: body, as: UTF8.self)) }
            }
            let running = AppVersion("0.9.0")!
            respond(200, list([entry("v0.9.0", pre: true), entry("v0.9.1")]))
            let newer = await UpdateChecker.check(current: running, session: session)
            check("a newer release is reported as available", { if case .available(let r) = newer { return r.tag == "v0.9.1" }; return false }(), "\(newer)")
            let (agent, accept, cookies) = seen.values
            check("the request says what app it is, nothing more", agent == "Scroblytics/0.9.0" && accept == "application/vnd.github+json" && cookies == false, "\(agent ?? "nil") \(accept ?? "nil") \(String(describing: cookies))")
            let same = await UpdateChecker.check(current: AppVersion("0.9.1")!, session: session)
            check("the same version is up to date", same == .upToDate)
            let ahead = await UpdateChecker.check(current: AppVersion("1.2.0")!, session: session)
            check("a newer running version (a dev build) is up to date", ahead == .upToDate)
            respond(403, Data(#"{"message": "API rate limit exceeded"}"#.utf8))
            let limited = await UpdateChecker.check(current: running, session: session)
            check("GitHub's rate limit is a plain failure", { if case .failed(let why) = limited { return why.contains("limiting") }; return false }())
            respond(404, Data("{}".utf8))
            let missing = await UpdateChecker.check(current: running, session: session)
            check("a missing list is a plain failure", { if case .failed = missing { return true }; return false }())
            respond(200, Data("<html>nope</html>".utf8))
            let unreadable = await UpdateChecker.check(current: running, session: session)
            check("an unreadable answer is a plain failure", { if case .failed = unreadable { return true }; return false }())

            // Offline mode: nothing is sent.
            respond(200, list([entry("v0.9.1")]))
            ConnectivityGate.set(offline: true)
            let whileOffline = await UpdateChecker.check(current: running, session: session)
            let sentOffline = FirstRunChecks.StubTransport.requests
            ConnectivityGate.set(offline: false)
            check("Offline mode: no request is sent", whileOffline == .offline && sentOffline == 0, "\(whileOffline), \(sentOffline) requests")

            // The store: skipping, the daily limit, persistence.
            let suite = "scroblytics.updatechecks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UpdateStore(defaults: defaults, feedURL: UpdateFeed.defaultURL, currentVersion: running, session: session)
            respond(200, list([entry("v0.9.1")]))
            check("automatic checks are on by default", store.automaticChecks)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            await store.checkAutomaticallyIfDue(now: start)
            check("the first launch checks and announces the newer release", FirstRunChecks.StubTransport.requests == 1 && store.announced?.tag == "v0.9.1")
            await store.checkAutomaticallyIfDue(now: start.addingTimeInterval(3600))
            check("an hour later it does not ask again", FirstRunChecks.StubTransport.requests == 1)
            await store.checkAutomaticallyIfDue(now: start.addingTimeInterval(UpdateStore.checkInterval + 60))
            check("a day later it asks again", FirstRunChecks.StubTransport.requests == 2)
            let remembered = UpdateStore(defaults: defaults, feedURL: UpdateFeed.defaultURL, currentVersion: running, session: session)
            check("a relaunch still knows about the release without asking", remembered.announced?.tag == "v0.9.1" && FirstRunChecks.StubTransport.requests == 2)
            let upgraded = UpdateStore(defaults: defaults, feedURL: UpdateFeed.defaultURL, currentVersion: AppVersion("0.9.1")!, session: session)
            check("once the app is that version, nothing is announced", upgraded.announced == nil)
            store.skip(store.announced!)
            check("a skipped version is not announced", store.announced == nil)
            respond(200, list([entry("v0.9.2")]))
            await store.checkNow()
            check("a newer release than the skipped one is announced", store.announced?.tag == "v0.9.2")
            store.dismissForNow()
            check("dismissing hides it for the session", store.announced == nil)
            respond(200, list([entry("v0.9.2")]))
            store.automaticChecks = false
            let before = FirstRunChecks.StubTransport.requests
            await store.checkAutomaticallyIfDue(now: start.addingTimeInterval(10 * UpdateStore.checkInterval))
            check("with automatic checks off, nothing is asked", FirstRunChecks.StubTransport.requests == before)
            check("the setting is remembered", UpdateStore(defaults: defaults, feedURL: UpdateFeed.defaultURL, currentVersion: running, session: session).automaticChecks == false)
            let failing = UpdateStore(defaults: UserDefaults(suiteName: suite + ".b")!, feedURL: UpdateFeed.defaultURL, currentVersion: running, session: session)
            respond(500, Data("{}".utf8))
            await failing.checkAutomaticallyIfDue(now: start)
            check("a failed check is not counted as checked (it is tried again next launch)", failing.lastCheckedAt == nil && failing.announced == nil)
            UserDefaults.standard.removePersistentDomain(forName: suite + ".b")

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
