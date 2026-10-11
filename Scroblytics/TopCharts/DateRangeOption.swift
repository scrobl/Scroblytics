import Foundation

/// The date-range preset list. Calendar boundaries anchor on the user's local
/// calendar: scrobble dates display in local time, so a UTC midnight boundary
/// would leak the prior day's/year's plays across the edge.
struct DateRange: Equatable {
    let from: Date
    let to: Date
}

struct DateRangeOption: Identifiable {
    let id: String
    let label: String
    let range: () -> DateRange
}

enum DateRangePresets {
    /// `oldestScrobbleDate` bounds "All time" and the range of per-year presets.
    static func build(oldestScrobbleDate: Date?) -> [DateRangeOption] {
        let calendar = AppCalendars.listening
        let now = Date()
        var options: [DateRangeOption] = []

        options.append(DateRangeOption(id: "alltime", label: "All time") {
            DateRange(from: oldestScrobbleDate ?? Date(timeIntervalSince1970: 0), to: Date())
        })
        options.append(DateRangeOption(id: "ytd", label: "Year to date") {
            let startOfYear = calendar.date(from: calendar.dateComponents([.year], from: Date()))!
            return DateRange(from: startOfYear, to: Date())
        })
        options.append(DateRangeOption(id: "mtd", label: "Month to date") {
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
            return DateRange(from: startOfMonth, to: Date())
        })
        let trailing: [(String, String, Int)] = [
            ("last7", "Last 7 days", 7), ("last30", "Last 30 days", 30),
            ("last90", "Last 90 days", 90), ("last365", "Last 365 days", 365),
        ]
        for (id, label, days) in trailing {
            options.append(DateRangeOption(id: id, label: label) {
                DateRange(from: Date().addingTimeInterval(-Double(days) * 86400), to: Date())
            })
        }

        let currentYear = calendar.component(.year, from: now)
        let oldestYear = oldestScrobbleDate.map { calendar.component(.year, from: $0) } ?? currentYear
        for year in stride(from: currentYear, through: oldestYear, by: -1) {
            options.append(DateRangeOption(id: "year-\(year)", label: "\(year)") {
                let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
                let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!.addingTimeInterval(-1)
                return DateRange(from: start, to: end)
            })
        }
        return options
    }
}
