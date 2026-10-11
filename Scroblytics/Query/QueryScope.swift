import Foundation

/// A date range a single field is computed over — "Plays, scoped to last September" beside "Plays,
/// scoped to the last 7 days" in the same table. A scope is either fixed dates or RELATIVE to "now"
/// (the run's `asOf`), so a saved set built from "the same 7 days a year earlier" stays correct next
/// week. A field with no scope reads the query's own period.
///
/// A scope is a base period, optionally moved back by whole units:
/// - **all time** — no bounds;
/// - **up to now** — everything before "now" (shifted back: the cumulative standing as of then);
/// - **last N days** — the N days ending "now";
/// - **calendar unit** — the day/week/month/quarter/year containing "now";
/// - **dates** — fixed from/to, either end optional.
///
/// Shifting moves "now" back first and THEN takes the period, so "this month, 1 year earlier" is the
/// whole of that month a year ago (not a month-end that drifted), and "last 7 days, 1 year earlier"
/// is the same 7 days a year back.
struct QueryScope: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case allTime, upToNow, trailing, calendar, absolute }
    enum Unit: String, Codable, CaseIterable, Sendable { case day, week, month, quarter, year }

    var kind: Kind
    /// `trailing`: how many days.
    var days: Int?
    /// `calendar`: which unit.
    var unit: Unit?
    /// `absolute`: either end may be nil (open).
    var from: Date?
    var to: Date?
    /// How many `shiftUnit`s to move "now" back before taking the period. 0 = none.
    var shiftCount: Int = 0
    var shiftUnit: Unit = .year

    static let allTime = QueryScope(kind: .allTime)
    static let upToNow = QueryScope(kind: .upToNow)
    static func trailing(days: Int) -> QueryScope { QueryScope(kind: .trailing, days: days) }
    static func calendar(_ unit: Unit) -> QueryScope { QueryScope(kind: .calendar, unit: unit) }
    static func absolute(from: Date?, to: Date?) -> QueryScope { QueryScope(kind: .absolute, from: from, to: to) }

    func shifted(back count: Int, _ unit: Unit) -> QueryScope {
        var copy = self
        copy.shiftCount = count
        copy.shiftUnit = unit
        return copy
    }

    /// Fixed dates and "all time" can't be moved: their meaning is already exact.
    var canShift: Bool { kind != .allTime && kind != .absolute }

    /// Stable text for caches and column identity.
    var cacheKey: String {
        [kind.rawValue, days.map(String.init) ?? "", unit?.rawValue ?? "",
         from.map { String($0.timeIntervalSince1970) } ?? "", to.map { String($0.timeIntervalSince1970) } ?? "",
         String(shiftCount), shiftCount > 0 ? shiftUnit.rawValue : ""].joined(separator: "|")
    }
}

/// A scope resolved to actual dates, inclusive at both ends; nil = open on that side.
struct ResolvedScope: Hashable, Sendable {
    var from: Date?
    var to: Date?

    func contains(_ date: Date) -> Bool {
        (from.map { date >= $0 } ?? true) && (to.map { date <= $0 } ?? true)
    }
}

extension QueryScope {
    /// Checks the scope makes sense; throws the first problem.
    func validate() throws {
        if shiftCount < 0 { throw QueryError.invalidScope("can’t shift forward in time") }
        if shiftCount > 0, !canShift { throw QueryError.invalidScope("“\(label)” can’t be shifted") }
        switch kind {
        case .trailing:
            guard let days, days >= 1 else { throw QueryError.invalidScope("“last N days” needs N of at least 1") }
        case .calendar:
            guard unit != nil else { throw QueryError.invalidScope("pick a calendar unit") }
        case .absolute:
            if let from, let to, from > to { throw QueryError.rangeOutOfOrder }
        case .allTime, .upToNow:
            break
        }
    }

    /// The actual dates for a run whose "now" is `asOf`.
    func resolve(asOf: Date, calendar: Calendar) throws -> ResolvedScope {
        try validate()
        let anchor = Self.shift(asOf, back: shiftCount, shiftUnit, calendar: calendar)
        switch kind {
        case .allTime:
            return ResolvedScope(from: nil, to: nil)
        case .upToNow:
            return ResolvedScope(from: nil, to: anchor)
        case .trailing:
            // Seconds, not calendar days — exactly how Top Charts' "Last N days" presets are drawn.
            return ResolvedScope(from: anchor.addingTimeInterval(-Double(days!) * 86400), to: anchor)
        case .calendar:
            let interval = Self.interval(of: unit!, containing: anchor, calendar: calendar)
            // Inclusive end: the last second of the period, like Top Charts' year presets.
            return ResolvedScope(from: interval.start, to: interval.end.addingTimeInterval(-1))
        case .absolute:
            return ResolvedScope(from: from, to: to)
        }
    }

    private static func shift(_ date: Date, back count: Int, _ unit: Unit, calendar: Calendar) -> Date {
        guard count > 0 else { return date }
        let (component, value): (Calendar.Component, Int) = switch unit {
        case .day: (.day, -count)
        case .week: (.weekOfYear, -count)
        case .month: (.month, -count)
        case .quarter: (.month, -3 * count)
        case .year: (.year, -count)
        }
        return calendar.date(byAdding: component, value: value, to: date) ?? date
    }

    private static func interval(of unit: Unit, containing date: Date, calendar: Calendar) -> DateInterval {
        switch unit {
        case .day: return calendar.dateInterval(of: .day, for: date)!
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)!
        case .month: return calendar.dateInterval(of: .month, for: date)!
        case .year: return calendar.dateInterval(of: .year, for: date)!
        case .quarter:
            let month = calendar.component(.month, from: date)
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1
            var components = calendar.dateComponents([.year], from: date)
            components.month = quarterStartMonth
            components.day = 1
            let start = calendar.date(from: components)!
            let end = calendar.date(byAdding: .month, value: 3, to: start)!
            return DateInterval(start: start, end: end)
        }
    }

    /// "Last 7 days, 1 year earlier" — shown on column headers and in the scope picker.
    var label: String {
        let base: String
        switch kind {
        case .allTime: base = "All time"
        case .upToNow: base = "Up to now"
        case .trailing: base = "Last \(days ?? 0) day\(days == 1 ? "" : "s")"
        case .calendar:
            base = switch unit ?? .month {
            case .day: "Today"
            case .week: "This week"
            case .month: "This month"
            case .quarter: "This quarter"
            case .year: "This year"
            }
        case .absolute:
            let f = { (d: Date) in d.formatted(date: .abbreviated, time: .omitted) }
            switch (from, to) {
            case (let a?, let b?): base = "\(f(a)) – \(f(b))"
            case (let a?, nil): base = "From \(f(a))"
            case (nil, let b?): base = "Until \(f(b))"
            case (nil, nil): base = "All time"
            }
        }
        guard shiftCount > 0, canShift else { return base }
        return "\(base), \(shiftCount) \(shiftUnit.rawValue)\(shiftCount == 1 ? "" : "s") earlier"
    }
}
