import Foundation
import SwiftData

struct SyncProgress: Sendable {
    enum Phase: String, Sendable {
        case preparing
        case scrobbles
        case lovedTracks
    }

    enum Mode: Sendable {
        case incremental
        case full
        case resumedBackfill
        case reconciliationBackfill

        var isFullHistory: Bool {
            self != .incremental
        }
    }

    let phase: Phase
    let mode: Mode
    let totalScrobbles: Int
    let newScrobbles: Int
    let processedScrobbles: Int
    let progressTotal: Int
    /// Set while the import is waiting out Last.fm's rate limit: how many seconds until it tries again.
    var waitingSeconds: Int? = nil

    var fractionCompleted: Double? {
        guard progressTotal > 0 else { return nil }
        return min(1, Double(processedScrobbles) / Double(progressTotal))
    }
}

struct SyncSummary: Sendable {
    let added: Int
    let updated: Int
    let removed: Int
    let escalatedToFullBackfill: Bool
    /// False when a backfill hit `maxWindows` and left a resumable cursor
    /// rather than actually finishing — sync again to continue it.
    let isComplete: Bool
    let lovedTracksChanged: Bool
    /// Set when a difference between Last.fm's total and what was found could not be settled by checking the recent days: the app asks
    /// whether to check the whole history, ignore the difference, or skip it for now.
    var pendingRecheck: PendingRecheck? = nil

    var dataChanged: Bool {
        added > 0 || updated > 0 || removed > 0 || lovedTracksChanged
    }

    init(
        added: Int,
        updated: Int,
        removed: Int,
        escalatedToFullBackfill: Bool,
        isComplete: Bool,
        lovedTracksChanged: Bool = false,
        pendingRecheck: PendingRecheck? = nil
    ) {
        self.added = added
        self.updated = updated
        self.removed = removed
        self.escalatedToFullBackfill = escalatedToFullBackfill
        self.isComplete = isComplete
        self.lovedTracksChanged = lovedTracksChanged
        self.pendingRecheck = pendingRecheck
    }

    func includingLovedTracksChange(_ changed: Bool) -> SyncSummary {
        SyncSummary(
            added: added,
            updated: updated,
            removed: removed,
            escalatedToFullBackfill: escalatedToFullBackfill,
            isComplete: isComplete,
            lovedTracksChanged: changed,
            pendingRecheck: pendingRecheck
        )
    }
}

enum TargetedSyncScope: Sendable {
    case artist
    case album
    case track
}

struct TargetedSyncSummary: Sendable {
    let scanned: Int
    let added: Int
    let updated: Int
    let removed: Int
    let windows: Int
    let isComplete: Bool
}

private struct BackfillResult {
    let added: Int
    let updated: Int
    let removed: Int
    let isComplete: Bool
}

enum SyncError: Error, LocalizedError {
    case notConfigured
    case pageCapExceeded

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Set up your Last.fm account in Settings before syncing."
        case .pageCapExceeded: "Sync stopped at its safety limit of pages. Run Sync again to continue."
        }
    }
}

/// Last.fm sync into a SwiftData-backed store. The algorithm covers page size,
/// backfill windowing pinned to a fixed `to`, resume cursor, incremental `from` = max cached uts + 1, dedupe key = uts+artist+
/// track, backdated-plays escalation via `user.getInfo`, and the retry/backoff
/// schedule. A real database means the whole history never has to be held in
/// memory at once (see `Scrobble.lastConfirmedAt`).
@ModelActor
actor SyncEngine {
    static let saveEvery = 10
    static let pageCap = 10_000
    static let maxWindows = 500
    private static let targetedWindowGap = 6 * 60 * 60
    private static let targetedWindowPadding = 60
    private static let targetedMaxWindows = 200
    private static let targetedPageCap = 2_000

    private var artistCache: [String: Artist] = [:]
    private var albumCache: [String: Album] = [:]
    private var trackCache: [String: Track] = [:]

    func sync(
        credentials: LastfmCredentials,
        full: Bool,
        fullRecheck: Bool = false,
        progress: @escaping @Sendable (SyncProgress) -> Void = { _ in }
    ) async throws -> SyncSummary {
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        let runStartedAt = Date()
        let nowUts = Int(runStartedAt.timeIntervalSince1970)

        let state = try fetchOrCreateSyncState(username: credentials.username)
        let existingCount = try modelContext.checkedCount(FetchDescriptor<Scrobble>())
        let remotePlaycount = try await client.fetchUserPlaycount()
        let expectedNew = max(0, remotePlaycount - existingCount)
        let initialMode: SyncProgress.Mode
        if full || existingCount == 0 {
            initialMode = .full
        } else if state.backfillNextPage != nil {
            initialMode = .resumedBackfill
        } else {
            initialMode = .incremental
        }
        ActivityLog.record(.sync, SyncLogWording.planLine(mode: initialMode, requestedFull: full, onThisMac: existingCount, onLastfm: remotePlaycount, resumePage: state.backfillNextPage))
        progress(SyncProgress(
            phase: .preparing,
            mode: initialMode,
            totalScrobbles: remotePlaycount,
            newScrobbles: expectedNew,
            processedScrobbles: 0,
            progressTotal: full || existingCount == 0 ? remotePlaycount : expectedNew
        ))

        if let resumeNextPage = state.backfillNextPage, !full {
            // Resuming an interrupted backfill — same window, same run identity.
            let to = state.backfillTo ?? nowUts
            let runIdentity = state.backfillRunIdentity ?? runStartedAt
            let result = try await runBackfill(
                client: client, state: state,
                startPage: resumeNextPage, startTo: to, runIdentity: runIdentity,
                totalScrobbles: remotePlaycount, newScrobbles: expectedNew,
                mode: .resumedBackfill, progress: progress
            )
            let summary = try finishBackfill(result, state: state, runStartedAt: runStartedAt, escalated: false)
            return summary
        }

        if full || existingCount == 0 {
            let runIdentity = runStartedAt
            state.backfillRunIdentity = runIdentity
            let result = try await runBackfill(
                client: client, state: state, startPage: 1, startTo: nowUts, runIdentity: runIdentity,
                totalScrobbles: remotePlaycount, newScrobbles: expectedNew,
                mode: .full, progress: progress
            )
            let summary = try finishBackfill(result, state: state, runStartedAt: runStartedAt, escalated: false)
            return summary
        }

        // Incremental.
        let maxExisting = try maxExistingUts()
        let fromParam = maxExisting + 1
        var added = 0
        var updated = 0
        var processed = 0
        var page = 1
        var totalPages = 1
        repeat {
            let waitingProgress = SyncProgress(
                phase: .scrobbles, mode: .incremental, totalScrobbles: remotePlaycount, newScrobbles: expectedNew,
                processedScrobbles: processed, progressTotal: max(expectedNew, processed)
            )
            let result = try await client.fetchRecentTracksPage(page: page, from: fromParam, onWait: { seconds in
                var update = waitingProgress
                update.waitingSeconds = seconds
                progress(update)
            })
            totalPages = result.totalPages
            let (a, u) = try upsert(result.scrobbles, confirmedAt: runStartedAt)
            added += a
            updated += u
            processed += result.scrobbles.count
            progress(SyncProgress(
                phase: .scrobbles,
                mode: .incremental,
                totalScrobbles: remotePlaycount,
                newScrobbles: expectedNew,
                processedScrobbles: processed,
                progressTotal: result.totalScrobbles
            ))
            page += 1
        } while page <= totalPages && page <= Self.pageCap

        // Persist the incremental pass's inserts now, before deciding whether to escalate — a
        // reconciliation backfill re-walks this same window, and its own `upsert` dedups by fetching
        // "existing" rows; an unsaved insert from this pass isn't guaranteed visible to that fetch, which
        // would otherwise re-insert the same scrobbles a second time (confirmed: this was producing exact
        // duplicates of the newest scrobbles whenever a sync happened to escalate).
        try modelContext.save()

        let previousTotal = state.remoteTotal
        let currentCount = try modelContext.checkedCount(FetchDescriptor<Scrobble>())
        var escalation = SyncLogWording.escalation(previousTotal: previousTotal, remoteTotal: remotePlaycount, found: added, onThisMac: currentCount)
        // "Check now" walks the whole history even if the totals happen to agree this time.
        if fullRecheck && escalation == nil { escalation = .askedFor }

        if let escalation {
            ActivityLog.record(.sync, SyncLogWording.escalationLine(escalation))
            // Late plays (or a recent deletion) sit within two weeks of the last sync, so look there first and compare the totals again.
            var windowAdded = 0, windowUpdated = 0, windowRemoved = 0
            var windowDaysTried: Int?
            if !fullRecheck, let previousTotal, let windowStart = SyncRecheckPlan.windowStart(escalation: escalation, lastSyncedAt: state.lastSyncedAt, now: runStartedAt) {
                let days = SyncRecheckPlan.days(from: windowStart, to: nowUts)
                windowDaysTried = days
                ActivityLog.record(.sync, SyncLogWording.windowStartLine(days: days))
                if let window = try await recheckWindow(
                    client: client, from: windowStart, to: nowUts, runIdentity: runStartedAt,
                    totalScrobbles: remotePlaycount, newScrobbles: expectedNew, progress: progress
                ) {
                    windowAdded = window.added; windowUpdated = window.updated; windowRemoved = window.removed
                    let actualChange = added + windowAdded - windowRemoved
                    let matched = SyncRecheckPlan.totalsMatch(previousTotal: previousTotal, remoteTotal: remotePlaycount, added: added + windowAdded, removed: windowRemoved)
                    ActivityLog.record(.sync, SyncLogWording.windowResultLine(
                        days: days, matched: matched, added: windowAdded, removed: windowRemoved,
                        expectedChange: remotePlaycount - previousTotal, actualChange: actualChange
                    ))
                    if matched {
                        state.remoteTotal = remotePlaycount
                        state.lastSyncedAt = runStartedAt
                        try modelContext.save()
                        return SyncSummary(added: added + windowAdded, updated: updated + windowUpdated, removed: windowRemoved, escalatedToFullBackfill: false, isComplete: true)
                    }
                } else {
                    ActivityLog.record(.sync, "The last \(days) days are too long to re-check on their own")
                    windowDaysTried = nil
                }
            }
            if !fullRecheck {
                // The recent days could not settle it, and the walk of the whole history can take many minutes, so finish this sync and let
                // the person choose (see `RecheckStrip`). The baseline moves only by what was found, so what is left unexplained is what is
                // asked about next time if it is skipped, and plays already found are not counted twice.
                let accounted = added + windowAdded - windowRemoved
                if let previousTotal {
                    state.remoteTotal = SyncRecheckPlan.baselineAfterUnsettled(previousTotal: previousTotal, added: added + windowAdded, removed: windowRemoved)
                }
                state.lastSyncedAt = runStartedAt
                try modelContext.save()
                let unexplained = previousTotal.map { (remotePlaycount - $0) - accounted } ?? (remotePlaycount - currentCount)
                let pending = PendingRecheck(reason: escalation, remoteTotal: remotePlaycount, unexplained: unexplained, windowDays: windowDaysTried)
                ActivityLog.record(.sync, SyncLogWording.waitingLine(pending))
                return SyncSummary(
                    added: added + windowAdded, updated: updated + windowUpdated, removed: windowRemoved,
                    escalatedToFullBackfill: false, isComplete: true, pendingRecheck: pending
                )
            }
            // Backdated plays (or server-side deletions) an incremental `from`
            // filter can never reach — re-walk the entire history and let the
            // per-window reconcile pick up both additions and removals.
            let runIdentity = runStartedAt
            state.backfillRunIdentity = runIdentity
            let backfillResult = try await runBackfill(
                client: client, state: state, startPage: 1, startTo: nowUts, runIdentity: runIdentity,
                totalScrobbles: remotePlaycount, newScrobbles: expectedNew,
                mode: .reconciliationBackfill, progress: progress
            )
            let combined = BackfillResult(
                added: backfillResult.added + added + windowAdded,
                updated: backfillResult.updated + updated + windowUpdated,
                removed: backfillResult.removed + windowRemoved,
                isComplete: backfillResult.isComplete
            )
            let summary = try finishBackfill(combined, state: state, runStartedAt: runStartedAt, escalated: true, remoteTotalOverride: remotePlaycount)
            ActivityLog.record(.sync, SyncLogWording.recheckResultLine(added: summary.added, updated: summary.updated, removed: summary.removed, complete: summary.isComplete))
            return summary
        }

        // remoteTotal always tracks the freshest known truth once observed,
        // whether or not this particular sync needed to escalate.
        state.remoteTotal = remotePlaycount
        state.lastSyncedAt = runStartedAt
        try modelContext.save()
        return SyncSummary(
            added: added,
            updated: updated,
            removed: 0,
            escalatedToFullBackfill: false,
            isComplete: true
        )
    }

    /// Re-fetches only the listening windows containing the selected entity's
    /// cached plays. This picks up Last.fm-side edits and deletions without a
    /// full-history sync. Nearby timestamps are clustered to avoid one request
    /// per play.
    func resync(
        credentials: LastfmCredentials,
        scope: TargetedSyncScope,
        artist: String,
        album: String? = nil,
        track: String? = nil
    ) async throws -> TargetedSyncSummary {
        let artistKey = artist.lowercased()
        let albumKey = album?.lowercased()
        let trackKey = track?.lowercased()
        let belongsToTarget: (FetchedScrobble) -> Bool = { fetched in
            guard fetched.artist.lowercased() == artistKey else { return false }
            switch scope {
            case .artist:
                return true
            case .album:
                return fetched.album.lowercased() == albumKey
            case .track:
                return fetched.track.lowercased() == trackKey
            }
        }
        let allScrobbles = try modelContext.fetch(FetchDescriptor<Scrobble>())
        let targets = allScrobbles.filter { row in
            guard row.artistName.lowercased() == artistKey else { return false }
            switch scope {
            case .artist:
                return true
            case .album:
                return row.albumName.lowercased() == albumKey
            case .track:
                return row.trackName.lowercased() == trackKey
            }
        }

        let timestamps = Array(Set(targets.map { Int($0.playedAt.timeIntervalSince1970) })).sorted()
        guard let firstTimestamp = timestamps.first else {
            return TargetedSyncSummary(scanned: 0, added: 0, updated: 0, removed: 0, windows: 0, isComplete: true)
        }

        var windows: [(from: Int, to: Int)] = []
        var windowStart = firstTimestamp
        var windowEnd = firstTimestamp
        for timestamp in timestamps.dropFirst() {
            if timestamp - windowEnd <= Self.targetedWindowGap {
                windowEnd = timestamp
            } else {
                windows.append((windowStart, windowEnd))
                windowStart = timestamp
                windowEnd = timestamp
            }
        }
        windows.append((windowStart, windowEnd))

        let windowsWereCapped = windows.count > Self.targetedMaxWindows
        let selectedWindows = Array(windows.suffix(Self.targetedMaxWindows))
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        let runIdentity = Date()
        var scanned = 0
        var added = 0
        var updated = 0
        var removed = 0
        var pagesFetched = 0
        var hitPageCap = false

        for window in selectedWindows {
            let from = window.from - Self.targetedWindowPadding
            let to = window.to + Self.targetedWindowPadding
            var fetchedKeysByTimestamp: [Int: Set<String>] = [:]
            var page = 1
            var totalPages = 1

            while page <= totalPages {
                guard pagesFetched < Self.targetedPageCap else {
                    hitPageCap = true
                    break
                }
                let result = try await client.fetchRecentTracksPage(page: page, from: from, to: to)
                pagesFetched += 1
                totalPages = result.totalPages
                scanned += result.scrobbles.count
                for fetched in result.scrobbles {
                    fetchedKeysByTimestamp[fetched.uts, default: []].insert(
                        scrobbleKey(uts: fetched.uts, artist: fetched.artist, track: fetched.track)
                    )
                }
                let changes = try upsert(
                    result.scrobbles,
                    confirmedAt: runIdentity,
                    countChange: belongsToTarget
                )
                added += changes.added
                updated += changes.updated
                page += 1
            }

            // Never infer deletions from an incompletely fetched window.
            guard !hitPageCap else { break }
            for target in targets {
                let timestamp = Int(target.playedAt.timeIntervalSince1970)
                guard timestamp >= window.from, timestamp <= window.to else { continue }
                let key = scrobbleKey(uts: timestamp, artist: target.artistName, track: target.trackName)
                if fetchedKeysByTimestamp[timestamp]?.contains(key) != true {
                    modelContext.delete(target)
                    removed += 1
                }
            }
        }

        try modelContext.save()
        return TargetedSyncSummary(
            scanned: scanned,
            added: added,
            updated: updated,
            removed: removed,
            windows: selectedWindows.count,
            isComplete: !windowsWereCapped && !hitPageCap
        )
    }

    /// Finalizes `SyncState` after a backfill run — `lastSyncedAt`/`remoteTotal`
    /// are only stamped when the backfill actually finished (matches the
    /// source: `lastSyncedAt: backfill ? store.lastSyncedAt : nowUts`). A run
    /// that only got partway (hit `maxWindows`) leaves its resumable cursor
    /// alone and reports `isComplete: false` instead.
    private func finishBackfill(
        _ result: BackfillResult, state: SyncState, runStartedAt: Date, escalated: Bool,
        remoteTotalOverride: Int? = nil
    ) throws -> SyncSummary {
        if result.isComplete {
            state.lastSyncedAt = runStartedAt
            // A completed backfill's baseline is the
            // fetched total itself, not a trusted server `@attr.total`.
            state.remoteTotal = try remoteTotalOverride ?? modelContext.fetchCount(FetchDescriptor<Scrobble>())
        }
        try modelContext.save()
        return SyncSummary(
            added: result.added, updated: result.updated, removed: result.removed,
            escalatedToFullBackfill: escalated, isComplete: result.isComplete
        )
    }

    // MARK: - Backfill (newest → oldest, windowed)

    /// Walks history newest→oldest in `to`-pinned windows (Last.fm caps how
    /// deep a single query can paginate). Each window is fully paged, then
    /// reconciled against the DB before opening the next, older window at
    /// `windowOldestUts - 1`.
    private func runBackfill(
        client: LastfmAPIClient, state: SyncState,
        startPage: Int, startTo: Int, runIdentity: Date,
        totalScrobbles: Int, newScrobbles: Int, mode: SyncProgress.Mode,
        progress: @escaping @Sendable (SyncProgress) -> Void
    ) async throws -> BackfillResult {
        var added = 0
        var updated = 0
        var removed = 0
        var processed = 0
        var pagesFetchedThisRun = 0

        var page = startPage
        var to = startTo
        var windowOldestUts: Int?
        var totalPages = state.backfillTotalPages ?? 1

        for _ in 0..<Self.maxWindows {
            var isFirstPageOfWindow = true
            while true {
                if pagesFetchedThisRun >= Self.pageCap {
                    try checkpoint(state: state, nextPage: page, to: to, totalPages: totalPages, runIdentity: runIdentity)
                    throw SyncError.pageCapExceeded
                }
                let result: LastfmAPIClient.Page
                let waitingProgress = SyncProgress(
                    phase: .scrobbles, mode: mode, totalScrobbles: totalScrobbles, newScrobbles: newScrobbles,
                    processedScrobbles: processed, progressTotal: totalScrobbles
                )
                do {
                    result = try await client.fetchRecentTracksPage(page: page, to: to, onWait: { seconds in
                        var update = waitingProgress
                        update.waitingSeconds = seconds
                        progress(update)
                    })
                } catch {
                    try checkpoint(state: state, nextPage: page, to: to, totalPages: totalPages, runIdentity: runIdentity)
                    throw error
                }
                pagesFetchedThisRun += 1
                if isFirstPageOfWindow {
                    totalPages = result.totalPages
                    isFirstPageOfWindow = false
                }
                for s in result.scrobbles {
                    windowOldestUts = min(windowOldestUts ?? s.uts, s.uts)
                }
                let (a, u) = try upsert(result.scrobbles, confirmedAt: runIdentity)
                added += a
                updated += u
                processed += result.scrobbles.count
                progress(SyncProgress(
                    phase: .scrobbles,
                    mode: mode,
                    totalScrobbles: totalScrobbles,
                    newScrobbles: newScrobbles,
                    processedScrobbles: processed,
                    progressTotal: totalScrobbles
                ))

                page += 1
                if page % Self.saveEvery == 0 || page > totalPages {
                    try checkpoint(state: state, nextPage: page, to: to, totalPages: totalPages, runIdentity: runIdentity)
                }
                if page > totalPages { break }
            }

            // Window exhausted — drop anything in its range Last.fm no longer
            // returns, then either finish (empty window = start of history)
            // or open the next, older window.
            guard let oldest = windowOldestUts else {
                clearBackfillCursor(state: state)
                try modelContext.save()
                return BackfillResult(added: added, updated: updated, removed: removed, isComplete: true)
            }
            removed += try reconcileWindow(lowerUts: oldest, upperUts: to, runIdentity: runIdentity)

            to = oldest - 1
            page = 1
            windowOldestUts = nil
            try checkpoint(state: state, nextPage: page, to: to, totalPages: 1, runIdentity: runIdentity)
        }

        // Hit the window cap — leave state resumable rather than declaring done.
        return BackfillResult(added: added, updated: updated, removed: removed, isComplete: false)
    }

    /// Re-walks just `from`…`to` (newest first) and drops any local play in that stretch Last.fm no longer returns. It keeps no resume
    /// point: if it is interrupted the next sync simply redoes this small stretch. Returns nil, having changed nothing further, when the
    /// stretch has more than `SyncRecheckPlan.maxWindowPages` pages (that is left to the whole-history walk).
    private func recheckWindow(
        client: LastfmAPIClient, from: Int, to: Int, runIdentity: Date,
        totalScrobbles: Int, newScrobbles: Int, progress: @escaping @Sendable (SyncProgress) -> Void
    ) async throws -> (added: Int, updated: Int, removed: Int)? {
        var added = 0, updated = 0, processed = 0
        var page = 1, totalPages = 1
        repeat {
            let waitingProgress = SyncProgress(
                phase: .scrobbles, mode: .incremental, totalScrobbles: totalScrobbles, newScrobbles: newScrobbles,
                processedScrobbles: processed, progressTotal: max(processed, 1)
            )
            let result = try await client.fetchRecentTracksPage(page: page, from: from, to: to, onWait: { seconds in
                var update = waitingProgress
                update.waitingSeconds = seconds
                progress(update)
            })
            totalPages = result.totalPages
            if totalPages > SyncRecheckPlan.maxWindowPages { try modelContext.save(); return nil }
            let (a, u) = try upsert(result.scrobbles, confirmedAt: runIdentity)
            added += a
            updated += u
            processed += result.scrobbles.count
            progress(SyncProgress(
                phase: .scrobbles, mode: .incremental, totalScrobbles: totalScrobbles, newScrobbles: newScrobbles,
                processedScrobbles: processed, progressTotal: max(result.totalScrobbles, processed)
            ))
            page += 1
        } while page <= totalPages
        try modelContext.save()
        // Last.fm's `from` may or may not include its own second, so a play exactly there is never judged missing.
        let removed = try reconcileWindow(lowerUts: from + 1, upperUts: to, runIdentity: runIdentity)
        try modelContext.save()
        return (added, updated, removed)
    }

    private func checkpoint(state: SyncState, nextPage: Int, to: Int, totalPages: Int, runIdentity: Date) throws {
        state.backfillNextPage = nextPage
        state.backfillTo = to
        state.backfillTotalPages = totalPages
        state.backfillRunIdentity = runIdentity
        try modelContext.save()
    }

    private func clearBackfillCursor(state: SyncState) {
        state.backfillNextPage = nil
        state.backfillTo = nil
        state.backfillTotalPages = nil
        state.backfillRunIdentity = nil
    }

    // MARK: - Loved tracks

    /// Re-syncs `user.getLovedTracks`, run independently after a scrobble sync
    /// so it never keeps the primary sync UI blocked. Best-effort and
    /// non-throwing: errors leave the prior set untouched.
    ///
    /// Common case — only new loves since last time — costs ONE request: the
    /// list is newest-first and carries a total, so when page 1's unseen tracks
    /// account for exactly the gap between our count and Last.fm's total, those
    /// are the only change (`LovedSyncPlan`). Anything else (an unlove, a swap,
    /// a love not on page 1, a count that doesn't reconcile) falls through to
    /// the full re-page below, so the result is the same either way.
    ///
    /// Data safety: older loves live
    /// on later pages, so a partial fetch must NEVER replace the set —
    /// dropped tracks from a failed page would silently read as "unloved."
    /// Only a fully complete walk replaces the set outright (so genuine
    /// unloves — tracks the user removed on Last.fm's side — still take
    /// effect); an incomplete walk unions what it did get into the prior set
    /// instead.
    func syncLovedTracks(
        credentials: LastfmCredentials,
        progress: @escaping @Sendable (_ remaining: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> Bool {
        let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
        progress(1, 1)
        do {
            var fetched: [(artist: String, track: String)] = []
            var lovedDates: [String: Date] = [:]
            func remember(_ page: LastfmAPIClient.LovedTracksPage) {
                for (track, date) in zip(page.tracks, page.dates) {
                    guard let date else { continue }
                    let key = TextNormalization.lovedKey(artist: track.artist, track: track.track)
                    if lovedDates[key] == nil { lovedDates[key] = date }
                }
            }
            let first = try await client.fetchLovedTracksPage(page: 1)
            remember(first)

            let local = try modelContext.fetch(FetchDescriptor<LovedTrackEntry>())
            // Loves saved before dates were kept get theirs from one full walk (the quick path only sees page 1).
            let needsDates = LovedSyncPlan.datesNeedBackfill && local.contains { $0.lovedAt == nil }
            if !needsDates, LovedSyncPlan.fullWalkIsRecent(), case .additions(let added) = LovedSyncPlan.plan(
                firstPage: first.tracks, total: first.total, pageSize: LastfmAPIClient.pageSize,
                localKeys: Set(local.map(\.cacheKey)), localCount: local.count
            ) {
                for track in added {
                    let key = TextNormalization.lovedKey(artist: track.artist, track: track.track)
                    modelContext.insert(LovedTrackEntry(cacheKey: key, artist: track.artist, track: track.track, lovedAt: lovedDates[key]))
                }
                if !added.isEmpty { try modelContext.save() }
                return !added.isEmpty
            }

            fetched.append(contentsOf: first.tracks)
            let totalPages = min(first.totalPages, 50) // safety cap
            progress(max(1, totalPages - 1), totalPages)
            var complete = true
            if totalPages > 1 {
                for page in 2...totalPages {
                    do {
                        let result = try await client.fetchLovedTracksPage(page: page)
                        remember(result)
                        fetched.append(contentsOf: result.tracks)
                        progress(max(1, totalPages - page), totalPages)
                    } catch {
                        complete = false
                        break
                    }
                }
            }

            let existing = local
            var existingKeys = Set(existing.map(\.cacheKey))
            var changed = false

            if complete {
                LovedSyncPlan.recordFullWalk()
                LovedSyncPlan.datesBackfilled = true
                for entry in existing where entry.lovedAt == nil {
                    if let date = lovedDates[entry.cacheKey] { entry.lovedAt = date; changed = true }
                }
                let fetchedKeys = Set(fetched.map {
                    TextNormalization.lovedKey(artist: $0.artist, track: $0.track)
                })
                for entry in existing where !fetchedKeys.contains(entry.cacheKey) {
                    modelContext.delete(entry)
                    existingKeys.remove(entry.cacheKey)
                    changed = true
                }

                for track in fetched {
                    let key = TextNormalization.lovedKey(artist: track.artist, track: track.track)
                    guard !existingKeys.contains(key) else { continue }
                    existingKeys.insert(key)
                    modelContext.insert(LovedTrackEntry(cacheKey: key, artist: track.artist, track: track.track, lovedAt: lovedDates[key]))
                    changed = true
                }
            } else {
                for track in fetched {
                    let key = TextNormalization.lovedKey(artist: track.artist, track: track.track)
                    guard !existingKeys.contains(key) else { continue }
                    existingKeys.insert(key)
                    modelContext.insert(LovedTrackEntry(cacheKey: key, artist: track.artist, track: track.track, lovedAt: lovedDates[key]))
                    changed = true
                }
            }
            if changed {
                try modelContext.save()
            }
            return changed
        } catch {
            // First-page failure — leave the prior set entirely untouched.
            return false
        }
    }

    // MARK: - Merge

    /// Upserts a page's scrobbles, keyed by
    /// uts+artist+track (not uts alone — two different tracks can legitimately
    /// scrobble in the same second). An existing row's album/art is refreshed
    /// in place so metadata edits on Last.fm's side are picked up on resync.
    /// Also opportunistically resolves Artist/Album/Track identity rows so
    /// later phases (Overview, Top Charts) have them ready to attach
    /// overrides/relationships to.
    @discardableResult
    private func upsert(
        _ scrobbles: [FetchedScrobble],
        confirmedAt: Date,
        countChange: (FetchedScrobble) -> Bool = { _ in true }
    ) throws -> (added: Int, updated: Int) {
        guard !scrobbles.isEmpty else { return (0, 0) }
        let minUts = scrobbles.map(\.uts).min()!
        let maxUts = scrobbles.map(\.uts).max()!
        let lower = Date(timeIntervalSince1970: TimeInterval(minUts))
        let upper = Date(timeIntervalSince1970: TimeInterval(maxUts))
        let descriptor = FetchDescriptor<Scrobble>(predicate: #Predicate { $0.playedAt >= lower && $0.playedAt <= upper })
        let existing = try modelContext.fetch(descriptor)
        var byKey: [String: Scrobble] = [:]
        for row in existing {
            byKey[scrobbleKey(uts: Int(row.playedAt.timeIntervalSince1970), artist: row.artistName, track: row.trackName)] = row
        }

        var added = 0
        var updated = 0
        for fetched in scrobbles {
            let key = scrobbleKey(uts: fetched.uts, artist: fetched.artist, track: fetched.track)
            if let row = byKey[key] {
                let albumChanged = row.albumName != fetched.album
                if albumChanged {
                    row.albumName = fetched.album
                }

                // Last.fm artwork URLs can vary between otherwise identical
                // responses. Artwork is resolved and refreshed independently,
                // so sync only fills a missing raw URL instead of replacing a
                // usable value and reporting a phantom scrobble update.
                if row.imageURL == nil, let imageURL = fetched.imageURL {
                    row.imageURL = imageURL
                }

                if albumChanged {
                    if countChange(fetched) {
                        updated += 1
                    }
                }
                row.lastConfirmedAt = confirmedAt
            } else {
                let row = Scrobble(
                    artistName: fetched.artist, albumName: fetched.album, trackName: fetched.track,
                    imageURL: fetched.imageURL,
                    playedAt: Date(timeIntervalSince1970: TimeInterval(fetched.uts)),
                    lastConfirmedAt: confirmedAt
                )
                modelContext.insert(row)
                byKey[key] = row
                if countChange(fetched) {
                    added += 1
                }
            }
            try resolveEntities(for: fetched)
        }
        return (added, updated)
    }

    private func scrobbleKey(uts: Int, artist: String, track: String) -> String {
        "\(uts)\u{0}\(artist)\u{0}\(track)"
    }

    private func reconcileWindow(lowerUts: Int, upperUts: Int, runIdentity: Date) throws -> Int {
        let lower = Date(timeIntervalSince1970: TimeInterval(lowerUts))
        let upper = Date(timeIntervalSince1970: TimeInterval(upperUts))
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate { $0.playedAt >= lower && $0.playedAt <= upper && $0.lastConfirmedAt != runIdentity }
        )
        let stale = try modelContext.fetch(descriptor)
        for row in stale { modelContext.delete(row) }
        return stale.count
    }

    // MARK: - Entity resolution (Artist/Album/Track identity rows)

    /// Find-or-create only — deterministic per-string normalization
    /// (`TextNormalization`), no cross-entity fuzzy merging. Consolidating
    /// near-duplicate album variants (edition Levenshtein-similarity,
    /// various-artists compilation detection) is Top Charts/Album Turnover
    /// phase work, not sync's job.
    private func resolveEntities(for scrobble: FetchedScrobble) throws {
        let artist = try resolveArtist(named: scrobble.artist)
        if !scrobble.album.isEmpty {
            try resolveAlbum(title: scrobble.album, artist: artist)
        }
        try resolveTrack(title: scrobble.track, artistName: scrobble.artist, artist: artist)
    }

    private func resolveArtist(named raw: String) throws -> Artist {
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let cached = artistCache[normalized] { return cached }
        var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.normalizedName == normalized })
        descriptor.fetchLimit = 1
        if let found = try modelContext.fetch(descriptor).first {
            artistCache[normalized] = found
            return found
        }
        // First-seen casing wins and is kept stable — a simplification of a
        // play-count-weighted approach that would pick the majority casing
        // across the whole history. Revisit if casing
        // drift (e.g. `Beyoncé` vs `beyoncé`) turns out to matter in practice.
        let artist = Artist(normalizedName: normalized, name: raw)
        modelContext.insert(artist)
        artistCache[normalized] = artist
        return artist
    }

    private func resolveAlbum(title raw: String, artist: Artist) throws {
        let normalizedTitle = TextNormalization.normalizeAlbumName(raw)
        let identityKey = TextNormalization.albumIdentityKey(artist: artist.name, album: raw)
        if albumCache[identityKey] != nil { return }
        var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.identityKey == identityKey })
        descriptor.fetchLimit = 1
        if let found = try modelContext.fetch(descriptor).first {
            albumCache[identityKey] = found
            return
        }
        let album = Album(identityKey: identityKey, title: raw, normalizedTitle: normalizedTitle, artist: artist)
        modelContext.insert(album)
        albumCache[identityKey] = album
    }

    private func resolveTrack(title raw: String, artistName: String, artist: Artist) throws {
        let identityKey = TextNormalization.lovedKey(artist: artistName, track: raw)
        if trackCache[identityKey] != nil { return }
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == identityKey })
        descriptor.fetchLimit = 1
        if let found = try modelContext.fetch(descriptor).first {
            trackCache[identityKey] = found
            return
        }
        let normalizedTitle = TextNormalization.normalizeTrackTitle(raw)
        let track = Track(identityKey: identityKey, title: raw, normalizedTitle: normalizedTitle, artist: artist)
        modelContext.insert(track)
        trackCache[identityKey] = track
    }

    // MARK: - Helpers

    private func fetchOrCreateSyncState(username: String) throws -> SyncState {
        var descriptor = FetchDescriptor<SyncState>(predicate: #Predicate { $0.username == username })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }
        let state = SyncState(username: username)
        modelContext.insert(state)
        return state
    }

    private func maxExistingUts() throws -> Int {
        var descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let newest = try modelContext.fetch(descriptor).first else { return 0 }
        return Int(newest.playedAt.timeIntervalSince1970)
    }
}
