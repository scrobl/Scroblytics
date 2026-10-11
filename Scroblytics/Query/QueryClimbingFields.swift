import Foundation

/// Registry fields that WRAP `ClimbingEngine.stats`. Like Fading Favorites, the window is
/// a field parameter, and the card's own guards (5+ recent plays, gained places, or a Hot
/// Shot Debut) are ordinary conditions over these fields — see `climbingSpec`.
extension QueryFieldRegistry {
    static let climbingWindow = QueryFieldParameter(
        id: "windowDays", label: "Window (days)",
        options: ClimbingEngine.allowedWindows.map { .number(Double($0)) }, defaultValue: .number(90), suffix: "d",
        help: "The window the Climbing card compares against: the rank before the window started vs. the rank now."
    )

    private static func climbingStats(_ run: QueryRun, _ parameters: [String: QueryValue], scope: QueryScope?) -> [QueryEntityID: ClimbingEngine.Stats] {
        guard case .number(let window)? = parameters["windowDays"] else {
            preconditionFailure("windowDays is always resolved to a default by QueryFieldRegistry.resolve")
        }
        return run.memoized("climbing.stats.\(Int(window)).\(scope?.cacheKey ?? "-")") {
            let view = run.engineView(scope)
            return Dictionary(uniqueKeysWithValues: ClimbingEngine.stats(
                scrobbles: view.scrobbles, windowDays: Int(window), referenceDate: view.asOf
            ).map { (QueryEntityID(target: .track, artist: $0.artist, name: $0.track), $0) })
        }
    }

    private static func climbingField(
        id: String, name: String, help: String, type: QueryValueType = .numeric, column: QueryColumnSpec? = nil,
        value: @escaping @Sendable (ClimbingEngine.Stats) -> QueryValue?
    ) -> QueryField {
        QueryField(
            id: id, name: name, group: .ranking, type: type, targets: [.track], parameters: [climbingWindow],
            column: column, help: help + " Under a date scope it is computed as of the scope’s end, from the plays up to then.",
            scopedCompute: { run, parameters, scope, entities in
            let stats = climbingStats(run, parameters, scope: scope)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                (entity.id, stats[entity.id].flatMap(value).map { .value($0) } ?? .missing)
            })
        })
    }

    static let climbingFields: [QueryField] = [
        climbingField(
            id: "rankWindowAgo", name: "Rank N days ago",
            help: "Its all-time rank as of the start of the window. No value if it had no plays before then."
        ) { $0.previousRank.map { .number(Double($0)) } },
        climbingField(
            id: "rankChange", name: "Places climbed",
            help: "All-time rank at the window’s start minus its rank now. Positive = climbing, negative = falling. No value for a track with no earlier plays."
        ) { stat in stat.previousRank == nil ? nil : .number(Double(stat.velocity)) },
        climbingField(
            id: "climbScore", name: "Climb score",
            help: "What the Climbing card ranks by: places climbed, or for a track with no earlier plays, how far it debuted up the library.",
            column: .standard(for: .numeric, style: .integer, width: 90)
        ) { .number(Double($0.velocity)) },
        climbingField(
            id: "hotShotDebut", name: "Hot Shot Debut", help: "No plays before the window, and now in the top quarter of your library by plays.",
            type: .boolean
        ) { .bool($0.isHotShotDebut) },
    ]
}
