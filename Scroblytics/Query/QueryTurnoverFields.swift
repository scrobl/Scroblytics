import Foundation

/// Registry fields that WRAP Album Turnover. The match decision (canonical vs observed
/// tracklist, ambiguity) and the cycle math are `AlbumTurnoverEngine.matchResult` /
/// `assemble` — the same functions the Overview card and the tool call — fed from a
/// read-only cache snapshot. A field never triggers a Last.fm lookup itself.
///
/// Turnover is measured over the query's scrobbles, so a period scopes the cycle count too.
/// Albums are the engine's groups: every name variant of one album (an edition, a
/// remaster) shows the SAME numbers.
extension QueryFieldRegistry {
    private static func turnoverLookups(_ run: QueryRun, scope: QueryScope?) -> [QueryEntityID: AlbumTurnoverEngine.Snapshot.Lookup?] {
        run.memoized("turnover.lookups.\(scope?.cacheKey ?? "-")") {
            let byArtist = run.snapshots.turnoverGroups.groups(for: run.engineView(scope).scrobbles)
            let snapshot = run.snapshots.turnover
            return Dictionary(uniqueKeysWithValues: run.universe.entities.map { entity in
                let group = byArtist[entity.artist].flatMap { AlbumTurnoverEngine.findAlbumGroup($0, album: entity.name) }
                return (entity.id, group.map { snapshot.lookup(for: $0) })
            })
        }
    }

    private static func turnoverField(
        id: String, name: String, type: QueryValueType = .numeric, help: String,
        column: QueryColumnSpec? = nil, value: @escaping @Sendable (AlbumTurnoverEngine.AlbumTurnover) -> QueryValue?
    ) -> QueryField {
        QueryField(
            id: id, name: name, group: .engagement, type: type, targets: [.album], column: column,
            help: help + " Needs the album’s tracklist to be looked up first; albums without one yet are still resolving. Under a date scope it counts only the plays up to the scope’s end.",
            isBackgroundResolved: true, resolver: .albumTracklists,
            scopedCompute: { run, _, scope, entities in
            let lookups = turnoverLookups(run, scope: scope)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                switch lookups[entity.id] ?? nil {
                case .pending?: return (entity.id, .pending)
                case .value(let turnover)?: return (entity.id, value(turnover).map { .value($0) } ?? .missing)
                // Not a full-album pattern (or no album group at all): nothing to measure.
                case .notApplicable?, nil: return (entity.id, .missing)
                }
            })
        })
    }

    static let turnoverFields: [QueryField] = [
        turnoverField(id: "turnoverCycles", name: "Turnover cycles completed",
                      help: "How many times you’ve listened through the whole album (every track at least once since the last time).",
                      column: .standard(for: .numeric, style: .integer, width: 130)) { .number(Double($0.cyclesCompleted)) },
        turnoverField(id: "turnoverRate", name: "Days per turnover cycle",
                      help: "The median number of days a full listen-through took. No value if you haven’t completed one.",
                      column: .standard(for: .numeric, style: .decimal(1), width: 130)) { $0.rateDays.map { .number($0) } },
        turnoverField(id: "turnoverLast", name: "Last completed a cycle", type: .date,
                      help: "The day you last finished a full listen-through. No value if you never have.") { $0.lastTurnoverDate.map { .date($0) } },
        turnoverField(id: "turnoverHeard", name: "Tracks heard this cycle",
                      help: "How many of its tracks you’ve heard since the last completed cycle.",
                      column: .standard(for: .numeric, style: .integer, width: 120)) { .number(Double($0.inProgressHeard)) },
        turnoverField(id: "turnoverToGo", name: "Tracks to go this cycle",
                      help: "Tracks still unheard before this cycle completes — the “N tracks to go” on the Overview card.",
                      column: .standard(for: .numeric, style: .integer, width: 120)) { .number(Double($0.inProgressTotal - $0.inProgressHeard)) },
        turnoverField(id: "turnoverTracks", name: "Tracks on the album",
                      help: "The tracklist size turnover is measured against: the album’s real tracklist when it was matched, otherwise the tracks you’ve actually played.",
                      column: .standard(for: .numeric, style: .integer, width: 120)) { .number(Double($0.trackCount)) },
    ]
}
