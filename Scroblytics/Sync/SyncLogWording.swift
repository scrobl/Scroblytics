import Foundation

/// The lines a sync writes to the activity log about what kind of sync it is and why, so a problem report can say whether a launch did a
/// quick check, resumed an unfinished import, or re-walked the whole history (and what made it). Counts only: no artist, album, track,
/// tag or account name, so the lines are safe to share.
enum SyncLogWording {
    /// Why a quick sync turned into a full re-check of the history.
    enum Escalation: Equatable, Sendable {
        /// Last.fm's total rose by more than the quick sync found: plays were added with times older than the newest one already here
        /// (a scrobbler that sends late, with the original time of the play), which a "newer than" request can never see.
        case totalGrewMoreThanFound(grew: Int, found: Int)
        /// Last.fm's total went down: plays were deleted on Last.fm.
        case totalFell(by: Int)
        /// This is the first time the total has been compared, and Last.fm has more plays than this Mac.
        case fewerHereThanLastfm(onThisMac: Int, onLastfm: Int)
    }

    /// What decides it, as `SyncEngine` does: the total Last.fm reported last time against this time, and how many plays the quick pass found.
    static func escalation(previousTotal: Int?, remoteTotal: Int, found: Int, onThisMac: Int) -> Escalation? {
        if let previousTotal {
            if remoteTotal < previousTotal { return .totalFell(by: previousTotal - remoteTotal) }
            if found < remoteTotal - previousTotal { return .totalGrewMoreThanFound(grew: remoteTotal - previousTotal, found: found) }
            return nil
        }
        return onThisMac < remoteTotal ? .fewerHereThanLastfm(onThisMac: onThisMac, onLastfm: remoteTotal) : nil
    }

    static func escalationLine(_ reason: Escalation) -> String {
        switch reason {
        case .totalGrewMoreThanFound(let grew, let found):
            return "Quick sync found \(count(found, "new play")) but Last.fm's total went up by \(grew), so it is re-checking (usually plays sent late with older times)"
        case .totalFell(let by):
            return "Last.fm's total went down by \(by), so it is re-checking (plays deleted on Last.fm)"
        case .fewerHereThanLastfm(let onThisMac, let onLastfm):
            return "This Mac has \(onThisMac.formatted()) plays and Last.fm has \(onLastfm.formatted()), so it is re-checking the whole history"
        }
    }

    /// The first line of a sync: which kind it is, with the two totals it works from.
    static func planLine(mode: SyncProgress.Mode, requestedFull: Bool, onThisMac: Int, onLastfm: Int, resumePage: Int?) -> String {
        let totals = "this Mac has \(onThisMac.formatted()), Last.fm has \(onLastfm.formatted())"
        switch mode {
        case .incremental:
            return "Sync plan: quick check for new plays (\(totals))"
        case .full:
            return requestedFull ? "Sync plan: full resync, as asked (\(totals))" : "Sync plan: first import, nothing here yet (\(totals))"
        case .resumedBackfill:
            return "Sync plan: resuming an unfinished import" + (resumePage.map { " from page \($0)" } ?? "") + " (\(totals))"
        case .reconciliationBackfill:
            return "Sync plan: full re-check (\(totals))"
        }
    }

    /// The result of a full re-check that began as a quick sync.
    static func recheckResultLine(added: Int, updated: Int, removed: Int, complete: Bool) -> String {
        "Full re-check \(complete ? "finished" : "paused, to continue next sync"): added \(added.formatted()), updated \(updated.formatted()), removed \(removed.formatted())"
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")" }
}

/// When a quick sync sees Last.fm's total move by more than it found, the plays it missed are almost always recent: Last.fm only accepts
/// plays up to about two weeks old, so anything sent since the last sync is dated within two weeks before it. So the sync first re-checks
/// just that stretch of time, and compares the totals again. If they now agree, that was all there was to find. If they don't, the cause
/// is further back (a deletion long ago, say) and the whole history is re-checked as before: never worse than re-checking everything.
enum SyncRecheckPlan {
    /// How far before the last sync the window starts: Last.fm's two-week limit plus a day of margin.
    static let lateDays = 15
    /// A window longer than this (the last sync was long ago) is not worth trying: the whole history is walked instead.
    static let maxWindowDays = 60
    /// A window with more pages than this is left to the whole-history walk.
    static let maxWindowPages = 100

    /// The unix time the window starts at, or nil when a window can't settle it: no earlier sync to measure from, a window longer than
    /// `maxWindowDays`, or a cause (this is the first comparison of totals) that isn't about recent plays.
    static func windowStart(escalation: SyncLogWording.Escalation, lastSyncedAt: Date?, now: Date) -> Int? {
        switch escalation {
        case .totalGrewMoreThanFound, .totalFell: break
        case .fewerHereThanLastfm: return nil
        }
        guard let lastSyncedAt else { return nil }
        let start = Int(lastSyncedAt.timeIntervalSince1970) - lateDays * 86_400
        guard Int(now.timeIntervalSince1970) - start <= maxWindowDays * 86_400 else { return nil }
        return max(0, start)
    }

    /// Whole days from the window's start to now, for the log.
    static func days(from start: Int, to now: Int) -> Int { max(1, (now - start + 86_399) / 86_400) }

    /// Whether what the sync has now accounts for the change in Last.fm's total exactly: the total moved by what was added, less what was
    /// removed. Any difference means something is still missing (or Last.fm's count counts what its list does not return).
    static func totalsMatch(previousTotal: Int, remoteTotal: Int, added: Int, removed: Int) -> Bool {
        remoteTotal - previousTotal == added - removed
    }
}

extension SyncLogWording {
    static func windowStartLine(days: Int) -> String {
        "Re-checking just the last \(days) days first, then comparing the totals again"
    }

    static func windowResultLine(days: Int, matched: Bool, added: Int, removed: Int, expectedChange: Int, actualChange: Int) -> String {
        let found = "found \(added.formatted()) older play\(added == 1 ? "" : "s"), removed \(removed.formatted())"
        let signed: (Int) -> String = { ($0 >= 0 ? "+" : "") + $0.formatted() }
        return matched
            ? "Last \(days) days re-checked: \(found); the totals now agree, so the whole history did not need re-checking"
            : "Last \(days) days re-checked: \(found); the totals still differ (Last.fm \(signed(expectedChange)), here \(signed(actualChange))), so the whole history is being re-checked"
    }
}
