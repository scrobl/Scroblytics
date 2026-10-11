import Foundation

/// Which day a week starts on, everywhere in the app (week buckets, "this week" date scopes, Active weeks, Time
/// Machine's week). The raw value is `Calendar.firstWeekday` (Sunday = 1).
enum WeekStart: Int, CaseIterable, Identifiable, Sendable {
    case monday = 2, sunday = 1, friday = 6

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .monday: "Monday"
        case .sunday: "Sunday"
        case .friday: "Friday"
        }
    }
}

extension Notification.Name {
    /// Posted when the week-start setting changes, so screens that cut data into weeks recompute.
    static let weekStartDidChange = Notification.Name("WeekStartDidChange")
}

/// The app's two date domains. Listening history follows the user's local day,
/// while release dates are date-only metadata and stay anchored to UTC.
/// Both use the one chosen week start; no week boundary is ever stored, so changing it is always safe.
enum AppCalendars {
    static let weekStartKey = "weekStartDay"

    static var weekStart: WeekStart {
        WeekStart(rawValue: UserDefaults.standard.integer(forKey: weekStartKey)) ?? .monday
    }

    static var listening: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = weekStart.rawValue
        return calendar
    }

    static var releaseDates: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = weekStart.rawValue
        return calendar
    }
}
