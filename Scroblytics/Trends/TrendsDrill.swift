import Foundation

/// What a Trends chart hands to Query when something is clicked: an ordinary `QuerySpec` (so the user can edit,
/// save or extend it) restricted to the clicked period and ordered by plays in it.
enum TrendsDrill {
    static func spec(from: Date, to: Date, target: QueryTarget, playFilter: QueryPlayFilter? = nil, tag: String? = nil) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.period = QueryPeriod(from: from, to: to)
        spec.playFilter = playFilter
        // Only what was played in the period; without this a zero-play item would match everything.
        spec.groups = [[QueryCondition("plays", .greaterThan, [.number(0)])]]
        if let tag { spec.groups[0].append(QueryCondition("tags", .tagsIsAny, [.tags([tag])])) }
        spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
        spec.columns = AskInterpreter.baseColumns.map { QueryFieldRef($0) }
        return spec
    }

    /// The entities whose `metric` falls in a histogram bar — over the same period the chart was drawn for.
    static func longTailBin(target: QueryTarget, metric: LongTailMetric, bin: LongTailBin, range: DateRange) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.period = QueryPeriod(from: range.from, to: range.to)
        let field = QueryFieldRef(metric.fieldID)
        if bin.lo == bin.hi {
            spec.groups = [[QueryCondition(field, .equals, [.number(bin.lo)])]]
        } else {
            spec.groups = [[QueryCondition(field, .greaterThanOrEqual, [.number(bin.lo)]),
                            QueryCondition(field, bin.isLast ? .lessThanOrEqual : .lessThan, [.number(bin.hi)])]]
        }
        spec.sorts = [QuerySort(key: .field(field), direction: .descending)]
        spec.columns = [field] + (metric == .plays ? [] : [QueryFieldRef("plays")])
        return spec
    }

    /// The tracks a bucket discovered: those whose first-ever play falls in it. No period — a first play is only
    /// meaningful over the whole history.
    static func discoveries(from: Date, to: Date) -> QuerySpec {
        var spec = QuerySpec(target: .track)
        spec.groups = [[QueryCondition("firstPlayed", .dateBetween, [.date(AppCalendars.listening.startOfDay(for: from)), .date(AppCalendars.listening.startOfDay(for: to))])]]
        spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
        spec.columns = [QueryFieldRef("firstPlayed"), QueryFieldRef("plays")]
        return spec
    }

    /// "Mar 4, 2026", "Week of Mar 2, 2026", "March 2026" — how a bucket is named.
    static func label(start: Date, granularity: TrendGranularity) -> String {
        switch granularity {
        case .day: start.formatted(.dateTime.month(.abbreviated).day().year())
        case .week: "Week of " + start.formatted(.dateTime.month(.abbreviated).day().year())
        case .month: start.formatted(.dateTime.month(.wide).year())
        }
    }

    static func rangeLabel(from: Date, to: Date) -> String {
        let f = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return from.formatted(f) + " – " + to.formatted(f)
    }
}

extension TrendsDrill {
    /// What ranked in a bucket: the entities of `target` by plays in it, top N — the column of dots the chart shows.
    static func rankedBucket(target: QueryTarget, topN: Int, from: Date, to: Date, metric: TrendsMetric = .plays) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.period = QueryPeriod(from: from, to: to)
        spec.groups = [[QueryCondition("plays", .greaterThan, [.number(0)])]]
        let sortField = metric == .plays ? "playRank" : "timeListened"
        spec.sorts = [QuerySort(key: .field(QueryFieldRef(sortField)), direction: metric == .plays ? .ascending : .descending)]
        spec.limit = topN
        spec.columns = [QueryFieldRef(metric == .plays ? "playRank" : "timeListened"), QueryFieldRef("plays")]
        return spec
    }
}

extension TrendsDrill {
    /// What of one release decade was played in a bucket.
    static func decadeBucket(target: QueryTarget, decade: Int, from: Date, to: Date, metric: TrendsMetric = .plays) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.period = QueryPeriod(from: from, to: to)
        let years = TrendsDecadeRiver.yearRange(ofDecade: decade)
        var conditions = [QueryCondition("plays", .greaterThan, [.number(0)])]
        switch (years.from, years.to) {
        case (let lo?, let hi?): conditions.append(QueryCondition("releaseYear", .between, [.number(Double(lo)), .number(Double(hi))]))
        case (let lo?, nil): conditions.append(QueryCondition("releaseYear", .greaterThanOrEqual, [.number(Double(lo))]))
        case (nil, let hi?): conditions.append(QueryCondition("releaseYear", .lessThanOrEqual, [.number(Double(hi))]))
        case (nil, nil): break
        }
        spec.groups = [conditions]
        let sortField = metric == .plays ? "plays" : "timeListened"
        spec.sorts = [QuerySort(key: .field(QueryFieldRef(sortField)), direction: .descending)]
        spec.columns = [QueryFieldRef("releaseYear"), QueryFieldRef("plays")] + (metric == .plays ? [] : [QueryFieldRef("timeListened")])
        return spec
    }
}


extension TrendsDrill {
    /// What of a range of release years was played in a bucket (the time-travel map's cell).
    static func releaseYears(target: QueryTarget, years: ClosedRange<Int>, from: Date, to: Date, metric: TrendsMetric = .plays) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.period = QueryPeriod(from: from, to: to)
        var conditions = [QueryCondition("plays", .greaterThan, [.number(0)])]
        if years.lowerBound == years.upperBound {
            conditions.append(QueryCondition("releaseYear", .equals, [.number(Double(years.lowerBound))]))
        } else {
            conditions.append(QueryCondition("releaseYear", .between, [.number(Double(years.lowerBound)), .number(Double(years.upperBound))]))
        }
        spec.groups = [conditions]
        let sortField = metric == .plays ? "plays" : "timeListened"
        spec.sorts = [QuerySort(key: .field(QueryFieldRef(sortField)), direction: .descending)]
        spec.columns = [QueryFieldRef("releaseYear"), QueryFieldRef("plays")] + (metric == .plays ? [] : [QueryFieldRef("timeListened")])
        return spec
    }
}
