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
            return "Quick sync found \(count(found, "new play")) but Last.fm's total went up by \(grew), so the whole history is being re-checked (usually plays sent late with older times)"
        case .totalFell(let by):
            return "Last.fm's total went down by \(by), so the whole history is being re-checked (plays deleted on Last.fm)"
        case .fewerHereThanLastfm(let onThisMac, let onLastfm):
            return "This Mac has \(onThisMac.formatted()) plays and Last.fm has \(onLastfm.formatted()), so the whole history is being re-checked"
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
