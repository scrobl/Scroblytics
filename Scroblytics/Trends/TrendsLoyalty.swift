import Foundation

/// How spread out listening is: the number of different days, weeks or months something was played in.
enum LoyaltySpread: String, CaseIterable, Identifiable, Sendable {
    /// Days from the first play to the last in the period.
    case span
    case activeDays, activeWeeks, activeMonths
    var id: String { rawValue }
    var fieldID: String { self == .span ? "playSpanDays" : rawValue }
    var label: String {
        switch self {
        case .span: "First to last play"
        case .activeDays: "Active days"
        case .activeWeeks: "Active weeks"
        case .activeMonths: "Active months"
        }
    }
    var unit: String { self == .span ? "day" : self == .activeDays ? "day" : self == .activeWeeks ? "week" : "month" }
    /// The axis title.
    var axis: String { self == .span ? "Days from first to last play" : label }
    /// An "active" count can never exceed the number of plays, so "few plays but many weeks" is impossible there and the
    /// "Background" corner stays empty; the span can, so it is the default.
    var note: String {
        self == .span
            ? "The span is how long it stayed in rotation, however often you played it."
            : "\(label) can’t exceed the number of plays, so the Background corner is always empty."
    }
}

enum LoyaltyQuadrant: String, CaseIterable, Identifiable, Sendable {
    /// Played a lot, over a long time.
    case lifers
    /// Played a lot, in a short burst.
    case obsessions
    /// Played a little, over a long time.
    case background
    /// Played a little, briefly.
    case passing
    var id: String { rawValue }

    var label: String {
        switch self {
        case .lifers: "Lifers"
        case .obsessions: "Obsessions"
        case .background: "Background"
        case .passing: "Passing interest"
        }
    }

    var summary: String {
        switch self {
        case .lifers: "Played a lot, across a long stretch"
        case .obsessions: "Played a lot, in a short burst"
        case .background: "Played a little, but for a long time"
        case .passing: "Played a little, briefly"
        }
    }

    static func of(plays: Double, spread: Double, xMedian: Double, yMedian: Double) -> LoyaltyQuadrant {
        let many = plays >= xMedian, long = spread >= yMedian
        return many ? (long ? .lifers : .obsessions) : (long ? .background : .passing)
    }
}

/// One artist / album / track: its plays in the period, how many different days / weeks / months they fall in, and
/// (when weighing by time listened) how much time that was.
struct LoyaltyItem: Identifiable, Hashable, Sendable {
    let id: QueryEntityID
    let plays: Int
    let spread: Int
    /// What the horizontal axis plots: `plays`, or the seconds listened.
    let value: Int

    var title: String { id.target == .artist ? id.artist : id.name }
    var subtitle: String? { id.target == .artist ? nil : id.artist }
}

/// The loyalty map's data for the period and, when comparing, the previous one. Both come from the Query engine
/// (plays and the active-days/weeks/months fields), so a dot's numbers are the same ones Query shows for it and a
/// quadrant can be opened in Query as an ordinary filter. The quadrants, medians and what is drawn are decided by the
/// view, from these lists, as the controls change.
struct TrendsLoyalty: Sendable {
    let target: QueryTarget
    let spread: LoyaltySpread
    let metric: TrendsMetric
    let range: DateRange
    let compareRange: DateRange?
    let current: [LoyaltyItem]
    let previous: [LoyaltyItem]?
    /// Time listened only: entities left out because their runtime isn't resolved yet.
    let pending: Int
}

enum TrendsLoyaltyEngine {
    /// `scrobbles` must have canonical artist names. An entity is left out (and counted in `pending`) when weighing
    /// by time listened and its runtime isn't resolved yet — never guessed at.
    static func compute(
        scrobbles: [ScrobbleSnapshot], target: QueryTarget, spread: LoyaltySpread, range: DateRange, compareRange: DateRange?,
        metric: TrendsMetric = .plays, durations: DurationEngine.Snapshot = .empty, now: Date = Date()
    ) -> TrendsLoyalty? {
        let valueField = metric == .plays ? "plays" : "timeListened"
        var spec = QuerySpec(target: target)
        spec.columns = [QueryFieldRef("plays"), QueryFieldRef(spread.fieldID)] + (metric == .plays ? [] : [QueryFieldRef(valueField)])
        spec.asOf = now
        guard let validated = try? spec.validate(against: .standard) else { return nil }
        let snapshots = metric == .plays ? QuerySnapshots.empty : QuerySnapshots(durations: durations)

        var pendingCount = 0
        func items(_ r: DateRange) -> [LoyaltyItem] {
            let plays = scrobbles.filter { $0.playedAt >= r.from && $0.playedAt <= r.to }
            guard !plays.isEmpty else { return [] }
            let run = QueryRun(target: target, asOf: now, scrobbles: plays, allTimeScrobbles: scrobbles, snapshots: snapshots)
            let result = QueryEngine.evaluate(validated, run: run)
            guard let playsKey = result.columns.first(where: { $0.field.id == "plays" })?.cacheKey,
                  let spreadKey = result.columns.first(where: { $0.field.id == spread.fieldID })?.cacheKey,
                  let valueKey = result.columns.first(where: { $0.field.id == valueField })?.cacheKey else { return [] }
            return result.rows.compactMap { row -> LoyaltyItem? in
                guard case .value(.number(let p))? = row.cells[playsKey], case .value(.number(let s))? = row.cells[spreadKey] else { return nil }
                switch row.cells[valueKey] {
                case .value(.number(let v))?: return LoyaltyItem(id: row.entity.id, plays: Int(p), spread: Int(s), value: Int(v))
                case .pending?: pendingCount += 1; return nil
                default: return LoyaltyItem(id: row.entity.id, plays: Int(p), spread: Int(s), value: metric == .plays ? Int(p) : 0)
                }
            }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.title < $1.title }
        }

        let current = items(range)
        guard !current.isEmpty else { return nil }
        let previous = compareRange.map(items)
        return TrendsLoyalty(target: target, spread: spread, metric: metric, range: range, compareRange: compareRange, current: current, previous: previous, pending: pendingCount)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

extension TrendsDrill {
    /// The entities in one quadrant of the loyalty map, as a filter on the axis metric and on spread — the same
    /// dividing lines the chart drew. `minPlays` is the map's "at least this many plays" floor, applied regardless
    /// of which metric is plotted.
    static func loyaltyQuadrant(
        target: QueryTarget, spread: LoyaltySpread, quadrant: LoyaltyQuadrant, xMedian: Double, yMedian: Double, minPlays: Int, range: DateRange,
        metric: TrendsMetric = .plays
    ) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.period = QueryPeriod(from: range.from, to: range.to)
        let plays = QueryFieldRef("plays"), spreadRef = QueryFieldRef(spread.fieldID)
        let xRef = QueryFieldRef(metric == .plays ? "plays" : "timeListened")
        var conditions = [QueryCondition(plays, .greaterThanOrEqual, [.number(Double(minPlays))])]
        switch quadrant {
        case .lifers: conditions += [QueryCondition(xRef, .greaterThanOrEqual, [.number(xMedian)]), QueryCondition(spreadRef, .greaterThanOrEqual, [.number(yMedian)])]
        case .obsessions: conditions += [QueryCondition(xRef, .greaterThanOrEqual, [.number(xMedian)]), QueryCondition(spreadRef, .lessThan, [.number(yMedian)])]
        case .background: conditions += [QueryCondition(xRef, .lessThan, [.number(xMedian)]), QueryCondition(spreadRef, .greaterThanOrEqual, [.number(yMedian)])]
        case .passing: conditions += [QueryCondition(xRef, .lessThan, [.number(xMedian)]), QueryCondition(spreadRef, .lessThan, [.number(yMedian)])]
        }
        spec.groups = [conditions]
        spec.sorts = [QuerySort(key: .field(xRef), direction: .descending)]
        spec.columns = [plays, spreadRef] + (metric == .plays ? [] : [xRef])
        return spec
    }
}


extension TrendsDrill {
    /// Everything inside one shaded cell of the loyalty map: a range of the axis metric by a range of spread.
    static func loyaltyRegion(
        target: QueryTarget, spread: LoyaltySpread, x: Range<Double>, y: Range<Double>, isLastRow: Bool, isLastColumn: Bool, minPlays: Int, range: DateRange,
        metric: TrendsMetric = .plays
    ) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.period = QueryPeriod(from: range.from, to: range.to)
        let plays = QueryFieldRef("plays"), spreadRef = QueryFieldRef(spread.fieldID)
        let xRef = QueryFieldRef(metric == .plays ? "plays" : "timeListened")
        var conditions = [
            QueryCondition(plays, .greaterThanOrEqual, [.number(Double(minPlays))]),
            QueryCondition(xRef, .greaterThanOrEqual, [.number(max(metric == .plays ? Double(minPlays) : 0, x.lowerBound))]),
            QueryCondition(xRef, isLastColumn ? .lessThanOrEqual : .lessThan, [.number(x.upperBound)]),
            QueryCondition(spreadRef, .greaterThanOrEqual, [.number(y.lowerBound)]),
            QueryCondition(spreadRef, isLastRow ? .lessThanOrEqual : .lessThan, [.number(y.upperBound)]),
        ]
        spec.groups = [conditions]
        spec.sorts = [QuerySort(key: .field(xRef), direction: .descending)]
        spec.columns = [plays, spreadRef] + (metric == .plays ? [] : [xRef])
        return spec
    }
}
