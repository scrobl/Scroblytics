import Foundation

#if DEBUG
/// `SCROBLYTICS_FIRSTRUN_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the first-run logic without a
/// screen or a network: the account check against canned Last.fm answers (a stub transport, no real requests), the
/// wording for every failure, and which first-run state each combination of facts gives.
enum FirstRunChecks {
    /// A transport that answers from a closure, so each Last.fm outcome can be produced on demand.
    final class StubTransport: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responder: (URLRequest) -> (status: Int, body: String)? = { _ in nil }
        nonisolated(unsafe) static var requests = 0

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests += 1
            guard let answer = Self.responder(request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_FIRSTRUN_CHECK"] != nil else { return }
        Task {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubTransport.self]
            let session = URLSession(configuration: configuration)
            func apiError(_ code: Int, _ message: String, status: Int) -> (Int, String)? {
                (status, "{\"error\": \(code), \"message\": \"\(message)\"}")
            }
            func outcome(_ answer: (status: Int, body: String)?, user: String = "someone", key: String = "abcdef0123456789abcdef0123456789") async -> LastfmAccountCheck.Outcome {
                StubTransport.responder = { _ in answer }
                return await LastfmAccountCheck.validate(username: user, apiKey: key, session: session)
            }
            func invalidText(_ o: LastfmAccountCheck.Outcome) -> String { if case .invalid(let text) = o { return text }; return "" }

            // A working pair.
            let good = await outcome((200, "{\"user\": {\"name\": \"SomeOne\", \"playcount\": \"1234\"}}"), user: "  someone ")
            check("a working pair is accepted", good == .valid(.init(username: "SomeOne", scrobbles: 1234)), "\(good)")
            check("…and shows the name as Last.fm spells it, with the scrobble total", good == .valid(.init(username: "SomeOne", scrobbles: 1234)))
            let empty = await outcome((200, "{\"user\": {\"name\": \"New\", \"playcount\": \"0\"}}"))
            check("an account with no scrobbles is accepted (it is not an error)", empty == .valid(.init(username: "New", scrobbles: 0)))

            // Each failure, in plain words.
            let bad = invalidText(await outcome(apiError(10, "Invalid API key", status: 403)))
            check("error 10 says the key isn't recognised and mentions the shared secret", bad.contains("doesn’t recognise this API key") && bad.contains("shared secret"), bad)
            let suspended = invalidText(await outcome(apiError(26, "Suspended API key", status: 403)))
            check("error 26 says the key is suspended", suspended.contains("suspended"), suspended)
            let unknown = invalidText(await outcome(apiError(6, "User not found", status: 404), user: "nobody"))
            check("error 6 names the user that wasn't found", unknown.contains("“nobody”") && unknown.contains("spelling"), unknown)
            let hidden = invalidText(await outcome(apiError(17, "Login: User required to be logged in", status: 403)))
            check("error 17 points at the privacy setting", hidden.contains("privacy settings"), hidden)
            let limited = invalidText(await outcome(apiError(29, "Rate Limit Exceeded", status: 429)))
            check("error 29 says to wait and retry", limited.contains("Wait a minute"), limited)
            for code in [8, 11, 16] {
                let temp = invalidText(await outcome(apiError(code, "temporary", status: 500)))
                check("error \(code) says Last.fm is temporarily unavailable", temp.contains("temporarily unavailable"), temp)
            }
            let other = invalidText(await outcome(apiError(99, "Something else", status: 400)))
            check("an unknown error code keeps Last.fm's own words", other.contains("99") && other.contains("Something else"), other)
            let down = invalidText(await outcome(nil))
            check("no connection says Last.fm can't be reached (not 'user not found')", down.contains("Can’t reach Last.fm"), down)
            let html = invalidText(await outcome((200, "<html>maintenance</html>")))
            check("an unreadable answer is reported, never accepted", !html.isEmpty)

            // Offline mode: nothing is sent.
            StubTransport.requests = 0
            ConnectivityGate.set(offline: true)
            let offline = invalidText(await outcome((200, "{\"user\": {\"name\": \"x\", \"playcount\": \"1\"}}")))
            ConnectivityGate.set(offline: false)
            check("Offline mode says to go online and sends nothing", offline.contains("Offline mode is on") && StubTransport.requests == 0, "\(offline) requests=\(StubTransport.requests)")

            // Typed values are checked before anything is sent.
            StubTransport.requests = 0
            let blankName = invalidText(await outcome((200, ""), user: "  "))
            let emailName = invalidText(await outcome((200, ""), user: "me@example.com"))
            let urlName = invalidText(await outcome((200, ""), user: "https://www.last.fm/user/me"))
            let blankKey = invalidText(await outcome((200, ""), key: " "))
            let spacedKey = invalidText(await outcome((200, ""), key: "abc def"))
            let urlKey = invalidText(await outcome((200, ""), key: "https://www.last.fm/api"))
            check("a blank username is explained", blankName.contains("Enter your Last.fm username"), blankName)
            check("an email address is explained", emailName.contains("not an email address"), emailName)
            check("a web address as username is explained", urlName.contains("not a web address"), urlName)
            check("a blank key is explained", blankKey.contains("Enter your Last.fm API key"), blankKey)
            check("a key with spaces or a web address is explained", spacedKey.contains("single run") && urlKey.contains("single run"))
            check("none of those sent a request", StubTransport.requests == 0, "requests=\(StubTransport.requests)")

            // First-run state.
            func state(_ creds: Bool, _ count: Int, _ done: Bool, _ syncing: Bool) -> FirstRunState {
                FirstRunState.derive(hasCredentials: creds, scrobbleCount: count, hasCompletedSync: done, isSyncing: syncing)
            }
            check("no account and no history: welcome", state(false, 0, false, false) == .noAccount)
            check("account saved, nothing imported, not syncing: waiting for the import", state(true, 0, false, false) == .awaitingFirstImport)
            check("account saved and a sync running: importing", state(true, 0, false, true) == .importing)
            check("an interrupted import (scrobbles present, never completed): importing", state(true, 120, false, false) == .importing)
            check("a completed sync: ready", state(true, 5000, true, false) == .ready)
            check("an account removed from a populated library: ready (not the welcome screen)", state(false, 5000, true, false) == .ready)
            check("history but no account and no completed sync is not 'no account'", state(false, 10, false, false) == .ready)
            check("a sync that finished with an empty Last.fm account: ready", state(true, 0, true, false) == .ready)

            // Time left: nothing until the pace has settled, then plain words. 1,000 scrobbles in 10 s = 100 a second.
            func left(_ remaining: Int, processed: Int = 1000, baseline: Int = 0, elapsed: Double = 10) -> String? {
                ImportEstimate.remainingText(processed: processed, total: processed + remaining, baselineProcessed: baseline, elapsed: elapsed)
            }
            check("no estimate in the first seconds", left(5000, elapsed: 3) == nil)
            check("no estimate before a few hundred scrobbles", left(5000, processed: 100) == nil)
            check("no estimate when nothing is left", left(0) == nil)
            check("30 s left reads “less than a minute”", left(3000) == "less than a minute left", "\(String(describing: left(3000)))")
            check("2 minutes", left(12_000) == "about 2 min left", "\(String(describing: left(12_000)))")
            check("6 minutes", left(36_000) == "about 6 min left", "\(String(describing: left(36_000)))")
            check("1 h 40 min", left(600_000) == "about 1 h 40 min left", "\(String(describing: left(600_000)))")
            check("2 h 45 min", left(1_000_000) == "about 2 h 45 min left", "\(String(describing: left(1_000_000)))")
            check("a day or more", left(9_000_000) == "more than a day left", "\(String(describing: left(9_000_000)))")
            check("the pace counts only what was done since timing began", left(3000, processed: 5000, baseline: 4000) == "less than a minute left")

            // Why a page is empty, and what to offer.
            typealias H = HistoryStatus
            func reason(_ count: Int, account: Bool, completed: Bool, _ phase: H.Phase) -> H.EmptyReason? {
                H.emptyReason(scrobbleCount: count, hasAccount: account, hasCompletedSync: completed, phase: phase)
            }
            check("history present: no empty reason", reason(10, account: true, completed: false, .running(isFirstImport: true)) == nil)
            check("no account", reason(0, account: false, completed: false, .idle) == .noAccount)
            check("a running import with nothing yet: importing", reason(0, account: true, completed: false, .running(isFirstImport: true)) == .importing)
            check("an account waiting for its import: importing", reason(0, account: true, completed: false, .idle) == .importing)
            check("a paused import with nothing yet: interrupted", reason(0, account: true, completed: false, .paused) == .interrupted)
            let rateLimited = H.Failure(error: LastfmAPIError.api(code: 29, message: "Rate Limit Exceeded"))
            let badKey = H.Failure(error: LastfmAPIError.api(code: 10, message: "Invalid API key"))
            check("a failed import carries its reason", reason(0, account: true, completed: false, .failed(rateLimited)) == .failed(rateLimited))
            check("a finished import of an empty account says so", reason(0, account: true, completed: true, .idle) == .accountHasNoScrobbles)
            check("a rate limit offers Retry", rateLimited.kind == .retry && rateLimited.message.contains("limiting"), rateLimited.message)
            check("a rejected key offers Open Settings, not Retry", badKey.kind == .fixAccount && badKey.message.contains("API key"), badKey.message)
            check("suspended key and private profile also point at the account",
                  H.Failure(error: LastfmAPIError.api(code: 26, message: "")).kind == .fixAccount && H.Failure(error: LastfmAPIError.api(code: 17, message: "")).kind == .fixAccount)
            check("a network failure offers Retry", H.Failure(error: LastfmAPIError.network(URLError(.timedOut))).kind == .retry)
            let unreachable = H.Failure(error: LastfmAPIError.network(URLError(.cannotConnectToHost)))
            check("not reaching Last.fm is said plainly, not as a raw network error", unreachable.message.contains("Can’t reach Last.fm") && !unreachable.message.contains("URLError"), unreachable.message)
            check("the partial-data note shows while the first import is unfinished and some history is in",
                  H.isPartial(scrobbleCount: 500, hasAccount: true, hasCompletedSync: false))
            check("…not when it has finished, when nothing is in yet, or with no account",
                  !H.isPartial(scrobbleCount: 500, hasAccount: true, hasCompletedSync: true)
                  && !H.isPartial(scrobbleCount: 0, hasAccount: true, hasCompletedSync: false)
                  && !H.isPartial(scrobbleCount: 500, hasAccount: false, hasCompletedSync: false))

            // Overview cards say "Loading…" until the page has loaded, and only then claim there is nothing.
            check("an empty card says Loading… while the Overview loads", OverviewEmptyText.text(message: "No milestones approaching.", loading: true) == "Loading…")
            check("…and its own message once loaded", OverviewEmptyText.text(message: "No milestones approaching.", loading: false) == "No milestones approaching.")

            // Why the database couldn't be opened: each cause is recognised, also when wrapped inside another error.
            func wrapped(_ domain: String, _ code: Int) -> NSError {
                NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [NSUnderlyingErrorKey: NSError(domain: domain, code: code)])
            }
            check("a full disk is recognised", StoreStartupFailure.cause(of: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .diskFull)
            check("…also as ENOSPC underneath another error", StoreStartupFailure.cause(of: wrapped(NSPOSIXErrorDomain, Int(ENOSPC))) == .diskFull)
            check("no permission is recognised", StoreStartupFailure.cause(of: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)) == .permission)
            check("…also as EACCES underneath another error", StoreStartupFailure.cause(of: wrapped(NSPOSIXErrorDomain, Int(EACCES))) == .permission)
            check("a migration error means a different version", StoreStartupFailure.cause(of: NSError(domain: NSCocoaErrorDomain, code: 134110)) == .newerVersion)
            check("a model version mismatch means a different version", StoreStartupFailure.cause(of: NSError(domain: NSCocoaErrorDomain, code: 134100)) == .newerVersion)
            check("SQLite “not a database” means damaged", StoreStartupFailure.cause(of: wrapped("NSSQLiteErrorDomain", 26)) == .damaged)
            check("SQLite “corrupt” means damaged", StoreStartupFailure.cause(of: wrapped("NSSQLiteErrorDomain", 11)) == .damaged)
            check("Core Data's “isn't in the correct format” with SQLite 26 inside is damaged",
                  StoreStartupFailure.cause(of: NSError(domain: NSCocoaErrorDomain, code: 259, userInfo: ["NSSQLiteErrorDomain": 26])) == .damaged)
            struct Carrier: Error { let _underlyingCocoaError: CocoaError? }
            check("a SwiftData error carrying a Cocoa error is looked into",
                  StoreStartupFailure.cause(of: Carrier(_underlyingCocoaError: CocoaError(.fileWriteOutOfSpace))) == .diskFull)
            check("anything else is still explained", StoreStartupFailure.cause(of: NSError(domain: "Other", code: 1)) == .other
                  && !StoreStartupFailure.describe(NSError(domain: "Other", code: 1), storePath: "/x").advice.isEmpty)

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
