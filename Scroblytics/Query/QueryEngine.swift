import Foundation

struct QueryRow: Identifiable, Sendable {
    let entity: QueryEntity
    /// Column values, keyed by `ResolvedField.cacheKey`.
    let cells: [String: QueryCell]
    /// The calendar year this row is for, when the query is broken down by year (the same entity then appears once per year).
    var period: Int? = nil
    var id: QueryEntityID { entity.id }
}

struct QueryResult: Sendable {
    let rows: [QueryRow]
    /// Columns in display order.
    let columns: [ResolvedField]
    /// Entities that matched before `limit` was applied.
    let matchedCount: Int
    /// Entities the query ran over.
    let universeCount: Int
    /// Background-resolved fields a condition or sort used, and how many
    /// entities were still `.pending` for each — those entities can match
    /// neither a comparison nor "is missing", so the user is told rather than
    /// left to wonder why rows are absent.
    let pending: [(field: String, count: Int, resolver: QueryResolverKind?)]
    /// The entities whose place in the result hinges on a still-unresolved value, grouped by the
    /// pipeline that would resolve it — so a resolver fetches what THIS query needs, not the whole
    /// library.
    let pendingEntities: [QueryResolverKind: Set<QueryEntityID>]
    /// Artwork and (for tracks) best album for the returned rows, from the same
    /// grouping pass the fields read.
    let entityInfo: [QueryEntityID: EntityInfo]

    struct EntityInfo: Sendable {
        let imageURL: String?
        let album: String?
    }
}

/// The single place a query is evaluated. Every consumer — the builder, saved
/// sets, any future preset UI or natural-language translator — calls
/// `evaluate`; none re-implement matching.
enum QueryEngine {
    static func evaluate(_ query: ValidatedQuery, run: QueryRun) -> QueryResult {
        if query.spec.breakdown != nil { return evaluateByYear(query, run: run) }
        let universe = run.evaluationEntities
        var matched = universe
        var cellsByField: [String: [QueryEntityID: QueryCell]] = [:]
        let matcher = QueryMatcher(calendar: run.calendar)

        if !query.groups.isEmpty {
            // Compute each referenced field once, over the whole universe.
            for group in query.groups {
                for condition in group where cellsByField[condition.field.cacheKey] == nil {
                    cellsByField[condition.field.cacheKey] = run.cells(for: condition.field, entities: universe)
                }
            }
            matched = universe.filter { entity in
                query.groups.contains { group in
                    group.allSatisfy { condition in
                        let cell = cellsByField[condition.field.cacheKey]?[entity.id] ?? .missing
                        return matcher.matches(
                            cell,
                            op: condition.op,
                            operands: condition.operands,
                            calendar: comparisonCalendar(for: condition.field)
                        )
                    }
                }
            }
        }

        let ordered = sorted(matched, by: query.sorts, run: run)
        let capped = applyGroupLimit(query.spec.groupLimit, releaseYear: query.releaseYearField, to: ordered, run: run)
        let picked = query.spec.limit.map { Array(capped.prefix($0)) } ?? capped
        // The sorts and caps chose these; the result order may be a different one (by release year, say). Ties keep the order they were picked in.
        let limited = sorted(picked, by: query.effectiveResultSorts, run: run)

        var columnCells: [String: [QueryEntityID: QueryCell]] = [:]
        for column in query.columns {
            columnCells[column.cacheKey] = run.cells(for: column, entities: limited)
        }
        let rows = limited.map { entity in
            QueryRow(entity: entity, cells: Dictionary(uniqueKeysWithValues: query.columns.map {
                ($0.cacheKey, columnCells[$0.cacheKey]?[entity.id] ?? .missing)
            }))
        }

        let aggregates = run.universe.aggregates
        let info = Dictionary(uniqueKeysWithValues: limited.compactMap { entity in
            aggregates[entity.id].map { (entity.id, QueryResult.EntityInfo(imageURL: $0.imageURL, album: $0.album)) }
        })

        let report = pendingReport(
            query, run: run, universe: universe, matched: matched, shown: limited, cellsByField: cellsByField, matcher: matcher
        )
        return QueryResult(
            rows: rows, columns: query.columns, matchedCount: matched.count, universeCount: universe.count,
            pending: report.summary, pendingEntities: report.entities, entityInfo: info
        )
    }

    // MARK: - Break down by calendar year

    /// The query run separately over each calendar year of the plays it counts: each year's own plays decide its plays, its sorts and its caps,
    /// and `limit` keeps that many per year. Fields that look at all of history (first played, turnover…) still do, via the all-time plays.
    private static func evaluateByYear(_ query: ValidatedQuery, run: QueryRun) -> QueryResult {
        var spec = query.spec
        spec.breakdown = nil
        let single = ValidatedQuery(
            spec: spec, groups: query.groups, sorts: query.sorts, resultSorts: query.resultSorts, columns: query.columns, releaseYearField: query.releaseYearField
        )
        let calendar = run.calendar
        let byYear = Dictionary(grouping: run.scrobbles) { calendar.component(.year, from: $0.playedAt) }
        let years = byYear.keys.sorted(by: query.spec.breakdown?.showsNewestFirst == true ? (>) : (<))

        var rows: [QueryRow] = []
        var info: [QueryEntityID: QueryResult.EntityInfo] = [:]
        var matched = 0
        var pending: [String: (field: String, count: Int, resolver: QueryResolverKind?)] = [:]
        var pendingEntities: [QueryResolverKind: Set<QueryEntityID>] = [:]
        for year in years {
            let yearRun = QueryRun(
                target: run.target, asOf: run.asOf, calendar: calendar, scrobbles: byYear[year] ?? [], allTimeScrobbles: run.allTimeScrobbles,
                snapshots: run.snapshots, entityScope: run.entityScope
            )
            let result = evaluate(single, run: yearRun)
            matched += result.matchedCount
            rows += result.rows.map { QueryRow(entity: $0.entity, cells: $0.cells, period: year) }
            for (id, value) in result.entityInfo where info[id] == nil { info[id] = value }
            for item in result.pending {
                let key = item.field + "|" + (item.resolver.map { "\($0)" } ?? "")
                pending[key] = (item.field, (pending[key]?.count ?? 0) + item.count, item.resolver)
            }
            for (kind, ids) in result.pendingEntities { pendingEntities[kind, default: []].formUnion(ids) }
        }
        return QueryResult(
            rows: rows, columns: query.columns, matchedCount: matched, universeCount: run.evaluationEntities.count,
            pending: pending.values.sorted { $0.field < $1.field }, pendingEntities: pendingEntities, entityInfo: info
        )
    }

    // MARK: - Group limit

    /// Diversity caps applied after sorting, before the overall `limit` — keeps at most `perArtist`
    /// results sharing the same artist, at most `perAlbum` sharing the same album and/or at most
    /// `perReleaseYear` sharing the same release year, simultaneously, in the current sort order.
    /// `perArtist` is a no-op for an artist-target run (every row is already unique on itself); `perAlbum`
    /// only ever applies to a track-target run, reusing the exact same "most-played album" value
    /// `entityInfo` already surfaces; the year is the Release year field's own value — never a second
    /// definition. A track with no resolved album, or an entity whose release year is missing or still
    /// being looked up, is never capped on that axis (nothing to share "the same" with).
    private static func applyGroupLimit(
        _ groupLimit: QueryGroupLimit?, releaseYear: ResolvedField?, to entities: [QueryEntity], run: QueryRun
    ) -> [QueryEntity] {
        guard let groupLimit, !groupLimit.isEmpty else { return entities }
        let perArtist = groupLimit.perArtist
        let perAlbum = groupLimit.perAlbum
        let perYear = releaseYear == nil ? nil : groupLimit.perReleaseYear
        let aggregates = run.universe.aggregates
        let yearCells: [QueryEntityID: QueryCell] = releaseYear.map { run.cells(for: $0, entities: entities) } ?? [:]

        var artistCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]
        var yearCounts: [Int: Int] = [:]
        var kept: [QueryEntity] = []
        kept.reserveCapacity(entities.count)
        for entity in entities {
            let capsByArtist = perArtist != nil && entity.id.target != .artist
            let albumKey: String? = (perAlbum != nil && entity.id.target == .track) ? aggregates[entity.id]?.album : nil
            var yearKey: Int?
            if perYear != nil, case .value(.number(let year))? = yearCells[entity.id] { yearKey = Int(year) }

            if capsByArtist, artistCounts[entity.id.artist, default: 0] >= perArtist! { continue }
            if let albumKey, albumCounts[albumKey, default: 0] >= perAlbum! { continue }
            if let yearKey, yearCounts[yearKey, default: 0] >= perYear! { continue }

            if capsByArtist { artistCounts[entity.id.artist, default: 0] += 1 }
            if let albumKey { albumCounts[albumKey, default: 0] += 1 }
            if let yearKey { yearCounts[yearKey, default: 0] += 1 }
            kept.append(entity)
        }
        return kept
    }

    // MARK: - Sorting

    private static func sorted(_ entities: [QueryEntity], by sorts: [ValidatedSort], run: QueryRun) -> [QueryEntity] {
        guard !sorts.isEmpty else { return entities } // already in the universe's deterministic (name, artist) order

        // Plays are listed newest first already: sorting on their time, the way a list of plays is read, is the order they are in (or its
        // reverse). Skips computing and comparing a value for every play of the library.
        if run.target == .scrobble, sorts.count == 1, case .field(let resolved) = sorts[0].key, resolved.field.id == "playedAt", resolved.scope == nil {
            return sorts[0].direction == .descending ? entities : entities.reversed()
        }

        enum Key { case cells([QueryEntityID: QueryCell]), shuffle([QueryEntityID: UInt64]) }
        let keys: [Key] = sorts.map { sort in
            switch sort.key {
            case .field(let resolved): .cells(run.cells(for: resolved, entities: entities))
            case .shuffle(let seed): .shuffle(shuffleKeys(for: entities, seed: seed))
            }
        }

        // `entities` is in (name, artist) order and Swift's sort isn't stable,
        // so the final tie-break is explicit: identical runs give identical output.
        let position = Dictionary(uniqueKeysWithValues: entities.enumerated().map { ($1.id, $0) })
        return entities.sorted { a, b in
            for (sort, key) in zip(sorts, keys) {
                let order: ComparisonResult
                switch key {
                case .shuffle(let random):
                    let (x, y) = (random[a.id]!, random[b.id]!)
                    // Direction is meaningless for a random order.
                    order = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
                case .cells(let cells):
                    switch (cells[a.id] ?? .missing, cells[b.id] ?? .missing) {
                    case (.value(let x), .value(let y)):
                        let natural = compare(x, y)
                        // Direction flips real values only; absent values stay last.
                        order = sort.direction == .ascending ? natural : flip(natural)
                    case (.value, _): return true          // value before no-value
                    case (_, .value): return false
                    default: order = .orderedSame          // both absent: fall through to next key
                    }
                }
                if order != .orderedSame { return order == .orderedAscending }
            }
            return position[a.id]! < position[b.id]!
        }
    }

    private static func flip(_ r: ComparisonResult) -> ComparisonResult {
        r == .orderedAscending ? .orderedDescending : (r == .orderedDescending ? .orderedAscending : .orderedSame)
    }

    private static func compare(_ a: QueryValue, _ b: QueryValue) -> ComparisonResult {
        switch (a, b) {
        case (.number(let x), .number(let y)): x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case (.text(let x), .text(let y)): x.localizedStandardCompare(y)
        case (.date(let x), .date(let y)): x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case (.bool(let x), .bool(let y)): x == y ? .orderedSame : (!x ? .orderedAscending : .orderedDescending)
        default: .orderedSame // tags are rejected at validation; mixed types can't occur for one field
        }
    }

    private static func shuffleKeys(for entities: [QueryEntity], seed: UInt64?) -> [QueryEntityID: UInt64] {
        var rng: any RandomNumberGenerator = seed.map { SplitMix64(seed: $0) } ?? SystemRandomNumberGenerator()
        return Dictionary(uniqueKeysWithValues: entities.map { ($0.id, rng.next()) })
    }

    // MARK: - Pending report

    /// Background-resolved values still pending, and who they affect:
    /// - a field a **condition** uses counts the entities that fail ONLY because it is unresolved —
    ///   every other test in some group already passes, so resolving it could add them to the result;
    /// - a field a **sort** uses counts the matched entities it can't rank yet;
    /// - a field only shown as a **column** counts the displayed rows whose cell reads "…".
    private static func pendingReport(
        _ query: ValidatedQuery, run: QueryRun, universe: [QueryEntity], matched: [QueryEntity], shown: [QueryEntity],
        cellsByField: [String: [QueryEntityID: QueryCell]], matcher: QueryMatcher
    ) -> (summary: [(field: String, count: Int, resolver: QueryResolverKind?)], entities: [QueryResolverKind: Set<QueryEntityID>]) {
        var order: [String] = []
        var fields: [String: ResolvedField] = [:]
        var affected: [String: Set<QueryEntityID>] = [:]
        func record(_ field: ResolvedField, _ id: QueryEntityID) {
            guard field.field.isBackgroundResolved else { return }
            if fields[field.cacheKey] == nil { fields[field.cacheKey] = field; order.append(field.cacheKey) }
            affected[field.cacheKey, default: []].insert(id)
        }

        if !query.groups.isEmpty {
            let matchedIDs = Set(matched.map(\.id))
            for entity in universe where !matchedIDs.contains(entity.id) {
                for group in query.groups {
                    var unresolved: [ResolvedField] = []
                    var failed = false
                    for condition in group {
                        let cell = cellsByField[condition.field.cacheKey]?[entity.id] ?? .missing
                        if cell == .pending {
                            unresolved.append(condition.field)
                        } else if !matcher.matches(
                            cell,
                            op: condition.op,
                            operands: condition.operands,
                            calendar: comparisonCalendar(for: condition.field)
                        ) {
                            failed = true
                            break
                        }
                    }
                    if !failed { unresolved.forEach { record($0, entity.id) } }
                }
            }
        }
        for sort in query.sorts {
            guard case .field(let resolved) = sort.key, resolved.field.isBackgroundResolved else { continue }
            let cells = run.cells(for: resolved, entities: matched)
            for entity in matched where cells[entity.id] == .pending { record(resolved, entity.id) }
        }
        // A per-release-year cap can't place an entity whose year is still being looked up.
        if let yearField = query.releaseYearField, query.spec.groupLimit?.perReleaseYear != nil {
            let cells = run.cells(for: yearField, entities: matched)
            for entity in matched where cells[entity.id] == .pending { record(yearField, entity.id) }
        }
        for column in query.columns where column.field.isBackgroundResolved {
            let cells = run.cells(for: column, entities: shown)
            for entity in shown where cells[entity.id] == .pending { record(column, entity.id) }
        }

        var byResolver: [QueryResolverKind: Set<QueryEntityID>] = [:]
        var summary: [(field: String, count: Int, resolver: QueryResolverKind?)] = []
        for key in order {
            guard let field = fields[key], let ids = affected[key], !ids.isEmpty else { continue }
            summary.append((field.field.name, ids.count, field.field.resolver))
            if let resolver = field.field.resolver {
                // A play's inherited field fills in the item it is of: the lookup is for that track, album or artist.
                if let level = field.field.itemLevel { byResolver[resolver, default: []].formUnion(ids.compactMap { run.itemID(level, ofPlay: $0) }) }
                else { byResolver[resolver, default: []].formUnion(ids) }
            }
        }
        return (summary, byResolver)
    }

    private static func comparisonCalendar(for field: ResolvedField) -> Calendar? {
        field.field.id == "releaseDate" ? AppCalendars.releaseDates : nil
    }
}

/// Small deterministic generator so a seeded shuffle is reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
