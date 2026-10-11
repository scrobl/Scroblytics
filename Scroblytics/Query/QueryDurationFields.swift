import Foundation

/// Registry fields that WRAP `DurationEngine`. Precedence (override > cached
/// Deezer value > confirmed miss > unresolved) is `DurationEngine.Snapshot.resolution`
/// — the same function `resolveDurationLookup` uses — and Time Listened is the
/// engine's own `timeListenedSeconds` sum, called once per entity.
extension QueryFieldRegistry {
    private static let minutes = QueryInputUnit(label: "min", perUnit: 60)
    private static let hours = QueryInputUnit(label: "hr", perUnit: 3600)

    static let durationFields: [QueryField] = [
        QueryField(
            id: "duration", name: "Duration", group: .duration, type: .numeric, targets: [.track],
            column: .standard(for: .numeric, style: .runtime),
            help: "The track’s runtime. A runtime you entered wins over the one found online. “Missing” means no runtime could be found; a value still being looked up matches neither.",
            isBackgroundResolved: true, inputUnit: minutes, resolver: .duration
        ) { run, _, entities in
            let snapshot = run.snapshots.durations
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                switch snapshot.resolution(forKey: DurationEngine.cacheKey(artist: entity.artist, track: entity.name)) {
                case .seconds(let seconds): return (entity.id, .value(.number(Double(seconds))))
                case .noMatch: return (entity.id, .missing)
                case .pending: return (entity.id, .pending)
                }
            })
        },
        QueryField(
            id: "timeListened", name: "Time listened", group: .duration, type: .numeric, targets: [.artist, .album, .track],
            column: .standard(for: .numeric, style: .listeningTime, width: 130),
            help: "Plays × runtime, summed over the query’s period — or this column’s own date scope. Pending while any of its tracks’ runtimes is still being looked up, so a partial total is never compared.",
            isBackgroundResolved: true, inputUnit: hours, resolver: .duration,
            scopedCompute: { run, _, scope, entities in
                let snapshot = run.snapshots.durations
                let lookup = snapshot.secondsLookup
                let byEntity = run.scopedScrobblesByEntity(scope)
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    let scrobbles = byEntity[entity.id] ?? []
                    let unresolved = scrobbles.contains { s in
                        !s.trackName.isEmpty && snapshot.resolution(forKey: DurationEngine.cacheKey(artist: s.artistName, track: s.trackName)) == .pending
                    }
                    if unresolved { return (entity.id, .pending) }
                    return (entity.id, .value(.number(Double(DurationEngine.timeListenedSeconds(scrobbles: scrobbles, lookup: lookup)))))
                })
            }
        ),
    ]
}
