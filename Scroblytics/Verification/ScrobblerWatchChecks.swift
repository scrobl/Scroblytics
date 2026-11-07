#if DEBUG
import Foundation
import SwiftData

/// Checks for the scrobbling check ("your scrobbler may have stopped") on made-up data, and a read-only run on the real library.
/// `SCROBLYTICS_SCROBBLERWATCH_CHECK=1` runs the checks. `SCROBLYTICS_SCROBBLERWATCH_DUMP=<file>` (a store copy on
/// `SCROBLYTICS_STORE_PATH`, and the running Music) compares the quick recently-played read of Music with the whole-library read,
/// shows today's verdict, and replays the check over the last 60 weeks of the real history to see how often it would have warned.
enum ScrobblerWatchChecks {
    typealias Watch = ScrobblerWatch

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SCROBLYTICS_SCROBBLERWATCH_DUMP"] {
            HeadlessTask.run("scrobblerwatch-dump") { try await dump(container: container, path: path) }
            return
        }
        guard environment["SCROBLYTICS_SCROBBLERWATCH_CHECK"] != nil else { return }
        HeadlessTask.run("scrobblerwatch-check") {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            verdictChecks(check)
            settingsChecks(check)
            stateChecks(check)
            wordingChecks(check)
            await storeChecks(check)
            HeadlessTask.finish(failures)
        }
    }

    // MARK: Made-up data

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let synced = now.addingTimeInterval(-60)
    private static let day: TimeInterval = 86_400

    private static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private static func scrobble(_ artist: String, _ track: String, _ time: Date) -> ScrobbleSnapshot {
        ScrobbleSnapshot(artistName: artist, albumName: "Album", trackName: track, imageURL: nil, playedAt: time)
    }

    private static func song(_ artist: String, _ name: String, played: Date) -> AppleMusicSnapshot.Track {
        AppleMusicSnapshot.Track(name: name, artist: artist, album: "Album", lastPlayedAt: played, playCount: 1)
    }

    private static func music(_ tracks: [AppleMusicSnapshot.Track]) -> AppleMusicSnapshot {
        AppleMusicSnapshot(favorites: [], library: tracks, source: .favoritedFlag, readSeconds: 0)
    }

    /// The history always starts long before the plays under test.
    private static func history(_ extra: [ScrobbleSnapshot] = []) -> [ScrobbleSnapshot] {
        [scrobble("Artist Z", "Old Song", ago(400 * day))] + extra
    }

    private static func verdict(
        _ tracks: [AppleMusicSnapshot.Track], _ scrobbles: [ScrobbleSnapshot] = [], threshold: Int = 3, window: Int = 7, submitted: Set<String> = []
    ) -> Watch.Verdict {
        Watch.evaluate(
            recent: music(tracks), scrobbles: history(scrobbles), syncedThrough: synced, submitted: submitted,
            settings: Watch.Settings(enabled: true, threshold: threshold, windowDays: window), now: now
        )
    }

    // MARK: The verdict

    private static func verdictChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let two = verdict([song("A", "One", played: ago(3600)), song("A", "Two", played: ago(7200))])
        check("two missed songs do not warn at the default of three", two.count == 2 && !two.fires && two.threshold == 3)
        let three = verdict([song("A", "One", played: ago(3600)), song("A", "Two", played: ago(7200)), song("B", "Three", played: ago(9000))])
        check("three missed songs warn", three.count == 3 && three.fires)
        check("the songs come oldest first, with the first and last missed play", three.missed.map(\.track) == ["Three", "Two", "One"] && three.firstMissed == ago(9000) && three.lastMissed == ago(3600))

        let tracks = [song("A", "One", played: ago(3600)), song("A", "Two", played: ago(7200))]
        check("the number of songs is configurable: two warn when the setting is two", verdict(tracks, threshold: 2).fires)
        check("…and five does not warn on three", !verdict(three.missed.map { song($0.artist, $0.track, played: $0.musicLastPlayed) }, threshold: 5).fires)
        check("a threshold of one warns on a single missed song", verdict([song("A", "Only", played: ago(3600))], threshold: 1).fires)

        // The number of days is configurable
        let spread = [song("A", "Hours", played: ago(3600)), song("A", "TwoDays", played: ago(2 * day)), song("A", "FiveDays", played: ago(5 * day)), song("A", "NineDays", played: ago(9 * day))]
        check("a one-day window counts only the last day", verdict(spread, window: 1).missed.map(\.track) == ["Hours"])
        check("three days adds the two-day-old song", verdict(spread, window: 3).count == 2)
        check("seven days adds the five-day-old one, and fourteen the nine-day-old one", verdict(spread, window: 7).count == 3 && verdict(spread, window: 14).count == 4)
        check("a play older than the window is not counted however many there are", verdict((0..<10).map { song("A", "Old \($0)", played: ago(8 * day + Double($0) * 60)) }).count == 0)

        // What is not a miss
        let shifted = verdict([song("A", "Shifted", played: ago(3600))], [scrobble("A", "Shifted", ago(3600 + 10 * 3600))])
        check("a play already scrobbled a whole number of hours off (a clock difference) is not a miss", shifted.count == 0)
        let variant = verdict([song("A", "Title", played: ago(3600))], [scrobble("A", "Title (feat. Guest)", ago(3600))])
        check("a title scrobbled with a (feat. …) credit is the same song, not a miss", variant.count == 0)
        let fresh = verdict([song("A", "Fresh", played: synced.addingTimeInterval(-60))])
        check("a play within five minutes of the last sync is too new to judge, so not a miss", fresh.count == 0)
        let key = UnscrobbledPlaysScrobbling.ledgerKey(artist: "A", track: "Sent", timestamp: Int(ago(3600).timeIntervalSince1970))
        check("a play already submitted from Unscrobbled Plays is not a miss", verdict([song("A", "Sent", played: ago(3600))], submitted: [key]).count == 0)
        check("a song that has a later scrobble is not a miss", verdict([song("A", "Seen", played: ago(7200))], [scrobble("A", "Seen", ago(3600))]).count == 0)

        // How many can still be scrobbled
        let edge = verdict([song("A", "Recent", played: ago(day)), song("A", "AtTheEdge", played: ago(14 * day - 1800))], window: 14)
        check("only plays inside Last.fm's 14-day window count as still scrobblable", edge.count == 2 && edge.stillScrobblable == 1, "\(edge.count) \(edge.stillScrobblable)")
        check("with a one-day window every missed song can still be scrobbled", verdict([song("A", "One", played: ago(3600))], window: 1).stillScrobblable == 1)
    }

    // MARK: Settings

    private static func settingsChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let suite = UserDefaults(suiteName: "scrobbler-watch-check")!
        suite.removePersistentDomain(forName: "scrobbler-watch-check")
        let defaults = Watch.Settings.load(defaults: suite)
        check("the check is off by default, at three songs in seven days", !defaults.enabled && defaults.threshold == 3 && defaults.windowDays == 7)
        Watch.Settings(enabled: true, threshold: 5, windowDays: 3).save(defaults: suite)
        check("settings round-trip", Watch.Settings.load(defaults: suite) == Watch.Settings(enabled: true, threshold: 5, windowDays: 3))
        check("a threshold outside 1…20 is brought back inside", Watch.Settings(enabled: true, threshold: 0, windowDays: 7).clamped().threshold == 1 && Watch.Settings(enabled: true, threshold: 99, windowDays: 7).clamped().threshold == 20)
        check("a number of days that isn't offered becomes the nearest one", Watch.Settings(windowDays: 10).clamped().windowDays == 7 && Watch.Settings(windowDays: 100).clamped().windowDays == 14 && Watch.Settings(windowDays: 0).clamped().windowDays == 1)
        suite.set(500, forKey: Watch.Settings.thresholdKey)
        suite.set(5, forKey: Watch.Settings.windowKey)
        check("a hand-edited saved value is clamped when loaded", Watch.Settings.load(defaults: suite).threshold == 20 && Watch.Settings.load(defaults: suite).windowDays == 3)
        check("Music is asked for the window plus a day", Watch.Settings(windowDays: 7).readDays == 8 && Watch.Settings(windowDays: 1).readDays == 2)
        check("the offered values are 1, 3, 7 and 14 days and the default is 3 songs in 7 days", Watch.windowChoices == [1, 3, 7, 14] && Watch.defaultThreshold == 3 && Watch.defaultWindowDays == 7)
        suite.removePersistentDomain(forName: "scrobbler-watch-check")
    }

    // MARK: Whether a warning is showing

    private static func stateChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        func v(_ n: Int) -> Watch.Verdict { verdict((0..<n).map { song("A", "S\($0)", played: ago(3600 + Double($0) * 60)) }) }
        var state = Watch.State()
        var (next, transition) = Watch.advance(state, with: v(1)); state = next
        check("a healthy check does nothing", transition == nil && !Watch.isShowing(state))
        (next, transition) = Watch.advance(state, with: v(4)); state = next
        check("the first check that finds the problem begins it, and the warning shows", transition == .began(count: 4) && Watch.isShowing(state))
        (next, transition) = Watch.advance(state, with: v(6)); state = next
        check("a later check that still finds it adds no new event", transition == nil && Watch.isShowing(state))
        state.dismissed = true
        check("a dismissed warning is hidden", !Watch.isShowing(state))
        (next, transition) = Watch.advance(state, with: v(9)); state = next
        check("it stays dismissed while the problem continues, however many more plays are missed", transition == nil && !Watch.isShowing(state) && state.dismissed)
        (next, transition) = Watch.advance(state, with: v(0)); state = next
        check("a healthy check ends it, and forgets the dismissal", transition == .recovered && !state.firing && !state.dismissed)
        (next, transition) = Watch.advance(state, with: v(3)); state = next
        check("when it comes back after recovering, the warning shows again", transition == .began(count: 3) && Watch.isShowing(state))
        check("a state that never fired stays quiet however it is dismissed", Watch.advance(Watch.State(firing: false, dismissed: true), with: v(0)).0 == Watch.State())
    }

    // MARK: Words

    private static func wordingChecks(_ report: (String, Bool, String) -> Void) {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let recent = ScrobblerWatchWording.headline(count: 5, since: ago(2 * day), now: now)
        check("the headline says how many songs and since when", recent.hasPrefix("Music played 5 songs since ") && recent.hasSuffix("that Last.fm didn’t get. Your scrobbler may have stopped."), recent)
        check("one song reads in the singular", ScrobblerWatchWording.headline(count: 1, since: ago(day), now: now).contains("1 song since"))
        check("an older start gives a date, not a weekday", !ScrobblerWatchWording.headline(count: 3, since: ago(10 * day), now: now).isEmpty)
        check("the detail says all of them, some of them, or none can still be scrobbled",
              ScrobblerWatchWording.detail(scrobblable: 4, count: 4).hasPrefix("All of them") && ScrobblerWatchWording.detail(scrobblable: 2, count: 5).hasPrefix("2 of them")
              && ScrobblerWatchWording.detail(scrobblable: 0, count: 5).contains("none of them") && ScrobblerWatchWording.detail(scrobblable: 1, count: 1).hasPrefix("It "))
    }

    // MARK: The store (no Music, no network)

    @MainActor
    private static func storeChecks(_ report: (String, Bool, String) -> Void) async {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let suite = UserDefaults(suiteName: "scrobbler-watch-store-check")!
        suite.removePersistentDomain(forName: "scrobbler-watch-store-check")
        let store = ScrobblerWatchStore(defaults: suite)
        check("a new store is off and shows nothing", !store.settings.enabled && !store.isShowing && store.verdict == nil)
        store.setThreshold(7)
        store.setWindowDays(3)
        check("changed numbers are remembered", ScrobblerWatch.Settings.load(defaults: suite).threshold == 7 && ScrobblerWatch.Settings.load(defaults: suite).windowDays == 3)
        store.setThreshold(500)
        check("an out-of-range number is clamped", store.settings.threshold == 20)
        store.setEnabled(true)
        check("turning it on is remembered", store.settings.enabled && ScrobblerWatch.Settings.load(defaults: suite).enabled)
        store.setEnabled(false)
        check("turning it off is remembered and clears the warning", !store.settings.enabled && !ScrobblerWatch.Settings.load(defaults: suite).enabled && !store.isShowing && store.verdict == nil)
        suite.set(true, forKey: "scrobblerWatch.firing")
        suite.set(true, forKey: "scrobblerWatch.dismissed")
        let reopened = ScrobblerWatchStore(defaults: suite)
        check("a dismissal survives a relaunch, so the same problem isn't announced again", reopened.state == ScrobblerWatch.State(firing: true, dismissed: true))
        check("with no check run yet the status says so", !reopened.statusText.isEmpty)
        suite.removePersistentDomain(forName: "scrobbler-watch-store-check")
    }

    // MARK: The real library (read-only)

    @MainActor
    private static func dump(container: ModelContainer, path: String) async throws {
        var out: [String] = []
        let startedAt = Date()
        let lean = try await AppleMusicFavoritesReader.readRecentlyPlayed(days: 14)
        out.append(String(format: "LEAN_READ %.2fs tracks=%d", lean.readSeconds, lean.library.count))
        let full = try await AppleMusicFavoritesReader.read(includePlayed: true)
        out.append(String(format: "FULL_READ %.2fs tracks=%d", full.readSeconds, full.library.count))

        // The quick read must give exactly what the whole-library read gives for the same plays (away from the edges, where a play can land between the reads).
        let from = startedAt.addingTimeInterval(-14 * 86_400 + 300), to = startedAt.addingTimeInterval(-300)
        func key(_ t: AppleMusicSnapshot.Track) -> String { "\(t.artist)\u{1F}\(t.name)\u{1F}\(Int(t.lastPlayedAt?.timeIntervalSince1970 ?? 0))\u{1F}\(t.playCount)" }
        func inside(_ t: AppleMusicSnapshot.Track) -> Bool { t.lastPlayedAt.map { $0 >= from && $0 <= to } ?? false }
        let leanKeys = lean.library.filter(inside).map(key).sorted()
        let fullKeys = full.library.filter(inside).map(key).sorted()
        out.append("LEAN_VS_FULL lean=\(leanKeys.count) full=\(fullKeys.count) identical=\(leanKeys == fullKeys)")
        let onlyLean = Set(leanKeys).subtracting(fullKeys), onlyFull = Set(fullKeys).subtracting(leanKeys)
        for k in onlyLean.sorted().prefix(6) { out.append("ONLY_LEAN \(k.replacingOccurrences(of: "\u{1F}", with: " | "))") }
        for k in onlyFull.sorted().prefix(6) { out.append("ONLY_FULL \(k.replacingOccurrences(of: "\u{1F}", with: " | "))") }
        out.append("WINDOW from=\(Int(from.timeIntervalSince1970)) to=\(Int(to.timeIntervalSince1970)) leanReadAt=\(Int(startedAt.timeIntervalSince1970))")

        let (scrobbles, synced) = try await offMain {
            let scrobbles = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            let synced = (try? ModelContext(container).fetch(FetchDescriptor<SyncState>()))?.first?.lastSyncedAt
            return (scrobbles, synced)
        }
        let today = Watch.evaluate(recent: lean, scrobbles: scrobbles, syncedThrough: synced, settings: Watch.Settings(enabled: true), now: Date())
        out.append("TODAY missed=\(today.count) fires=\(today.fires) stillScrobblable=\(today.stillScrobblable)")

        // The store end to end (private preferences, never the real ones): turning it on checks at once; Music is read, the history is
        // compared, and the status is set.
        let suite = UserDefaults(suiteName: "scrobbler-watch-dump")!
        suite.removePersistentDomain(forName: "scrobbler-watch-dump")
        let store = ScrobblerWatchStore(defaults: suite)
        store.start(container: container)
        store.setEnabled(true)
        for _ in 0..<80 where store.isChecking || store.lastCheckedAt == nil && store.problem == nil { try? await Task.sleep(for: .milliseconds(250)) }
        out.append("STORE checked=\(store.lastCheckedAt != nil) problem=\(store.problem ?? "none") missed=\(store.verdict?.count ?? -1) showing=\(store.isShowing)")
        out.append("STORE_STATUS \(store.statusText)")
        store.setEnabled(false)
        suite.removePersistentDomain(forName: "scrobbler-watch-dump")

        // Replay: the check as it would have run at the end of each of the last 60 weeks, from what Music and the history say now.
        var fires = 0
        var weeks: [String] = []
        for k in 0..<60 {
            let end = startedAt.addingTimeInterval(-Double(k) * 7 * 86_400)
            let begin = end.addingTimeInterval(-7 * 86_400)
            let slice = AppleMusicSnapshot(
                favorites: [], library: full.library.filter { $0.lastPlayedAt.map { $0 > begin && $0 <= end } ?? false }, source: .favoritedFlag, readSeconds: 0
            )
            let history = scrobbles.filter { $0.playedAt <= end }
            let v = Watch.evaluate(recent: slice, scrobbles: history, syncedThrough: end, settings: Watch.Settings(enabled: true), now: end)
            if v.fires {
                fires += 1
                weeks.append("\(end.formatted(.iso8601.year().month().day())):\(v.count)of\(slice.library.count)")
            }
        }
        out.append("REPLAY_60_WEEKS fires=\(fires) \(weeks.joined(separator: " "))")
        try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(path)")
        exit(0)
    }
}
#endif
