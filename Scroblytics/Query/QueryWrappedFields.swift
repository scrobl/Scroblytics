import Foundation

/// Registry fields that WRAP an existing, already-validated engine. Each
/// `compute` calls that engine's own function and reads its result — none
/// re-derives a value, so there is exactly one computation of each.
extension QueryFieldRegistry {

    // MARK: Fading Favorites (wraps `FadingFavoritesEngine.stats`)

    /// The fading window is a field PARAMETER, not global state: "Peak plays @ 90d"
    /// and "Peak plays @ 180d" are different values. (There is one fading definition,
    /// not separate ones for Ask and the tool.)
    static let fadingWindow = QueryFieldParameter(
        id: "windowDays", label: "Window (days)",
        options: FadingFavoritesEngine.allowedDays.map { .number(Double($0)) },
        defaultValue: .number(90),
        suffix: "d",
        help: "How many days count as “recent” — a track’s peak is its best span of this length, and recent plays are those in the last stretch of this length."
    )

    private static func fadingStats(_ run: QueryRun, _ parameters: [String: QueryValue], scope: QueryScope?) -> [QueryEntityID: FadingFavoriteStats] {
        guard case .number(let window)? = parameters["windowDays"] else {
            preconditionFailure("windowDays is always resolved to a default by QueryFieldRegistry.resolve")
        }
        return run.memoized("fading.stats.\(Int(window)).\(scope?.cacheKey ?? "-")") {
            let view = run.engineView(scope)
            return Dictionary(uniqueKeysWithValues: FadingFavoritesEngine.stats(
                scrobbles: view.scrobbles, windowDays: Int(window), asOf: view.asOf
            ).map { (QueryEntityID(target: .track, artist: $0.artist, name: $0.track), $0) })
        }
    }

    private static func fadingField(
        id: String, name: String, type: QueryValueType = .numeric, help: String, column: QueryColumnSpec,
        value: @escaping @Sendable (FadingFavoriteStats) -> Double
    ) -> QueryField {
        QueryField(
            id: id, name: name, group: .sentiment, type: type, targets: [.track],
            parameters: [fadingWindow], column: column, help: help + " Under a date scope it is computed as of the scope’s end, from the plays up to then.",
            scopedCompute: { run, parameters, scope, entities in
            let stats = fadingStats(run, parameters, scope: scope)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                // No plays up to the as-of date → the engine has no stats → genuinely absent.
                (entity.id, stats[entity.id].map { .value(.number(value($0))) } ?? .missing)
            })
        })
    }

    private static func fadingDateField(
        id: String, name: String, help: String,
        value: @escaping @Sendable (FadingFavoriteStats) -> Date
    ) -> QueryField {
        QueryField(
            id: id, name: name, group: .sentiment, type: .date, targets: [.track],
            parameters: [fadingWindow], column: .standard(for: .date),
            help: help + " Under a date scope it is computed as of the scope’s end, from the plays up to then.",
            scopedCompute: { run, parameters, scope, entities in
            let stats = fadingStats(run, parameters, scope: scope)
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                (entity.id, stats[entity.id].map { .value(.date(value($0))) } ?? .missing)
            })
        })
    }

    static let fadingFields: [QueryField] = [
        fadingField(
            id: "fadingPeak", name: "Peak plays",
            help: "The most plays this track had in any span of the window length — how big a favorite it once was.",
            column: QueryColumnSpec(alignment: .trailing, style: .custom("peakBadge"), width: 120)
        ) { Double($0.peakPlaycount) },
        fadingDateField(
            id: "fadingPeakStart", name: "Peak period start",
            help: "The start of the window where this track had its peak play density — its first play inside that span."
        ) { $0.peakWindowStart },
        fadingDateField(
            id: "fadingPeakEnd", name: "Peak period end",
            help: "The end of the window where this track had its peak play density — its last play inside that span."
        ) { $0.peakWindowEnd },
        fadingField(
            id: "fadingRecent", name: "Recent plays",
            help: "Plays in the window immediately before the query’s “now”.",
            column: .standard(for: .numeric)
        ) { Double($0.recentPlaycount) },
        fadingField(
            id: "fadingDecay", name: "Fade ratio",
            help: "Recent plays as a fraction of the peak. 0% = gone silent, 100% = still at its peak.",
            column: .standard(for: .numeric, style: .percent)
        ) { $0.decayScore },
        fadingField(
            id: "rediscoveryScore", name: "Rediscovery score",
            help: "Peak plays × how far it has faded — a big past favorite that has gone quiet scores highest.",
            column: .standard(for: .numeric, style: .decimal(1))
        ) { $0.rediscoveryScore },
    ]

    // MARK: Popularity (wraps `PopularitySnapshot`)

    private static func popularityLookup(_ entity: QueryEntity) -> PopularityLookup {
        switch entity.target {
        case .artist: .artist(entity.name)
        case .album: .album(artist: entity.artist, name: entity.name)
        case .track: .track(artist: entity.artist, name: entity.name)
        }
    }

    static let popularityFields: [QueryField] = {
        let all: Set<QueryTarget> = [.artist, .album, .track]

        return [
            QueryField(
                id: "popular", name: "Popular", group: .flags, type: .boolean, targets: all,
                column: QueryColumnSpec(alignment: .center, style: .custom("popularityDiamond"), width: 90),
                help: "In the top quartile of your whole library by combined Last.fm and Deezer popularity — the same test as the diamond.",
                isBackgroundResolved: true
            ) { run, _, entities in
                Dictionary(uniqueKeysWithValues: entities.map { entity in
                    let key = popularityLookup(entity).key
                    guard let indicator = run.popularity.indicator(forKey: key) else { return (entity.id, .pending) }
                    return (entity.id, .value(.bool(indicator.libraryPopular)))
                })
            },
            QueryField(
                id: "popularForArtist", name: "Popular for this artist", group: .flags, type: .boolean, targets: [.album, .track],
                column: QueryColumnSpec(alignment: .center, style: .boolean, width: 130),
                help: "In the top quartile of just this artist’s own albums or tracks. Needs at least 4 of the artist’s items to compare, otherwise it has no value.",
                isBackgroundResolved: true
            ) { run, _, entities in
                Dictionary(uniqueKeysWithValues: entities.map { entity in
                    let key = popularityLookup(entity).key
                    guard let indicator = run.popularity.indicator(forKey: key) else { return (entity.id, .pending) }
                    // Below the minimum pool there is no artist tier at all: absent, not "no".
                    guard run.popularity.hasArtistTier(forKey: key) else { return (entity.id, .missing) }
                    return (entity.id, .value(.bool(indicator.artistPopular)))
                })
            },
            QueryField(
                id: "popularityScore", name: "Popularity", group: .flags, type: .numeric, targets: all,
                column: .standard(for: .numeric, style: .percent),
                help: "Combined library-wide popularity score (0–100%): the average of this item’s percentile across its Last.fm and Deezer signals.",
                isBackgroundResolved: true
            ) { run, _, entities in
                Dictionary(uniqueKeysWithValues: entities.map { entity in
                    let key = popularityLookup(entity).key
                    guard run.popularity.hasRecord(forKey: key) else { return (entity.id, .pending) }
                    return (entity.id, run.popularity.libraryScore(forKey: key).map { .value(.number($0)) } ?? .missing)
                })
            },
        ]
    }()

    // MARK: The registry the app uses

    static let standard = QueryFieldRegistry(fields: coreFields + fadingFields + popularityFields + durationFields + bpmFields + releaseDateFields + climbingFields + milestoneFields + turnoverFields + lovedFields + libraryFields + flaggedFields + tagFields + imageFields + matchFields + editionFields)
}
