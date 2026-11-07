import Foundation

/// The "your scrobbler may have stopped" check: after a sync, if Music has played several songs recently that Last.fm never got,
/// something that should be scrobbling them (a scrobbler app on this Mac, or on a phone whose plays sync into Music) probably isn't.
///
/// It reuses the Unscrobbled Plays comparison (the same song matching, the same allowance for clock differences and for plays too new to
/// judge), applied to just the songs Music played in the last few days. This file is the pure part: the settings, the verdict, and the
/// small piece of state that decides whether a warning is showing. `ScrobblerWatchStore` runs it.
enum ScrobblerWatch {
    nonisolated static let thresholdRange = 1...20
    nonisolated static let windowChoices = [1, 3, 7, 14]
    nonisolated static let defaultThreshold = 3
    nonisolated static let defaultWindowDays = 7
    /// A check after a sync is skipped when the last one was this recent, so a run of syncs doesn't keep asking Music.
    nonisolated static let minimumInterval: TimeInterval = 15 * 60

    // MARK: Settings

    struct Settings: Equatable, Sendable {
        /// Off until the person turns it on: the first read of Music asks for permission to control it, which a check that runs by
        /// itself must never do unprompted.
        var enabled = false
        /// How many different songs Music must have played, unscrobbled, to warn.
        var threshold = ScrobblerWatch.defaultThreshold
        /// How many days back a play counts.
        var windowDays = ScrobblerWatch.defaultWindowDays

        nonisolated static let enabledKey = "scrobblerWatch.enabled"
        nonisolated static let thresholdKey = "scrobblerWatch.threshold"
        nonisolated static let windowKey = "scrobblerWatch.windowDays"

        /// Values kept inside what the settings offer (an old or hand-edited value never breaks the check).
        nonisolated func clamped() -> Settings {
            var s = self
            s.threshold = min(max(s.threshold, ScrobblerWatch.thresholdRange.lowerBound), ScrobblerWatch.thresholdRange.upperBound)
            if !ScrobblerWatch.windowChoices.contains(s.windowDays) {
                s.windowDays = ScrobblerWatch.windowChoices.min { abs($0 - s.windowDays) < abs($1 - s.windowDays) } ?? ScrobblerWatch.defaultWindowDays
            }
            return s
        }

        nonisolated static func load(defaults: UserDefaults = .standard) -> Settings {
            Settings(
                enabled: defaults.bool(forKey: enabledKey),
                threshold: defaults.object(forKey: thresholdKey) as? Int ?? ScrobblerWatch.defaultThreshold,
                windowDays: defaults.object(forKey: windowKey) as? Int ?? ScrobblerWatch.defaultWindowDays
            ).clamped()
        }

        nonisolated func save(defaults: UserDefaults = .standard) {
            let s = clamped()
            defaults.set(s.enabled, forKey: Self.enabledKey)
            defaults.set(s.threshold, forKey: Self.thresholdKey)
            defaults.set(s.windowDays, forKey: Self.windowKey)
        }

        /// How many days of plays to ask Music for: the window plus a day, so a play at its edge is still there.
        nonisolated var readDays: Int { windowDays + 1 }
    }

    // MARK: Verdict

    struct Verdict: Sendable {
        /// The songs Music played in the window that Last.fm has no scrobble for, oldest first.
        let missed: [UnscrobbledPlaysEngine.Row]
        let threshold: Int
        let windowDays: Int
        let checkedAt: Date
        /// How many of them Last.fm would still accept as scrobbles (see `UnscrobbledPlaysScrobbling`).
        let stillScrobblable: Int

        var count: Int { missed.count }
        var fires: Bool { count >= threshold }
        var firstMissed: Date? { missed.first?.musicLastPlayed }
        var lastMissed: Date? { missed.last?.musicLastPlayed }
    }

    /// Compares the songs Music played recently (`recent`, from `readRecentlyPlayed`) with the history. Variants of a title count as the
    /// same song, so a "(feat. …)" scrobble doesn't look like a miss; a play too new to judge, a whole-hour clock difference, and a play
    /// already submitted from Unscrobbled Plays are not counted.
    nonisolated static func evaluate(
        recent: AppleMusicSnapshot, scrobbles: [ScrobbleSnapshot], syncedThrough: Date?, submitted: Set<String> = [],
        settings: Settings, now: Date = Date()
    ) -> Verdict {
        let settings = settings.clamped()
        let result = UnscrobbledPlaysEngine.compute(
            scrobbles: scrobbles, music: recent, matchVariants: true, syncedThrough: syncedThrough, submitted: submitted, now: now
        )
        let cutoff = now.addingTimeInterval(-Double(settings.windowDays) * 86_400)
        let missed = result.notScrobbled.filter { $0.musicLastPlayed >= cutoff }.sorted { ($0.musicLastPlayed, $0.id) < ($1.musicLastPlayed, $1.id) }
        return Verdict(
            missed: missed, threshold: settings.threshold, windowDays: settings.windowDays, checkedAt: now,
            stillScrobblable: UnscrobbledPlaysScrobbling.eligible(missed, now: now).count
        )
    }

    // MARK: Whether a warning is showing

    /// What the check remembers between runs: whether the last one found the problem, and whether the person dismissed it.
    struct State: Equatable, Sendable {
        var firing = false
        var dismissed = false
    }

    enum Transition: Equatable, Sendable {
        case began(count: Int)
        case recovered
    }

    /// The state after a check. A dismissed warning stays dismissed for as long as the problem continues, however many more plays are
    /// missed, and only comes back once a check has found things healthy again and then finds the problem anew.
    nonisolated static func advance(_ state: State, with verdict: Verdict) -> (State, Transition?) {
        var next = state
        if verdict.fires {
            guard !state.firing else { return (next, nil) }
            next.firing = true
            return (next, .began(count: verdict.count))
        }
        guard state.firing else { next.dismissed = false; return (next, nil) }
        next.firing = false
        next.dismissed = false
        return (next, .recovered)
    }

    nonisolated static func isShowing(_ state: State) -> Bool { state.firing && !state.dismissed }
}
