import Foundation
import SwiftData

struct StreakDay: Sendable {
    /// Local calendar date, "YYYY-MM-DD".
    let date: String
    /// UTC-midnight of this calendar date — a presentation encoding (not a
    /// real local-midnight instant) so
    /// day-number labels can be read back with a UTC calendar regardless of
    /// the viewer's own timezone.
    let utcDate: Date
    let count: Int
}

struct ListeningStreakResult: Sendable {
    let days: [StreakDay]
    /// Consecutive days with at least one scrobble, counting back from
    /// today (or yesterday if today has none yet — today isn't "broken"
    /// until it ends).
    let currentStreak: Int
    /// Longest run of consecutive local calendar days with at least one
    /// scrobble across the entire synced history.
    let longestStreak: Int
}

/// Listening streak — a "day" is a local calendar day in
/// the current timezone; the trailing-days window and both streak counts are
/// computed over ALL synced history, independent of the page's date range.
/// Pure computation over a `Sendable` snapshot — safe to run off the main
/// actor, which Overview now does for its whole local phase.
enum ListeningStreakEngine {
    static func fetch(scrobbles allScrobbles: [ScrobbleSnapshot], days: Int = 30) -> ListeningStreakResult {
        let calendar = AppCalendars.listening

        func dayKey(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }

        var countsByDay: [String: Int] = [:]
        for s in allScrobbles {
            countsByDay[dayKey(s.playedAt), default: 0] += 1
        }

        let today = calendar.startOfDay(for: Date())

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        var dayList: [StreakDay] = []
        dayList.reserveCapacity(days)
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let d = calendar.date(byAdding: .day, value: -i, to: today) else { continue }
            let key = dayKey(d)
            let comps = calendar.dateComponents([.year, .month, .day], from: d)
            let utcDate = utcCalendar.date(from: comps) ?? d
            dayList.append(StreakDay(date: key, utcDate: utcDate, count: countsByDay[key] ?? 0))
        }

        var currentStreak = 0
        var cursor = today
        if (countsByDay[dayKey(cursor)] ?? 0) == 0 {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while (countsByDay[dayKey(cursor)] ?? 0) > 0 {
            currentStreak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        // Longest run of consecutive calendar days across all history —
        // string-sorted keys equal chronological order for "YYYY-MM-DD".
        let sortedKeys = countsByDay.keys.sorted()
        var longestStreak = 0
        var run = 0
        var prevKey: String?
        let keyFormatter = DateFormatter()
        keyFormatter.dateFormat = "yyyy-MM-dd"
        keyFormatter.timeZone = TimeZone(identifier: "UTC")
        for key in sortedKeys {
            if let prev = prevKey, let prevDate = keyFormatter.date(from: prev), let currDate = keyFormatter.date(from: key) {
                let diffDays = Int((currDate.timeIntervalSince(prevDate) / 86400).rounded())
                run = diffDays == 1 ? run + 1 : 1
            } else {
                run = 1
            }
            if run > longestStreak { longestStreak = run }
            prevKey = key
        }

        return ListeningStreakResult(days: dayList, currentStreak: currentStreak, longestStreak: longestStreak)
    }
}
