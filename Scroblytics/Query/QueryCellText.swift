import Foundation

/// A query cell as plain text, the way the results table shows it. The table draws some cells as pictures (a heart, a flag, a bar), but
/// anything that needs words (a shared card, its text copies) reads this, so the two never disagree about a number or a date.
@MainActor
enum QueryCellText {
    static func string(_ cell: QueryCell, column: ResolvedField) -> String {
        switch cell {
        case .pending: return "…"
        case .missing: return "—"
        case .value(let value): return string(value, column: column)
        }
    }

    static func string(_ value: QueryValue, column: ResolvedField) -> String {
        switch (column.field.column.style, value) {
        case (.custom("peakBadge"), .number(let n)): return "\(Int(n)) at peak"
        case (.custom("popularityDiamond"), .bool(let popular)): return popular ? "Popular" : "—"
        case (.custom("lovedHeart"), .bool(let loved)): return loved ? "Loved" : "—"
        case (.custom("flaggedFlag"), .bool(let flagged)): return flagged ? "Flagged" : "—"
        case (.custom("similarScore"), .number(let n)): return Int(n.rounded()).formatted()
        case (.custom("becauseYouLike"), .text(let seeds)): return seeds.replacingOccurrences(of: SimilaritySnapshot.sourceSeparator, with: ", ")
        case (.custom, _): return plain(value)
        case (.integer, .number(let n)): return Int(n).formatted()
        case (.decimal(let places), .number(let n)): return n.formatted(.number.precision(.fractionLength(places)))
        case (.year, .number(let n)): return String(Int(n))
        case (.runtime, .number(let n)): return DurationEngine.formatDuration(Int(n))
        case (.tempo, .number(let n)): return BPMEngine.format(n)
        case (.temperature, .number(let n)): return WeatherSettings.temperatureUnit().text(shown: n, places: 1)
        case (.listeningTime, .number(let n)): return DurationEngine.formatTimeListened(Int(n))
        case (.percent, .number(let n)): return n.formatted(.percent.precision(.fractionLength(0)))
        case (.date, .date(let d)): return date(d, fieldID: column.field.id)
        default: return plain(value)
        }
    }

    static func date(_ date: Date, fieldID: String) -> String {
        switch fieldID {
        case "firstPlayed", "lastPlayed": AppDateFormatting.recentPlay.string(from: date)
        case "releaseDate": AppDateFormatting.releaseDate.string(from: date)
        default: date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    private static func plain(_ value: QueryValue) -> String {
        switch value {
        case .number(let n): n.formatted()
        case .text(let s): s
        case .bool(let b): b ? "Yes" : "No"
        case .date(let d): d.formatted(date: .abbreviated, time: .omitted)
        case .tags(let t): t.joined(separator: ", ")
        }
    }
}
