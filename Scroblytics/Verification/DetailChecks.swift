import Foundation

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

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
