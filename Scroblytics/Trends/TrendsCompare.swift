import Foundation
import SwiftUI
import Observation

/// How Trends compares a period with another. Separate from the shared "chart comparison" used by Top Charts and
/// Overview: that one keeps the period's start and moves its END back N days (how a ranking looked N days ago),
/// which is not period-over-period. These are whole like-for-like periods.
enum TrendsCompareMode: String, CaseIterable, Identifiable, Sendable {
    case off, previous, lastYear, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "No comparison"
        case .previous: "Previous period"
        case .lastYear: "Same period last year"
        case .custom: "Custom period…"
        }
    }
}

enum TrendsCompare {
    /// The period to compare `range` with, or nil for none.
    ///
    /// - Previous period: the one just before, of the same shape. A calendar-aligned period compares with the
    ///   matching calendar one — a year with the year before, "month to date" with the previous month over the same
    ///   days (Sep 1–26 with Aug 1–26), the way a person means it — and anything else (a trailing window) with the
    ///   equal-length stretch right before it.
    /// - Same period last year: both ends moved back a year.
    /// - Custom: exactly the dates given.
    ///
    /// Like-for-like matters when the period is still running: a half-finished month is compared with the same
    /// stretch of the last one, never with a whole month.
    static func resolve(_ mode: TrendsCompareMode, range: DateRange, custom: DateRange?, calendar: Calendar = AppCalendars.listening) -> DateRange? {
        switch mode {
        case .off:
            return nil
        case .custom:
            guard let custom, custom.from <= custom.to else { return nil }
            return custom
        case .lastYear:
            return shifted(range, .year, by: 1, calendar: calendar)
        case .previous:
            let start = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: range.from)
            if start.month == 1, start.day == 1, start.hour == 0, start.minute == 0, start.second == 0 {
                return shifted(range, .year, by: 1, calendar: calendar)
            }
            if start.day == 1, start.hour == 0, start.minute == 0, start.second == 0 {
                return shifted(range, .month, by: 1, calendar: calendar)
            }
            let length = range.to.timeIntervalSince(range.from)
            let end = range.from.addingTimeInterval(-1)
            return DateRange(from: end.addingTimeInterval(-length), to: end)
        }
    }

    /// Both ends moved back `count` calendar units. An end that is the last moment of its month stays the last
    /// moment of the month it lands in (Sep 30 → Aug 31, not Aug 30).
    private static func shifted(_ range: DateRange, _ unit: Calendar.Component, by count: Int, calendar: Calendar) -> DateRange? {
        guard let from = calendar.date(byAdding: unit, value: -count, to: range.from) else { return nil }
        let to: Date?
        if isLastMomentOfMonth(range.to, calendar: calendar),
           let moved = calendar.date(byAdding: unit, value: -count, to: range.to),
           let monthEnd = calendar.dateInterval(of: .month, for: moved)?.end {
            to = monthEnd.addingTimeInterval(-1)
        } else {
            to = calendar.date(byAdding: unit, value: -count, to: range.to)
        }
        guard let to else { return nil }
        return DateRange(from: from, to: to)
    }

    private static func isLastMomentOfMonth(_ date: Date, calendar: Calendar) -> Bool {
        guard let end = calendar.dateInterval(of: .month, for: date)?.end else { return false }
        return abs(end.timeIntervalSince(date) - 1) < 1
    }
}

/// The Trends page's own comparison choice, remembered across launches.
@MainActor
@Observable
final class TrendsSettings {
    private enum Keys {
        static let mode = "trends.compareMode"
        static let customFrom = "trends.compareCustomFrom"
        static let customTo = "trends.compareCustomTo"
    }

    var compareMode: TrendsCompareMode {
        didSet { UserDefaults.standard.set(compareMode.rawValue, forKey: Keys.mode) }
    }
    var customFrom: Date? {
        didSet { UserDefaults.standard.set(customFrom, forKey: Keys.customFrom) }
    }
    var customTo: Date? {
        didSet { UserDefaults.standard.set(customTo, forKey: Keys.customTo) }
    }

    init() {
        let defaults = UserDefaults.standard
        compareMode = defaults.string(forKey: Keys.mode).flatMap(TrendsCompareMode.init(rawValue:)) ?? .previous
        customFrom = defaults.object(forKey: Keys.customFrom) as? Date
        customTo = defaults.object(forKey: Keys.customTo) as? Date
    }

    /// The custom period as whole days: from the start of the first day through the end of the last.
    var customRange: DateRange? {
        guard let customFrom, let customTo else { return nil }
        let calendar = AppCalendars.listening
        let start = calendar.startOfDay(for: min(customFrom, customTo))
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(customFrom, customTo)))?.addingTimeInterval(-1) else { return nil }
        return DateRange(from: start, to: end)
    }

    func resolve(for range: DateRange) -> DateRange? {
        TrendsCompare.resolve(compareMode, range: range, custom: customRange)
    }
}

/// The comparison picker in the Trends header: what to compare with, and — for a custom period — its two dates.
struct TrendsCompareControl: View {
    @Bindable var settings: TrendsSettings
    let currentRange: DateRange

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                compareMenu
                customDateControls
            }
            VStack(alignment: .leading, spacing: 8) {
                compareMenu
                customDateControls
            }
        }
    }

    private var compareMenu: some View {
        Menu {
            Picker("Compare with", selection: Binding(
                get: { settings.compareMode },
                set: { mode in
                    if mode == .custom, settings.customRange == nil { seedCustomPeriod() }
                    settings.compareMode = mode
                }
            )) {
                ForEach(TrendsCompareMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Compare: \(settings.compareMode.label)", systemImage: "arrow.left.arrow.right")
        }
    }

    @ViewBuilder
    private var customDateControls: some View {
        if settings.compareMode == .custom {
            HStack(spacing: 8) {
                PopoverDatePicker("From", selection: Binding(get: { settings.customFrom ?? currentRange.from }, set: { settings.customFrom = $0 }), in: Date(timeIntervalSince1970: 0)...Date())
                Text("to").foregroundStyle(.secondary)
                PopoverDatePicker("To", selection: Binding(get: { settings.customTo ?? currentRange.from }, set: { settings.customTo = $0 }), in: Date(timeIntervalSince1970: 0)...Date())
            }
        }
    }

    /// A first guess for a custom period — the previous one — so the pickers open on something sensible.
    private func seedCustomPeriod() {
        let seed = TrendsCompare.resolve(.previous, range: currentRange, custom: nil)
        settings.customFrom = seed?.from ?? currentRange.from
        settings.customTo = seed?.to ?? currentRange.from
    }
}
