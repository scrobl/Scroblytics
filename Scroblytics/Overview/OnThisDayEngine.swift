import Foundation

struct OnThisDayEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let track: String
    let artist: String
    let album: String?
    let imageURL: String?
    let playcount: Int
    /// Distinct years this track was played on this calendar day, newest first.
    let years: [Int]
    let lastPlayed: Date
}

/// On This Day's core ranking, scoped to "today, every year"
/// only (the full Tool's week/month period and specific-year modes, plus tag/
/// release-date/conditionGroup enrichment, are standalone-Tool richness not
/// needed for the Overview card).
enum TimeMachinePeriod: String, CaseIterable, Codable, Identifiable, Sendable {
    case day
    case week
    case month

    var id: Self { self }
    var label: String { rawValue.capitalized }
}

struct TimeMachineResult: Sendable {
    let entries: [OnThisDayEntry]
    let availableYears: [Int]
    let matchedScrobbleCount: Int
}

enum OnThisDayEngine {
    private struct ArtistTrackKey: Hashable {
        let artist: String
        let track: String
    }

    static func fetch(
        scrobbles all: [ScrobbleSnapshot], referenceDate: Date = Date(), calendar: Calendar = AppCalendars.listening, limit: Int = 100
    ) -> [OnThisDayEntry] {
        timeMachine(scrobbles: all, referenceDate: referenceDate, period: .day, year: nil, calendar: calendar, limit: limit).entries
    }

    static func timeMachine(
        scrobbles all: [ScrobbleSnapshot],
        referenceDate: Date,
        period: TimeMachinePeriod,
        year: Int?,
        calendar: Calendar = AppCalendars.listening,
        limit: Int = 0
    ) -> TimeMachineResult {
        let calendarMatches = all.filter {
            matches($0.playedAt, referenceDate: referenceDate, period: period, calendar: calendar)
        }
        let availableYears = Set(calendarMatches.map { calendar.component(.year, from: $0.playedAt) }).sorted(by: >)
        let matches = year.map { selected in
            calendarMatches.filter { calendar.component(.year, from: $0.playedAt) == selected }
        } ?? calendarMatches

        var groups: [ArtistTrackKey: [ScrobbleSnapshot]] = [:]
        for match in matches {
            groups[ArtistTrackKey(artist: match.artistName, track: match.trackName), default: []].append(match)
        }

        var entries = groups.map { key, group in
            var albumCounts: [String: Int] = [:]
            for scrobble in group where !scrobble.albumName.isEmpty {
                albumCounts[scrobble.albumName, default: 0] += 1
            }
            return OnThisDayEntry(
                track: key.track,
                artist: key.artist,
                album: albumCounts.max { $0.value < $1.value }?.key,
                imageURL: TextNormalization.firstNonPlaceholderImage(group.map(\.imageURL)),
                playcount: group.count,
                years: Set(group.map { calendar.component(.year, from: $0.playedAt) }).sorted(by: >),
                lastPlayed: group.map(\.playedAt).max() ?? referenceDate
            )
        }
        entries.sort { first, second in
            if first.playcount != second.playcount { return first.playcount > second.playcount }
            if first.years.count != second.years.count { return first.years.count > second.years.count }
            if first.artist != second.artist { return first.artist.localizedStandardCompare(second.artist) == .orderedAscending }
            return first.track.localizedStandardCompare(second.track) == .orderedAscending
        }
        if limit > 0 { entries = Array(entries.prefix(limit)) }
        return TimeMachineResult(entries: entries, availableYears: availableYears, matchedScrobbleCount: matches.count)
    }

    private static func matches(
        _ date: Date,
        referenceDate: Date,
        period: TimeMachinePeriod,
        calendar: Calendar
    ) -> Bool {
        let candidate = calendar.dateComponents([.month, .day], from: date)
        switch period {
        case .day:
            let reference = calendar.dateComponents([.month, .day], from: referenceDate)
            return candidate.month == reference.month && candidate.day == reference.day
        case .month:
            return candidate.month == calendar.component(.month, from: referenceDate)
        case .week:
            let weekday = calendar.component(.weekday, from: referenceDate)
            let weekStart = calendar.date(byAdding: .day, value: -(weekday - calendar.firstWeekday + 7) % 7, to: referenceDate) ?? referenceDate
            let calendarDays = Set((0..<7).compactMap { offset -> MonthDay? in
                guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
                let components = calendar.dateComponents([.month, .day], from: day)
                guard let month = components.month, let dayNumber = components.day else { return nil }
                return MonthDay(month: month, day: dayNumber)
            })
            guard let month = candidate.month, let day = candidate.day else { return false }
            return calendarDays.contains(MonthDay(month: month, day: day))
        }
    }

    private struct MonthDay: Hashable {
        let month: Int
        let day: Int
    }

    /// The Overview card is a nostalgic look back — it only shows tracks
    /// played on this calendar day in *previous* years, never today's own
    /// scrobbles (the full Time Machine tool lets the user opt into today;
    /// this card deliberately doesn't). Strips the current year from each
    /// entry's year list and drops anything left with none — note this only
    /// touches the displayed `years`, not `playcount` (which still includes
    /// any play from today).
    static func excludingCurrentYear(
        _ entries: [OnThisDayEntry], referenceDate: Date = Date(), calendar: Calendar = AppCalendars.listening
    ) -> [OnThisDayEntry] {
        let currentYear = calendar.component(.year, from: referenceDate)
        return entries
            .map { entry in
                OnThisDayEntry(
                    track: entry.track, artist: entry.artist, album: entry.album, imageURL: entry.imageURL,
                    playcount: entry.playcount, years: entry.years.filter { $0 < currentYear },
                    lastPlayed: entry.lastPlayed
                )
            }
            .filter { !$0.years.isEmpty }
    }
}
