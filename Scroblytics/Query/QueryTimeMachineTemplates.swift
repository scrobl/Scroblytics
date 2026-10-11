import Foundation

/// The "Time Machine" scenarios — pick a period now and the same period a while back, and compare
/// them — expressed as ordinary saved query sets. Nothing here is special machinery: each is a
/// few registry fields scoped to a date range (`plays`, `playRank`) or comparing two (`rankMovement`,
/// `playsChange`), plus conditions and a sort, so every one can be opened, edited and re-saved in the
/// builder like any other set.
enum QueryTimeMachineTemplates {
    /// The two periods a scenario compares. `then` is normally `now` moved back (a week, a month, a
    /// year), but any two scopes work — the builder lets either be changed after loading.
    struct Comparison: Sendable {
        var now: QueryScope
        var then: QueryScope
        var title: String

        /// The last 7 days against the same 7 days a year earlier.
        static let weekVsLastYear = Comparison(
            now: .trailing(days: 7), then: QueryScope.trailing(days: 7).shifted(back: 1, .year), title: "This week vs. a year ago")
        /// This calendar month so far against the whole of the same month a year earlier.
        static let monthVsLastYear = Comparison(
            now: .calendar(.month), then: QueryScope.calendar(.month).shifted(back: 1, .year), title: "This month vs. a year ago")
    }

    enum Scenario: String, CaseIterable, Sendable {
        case thenVersusNow, whatIWasInto, goneQuiet, newArrivals

        var title: String {
            switch self {
            case .thenVersusNow: "Then vs. now"
            case .whatIWasInto: "What I was into then"
            case .goneQuiet: "Gone quiet since"
            case .newArrivals: "New arrivals"
            }
        }
    }

    /// Top-N cut-offs the two "who left / who arrived" scenarios use.
    static let topThen = 25
    static let stillPresent = 100

    static func spec(_ scenario: Scenario, target: QueryTarget, _ comparison: Comparison, top: Int = 10) -> QuerySpec {
        let now = comparison.now, then = comparison.then
        func rank(_ scope: QueryScope) -> QueryFieldRef { QueryFieldRef("playRank", scope: scope) }
        func plays(_ scope: QueryScope) -> QueryFieldRef { QueryFieldRef("plays", scope: scope) }
        let movement = QueryFieldRef("rankMovement", scope: now, baseline: then)
        let change = QueryFieldRef("playsChange", scope: now, baseline: then)

        var spec = QuerySpec(target: target)
        switch scenario {
        case .thenVersusNow:
            // Anything played in either period, in the order of the current period's chart.
            spec.groups = [[QueryCondition(plays(now), .greaterThan, [.number(0)])], [QueryCondition(plays(then), .greaterThan, [.number(0)])]]
            spec.sorts = [QuerySort(key: .field(rank(now)), direction: .ascending), QuerySort(key: .field(rank(then)), direction: .ascending)]
            spec.columns = [rank(now), plays(now), rank(then), plays(then), movement, change]
            spec.limit = 25
        case .whatIWasInto:
            // The top of the earlier period, and where each of them stands now.
            spec.groups = [[QueryCondition(rank(then), .lessThanOrEqual, [.number(Double(top))])]]
            spec.sorts = [QuerySort(key: .field(rank(then)), direction: .ascending)]
            spec.columns = [rank(then), plays(then), rank(now), plays(now), movement]
            spec.limit = top
        case .goneQuiet:
            // In the earlier top 25 but out of today's top 100 — including anything not played at all.
            let earlier = QueryCondition(rank(then), .lessThanOrEqual, [.number(Double(topThen))])
            spec.groups = [
                [earlier, QueryCondition(rank(now), .greaterThan, [.number(Double(stillPresent))])],
                [earlier, QueryCondition(rank(now), .isMissing)],
            ]
            spec.sorts = [QuerySort(key: .field(rank(then)), direction: .ascending)]
            spec.columns = [rank(then), plays(then), rank(now), plays(now)]
        case .newArrivals:
            // In today's top 25 with no plays at all in the earlier period.
            spec.groups = [[QueryCondition(rank(now), .lessThanOrEqual, [.number(Double(topThen))]), QueryCondition(rank(then), .isMissing)]]
            spec.sorts = [QuerySort(key: .field(rank(now)), direction: .ascending)]
            spec.columns = [rank(now), plays(now), plays(then)]
        }
        return spec
    }
}
