import Foundation
import SwiftUI

/// Shared cell-coloring scale for the 24-hour heatmap and streak strips —
/// log-spaced
/// thresholds over whichever counts are actually being displayed, mapped to
/// 8 opacity levels; hue is orange for daytime hours (6am-6pm local) / blue
/// for night, unless a fixed override color is supplied (the streak strip's
/// purple).
enum HeatColorScale {
    private static let levelOpacityPercent: [Double] = [10, 20, 31, 43, 56, 70, 84, 97]

    /// 8 ascending thresholds. All-zero when every count is 0 (nothing to
    /// scale against); all-equal-to-that-value when every nonzero count is
    /// identical (log-spacing needs two distinct points).
    static func computeThresholds(_ counts: [Int]) -> [Double] {
        let nonzero = counts.filter { $0 > 0 }
        guard let minC = nonzero.min(), let maxC = nonzero.max() else {
            return Array(repeating: 0, count: 8)
        }
        if minC == maxC { return Array(repeating: Double(minC), count: 8) }
        let logMin = log(Double(minC))
        let logMax = log(Double(maxC))
        let step = (logMax - logMin) / 8
        return (1...8).map { exp(logMin + step * Double($0)) }
    }

    private static func level(for count: Int, thresholds: [Double]) -> Int {
        guard count > 0 else { return 0 }
        for (i, t) in thresholds.enumerated() where Double(count) <= t {
            return i + 1
        }
        return 8
    }

    static func isDayHour(_ hour: Int) -> Bool { hour >= 6 && hour < 18 }

    static func cellColor(count: Int, thresholds: [Double], hour: Int, override: Color? = nil) -> Color {
        let lvl = level(for: count, thresholds: thresholds)
        guard lvl > 0 else { return Color.gray.opacity(0.12) }
        let base = override ?? (isDayHour(hour) ? Color.orange : Color.blue)
        return base.opacity(levelOpacityPercent[lvl - 1] / 100)
    }
}

struct HeatmapCellCount {
    /// 0 = Sunday, matching JS `Date#getDay()`, local time.
    let day: Int
    /// 0-23, local time.
    let hour: Int
    let count: Int
}

/// Scrobble density per
/// local (day-of-week, hour-of-day) cell, 168 cells total for a given range.
/// Pure computation over a `Sendable` snapshot — safe to run off the main actor.
enum HeatmapEngine {
    static func buildCells(scrobbles: [ScrobbleSnapshot], from: Date, to: Date) -> [HeatmapCellCount] {
        let calendar = AppCalendars.listening
        var counts: [Int: Int] = [:]
        for s in scrobbles where s.playedAt >= from && s.playedAt <= to {
            // Calendar.weekday is 1=Sunday...7=Saturday; JS getDay() is
            // 0=Sunday...6=Saturday — subtract 1 to match exactly.
            let day = calendar.component(.weekday, from: s.playedAt) - 1
            let hour = calendar.component(.hour, from: s.playedAt)
            counts[day * 24 + hour, default: 0] += 1
        }
        var cells: [HeatmapCellCount] = []
        cells.reserveCapacity(168)
        for day in 0..<7 {
            for hour in 0..<24 {
                cells.append(HeatmapCellCount(day: day, hour: hour, count: counts[day * 24 + hour] ?? 0))
            }
        }
        return cells
    }

    /// Rolling `[anchor-24h, anchor]` window, NOT calendar-aligned. Each of the 24 hourly slots is identified by its own
    /// local (weekday, hour) pair and looked up from the full density map;
    /// over exactly 24 hours those 24 pairs are unique, so this is
    /// equivalent to true hourly bucketing without needing a separate code
    /// path from the 168-cell computation above.
    static func rollingLast24Hours(scrobbles: [ScrobbleSnapshot], anchor: Date) -> [(date: Date, hour: Int, count: Int)] {
        let calendar = AppCalendars.listening
        let from = calendar.date(byAdding: .hour, value: -24, to: anchor) ?? anchor.addingTimeInterval(-86400)
        let cells = buildCells(scrobbles: scrobbles, from: from, to: anchor)
        var lookup: [Int: Int] = [:]
        for c in cells { lookup[c.day * 24 + c.hour] = c.count }

        var slots: [(date: Date, hour: Int, count: Int)] = []
        for i in 0..<24 {
            let t = calendar.date(byAdding: .hour, value: -(23 - i), to: anchor) ?? anchor
            let day = calendar.component(.weekday, from: t) - 1
            let hour = calendar.component(.hour, from: t)
            slots.append((date: t, hour: hour, count: lookup[day * 24 + hour] ?? 0))
        }
        return slots
    }
}
