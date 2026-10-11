import Foundation

#if DEBUG
/// `SCROBLYTICS_RATELIMIT_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): how the app keeps within Last.fm's request limit
/// and waits out "rate limit exceeded" (error 29), with no network (canned answers through a stub transport). Exits 0 on success.
enum RateLimitChecks {
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_RATELIMIT_CHECK"] != nil else { return }
        Task {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }

            // Pacing: requests are spread out, never closer than the gap, and a long quiet spell costs nothing.
            var pacing = LastfmPacing()
            let first = pacing.delay(now: 0)
            let second = pacing.delay(now: 0)
            let third = pacing.delay(now: 0.1)
            check("the first request goes at once", first == 0)
            check("a second request waits one gap", abs(second - 0.25) < 1e-9, "\(second)")
            check("a third, ready at 0.1 s, takes the next slot (0.5 s)", abs(third - 0.4) < 1e-9, "\(third)")
            check("after a quiet minute a request goes at once", pacing.delay(now: 60) == 0)
            var slots: [TimeInterval] = []
            var spaced = LastfmPacing()
            for step in 0..<50 { slots.append(Double(step) * 0.01 + spaced.delay(now: Double(step) * 0.01)) }
            check("50 requests asked for 10 ms apart are sent at least 250 ms apart", zip(slots, slots.dropFirst()).allSatisfy { $1 - $0 >= 0.25 - 1e-9 })
            check("that is at most 4 requests in any second", slots.indices.allSatisfy { i in slots.filter { $0 >= slots[i] && $0 < slots[i] + 1 }.count <= 4 })
            spaced.noteRateLimited()
            _ = spaced.delay(now: 1000)
            let afterWiden = spaced.delay(now: 1000)
            check("after a rate limit the gap widens to 600 ms", abs(afterWiden - 0.6) < 1e-9, "\(afterWiden)")

            // Priority: twelve background lookups queued at once, then an import page asks for its turn; it must not wait behind them.
            final class Times: @unchecked Sendable {
                private let lock = NSLock()
                private var values: [TimeInterval] = []
                func add(_ v: TimeInterval) { lock.lock(); values.append(v); lock.unlock() }
                var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values }
            }
            let pacer = LastfmPacer()
            let begin = ProcessInfo.processInfo.systemUptime
            let backgroundDone = Times()
            let backgroundTasks = (0..<12).map { _ in Task { try? await pacer.waitForTurn(foreground: false); backgroundDone.add(ProcessInfo.processInfo.systemUptime - begin) } }
            try? await Task.sleep(nanoseconds: 600_000_000)
            let asked = ProcessInfo.processInfo.systemUptime
            try? await pacer.waitForTurn(foreground: true)
            let foregroundWait = ProcessInfo.processInfo.systemUptime - asked
            for task in backgroundTasks { _ = await task.result }
            let backgroundSpan = backgroundDone.all.max() ?? 0
            check("an import request asking behind 12 queued background lookups waits at most about two gaps", foregroundWait < 0.65, String(format: "%.2f s", foregroundWait))
            check("…while the 12 background lookups still go out about a quarter second apart", backgroundSpan > 2.4 && backgroundSpan < 6, String(format: "%.2f s for 12", backgroundSpan))

            // The waiting schedule: 30 s, then 60 s each time, until 10 minutes have been spent.
            let policy = RateLimitPolicy()
            check("waits are 30 s, then 60 s", policy.wait(afterRateLimits: 0) == 30 && policy.wait(afterRateLimits: 1) == 60 && policy.wait(afterRateLimits: 7) == 60)
            var spent: TimeInterval = 0, waits = 0
            while spent + policy.wait(afterRateLimits: waits) <= policy.patience { spent += policy.wait(afterRateLimits: waits); waits += 1 }
            check("it waits ten times (570 s) and then gives up inside 10 minutes", waits == 10 && spent == 570, "\(waits) waits, \(spent) s")

            // The client, against canned Last.fm answers.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FirstRunChecks.StubTransport.self]
            let session = URLSession(configuration: configuration)
            let rateLimited = (status: 429, body: #"{"error": 29, "message": "Rate Limit Exceeded"}"#)
            let goodPage = (status: 200, body: #"{"recenttracks": {"track": [], "@attr": {"user": "x", "totalPages": "1", "page": "1", "perPage": "200", "total": "0"}}}"#)
            let fast = RateLimitPolicy(waits: [0.05, 0.05], patience: 0.12)

            final class Waits: @unchecked Sendable {
                private let lock = NSLock()
                private var values: [Int?] = []
                func add(_ v: Int?) { lock.lock(); values.append(v); lock.unlock() }
                var all: [Int?] { lock.lock(); defer { lock.unlock() }; return values }
            }

            // Two rate-limit answers, then a good page: it waits, tells the screen, and carries on.
            FirstRunChecks.StubTransport.requests = 0
            FirstRunChecks.StubTransport.responder = { _ in FirstRunChecks.StubTransport.requests <= 2 ? rateLimited : goodPage }
            let heard = Waits()
            let client = LastfmAPIClient(apiKey: "k", username: "x", session: session, rateLimitPolicy: fast)
            do {
                let page = try await client.fetchRecentTracksPage(page: 1, onWait: { heard.add($0) })
                check("two rate limits then a good page: the page comes back", page.totalPages == 1)
                check("…after exactly three requests (no short retries piled on)", FirstRunChecks.StubTransport.requests == 3, "\(FirstRunChecks.StubTransport.requests)")
                check("…the screen was told about each wait and then that it was over", heard.all.count == 3 && heard.all.last! == nil && heard.all.dropLast().allSatisfy { $0 != nil }, "\(heard.all)")
            } catch {
                check("two rate limits then a good page: the page comes back", false, "\(error)")
            }

            // Always limited: gives up after the patience, with a rate-limit error, not after a dozen quick retries.
            FirstRunChecks.StubTransport.requests = 0
            FirstRunChecks.StubTransport.responder = { _ in rateLimited }
            let patient = LastfmAPIClient(apiKey: "k", username: "x", session: session, rateLimitPolicy: fast)
            do {
                _ = try await patient.fetchRecentTracksPage(page: 1)
                check("always rate-limited: it gives up", false)
            } catch let error as LastfmAPIError {
                check("always rate-limited: it gives up with the rate-limit error", error.isRateLimit)
                check("…after three requests (the patience allows two waits)", FirstRunChecks.StubTransport.requests == 3, "\(FirstRunChecks.StubTransport.requests)")
                let text = error.errorDescription ?? ""
                check("…and the message tells the person what to do", text.contains("Retry") && text.contains("several minutes"), text)
            } catch {
                check("always rate-limited: it gives up with the rate-limit error", false, "\(error)")
            }

            // Other temporary errors keep the short retries (1 s, 2 s, ...), not the long wait.
            FirstRunChecks.StubTransport.requests = 0
            FirstRunChecks.StubTransport.responder = { _ in FirstRunChecks.StubTransport.requests <= 1 ? (status: 503, body: #"{"error": 16, "message": "temporary"}"#) : goodPage }
            let other = LastfmAPIClient(apiKey: "k", username: "x", session: session, rateLimitPolicy: fast)
            let started = Date()
            let recovered = (try? await other.fetchRecentTracksPage(page: 1)) != nil
            check("a temporary error (16) is retried after about a second and then succeeds", recovered && Date().timeIntervalSince(started) < 5, "\(Date().timeIntervalSince(started)) s")

            // Last.fm's other errors are not retried at all.
            FirstRunChecks.StubTransport.requests = 0
            FirstRunChecks.StubTransport.responder = { _ in (status: 403, body: #"{"error": 10, "message": "Invalid API key"}"#) }
            _ = try? await other.fetchRecentTracksPage(page: 1)
            check("a rejected key (10) is not retried", FirstRunChecks.StubTransport.requests == 1, "\(FirstRunChecks.StubTransport.requests)")

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
