import Foundation
import SwiftData
import SwiftUI

#if DEBUG
/// `SCROBLYTICS_DETAIL_DUMP=1` (with `SCROBLYTICS_STORE_PATH` on a COPY of a library and `SCROBLYTICS_OFFLINE=1`): runs the new Track
/// page's model on the library's most-played tracks, using only local reads, and compares what it loads with an independent count
/// of the plays. Exits 0 on success. No network, and nothing is written outside the copy.
enum DetailDump {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_DETAIL_DUMP"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let history = (try? await ScrobbleHistoryCache.shared.snapshots(container: container)) ?? []
            check("the copy has plays to read", !history.isEmpty, "\(history.count)")
            var counts: [String: (artist: String, track: String, count: Int)] = [:]
            for play in history where !play.trackName.isEmpty {
                let key = TextNormalization.artistIdentityKey(play.artistName) + "\u{0}" + play.trackName
                let current = counts[key] ?? (play.artistName, play.trackName, 0)
                counts[key] = (current.artist, current.track, current.count + 1)
            }
            let top = counts.values.sorted { $0.count > $1.count }.prefix(3)
            for entry in top {
                let identity = TrackIdentity(artist: entry.artist, name: entry.track)
                let model = TrackDetailModel()
                model.bind(identity: identity, context: container.mainContext)
                let all = DateRange(from: .distantPast, to: Date().addingTimeInterval(86400))
                let started = Date()
                model.loadOldestScrobbleDate()
                model.loadStats(range: all)
                model.loadScrobbleHistory(range: all)
                await model.loadYearlyTopRanks()
                let seconds = Date().timeIntervalSince(started)
                // The independent count: every play with this artist (spelling-merged) and this exact track title.
                let artistKey = TextNormalization.artistIdentityKey(entry.artist)
                let plays = history.filter { TextNormalization.artistIdentityKey($0.artistName) == artistKey && $0.trackName == entry.track }
                check("page plays equal an independent count (\(entry.count) plays)", model.stats?.plays == plays.count, "\(model.stats?.plays ?? -1) vs \(plays.count)")
                check("the play list has one row per play", model.scrobbleHistory.count == plays.count, "\(model.scrobbleHistory.count) vs \(plays.count)")
                check("first and last scrobble match", model.stats?.firstScrobble == plays.map(\.playedAt).min() && model.stats?.lastScrobble == plays.map(\.playedAt).max())
                let headline = DetailHeaderCard<EmptyView>.headline(stats: model.stats, metric: .scrobbles, timeListenedSeconds: nil)
                check("the headline tiles all have values", headline.count == 4 && headline.allSatisfy(\.hasValue), "\(headline.map(\.displayText))")
                print("      loaded in \(String(format: "%.2f", seconds)) s; ranks \(model.yearlyTopRanks.map { "#\($0.rank)·\($0.year)" }.joined(separator: " ")); headline \(headline.map(\.displayText).joined(separator: " | "))")
            }

            // MARK: Albums
            var albumCounts: [String: (artist: String, album: String, count: Int)] = [:]
            for play in history where !play.albumName.isEmpty {
                let key = TextNormalization.artistIdentityKey(play.artistName) + "\u{0}" + TextNormalization.normalizeAlbumName(play.albumName)
                let current = albumCounts[key] ?? (play.artistName, play.albumName, 0)
                albumCounts[key] = (current.artist, current.album, current.count + 1)
            }
            for entry in albumCounts.values.sorted(by: { $0.count > $1.count }).prefix(3) {
                let model = AlbumDetailModel()
                model.clientProvider = { nil }
                model.bind(identity: AlbumIdentity(artist: entry.artist, name: entry.album), context: container.mainContext)
                let all = DateRange(from: .distantPast, to: Date().addingTimeInterval(86400))
                let started = Date()
                model.loadOldestScrobbleDate()
                await model.loadStats(range: all, rangeID: "all")
                await model.loadYearlyTopRanks()
                let seconds = Date().timeIntervalSince(started)
                let artistKey = TextNormalization.artistIdentityKey(entry.artist)
                let albumKey = TextNormalization.normalizeAlbumName(entry.album)
                let plays = history.filter { TextNormalization.artistIdentityKey($0.artistName) == artistKey && TextNormalization.normalizeAlbumName($0.albumName) == albumKey }
                check("album page plays equal an independent count (\(entry.count) plays)", model.stats?.plays == plays.count, "\(model.stats?.plays ?? -1) vs \(plays.count)")
                check("first and last scrobble of the album match", model.stats?.firstScrobble == plays.map(\.playedAt).min() && model.stats?.lastScrobble == plays.map(\.playedAt).max())
                check("with no account there are no turnover tiles, only the release date", model.facts(onEditReleaseDate: {}, onFixAlbumMatch: {}).map(\.label) == ["Released"])
                print("      loaded in \(String(format: "%.2f", seconds)) s; ranks \(model.yearlyTopRanks.map { "#\($0.rank)·\($0.year)" }.joined(separator: " "))")

                // The table: the period's played tracks joined with the album's cached tracklist (no network: Offline mode is on).
                let played = (try? await TopChartsEngine.fetchScopedRankings(
                    container: container, durationContext: container.mainContext, entity: .track, artist: entry.artist, album: entry.album,
                    range: all, compareRange: nil, metric: .scrobbles
                )) ?? []
                let client = LastfmAPIClient(apiKey: "offline", username: "offline")
                var listed: [AlbumTrackRows.ListedTrack]?
                if case .found(let found)? = try? await AlbumTurnoverEngine.getCachedTracklist(context: container.mainContext, client: client, artist: entry.artist, album: entry.album) {
                    listed = found.tracks.map { AlbumTrackRows.ListedTrack(title: $0, heardThisCycle: nil) }
                }
                let rows = AlbumTrackRows.merge(tracklist: listed, entries: played)
                let playedIDs = Set(played.map(\.id))
                let rowIDs = rows.compactMap { $0.entry?.id }
                check("table: every played track is in exactly one row", Set(rowIDs) == playedIDs && rowIDs.count == played.count, "\(rowIDs.count) rows vs \(played.count) tracks")
                check("table: the plays in the rows equal the plays in the period", rows.compactMap { $0.entry }.map { $0.playcount }.reduce(0, +) == played.map { $0.playcount }.reduce(0, +))
                if let listed {
                    check("table: one row per tracklist entry, then only unmatched plays", rows.filter { $0.kind == .listed }.count == listed.count && rows.prefix(listed.count).allSatisfy { $0.kind == .listed })
                    let matched = rows.filter { $0.kind == .listed && $0.entry != nil }.count
                    print("      tracklist of \(listed.count): \(matched) played in the period, \(listed.count - matched) not; \(rows.filter { $0.kind == .extra }.count) other tracks played")
                } else {
                    print("      no cached tracklist for this album: the table is the \(played.count) played tracks")
                }
            }


            // MARK: Artists
            var artistCounts: [String: (artist: String, count: Int)] = [:]
            for play in history {
                let key = TextNormalization.artistIdentityKey(play.artistName)
                let current = artistCounts[key] ?? (play.artistName, 0)
                artistCounts[key] = (current.artist, current.count + 1)
            }
            for entry in artistCounts.values.sorted(by: { $0.count > $1.count }).prefix(3) {
                let model = ArtistDetailModel()
                model.bind(identity: ArtistIdentity(name: entry.artist), context: container.mainContext)
                let all = DateRange(from: .distantPast, to: Date().addingTimeInterval(86400))
                let started = Date()
                model.loadOldestScrobbleDate()
                model.loadStats(range: all)
                await model.loadYearlyTopRanks()
                let seconds = Date().timeIntervalSince(started)
                let artistKey = TextNormalization.artistIdentityKey(entry.artist)
                let plays = history.filter { TextNormalization.artistIdentityKey($0.artistName) == artistKey }
                check("artist page plays equal an independent count (\(entry.count) plays)", model.stats?.plays == plays.count, "\(model.stats?.plays ?? -1) vs \(plays.count)")
                check("first and last scrobble of the artist match", model.stats?.firstScrobble == plays.map(\.playedAt).min() && model.stats?.lastScrobble == plays.map(\.playedAt).max())
                let headline = DetailHeaderCard<EmptyView>.headline(stats: model.stats, metric: .scrobbles, timeListenedSeconds: nil)
                check("the artist's four headline tiles have values", headline.count == 4 && headline.allSatisfy(\.hasValue))
                print("      loaded in \(String(format: "%.2f", seconds)) s; ranks \(model.yearlyTopRanks.map { "#\($0.rank)·\($0.year)" }.joined(separator: " "))")
            }


            // MARK: Where the album page spends its time (cache only: Offline mode is on)
            if let top = albumCounts.values.max(by: { $0.count < $1.count }) {
                let model = AlbumDetailModel()
                model.clientProvider = { LastfmAPIClient(apiKey: "offline", username: "offline") }
                model.bind(identity: AlbumIdentity(artist: top.artist, name: top.album), context: container.mainContext)
                let all = DateRange(from: .distantPast, to: Date().addingTimeInterval(86400))
                @MainActor func fetchTable() async {
                    _ = try? await TopChartsEngine.fetchScopedRankings(container: container, durationContext: container.mainContext, entity: .track, artist: top.artist, album: top.album, range: all, compareRange: nil, metric: .scrobbles)
                }
                @MainActor func timed(_ label: String, _ work: @MainActor () async -> Void) async {
                    let started = Date()
                    await work()
                    print("      TIMING \(label): \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
                }
                await timed("album stats") { await model.loadStats(range: all, rangeID: "all") }
                await timed("yearly ranks") { await model.loadYearlyTopRanks() }
                await timed("played tracks (the table's list)") { await fetchTable() }
                await timed("turnover (tracklist from cache)") { await model.loadTurnover() }
                await timed("joining a 70-track tracklist with 70 played tracks, 10 times") {
                    let titles = (0..<70).map { "Some Track Title \($0) (feat. Guest Artist) - 2011 Remaster" }
                    let listed = titles.map { AlbumTrackRows.ListedTrack(title: $0, heardThisCycle: true) }
                    let sample = (try? await TopChartsEngine.fetchScopedRankings(container: container, durationContext: container.mainContext, entity: .track, artist: top.artist, album: top.album, range: all, compareRange: nil, metric: .scrobbles)) ?? []
                    for _ in 0..<10 { _ = AlbumTrackRows.sorted(AlbumTrackRows.merge(tracklist: listed, entries: sample), by: .trackOrder, metric: .scrobbles) }
                }
                await timed("all of them at once") {
                    model.bind(identity: AlbumIdentity(artist: top.artist, name: top.album), context: container.mainContext)
                    let begun = Date()
                    @MainActor func done(_ label: String) { print("      TIMING   \(label) finished at \(String(format: "%.2f", Date().timeIntervalSince(begun))) s") }
                    let tasks = [
                        Task { @MainActor in await model.loadTurnover(); done("turnover") },
                        Task { @MainActor in await fetchTable(); done("table list") },
                        Task { @MainActor in await model.loadStats(range: all, rangeID: "all"); done("stats") },
                        Task { @MainActor in await model.loadYearlyTopRanks(); done("yearly ranks") },
                    ]
                    for task in tasks { await task.value }
                }
            }

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
