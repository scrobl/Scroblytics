import Foundation

/// Decides whether a loved-tracks sync can be satisfied from page 1 alone.
///
/// `user.getLovedTracks` is newest-first and reports `@attr.total`, so additions are cheap to detect — but
/// removals are not reported, only visible as a count change. The fast path is therefore taken only when it is
/// PROVABLY equivalent to a full walk: the tracks on page 1 we haven't seen account for exactly the difference
/// between Last.fm's total and our count. A removal (total drops), a removal paired with an addition (the count
/// is off by one), or a love that isn't on page 1 (total exceeds what page 1 explains) all break that equation
/// and fall back to the full re-page. A page with no already-known track on it (a full page of new loves) also
/// falls back, since older new loves might lie beyond it.
///
/// What the count can't see: local drifting from Last.fm in a way that keeps the totals equal (a love we're
/// missing paired with a removal we missed). New loves always land on page 1, so this shouldn't arise from
/// normal use, but as a backstop a full walk is forced once a week (`fullWalkIsRecent`).
enum LovedSyncPlan {
    private static let lastFullWalkKey = "lovedTracksLastFullWalk"
    static let fullWalkInterval: TimeInterval = 7 * 24 * 3600

    /// True if a complete walk happened within the last week — the only time the fast path is allowed.
    static func fullWalkIsRecent(now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        guard let last = defaults.object(forKey: lastFullWalkKey) as? Date else { return false }
        return now.timeIntervalSince(last) < fullWalkInterval && last <= now
    }

    private static let datesBackfilledKey = "lovedTracksDatesBackfilled"
    /// Set once a complete walk has given every love its date. Until then a sync that finds loves without one does a full walk
    /// instead of the quick path; after it, a love Last.fm gave no date for no longer forces walks.
    static var datesBackfilled: Bool {
        get { UserDefaults.standard.bool(forKey: datesBackfilledKey) }
        set { UserDefaults.standard.set(newValue, forKey: datesBackfilledKey) }
    }
    static var datesNeedBackfill: Bool { !datesBackfilled }

    static func recordFullWalk(now: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: lastFullWalkKey)
    }

    enum Plan: Equatable {
        case additions([(artist: String, track: String)])
        case fullWalk

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            switch (lhs, rhs) {
            case (.fullWalk, .fullWalk): true
            case (.additions(let a), .additions(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.artist == $1.artist && $0.track == $1.track }
            default: false
            }
        }
    }

    static func plan(
        firstPage: [(artist: String, track: String)], total: Int?, pageSize: Int,
        localKeys: Set<String>, localCount: Int
    ) -> Plan {
        guard let total, localCount == localKeys.count else { return .fullWalk }
        var seen = Set<String>()
        var added: [(artist: String, track: String)] = []
        var knownOnPage = 0
        for track in firstPage {
            let key = TextNormalization.lovedKey(artist: track.artist, track: track.track)
            guard seen.insert(key).inserted else { continue }
            if localKeys.contains(key) { knownOnPage += 1 } else { added.append(track) }
        }
        // Everything fits on one page only when the account has at most a page of loves; otherwise require a
        // known track on the page so every new love is provably within it.
        let wholeListOnPage = total <= pageSize && firstPage.count == total
        guard wholeListOnPage || added.isEmpty || knownOnPage > 0 else { return .fullWalk }
        return localCount + added.count == total ? .additions(added) : .fullWalk
    }
}

#if DEBUG
import SwiftData

/// Verification hook: `SCROBLYTICS_LOVEDSYNC_CHECK=/path/out.txt` (with SCROBLYTICS_STORE_PATH pointing at a COPY of
/// the store) checks the fast path against the real account — the plan for each synthetic change, then a real
/// `syncLovedTracks` after deleting the newest local loves, compared with an independent full walk.
enum LovedSyncDebugCheck {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_LOVEDSYNC_CHECK"] else { return }
        Task { @MainActor in
            var out: [String] = []
            defer { try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8); exit(0) }
            // The checks below touch the real defaults key; leave it as found (unset) so the real app still walks first.
            let priorWalk = UserDefaults.standard.object(forKey: "lovedTracksLastFullWalk")
            defer {
                if let priorWalk { UserDefaults.standard.set(priorWalk, forKey: "lovedTracksLastFullWalk") } else { UserDefaults.standard.removeObject(forKey: "lovedTracksLastFullWalk") }
            }
            guard let credentials = LastfmCredentialsStore.load() else { out.append("ERROR: no credentials"); return }
            let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
            let context = container.mainContext
            do {
                let first = try await client.fetchLovedTracksPage(page: 1)
                let local = try context.fetch(FetchDescriptor<LovedTrackEntry>())
                let keys = Set(local.map(\.cacheKey))
                out.append("page1 tracks=\(first.tracks.count) totalPages=\(first.totalPages) total=\(first.total.map(String.init) ?? "nil") local=\(local.count) distinctKeys=\(keys.count)")
                func key(_ t: (artist: String, track: String)) -> String { TextNormalization.lovedKey(artist: t.artist, track: t.track) }
                func describe(_ p: LovedSyncPlan.Plan) -> String {
                    if case .additions(let a) = p { return "additions(\(a.count))" }
                    return "fullWalk"
                }
                func plan(_ k: Set<String>) -> String {
                    describe(LovedSyncPlan.plan(firstPage: first.tracks, total: first.total, pageSize: LastfmAPIClient.pageSize, localKeys: k, localCount: k.count))
                }
                out.append("A in sync as-is:                     \(plan(keys))")
                out.append("B newest love missing locally:       \(plan(keys.subtracting([key(first.tracks[0])])))")
                out.append("C newest 3 missing locally:          \(plan(keys.subtracting(first.tracks.prefix(3).map(key))))")
                out.append("D unlove (extra local key):          \(plan(keys.union(["zz|unloved"])))")
                out.append("E swap (newest missing + extra):     \(plan(keys.subtracting([key(first.tracks[0])]).union(["zz|unloved"])))")
                let onPage = Set(first.tracks.map(key))
                if let old = keys.subtracting(onPage).first {
                    out.append("F off-page love missing locally:     \(plan(keys.subtracting([old])))")
                    out.append("G off-page missing + newest missing: \(plan(keys.subtracting([old, key(first.tracks[0])])))")
                }

                // The fast path needs a recent full walk; none recorded yet → the first sync must walk.
                UserDefaults.standard.removeObject(forKey: "lovedTracksLastFullWalk")
                out.append("no recorded full walk -> fullWalkIsRecent=\(LovedSyncPlan.fullWalkIsRecent())")
                LovedSyncPlan.recordFullWalk()
                out.append("after recording -> fullWalkIsRecent=\(LovedSyncPlan.fullWalkIsRecent()); 8 days later -> \(LovedSyncPlan.fullWalkIsRecent(now: .now.addingTimeInterval(8 * 86400)))")

                // Real run: drop the newest 3 locally, sync, compare with an independent full walk.
                let newest = Set(first.tracks.prefix(3).map(key))
                for entry in local where newest.contains(entry.cacheKey) { context.delete(entry) }
                try context.save()
                let started = Date()
                let changed = await SyncEngine(modelContainer: container).syncLovedTracks(credentials: credentials)
                out.append("syncLovedTracks changed=\(changed) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                var walked = Set<String>()
                for page in 1...max(1, first.totalPages) {
                    walked.formUnion(try await client.fetchLovedTracksPage(page: page).tracks.map(key))
                }
                let after = Set(try context.fetch(FetchDescriptor<LovedTrackEntry>()).map(\.cacheKey))
                out.append("after sync: local=\(after.count) independentWalk=\(walked.count) identical=\(after == walked)")

                // Fallback, for real: a phantom local love (an unlove on Last.fm's side).
                context.insert(LovedTrackEntry(cacheKey: "phantom|unloved", artist: "Phantom", track: "Unloved"))
                try context.save()
                let started2 = Date()
                let changed2 = await SyncEngine(modelContainer: container).syncLovedTracks(credentials: credentials)
                let after2 = Set(try context.fetch(FetchDescriptor<LovedTrackEntry>()).map(\.cacheKey))
                out.append("fallback sync changed=\(changed2) in \(String(format: "%.2f", Date().timeIntervalSince(started2)))s: local=\(after2.count) identical=\(after2 == walked) phantomRemoved=\(!after2.contains("phantom|unloved"))")
            } catch {
                out.append("ERROR: \(error)")
            }
        }
    }
}
#endif

