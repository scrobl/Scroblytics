import Foundation

/// Which half of the world the person lives in, because winter is December to February in the north and June to August in the south.
/// Chosen in Settings › General (northern until chosen); everything that names a season reads it from here.
enum Hemisphere: String, CaseIterable, Identifiable, Sendable {
    case north, south

    var id: String { rawValue }
    var label: String { self == .north ? "Northern hemisphere" : "Southern hemisphere" }
}

/// A meteorological season: three whole calendar months, so a play's season never depends on the exact solstice or equinox.
/// The order (winter first) is the order of the Season field's choices and of its tie-break.
enum Season: Int, CaseIterable, Identifiable, Sendable {
    case winter, spring, summer, autumn

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .winter: "Winter"
        case .spring: "Spring"
        case .summer: "Summer"
        case .autumn: "Autumn"
        }
    }

    /// The calendar months (1 = January) of this season in that hemisphere, in calendar order starting from the first of the three.
    func months(in hemisphere: Hemisphere) -> [Int] {
        let north: [Int]
        switch self {
        case .winter: north = [12, 1, 2]
        case .spring: north = [3, 4, 5]
        case .summer: north = [6, 7, 8]
        case .autumn: north = [9, 10, 11]
        }
        return hemisphere == .north ? north : north.map { (($0 - 1 + 6) % 12) + 1 }
    }

    /// The season a calendar month (1–12) falls in.
    static func of(month: Int, in hemisphere: Hemisphere) -> Season {
        allCases.first { $0.months(in: hemisphere).contains(month) } ?? .winter
    }

    /// The season whose three months are exactly `months` (in any order), if there is one.
    static func matching(months: [Int], in hemisphere: Hemisphere) -> Season? {
        let wanted = Set(months)
        return allCases.first { Set($0.months(in: hemisphere)) == wanted }
    }

    /// "Dec–Feb": the first and last month of the season as the calendar runs.
    func rangeLabel(in hemisphere: Hemisphere) -> String {
        let months = months(in: hemisphere)
        return "\(MonthNames.short[months[0] - 1])–\(MonthNames.short[months[2] - 1])"
    }
}

enum MonthNames {
    static let short = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let full = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
}

enum SeasonSettings {
    static let hemisphereKey = "seasons.hemisphere"

    static func hemisphere(defaults: UserDefaults = .standard) -> Hemisphere {
        defaults.string(forKey: hemisphereKey).flatMap(Hemisphere.init(rawValue:)) ?? .north
    }

    static var hemisphere: Hemisphere { hemisphere() }
}
