import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_CONSISTENCY_CHECK=1` (with `SCROBLYTICS_STORE_PATH` pointing at a COPY of the store): confirms that the
/// screens agree about an artist spelled two ways, and that a spelling flip after a sync does not fake a milestone.
/// `SCROBLYTICS_CONSISTENCY_ARTIST` names one spelling of such an artist.
enum ConsistencyChecks {
    static func runHeadlessIfRequested(container: ModelContainer) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SCROBLYTICS_CONSISTENCY_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
                print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail().isEmpty ? "" : " — " + detail())")
                if !ok { failures += 1 }
            }
            let context = container.mainContext
            let raw = try context.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
            let canonical = QueryIdentity.canonicalizingArtists(raw)
            let all = DateRange(from: .distantPast, to: Date())

            if let artist = environment["SCROBLYTICS_CONSISTENCY_ARTIST"] {
                let key = TextNormalization.artistIdentityKey(artist)
                let expected = raw.filter { TextNormalization.artistIdentityKey($0.artistName) == key }.count
                let spellings = Set(raw.filter { TextNormalization.artistIdentityKey($0.artistName) == key }.map(\.artistName))
                print("artist has \(spellings.count) spellings, \(expected) plays in total")
                check("the artist really has more than one spelling", spellings.count > 1)

                for spelling in spellings.sorted() {
                    let stats = try EntityStatsEngine.fetchArtistStats(context: context, artist: spelling, range: all)
                    check("artist detail page for “\(spelling)” counts every spelling (\(expected))", stats.plays == expected, "got \(stats.plays)")
                }
                let chart = try await TopChartsEngine.fetchRankings(context: context, entity: .artist, range: all, limit: 100_000, includePeak: false)
                let row = chart.first { TextNormalization.artistIdentityKey($0.name) == key }
                check("Top Charts shows the same number", row?.playcount == expected, "chart \(row?.playcount as Any)")

                let milestones = MilestonesEngine.fetch(scrobbles: canonical)
                let rows = (milestones.artists.upcoming.map { ($0.name, $0.current) } + milestones.artists.achieved.map { ($0.name, $0.current) })
                    .filter { TextNormalization.artistIdentityKey($0.0) == key }
                check("Milestones lists the artist once with the full count", rows.count <= 1 && (rows.isEmpty || rows[0].1 == expected), "\(rows)")
                let rawMilestones = MilestonesEngine.fetch(scrobbles: raw)
                let rawRows = (rawMilestones.artists.upcoming.map { ($0.name, $0.current) } + rawMilestones.artists.achieved.map { ($0.name, $0.current) })
                    .filter { TextNormalization.artistIdentityKey($0.0) == key }
                print("(before the fix Milestones saw: \(rawRows))")

                let canonicalArtists = Set(canonical.map(\.artistName)).count
                let rawArtists = Set(raw.map(\.artistName)).count
                print("distinct artists: raw \(rawArtists), canonical \(canonicalArtists)")
                check("canonical spelling removes the duplicate", canonicalArtists < rawArtists)

                // A track by that artist: the detail page counts the same as the library.
                if let sample = canonical.first(where: { TextNormalization.artistIdentityKey($0.artistName) == key }) {
                    let trackPlays = canonical.filter { TextNormalization.artistIdentityKey($0.artistName) == key && $0.trackName == sample.trackName }.count
                    let stats = try EntityStatsEngine.fetchTrackStats(context: context, artist: sample.artistName, track: sample.trackName, range: all)
                    check("track detail page counts every spelling (\(trackPlays))", stats.plays == trackPlays, "got \(stats.plays)")
                }
            }

            // Tracks tile: loved tracks among those played in a range (printed, then recomputed independently from SQLite).
            let lovedSet = Set(try context.fetch(FetchDescriptor<LovedTrackEntry>()).map(\.cacheKey))
            let year = DateRange(from: Date().addingTimeInterval(-365 * 86400), to: Date())
            for (label, range) in [("all", all), ("365", year)] {
                let totals = OverviewTotalsEngine.fetch(scrobbles: canonical, range: range, compareRange: nil, lovedSet: lovedSet)
                print("TILE \(label) tracks=\(totals.tracks) lovedInRange=\(totals.trackKeys.intersection(lovedSet).count)")
            }

            // The Climbing template selects the same tracks as the Climb engine (the Overview card's source).
            do {
                let now = Date()
                let engineRows = TheClimbEngine.compute(scrobbles: canonical, compareDays: 90, minPlaysNow: 5, topN: 500, now: now)?.rows ?? []
                var spec = TheClimbEngine.spec(compareDays: 90, minPlaysNow: 5, topN: 500)
                spec.limit = nil
                let validated = try spec.validate(against: .standard)
                let run = QueryRun(target: .track, asOf: now, scrobbles: canonical, allTimeScrobbles: canonical)
                let queryIDs = Set(QueryEngine.evaluate(validated, run: run).rows.map(\.entity.id))
                let engineIDs = Set(engineRows.map(\.id))
                print("CLIMB engine \(engineIDs.count) tracks, template \(queryIDs.count) tracks")
                check("the Climbing template selects exactly the Climb engine’s tracks", queryIDs == engineIDs, "only template: \(queryIDs.subtracting(engineIDs).count), only engine: \(engineIDs.subtracting(queryIDs).count)")
            }

            // Error text: every case reads as a sentence, never as a Swift enum dump.
            let samples: [Error] = [
                LastfmAPIError.api(code: 10, message: "Invalid API key"), LastfmAPIError.api(code: 29, message: "Rate limit"),
                LastfmAPIError.api(code: 6, message: "User not found"), LastfmAPIError.api(code: 17, message: "Login required"),
                LastfmAPIError.http(502), LastfmAPIError.network(URLError(.notConnectedToInternet)), LastfmAPIError.invalidResponse,
                LastfmAPIError.malformedField("totalPages"), SyncError.pageCapExceeded, SyncError.notConfigured,
                LastfmCredentialsStore.KeychainError.write(-25299), LovedTracksEngine.LovedTracksError.notConnected, CancellationError(),
            ]
            for sample in samples {
                let text = describeSyncError(sample)
                print("ERROR TEXT: \(text)")
                check("error text for \(sample) is plain words", !text.contains("api(code") && !text.contains("LastfmAPIError") && !text.isEmpty)
            }

            // Library Gaps: saved statuses for tracks that no longer have scrobbles are found and removed (on the COPY).
            do {
                let store = LibraryPresenceStore(modelContainer: container)
                let existing = try await store.records()
                let usage = try await LibraryGapsRunner.scrobbledUsage(container: container)
                let orphans = LibraryGapsEngine.orphanKeys(existing: existing, usage: usage)
                let liveKeys = Set(usage.map(\.matchKey))
                print("LIBGAPS saved=\(existing.count) tracked=\(usage.count) orphans=\(orphans.count)")
                check("every saved status is either live or reported as an orphan", existing.keys.allSatisfy { liveKeys.contains($0) != orphans.contains($0) })
                check("saved statuses minus orphans equals the scrobbled tracks that have one", existing.count - orphans.count == existing.keys.filter { liveKeys.contains($0) }.count)
                let checkedAt = (try await store.lastCheck())?.checkedAt ?? Date()
                try await store.apply(changed: [], removing: orphans, checkedAt: checkedAt, libraryTrackCount: 0, trackedCount: usage.count)
                let after = try await store.records()
                check("applying the removal deletes exactly the orphans", after.count == existing.count - orphans.count && orphans.allSatisfy { after[$0] == nil })
                check("no orphan remains afterwards", LibraryGapsEngine.orphanKeys(existing: after, usage: usage).isEmpty)
            }

            // Sync events: a spelling flip must not fake a milestone.
            func play(_ artist: String, _ i: Int) -> ScrobbleSnapshot {
                ScrobbleSnapshot(artistName: artist, albumName: "", trackName: "t\(i % 7)", imageURL: nil, playedAt: Date(timeIntervalSince1970: Double(i) * 60))
            }
            let before = (0..<76).map { play("Artist A", $0) } + (76..<150).map { play("artist a", $0) }          // 150 merged; "Artist A" leads
            let after = before + (150..<152).map { play("artist a", $0) }                                           // "artist a" now leads
            let flipped = SyncEventsEngine.findNewMilestones(
                before: SyncEventsEngine.countEntities(QueryIdentity.canonicalizingArtists(before)),
                after: SyncEventsEngine.countEntities(QueryIdentity.canonicalizingArtists(after))
            )
            check("a spelling flip after a sync fakes no artist milestone", !flipped.contains { $0.kind == .artist }, "\(flipped)")
            let crossing = SyncEventsEngine.findNewMilestones(
                before: SyncEventsEngine.countEntities(QueryIdentity.canonicalizingArtists((0..<99).map { play($0 < 50 ? "Artist A" : "artist a", $0) })),
                after: SyncEventsEngine.countEntities(QueryIdentity.canonicalizingArtists((0..<100).map { play($0 < 50 ? "Artist A" : "artist a", $0) }))
            )
            check("a real crossing (99 → 100 plays across two spellings) is reported once", crossing.filter { $0.kind == .artist }.count == 1, "\(crossing)")

            print(failures == 0 ? "ALL CONSISTENCY CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
