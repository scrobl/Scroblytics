import Foundation
import SwiftData

/// Runs a validated query over the whole history without the Query screen, with the same history, snapshots and engine the screen
/// uses, so what comes back is the rows Query would list. The Collage tool's saved queries and the automatic playlists run this way.
enum QueryHeadlessRunner {
    /// The result, and the artwork lookup the rows' images are found in.
    @MainActor
    static func run(
        _ validated: ValidatedQuery, container: ModelContainer, popularity: PopularityStore?, history: [ScrobbleSnapshot]? = nil
    ) async throws -> (result: QueryResult, imageLookup: [String: String]) {
        let scrobbles: [ScrobbleSnapshot]
        if let history { scrobbles = history } else {
            scrobbles = try await offMain {
                try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            }
        }
        let loaded = await QuerySnapshotReader.loadAll(container: container)
        let snapshots = QuerySnapshots(
            popularity: popularity?.snapshot ?? .empty, durations: loaded.durations, bpm: loaded.bpm, releaseDates: loaded.releaseDates,
            turnover: loaded.turnover, lovedKeys: loaded.lovedKeys, flaggedKeys: loaded.flaggedKeys,
            entityTags: loaded.entityTags, libraryPresence: loaded.libraryPresence, appleMusic: loaded.appleMusic, weather: loaded.weather, images: loaded.images
        )
        let result = await Task.detached(priority: .userInitiated) { () -> QueryResult in
            let inScope = validated.spec.countedPlays(scrobbles, weather: snapshots.weather)
            let run = QueryRun(
                target: validated.spec.target, asOf: validated.spec.asOf ?? Date(), scrobbles: inScope, allTimeScrobbles: scrobbles,
                snapshots: snapshots, sessionGapMinutes: Double(validated.spec.effectiveSessionGapMinutes)
            )
            return QueryEngine.evaluate(validated, run: run)
        }.value
        return (result, loaded.images.lookup)
    }
}
