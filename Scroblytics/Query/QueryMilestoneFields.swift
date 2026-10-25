import Foundation

/// Registry fields that WRAP `MilestonesEngine.entityStats` — the same per-entity
/// accumulation the Overview card and Milestones page build on, before the card's
/// top-60 cap. The thresholds, the 30-day pace estimate and "which plays crossed a
/// threshold" all live in the engine.
extension QueryFieldRegistry {
    private static func milestoneStats(_ run: QueryRun, scope: QueryScope?) -> [QueryEntityID: MilestonesEngine.EntityStats] {
        run.memoized("milestones.stats.\(scope?.cacheKey ?? "-")") {
            let view = run.engineView(scope)
            let all = MilestonesEngine.entityStats(scrobbles: view.scrobbles, referenceDate: view.asOf)
            let entries: [MilestonesEngine.EntityEntry]
            switch run.target {
            case .artist: entries = all.artists
            case .album: entries = all.albums
            case .track: entries = all.tracks
            case .scrobble: entries = []   // milestone fields are not offered for single plays
            }
            return Dictionary(uniqueKeysWithValues: entries.map { entry in
                (QueryEntityID(target: run.target, artist: entry.artist ?? entry.name, name: entry.name), entry.stats)
            })
        }
    }

    private static func milestoneField(
        id: String, name: String, type: QueryValueType = .numeric, help: String,
        column: QueryColumnSpec? = nil, value: @escaping @Sendable (MilestonesEngine.EntityStats) -> QueryValue?
    ) -> QueryField {
        QueryField(id: id, name: name, group: .volume, type: type, targets: [.artist, .album, .track], column: column,
                   help: help + " Under a date scope it is computed as of the scope’s end, from the plays up to then.",
                   scopedCompute: { run, _, scope, entities in
            let stats = milestoneStats(run, scope: scope)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                (entity.id, stats[entity.id].flatMap(value).map { .value($0) } ?? .missing)
            })
        })
    }

    static let milestoneFields: [QueryField] = [
        milestoneField(id: "nextMilestone", name: "Next milestone", help: "The next play-count milestone (100, 250, 500, 1,000, 2,500…) above its plays in the period.",
                       column: .standard(for: .numeric, style: .integer, width: 100)) { .number(Double($0.next)) },
        milestoneField(id: "toNextMilestone", name: "Plays to next milestone", help: "How many more plays until its next milestone.",
                       column: .standard(for: .numeric, style: .integer, width: 130)) { .number(Double($0.remaining)) },
        milestoneField(id: "milestoneEta", name: "Days to next milestone",
                       help: "Estimated days until its next milestone at the last 30 days’ pace. No value if it hasn’t been played in the last 30 days.",
                       column: .standard(for: .numeric, style: .integer, width: 130)) { $0.etaDays.map { .number(Double($0)) } },
        milestoneField(id: "milestonesReached", name: "Milestones reached", help: "How many play-count milestones it has passed.",
                       column: .standard(for: .numeric, style: .integer, width: 120)) { .number(Double($0.achieved.count)) },
        milestoneField(id: "lastMilestone", name: "Last milestone reached", help: "The most recent milestone it passed. No value if it hasn’t reached its first (100 plays).",
                       column: .standard(for: .numeric, style: .integer, width: 140)) { $0.achieved.last.map { .number(Double($0.milestone)) } },
        milestoneField(id: "lastMilestoneDate", name: "Last milestone reached on", type: .date,
                       help: "The day it passed that milestone. No value if it hasn’t reached its first.") { $0.achieved.last.map { .date($0.achievedAt) } },
    ]
}
