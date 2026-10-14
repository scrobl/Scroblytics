import Foundation

#if DEBUG
/// `SCROBLYTICS_OVERVIEW_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): Overview's "Almost there" cards. Which items are
/// chosen and in what order, and how many are shown for the width Overview has (three columns by two rows at most). Made-up data.
/// Exits 0 on success.
enum OverviewChecks {
    @MainActor
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_OVERVIEW_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            func item(_ name: String, remaining: Int, eta: Int? = nil, entity: TopChartsEntity = .track) -> MilestoneUpcoming {
                MilestoneUpcoming(entity: entity, artist: "Artist A", name: name, album: nil, imageURL: nil, current: 100 - remaining, next: 100, remaining: remaining, etaDays: eta)
            }
            func names(_ items: [MilestoneUpcoming]) -> [String] { items.map(\.name) }

            // MARK: Which items, in what order
            let pool = [
                item("Far away", remaining: 40), item("One, no estimate", remaining: 1), item("One, 9 days", remaining: 1, eta: 9),
                item("Two plays", remaining: 2), item("One, 3 days", remaining: 1, eta: 3), item("At it", remaining: 0, eta: 1),
                item("One, 3 days, later in the list", remaining: 1, eta: 3), item("One, 20 days", remaining: 1, eta: 20),
            ]
            let chosen = names(MilestonesEngine.almostThere(from: pool))
            check("only items one play (or none) from a milestone qualify", !chosen.contains("Far away") && !chosen.contains("Two plays"), "\(chosen)")
            check("the closest come first, then the soonest expected, then the order given, and one with no estimate last",
                  chosen == ["At it", "One, 3 days", "One, 3 days, later in the list", "One, 9 days", "One, 20 days", "One, no estimate"], "\(chosen)")
            let many = (0..<20).map { (n: Int) in item("Item \(n)", remaining: 1, eta: n) }
            check("never more than six, and they are the soonest six", names(MilestonesEngine.almostThere(from: many)) == (0..<6).map { (n: Int) in "Item \(n)" }, "\(names(MilestonesEngine.almostThere(from: many)))")
            check("a smaller limit is honoured", MilestonesEngine.almostThere(from: many, limit: 4).count == 4)
            check("nothing close gives nothing (the section hides)", MilestonesEngine.almostThere(from: [item("Far", remaining: 5)]).isEmpty && MilestonesEngine.almostThere(from: []).isEmpty)
            check("artists, albums and tracks mix on equal footing", Set(MilestonesEngine.almostThere(from: [item("A", remaining: 1, eta: 5, entity: .artist), item("B", remaining: 1, eta: 4, entity: .album), item("C", remaining: 1, eta: 3, entity: .track)]).map(\.entity)) == [.artist, .album, .track])

            // MARK: How many columns and cards
            func columns(_ width: CGFloat) -> Int { AlmostMilestonesSection.columnCount(forWidth: width) }
            check("a wide window has three columns", columns(1400) == 3 && columns(900) == 3)
            check("a middling one has two, a narrow one has one", columns(899) == 2 && columns(640) == 2 && columns(639) == 1 && columns(300) == 1)
            func shown(_ total: Int, _ columns: Int) -> Int { AlmostMilestonesSection.visibleCount(of: total, columns: columns) }
            check("three columns by two rows is six cards", shown(10, 3) == 6 && shown(6, 3) == 6)
            check("two columns show four, one column shows two (never a third row)", shown(10, 2) == 4 && shown(10, 1) == 2)
            check("fewer items than room show just those", shown(3, 3) == 3 && shown(0, 3) == 0 && shown(1, 1) == 1)
            check("no width and no count ever makes more than two rows",
                  stride(from: 200, through: 1600, by: 50).allSatisfy { width in
                      (0...12).allSatisfy { total in
                          let cols = columns(CGFloat(width)); let count = shown(total, cols)
                          return count == 0 || (count + cols - 1) / cols <= AlmostMilestonesSection.maxRows
                      }
                  })

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
