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
            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
