import Foundation
import SwiftData
import SwiftUI

#if DEBUG
/// `SCROBLYTICS_DETAIL_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the Artist, Album and Track detail pages. The
/// fact tiles and headline numbers, the album's turnover tiles, and the track table's join, filters, sorts, directions and length
/// keys, on made-up data with no network. Exits 0 on success.
enum DetailChecks {
    @MainActor
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_DETAIL_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }

            // MARK: Fact tiles and the headline numbers
            let loadingFact = DetailFact(id: "a", label: "Released", value: .loading)
            let unknownFact = DetailFact(id: "b", label: "Length", value: .unknown)
            let valueFact = DetailFact(id: "c", label: "Tempo", value: .text("118 BPM"))
            check("a tile says what state it is in", loadingFact.displayText == "Checking…" && unknownFact.displayText == "Unknown" && valueFact.displayText == "118 BPM")
            check("only a tile with a value counts as having one", !loadingFact.hasValue && !unknownFact.hasValue && valueFact.hasValue)
            let waiting = DetailHeaderCard<EmptyView>.headline(stats: nil, metric: .scrobbles, timeListenedSeconds: nil)
            check("while stats load the four headline tiles are already there, as dashes", waiting.count == 4 && waiting.allSatisfy { $0.displayText == "—" && !$0.hasValue })
            let stats = DetailSnapshots.sampleStats()
            let headline = DetailHeaderCard<EmptyView>.headline(stats: stats, metric: .scrobbles, timeListenedSeconds: nil)
            check("the headline tiles read plays, first, last and frequency", headline.map(\.label) == ["Scrobbles", "First scrobble", "Last scrobble", "Play frequency"] && headline[0].displayText == "142", "\(headline.map(\.displayText))")
            let byTime = DetailHeaderCard<EmptyView>.headline(stats: stats, metric: .timeListened, timeListenedSeconds: nil)
            check("by time listened, the first tile waits for the length instead of showing plays", byTime[0].label == "Time Listened" && !byTime[0].hasValue)
            let byTimeKnown = DetailHeaderCard<EmptyView>.headline(stats: stats, metric: .timeListened, timeListenedSeconds: 3600)
            check("and shows it once known", byTimeKnown[0].hasValue && byTimeKnown[0].displayText == DurationEngine.formatTimeListened(3600))
            check("play frequency reads in words", DetailHeaderCard<EmptyView>.playFrequency(nil) == "—" && DetailHeaderCard<EmptyView>.playFrequency(0.4) == "several a day" && DetailHeaderCard<EmptyView>.playFrequency(6.44) == "every 6.4 days" && DetailHeaderCard<EmptyView>.playFrequency(38.2) == "every 38 days")

            check("the countdown to the next milestone is labelled", DetailHeaderCard<EmptyView>.nextMilestoneText(remaining: 186, next: 500) == "Next milestone: 186 to 500")

            // MARK: The track page's own facts
            let model = TrackDetailModel()
            var edits = 0
            @MainActor func trackFacts() -> [DetailFact] { model.facts(onEditReleaseDate: { edits += 1 }, onEditDuration: { edits += 1 }, onEditTempo: { edits += 1 }) }
            model.isLoadingReleaseDate = true; model.isLoadingDuration = true; model.isLoadingBPM = true
            check("a track's facts are release date, length and tempo, each loading at first", trackFacts().map(\.label) == ["Released", "Length", "Tempo"] && trackFacts().allSatisfy { $0.value == .loading })
            model.isLoadingReleaseDate = false; model.isLoadingDuration = false; model.isLoadingBPM = false
            check("looked up and not found reads as unknown, never as loading", trackFacts().allSatisfy { $0.value == .unknown })
            model.releaseDate = "2018-09-12"; model.resolvedDuration = 224
            check("found values show", trackFacts()[0].hasValue && trackFacts()[1].displayText == DurationEngine.formatDuration(224), "\(trackFacts().map(\.displayText))")
            model.overrideSeconds = 230
            check("a corrected length is marked", trackFacts()[1].corrected && !trackFacts()[0].corrected)
            trackFacts().forEach { $0.onEdit?() }
            check("every track fact has an editor", edits == 3)


            // MARK: The album page's listen-through facts
            @MainActor func labels(_ state: AlbumTurnoverState) -> [String] { AlbumDetailModel.turnoverFacts(state, onFixAlbumMatch: {}).map(\.label) }
            check("no account or no match means no turnover tiles", labels(.unavailable).isEmpty)
            check("while turnover loads the four tiles are there, loading", AlbumDetailModel.turnoverFacts(.loading, onFixAlbumMatch: {}).count == 4 && AlbumDetailModel.turnoverFacts(.loading, onFixAlbumMatch: {}).allSatisfy { $0.value == .loading })
            let clean = AlbumDetailModel.turnoverFacts(.ready(DetailSnapshots.sampleTurnover()), onFixAlbumMatch: {})
            check("a matched album shows tracks, turnover, full cycles and this cycle", clean.map(\.label) == ["Tracks", "Turnover", "Full cycles", "This cycle"], "\(clean.map(\.label))")
            check("their values read plainly", clean[0].displayText == "11" && clean[1].displayText == AlbumTurnoverEngine.formatTurnoverRate(38) && clean[2].displayText == "7" && clean[3].displayText == "8 of 11", "\(clean.map(\.displayText))")
            check("a clean match asks for no attention", clean.allSatisfy { !$0.attention })
            check("the Turnover tile always carries the way to fix the match, as a pencil, and no other tile does", clean[1].onEdit != nil && clean[1].editImage == "pencil" && clean[1].editHelp == "Fix album match…" && clean.filter { $0.onEdit != nil }.count == 1)
            let uncertain = AlbumDetailModel.turnoverFacts(.ready(DetailSnapshots.sampleTurnover(ambiguous: true)), onFixAlbumMatch: { edits += 100 })
            check("an uncertain match says so, asks for a look, and its button is the fix, as a warning", uncertain[1].detail == "Uncertain match" && uncertain[1].attention && uncertain[1].editHelp == "Fix album match…" && uncertain[1].editImage == "exclamationmark.triangle.fill")
            uncertain[1].onEdit?()
            check("pressing it runs the fix", edits >= 100)
            let fresh = AlbumDetailModel.turnoverFacts(.ready(DetailSnapshots.sampleTurnover(cycles: 3, heard: 0)), onFixAlbumMatch: {})
            check("a cycle that just started says so", fresh[3].displayText == "0 of 11" && fresh[3].detail == "New cycle just starting")
            let firstCycle = AlbumDetailModel.turnoverFacts(.ready(DetailSnapshots.sampleTurnover(cycles: 0, heard: 0)), onFixAlbumMatch: {})
            check("the very first cycle is not 'just starting'", firstCycle[3].detail == nil && firstCycle[2].displayText == "0")
            let notApplicable = AlbumTurnoverEngine.AlbumTurnover(
                artist: "A", album: "B", applicable: false, basis: .observed, ambiguous: false, noCanonicalMatch: true, resolved: false, rateDays: nil,
                cyclesCompleted: 0, lastTurnoverDate: nil, trackCount: 0, observedDistinct: 4, inProgressHeard: 0, inProgressTotal: 0,
                inProgressMissing: [], tracks: [], isCompilation: true, groupKey: "k", imageURL: nil
            )
            check("an album with no listen-through (a compilation) shows no tiles", AlbumDetailModel.turnoverFacts(.ready(notApplicable), onFixAlbumMatch: {}).isEmpty)
            let observed = AlbumTurnoverEngine.AlbumTurnover(
                artist: "A", album: "B", applicable: true, basis: .observed, ambiguous: false, noCanonicalMatch: true, resolved: false, rateDays: nil,
                cyclesCompleted: 0, lastTurnoverDate: nil, trackCount: 6, observedDistinct: 6, inProgressHeard: 2, inProgressTotal: 6,
                inProgressMissing: [], tracks: [], isCompilation: false, groupKey: "k", imageURL: nil
            )
            let observedFacts = AlbumDetailModel.turnoverFacts(.ready(observed), onFixAlbumMatch: {})
            check("with no real tracklist there is no 'Tracks' tile, and the no-match note shows", !observedFacts.map(\.label).contains("Tracks") && observedFacts.first?.detail == "No match found" && observedFacts.first?.attention == true, "\(observedFacts.map(\.label))")
            check("rate text with no full cycle yet", observedFacts.first?.displayText == "No full cycle yet")


            // MARK: The album track table's join
            let now = Date()
            func entry(_ name: String, plays: Int, daysAgo: Double, release: String? = nil) -> TopChartEntry {
                TopChartEntry(
                    rank: 1, name: name, artist: "Artist A", album: "Album Name", playcount: plays, timeListenedSeconds: nil, imageURL: nil,
                    hasCompareRange: false, previousRank: nil, peakRank: 1, lastPlayedAt: now.addingTimeInterval(-daysAgo * 86400), loved: false,
                    releaseDateResolution: release.map { .date($0) } ?? .unknown
                )
            }
            let tracklist: [AlbumTrackRows.ListedTrack] = [
                .init(title: "Song One", heardThisCycle: true), .init(title: "Song Two", heardThisCycle: true),
                .init(title: "Song Three", heardThisCycle: false), .init(title: "Song Four", heardThisCycle: true),
                .init(title: "Song Five", heardThisCycle: false), .init(title: "Song Six", heardThisCycle: true),
            ]
            // Ranked order (most plays first). "Song Two - 2011 Remaster" is the same song under another title; "Bonus Track" is on no list.
            let played = [
                entry("Song One", plays: 50, daysAgo: 3), entry("Song Two - 2011 Remaster", plays: 30, daysAgo: 9),
                entry("Song Four", plays: 5, daysAgo: 40), entry("Bonus Track", plays: 4, daysAgo: 1), entry("Song Six", plays: 1, daysAgo: 200, release: "2018-09-12"),
            ]
            let merged = AlbumTrackRows.merge(tracklist: tracklist, entries: played)
            check("every track of the tracklist is a row, in order, then the unmatched plays", merged.map(\.title) == ["Song One", "Song Two", "Song Three", "Song Four", "Song Five", "Song Six", "Bonus Track"], "\(merged.map(\.title))")
            check("rows know their place on the tracklist", merged.prefix(6).map(\.position) == [1, 2, 3, 4, 5, 6] && merged[6].position == nil && merged[6].kind == .extra)
            check("a played track carries its plays", merged[0].entry?.playcount == 50 && merged[3].entry?.playcount == 5)
            check("a title under another name matches by its normalized title", merged[1].entry?.playcount == 30, "\(merged[1].entry?.name ?? "none")")
            check("a track with no plays in the period has no entry but is still a row", merged[2].entry == nil && merged[4].entry == nil && merged[2].kind == .listed)
            let marks: [Bool?] = merged.prefix(6).map { $0.heardThisCycle }
            let expectedMarks: [Bool?] = [true, true, false, true, false, true]
            check("cycle state comes from the tracklist", marks == expectedMarks && merged[6].heardThisCycle == nil)
            let mergedIDs: Set<UUID> = Set(merged.compactMap { $0.entry?.id })
            let playedIDs: Set<UUID> = Set(played.map { $0.id })
            check("plays are not lost: every played track appears exactly once", mergedIDs == playedIDs && merged.compactMap { $0.entry }.count == played.count)
            let mergedPlays: Int = merged.compactMap { $0.entry }.map { $0.playcount }.reduce(0, +)
            let periodPlays: Int = played.map { $0.playcount }.reduce(0, +)
            check("the plays across all rows equal the plays across the period", mergedPlays == periodPlays)
            let twice = AlbumTrackRows.merge(
                tracklist: [.init(title: "Reprise", heardThisCycle: true), .init(title: "Middle", heardThisCycle: true), .init(title: "Reprise", heardThisCycle: false)],
                entries: [entry("Reprise", plays: 9, daysAgo: 1), entry("Reprise (Remastered)", plays: 2, daysAgo: 2)]
            )
            check("a title that appears twice on the tracklist is paired in order", twice[0].entry?.playcount == 9 && twice[2].entry?.playcount == 2 && twice[1].entry == nil, "\(twice.map { $0.entry?.playcount ?? -1 })")
            // Titles made only of symbols, as on an album whose tracks are "/=/" and "/=/=/": each keeps its own key and its own plays.
            let symbolKeys = ["/=/", "/=/=/", " /=/ ", "Song One", "夜に駆ける", "群青"].map { TextNormalization.normalizeTrackTitle($0) }
            check("a title of only symbols keeps a key of its own, apart from a longer one and unaffected by spaces", !symbolKeys[0].isEmpty && symbolKeys[0] != symbolKeys[1] && symbolKeys[0] == symbolKeys[2], "\(symbolKeys)")
            check("titles in another alphabet are told apart too, and Latin titles are normalised as before", symbolKeys[4] != symbolKeys[5] && !symbolKeys[4].isEmpty && symbolKeys[3] == "song one" && TextNormalization.normalizeTrackTitle("Song One - 2011 Remaster") == "song one")
            let symbolList: [AlbumTrackRows.ListedTrack] = [.init(title: "/=/", heardThisCycle: true), .init(title: "Interlude", heardThisCycle: true), .init(title: "/=/=/", heardThisCycle: false)]
            let symbolRows = AlbumTrackRows.merge(tracklist: symbolList, entries: [entry("/=/=/", plays: 6, daysAgo: 1), entry("/=/", plays: 7, daysAgo: 2)])
            check("on an album with symbol-only tracks each row gets its own plays, whatever order they were ranked in", symbolRows[0].entry?.playcount == 7 && symbolRows[2].entry?.playcount == 6 && symbolRows[1].entry == nil && symbolRows.count == 3, "\(symbolRows.map { $0.entry?.playcount ?? -1 })")
            let symbolTitles = ["/=/", "Interlude", "/=/=/"]
            check("the turnover counts symbol-only tracks as heard: a full listen-through is a cycle, and they count towards coverage", AlbumTurnoverEngine.coverageOf(scrobbleTitles: symbolTitles, canonicalTitles: symbolTitles) == 1)
            let day = Date(timeIntervalSince1970: 1_700_000_000)
            let listenThrough = symbolTitles.enumerated().map { ScrobbleSnapshot(artistName: "Artist A", albumName: "Album", trackName: $0.element, imageURL: nil, playedAt: day.addingTimeInterval(Double($0.offset) * 240)) }
            let cycles = AlbumTurnoverEngine.computeCycles(scrobbles: listenThrough, canonicalTitles: symbolTitles)
            check("…and the turnover finds the cycle, ending with the last track", cycles.cycleDurationsDays.count == 1 && cycles.lastCycleEndDate == listenThrough.last?.playedAt, "\(cycles.cycleDurationsDays) \(String(describing: cycles.lastCycleEndDate))")
            let noList = AlbumTrackRows.merge(tracklist: nil, entries: played)
            check("with no tracklist the rows are exactly the played tracks, none marked as listed", noList.count == played.count && noList.allSatisfy { $0.kind == .extra && $0.position == nil && $0.heardThisCycle == nil })
            check("an empty tracklist is treated as none", AlbumTrackRows.merge(tracklist: [], entries: played).count == played.count)
            check("nothing played still lists the whole tracklist", AlbumTrackRows.merge(tracklist: tracklist, entries: []).count == 6 && AlbumTrackRows.merge(tracklist: tracklist, entries: []).allSatisfy { $0.entry == nil })
            check("no tracklist and nothing played is empty", AlbumTrackRows.merge(tracklist: nil, entries: []).isEmpty)

            // The filters.
            check("'all tracks' keeps every row", AlbumTrackRows.filtered(merged, by: .all).count == 7)
            check("'played in period' keeps the four that have plays plus the extra", AlbumTrackRows.filtered(merged, by: .playedInPeriod).map(\.title) == ["Song One", "Song Two", "Song Four", "Song Six", "Bonus Track"])
            check("'not heard this cycle' keeps exactly the unheard tracklist rows, and its count agrees", AlbumTrackRows.filtered(merged, by: .notHeardThisCycle).map(\.title) == ["Song Three", "Song Five"] && AlbumTrackRows.notHeardCount(merged) == 2)
            check("extras are never 'not heard'", !AlbumTrackRows.filtered(merged, by: .notHeardThisCycle).contains { $0.kind == .extra })

            // The orders.
            check("track order is the tracklist, extras last", AlbumTrackRows.sorted(merged.shuffled(), by: .trackOrder, metric: .scrobbles).map(\.title) == merged.map(\.title))
            check("most played puts the most plays first and the unplayed last, in tracklist order", AlbumTrackRows.sorted(merged, by: .mostPlayed, metric: .scrobbles).map(\.title) == ["Song One", "Song Two", "Song Four", "Bonus Track", "Song Six", "Song Three", "Song Five"], "\(AlbumTrackRows.sorted(merged, by: .mostPlayed, metric: .scrobbles).map(\.title))")
            check("A–Z is alphabetical over every row", AlbumTrackRows.sorted(merged, by: .alphabetical, metric: .scrobbles).map(\.title) == ["Bonus Track", "Song Five", "Song Four", "Song One", "Song Six", "Song Three", "Song Two"])
            check("recently played puts the newest play first and the unplayed last", AlbumTrackRows.sorted(merged, by: .recentlyPlayed, metric: .scrobbles).map(\.title) == ["Bonus Track", "Song One", "Song Two", "Song Four", "Song Six", "Song Three", "Song Five"])
            check("release year puts tracks with a year first, the rest in tracklist order", AlbumTrackRows.sorted(merged, by: .releaseYear, metric: .scrobbles).first?.title == "Song Six")
            check("sorting never drops or repeats a row", AlbumTrackSort.allCases.allSatisfy { Set(AlbumTrackRows.sorted(merged, by: $0, metric: .scrobbles).map(\.id)) == Set(merged.map(\.id)) && AlbumTrackRows.sorted(merged, by: $0, metric: .scrobbles).count == merged.count })


            // The sort directions.
            func titles(_ sort: AlbumTrackSort, _ ascending: Bool?, _ rows: [AlbumTrackRow]? = nil) -> [String] {
                AlbumTrackRows.sorted(rows ?? merged, by: sort, metric: .scrobbles, ascending: ascending).map(\.title)
            }
            check("each sort starts in its own direction: reading orders upward, plays and dates newest or most first", AlbumTrackSort.allCases.map(\.startsAscending) == [true, false, true, false, false], "\(AlbumTrackSort.allCases.map(\.startsAscending))")
            check("asking for no direction is the starting direction", AlbumTrackSort.allCases.allSatisfy { titles($0, nil) == titles($0, $0.startsAscending) })
            check("track order and A–Z reversed are exactly backwards", titles(.trackOrder, false) == titles(.trackOrder, true).reversed() && titles(.alphabetical, false) == titles(.alphabetical, true).reversed())
            check("track order reversed starts with the extras, then the last track", titles(.trackOrder, false).first == "Bonus Track" && titles(.trackOrder, false).last == "Song One")
            check("fewest played first puts the unplayed tracks first, then upward", titles(.mostPlayed, true) == ["Song Three", "Song Five", "Song Six", "Bonus Track", "Song Four", "Song Two", "Song One"], "\(titles(.mostPlayed, true))")
            check("oldest play first, with the tracks that have no play still last", titles(.recentlyPlayed, true) == ["Song Six", "Song Four", "Song Two", "Song One", "Bonus Track", "Song Three", "Song Five"], "\(titles(.recentlyPlayed, true))")
            check("release year in either direction keeps tracks with no year last", titles(.releaseYear, true).first == "Song Six" && titles(.releaseYear, false).first == "Song Six" && titles(.releaseYear, true).suffix(6).contains("Song Six") == false)
            check("every sort in either direction keeps every row once", AlbumTrackSort.allCases.allSatisfy { sort in [true, false].allSatisfy { Set(titles(sort, $0)).count == merged.count && titles(sort, $0).count == merged.count } })
            check("the direction button speaks each sort's own words", AlbumTrackSort.allCases.allSatisfy { $0.directionLabel(ascending: true) != $0.directionLabel(ascending: false) && !$0.directionLabel(ascending: true).isEmpty })
            check("the sub-list's sorts follow the same rules", SubListSort.allCases.allSatisfy { $0.startsAscending == (($0 == .alphabetical) || ($0 == .trackOrder)) } && SubListSort.mostPlayed.directionLabel(ascending: false) == "Most first" && SubListSort.releaseYear.directionLabel(ascending: true) == "Oldest first")

            // Where the tracklist comes from.
            check("no tracklist while turnover loads or is unavailable", AlbumTrackRows.tracklist(from: .loading) == nil && AlbumTrackRows.tracklist(from: .unavailable) == nil)
            check("no tracklist when the album is matched only by what was played", AlbumTrackRows.tracklist(from: .ready(DetailSnapshots.sampleObservedTurnover())) == nil)
            let withTracks = DetailSnapshots.sampleTurnover(tracks: [.init(title: "A", heardThisCycle: true), .init(title: "B", heardThisCycle: false)])
            check("a real tracklist is taken from the turnover result, with its cycle marks", AlbumTrackRows.tracklist(from: .ready(withTracks)) == [.init(title: "A", heardThisCycle: true), .init(title: "B", heardThisCycle: false)])


            // MARK: Every box the same height
            let plain = [DetailFact(id: "a", label: "A", value: .text("1")), DetailFact(id: "b", label: "B", value: .text("2"))]
            check("a card with no second lines keeps its tiles to two lines", !DetailFactGrid.reservesDetailLine(for: plain))
            check("a tile with a second line makes every tile on the card keep room for one", DetailFactGrid.reservesDetailLine(for: plain + [DetailFact(id: "c", label: "C", value: .text("3"), detail: "note")]))
            check("so does a kind of fact that sometimes has one, even before it has one", DetailFactGrid.reservesDetailLine(for: plain + [DetailFact(id: "c", label: "C", value: .loading, mayHaveDetail: true)]))
            let albumLoading = AlbumDetailModel.turnoverFacts(.loading, onFixAlbumMatch: {})
            let albumReady = AlbumDetailModel.turnoverFacts(.ready(DetailSnapshots.sampleTurnover()), onFixAlbumMatch: {})
            check("an album's tiles reserve the line while turnover loads and after, so nothing resizes when it arrives", DetailFactGrid.reservesDetailLine(for: albumLoading) && DetailFactGrid.reservesDetailLine(for: albumReady))
            model.resolvedBPM = nil
            check("a track's tempo tile reserves it too", DetailFactGrid.reservesDetailLine(for: trackFacts()))


            // MARK: The length column
            let playedRow = merged[0], unplayedRow = merged[2]
            check("a played track's length is looked up under its own artist and title", AlbumTrackDurations.key(for: playedRow, albumArtist: "Someone Else") == DurationEngine.cacheKey(artist: "Artist A", track: "Song One"))
            check("a track nobody played is looked up under the album's artist and the tracklist title", AlbumTrackDurations.key(for: unplayedRow, albumArtist: "Artist A") == DurationEngine.cacheKey(artist: "Artist A", track: "Song Three"))
            check("every row has its own key", Set(AlbumTrackDurations.keys(for: merged, albumArtist: "Artist A").keys).count == merged.count)
            check("a length reads as m:ss, h:mm:ss, or a dash when unknown", AlbumTrackDurations.text(seconds: 224) == "3:44" && AlbumTrackDurations.text(seconds: 3725) == "1:02:05" && AlbumTrackDurations.text(seconds: nil) == "—")


            // MARK: Opening a track that wasn't played in the period
            func snap(_ artist: String, _ album: String, _ track: String) -> ScrobbleSnapshot {
                ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: nil, playedAt: now)
            }
            var history: [ScrobbleSnapshot] = []
            history += (0..<5).map { _ in snap("Artist A", "Album Name", "Song Three - 2011 Remaster") }
            history += (0..<2).map { _ in snap("Artist A", "Album Name", "Song Three") }
            history += (0..<3).map { _ in snap("artist a", "Album Name (Deluxe Edition)", "Song Five") }
            history += (0..<9).map { _ in snap("Artist B", "Album Name", "Song Four") }
            history += (0..<9).map { _ in snap("Artist A", "A Different Album", "Song Four") }
            history += (0..<4).map { _ in snap("Artist A", "Album Name", "") }
            let names = AlbumTrackRows.playedNames(from: history, artist: "Artist A", album: "Album Name")
            check("the history's spelling of a title is found by its normalized title, taking the most played spelling", names["song three"] == PlayedName(artist: "Artist A", name: "Song Three - 2011 Remaster"), "\(names)")
            check("an artist's capitalization and an album's edition suffix don't hide a track", names["song five"]?.name == "Song Five")
            check("another artist's or another album's plays, and plays with no title, are left out", names["song four"] == nil && names.count == 2, "\(names.keys.sorted())")
            // Two spellings of one title (the second is the same song with a remaster suffix), played equally often, in either order.
            let plainFirst = AlbumTrackRows.playedNames(from: [snap("Artist A", "Album Name", "Same Song"), snap("Artist A", "Album Name", "Same Song - 2011 Remaster")], artist: "Artist A", album: "Album Name")
            let remasterFirst = AlbumTrackRows.playedNames(from: [snap("Artist A", "Album Name", "Same Song - 2011 Remaster"), snap("Artist A", "Album Name", "Same Song")], artist: "Artist A", album: "Album Name")
            check("a tie between two spellings always goes the same way, whichever was played first", plainFirst.count == 1 && plainFirst == remasterFirst && plainFirst.values.first?.name == "Same Song", "\(plainFirst) \(remasterFirst)")
            check("no history means no names", AlbumTrackRows.playedNames(from: [], artist: "Artist A", album: "Album Name").isEmpty)
            let notPlayed = merged[2]   // "Song Three": nothing in the period
            check("a track played in another period opens under how it was played", AlbumTrackRows.identity(for: notPlayed, albumArtist: "Artist A", playedNames: names) == PlayedName(artist: "Artist A", name: "Song Three - 2011 Remaster"))
            check("a track nobody played opens under the tracklist's title and the album's artist", AlbumTrackRows.identity(for: merged[4], albumArtist: "Artist A", playedNames: [:]) == PlayedName(artist: "Artist A", name: "Song Five"))
            check("a track played in the period opens under its own names", AlbumTrackRows.identity(for: merged[0], albumArtist: "Someone Else", playedNames: names) == PlayedName(artist: "Artist A", name: "Song One"))
            check("its length is looked up under the same names", AlbumTrackDurations.key(for: notPlayed, albumArtist: "Artist A", playedNames: names) == DurationEngine.cacheKey(artist: "Artist A", track: "Song Three - 2011 Remaster"))


            // MARK: A flag is drawn once
            // TrackLovedIndicator already draws a track's flag (with its heart and library mark); a row that also draws
            // TrackFlaggedIndicator shows the flag twice. Read the app's own sources for rows that do both.
            let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            var doubled: [String] = []
            var scanned = 0
            let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            do {
                for file in files where file.pathExtension == "swift" && !file.path.contains("/Verification/") {
                    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    scanned += 1
                    let lines = text.components(separatedBy: "\n")
                    for (index, line) in lines.enumerated() where line.contains("TrackFlaggedIndicator(") && !line.contains("struct ") {
                        let near = lines[max(0, index - 14)...min(lines.count - 1, index + 14)]
                        if near.contains(where: { $0.contains("TrackLovedIndicator(") && !$0.contains("struct ") }) {
                            doubled.append("\(file.lastPathComponent):\(index + 1)")
                        }
                    }
                }
            }
            check("no row draws a flag twice (a flag indicator beside the loved indicator); \(scanned) source files read", scanned > 50 && doubled.isEmpty, doubled.joined(separator: ", "))

            // MARK: The tile grid's columns
            func columns(_ width: CGFloat, _ count: Int) -> Int { EvenGridLayout.columnCount(width: width, count: count, minimumWidth: 138, spacing: 10) }
            check("a wide window puts every tile in one row", columns(1200, 4) == 4 && columns(1200, 3) == 3 && columns(1200, 1) == 1)
            check("never more columns than tiles", columns(5000, 2) == 2)
            check("a narrow window falls to one column", columns(120, 4) == 1 && columns(100, 3) == 1)
            check("four tiles are two and two, not three and one", columns(560, 4) == 2 && columns(450, 4) == 2)
            check("five tiles in four columns become three and two", columns(640, 5) == 3)
            check("three tiles that fit two are two and one", columns(300, 3) == 2)

            // Reappearing pages keep what they have (a tab switched back to must not reload every page of its stack).
            var memo = DetailLoadMemo()
            let memoNow = Date()
            check("a page never loaded is not fresh", !memo.isFresh(for: "a", now: memoNow))
            memo.record("a", now: memoNow)
            check("a page just loaded is fresh for the same item", memo.isFresh(for: "a", now: memoNow.addingTimeInterval(30)))
            check("a different item is not fresh", !memo.isFresh(for: "b", now: memoNow.addingTimeInterval(30)))
            check("a page loaded long ago is not fresh", !memo.isFresh(for: "a", now: memoNow.addingTimeInterval(DetailLoadMemo.freshFor + 1)))
            memo.reset()
            check("a reset page loads again", !memo.isFresh(for: "a", now: memoNow))
            let memoModel = ArtistDetailModel()
            check("a new model has loaded nothing", !memoModel.isLoaded(for: "x"))
            memoModel.markLoaded("x")
            check("and remembers what it loaded", memoModel.isLoaded(for: "x") && !memoModel.isLoaded(for: "y"))
            // One header picture is resolved from a few rows, the same answer as the whole-library index.
            let container = try? ModelContainer(for: Schema([Artist.self, Album.self, Track.self, AlbumImageOverride.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            if let container {
                let context = ModelContext(container)
                let artist = Artist(normalizedName: "artist a", name: "Artist A")
                context.insert(artist)
                context.insert(Album(identityKey: TextNormalization.albumIdentityKey(artist: "Artist A", album: "Album"), title: "Album", normalizedTitle: TextNormalization.normalizeAlbumName("Album"), artist: artist))
                context.insert(Track(identityKey: TextNormalization.lovedKey(artist: "Artist A", track: "Song"), title: "Song", normalizedTitle: "song", artist: artist))
                try? context.save()
                let targets = [
                    ImageTarget(kind: .artist, artist: "Artist A", album: nil, track: nil), ImageTarget(kind: .artist, artist: " ARTIST a ", album: nil, track: nil),
                    ImageTarget(kind: .album, artist: "Artist A", album: "Album", track: nil), ImageTarget(kind: .album, artist: "Artist A", album: "Album (Deluxe Edition)", track: nil),
                    ImageTarget(kind: .track, artist: "Artist A", album: "Album", track: "Song"), ImageTarget(kind: .track, artist: "Nobody", album: nil, track: "Nothing"),
                ]
                let full = (try? ImageResolutionEngine.imageLookup(context: context)) ?? [:]
                for fallback in [nil, "https://example.invalid/a.jpg"] as [String?] {
                    let agree = targets.allSatisfy { target in
                        ImageResolutionEngine.effectiveImageURL(for: target, lookup: full, fallbackURL: fallback) == (try? ImageResolutionEngine.effectiveImageURL(for: target, context: context, fallbackURL: fallback))
                    }
                    check("a header picture resolved from its own rows matches the whole-library lookup (fallback \(fallback == nil ? "none" : "given"))", agree)
                }
            } else {
                check("an in-memory store opens for the picture lookup check", false)
            }

            // Back from a Query opened by a tool lands on that tool's page, not the Tools landing page.
            let tripsTool = ToolDescriptor.all.first { $0.id == .trips }!
            let nav = DetailNavigationCoordinator(origin: .tools)
            nav.path.append(tripsTool)
            nav.setOrigin(.tools, label: tripsTool.name)
            var returned = 0
            nav.predecessor = DetailPredecessor(source: "Tools", detail: "Scrobbles · in Place", onReturn: { returned += 1 })
            nav.rememberToolPage()
            nav.path.append(ToolDescriptor.query)
            nav.path.append(ArtistIdentity(name: "Artist A"))
            nav.returnToPredecessor()
            check("back from a tool's Query keeps that tool open", nav.path.count == 1 && returned == 1 && nav.originTitle == "Trips" && nav.predecessor == nil, "depth \(nav.path.count)")
            let fromTrends = DetailNavigationCoordinator(origin: .tools)
            fromTrends.path.append(tripsTool)
            fromTrends.predecessor = DetailPredecessor(source: "Trends", detail: "x", onReturn: {})
            fromTrends.rememberToolPage()
            fromTrends.path.append(ToolDescriptor.query)
            fromTrends.returnToPredecessor()
            check("back from a Query opened by another tab still clears the stack", fromTrends.path.isEmpty)
            let landing = DetailNavigationCoordinator(origin: .tools)
            landing.predecessor = DetailPredecessor(source: "Tools", detail: "x", onReturn: {})
            landing.rememberToolPage()
            landing.path.append(ToolDescriptor.query)
            landing.returnToPredecessor()
            check("a Query opened from the Tools page itself returns to the Tools page", landing.path.isEmpty)

            // A page opened over the Query page (the Collage Generator from its results) returns to it with its navigation as it was.
            let collage = ToolDescriptor.all.first { $0.id == .collageGenerator }!
            let overQuery = DetailNavigationCoordinator(origin: .tools)
            overQuery.path.append(ToolDescriptor.query)
            overQuery.setOrigin(.query)
            overQuery.pushOverQuery(collage)
            check("a page opened over the query says so, and the query is under it", overQuery.isOverQuery && overQuery.path.count == 2)
            overQuery.setOrigin(.tools, label: "Collage Generator")
            overQuery.returnToQuery()
            check("returning puts the query on top again, with its own origin and Back as before", overQuery.path.count == 1 && !overQuery.isOverQuery && overQuery.origin == .query && overQuery.originLabel == nil, "\(overQuery.path.count) \(overQuery.origin) \(String(describing: overQuery.originLabel))")
            overQuery.pushOverQuery(collage)
            overQuery.setOrigin(.tools, label: "Collage Generator")
            overQuery.path.removeLast()
            overQuery.restoreQueryOriginIfPopped()
            check("closing the page by the system Back puts the query's origin back too", !overQuery.isOverQuery && overQuery.origin == .query && overQuery.originLabel == nil)
            overQuery.pushOverQuery(collage)
            overQuery.setOrigin(.tools, label: "Collage Generator")
            overQuery.path.append(ArtistIdentity(name: "Artist A"))
            overQuery.restoreQueryOriginIfPopped()
            check("opening an artist from the collage keeps the collage as the origin until it is closed", overQuery.isOverQuery && overQuery.originLabel == "Collage Generator" && overQuery.path.count == 3)

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
