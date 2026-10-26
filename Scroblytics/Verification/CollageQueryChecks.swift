#if DEBUG
import Foundation
import SwiftData

/// `SCROBLYTICS_COLLAGEQUERY_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the collage made from a Query's results: which rows
/// become tiles, in what order, what each tile says, and the grid chosen for them. Made-up plays with hand-worked answers, and, when the
/// store has a library, an independent recount of the top albums.
enum CollageQueryChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_COLLAGEQUERY_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let registry = QueryFieldRegistry.standard
            let calendar = AppCalendars.listening
            let start = calendar.date(from: DateComponents(year: 2025, month: 3, day: 3, hour: 9))!
            // Artist A: Song 1 ×4 (Album X), Song 2 ×1 (Album X); Artist B: Song 3 ×2 (Album Y); Artist C: Song 4 ×1 (no album).
            func play(_ artist: String, _ track: String, _ album: String, _ minutes: Int) -> ScrobbleSnapshot {
                ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: nil, playedAt: start.addingTimeInterval(Double(minutes) * 3600))
            }
            let plays = [
                play("Artist A", "Song 1", "Album X", 0), play("Artist A", "Song 1", "Album X", 1), play("Artist A", "Song 2", "Album X", 2),
                play("Artist B", "Song 3", "Album Y", 3), play("Artist A", "Song 1", "Album X", 4), play("Artist B", "Song 3", "Album Y", 5),
                play("Artist A", "Song 1", "Album X", 6), play("Artist C", "Song 4", "", 7),
            ]
            func results(_ spec: QuerySpec, over source: [ScrobbleSnapshot]) throws -> (QueryResult, [QueryDisplayRow]) {
                let validated = try spec.validate(against: registry)
                let run = QueryRun(target: spec.target, asOf: Date(), scrobbles: spec.countedPlays(source), allTimeScrobbles: source)
                let result = QueryEngine.evaluate(validated, run: run)
                return (result, QueryDisplayRow.make(from: result, imageLookup: [:]))
            }
            @MainActor func payload(_ spec: QuerySpec, over source: [ScrobbleSnapshot], title: String = "Test") -> CollageQueryPayload? {
                guard let (result, rows) = try? results(spec, over: source) else { return nil }
                return CollageQuerySource.payload(
                    title: title, target: spec.target, rows: rows, columns: result.columns,
                    sortedColumn: ShareCards.sortedColumnIndex(columns: result.columns, sorts: spec.sorts, target: spec.target, registry: registry), entityInfo: result.entityInfo
                )
            }
            func spec(_ target: QueryTarget, sort: String = "plays", columns: [String] = ["plays", "lastPlayed"]) -> QuerySpec {
                var s = QuerySpec(target: target)
                s.columns = columns.map { QueryFieldRef($0) }
                s.sorts = [QuerySort(key: .field(QueryFieldRef(sort)), direction: .descending)]
                return s
            }

            // Which kinds, and the grid.
            check("a collage is offered for artists, albums and tracks, and not for plays or sessions", CollageQuerySource.entity(for: .artist) == .artist && CollageQuerySource.entity(for: .album) == .album && CollageQuerySource.entity(for: .track) == .track && CollageQuerySource.entity(for: .scrobble) == nil && CollageQuerySource.entity(for: .session) == nil)
            check("the grid is the smallest square that holds the rows", [1, 9, 10, 25, 26, 49, 50, 100, 101, 500].map { CollageQuerySource.suggestedGrid(count: $0) } == [.three, .three, .five, .five, .seven, .seven, .ten, .ten, .twelve, .twelve])

            // Albums, most played first.
            let albums = payload(spec(.album), over: plays)
            check("albums become tiles in the order the query put them", albums?.items.map(\.name) == ["Album X", "Album Y"] && albums?.entity == .album, "\(String(describing: albums?.items.map(\.name)))")
            check("each tile says the value of the column the results are sorted by", albums?.items.map(\.valueText) == ["5", "2"] && albums?.valueLabel == "Plays", "\(String(describing: albums?.items.map(\.valueText)))")
            check("an album tile names its artist and itself as the album", albums?.items.first.map { $0.artist == "Artist A" && $0.album == "Album X" } == true)
            check("the caption says what the query was and which column is shown", albums?.caption.text(date: start) == "Test · From Query · Showing Plays · \(start.formatted(date: .abbreviated, time: .omitted))", "\(String(describing: albums?.caption.text(date: start)))")

            // Tracks and artists.
            let tracks = payload(spec(.track), over: plays)
            check("tracks become tiles with the track's album, and the plays of each", tracks?.items.map(\.name) == ["Song 1", "Song 3", "Song 2", "Song 4"] && tracks?.items.map(\.valueText) == ["4", "2", "1", "1"] && tracks?.items.first?.album == "Album X", "\(String(describing: tracks?.items.map { "\($0.name)/\($0.valueText ?? "-")" }))")
            check("a track with no album has none on its tile", tracks?.items.last.map { $0.name == "Song 4" && $0.album == nil } == true)
            let artists = payload(spec(.artist), over: plays)
            check("artists become tiles named for themselves", artists?.items.map(\.name) == ["Artist A", "Artist B", "Artist C"] && artists?.items.allSatisfy { $0.artist == $0.name && $0.album == nil } == true && artists?.entity == .artist)
            check("every tile has an id of its own, so its picture is its own", Set(tracks?.items.map(\.id) ?? []).count == tracks?.items.count)

            // A different sort column, a column of another kind, and none at all.
            let byLast = payload(spec(.album, sort: "lastPlayed"), over: plays)
            check("sorted by last played, the tiles show that date", byLast?.items.first?.valueText?.isEmpty == false && byLast?.valueLabel == "Last played", "\(String(describing: byLast?.items.first?.valueText))")
            var noColumns = spec(.album)
            noColumns.columns = []
            let bare = payload(noColumns, over: plays)
            check("a query with no column to show makes tiles with no value", bare?.items.count == 2 && bare?.items.allSatisfy { $0.valueText == nil } == true && bare?.valueLabel == nil)
            check("nothing to show makes no collage, and neither do plays or sessions", payload(spec(.track), over: []) == nil && payload(spec(.scrobble, sort: "playedAt", columns: ["playedAt"]), over: plays) == nil)

            // Broken down by year: each row says its year.
            var yearly = spec(.artist)
            yearly.breakdown = QueryBreakdown()
            yearly.limit = 1
            let years = payload(yearly, over: plays)
            check("a query broken down by year makes tiles that carry their year, which the tile's period label shows", years?.hasPeriodLabels == true && years?.items.first?.periodLabel == "2025", "\(String(describing: years?.items.map(\.periodLabel)))")

            // More rows than the largest grid holds.
            let many = (0..<200).map { play("Artist \($0)", "Song", "Album \($0)", $0) }
            let big = payload(spec(.artist), over: many)
            check("rows beyond the largest grid are left out, and the collage says how many there were", big?.items.count == CollageQuerySource.maxItems && big?.totalRows == 200 && CollageQuerySource.maxItems == 144)

            // The hand-off is taken once.
            let handoff = CollageHandoff()
            handoff.offer(albums!)
            check("a hand-off is picked up once", handoff.pending?.id == albums?.id && handoff.take()?.id == albums?.id && handoff.take() == nil && handoff.pending == nil)

            // A copy of a real library: the top albums against an independent recount.
            let history = (try? await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)) ?? []
            if history.count > 1000 {
                var top = spec(.album)
                top.limit = 25
                let real = payload(top, over: history, title: "Top albums")
                var counts: [String: Int] = [:]
                for p in history where !p.albumName.isEmpty { counts[p.artistName + "\u{0}" + p.albumName, default: 0] += 1 }
                let wanted = counts.values.sorted(by: >).prefix(25).map { String($0) }
                let shown = real?.items.compactMap(\.valueText) ?? []
                check("real library: a 25-tile collage of the top albums has the 25 highest play counts, most first", shown.map { Int($0.replacingOccurrences(of: ",", with: "")) ?? -1 } == wanted.map { Int($0)! } && real?.items.count == 25, "\(shown.prefix(5)) vs \(wanted.prefix(5))")
                check("real library: each tile's number is that album's own count", real?.items.allSatisfy { item in
                    let counted = counts[item.artist + "\u{0}" + (item.album ?? item.name)]
                    return counted.map { String($0) } == item.valueText?.replacingOccurrences(of: ",", with: "")
                } == true)
                check("real library: that many rows fill a 5 × 5 grid", real.map { CollageQuerySource.suggestedGrid(count: $0.items.count) } == .five)
            } else {
                print("      (no library copy here: the real-data cross-check was skipped)")
            }

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
