import Foundation
import SwiftUI

#if DEBUG
/// `SCROBLYTICS_DETAIL_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the Artist, Album and Track detail pages' new
/// look. The switch between the classic and the new pages, and (as the pages are built) the album track table's join, on
/// made-up data with no network. Exits 0 on success.
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

            // MARK: The switch
            check("nothing stored means the classic pages", DetailPageStyle.resolve(stored: nil) == .classic)
            check("an unknown stored value means the classic pages", DetailPageStyle.resolve(stored: "sideways") == .classic && DetailPageStyle.resolve(stored: "") == .classic)
            check("'new' and 'classic' are read as stored", DetailPageStyle.resolve(stored: "new") == .new && DetailPageStyle.resolve(stored: "classic") == .classic)
            check("a test can force a style over what is stored", DetailPageStyle.resolve(stored: "classic", override: "new") == .new && DetailPageStyle.resolve(stored: "new", override: "classic") == .classic)
            check("a nonsense override is ignored", DetailPageStyle.resolve(stored: "new", override: "nope") == .new && DetailPageStyle.resolve(stored: nil, override: "nope") == .classic)
            check("both styles have a label for Settings", DetailPageStyle.allCases.count == 2 && DetailPageStyle.allCases.allSatisfy { !$0.label.isEmpty })


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
            check("a clean match asks for no attention and has no fix button", clean.allSatisfy { !$0.attention && $0.onEdit == nil })
            let uncertain = AlbumDetailModel.turnoverFacts(.ready(DetailSnapshots.sampleTurnover(ambiguous: true)), onFixAlbumMatch: { edits += 100 })
            check("an uncertain match says so, asks for a look, and its button is the fix", uncertain[1].detail == "Uncertain match" && uncertain[1].attention && uncertain[1].editHelp == "Fix album match…")
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

            // MARK: The tile grid's columns
            func columns(_ width: CGFloat, _ count: Int) -> Int { EvenGridLayout.columnCount(width: width, count: count, minimumWidth: 138, spacing: 10) }
            check("a wide window puts every tile in one row", columns(1200, 4) == 4 && columns(1200, 3) == 3 && columns(1200, 1) == 1)
            check("never more columns than tiles", columns(5000, 2) == 2)
            check("a narrow window falls to one column", columns(120, 4) == 1 && columns(100, 3) == 1)
            check("four tiles are two and two, not three and one", columns(560, 4) == 2 && columns(450, 4) == 2)
            check("five tiles in four columns become three and two", columns(640, 5) == 3)
            check("three tiles that fit two are two and one", columns(300, 3) == 2)

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
