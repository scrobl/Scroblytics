import Foundation

/// What a click on a cell of Overview's "Last 24 Hours" or "Current streak" strip hands to Query: the plays of that one hour or day,
/// one row for each, newest first. Built on `TrendsDrill.spec`, so it reads like the specs Trends' charts hand over.
enum OverviewDrill {
    struct Drill: Equatable {
        let spec: QuerySpec
        /// How the click is named in Query's header and the breadcrumb tooltip ("Scrobbles · Mon, Oct 12 · 3 PM").
        let detail: String
    }

    /// The first and last second of the local calendar day containing `date`. The next day is found with the calendar, not by adding
    /// 86,400 seconds, so a day with a clock change is 23 or 25 hours long and the range is still exactly that day.
    static func dayRange(containing date: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, next.addingTimeInterval(-1))
    }

    /// One cell of the 24-hour strip: the day the cell falls on, with the plays limited to that clock hour. (Query's period is whole
    /// days, so an hour is a day plus an hour filter, which Query shows and lets you edit.)
    static func hour(slotDate: Date, hour: Int, calendar: Calendar = AppCalendars.listening) -> Drill {
        let range = dayRange(containing: slotDate, calendar: calendar)
        let filter = QueryPlayFilter(weekdays: nil, fromHour: hour, toHour: hour)
        let day = slotDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return Drill(
            spec: TrendsDrill.spec(from: range.from, to: range.to, target: .scrobble, playFilter: filter),
            detail: "Scrobbles · \(day) · \(QueryPlayFilter.hourLabel(hour))"
        )
    }

    /// One cell of the streak strip: a local calendar day named "YYYY-MM-DD". nil if the name isn't a date.
    static func day(key: String, calendar: Calendar = AppCalendars.listening) -> Drill? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return nil }
        let range = dayRange(containing: date, calendar: calendar)
        let label = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        return Drill(
            spec: TrendsDrill.spec(from: range.from, to: range.to, target: .scrobble),
            detail: "Scrobbles · \(label)"
        )
    }
}
