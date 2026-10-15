import Foundation
import SwiftData

#if DEBUG
/// Real-data verification hook: with `SCROBLYTICS_TURNOVER_DUMP=/path.tsv` set, computes
/// `AlbumTurnoverEngine.resolveAlbumTurnover` for every album group whose tracklist is
/// already cached (so it never touches the network), writes one line per group, and quits.
/// Used to prove a refactor of the engine changed nothing.
enum AlbumTurnoverDebugDump {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_TURNOVER_DUMP"] else { return }
        Task { @MainActor in
            do {
            let context = container.mainContext
            let scrobbles = try context.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
            let groups = await AlbumTurnoverEngine.buildAllGroups(scrobbles: scrobbles, separateEditions: AlbumTurnoverEngine.separateEditionKeys(context: context))
            let cachedKeys = Set(try context.fetch(FetchDescriptor<AlbumTracklistCacheEntry>()).map(\.cacheKey))
            let client = LastfmAPIClient(apiKey: "unused", username: "unused")
            var lines: [String] = []
            var skipped = 0
            for group in groups {
                let resolution = AlbumTurnoverEngine.storedResolution(context: context, group: group)
                // Which lookup would resolveTurnover make? Mirror its branching only far enough to
                // know whether a cache row exists; anything that would hit the network is skipped.
                let request = AlbumTurnoverEngine.tracklistRequest(group: group, resolution: resolution)
                let needsLookup = request != nil
                let lookupKey = request.map { AlbumTurnoverEngine.tracklistCacheKey(artist: $0.artist, album: $0.album) } ?? ""
                if needsLookup, !cachedKeys.contains(lookupKey) { skipped += 1; continue }
                let t = try await AlbumTurnoverEngine.resolveAlbumTurnover(context: context, group: group, resolution: resolution, client: client)
                let fields: [String] = [
                    t.artist, t.album, "\(t.applicable)", "\(t.basis)", "\(t.ambiguous)", "\(t.noCanonicalMatch)", "\(t.resolved)",
                    t.rateDays.map { "\($0)" } ?? "-", "\(t.cyclesCompleted)", t.lastTurnoverDate.map { "\($0.timeIntervalSince1970)" } ?? "-",
                    "\(t.trackCount)", "\(t.observedDistinct)", "\(t.inProgressHeard)", "\(t.inProgressTotal)", "\(t.inProgressMissing.count)",
                    "\(t.isCompilation)", t.groupKey.replacingOccurrences(of: "\u{0}", with: "␀"),
                ]
                lines.append(fields.joined(separator: "\t"))
            }
            lines.sort()
            try (lines.joined(separator: "\n") + "\n# groups \(groups.count), dumped \(lines.count), skipped (uncached) \(skipped)\n").write(toFile: path, atomically: true, encoding: .utf8)
            print("[AlbumTurnoverDebugDump] \(lines.count) groups dumped, \(skipped) skipped")
            exit(0)
            } catch {
                print("[AlbumTurnoverDebugDump] FAILED: \(error)")
                exit(1)
            }
        }
    }
}
#endif
